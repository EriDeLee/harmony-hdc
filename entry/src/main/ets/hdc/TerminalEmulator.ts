/**
 * 行式终端模拟器：把交互式 shell 通道的原始回显字节流变成「该在屏幕上看到的样子」。
 * 宽度可配；应用侧配 TERMINAL_COLUMNS(200) 并在连接时向 shell 下发同值 COLUMNS，
 * 两处必须一致（见 pages/Index.ets 的 TERMINAL_COLUMNS 注释）。
 *
 * 为什么必须有它（2026-08-18 真机实测）：
 * daemon 开 PTY 时从不设置 winsize（shell.cpp 只有 openpty，没有 TIOCSWINSZ），
 * 内核默认 0x0，mksh 行编辑器对 0 宽回退 80 列。命令超过列宽时 mksh 不换行，
 * 而是**横向滚动**：发 `\r` 回行首，重画当前可见窗口并补位空格，尾随 `<` 滚动标记
 * （真机实测标记打在行尾）。被滚出窗口的前缀 mksh 不会重发，任何模拟器都救不回来——
 * 所以真正的修法是连接时设 `COLUMNS=200` 让行编辑器不滚（Index.ets onConnect），
 * 本类只负责消化剩余的控制码（\r 重画、补位、CSI 行编辑序列）。
 * 终端页此前把每个字节都当文字拼接（appendTerminalOutput 直接 +=），重画序列全部显形，
 * 长命令的回显变成「phone-defaultage/media/...」这样的碎片拼接。
 *
 * 模型（有意从简，够用为止）：
 * - 只有**一条活动行** + 已定稿的回滚行列表。多行光标寻址（vim/top 那类全屏程序）
 *   不支持——本终端是给命令行用的，这不是目标。
 * - 换行采用 xterm 的**延迟回卷**：写到第 80 列后不立即换行，等下一个可打印字符
 *   才落行。否则正好填满一行再接 `\r\n` 的输出会多出一个空行。
 * - CSI 只实现行内编辑会用到的子集：EL(K) 行内擦除、ED(J) 清屏、
 *   D/C/G 光标移动、P/@/X 字符删除/插入/擦除。颜色(m)、模式(h/l) 等一律吞掉。
 * - `ED 2`（clear 命令发的）连回滚区一起清掉。真终端只清可见屏不清回滚，
 *   这里没有「可见屏 vs 回滚」之分，全清最接近用户预期。
 * - 制表符按 8 列停靠位补空格，但**只补洞、不覆盖**已有字符（真终端的 tab 不擦字）。
 *
 * 验证：scripts/tests/terminal-emu-test.js 是本文件的镜像实现 + 断言，
 * 两处必须一起改（ArkTS 不能直接在 Node 里跑，与 launcher-entry-test 同一套办法）。
 */

// 解析器状态：正常 / 收到 ESC / CSI 参数中 / OSC 标题中 / OSC 里见到 ESC（等 ST 的 \）
const STATE_NORMAL: number = 0;
const STATE_ESC: number = 1;
const STATE_CSI: number = 2;
const STATE_OSC: number = 3;
const STATE_OSC_ESC: number = 4;

const CR: number = 13;
const LF: number = 10;
const BS: number = 8;
const TAB: number = 9;
const BEL: number = 7;
const ESC: number = 27;
const VT: number = 11;
const FF: number = 12;

export class TerminalEmulator {
  private readonly width: number;
  private readonly maxBufferChars: number;

  /** 已定稿的行（回滚区）。 */
  private lines: string[] = [];
  /** 活动行：还在被回显/重画修改的最后一行。 */
  private line: string = '';
  private col: number = 0;
  /** 延迟回卷标记：已写到第 width 列，下一个可打印字符先换行再落笔。 */
  private pendingWrap: boolean = false;
  /** 回滚区是否因超限裁剪过头部（用于「输出过长」提示）。 */
  private truncated: boolean = false;
  /** 回滚区总字符数（含换行），用于超限裁剪。 */
  private charCount: number = 0;
  private state: number = STATE_NORMAL;
  private csiBuf: string = '';

