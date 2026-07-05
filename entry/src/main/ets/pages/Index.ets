import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { HdcConnection, AuthResult, AuthOutcome, ConnectOptions } from '../hdc/HdcConnection';
import { DEFAULT_VERSION } from '../hdc/HdcTypes';
import { generateKeyPair, HdcKeyPair } from '../hdc/HdcCrypto';
import { hasKeyPair, loadKeyPair, saveKeyPair, clearKeyPair } from '../hdc/HdcKeyStore';
import { HdcShellChannel } from '../hdc/HdcShellChannel';
import {
  loadConnection,
  saveConnection,
  loadBundleSystemMap,
  saveBundleSystemMap
} from '../hdc/HdcSettings';
import { listBundles, clearBundleData, BundleEntry, ListBundlesResult } from '../hdc/BundleManager';

const MAX_LOG_LINES: number = 500;
const MAX_OUTPUT_BUFFER_CHARS: number = 32000;
const MAX_OUTPUT_RENDER_CHARS: number = 16000;
const TERMINAL_FLUSH_DELAY_MS: number = 80;
const TERMINAL_SCROLL_DELAY_MS: number = 16;

type ViewMode = 'logs' | 'tools';

interface PowerModeOption {
  value: number;
  title: string;
}

interface TimeoutParts {
  hours: number;
  minutes: number;
  seconds: number;
}

interface PowerTimeoutState {
  timeoutMs: number | null;
  overrideMs: number | null;
}

const MIN_POWER_MODE: number = 600;
const MAX_POWER_MODE: number = 603;
const TIMEOUT_MIN_MS: number = 1;
const TIMEOUT_MAX_MS: number = 2147483647;
const SECONDS_PER_MINUTE: number = 60;
const SECONDS_PER_HOUR: number = 3600;
const TIMEOUT_MAX_SECONDS: number = Math.floor(TIMEOUT_MAX_MS / 1000);
const TIMEOUT_MAX_HOURS: number = Math.floor(TIMEOUT_MAX_SECONDS / SECONDS_PER_HOUR);
const TIMEOUT_MAX_MINUTES: number = Math.floor(
  (TIMEOUT_MAX_SECONDS - (TIMEOUT_MAX_HOURS * SECONDS_PER_HOUR)) / SECONDS_PER_MINUTE
);
const TIMEOUT_MAX_REMAINDER_SECONDS: number = TIMEOUT_MAX_SECONDS -
  (TIMEOUT_MAX_HOURS * SECONDS_PER_HOUR) -
  (TIMEOUT_MAX_MINUTES * SECONDS_PER_MINUTE);
const POWER_DUMP_COMMAND: string = 'hidumper -s PowerManagerService -a "-s"';
const POWER_COMMAND_EXIT_MARKER: string = '__HDC_TOOLBOX_POWER_EXIT__=';
const POWER_MODES: PowerModeOption[] = [
  { value: 600, title: '普通模式' },
  { value: 601, title: '省电模式' },
  { value: 602, title: '性能模式' },
  { value: 603, title: '超级省电' }
];

