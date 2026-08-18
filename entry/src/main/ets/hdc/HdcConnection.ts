/**
 * HDC 无线调试直连：TCP 连接 + 新版 6 字段握手 + 公钥/签名认证状态机。
 * 认证成功（AUTH_OK 且非 DAEMON_UNAUTH）后，连接可用于后续命令信道。
 */
import { socket } from '@kit.NetworkKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import {
  buildFrame,
  buildInitialBuf,
  parseHandShake,
  serializeHandShake,
  tlvParse,
  tryParseFrame
} from './Protocol';
import { bytesToUtf8, concatBytes, utf8ToBytes } from './Bytes';
import { signToken } from './HdcCrypto';
import type { HdcKeyPair } from './HdcCrypto';
import { HdcShellChannel } from './HdcShellChannel';
import type { ShellOutputSink } from './HdcShellChannel';
import { HdcUnityCommandChannel } from './HdcUnityCommandChannel';
import { HdcFileChannel } from './HdcFileChannel';
import {
  AUTH_ENCRYPT,
  AUTH_NONE,
  AUTH_OK,
  AUTH_PUBLICKEY,
  AUTH_SIGNATURE,
  CMD_KERNEL_CHANNEL_CLOSE,
  CMD_KERNEL_ECHO,
  CMD_KERNEL_ECHO_RAW,
  CMD_KERNEL_HANDSHAKE,
  DEFAULT_VERSION
} from './HdcTypes';
import type { HandShake, HdcFrame } from './HdcTypes';

export enum AuthResult {
  OK = 'OK',
  UNAUTHORIZED = 'UNAUTHORIZED',
  ENCRYPT_REQUIRED = 'ENCRYPT_REQUIRED',
  REJECTED = 'REJECTED',
  ERROR = 'ERROR'
}

export interface ConnectOptions {
  host: string;
  port: number;
  version: string;
  hostName: string;
  advertiseEncryptTcp: boolean;
  timeoutMs: number;
}

/**
 * 一条正在飞的一次性命令。
 * `channelId` 用来在中途掐掉它（见 `abortCommand`），`result` 是命令的结果。
 */
export interface PendingCommand {
  channelId: number;
  result: Promise<string>;
}

export interface AuthOutcome {
  result: AuthResult;
  message: string;
  sessionId: number;
}

export type LogSink = (line: string) => void;
export type FrameSink = (frame: HdcFrame) => void;

function toArrayBuffer(data: Uint8Array): ArrayBuffer {
  return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
}

function randomSessionId(): number {
  return (Math.floor(Math.random() * 0xfffffffe) + 1) >>> 0;
}

export class HdcConnection {
  private tcp: socket.TCPSocket | null = null;
  private recvBuf: Uint8Array = new Uint8Array(0);
  private frameQueue: HdcFrame[] = [];
  private waiter: ((frame: HdcFrame) => void) | null = null;
  private waiterReject: ((err: Error) => void) | null = null;
  private sessionId: number = 0;
  private closed: boolean = false;
  private nextChannelId: number = 1;
  private readonly shellChannels: Map<number, HdcShellChannel> = new Map<number, HdcShellChannel>();
  private readonly unityChannels: Map<number, HdcUnityCommandChannel> = new Map<number, HdcUnityCommandChannel>();
  private readonly fileChannels: Map<number, HdcFileChannel> = new Map<number, HdcFileChannel>();
  private readonly expiredUnityChannels: Set<number> = new Set<number>();
  private readonly loggedUnroutedCmds: Set<number> = new Set<number>();

  private readonly log: LogSink;
  private dataSink: FrameSink | null = null;

  constructor(log: LogSink) {
    this.log = log;
  }

  /** 注册“认证完成后”的数据帧回调（命令信道使用）。 */
  setDataSink(sink: FrameSink | null): void {
    this.dataSink = sink;
  }

  /** 打开一个交互式 shell 信道。 */
  async openShell(onOutput: ShellOutputSink): Promise<HdcShellChannel> {
    const channelId = this.nextChannelId;
    this.nextChannelId += 1;
    const channel = new HdcShellChannel(
      channelId,
      (payload: Uint8Array, commandFlag: number, ch: number) => this.send(payload, commandFlag, ch),
      onOutput
    );
    this.shellChannels.set(channelId, channel);
    await channel.start();
    return channel;
  }

