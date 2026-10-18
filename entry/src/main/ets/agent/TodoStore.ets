/*
 * todo 计划与进度换算。
 *
 * 存在的理由：长时任务的实况窗通知只有一个 `downloadTemplate`，它的 `progressValue`
 * 是**百分比**（≤0 显示为 0，≥100 进度环消失）。而 agent 的总步数事先不知道，
 * 算不出百分比。解法是让模型自己声明计划，用计划完成度当百分比。
 *
 * 因此这里既是给模型看的计划，也是通知栏进度环的唯一数据来源。
 */

/** 每项的状态。`abandoned` 只由应用侧兜底时写入，模型不应主动使用。 */
export type TodoStatus = 'pending' | 'active' | 'done' | 'abandoned';

export interface TodoItem {
  text: string;
  status: TodoStatus;
}

/** 模型每次全量重写时提交的一项；status 允许缺省，缺省视为待办。 */
export interface TodoInput {
  text?: string;
  status?: string;
}

/**
 * 一次重写的两份输出。
 *
 * 必须拆开：这两份以前是同一个字符串，同时喂给模型和界面时间线。给模型的那份想缩短，
 * 界面那份不能缩 —— 用户要在时间线上看见每一项写了什么。
 */
export interface RewriteResult {
  /** 界面时间线用：永远是完整列表。 */
  display: string;
  /**
   * 模型用：只有在我们改动了它提交的内容时才是完整列表，否则只有进度加当前项那一行。
   *
   * 为什么平时不回显：模型在同一轮里刚把完整列表作为参数发出来，回显等于把同一份东西
   * 在同一个来回里说两遍，而这段文字进历史段、此后每轮重发。实测一次任务里 4 次调用
   * 的回显共 284 字符，占整段对话的 3.8%。
   *
   * 为什么改动时必须回显：`rewrite` 会悄悄丢掉空文本项、截断过长文本、砍掉超出上限的项。
   * 那种情况下这份回显是模型唯一能发现"我提交的东西被改了"的渠道。
   */
  forModel: string;
}

export interface TodoProgress {
  /** 已完成项数（`abandoned` 不计入完成）。 */
  doneCount: number;
  /** 未被放弃的总项数，即进度的分母。 */
  totalCount: number;
  /**
   * 发给通知的百分比。
   * 运行中封顶 99：`progressValue >= 100` 会让进度环消失，中途消失会被误读成跑完了。
   */
  percent: number;
}

const MAX_ITEMS: number = 40;
const MAX_TEXT_LENGTH: number = 120;
/** 运行中允许的最大百分比。100 留给整轮任务真正结束的那一刻。 */
export const RUNNING_PERCENT_CAP: number = 99;
/** 模型带着未完成项调 done 时，最多追问几次。第 N+1 次接受结束。 */
export const MAX_DONE_REMINDERS: number = 2;

/** normalizeStatus 认得的全部写法。不在其中的会被静默当成待办，那算一次改动。 */
const KNOWN_STATUS: string[] = [
  'done', 'completed', '已完成',
  'active', 'in_progress', '进行中',
  'abandoned', 'cancelled', '已放弃',
  'pending', 'todo', '待办'
];

/** 缺省是写明的行为（视为待办），不算改动；写了个认不出的值才算。 */
function statusRecognized(raw: string | undefined): boolean {
  if (raw === undefined) {
    return true;
  }
  const value = raw.trim().toLowerCase();
  for (const known of KNOWN_STATUS) {
    if (value === known) {
      return true;
    }
  }
  return false;
}

function normalizeStatus(raw: string | undefined): TodoStatus {
  if (raw === undefined) {
    return 'pending';
  }
  const value = raw.trim().toLowerCase();
  if (value === 'done' || value === 'completed' || value === '已完成') {
    return 'done';
  }
  if (value === 'active' || value === 'in_progress' || value === '进行中') {
    return 'active';
  }
  if (value === 'abandoned' || value === 'cancelled' || value === '已放弃') {
    return 'abandoned';
  }
  return 'pending';
}

function statusLabel(status: TodoStatus): string {
  if (status === 'done') {
    return '已完成';
  }
  if (status === 'active') {
    return '进行中';
  }
  if (status === 'abandoned') {
    return '已放弃';
  }
  return '待办';
}

