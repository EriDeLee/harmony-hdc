/**
 * HDC 交互式 shell 信道。
 * 流程（认证成功后）：
 *   1. 发送 CMD_SHELL_INIT(channelId) → daemon 拉起交互式登录 shell
 *   2. shell 输出以 CMD_KERNEL_ECHO_RAW(channelId) 回传
 *   3. 通过 CMD_SHELL_DATA(channelId, "cmd\n") 写入 stdin
 *   4. 单字节 0x03 表示 Ctrl+C
 *   5. CMD_KERNEL_CHANNEL_CLOSE(channelId) 关闭
 * 依据：developtools_hdc_standard/src/daemon/shell.cpp、daemon.cpp。
 */
import { util } from '@kit.ArkTS';
import { utf8ToBytes } from './Bytes';
import { CMD_KERNEL_CHANNEL_CLOSE, CMD_SHELL_DATA, CMD_SHELL_INIT } from './HdcTypes';
import type { HdcFrame } from './HdcTypes';

export type ShellOutputSink = (text: string) => void;
export type ShellSender = (payload: Uint8Array, commandFlag: number, channelId: number) => Promise<void>;

const CTRL_C: Uint8Array = new Uint8Array([0x03]);

export class HdcShellChannel {
  readonly channelId: number;
  private readonly send: ShellSender;
  private readonly onOutput: ShellOutputSink;
  private readonly decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
  private started: boolean = false;
  private closed: boolean = false;

  constructor(channelId: number, send: ShellSender, onOutput: ShellOutputSink) {
    this.channelId = channelId;
    this.send = send;
    this.onOutput = onOutput;
  }

  /** 拉起交互式 shell。 */
  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    await this.send(new Uint8Array(0), CMD_SHELL_INIT, this.channelId);
  }

  /** 写入一行命令（自动补换行）。 */
  async sendCommand(command: string): Promise<void> {
    const line = command.endsWith('\n') ? command : `${command}\n`;
    await this.send(utf8ToBytes(line), CMD_SHELL_DATA, this.channelId);
  }

  /** 写入原始 stdin 字节。 */
  async sendRaw(data: Uint8Array): Promise<void> {
    await this.send(data, CMD_SHELL_DATA, this.channelId);
  }

  /** 发送 Ctrl+C。 */
  async sendCtrlC(): Promise<void> {
    await this.send(CTRL_C, CMD_SHELL_DATA, this.channelId);
  }

  /** 关闭 shell 信道。 */
  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    await this.send(new Uint8Array([1]), CMD_KERNEL_CHANNEL_CLOSE, this.channelId);
  }

  /** 收到属于本信道的输出帧；流式解码 UTF-8（跨帧多字节安全）。 */
  handleEchoRaw(frame: HdcFrame): void {
    if (frame.payload.length === 0) {
      return;
    }
    const text = this.decoder.decodeToString(frame.payload, { stream: true });
    if (text.length > 0) {
      this.onOutput(text);
    }
  }
}