  constructor(width: number = 80, maxBufferChars: number = 32000) {
    this.width = width;
    this.maxBufferChars = maxBufferChars;
  }

  /** 喂入一段解码后的回显文本（UTF-8 跨帧解码在 HdcShellChannel 里已完成）。 */
  feed(text: string): void {
    for (let i = 0; i < text.length; i++) {
      this.step(text.charCodeAt(i));
    }
  }

  /** 清空全部状态（断开重连时用）。 */
  reset(): void {
    this.lines = [];
    this.line = '';
    this.col = 0;
    this.pendingWrap = false;
    this.truncated = false;
    this.charCount = 0;
    this.state = STATE_NORMAL;
    this.csiBuf = '';
  }

  /** 活动行：还在被回显/重画修改的最后一行（连接后的自动设置命令靠它等提示符）。 */
  getActiveLine(): string {
    return this.line;
  }

  /** 当前应显示的完整文本：回滚行 + 活动行。 */
  getDisplayText(): string {
    if (this.lines.length === 0) {
      return this.line;
    }
    if (this.line.length === 0) {
      return this.lines.join('\n');
    }
    return `${this.lines.join('\n')}\n${this.line}`;
  }

  /** 回滚区是否被裁剪过。 */
  isTruncated(): boolean {
    return this.truncated;
  }

  // ---------- 内部 ----------

  private step(code: number): void {
    if (this.state === STATE_ESC) {
      if (code === 91) { // '[' -> CSI
        this.state = STATE_CSI;
        this.csiBuf = '';
      } else if (code === 93) { // ']' -> OSC 标题
        this.state = STATE_OSC;
      } else {
        // ESC ( ) = > 等：吞掉转义后紧随的一个字符即可
        this.state = STATE_NORMAL;
      }
      return;
    }
    if (this.state === STATE_CSI) {
      // 参数与中间字节 0x20-0x3F，终止字节 0x40-0x7E
      if (code >= 0x40 && code <= 0x7e) {
        this.execCsi(this.csiBuf, code);
        this.state = STATE_NORMAL;
      } else if (this.csiBuf.length < 32) {
        this.csiBuf += String.fromCharCode(code);
      }
      return;
    }
    if (this.state === STATE_OSC) {
      if (code === BEL) {
        this.state = STATE_NORMAL;
      } else if (code === ESC) {
        this.state = STATE_OSC_ESC;
      }
      return;
    }
    if (this.state === STATE_OSC_ESC) {
      this.state = STATE_NORMAL; // ST（ESC \）的 '\'，无论是什么都结束 OSC
      return;
    }

    switch (code) {
      case CR:
        this.col = 0;
        this.pendingWrap = false;
        break;
      case LF:
      case VT:
      case FF:
        this.newline();
        break;
      case BS:
        if (this.pendingWrap) {
          this.pendingWrap = false;
          this.col = this.width - 1;
        } else {
          this.col = Math.max(0, this.col - 1);
        }
        break;
      case TAB:
        this.tab();
        break;
      case BEL:
      case 0:
      case 14:
      case 15:
        break; // BEL / NUL / SO / SI：忽略
      case ESC:
        this.state = STATE_ESC;
        break;
      default:
        if (code >= 32) {
          this.putChar(String.fromCharCode(code));
        }
        break;
    }
  }

  private putChar(ch: string): void {
    if (this.pendingWrap) {
      this.newline();
    }
    if (this.col < this.line.length) {
      this.line = this.line.substring(0, this.col) + ch + this.line.substring(this.col + 1);
    } else if (this.col === this.line.length) {
      this.line += ch;
    } else {
      let padded = this.line;
      for (let k = this.line.length; k < this.col; k++) {
        padded += ' ';
      }
      this.line = padded + ch;
    }
    this.col += 1;
    if (this.col === this.width) {
      this.pendingWrap = true;
    }
  }