  /**
   * 发一条一次性 shell 命令，并把**通道号**交出来。
   *
   * 存在的理由：调用方需要能在中途掐掉这条命令。`executeCommand` 只返回结果，
   * 拿不到通道号，于是一旦命令飞出去就只能等设备回包或等超时 ——
   * 用户按「停止」最坏要等满整个超时才落地。
   *
   * 只有需要这种能力的调用方才用它（目前是 agent 的动作）。其余照用 executeCommand。
   */
  startCommand(command: string, timeoutMs: number = 30000): PendingCommand {
    const channelId = this.nextChannelId;
    this.nextChannelId += 1;
    const channel = new HdcUnityCommandChannel(
      channelId,
      (payload: Uint8Array, commandFlag: number, ch: number) => this.send(payload, commandFlag, ch),
      (ch: number, waitForClose: boolean) => {
        this.unityChannels.delete(ch);
        if (waitForClose) {
          this.expiredUnityChannels.add(ch);
        } else {
          this.expiredUnityChannels.delete(ch);
        }
      }
    );
    this.unityChannels.set(channelId, channel);
    return { channelId, result: channel.execute(command, timeoutMs) };
  }

  /** 执行一次性 shell 命令（CMD_UNITY_EXECUTE），与交互式 shell 隔离。 */
  async executeCommand(command: string, timeoutMs: number = 30000): Promise<string> {
    return await this.startCommand(command, timeoutMs).result;
  }

  /**
   * 打开一个 FILE 通道（向所连设备推文件）。
   * 帧序列见 HdcFileChannel 头注释；本地/远程设备同一条路（文件由应用读、经协议推送）。
   */
  openFileChannel(): HdcFileChannel {
    const channelId = this.nextChannelId;
    this.nextChannelId += 1;
    const channel = new HdcFileChannel(
      channelId,
      (payload: Uint8Array, commandFlag: number, ch: number) => this.send(payload, commandFlag, ch),
      (ch: number) => { this.fileChannels.delete(ch); }
    );
    this.fileChannels.set(channelId, channel);
    return channel;
  }

  /**
   * 掐掉一条在飞的命令：拒掉它的 promise 并清掉它的超时定时器。
   *
   * **只影响这一个通道。** 一条命令一个通道，所以终端页、电源页、屏幕看守各自的
   * 命令都不受影响 —— 中断是 agent 这个任务的事，不该把别处的命令一起掐掉。
   *
   * 命令已经结束时是空操作（通道里有 settled 保护），所以调用方不必先判断状态。
   *
   * 注意：掐掉的是**我们的等待**，不是**设备上的动作**。已经发出去的滑动、按键
   * 在手机上该走完还是会走完。
   */
  abortCommand(channelId: number, reason: string): boolean {
    const channel = this.unityChannels.get(channelId);
    if (channel === undefined) {
      return false;
    }
    channel.fail(new Error(reason));
    return true;
  }

  getSessionId(): number {
    return this.sessionId;
  }

  isClosed(): boolean {
    return this.closed;
  }