function formatPickerNumber(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

function buildPickerOptions(max: number): string[] {
  const options: string[] = [];
  for (let i = 0; i <= max; i += 1) {
    options.push(formatPickerNumber(i));
  }
  return options;
}

const HOUR_OPTIONS: string[] = buildPickerOptions(TIMEOUT_MAX_HOURS);
const MINUTE_OPTIONS: string[] = buildPickerOptions(59);
const SECOND_OPTIONS: string[] = buildPickerOptions(59);
const MAX_HOUR_MINUTE_OPTIONS: string[] = buildPickerOptions(TIMEOUT_MAX_MINUTES);
const MAX_HOUR_MAX_MINUTE_SECOND_OPTIONS: string[] = buildPickerOptions(TIMEOUT_MAX_REMAINDER_SECONDS);

interface BundleItem {
  name: string;
  label: string;
  system: boolean;
  classified: boolean;
  clearable: boolean;
  checked: boolean;
}

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

  // 功能区状态
  @State viewMode: ViewMode = 'logs';
  @State showTerminalPage: boolean = false;
  @State showClearPage: boolean = false;
  @State showPowerPage: boolean = false;
  @State bundles: BundleItem[] = [];
  @State bundlesLoaded: boolean = false;
  @State includeSystem: boolean = false;
  @State toolsBusy: boolean = false;
  @State toolsStatus: string = '尚未加载应用列表';
  @State powerBusy: boolean = false;
  @State powerPageScrolling: boolean = false;
  @State pendingPowerMode: number = 600;
  @State timeoutOverrideActive: boolean = false;
  @State timeoutOverrideMs: number = 0;
  @State timeoutSystemMs: number = 0;
  @State timeoutHours: number = 0;
  @State timeoutMinutes: number = 1;
  @State timeoutSeconds: number = 0;
  @State powerTimeoutSynced: boolean = false;
  @State powerTimeoutSyncing: boolean = false;

  private conn: HdcConnection | null = null;
  private keyPair: HdcKeyPair | null = null;
  private shell: HdcShellChannel | null = null;
  private bundleCache: Map<string, boolean> = new Map();
  private terminalScroller: Scroller = new Scroller();
  private terminalOutputText: string = '';
  private terminalOutputTruncated: boolean = false;
  private terminalFlushPending: boolean = false;
  private terminalScrollPending: boolean = false;
  private terminalStickToBottom: boolean = true;
  private powerScrollToken: number = 0;

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.refreshKeyState();
    this.restoreConnection();
    this.restoreBundleCache();
  }

  onPageShow(): void {
    if (this.showPowerPage && this.connected) {
      this.syncPowerTimeoutState(false);
    }
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

  private async restoreBundleCache(): Promise<void> {
    try {
      this.bundleCache = await loadBundleSystemMap(this.getCtx());
    } catch (err) {
      this.bundleCache = new Map();
    }
  }

  private getCtx(): common.Context {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      throw new Error('无法获取应用上下文');
    }
    return ctx as common.Context;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2000 });
    } catch (err) {
      this.appendLog(`[ui] toast failed: ${(err as BusinessError).message ?? `${err}`}`);
    }
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
        this.resetTerminalOutput();
        this.shell = await conn.openShell((text: string) => {
          this.appendTerminalOutput(text);
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
    this.viewMode = 'logs';
    this.showTerminalPage = false;
    this.showClearPage = false;
    this.showPowerPage = false;
    this.bundles = [];
    this.bundlesLoaded = false;
    this.toolsStatus = '尚未加载应用列表';
    this.powerTimeoutSynced = false;
    this.powerTimeoutSyncing = false;
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
      this.terminalStickToBottom = true;
      this.flushTerminalOutput();
    } catch (err) {
      this.appendLog(`[shell] 发送失败: ${(err as BusinessError).message}`);
    }
  }

  private resetTerminalOutput(): void {
    this.terminalOutputText = '';
    this.terminalOutputTruncated = false;
    this.terminalFlushPending = false;
    this.terminalScrollPending = false;
    this.terminalStickToBottom = true;
    this.outputText = '';
  }

  private appendTerminalOutput(text: string): void {
    if (text.length === 0) {
      return;
    }
    if (text.length >= MAX_OUTPUT_BUFFER_CHARS) {
      this.terminalOutputText = text.slice(text.length - MAX_OUTPUT_BUFFER_CHARS);
      this.terminalOutputTruncated = true;
    } else {
      const maxPreviousLength = MAX_OUTPUT_BUFFER_CHARS - text.length;
      if (this.terminalOutputText.length > maxPreviousLength) {
        const previousTail = this.terminalOutputText.slice(this.terminalOutputText.length - maxPreviousLength);
        this.terminalOutputText = previousTail + text;
        this.terminalOutputTruncated = true;
      } else {
        this.terminalOutputText += text;
      }
    }
    if (this.showTerminalPage && this.terminalStickToBottom) {
      this.scheduleTerminalOutputFlush();
    }
  }

  private scheduleTerminalOutputFlush(): void {
    if (this.terminalFlushPending) {
      return;
    }
    this.terminalFlushPending = true;
    setTimeout(() => {
      this.terminalFlushPending = false;
      this.flushTerminalOutput();
    }, TERMINAL_FLUSH_DELAY_MS);
  }

  private flushTerminalOutput(): void {
    if (!this.showTerminalPage || !this.terminalStickToBottom) {
      return;
    }
    let text = this.terminalOutputText;
    const renderTruncated = text.length > MAX_OUTPUT_RENDER_CHARS;
    if (renderTruncated) {
      text = text.slice(text.length - MAX_OUTPUT_RENDER_CHARS);
    }
    const rendered = (this.terminalOutputTruncated || renderTruncated) ?
      `（输出过长，已仅显示最近内容）\n${text}` :
      text;
    if (this.outputText !== rendered) {
      this.outputText = rendered;
    }
    this.scrollTerminalToBottomIfNeeded();
  }

  private scrollTerminalToBottomIfNeeded(): void {
    if (this.terminalStickToBottom) {
      this.scrollTerminalToBottom();
    }
  }

  private scrollTerminalToBottom(): void {
    if (!this.showTerminalPage || this.terminalScrollPending) {
      return;
    }
    this.terminalScrollPending = true;
    setTimeout(() => {
      try {
        this.terminalScroller.scrollEdge(Edge.Bottom);
      } catch (err) {
        // Scroll may not be mounted yet when output arrives during page transitions.
      } finally {
        this.terminalScrollPending = false;
      }
    }, TERMINAL_SCROLL_DELAY_MS);
  }

  private async onCtrlC(): Promise<void> {
    if (this.shell !== null) {
      await this.shell.sendCtrlC();
    }
  }

  // ---------- 功能区 ----------

  private openToolsPage(): void {
    if (!this.connected) {
      this.toast('请先连接设备');
      return;
    }
    this.viewMode = 'tools';
  }

  private openTerminalPage(): void {
    if (!this.connected) {
      this.toast('请先连接设备');
      return;
    }
    this.showClearPage = false;
    this.showPowerPage = false;
    this.showTerminalPage = true;
    this.terminalStickToBottom = true;
    this.flushTerminalOutput();
  }

  private closeTerminalPage(): void {
    this.showTerminalPage = false;
  }

  private openClearPage(): void {
    if (!this.connected) {
      this.toast('请先连接设备');
      return;
    }
    this.showTerminalPage = false;
    this.showPowerPage = false;
    this.showClearPage = true;
    if (!this.bundlesLoaded && !this.toolsBusy) {
      this.onRefreshBundles();
    }
  }

  private closeClearPage(): void {
    this.showClearPage = false;
  }

  private openPowerPage(): void {
    if (!this.connected) {
      this.toast('请先连接设备');
      return;
    }
    this.showTerminalPage = false;
    this.showClearPage = false;
    this.showPowerPage = true;
    this.powerPageScrolling = false;
    this.powerTimeoutSynced = false;
    this.powerTimeoutSyncing = false;
    this.syncPowerTimeoutState(true);
  }

  private closePowerPage(): void {
    this.showPowerPage = false;
    this.powerPageScrolling = false;
  }

  private clampPowerMode(value: number): number {
    const rounded = Math.round(value);
    if (rounded < MIN_POWER_MODE) {
      return MIN_POWER_MODE;
    }
    if (rounded > MAX_POWER_MODE) {
      return MAX_POWER_MODE;
    }
    return rounded;
  }

  private powerModeInfo(mode: number): PowerModeOption {
    const safeMode = this.clampPowerMode(mode);
    const found = POWER_MODES.find((item: PowerModeOption) => item.value === safeMode);
    if (found !== undefined) {
      return found;
    }
    return POWER_MODES[0];
  }

  private setPendingPowerMode(value: number): void {
    this.pendingPowerMode = this.clampPowerMode(value);
  }

  private markPowerPageScrolling(source: ScrollSource): void {
    if (source !== ScrollSource.DRAG && source !== ScrollSource.FLING &&
      source !== ScrollSource.OTHER_USER_INPUT && source !== ScrollSource.SCROLL_BAR &&
      source !== ScrollSource.SCROLL_BAR_FLING) {
      return;
    }
    this.powerPageScrolling = true;
    this.powerScrollToken += 1;
    const token = this.powerScrollToken;
    setTimeout(() => {
      if (this.powerScrollToken === token) {
        this.powerPageScrolling = false;
      }
    }, 220);
  }

  private onPowerModeSliderChange(value: number, mode: SliderChangeMode): void {
    if (this.powerBusy || this.powerPageScrolling) {
      return;
    }
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.setPendingPowerMode(value);
    }
  }

  private async executeCheckedPowerCommand(command: string, timeoutMs: number): Promise<string> {
    if (this.conn === null) {
      throw new Error('未连接');
    }
    const wrappedCommand = `${command}; code=$?; printf '\n${POWER_COMMAND_EXIT_MARKER}%s\n' "$code"`;
    const output = await this.conn.executeCommand(wrappedCommand, timeoutMs);
    const markerIndex = output.lastIndexOf(`\n${POWER_COMMAND_EXIT_MARKER}`);
    if (markerIndex < 0) {
      throw new Error(`命令结果缺少退出码: ${output.trim()}`);
    }
    const commandOutput = output.substring(0, markerIndex).trim();
    const exitText = output.substring(markerIndex + POWER_COMMAND_EXIT_MARKER.length + 1).trim().split('\n')[0];
    const exitCode = Number.parseInt(exitText, 10);
    if (Number.isNaN(exitCode)) {
      throw new Error(`命令退出码无效: ${exitText}`);
    }
    if (exitCode !== 0) {
      const message = commandOutput.length > 0 ? commandOutput : `${command} exit=${exitCode}`;
      throw new Error(message);
    }
    return commandOutput;
  }

  private async runPowerCommand(command: string, successMessage: string, timeoutMs: number = 10000): Promise<void> {
    if (!this.connected || this.conn === null) {
      this.toast('请先连接设备');
      return;
    }
    if (this.powerBusy) {
      return;
    }
    this.powerBusy = true;
    try {
      const detail = await this.executeCheckedPowerCommand(command, timeoutMs);
      this.appendLog(`[power] ${command}: ${detail.length > 0 ? detail : 'done'}`);
      this.toast(successMessage);
    } catch (err) {
      const msg = (err as BusinessError).message ?? `${err}`;
      this.appendLog(`[power] ${command} 失败: ${msg}`);
      this.toast('电源命令执行失败');
    } finally {
      this.powerBusy = false;
    }
  }

  private async onSuspendScreen(): Promise<void> {
    await this.runPowerCommand('power-shell suspend', '已发送熄屏命令');
  }

  private async onApplyPowerMode(): Promise<void> {
    const mode = this.clampPowerMode(this.pendingPowerMode);
    await this.runPowerCommand(`power-shell setmode ${mode}`, `已应用${this.powerModeInfo(mode).title}`);
  }

  private timeoutTotalSeconds(): number {
    const hours = Math.max(0, Math.round(this.timeoutHours));
    const minutes = Math.max(0, Math.round(this.timeoutMinutes));
    const seconds = Math.max(0, Math.round(this.timeoutSeconds));
    return (hours * SECONDS_PER_HOUR) + (minutes * SECONDS_PER_MINUTE) + seconds;
  }

  private timeoutMillis(): number {
    const totalSeconds = this.timeoutTotalSeconds();
    if (totalSeconds >= TIMEOUT_MAX_SECONDS) {
      return TIMEOUT_MAX_MS;
    }
    const millis = totalSeconds * 1000;
    if (millis < TIMEOUT_MIN_MS) {
      return TIMEOUT_MIN_MS;
    }
    if (millis > TIMEOUT_MAX_MS) {
      return TIMEOUT_MAX_MS;
    }
    return millis;
  }

  private timeoutPartsFromSeconds(totalSeconds: number): TimeoutParts {
    const safeSeconds = Math.min(Math.max(0, Math.round(totalSeconds)), TIMEOUT_MAX_SECONDS);
    const hours = Math.floor(safeSeconds / SECONDS_PER_HOUR);
    const minuteRemainder = safeSeconds - (hours * SECONDS_PER_HOUR);
    const minutes = Math.floor(minuteRemainder / SECONDS_PER_MINUTE);
    const seconds = minuteRemainder - (minutes * SECONDS_PER_MINUTE);
    return { hours, minutes, seconds };
  }

  private setTimeoutFromSeconds(totalSeconds: number): void {
    const parts = this.timeoutPartsFromSeconds(totalSeconds);
    this.timeoutHours = parts.hours;
    this.timeoutMinutes = parts.minutes;
    this.timeoutSeconds = parts.seconds;
  }

  private setTimeoutParts(hours: number, minutes: number, seconds: number): void {
    const totalSeconds = (Math.max(0, Math.round(hours)) * SECONDS_PER_HOUR) +
      (Math.max(0, Math.round(minutes)) * SECONDS_PER_MINUTE) +
      Math.max(0, Math.round(seconds));
    this.setTimeoutFromSeconds(totalSeconds);
  }

  private normalizeTimeoutParts(): void {
    this.setTimeoutParts(this.timeoutHours, this.timeoutMinutes, this.timeoutSeconds);
  }

  private timeoutMinuteOptions(): string[] {
    return this.timeoutHours >= TIMEOUT_MAX_HOURS ? MAX_HOUR_MINUTE_OPTIONS : MINUTE_OPTIONS;
  }

  private timeoutSecondOptions(): string[] {
    if (this.timeoutHours >= TIMEOUT_MAX_HOURS && this.timeoutMinutes >= TIMEOUT_MAX_MINUTES) {
      return MAX_HOUR_MAX_MINUTE_SECOND_OPTIONS;
    }
    return SECOND_OPTIONS;
  }

  private timeoutMinuteMax(): number {
    return this.timeoutHours >= TIMEOUT_MAX_HOURS ? TIMEOUT_MAX_MINUTES : 59;
  }

  private timeoutSecondMax(): number {
    if (this.timeoutHours >= TIMEOUT_MAX_HOURS && this.timeoutMinutes >= TIMEOUT_MAX_MINUTES) {
      return TIMEOUT_MAX_REMAINDER_SECONDS;
    }
    return 59;
  }

  private timeoutSummary(): string {
    const millis = this.timeoutMillis();
    if (millis === TIMEOUT_MIN_MS) {
      return '最小值 1 毫秒';
    }
    return `${this.timeoutHours} 时 ${this.timeoutMinutes} 分 ${this.timeoutSeconds} 秒（${millis} 毫秒）`;
  }

  private pickerIndex(index: number | number[]): number {
    if (Array.isArray(index)) {
      return index.length > 0 ? index[0] : 0;
    }
    return index;
  }

  private timeoutCommandPreview(): string {
    if (this.timeoutOverrideActive) {
      return 'power-shell timeout -r';
    }
    return `power-shell timeout -o ${this.timeoutMillis()}`;
  }

  private timeoutApplyButtonText(): string {
    if (this.powerBusy) {
      return '执行中...';
    }
    if (!this.powerTimeoutSynced) {
      return this.powerTimeoutSyncing ? '同步中...' : '等待同步';
    }
    if (this.timeoutOverrideActive) {
      return '恢复系统屏幕超时';
    }
    return '应用';
  }

  private timeoutControlsEnabled(): boolean {
    return this.connected && !this.powerBusy && this.powerTimeoutSynced;
  }

  private parsePowerTimeoutNumber(output: string, regex: RegExp): number | null {
    const match = output.match(regex);
    if (match === null || match.length < 2) {
      return null;
    }
    const value = Number.parseInt(match[1], 10);
    if (Number.isNaN(value)) {
      return null;
    }
    return value;
  }

  private parsePowerTimeoutState(output: string): PowerTimeoutState {
    return {
      timeoutMs: this.parsePowerTimeoutNumber(output, /ScreenOffTime:[^\n\r]*?\bTimeout\s*=\s*(\d+)ms/i),
      overrideMs: this.parsePowerTimeoutNumber(output, /OverrideTimeout\s*=\s*(\d+)ms/i)
    };
  }

  private setTimeoutFromMillis(millis: number): void {
    if (millis <= TIMEOUT_MIN_MS) {
      this.setTimeoutFromSeconds(0);
      return;
    }
    this.setTimeoutFromSeconds(Math.round(millis / 1000));
  }

  private timeoutPickerValue(value: number, max: number): number {
    const rounded = Math.round(value);
    if (rounded < 0) {
      return 0;
    }
    if (rounded > max) {
      return max;
    }
    return rounded;
  }

  private applyPowerTimeoutState(state: PowerTimeoutState, updatePicker: boolean): void {
    this.timeoutOverrideActive = state.overrideMs !== null;
    this.timeoutOverrideMs = state.overrideMs ?? 0;
    if (state.timeoutMs !== null) {
      this.timeoutSystemMs = state.timeoutMs;
      if (updatePicker) {
        this.setTimeoutFromMillis(state.timeoutMs);
        this.appendLog(`[power] 已用系统 Timeout 初始化滚轮: ${this.timeoutHours}h ${this.timeoutMinutes}m ${this.timeoutSeconds}s`);
      }
    }
  }

  private async readPowerTimeoutState(): Promise<PowerTimeoutState> {
    if (this.conn === null) {
      throw new Error('未连接');
    }
    const dump = await this.conn.executeCommand(POWER_DUMP_COMMAND, 12000);
    const state = this.parsePowerTimeoutState(dump);
    this.appendLog(`[power] hidumper Timeout=${state.timeoutMs === null ? '<empty>' : `${state.timeoutMs}ms`} ` +
      `OverrideTimeout=${state.overrideMs === null ? '<empty>' : `${state.overrideMs}ms`}`);
    return state;
  }

  private async syncPowerTimeoutState(updatePicker: boolean): Promise<void> {
    if (!this.connected || this.conn === null || this.powerBusy) {
      return;
    }
    if (updatePicker) {
      this.powerTimeoutSynced = false;
      this.powerTimeoutSyncing = true;
    }
    try {
      const state = await this.readPowerTimeoutState();
      this.applyPowerTimeoutState(state, updatePicker);
      if (updatePicker) {
        this.powerTimeoutSynced = true;
      }
    } catch (err) {
      if (updatePicker) {
        this.powerTimeoutSynced = false;
      }
      this.appendLog(`[power] 同步屏幕超时状态失败: ${(err as BusinessError).message ?? `${err}`}`);
    } finally {
      if (updatePicker) {
        this.powerTimeoutSyncing = false;
      }
    }
  }

  private async onApplyTimeout(): Promise<void> {
    if (!this.connected || this.conn === null) {
      this.toast('请先连接设备');
      return;
    }
    if (this.powerBusy) {
      return;
    }
    this.powerBusy = true;
    try {
      const current = await this.readPowerTimeoutState();
      this.applyPowerTimeoutState(current, false);

      if (this.timeoutOverrideActive) {
        const command = 'power-shell timeout -r';
        await this.conn.executeCommand(command, 10000);
        const restored = await this.readPowerTimeoutState();
        if (restored.overrideMs !== null) {
          throw new Error(`OverrideTimeout 仍为 ${restored.overrideMs}ms`);
        }
        this.applyPowerTimeoutState(restored, false);
        this.appendLog(`[power] ${command}: OverrideTimeout cleared`);
        this.toast('已恢复系统屏幕超时');
        return;
      }

      this.normalizeTimeoutParts();
      const millis = this.timeoutMillis();
      const command = `power-shell timeout -o ${millis}`;
      await this.conn.executeCommand(command, 10000);
      const updated = await this.readPowerTimeoutState();
      if (updated.overrideMs !== millis) {
        throw new Error(`OverrideTimeout=${updated.overrideMs === null ? '<empty>' : `${updated.overrideMs}ms`}`);
      }
      this.applyPowerTimeoutState(updated, false);
      this.appendLog(`[power] ${command}: verified OverrideTimeout=${millis}ms`);
      this.toast(`成功应用 ${millis}ms 屏幕超时`);
    } catch (err) {
      const msg = (err as BusinessError).message ?? `${err}`;
      this.appendLog(`[power] ${this.timeoutCommandPreview()} 校验失败: ${msg}`);
      this.toast('屏幕超时设置校验失败');
    } finally {
      this.powerBusy = false;
    }
  }

  onBackPress(): boolean {
    if (this.showTerminalPage) {
      this.closeTerminalPage();
      return true;
    }
    if (this.showClearPage) {
      this.closeClearPage();
      return true;
    }
    if (this.showPowerPage) {
      this.closePowerPage();
      return true;
    }
    return false;
  }

  /** 当前筛选条件下展示的应用列表。 */
  private displayBundles(): BundleItem[] {
    if (this.includeSystem) {
      return this.bundles;
    }
    return this.bundles.filter((b: BundleItem) => !b.system);
  }

  private selectedCount(): number {
    return this.displayBundles().filter((b: BundleItem) => b.checked).length;
  }

  private setChecked(name: string, checked: boolean): void {
    this.bundles = this.bundles.map((b: BundleItem): BundleItem => {
      if (b.name === name) {
        return {
          name: b.name,
          label: b.label,
          system: b.system,
          classified: b.classified,
          clearable: b.clearable,
          checked: b.clearable ? checked : false
        };
      }
      return b;
    });
  }

  private setAllChecked(checked: boolean): void {
    const visible = new Set<string>(this.displayBundles().map((b: BundleItem) => b.name));
    this.bundles = this.bundles.map((b: BundleItem): BundleItem => {
      if (visible.has(b.name)) {
        return {
          name: b.name,
          label: b.label,
          system: b.system,
          classified: b.classified,
          clearable: b.clearable,
          checked: b.clearable ? checked : false
        };
      }
      return b;
    });
  }

  private clearSelection(): void {
    this.bundles = this.bundles.map((b: BundleItem): BundleItem => {
      return {
        name: b.name,
        label: b.label,
        system: b.system,
        classified: b.classified,
        clearable: b.clearable,
        checked: false
      };
    });
  }

  private async onRefreshBundles(): Promise<void> {
    if (!this.connected || this.conn === null || this.toolsBusy) {
      return;
    }
    this.toolsBusy = true;
    this.toolsStatus = '加载应用列表中...';
    try {
      const result: ListBundlesResult = await listBundles(this.conn, this.bundleCache);
      this.bundleCache = result.systemMap;
      this.bundles = result.entries.map((e: BundleEntry): BundleItem => {
        return {
          name: e.name,
          label: e.label,
          system: e.system,
          classified: e.classified,
          clearable: e.clearable,
          checked: false
        };
      });
      this.bundlesLoaded = true;
      const total = result.entries.length;
      const sysCount = result.entries.filter((e: BundleEntry) => e.classified && e.system).length;
      const otherCount = total - sysCount - result.unknownCount;
      this.toolsStatus = `共 ${total} 个应用（系统 ${sysCount}，其他 ${otherCount}，未知 ${result.unknownCount}）`;
      this.appendLog(`[bm] 已加载 ${total} 个应用`);
      try {
        await saveBundleSystemMap(this.getCtx(), this.bundleCache);
      } catch (err) {
        this.appendLog(`[bm] 缓存保存失败: ${(err as BusinessError).message}`);
      }
    } catch (err) {
      const msg = (err as BusinessError).message ?? `${err}`;
      this.toolsStatus = `加载失败: ${msg}`;
      this.appendLog(`[bm] 加载应用列表失败: ${msg}`);
    } finally {
      this.toolsBusy = false;
    }
  }

  private onClearDataClick(): void {
    if (this.toolsBusy) {
      return;
    }
    const targets = this.displayBundles()
      .filter((b: BundleItem) => b.checked && b.clearable)
      .map((b: BundleItem) => b.name);
    if (targets.length === 0) {
      this.toast('请先选择要清空数据的应用');
      return;
    }
    const preview = targets.length > 8 ?
      `${targets.slice(0, 8).join('\n')}\n... 等 ${targets.length} 个` :
      targets.join('\n');
    this.getUIContext().showAlertDialog({
      title: '确认清空应用数据',
      message: `将清空以下 ${targets.length} 个应用的数据（不可恢复）：\n\n${preview}`,
      autoCancel: false,
      primaryButton: {
        value: '清空',
        fontColor: Color.Red,
        action: () => { this.doClearData(targets); }
      },
      secondaryButton: {
        value: '取消',
        action: () => {}
      }
    });
  }

  private async doClearData(targets: string[]): Promise<void> {
    if (this.conn === null) {
      return;
    }
    this.toolsBusy = true;
    this.toolsStatus = `正在清空 ${targets.length} 个应用...`;
    let ok = 0;
    let fail = 0;
    for (const name of targets) {
      try {
        const out = await clearBundleData(this.conn, name);
        ok += 1;
        this.appendLog(`[bm] clean ${name}: ${out.length > 0 ? out : 'done'}`);
      } catch (err) {
        fail += 1;
        this.appendLog(`[bm] clean ${name} 失败: ${(err as BusinessError).message}`);
      }
    }
    this.clearSelection();
    this.toolsBusy = false;
    this.toolsStatus = `清空完成：成功 ${ok}，失败 ${fail}`;
    this.toast(`清空完成：成功 ${ok}，失败 ${fail}`);
  }

  // ---------- Builders ----------

  @Builder
  fieldRow(label: string, value: string, onChange: (v: string) => void, enabled: boolean, inputType: InputType) {
    Row() {
      Text(label).fontSize(13).width(72).fontColor($r('app.color.text_secondary'));
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

  @Builder
  modeSwitch() {
    Row() {
      Button('日志')
        .layoutWeight(1)
        .type(ButtonType.Normal)
        .backgroundColor(this.viewMode === 'logs' ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.log_background'))
        .fontColor(this.viewMode === 'logs' ? Color.White : $r('app.color.text_primary'))
        .border({
          width: 1,
          color: this.viewMode === 'logs' ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.log_background')
        })
        .borderRadius(8)
        .onClick(() => { this.viewMode = 'logs'; });
      Button('功能')
        .layoutWeight(1)
        .margin({ left: 8 })
        .type(ButtonType.Normal)
        .backgroundColor(this.viewMode === 'tools' ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.log_background'))
        .fontColor(this.viewMode === 'tools' ? Color.White : $r('app.color.text_primary'))
        .border({
          width: 1,
          color: this.viewMode === 'tools' ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.log_background')
        })
        .borderRadius(8)
        .onClick(() => { this.openToolsPage(); });
    }
    .width('100%')
    .margin({ bottom: 8 });
  }

  @Builder
  terminalPanel() {
    Column() {
      Scroll(this.terminalScroller) {
        Text(this.outputText.length > 0 ? this.outputText : '（shell 输出）')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.terminal_text'))
          .width('100%')
          .textAlign(TextAlign.Start);
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor($r('app.color.terminal_background'))
      .scrollBar(BarState.Auto)
      .scrollBarColor('#C7C7CC')
      .scrollBarWidth(6)
      .onWillScroll((_xOffset: number, _yOffset: number, _state: ScrollState, source: ScrollSource) => {
        if (source === ScrollSource.DRAG || source === ScrollSource.FLING ||
          source === ScrollSource.OTHER_USER_INPUT || source === ScrollSource.SCROLL_BAR ||
          source === ScrollSource.SCROLL_BAR_FLING) {
          this.terminalStickToBottom = false;
        }
      })
      .onScrollEdge((side: Edge) => {
        if (side === Edge.Bottom) {
          this.terminalStickToBottom = true;
          if (!this.terminalScrollPending) {
            this.flushTerminalOutput();
          }
        }
      })
      .borderRadius(8)
      .padding(8)
      .align(Alignment.TopStart);

      Row() {
        // 已知问题：命令输入框无法关闭输入法自动大写（实测多种方案均无效）。
        TextInput({ text: this.command, placeholder: '输入 shell 命令' })
          .fontSize(13)
          .fontFamily('monospace')
          .fontColor($r('app.color.terminal_text'))
          .placeholderColor('#8E8E93')
          .caretColor(Color.White)
          .layoutWeight(1)
          .enabled(this.connected)
          .defaultFocus(this.showTerminalPage)
          .type(InputType.Normal)
          .enterKeyType(EnterKeyType.Send)
          .height(40)
          .padding({ left: 10, right: 10 })
          .borderRadius(8)
          .border({ width: 1, color: '#48484A' })
          .backgroundColor('#2C2C2E')
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
      .margin({ top: 8 });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  logPanel() {
    Scroll() {
      Column() {
        ForEach(this.logs, (line: string, index: number) => {
          Text(line)
            .fontSize(10)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .textAlign(TextAlign.Start);
        }, (line: string, index: number) => `${index}:${line}`);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.log_background'))
    .borderRadius(12)
    .padding(10)
    .align(Alignment.TopStart);
  }

  @Builder
  featureList() {
    Column() {
      Row() {
        Column() {
          Text('终端')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('全屏使用交互式 shell')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Text('›')
          .fontSize(22)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .padding(16)
      .borderRadius(12)
      .backgroundColor($r('app.color.log_background'))
      .onClick(() => { this.openTerminalPage(); });

      Row() {
        Column() {
          Text('清空应用数据')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('多选应用，通过 bm 清除其数据')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Text('›')
          .fontSize(22)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .padding(16)
      .borderRadius(12)
      .backgroundColor($r('app.color.log_background'))
      .margin({ top: 10 })
      .onClick(() => { this.openClearPage(); });

      Row() {
        Column() {
          Text('电源控制')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('熄屏、电源挡位与屏幕超时')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Text('›')
          .fontSize(22)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .padding(16)
      .borderRadius(12)
      .backgroundColor($r('app.color.log_background'))
      .margin({ top: 10 })
      .onClick(() => { this.openPowerPage(); });
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  powerSection(title: string, subtitle: string) {
    Column() {
      Text(title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      Text(subtitle)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 4 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 12 });
  }

  @Builder
  powerModeTick(option: PowerModeOption) {
    Column() {
      Text(`${option.value}`)
        .fontSize(12)
        .fontWeight(this.pendingPowerMode === option.value ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.pendingPowerMode === option.value ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.text_secondary'));
      Text(option.title)
        .fontSize(10)
        .fontColor(this.pendingPowerMode === option.value ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 2 });
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  timeoutHourPickerColumn() {
    Column() {
      Text('小时')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 4 });
      TextPicker({ range: HOUR_OPTIONS, selected: $$this.timeoutHours })
        .height(248)
        .width('100%')
        .enabled(this.timeoutControlsEnabled())
        .canLoop(false)
        .selectedIndex(this.timeoutPickerValue(this.timeoutHours, HOUR_OPTIONS.length - 1))
        .defaultPickerItemHeight(56)
        .gradientHeight(56)
        .divider({
          strokeWidth: 0.5,
          color: '#D1D1D6',
          startMargin: 0,
          endMargin: 0
        } as DividerOptions)
        .disappearTextStyle({ color: '#D1D1D6', font: { size: 22, weight: FontWeight.Regular } })
        .textStyle({ color: $r('app.color.text_primary'), font: { size: 28, weight: FontWeight.Regular } })
        .selectedTextStyle({ color: $r('sys.color.ohos_id_color_emphasize'), font: { size: 36, weight: FontWeight.Bold } })
        .onChange((_value: string | string[], index: number | number[]) => {
          if (!this.timeoutControlsEnabled()) {
            return;
          }
          this.setTimeoutParts(this.pickerIndex(index), this.timeoutMinutes, this.timeoutSeconds);
        });
    }
    .layoutWeight(1)
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  timeoutMinutePickerColumn() {
    Column() {
      Text('分钟')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 4 });
      TextPicker({ range: this.timeoutMinuteOptions(), selected: $$this.timeoutMinutes })
        .height(248)
        .width('100%')
        .enabled(this.timeoutControlsEnabled())
        .canLoop(false)
        .selectedIndex(this.timeoutPickerValue(this.timeoutMinutes, this.timeoutMinuteMax()))
        .defaultPickerItemHeight(56)
        .gradientHeight(56)
        .divider({
          strokeWidth: 0.5,
          color: '#D1D1D6',
          startMargin: 0,
          endMargin: 0
        } as DividerOptions)
        .disappearTextStyle({ color: '#D1D1D6', font: { size: 22, weight: FontWeight.Regular } })
        .textStyle({ color: $r('app.color.text_primary'), font: { size: 28, weight: FontWeight.Regular } })
        .selectedTextStyle({ color: $r('sys.color.ohos_id_color_emphasize'), font: { size: 36, weight: FontWeight.Bold } })
        .onChange((_value: string | string[], index: number | number[]) => {
          if (!this.timeoutControlsEnabled()) {
            return;
          }
          this.setTimeoutParts(this.timeoutHours, this.pickerIndex(index), this.timeoutSeconds);
        });
    }
    .layoutWeight(1)
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  timeoutSecondPickerColumn() {
    Column() {
      Text('秒')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 4 });
      TextPicker({ range: this.timeoutSecondOptions(), selected: $$this.timeoutSeconds })
        .height(248)
        .width('100%')
        .enabled(this.timeoutControlsEnabled())
        .canLoop(false)
        .selectedIndex(this.timeoutPickerValue(this.timeoutSeconds, this.timeoutSecondMax()))
        .defaultPickerItemHeight(56)
        .gradientHeight(56)
        .divider({
          strokeWidth: 0.5,
          color: '#D1D1D6',
          startMargin: 0,
          endMargin: 0
        } as DividerOptions)
        .disappearTextStyle({ color: '#D1D1D6', font: { size: 22, weight: FontWeight.Regular } })
        .textStyle({ color: $r('app.color.text_primary'), font: { size: 28, weight: FontWeight.Regular } })
        .selectedTextStyle({ color: $r('sys.color.ohos_id_color_emphasize'), font: { size: 36, weight: FontWeight.Bold } })
        .onChange((_value: string | string[], index: number | number[]) => {
          if (!this.timeoutControlsEnabled()) {
            return;
          }
          this.setTimeoutParts(this.timeoutHours, this.timeoutMinutes, this.pickerIndex(index));
        });
    }
    .layoutWeight(1)
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  powerPage() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.closePowerPage(); });
        Text('电源控制')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.text_primary'));
        Text('返回')
          .fontSize(16)
          .opacity(0);
      }
      .width('100%')
      .padding({ top: 4, bottom: 12 });

      Scroll() {
        Column() {
          Column() {
            this.powerSection('电源挡位', '滑动只选择挡位，点“应用挡位”后才会切换电源计划');
            Text(`${this.powerModeInfo(this.pendingPowerMode).title}（${this.pendingPowerMode}）`)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ bottom: 12 });
            Text(`将执行：power-shell setmode ${this.pendingPowerMode}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ bottom: 12 });
            Slider({ value: this.pendingPowerMode, min: MIN_POWER_MODE, max: MAX_POWER_MODE, step: 1 })
              .enabled(!this.powerBusy && !this.powerPageScrolling)
              .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
              .onChange((value: number, mode: SliderChangeMode) => { this.onPowerModeSliderChange(value, mode); });
            Row() {
              ForEach(POWER_MODES, (option: PowerModeOption) => {
                this.powerModeTick(option);
              }, (option: PowerModeOption) => `${option.value}`);
            }
            .width('100%')
            .margin({ top: 8, bottom: 16 });
            Button(this.powerBusy ? '执行中...' : '应用挡位')
              .width('100%')
              .height(44)
              .enabled(this.connected && !this.powerBusy)
              .onClick(() => { this.onApplyPowerMode(); });
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('app.color.log_background'))
          .margin({ top: 0 });

          Column() {
            this.powerSection('屏幕', '立即发送 power-shell suspend 熄灭屏幕');
            Button('熄屏')
              .width('100%')
              .height(44)
              .backgroundColor(Color.Red)
              .fontColor(Color.White)
              .enabled(this.connected && !this.powerBusy)
              .onClick(() => { this.onSuspendScreen(); });
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('app.color.log_background'))
          .margin({ top: 12 });

          Column() {
            this.powerSection('屏幕超时', '写入一次性 OverrideTimeout；应用后可恢复系统屏幕超时');
            Row() {
              this.timeoutHourPickerColumn();
              Blank().width(8);
              this.timeoutMinutePickerColumn();
              Blank().width(8);
              this.timeoutSecondPickerColumn();
            }
            .width('100%')
            .margin({ top: 12 });

            Text(this.timeoutSummary())
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .margin({ top: 14 });
            Text(`将执行：${this.timeoutCommandPreview()}`)
              .fontSize(12)
              .fontFamily('monospace')
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6, bottom: 12 });

            Button(this.timeoutApplyButtonText())
              .width('100%')
              .height(44)
              .enabled(this.timeoutControlsEnabled())
              .onClick(() => { this.onApplyTimeout(); });
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('app.color.log_background'))
          .margin({ top: 12 });

        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }
      .layoutWeight(1)
      .width('100%')
      .onWillScroll((_xOffset: number, _yOffset: number, _state: ScrollState, source: ScrollSource) => {
        this.markPowerPageScrolling(source);
      });
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 4 })
    .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  terminalPage() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(16)
          .fontColor(Color.White)
          .onClick(() => { this.closeTerminalPage(); });
        Text('终端')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontColor(Color.White);
        Text(this.connected ? '已连接' : '未连接')
          .fontSize(12)
          .fontColor($r('app.color.terminal_text'));
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 18, bottom: 10 })
      .backgroundColor($r('app.color.terminal_background'));

      Column() {
        this.terminalPanel();
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 20 });
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.terminal_background'))
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
  }

  @Builder
  bundleRow(item: BundleItem) {
    Row() {
      Checkbox()
        .select(item.checked)
        .enabled(!this.toolsBusy && item.clearable)
        .onChange((value: boolean) => { this.setChecked(item.name, value); });
      Column() {
        Text(item.label)
          .fontSize(14)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary'));
        Text(item.name)
          .fontSize(11)
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 1 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 8 });
      if (!item.classified || item.system) {
        Text(item.classified ? '系统' : '未知')
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(4)
          .backgroundColor($r('app.color.log_background'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .opacity(item.clearable ? 1 : 0.6)
    .onClick(() => {
      if (item.clearable) {
        this.setChecked(item.name, !item.checked);
      }
    });
  }

  @Builder
  clearDataPage() {
    Column() {
      // 顶部栏
      Row() {
        Text('‹ 返回')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.closeClearPage(); });
        Text('清空应用数据')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.text_primary'));
        // 右侧占位，保持标题居中
        Text('返回')
          .fontSize(16)
          .opacity(0);
      }
      .width('100%')
      .padding({ top: 4, bottom: 12 });

      // 筛选与刷新
      Row() {
        Text('包含系统应用')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'));
        Toggle({ type: ToggleType.Switch, isOn: this.includeSystem })
          .enabled(!this.toolsBusy)
          .onChange((isOn: boolean) => { this.includeSystem = isOn; });
        Blank();
        Button('刷新')
          .fontSize(13)
          .enabled(this.connected && !this.toolsBusy)
          .onClick(() => { this.onRefreshBundles(); });
      }
      .width('100%')
      .margin({ bottom: 6 });

      Row() {
        Text(this.toolsStatus)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`已选 ${this.selectedCount()}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .margin({ bottom: 6 });

      Row() {
        Button('全选')
          .fontSize(13)
          .layoutWeight(1)
          .type(ButtonType.Normal)
          .borderRadius(8)
          .backgroundColor($r('app.color.log_background'))
          .fontColor($r('app.color.text_primary'))
          .enabled(!this.toolsBusy)
          .onClick(() => { this.setAllChecked(true); });
        Button('全不选')
          .fontSize(13)
          .layoutWeight(1)
          .margin({ left: 8 })
          .type(ButtonType.Normal)
          .borderRadius(8)
          .backgroundColor($r('app.color.log_background'))
          .fontColor($r('app.color.text_primary'))
          .enabled(!this.toolsBusy)
          .onClick(() => { this.setAllChecked(false); });
      }
      .width('100%')
      .margin({ bottom: 8 });

      // 应用多选列表
      List({ space: 0 }) {
        ForEach(this.displayBundles(), (item: BundleItem) => {
          ListItem() {
            this.bundleRow(item);
          }
        }, (item: BundleItem) => `${item.name}:${item.checked}`);
      }
      .layoutWeight(1)
      .width('100%')
      .divider({ strokeWidth: 0.5, color: $r('app.color.text_secondary') })
      .backgroundColor($r('app.color.log_background'))
      .borderRadius(12)
      .padding({ left: 12, right: 12 });

      Button(this.toolsBusy ? '处理中...' : `清除应用数据（${this.selectedCount()}）`)
        .width('100%')
        .margin({ top: 12 })
        .backgroundColor(Color.Red)
        .fontColor(Color.White)
        .enabled(this.connected && !this.toolsBusy)
        .onClick(() => { this.onClearDataClick(); });
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 4 })
    .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  mainPage() {
    Column() {
      Text('HDC Toolbox')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: 4 });
      Text(`${this.status} · ${this.keyState}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
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

      this.modeSwitch();

      // 内容区：日志 / 功能
      Column() {
        if (this.viewMode === 'logs') {
          this.logPanel();
        } else {
          this.featureList();
        }
      }
      .layoutWeight(1)
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 4 });
  }

  build() {
    Stack() {
      this.mainPage();
      if (this.showTerminalPage) {
        this.terminalPage();
      }
      if (this.showClearPage) {
        this.clearDataPage();
      }
      if (this.showPowerPage) {
        this.powerPage();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'));
  }
}
