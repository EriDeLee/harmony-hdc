import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { HdcConnection, AuthResult, AuthOutcome, ConnectOptions } from '../hdc/HdcConnection';
import { DEFAULT_VERSION } from '../hdc/HdcTypes';
import { generateKeyPair, HdcKeyPair } from '../hdc/HdcCrypto';
import { hasKeyPair, loadKeyPair, saveKeyPair, clearKeyPair } from '../hdc/HdcKeyStore';
import { HdcShellChannel } from '../hdc/HdcShellChannel';
import { loadConnection, saveConnection } from '../hdc/HdcSettings';

const MAX_LOG_LINES: number = 500;
const MAX_OUTPUT_CHARS: number = 64000;

@Entry
@Component
struct Index {
  @State host: string = '127.0.0.1';
  @State port: string = '37635';
  @State version: string = DEFAULT_VERSION;
  @State hostName: string = 'hdc-toolbox';
  @State status: string = '未连接';
  @State connected: boolean = false;
  @State busy: boolean = false;
  @State keyState: string = '无密钥';
  @State logs: string[] = [];
  @State command: string = '';
  @State outputText: string = '';

  private conn: HdcConnection | null = null;
  private keyPair: HdcKeyPair | null = null;
  private shell: HdcShellChannel | null = null;

  aboutToAppear(): void {
    this.refreshKeyState();
    this.restoreConnection();
  }

  private async restoreConnection(): Promise<void> {
    try {
      const cfg = await loadConnection(this.getCtx());
      if (cfg !== null) {
        this.host = cfg.host;
        this.port = `${cfg.port}`;
      }
    } catch (err) {
      // 忽略：无记录或读取失败时用默认值
    }
  }