export class TodoStore {
  private items: TodoItem[] = [];
  /** 模型是否已经写过至少一次计划。首轮拦截用它判断。 */
  private initialized: boolean = false;
  /** 已经因为"还有未完成项"追问过几次。 */
  private reminders: number = 0;

  hasPlan(): boolean {
    return this.initialized;
  }

  /** 用于存盘恢复。直接灌入已有条目，不走 rewrite 的校验与截断。 */
  load(items: TodoItem[]): void {
    this.items = items.slice(0, MAX_ITEMS);
    // 恢复出来的计划就是计划。不置这个标志，闸门会用「开始操作之前请先调用 todo_write
    // 列出你的计划」拒掉恢复后的第一个动作 —— 而同一次恢复刚把这份计划渲染进状态栏，
    // 模型于是被告知一件与屏幕上写着的相反的事，还白费一轮。
    if (this.items.length > 0) {
      this.initialized = true;
    }
  }

  list(): TodoItem[] {
    const copy: TodoItem[] = [];
    for (const item of this.items) {
      copy.push({ text: item.text, status: item.status });
    }
    return copy;
  }

  /**
   * 全量重写。模型每次提交完整列表，覆盖旧的。
   *
   * 选全量而不是 add/check/edit 三个接口：模型必须能自由增删、重排、改写计划，
   * 增量接口会让它多花几倍调用，而且应用侧状态很容易和模型的认知对不上。
   * 代价是模型可能手滑丢项，所以调用方要把重写后的完整列表回显给模型。
   */
  rewrite(inputs: TodoInput[]): RewriteResult {
    const next: TodoItem[] = [];
    // 我们有没有改动模型提交的内容。改动了就必须把完整列表回显给它，那是它唯一的知情渠道。
    let altered = false;
    for (const raw of inputs) {
      const text = raw.text === undefined ? '' : raw.text.trim();
      if (text.length === 0) {
        altered = true;
        continue;
      }
      // 原来这里是 break。改成 continue 是为了把"还有几项被砍掉"也算进 altered，
      // 结果列表一模一样。
      if (next.length >= MAX_ITEMS) {
        altered = true;
        continue;
      }
      if (text.length > MAX_TEXT_LENGTH) {
        altered = true;
      }
      if (!statusRecognized(raw.status)) {
        altered = true;
      }
      next.push({
        text: text.length > MAX_TEXT_LENGTH ? `${text.substring(0, MAX_TEXT_LENGTH)}…` : text,
        status: normalizeStatus(raw.status)
      });
    }
    if (next.length === 0) {
      const empty = '计划为空，至少要有一项。请重新提交。';
      return { display: empty, forModel: empty };
    }
    this.items = next;
    this.initialized = true;
    const full = this.render();
    return { display: full, forModel: altered ? full : this.progressBrief() };
  }

  /** 进度那一行。用在 render() 的表头，那里下面紧跟着完整列表，不必再点名当前项。 */
  private progressLine(): string {
    const p = this.progress();
    return `计划进度 ${p.doneCount}/${p.totalCount}`;
  }

  /**
   * 不回显完整列表时给模型的那一行：进度 + 当前在做哪一项。
   *
   * 为什么要带上当前项：把完整列表撤掉之后，模型手里最近的一份"当前计划"只剩一个分数，
   * 哪项做完了、哪项在做，得回头翻它自己几条消息前的调用参数。实测两次任务里各出现过
   * 一次"提交一份和上次一字不差的计划"的空转，缩短回显前后各一次。证据不足以断定是
   * 缩短造成的，但把当前项摆回眼前的成本只有十几个字符。
   */
  private progressBrief(): string {
    const line = this.progressLine();
    const current = this.currentItemText();
    return current.length > 0 ? `${line}，当前：${current}` : line;
  }

  /** 当前在做的那一项。优先取标了 active 的；没有就取第一个还没做完的。 */
  private currentItemText(): string {
    for (const item of this.items) {
      if (item.status === 'active') {
        return item.text;
      }
    }
    for (const item of this.items) {
      if (item.status !== 'done' && item.status !== 'abandoned') {
        return item.text;
      }
    }
    return '';
  }

