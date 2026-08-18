/**
 * HDC FILE 通道（应用 → 所连设备推文件）。
 *
 * 帧序列是 2026-08-18 真机探针验证过的（scripts/device/hdc-file-probe.js，
 * ALN-AL00 + PC 官方 hdckey，30KB 三帧 MD5 一致）：
 *   1. WAKEUP_SLAVETASK(12) 空 payload —— daemon 预建任务容器，必须最先发
 *   2. FILE_CHECK(3001) = TransferConfig{1:fileSize, 5:path, 6:optionalName,
 *      7:updateIfNew=0, 8:compressType=0}（protobuf wire format）
 *   3. daemon → FILE_BEGIN(3002)（真机 payload 8B 非空，内容忽略；源码说空，闭源版加了东西）
 *   4. FILE_DATA(3003) × N：64B 前缀（TransferPayload{1:index=块起始偏移, 2:compressType=0,
 *      3:compressSize=n, 4:uncompressSize=n} 编码后补零到 64）+ 数据，12288B/帧
 *   5. daemon → FILE_FINISH(3004) payload=[1]
 *   6. 我方 → FILE_FINISH(3004) payload=[0]
 *   7. daemon → CHANNEL_CLOSE(2)
 * 错误经 CMD_KERNEL_ECHO 回报（首字节 = MessageLevel，其余为文本）。
 */
import { encodeVarint } from './Protocol';
import { utf8ToBytes, concatBytes, bytesToUtf8 } from './Bytes';
import {
  CMD_KERNEL_WAKEUP_SLAVETASK,
  CMD_FILE_CHECK,
  CMD_FILE_BEGIN,
  CMD_FILE_DATA,
  CMD_FILE_FINISH,
  CMD_KERNEL_CHANNEL_CLOSE,
  CMD_KERNEL_ECHO
} from './HdcTypes';
import type { HdcFrame } from './HdcTypes';

/**
 * 块大小：真机探针实测曲线（PC→手机 WiFi，100MB，MD5 全对）：
 *   12288B=34.1 MB/s · 32768B=35.9 MB/s（峰值）· 49152B=27.2 · 57344B=18.8
 * daemon 收大帧没问题，但 ≥48KB 反而变慢（疑撞其 61440 读缓冲边界）。
 * 取峰值 32KB，不再加大。
 */
export const FILE_CHUNK_BYTES: number = 32768;
/**
 * 发送窗口：滑动窗口，窗口满时只等最老一帧，窗口全程保持满。
 * 早期版本是批式（每 8 帧 allSettled 才放下一批），管线每批停一拍、窗口平均半满，
 * loopback 实测 56MB/s；滑动化后由 send promise 延迟与块大小决定上限。
 */
const SEND_WINDOW: number = 16;
/**
 * 进度上报节流：每 8MB 回调一次（156MB 约 20 次）。
 * 早期 2MB 一刷，滑窗提速后 UI 重绘追不上数据（用户实测「进度条跟不上」），
 * 传输已非瓶颈，节流只照顾渲染。小文件仍有「末帧必报」兜底，不会漏 100%。
 */
const PROGRESS_STEP_BYTES: number = 8 * 1024 * 1024;
const PAYLOAD_PREFIX_BYTES: number = 64;

export type FileSender = (payload: Uint8Array, commandFlag: number, channelId: number) => Promise<void>;
export type FileRelease = (channelId: number) => void;
/** 读文件 [offset, offset+maxLen)，返回实际字节；文件读尽返回长度 0 的数组。 */
export type FileChunkReader = (offset: number, maxLen: number) => Promise<Uint8Array>;

function fieldVarint(tag: number, value: number): Uint8Array {
  return concatBytes([encodeVarint((tag << 3) | 0), encodeVarint(value)]);
}

function fieldBytes(tag: number, value: Uint8Array): Uint8Array {
  return concatBytes([encodeVarint((tag << 3) | 2), encodeVarint(value.length), value]);
}

/** protobuf 字段序列（tag<<3|wireType）的 varint，同 tag 可重复出现。 */
function encodeTransferConfig(fileSize: number, remotePath: string, optionalName: string): Uint8Array {
  return concatBytes([
    fieldVarint(1, fileSize),
    fieldBytes(5, utf8ToBytes(remotePath)),
    fieldBytes(6, utf8ToBytes(optionalName)),
    fieldVarint(7, 0),
    fieldVarint(8, 0)
  ]);
}