  /** 建立 TCP 连接。 */
  async connect(options: ConnectOptions): Promise<void> {
    const tcp = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    this.closed = false;

    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.onBytes(new Uint8Array(info.message));
    });
    tcp.on('close', () => {
      this.closed = true;
      this.failWaiter(new Error('连接已关闭'));
      this.failUnityChannels(new Error('连接已关闭'));
      this.failFileChannels(new Error('连接已关闭'));
    });
    tcp.on('error', (err: BusinessError) => {
      this.closed = true;
      this.log(`[socket] error code=${err.code} msg=${err.message}`);
      this.failWaiter(new Error(`socket 错误 ${err.code}`));
      this.failUnityChannels(new Error(`socket 错误 ${err.code}`));
      this.failFileChannels(new Error(`socket 错误 ${err.code}`));
    });

    const address: socket.NetAddress = { address: options.host, port: options.port };
    const connectOptions: socket.TCPConnectOptions = { address, timeout: options.timeoutMs };
    await tcp.connect(connectOptions);
    this.log(`[tcp] connected ${options.host}:${options.port}`);
  }

  /** 执行握手 + 认证全流程。 */
  async authenticate(options: ConnectOptions, keyPair: HdcKeyPair): Promise<AuthOutcome> {
    this.sessionId = randomSessionId();
    const connectKey = `${options.host}:${options.port}`;
    const initialBuf = buildInitialBuf(options.advertiseEncryptTcp);

    await this.send(serializeHandShake({
      authType: AUTH_NONE,
      sessionId: this.sessionId,
      connectKey,
      buf: initialBuf,
      version: options.version,
      includeVersion: true
    }), CMD_KERNEL_HANDSHAKE);
    this.log(`[hs] sent initial handshake sid=${this.sessionId} bufLen=${initialBuf.length}`);

    let frame = await this.nextFrame(options.timeoutMs);
    let hs = parseHandShake(frame.payload);
    this.logHandShake('recv#1', hs);
    let version = hs.version.length > 0 ? hs.version : options.version;
    let authType = hs.authType;

    // 公钥认证
    if (authType === AUTH_PUBLICKEY) {
      const info = concatBytes([utf8ToBytes(options.hostName), new Uint8Array([0x0c]), utf8ToBytes(keyPair.publicPem)]);
      await this.send(serializeHandShake({
        authType: AUTH_PUBLICKEY,
        sessionId: this.sessionId,
        connectKey: '',
        buf: info,
        version,
        includeVersion: true
      }), CMD_KERNEL_HANDSHAKE);
      this.log(`[hs] sent public key infoLen=${info.length}（请在设备上确认授权弹窗）`);
      frame = await this.nextFrame(options.timeoutMs);
      hs = parseHandShake(frame.payload);
      this.logHandShake('recv#publickey', hs);
      authType = hs.authType;
      if (hs.version.length > 0) {
        version = hs.version;
      }
    }

    // 签名认证
    if (authType === AUTH_SIGNATURE) {
      const signatureB64 = await signToken(keyPair, hs.buf);
      await this.send(serializeHandShake({
        authType: AUTH_SIGNATURE,
        sessionId: this.sessionId,
        connectKey: '',
        buf: utf8ToBytes(signatureB64),
        version,
        includeVersion: true
      }), CMD_KERNEL_HANDSHAKE);
      this.log(`[hs] sent signature tokenLen=${hs.buf.length} sigB64Len=${signatureB64.length}`);
      frame = await this.nextFrame(options.timeoutMs);
      hs = parseHandShake(frame.payload);
      this.logHandShake('recv#signature', hs);
      authType = hs.authType;
    }

    if (authType === AUTH_ENCRYPT) {
      return { result: AuthResult.ENCRYPT_REQUIRED, message: '设备要求 TLS-PSK 加密信道（暂未实现）', sessionId: this.sessionId };
    }

    if (authType === AUTH_OK) {
      const status = this.daemonAuthStatus(hs);
      if (status === 'DAEMON_UNAUTH') {
        return { result: AuthResult.UNAUTHORIZED, message: '设备未授权该公钥，请在设备上确认弹窗后重试', sessionId: this.sessionId };
      }
      return { result: AuthResult.OK, message: '认证成功', sessionId: this.sessionId };
    }

    return { result: AuthResult.REJECTED, message: `握手被拒绝 authType=${authType} buf=${bytesToUtf8(hs.buf)}`, sessionId: this.sessionId };
  }

  /** 发送一帧（commandFlag 决定类型）。channelId 默认 0。 */
  async send(payload: Uint8Array, commandFlag: number, channelId: number = 0): Promise<void> {
    if (this.tcp === null) {
      throw new Error('未连接');
    }
    const frame = buildFrame(payload, channelId, commandFlag);
    const sendOptions: socket.TCPSendOptions = { data: toArrayBuffer(frame) };
    await this.tcp.send(sendOptions);
  }

  async close(): Promise<void> {
    this.closed = true;
    this.failUnityChannels(new Error('连接已关闭'));
    this.failFileChannels(new Error('连接已关闭'));
    this.expiredUnityChannels.clear();
    if (this.tcp !== null) {
      try {
        await this.tcp.close();
      } catch (err) {
        this.log(`[tcp] close err ${(err as BusinessError).code}`);
      }
      this.tcp = null;
    }
  }

  // ---------- 内部：流式收帧 ----------

  private onBytes(chunk: Uint8Array): void {
    this.recvBuf = concatBytes([this.recvBuf, chunk]);
    while (true) {
      let parsed: ReturnType<typeof tryParseFrame>;
      try {
        parsed = tryParseFrame(this.recvBuf);
      } catch (err) {
        this.log(`[frame] parse error: ${(err as Error).message}`);
        this.recvBuf = new Uint8Array(0);
        this.failWaiter(err as Error);
        return;
      }
      if (parsed === null) {
        return;
      }
      this.recvBuf = this.recvBuf.slice(parsed.consumed);
      this.deliverFrame(parsed.frame);
    }
  }

  private deliverFrame(frame: HdcFrame): void {
    // 握手帧交给等待者
    if (frame.commandFlag === CMD_KERNEL_HANDSHAKE) {
      if (this.waiter !== null) {
        const resolve = this.waiter;
        this.waiter = null;
        this.waiterReject = null;
        resolve(frame);
      } else {
        this.frameQueue.push(frame);
      }
      return;
    }
    // shell 输出：按 channelId 路由；不匹配时仅在“唯一 shell”情况下回退。
    // 多 shell 时盲目丢给第一个 channel 会导致工具命令输出被主终端吞掉。
    if (frame.commandFlag === CMD_KERNEL_ECHO_RAW || frame.commandFlag === CMD_KERNEL_ECHO) {
      const fileChannel = this.fileChannels.get(frame.channelId);
      if (fileChannel !== undefined) {
        fileChannel.handleFrame(frame);
        return;
      }
      const unityChannel = this.unityChannels.get(frame.channelId);
      if (unityChannel !== undefined) {
        unityChannel.handleEchoRaw(frame);
        return;
      }
      if (this.expiredUnityChannels.has(frame.channelId)) {
        return;
      }
      const channel = this.shellChannels.get(frame.channelId) ??
        (frame.channelId === 0 ? this.singleShellChannel() : undefined);
      if (channel !== undefined) {
        channel.handleEchoRaw(frame);
        return;
      }
    }
    if (frame.commandFlag === CMD_KERNEL_CHANNEL_CLOSE) {
      const fileChannel = this.fileChannels.get(frame.channelId);
      if (fileChannel !== undefined) {
        fileChannel.handleFrame(frame);
        return;
      }
      const unityChannel = this.unityChannels.get(frame.channelId);
      if (unityChannel !== undefined) {
        unityChannel.handleClose();
        return;
      }
      if (this.expiredUnityChannels.delete(frame.channelId)) {
        this.log(`[unity] channel ${frame.channelId} closed after timeout`);
        return;
      }
      this.shellChannels.delete(frame.channelId);
      this.log(`[shell] channel ${frame.channelId} closed by daemon`);
      return;
    }
    // FILE 通道的任务帧（BEGIN/FINISH 等）：交给对应通道，没有则按未知帧处理
    const fileTaskChannel = this.fileChannels.get(frame.channelId);
    if (fileTaskChannel !== undefined && fileTaskChannel.handleFrame(frame)) {
      return;
    }
    if (this.dataSink !== null) {
      this.dataSink(frame);
      return;
    }
    // 其它帧（如 heartbeat）静默忽略，每种命令只记一次，避免刷屏
    if (!this.loggedUnroutedCmds.has(frame.commandFlag)) {
      this.loggedUnroutedCmds.add(frame.commandFlag);
      this.log(`[frame] 忽略 cmd=${frame.commandFlag} ch=${frame.channelId} len=${frame.payload.length}（后续同类不再提示）`);
    }
  }

  private singleShellChannel(): HdcShellChannel | undefined {    if (this.shellChannels.size !== 1) {
      return undefined;
    }
    for (const channel of this.shellChannels.values()) {
      return channel;
    }
    return undefined;
  }

  private nextFrame(timeoutMs: number): Promise<HdcFrame> {
    const queued = this.frameQueue.shift();
    if (queued !== undefined) {
      return Promise.resolve(queued);
    }
    return new Promise<HdcFrame>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.waiter !== null) {
          this.waiter = null;
          this.waiterReject = null;
          reject(new Error('等待响应超时'));
        }
      }, timeoutMs);
      this.waiter = (frame: HdcFrame): void => {
        clearTimeout(timer);
        resolve(frame);
      };
      this.waiterReject = (err: Error): void => {
        clearTimeout(timer);
        reject(err);
      };
    });
  }

  private failWaiter(err: Error): void {
    if (this.waiterReject !== null) {
      const reject = this.waiterReject;
      this.waiter = null;
      this.waiterReject = null;
      reject(err);
    }
  }

  private failUnityChannels(err: Error): void {
    const channels: HdcUnityCommandChannel[] = [];
    this.unityChannels.forEach((channel: HdcUnityCommandChannel) => {
      channels.push(channel);
    });
    for (const channel of channels) {
      channel.fail(err);
    }
  }

  private failFileChannels(err: Error): void {
    const channels: HdcFileChannel[] = [];
    this.fileChannels.forEach((channel: HdcFileChannel) => {
      channels.push(channel);
    });
    this.fileChannels.clear();
    for (const channel of channels) {
      channel.fail(err);
    }
  }

  private daemonAuthStatus(hs: HandShake): string {
    const tlv = tlvParse(hs.buf);
    const status = tlv.get('daemonauthstatus');
    return status === undefined ? '' : bytesToUtf8(status);
  }

  private logHandShake(label: string, hs: HandShake): void {
    this.log(`[hs] ${label}: authType=${hs.authType} sid=${hs.sessionId} version=${hs.version} bufLen=${hs.buf.length}`);
    const tlv = tlvParse(hs.buf);
    if (tlv.size > 0) {
      const parts: string[] = [];
      tlv.forEach((value: Uint8Array, key: string) => {
        parts.push(`${key}=${bytesToUtf8(value)}`);
      });
      this.log(`[hs] ${label} TLV: ${parts.join(' | ')}`);
    }
  }
}

export { DEFAULT_VERSION };
