/**
 * HDC 一次性命令通道（CMD_UNITY_EXECUTE）。
 *
 * 这是执行工具命令的正统路径：daemon 端会把 payload 当 shell 命令执行，
 * stdout/stderr 以 CMD_KERNEL_ECHO_RAW 按 channelId 回传，任务结束时关闭 channel。
 * 与交互式 shell 完全隔离，不需要哨兵、不处理 prompt，也不会污染终端。
 */
import { util } from '@kit.ArkTS';
import { utf8ToBytes } from './Bytes';
import { CMD_UNITY_EXECUTE } from './HdcTypes';
import type { HdcFrame } from './HdcTypes';

export type UnitySender = (payload: Uint8Array, commandFlag: number, channelId: number) => Promise<void>;
export type UnityRelease = (channelId: number, waitForClose: boolean) => void;

export class HdcUnityCommandChannel {
  readonly channelId: number;
  private readonly send: UnitySender;
  private readonly release: UnityRelease;
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
  private output: string = '';
  private settled: boolean = false;
  private timer: number = -1;
  private resolveFn: ((value: string) => void) | null = null;
  private rejectFn: ((err: Error) => void) | null = null;

  constructor(channelId: number, send: UnitySender, release: UnityRelease) {
    this.channelId = channelId;
    this.send = send;
    this.release = release;
  }

  execute(command: string, timeoutMs: number): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void, reject: (err: Error) => void) => {
      this.resolveFn = resolve;
      this.rejectFn = reject;
      this.timer = setTimeout(() => {
        this.fail(new Error('命令执行超时'));
      }, timeoutMs);
      this.send(utf8ToBytes(command), CMD_UNITY_EXECUTE, this.channelId).catch((err: Error) => {
        this.fail(err);
      });
    });
  }

  handleEchoRaw(frame: HdcFrame): void {
    if (this.settled || frame.payload.length === 0) {
      return;
    }
    const text = this.decoder.decodeToString(frame.payload, { stream: true });
    if (text.length > 0) {
      this.output += text;
    }
  }

  handleClose(): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.cleanup(false);
    if (this.resolveFn !== null) {
      const resolve = this.resolveFn;
      this.resolveFn = null;
      this.rejectFn = null;
      resolve(this.output);
    }
  }

  fail(err: Error): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.cleanup(true);
    if (this.rejectFn !== null) {
      const reject = this.rejectFn;
      this.resolveFn = null;
      this.rejectFn = null;
      reject(err);
    }
  }

  private cleanup(waitForClose: boolean): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.release(this.channelId, waitForClose);
  }
}