/** TransferPayload 编码后补零到 64 字节（官方 payloadPrefixReserve）。 */
function encodePayloadPrefix(index: number, size: number): Uint8Array {
  const encoded = concatBytes([
    fieldVarint(1, index),
    fieldVarint(2, 0),
    fieldVarint(3, size),
    fieldVarint(4, size)
  ]);
  const prefix = new Uint8Array(PAYLOAD_PREFIX_BYTES);
  prefix.set(encoded, 0);
  return prefix;
}

export class HdcFileChannel {
  readonly channelId: number;
  private readonly send: FileSender;
  private readonly release: FileRelease;
  private settled: boolean = false;
  private beginReceived: boolean = false;
  private finishReceived: boolean = false;
  private closeReceived: boolean = false;
  private echoError: string | null = null;
  private timer: number = -1;
  /** push() 的失败出口：fail() 可能从超时定时器回调里调，那里不能 throw。 */
  private failReject: ((err: Error) => void) | null = null;

  constructor(channelId: number, send: FileSender, release: FileRelease) {
    this.channelId = channelId;
    this.send = send;
    this.release = release;
  }

  /**
   * 推送整个文件到设备 remotePath。
   * readChunk 由调用方实现（本地 fs / picker URI 流式读），不把大文件整块吃进内存。
   */
  async push(
    fileSize: number,
    remotePath: string,
    optionalName: string,
    readChunk: FileChunkReader,
    onProgress: (sentBytes: number) => void,
    timeoutMs: number = 300000
  ): Promise<void> {
    const failPromise = new Promise<never>((_resolve: (value: never) => void, reject: (err: Error) => void) => {
      this.failReject = reject;
    });
    this.timer = setTimeout(() => {
      // 真断开（对端关连接/报错）由 socket close/error 事件即时失败，不走这里；
      // 这条只兜「假死」（WiFi 静默丢包，TCP 层未断），分钟数按实际超时换算。
      const minutes = Math.max(1, Math.round(timeoutMs / 60000));
      this.fail(new Error(`文件传输超时（超过 ${minutes} 分钟）`));
    }, timeoutMs);
    try {
      await Promise.race([
        this.doPush(fileSize, remotePath, optionalName, readChunk, onProgress),
        failPromise
      ]);
    } finally {
      this.failReject = null;
      if (this.timer >= 0) {
        clearTimeout(this.timer);
        this.timer = -1;
      }
      // doPush 抛错（读文件失败/daemon ECHO 报错）时通道没人清理，会永远留在
      // fileChannels 表里（子代理 review 2026-08-19 揪出）。成功路径 doPush 末尾、
      // 失败路径 fail() 都已置 settled 并 release，这里只兜「race 以 doPush 拒绝
      // 收场」这一条漏网分支，幂等。
      if (!this.settled) {
        this.settled = true;
        this.release(this.channelId);
      }
    }
  }

  private async doPush(
    fileSize: number,
    remotePath: string,
    optionalName: string,
    readChunk: FileChunkReader,
    onProgress: (sentBytes: number) => void
  ): Promise<void> {
    await this.send(new Uint8Array(0), CMD_KERNEL_WAKEUP_SLAVETASK, this.channelId);
    await this.send(encodeTransferConfig(fileSize, remotePath, optionalName), CMD_FILE_CHECK, this.channelId);
    await this.waitBegin();
    // 缓冲复用：帧缓冲 = 64B 前缀 + 块数据，整段传输只分配一次；
    // readChunk 读进 scratch 后 set 进帧缓冲 64 偏移处，消灭逐帧 32KB 分配。
    const frameBuf = new Uint8Array(PAYLOAD_PREFIX_BYTES + FILE_CHUNK_BYTES);
    let offset = 0;
    let lastReported = -1;
    const inflight: Promise<void>[] = [];
    let firstFailure: Error | null = null;
    while (offset < fileSize) {
      const n = Math.min(FILE_CHUNK_BYTES, fileSize - offset);
      const chunk = await readChunk(offset, n);
      if (chunk.length === 0) {
        throw new Error(`本地文件提前读尽（${offset}/${fileSize}）`);
      }
      encodePayloadPrefix(offset, chunk.length).forEach((b: number, i: number) => {
        frameBuf[i] = b;
      });
      // 末帧可能不足整块：只取帧缓冲前 64+n
      const payload = offset + chunk.length >= fileSize || chunk.length === FILE_CHUNK_BYTES ?
        frameBuf.subarray(0, PAYLOAD_PREFIX_BYTES + chunk.length) :
        frameBuf.slice(0, PAYLOAD_PREFIX_BYTES + chunk.length);
      if (chunk.length === FILE_CHUNK_BYTES) {
        frameBuf.set(chunk, PAYLOAD_PREFIX_BYTES);
      } else {
        frameBuf.set(chunk.subarray(0, chunk.length), PAYLOAD_PREFIX_BYTES);
      }
      // 滑动窗口：满时只等最老一帧（各帧自带 catch，等待本身不会抛），窗口全程保持满。
      // 批式 allSettled 每批停一拍、窗口平均半满，是 56MB/s 时的残余瓶颈。
      // send 的同步段就完成 buildFrame 拷贝，下一轮覆写帧缓冲不污染在飞数据；
      // 同一线程按调用序写 socket，帧序不变。
      if (inflight.length >= SEND_WINDOW) {
        await inflight.shift();
        if (firstFailure !== null) {
          throw firstFailure;
        }
        // 超时看门狗触发后 doPush 已被 race 抛弃，但这个循环还会继续读完整份文件
        // 才到 waitFinish——这里早点停（settled 只在 fail() 走过后为真）。
        if (this.settled) {
          throw new Error('传输通道已失败');
        }
      }
      inflight.push(
        this.send(payload, CMD_FILE_DATA, this.channelId).catch((err: Error) => {
          if (firstFailure === null) {
            firstFailure = err;
          }
        })
      );
      offset += chunk.length;
      if (offset - lastReported >= PROGRESS_STEP_BYTES || offset >= fileSize) {
        lastReported = offset;
        onProgress(offset);
      }
    }
    if (inflight.length > 0) {
      await Promise.allSettled(inflight);
      if (firstFailure !== null) {
        throw firstFailure;
      }
    }
    await this.waitFinish();
    await this.send(new Uint8Array(1), CMD_FILE_FINISH, this.channelId); // payload=[0]
    await this.waitClose();
    if (!this.settled) {
      this.settled = true;
      this.release(this.channelId);
    }
  }