  private newline(): void {
    this.lines.push(this.line);
    this.charCount += this.line.length + 1;
    this.line = '';
    this.col = 0;
    this.pendingWrap = false;
    this.trim();
  }

  private tab(): void {
    this.pendingWrap = false;
    const target = this.col + (8 - this.col % 8);
    const newCol = Math.min(target, this.width - 1);
    // 只补洞，不覆盖：已有字符保持原样
    let padded = this.line;
    for (let k = this.line.length; k < newCol; k++) {
      padded += ' ';
    }
    this.line = padded;
    this.col = newCol;
  }

  /** 光标列的钳制值（pendingWrap 时 col==width，取最后一列）。 */
  private clampedCol(): number {
    return Math.min(this.col, this.width - 1);
  }

  private trim(): void {
    while (this.charCount > this.maxBufferChars && this.lines.length > 1) {
      this.charCount -= this.lines[0].length + 1;
      this.lines.shift();
      this.truncated = true;
    }
  }

  private csiParam(buf: string, index: number, defaultValue: number): number {
    const parts = buf.split(';');
    if (index >= parts.length) {
      return defaultValue;
    }
    const digits = parts[index].replace(/[^0-9]/g, '');
    if (digits.length === 0) {
      return defaultValue;
    }
    return Number.parseInt(digits, 10);
  }

  private execCsi(buf: string, finalByte: number): void {
    const ch = String.fromCharCode(finalByte);
    if (ch === 'K') {
      const n = this.csiParam(buf, 0, 0);
      const c = this.clampedCol();
      if (n === 0) {
        this.line = this.line.substring(0, c);
      } else if (n === 1) {
        let head = '';
        for (let k = 0; k < Math.min(c, this.line.length); k++) {
          head += ' ';
        }
        this.line = head + this.line.substring(Math.min(c, this.line.length));
      } else {
        this.line = '';
      }
      return;
    }
    if (ch === 'J') {
      const n = this.csiParam(buf, 0, 0);
      if (n === 0) {
        this.line = this.line.substring(0, this.clampedCol());
      } else if (n === 2 || n === 3) {
        // clear 命令走这里：没有「可见屏 vs 回滚」之分，全清
        this.lines = [];
        this.line = '';
        this.col = 0;
        this.charCount = 0;
        this.pendingWrap = false;
        this.truncated = false;
      }
      return;
    }
    if (ch === 'D') {
      const n = this.csiParam(buf, 0, 1);
      this.col = Math.max(0, this.clampedCol() - n);
      this.pendingWrap = false;
      return;
    }
    if (ch === 'C') {
      const n = this.csiParam(buf, 0, 1);
      this.col = Math.min(this.width - 1, this.clampedCol() + n);
      this.pendingWrap = false;
      return;
    }
    if (ch === 'G') {
      const n = this.csiParam(buf, 0, 1);
      this.col = Math.min(this.width - 1, Math.max(0, n - 1));
      this.pendingWrap = false;
      return;
    }
    if (ch === 'P') {
      const n = this.csiParam(buf, 0, 1);
      const c = this.clampedCol();
      this.line = this.line.substring(0, c) + this.line.substring(Math.min(this.line.length, c + n));
      return;
    }
    if (ch === '@') {
      const n = this.csiParam(buf, 0, 1);
      const c = this.clampedCol();
      let spaces = '';
      for (let k = 0; k < n; k++) {
        spaces += ' ';
      }
      this.line = this.line.substring(0, c) + spaces + this.line.substring(c);
      return;
    }
    if (ch === 'X') {
      const n = this.csiParam(buf, 0, 1);
      const c = this.clampedCol();
      let spaces = '';
      for (let k = 0; k < n; k++) {
        spaces += ' ';
      }
      this.line = this.line.substring(0, c) + spaces + this.line.substring(Math.min(this.line.length, c + n));
      return;
    }
    // 其余（颜色 m、模式 h/l、光标寻址 H/f/A/B、区域 r…）不支持，静默吞掉
  }
}