  /** 兜底：把仍未完成的项标记为已放弃。不替模型勾成"已完成"，那是伪造完成度。 */
  abandonUnfinished(): number {
    let changed = 0;
    for (const item of this.items) {
      if (item.status !== 'done' && item.status !== 'abandoned') {
        item.status = 'abandoned';
        changed += 1;
      }
    }
    return changed;
  }

  unfinishedCount(): number {
    let n = 0;
    for (const item of this.items) {
      if (item.status !== 'done' && item.status !== 'abandoned') {
        n += 1;
      }
    }
    return n;
  }

  /**
   * 进度换算。
   *
   * 允许倒退：模型加项会让分母变大、百分比下降。如实显示 —— 进度条倒退是
   * "计划变大了"的真实信号，比一个只会前进的假进度有用。
   */
  progress(): TodoProgress {
    let done = 0;
    let total = 0;
    for (const item of this.items) {
      if (item.status === 'abandoned') {
        continue;
      }
      total += 1;
      if (item.status === 'done') {
        done += 1;
      }
    }
    if (total === 0) {
      return { doneCount: 0, totalCount: 0, percent: 0 };
    }
    const raw = Math.floor((done * 100) / total);
    return {
      doneCount: done,
      totalCount: total,
      percent: raw > RUNNING_PERCENT_CAP ? RUNNING_PERCENT_CAP : raw
    };
  }

  /** 回显给模型的完整列表。带编号是为了让模型能在下一次重写里对齐。 */
  render(): string {
    if (this.items.length === 0) {
      return '当前没有计划。';
    }
    const lines: string[] = [this.progressLine()];
    for (let i = 0; i < this.items.length; i += 1) {
      const item = this.items[i];
      lines.push(`${i + 1} [${statusLabel(item.status)}] ${item.text}`);
    }
    return lines.join('\n');
  }

  /** 顶部常驻的一行摘要。 */
  summary(): string {
    const p = this.progress();
    if (p.totalCount === 0) {
      return '未制定计划';
    }
    return `${p.doneCount}/${p.totalCount}`;
  }

  /**
   * 模型调 done 时的裁决。
   *
   * 用户定的规则本身可能死循环：模型说 done → 我们说还有没勾的 → 模型又说 done → …
   * 所以追问上限 MAX_DONE_REMINDERS 次，超过就接受结束并把剩余项标为已放弃。
   */
  judgeDone(): DoneVerdict {
    const left = this.unfinishedCount();
    if (left === 0) {
      return { accept: true, reminder: '', abandoned: 0 };
    }
    if (this.reminders >= MAX_DONE_REMINDERS) {
      const abandoned = this.abandonUnfinished();
      return { accept: true, reminder: '', abandoned };
    }
    this.reminders += 1;
    // 后面原先还有三句说明「是忘了打勾还是没做、分别该怎么办」。删掉：done 的描述
    // 已经说过系统会把计划回给你让你判断，todo_write 的描述也说过完成一步就改成 done、
    // 结束时不应再有未完成项。这条消息真正承载信息的是数量和这份重新渲染的清单。
    const reminder =
      `你已宣布完成，但计划里还有 ${left} 项没有勾掉。\n` +
      `${this.render()}`;
    return { accept: false, reminder, abandoned: 0 };
  }

  remindersUsed(): number {
    return this.reminders;
  }

  /**
   * 新任务开始时清掉追问预算。
   *
   * 这个预算是为「一次 done 争议」设的（模型说做完了、我们指出还有没勾的、最多追问两次）。
   * 不清的话，第一个任务用完之后，第二个任务的第一次 done 会被直接接受，剩余计划项
   * 静默标成已放弃 —— 而这个实例是跨任务复用的，后续消息走 continueWith，不重建。
   */
  resetReminders(): void {
    this.reminders = 0;
  }
}

export interface DoneVerdict {
  /** 是否接受本次结束。 */
  accept: boolean;
  /** 不接受时，要追加给模型的那条消息；接受时为空串。 */
  reminder: string;
  /** 接受结束时被强制标为已放弃的项数。 */
  abandoned: number;
}