  /** 路由进来的帧。返回 true 表示该帧属于本通道。 */
  handleFrame(frame: HdcFrame): boolean {
    if (frame.channelId !== this.channelId) {
      return false;
    }
    if (frame.commandFlag === CMD_FILE_BEGIN) {
      this.beginReceived = true;
      return true;
    }
    if (frame.commandFlag === CMD_FILE_FINISH) {
      this.finishReceived = true;
      return true;
    }
    if (frame.commandFlag === CMD_KERNEL_CHANNEL_CLOSE) {
      this.closeReceived = true;
      return true;
    }
    if (frame.commandFlag === CMD_KERNEL_ECHO) {
      // 首字节 = MessageLevel，真机实证（2026-08-18 探针）：0=FAIL（如
      // "Error opening file..."），2=OK（如传输完成的 "FileTransfer finish..." 摘要）。
      // 第一版把所有 ECHO 当错误，导致传输成功摘要被当成失败信息弹给用户。
      const level = frame.payload.length > 0 ? frame.payload[0] : 0;
      if (level === 0) {
        const text = frame.payload.length > 1 ? bytesToUtf8(frame.payload.subarray(1)) : '';
        this.echoError = text.length > 0 ? text : `ECHO level=0`;
      }
      // level 1/2（INFO/OK，含成功摘要）：忽略。
      return true;
    }
    return false;
  }

  private waitBegin(): Promise<void> {
    return this.waitState(() => this.beginReceived, '等 FILE_BEGIN');
  }

  private waitFinish(): Promise<void> {
    return this.waitState(() => this.finishReceived, '等 FILE_FINISH');
  }

  private waitClose(): Promise<void> {
    return this.waitState(() => this.closeReceived, '等 CHANNEL_CLOSE');
  }

  /** 20ms 轮询。echoError 优先（daemon 报错时给出文本）。 */
  private waitState(check: () => boolean, what: string): Promise<void> {
    return new Promise<void>((resolve: () => void, reject: (err: Error) => void) => {
      const tick = (): void => {
        // fail()（超时/断连）已把通道从路由表摘除，标志位从此冻结——不查 settled
        // 的话被 race 抛弃的 doPush 会在这里每 20ms 空转永远（review 2026-08-19）。
        // 这个 reject 只发生在「race 已被真正的错误（超时/断连文本）结算」之后，
        // 会被 race 吞掉，不会顶替用户看到的错误。
        if (this.settled) {
          reject(new Error('传输通道已失败'));
          return;
        }
        if (this.echoError !== null) {
          reject(new Error(this.echoError));
          return;
        }
        if (check()) {
          resolve();
          return;
        }
        setTimeout(tick, 20);
      };
      tick();
    });
  }

  fail(err: Error): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.release(this.channelId);
    if (this.failReject !== null) {
      const reject = this.failReject;
      this.failReject = null;
      reject(err);
    }
  }
}