  private getCtx(): common.Context {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      throw new Error('无法获取应用上下文');
    }
    return ctx as common.Context;
  }

  private appendLog(line: string): void {
    const next = this.logs.concat([line]);
    this.logs = next.length > MAX_LOG_LINES ? next.slice(next.length - MAX_LOG_LINES) : next;
  }

  private async refreshKeyState(): Promise<void> {
    try {
      const exists = await hasKeyPair(this.getCtx());
      this.keyState = exists ? '已持久化密钥' : '无密钥';
    } catch (err) {
      this.keyState = '密钥状态未知';
    }
  }

  private async ensureKeyPair(): Promise<HdcKeyPair> {
    if (this.keyPair !== null) {
      return this.keyPair;
    }
    try {
      const loaded = await loadKeyPair(this.getCtx());
      if (loaded !== null) {
        this.keyPair = loaded;
        this.appendLog(`[key] 已加载持久化密钥 privLen=${loaded.privatePem.length} pubLen=${loaded.publicPem.length}`);
        return loaded;
      }
    } catch (err) {
      this.appendLog(`[key] 持久化密钥无效，重新生成: ${(err as BusinessError).message}`);
    }
    this.appendLog('[key] 生成新的 RSA-3072 密钥对...');
    const created = await generateKeyPair();
    await saveKeyPair(this.getCtx(), created);
    this.keyPair = created;
    await this.refreshKeyState();
    this.appendLog(`[key] 新密钥已生成并持久化 privLen=${created.privatePem.length} pubLen=${created.publicPem.length}`);
    return created;
  }

  private async onGenerateKey(): Promise<void> {
    this.busy = true;
    try {
      const created = await generateKeyPair();
      await saveKeyPair(this.getCtx(), created);
      this.keyPair = created;
      await this.refreshKeyState();
      this.appendLog('[key] 已重新生成并持久化密钥');
    } catch (err) {
      this.appendLog(`[key] 生成失败: ${(err as BusinessError).message}`);
    } finally {
      this.busy = false;
    }
  }

  private async onClearKey(): Promise<void> {
    try {
      await clearKeyPair(this.getCtx());
      this.keyPair = null;
      await this.refreshKeyState();
      this.appendLog('[key] 已清除持久化密钥');
    } catch (err) {
      this.appendLog(`[key] 清除失败: ${(err as BusinessError).message}`);
    }
  }

  private buildOptions(): ConnectOptions {
    return {
      host: this.host.trim(),
      port: Number.parseInt(this.port.trim(), 10),
      version: this.version.trim(),
      hostName: this.hostName.trim(),
      advertiseEncryptTcp: false,
      timeoutMs: 12000
    };
  }

  private async onConnect(): Promise<void> {
    if (this.busy || this.connected) {
      return;
    }
    this.busy = true;
    this.status = '连接中...';
    const options = this.buildOptions();
    try {
      const keyPair = await this.ensureKeyPair();
      const conn = new HdcConnection((line: string) => this.appendLog(line));
      this.conn = conn;
      await conn.connect(options);
      const outcome: AuthOutcome = await conn.authenticate(options, keyPair);
      this.appendLog(`[auth] ${outcome.result}: ${outcome.message}`);
      if (outcome.result === AuthResult.OK) {
        this.connected = true;
        this.status = `已连接 (sid=${outcome.sessionId})`;
        this.outputText = ''; // 新会话清空终端，避免提示符紧贴旧输出
        this.shell = await conn.openShell((text: string) => {
          const next = this.outputText + text;
          this.outputText = next.length > MAX_OUTPUT_CHARS ? next.slice(next.length - MAX_OUTPUT_CHARS) : next;
        });
        this.appendLog(`[shell] 已打开交互式 shell (channel=${this.shell.channelId})`);
        try {
          await saveConnection(this.getCtx(), options.host, options.port);
        } catch (err) {
          this.appendLog(`[cfg] 保存连接配置失败: ${(err as BusinessError).message}`);
        }
      } else {
        this.status = outcome.message;
        await conn.close();
        this.conn = null;
      }
    } catch (err) {
      const e = err as BusinessError;
      this.appendLog(`[error] ${e.message ?? err}`);
      this.status = '连接失败';
      if (this.conn !== null) {
        await this.conn.close();
        this.conn = null;
      }
    } finally {
      this.busy = false;
    }
  }

  private async onDisconnect(): Promise<void> {
    if (this.shell !== null) {
      try {
        await this.shell.close();
      } catch (err) {
        this.appendLog(`[shell] close err ${(err as BusinessError).message}`);
      }
      this.shell = null;
    }
    if (this.conn !== null) {
      await this.conn.close();
      this.conn = null;
    }
    this.connected = false;
    this.status = '未连接';
    this.appendLog('[tcp] disconnected');
  }

  private async onSendCommand(): Promise<void> {
    if (this.shell === null) {
      return;
    }
    const cmd = this.command;
    this.command = '';
    try {
      await this.shell.sendCommand(cmd);
    } catch (err) {
      this.appendLog(`[shell] 发送失败: ${(err as BusinessError).message}`);
    }
  }

  private async onCtrlC(): Promise<void> {
    if (this.shell !== null) {
      await this.shell.sendCtrlC();
    }
  }

  @Builder
  fieldRow(label: string, value: string, onChange: (v: string) => void, enabled: boolean, inputType: InputType) {
    Row() {
      Text(label).fontSize(13).width(72).fontColor('#8E8E93');
      TextInput({ text: value })
        .fontSize(13)
        .layoutWeight(1)
        .enabled(enabled)
        .type(inputType)
        .onChange(onChange);
    }
    .width('100%')
    .margin({ bottom: 8 });
  }

  build() {
    Column() {
      Text('HDC Toolbox')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .margin({ bottom: 4 });
      Text(`${this.status} · ${this.keyState}`)
        .fontSize(12)
        .fontColor('#8E8E93')
        .width('100%')
        .margin({ bottom: 12 });

      this.fieldRow('Host', this.host, (v: string) => { this.host = v; }, !this.connected, InputType.Normal);
      this.fieldRow('Port', this.port, (v: string) => { this.port = v; }, !this.connected, InputType.Number);
      this.fieldRow('Version', this.version, (v: string) => { this.version = v; }, !this.connected, InputType.Normal);
      this.fieldRow('HostName', this.hostName, (v: string) => { this.hostName = v; }, !this.connected, InputType.Normal);

      Row() {
        Button(this.connected ? '断开' : '连接')
          .layoutWeight(1)
          .enabled(!this.busy)
          .onClick(() => {
            if (this.connected) {
              this.onDisconnect();
            } else {
              this.onConnect();
            }
          });
        Button('生成密钥')
          .layoutWeight(1)
          .margin({ left: 8 })
          .enabled(!this.busy && !this.connected)
          .onClick(() => { this.onGenerateKey(); });
        Button('清除密钥')
          .layoutWeight(1)
          .margin({ left: 8 })
          .enabled(!this.busy && !this.connected)
          .onClick(() => { this.onClearKey(); });
      }
      .width('100%')
      .margin({ top: 4, bottom: 12 });

      // 终端输出
      Scroll() {
        Text(this.outputText.length > 0 ? this.outputText : '（shell 输出）')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor('#E0E0E0')
          .width('100%')
          .textAlign(TextAlign.Start);
      }
      .layoutWeight(2)
      .width('100%')
      .backgroundColor('#1C1C1E')
      .borderRadius(8)
      .padding(8)
      .align(Alignment.TopStart);

      // 命令输入
      Row() {
        // 已知问题：命令输入框无法关闭输入法自动大写（实测多种方案均无效）。
        //  - autoCapitalizationMode(NONE) 在该设备输入法下被忽略，首字母仍自动大写；
        //  - InputType.USER_NAME 同样压不住自动大写，且会拦截空格（shell 命令必须用空格），更不可用；
        // 故回退为 InputType.Normal。自动大写为输入法行为，暂作为已知 bug，由用户手动修正大小写。
        TextInput({ text: this.command, placeholder: '输入 shell 命令' })
          .fontSize(13)
          .fontFamily('monospace')
          .layoutWeight(1)
          .enabled(this.connected)
          .type(InputType.Normal)
          .enterKeyType(EnterKeyType.Send)
          .onChange((v: string) => { this.command = v; })
          .onSubmit(() => { this.onSendCommand(); });
        Button('发送')
          .margin({ left: 8 })
          .enabled(this.connected)
          .onClick(() => { this.onSendCommand(); });
        Button('^C')
          .margin({ left: 8 })
          .enabled(this.connected)
          .onClick(() => { this.onCtrlC(); });
      }
      .width('100%')
      .margin({ top: 8, bottom: 8 });

      // 协议日志
      Scroll() {
        Column() {
          ForEach(this.logs, (line: string, index: number) => {
            Text(line)
              .fontSize(10)
              .fontFamily('monospace')
              .width('100%')
              .textAlign(TextAlign.Start);
          }, (line: string, index: number) => `${index}:${line}`);
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#F2F2F7')
      // 顶角小、底角略大且柔和，不再尖，也不过分
      .borderRadius({ topLeft: 12, topRight: 12, bottomLeft: 18, bottomRight: 18 })
      .padding(10)
      .align(Alignment.TopStart);
    }
    .width('100%')
    .height('100%')
    // 四周留白；底部仅留 4（系统已自动避让手势区），贴近手势条上沿但不进入手势区
    .padding({ left: 16, right: 16, top: 16, bottom: 4 })
    .backgroundColor(Color.White);
  }
}
