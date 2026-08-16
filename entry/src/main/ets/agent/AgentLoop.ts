/*
 * agent 主循环。
 *
 * 职责：发请求 → 收到 tool_use → 执行 → 把结果接回去 → 再发。中间夹着四道闸门：
 *   1. 首轮没写计划就不许动屏幕
 *   2. 锁屏时冻结（锁屏下观测可用、动作全部无效，让模型去撞墙毫无意义）
 *   3. 前台应用被用户切走时暂停等确认，不抢屏幕
 *   4. 黑名单应用直接拒绝
 *
 * 以及一条兜底：模型带着未完成的计划调 done 时先追问，追问上限内不接受结束。
 */

import type {
  DeviceControl, ActionResult, ScreenshotResult, AppEntry, ScreenGuardTick
} from './DeviceControl';
import { MIN_SCREEN_OFF_MS, CANCEL_REASON } from './DeviceControl';
import type {
  AnthropicClient, ApiMessage, ApiBlock, ApiTool, ApiResult,
  ContentPart, SendOptions, StreamSink
} from './AnthropicClient';
import { assistantTurnToBlocks } from './AnthropicClient';
import type { AgentConfig } from './AgentSettings';
import type { TodoInput, TodoItem } from './TodoStore';
import { TodoStore, RUNNING_PERCENT_CAP } from './TodoStore';
import {
  buildTools, buildSystemPrompt, isActionTool, buildCompactionPrompt, SUMMARY_HEADER,
  TOOL_TODO_WRITE, TOOL_OBSERVE, TOOL_SCREENSHOT, TOOL_TAP, TOOL_CLICK, TOOL_LONG_PRESS,
  TOOL_DOUBLE_TAP, TOOL_SCROLL, TOOL_DRAG, TOOL_DRAW, TOOL_INPUT_TEXT, TOOL_KEY,
  TOOL_LAUNCH_APP, TOOL_LIST_APPS, TOOL_WAIT, TOOL_DONE
} from './AgentTools';

/** 时间线条目的种类，界面按它决定样式。 */
export type AgentEventKind =
  'thinking' | 'model_text' | 'tool_call' | 'tool_result' | 'todo' |
  'notice' | 'paused' | 'error' | 'finished' | 'interrupted';

export interface AgentEvent {
  kind: AgentEventKind;
  text: string;
  /** tool_call 时是 tool 名，其余为空串。 */
  toolName: string;
}

export interface AgentHooks {
  /** 追加一条时间线条目。 */
  onEvent: (ev: AgentEvent) => void;
  /** 进度变化。percent 直接送给通知栏进度环，summary 形如 "3/7"。 */
  onProgress: (percent: number, summary: string) => void;
  /** 累计用量，用于在界面上显示花了多少 token。 */
  onUsage: (inputTokens: number, outputTokens: number, cachedTokens: number) => void;
  /**
   * 需要用户介入时调用，返回 true 表示可以继续、false 表示放弃任务。
   * 界面实现成一条横幅加一个「继续」按钮。
   */
  waitForResume: (reason: string) => Promise<boolean>;
}

/** 存盘用的会话快照。 */
export interface AgentSnapshot {
  messages: ApiMessage[];
  todos: TodoItem[];
  totalInput: number;
  totalOutput: number;
  totalCached: number;
}

export interface LoopLimits {
  /**
   * 折叠时原文保留最近几个来回。
   *
   * 单位是「来回」而不是「消息条数」，因为一个来回固定占两条消息
   * （一条 assistant 装思考与全部 tool_use，一条 user 装全部 tool_result 与截图），
   * 按条数切会切出半个来回：留下的 tool_result 找不到配对的 tool_use，服务端直接 400。
   */
  keepRecentRounds: number;
  /** API 请求的连接与读取超时。 */
  connectTimeoutMs: number;
  readTimeoutMs: number;
  /** 单次 API 失败的重试次数。 */
  maxRetries: number;
}

export function defaultLimits(): LoopLimits {
  return {
    keepRecentRounds: 4,
    connectTimeoutMs: 15000,
    // 流式长回复加上高推理强度可能很久，读超时给足
    readTimeoutMs: 600000,
    maxRetries: 3
  };
}

/**
 * 所有 tool 的参数并集。
 *
 * 用一个结构装全部字段，而不是给每个 tool 写联合类型：ArkTS 里联合类型的收窄很啰嗦，
 * 而 JSON.parse 后未出现的字段就是 undefined，检查一下即可。这与 AnthropicClient
 * 里 ApiBlock 的做法一致。
 */
interface ToolArgs {
  items?: TodoInput[];
  index?: number;
  direction?: string;
  amount?: number;
  from_index?: number;
  to_index?: number;
  /** click 的画面比例坐标，0~1。 */
  x?: number;
  y?: number;
  strokes?: string[];
  text?: string;
  name?: string;
  repeat?: number;
  /** launch_app 的目标：应用名字，或者包名。 */
  app?: string;
  ms?: number;
  summary?: string;
}

interface ToolOutcome {
  /** 回给模型的文本。 */
  text: string;
  isError: boolean;
  /** 非空时作为独立的 image 块跟在 tool_result 后面。 */
  imageBase64: string;
}

/**
 * 用户点「继续」之后回给模型的话。
 *
 * 不放行那个待执行的动作，而是把发生的事告诉模型，让它自己导航回去。
 * 不写具体包名：用户点继续时前台是本应用，暂停前那个包名对它来说只是个提示，
 * 而"回到暂停前的应用"这句话它自己就能对上号 —— 计划和历史都在它手里。
 */
const RESUME_NOTICE: string =
  '任务在这一步被暂停过，用户刚点了继续。\n' +
  '你上一个动作可能没有执行，先回到暂停前的应用重新观测，再接着做原来的计划。';

function textBlock(text: string): ApiBlock {
  return { type: 'text', text };
}

function userMessage(blocks: ApiBlock[]): ApiMessage {
  return { role: 'user', content: blocks };
}

export class AgentLoop {
  private readonly device: DeviceControl;
  private readonly api: AnthropicClient;
  /** 实例跨任务存活，所以配置不能只在构造时取一次；每次发送前由界面推入最新值。 */
  private config: AgentConfig;
  private readonly hooks: AgentHooks;
  private readonly limits: LoopLimits;
  private readonly todos: TodoStore = new TodoStore();
  private readonly tools: ApiTool[];
  /** 黑名单写在系统提示里，所以配置变了要跟着重建。 */
  private systemPrompt: string;
  private readonly ownBundle: string;

  private messages: ApiMessage[] = [];
  private running: boolean = false;
  private stopRequested: boolean = false;
  /** 任务开始时的前台应用，用于发现用户把屏幕抢走。 */
  private expectedBundle: string = '';
  /** 端点是否已被证实不支持图片块；一旦证实就不再提供 screenshot。 */
  private imagesRejected: boolean = false;
  /**
   * 连续失败的工具调用次数。只作为信息回给模型，不在这里定任何重试策略：
   * 重试、改计划还是收摊，由模型自己决定。
   */
  private consecutiveToolFailures: number = 0;
  /** 本轮是否已经因为屏幕原因中断过，避免重复发事件。 */
  private interrupted: boolean = false;
  private guardTimer: number = -1;
  private totalInput: number = 0;
  private totalOutput: number = 0;
  private totalCached: number = 0;
  /**
   * 上一次回包时这段对话真实占了多少上下文：输入 + 缓存创建 + 缓存命中 + 输出。
   *
   * 这是判断该不该折叠的**唯一**依据，和上面三个累计量是两件事。累计量是"这个任务
   * 到现在一共花了多少 token"，用于界面显示花费；每轮都要重发整段历史，所以它涨得
   * 比真实上下文快得多。拿累计量去比阈值，会在上下文还很小的时候就开始折，
   * 而且折完仍然大于阈值，于是每轮都折 —— 表现为模型反复失忆。
   *
   * 赋值不累加。折叠之后归零：那一刻我们并不知道新历史有多大，等下一个回包来告。
   */
  private lastContextTokens: number = 0;
  /** 本次任务截了第几张图。只用于在文字里给每张图一个能被引用的编号。 */
  private screenshotSeq: number = 0;
  /** 刚从暂停恢复。用来让这一次的"动作没放行"不被算进连续失败次数。 */
  private resumedFromPause: boolean = false;
  /**
   * 上一次闸门看到的焦点窗口 id。它是"有没有人换过屏幕"的便宜筛子：
   * 由 quickState 顺带带回，不额外花一次完整观测。
   */
  private lastFocusWindowId: string = '';

  constructor(
    device: DeviceControl,
    api: AnthropicClient,
    config: AgentConfig,
    ownBundle: string,
    hooks: AgentHooks,
    limits: LoopLimits
  ) {
    this.device = device;
    this.api = api;
    this.config = config;
    this.hooks = hooks;
    this.limits = limits;
    this.ownBundle = ownBundle;
    this.tools = buildTools(true);
    this.systemPrompt = buildSystemPrompt(ownBundle, config.blacklistBundles);
  }

  /** 有历史就说明这是一段进行中的对话，下一条消息应当接着聊而不是重新开始。 */
  hasHistory(): boolean {
    return this.messages.length > 0;
  }

  /**
   * 导出会话用于存盘。图片块换成一行文字：截图原生分辨率的 base64 单张可达数百 KB，
   * 全存下来磁盘和恢复耗时都不划算。代价是应用被系统回收再打开后，
   * 模型只知道"这里曾截过一张图"，要重新看就得再截一次。
   */
  snapshot(): AgentSnapshot {
    const messages: ApiMessage[] = [];
    for (const msg of this.messages) {
      const blocks: ApiBlock[] = [];
      for (const block of msg.content) {
        if (block.type === 'image') {
          blocks.push({ type: 'text', text: '（上面那张截图的画面已移除：会话存盘不保存图片数据。）' });
        } else {
          blocks.push(block);
        }
      }
      messages.push({ role: msg.role, content: blocks });
    }
    return {
      messages,
      todos: this.todos.list(),
      totalInput: this.totalInput,
      totalOutput: this.totalOutput,
      totalCached: this.totalCached
    };
  }

  /**
   * 合并相邻的同角色消息。角色必须交替，连着两条 user 会被服务端拒。
   *
   * 需要这一步是因为存盘可能来自旧版本：早先补齐落单 tool_use 时单独推了一条 user，
   * 紧跟着用户那句话又是一条 user，真机存盘里就留下了这种形状。
   * 光改写入侧不够，读回来也得能纠正。
   */
  private static coalesceRoles(input: ApiMessage[]): ApiMessage[] {
    const out: ApiMessage[] = [];
    for (const msg of input) {
      if (out.length > 0 && out[out.length - 1].role === msg.role) {
        const prev = out[out.length - 1];
        out[out.length - 1] = { role: prev.role, content: prev.content.concat(msg.content) };
        continue;
      }
      out.push({ role: msg.role, content: msg.content });
    }
    return out;
  }

  /**
   * 从存盘恢复。只灌状态，不触发任何请求。
   *
   * 真实上下文大小不进存盘，恢复后从 0 起算：加一个字段就得抬存档版本号，
   * 而抬版本号会让用户已有的会话全部作废，代价远大于收益。代价是恢复后的第一发
   * 不做折叠检查 —— 而那一发本来就要发出去，第一个回包会立刻把这个数补上。
   */
  restore(snap: AgentSnapshot): void {
    this.messages = AgentLoop.coalesceRoles(snap.messages);
    this.todos.load(snap.todos);
    this.totalInput = snap.totalInput;
    this.totalOutput = snap.totalOutput;
    this.totalCached = snap.totalCached;
    this.lastContextTokens = 0;
    this.screenshotSeq = AgentLoop.maxScreenshotSeq(this.messages);
    this.hooks.onUsage(this.totalInput, this.totalOutput, this.totalCached);
    this.reportProgress();
  }

  /**
   * 从恢复的历史里数出截图编号已经用到第几。
   *
   * 编号本身不进存盘（存盘只有消息、计划、用量三样），但历史里每条截图说明都带着它。
   * 不接上就会从 1 重新开始，同一段对话里出现两个「第 1 张截图」——
   * 折叠时摘要模型会把它们当成同一张，时间线就错了。
   */
  private static maxScreenshotSeq(messages: ApiMessage[]): number {
    let max = 0;
    for (const msg of messages) {
      for (const block of msg.content) {
        // 截图说明是 tool_result 的正文，落在 content 上；存盘替换出来的占位文字落在 text 上。
        // 两处都要扫：占位文字本身不带编号，但同一条 tool_result 的正文带。
        const text = block.content !== undefined ? block.content :
          (block.text !== undefined ? block.text : '');
        if (text.length === 0) {
          continue;
        }
        const re = new RegExp('第\\s*(\\d+)\\s*张截图', 'g');
        let hit = re.exec(text);
        while (hit !== null) {
          const n = Number.parseInt(hit[1], 10);
          if (!Number.isNaN(n) && n > max) {
            max = n;
          }
          hit = re.exec(text);
        }
      }
    }
    return max;
  }

  /**
   * 推入最新配置。实例跨任务存活，若只在构造时取一次，
   * 用户改完模型或黑名单后会毫无提示地继续用旧值。
   */
  applyConfig(config: AgentConfig): void {
    this.config = config;
    this.systemPrompt = buildSystemPrompt(this.ownBundle, config.blacklistBundles);
  }

  isRunning(): boolean {
    return this.running;
  }

  todoSummary(): string {
    return this.todos.summary();
  }

  /** 用户按停止。会中止在途请求，循环在下一个检查点退出。 */
  stop(): void {
    this.stopRequested = true;
    this.api.abort();
    this.device.requestCancel();
  }

  private emit(kind: AgentEventKind, text: string, toolName: string = ''): void {
    this.hooks.onEvent({ kind, text, toolName });
  }

  private reportProgress(): void {
    const p = this.todos.progress();
    this.hooks.onProgress(p.percent, this.todos.summary());
  }

  /** 跑一个任务，直到模型结束、用户停止或出错。 */
  async run(task: string): Promise<void> {
    if (this.running) {
      this.emit('error', '已有任务在跑，先停止它。');
      return;
    }
    this.running = true;
    this.stopRequested = false;
    this.interrupted = false;
    this.messages = [userMessage([textBlock(task)])];
    this.lastContextTokens = 0;
    this.screenshotSeq = 0;
    this.resumedFromPause = false;
    this.lastFocusWindowId = '';
    this.reportProgress();
    await this.pumpGuarded();
  }

  /**
   * 接着上次的对话继续。与 `run` 的唯一区别是**只追加不重置**：
   * 消息历史、计划、用量都留着。
   */
  async continueWith(text: string): Promise<void> {
    if (this.running) {
      this.emit('error', '已有任务在跑，先停止它。');
      return;
    }
    if (this.messages.length === 0) {
      await this.run(text);
      return;
    }
    this.running = true;
    this.stopRequested = false;
    this.interrupted = false;
    // 中断可能停在「已发出 tool_use、还没回 tool_result」的位置上。
    // 不补齐就续聊，服务端会因为 tool_use 没有配对结果直接 400。
    // 补齐块必须与用户这句话合成**同一条** user 消息：角色必须交替，
    // 连着推两条 user 消息同样是 400。
    const blocks = this.danglingToolResults();
    blocks.push(textBlock(text));
    this.appendUserBlocks(blocks);
    this.reportProgress();
    await this.pumpGuarded();
  }

  /** 起跑前的屏幕检查 + 全程看守，两个入口共用。 */
  private async pumpGuarded(): Promise<void> {
    this.device.clearCancel();
    try {
      const state = await this.device.quickState();
      if (state.locked) {
        this.emit('error', '设备处于锁屏状态，无法开始：锁屏下所有动作都无效。请先解锁。');
        return;
      }
      const timeout = await this.device.readScreenOffTimeoutMs();
      if (timeout > 0 && timeout < MIN_SCREEN_OFF_MS) {
        this.emit('error',
          `息屏时长只有 ${Math.round(timeout / 1000)} 秒，太短，无法保证任务不被误中断。` +
          `请把屏幕超时调到 ${Math.round(MIN_SCREEN_OFF_MS / 1000)} 秒以上再开始。`);
        return;
      }
      if (timeout <= 0) {
        this.emit('notice', '读不到系统息屏时长，看守按最快节奏运行。');
      }
      // 这一笔只是给闸门定个基准，读不到就留空：空基准的含义本来就是"还没有基准"，
      // 闸门会跳过比对，第一个动作做完由 syncExpectedBundle 补上。
      // 不发提示 —— 这是内部记账，用户既看不懂也不需要做任何事。
      try {
        this.expectedBundle = await this.currentBundle(true);
      } catch (err) {
        this.expectedBundle = '';
      }
      await this.startScreenGuard();
      await this.pump();
    } catch (err) {
      this.emit('error', `任务异常终止: ${(err as Error).message}`);
    } finally {
      this.stopScreenGuard();
      this.running = false;
    }
  }

  /**
   * 屏幕看守。一拍同时做两件事：判断用户还看不看得见，以及把屏幕点回去。
   * 间隔由设备真实息屏时长推导并封顶，见 `suggestGuardIntervalMs`。
   */
  private async startScreenGuard(): Promise<void> {
    this.stopScreenGuard();
    const interval = await this.device.suggestGuardIntervalMs();
    this.guardTimer = setInterval(() => {
      if (!this.running || this.stopRequested) {
        return;
      }
      this.device.screenGuardTick().then((tick: ScreenGuardTick) => {
        if (tick.ok && tick.shouldStop) {
          this.interruptForScreen(tick.reason);
        }
      }).catch((err: Error) => {
        this.emit('notice', `屏幕看守这一拍失败: ${err.message}`);
      });
    }, interval);
  }

  private stopScreenGuard(): void {
    if (this.guardTimer >= 0) {
      clearInterval(this.guardTimer);
      this.guardTimer = -1;
    }
  }

  /**
   * 给最后一条 assistant 消息里没有配对结果的 `tool_use` 补上结果。
   *
   * 中断发生在工具执行途中时，带 `tool_use` 的 assistant 消息已经进了历史，
   * 而 `tool_result` 还没推。这种历史直接续聊，服务端会因为
   * 「每个 tool_use 都必须有对应的 tool_result」而 400。
   */
  /**
   * 追加 user 块。末尾已经是 user 消息时并进去，而不是再推一条。
   *
   * 角色必须交替，连着两条 user 会被服务端拒。历史末尾是 user 的情形不止一种：
   * 上一轮刚推完 tool_result 就停了、或者旧存盘经过合并之后正好收在 user 上。
   * 与其在每个调用点各自判断，不如让追加这一步本身就不可能产生连续同角色。
   */
  private appendUserBlocks(blocks: ApiBlock[]): void {
    if (blocks.length === 0) {
      return;
    }
    if (this.messages.length > 0) {
      const last = this.messages[this.messages.length - 1];
      if (last.role === 'user') {
        this.messages[this.messages.length - 1] = {
          role: 'user',
          content: last.content.concat(blocks)
        };
        return;
      }
    }
    this.messages.push(userMessage(blocks));
  }

  private danglingToolResults(): ApiBlock[] {
    if (this.messages.length === 0) {
      return [];
    }
    const last = this.messages[this.messages.length - 1];
    if (last.role !== 'assistant') {
      return [];
    }
    // 最后一条是 assistant，说明它后面根本没有 tool_result，里面的 tool_use 全都落单。
    const pending: string[] = [];
    for (const block of last.content) {
      if (block.type === 'tool_use' && block.id !== undefined) {
        pending.push(block.id);
      }
    }
    if (pending.length === 0) {
      return [];
    }
    const repair: ApiBlock[] = [];
    for (const id of pending) {
      repair.push({
        type: 'tool_result',
        tool_use_id: id,
        content: '这一步没有执行：任务在此处被中断（屏幕熄灭或设备锁屏）。',
        is_error: true
      });
    }
    this.emit('notice', `已为中断处 ${repair.length} 个未完成的工具调用补上结果，以便继续。`);
    return repair;
  }

  /**
   * 当前前台包名。`forceFresh` 为 true 时必须重新观测，不许吃缓存。
   *
   * 任务起跑时一定要 forceFresh。上一次观测是上一个任务留下的，而两个任务之间隔着
   * 用户打字的那段时间：本应用为了操作别的应用会把自己切到后台，桌面
   * （com.ohos.sceneboard）于是成为真正的前台。吃缓存会把"期望前台"设成上个任务的
   * 那个应用，然后模型第一个动作就被判成"用户抢走了屏幕"而暂停 —— 用户明明没碰手机。
   */
  private async currentBundle(forceFresh: boolean = false): Promise<string> {
    if (!forceFresh) {
      const obs = this.device.getLastObservation();
      if (obs !== null) {
        return obs.foregroundBundle;
      }
    }
    // 用不标记的那个读法：这一份是闸门自己看的，从不发给模型，不能算"模型看过的表"。
    return await this.device.foregroundBundleFresh();
  }

  /** 主循环。每一轮：发请求 → 处理回复 → 有 tool_use 就执行并继续。 */
  private async pump(): Promise<void> {
    while (!this.stopRequested) {
      // 折叠自己要发一次请求，失败就停下：继续发只会撞上同一个超限。
      if (!await this.maybeCompact()) {
        // 折叠中途被用户按停时不算失败，走和别处一致的停止提示。
        if (this.stopRequested) {
          this.emit('notice', '已停止。');
        }
        return;
      }
      if (this.stopRequested) {
        this.emit('notice', '已停止。');
        return;
      }

      const result = await this.sendOnce();
      if (this.stopRequested) {
        this.emit('notice', '已停止。');
        return;
      }
      if (!result.ok || result.turn === null) {
        // 这里曾有一条「上下文超限就压缩后重试」的分支。**不要加回来。**
        //
        // 它建立在一个我替所有端点做的假设上：超限时服务端会返回 400 并在文案里
        // 点明 prompt 过长。这只是 Anthropic 官方端点的行为，兼容端点没有义务遵守 ——
        // 换个端点可能报别的状态码、别的措辞，甚至截断了也不报错。靠猜错误文案来
        // 触发压缩，等于把一条不可靠的推断放进主循环。
        //
        // 现在压缩只由「压缩阈值」这个设置主动触发（默认 128000）。
        // 端点真的报 400 时，原样把它的报文交给用户，不再自作解释。
        if (result.errorKind === 'bad_request' && this.looksLikeImageRejection(result.errorMessage)) {
          // 端点不支持图片块（已知 DeepSeek 如此）。摘掉截图能力后重试，而不是让任务死掉。
          this.imagesRejected = true;
          this.dropImageBlocks();
          this.emit('notice', '这个端点不支持图片，已关闭截图能力并继续。');
          continue;
        }
        this.emit('error', `请求失败(${result.errorKind}): ${result.errorMessage}`);
        return;
      }

      const turn = result.turn;
      this.totalInput += turn.usage.inputTokens;
      this.totalOutput += turn.usage.outputTokens;
      this.totalCached += turn.usage.cacheReadInputTokens;
      this.hooks.onUsage(this.totalInput, this.totalOutput, this.totalCached);
      // 缓存命中与缓存创建的那部分同样占着窗口，不能只算 inputTokens，否则严重低估。
      // 加上 outputTokens 是因为这条回复已经进了历史，下一发要连它一起送。
      this.lastContextTokens = turn.usage.inputTokens +
        turn.usage.cacheCreationInputTokens +
        turn.usage.cacheReadInputTokens +
        turn.usage.outputTokens;

      // thinking 与 signature 必须原样回传，否则下一轮 400。这一步不可省。
      this.messages.push({ role: 'assistant', content: assistantTurnToBlocks(turn) });

      for (const part of turn.parts) {
        if (part.kind === 'thinking' && part.text.length > 0) {
          this.emit('thinking', part.text);
        } else if (part.kind === 'text' && part.text.trim().length > 0) {
          this.emit('model_text', part.text);
        }
      }

      const calls: ContentPart[] = [];
      for (const part of turn.parts) {
        if (part.kind === 'tool_use') {
          calls.push(part);
        }
      }

      if (calls.length === 0) {
        // 模型只说话没动手。给它一句提示而不是就此结束，否则任务会莫名停住。
        this.messages.push(userMessage([textBlock(
          '你没有调用任何工具。请继续操作，或者调用 done 结束任务。'
        )]));
        continue;
      }

      const resultBlocks: ApiBlock[] = [];
      let finished = false;
      for (const call of calls) {
        if (this.stopRequested) {
          break;
        }
        if (call.toolName === TOOL_DONE) {
          const verdict = this.todos.judgeDone();
          if (verdict.accept) {
            if (verdict.abandoned > 0) {
              this.emit('notice', `有 ${verdict.abandoned} 项计划未完成，已标记为放弃。`);
            }
            const args = this.parseArgs(call);
            const summary = args !== null && args.summary !== undefined ? args.summary : '（没有给出总结）';
            // done 也必须回一条 tool_result。早先这里直接 return，历史就永远停在
            // 一个没有配对结果的 tool_use 上；下次续聊时补齐逻辑会给它编一条
            // 「这一步没有执行：任务被中断」—— 任务其实是正常完成的，那句话是假的。
            resultBlocks.push({
              type: 'tool_result',
              tool_use_id: call.toolId,
              content: '任务已结束。',
              is_error: false
            });
            this.emit('finished', summary);
            this.hooks.onProgress(100, this.todos.summary());
            finished = true;
            break;
          }
          resultBlocks.push({
            type: 'tool_result',
            tool_use_id: call.toolId,
            content: verdict.reminder,
            is_error: false
          });
          this.emit('notice', '模型宣布完成但计划还有未勾项，已要求它自查。');
          continue;
        }

        const outcome = await this.executeSafely(call);
        resultBlocks.push({
          type: 'tool_result',
          tool_use_id: call.toolId,
          content: outcome.text,
          is_error: outcome.isError
        });
        if (outcome.imageBase64.length > 0) {
          // 图片作为 tool_result 的兄弟块放在同一条 user 消息里，
          // 这样不必把 ApiBlock.content 改成联合类型。
          resultBlocks.push({
            type: 'image',
            source: { type: 'base64', media_type: 'image/jpeg', data: outcome.imageBase64 }
          });
        }
      }

      // 收尾前也要把结果推进历史，否则末尾会留下没有配对结果的 tool_use。
      if (resultBlocks.length > 0) {
        this.appendUserBlocks(resultBlocks);
        this.pruneOldScreenshots();
      }
      if (finished) {
        return;
      }
      if (this.stopRequested) {
        this.emit('notice', '已停止。');
        return;
      }
    }
    this.emit('notice', '已停止。');
  }

  private looksLikeImageRejection(message: string): boolean {
    const lowered = message.toLowerCase();
    return lowered.indexOf('image') >= 0 &&
      (lowered.indexOf('not support') >= 0 || lowered.indexOf('unsupported') >= 0 ||
       lowered.indexOf('invalid') >= 0 || lowered.indexOf('expected') >= 0);
  }

  /** 把历史里的图片块换成一行文字。端点拒绝图片后必须清干净，否则每次重试都会再撞一次。 */
  private dropImageBlocks(): void {
    for (const msg of this.messages) {
      const kept: ApiBlock[] = [];
      for (const block of msg.content) {
        if (block.type === 'image') {
          kept.push(textBlock('（上面那张截图的画面已移除：当前端点不支持图片。）'));
        } else {
          kept.push(block);
        }
      }
      msg.content = kept;
    }
  }

  private parseArgs(call: ContentPart): ToolArgs | null {
    if (call.toolInputJson.length === 0) {
      return {};
    }
    try {
      return JSON.parse(call.toolInputJson) as ToolArgs;
    } catch (err) {
      return null;
    }
  }

  /**
   * 工具执行的唯一出口。任何异常都变成一条回给模型的 tool_result，绝不终止会话。
   *
   * 由来：命令超时原先会一路抛到 `run()` 的 catch，把整个任务判成「异常终止」。
   * 真机息屏实测中系统把应用降频到 2.4 倍慢，一条 `dumpLayout` 超过 20 秒上限，
   * 任务就死了 —— 而系统从头到尾没有取消长时任务，是我们自己先放弃的。
   *
   * 这里不做重试、不做退避、不设次数上限：重试、改计划还是收摊由模型决定。
   * 连续失败次数只作为信息一并告知，好让它判断该不该升级处理。
   */
  private async executeSafely(call: ContentPart): Promise<ToolOutcome> {
    try {
      const outcome = await this.execute(call);
      if (this.resumedFromPause) {
        // 「被用户打断过」不是「这一步失败了」。连续失败次数是给模型判断"是不是一直在
        // 撞同一个墙"用的，被打断一次就加一笔会污染它。也不清零：暂停之前若真在连续
        // 失败，那个事实没有因为一次暂停而消失。
        this.resumedFromPause = false;
        return outcome;
      }
      if (outcome.isError) {
        this.consecutiveToolFailures += 1;
      } else {
        this.consecutiveToolFailures = 0;
        this.syncExpectedBundle(call.toolName);
      }
      return outcome;
    } catch (err) {
      const message = (err as Error).message;
      // 用户主动停止不算工具失败：既不该说成「执行异常」，也不该计进连续失败次数 ——
      // 那个次数是给模型判断「是不是一直在撞同一个墙」用的，被停一次就加一笔会污染它。
      if (message.indexOf(CANCEL_REASON) >= 0) {
        this.emit('notice', `${call.toolName} 已取消。`);
        return { text: this.toolFailureText(call.toolName, message), isError: true, imageBase64: '' };
      }
      this.consecutiveToolFailures += 1;
      this.emit('notice',
        `工具 ${call.toolName} 执行异常（连续第 ${this.consecutiveToolFailures} 次），已交回模型判断: ${message}`);
      return { text: this.toolFailureText(call.toolName, message), isError: true, imageBase64: '' };
    }
  }

  /**
   * 动作做完之后，把"期望前台"对齐到动作留下的那个界面。
   *
   * 闸门要挡的是"模型在思考的这段时间里用户把屏幕抢走了"。所以基准必须是**我们自己
   * 上一个动作结束时**的前台，而不是任务开始时定下的某个应用 —— 模型点一下桌面图标、
   * 或者应用自己跳到另一个应用，前台都会合法地变，那些都不是用户抢屏幕。
   *
   * launch_app 已经在自己那儿把期望前台设成目标包名了，这里不覆盖它：启动动作返回时
   * 新应用可能还没完全顶到前台，此刻的观测有可能仍是旧界面。
   */
  private syncExpectedBundle(toolName: string): void {
    if (!isActionTool(toolName) || toolName === TOOL_LAUNCH_APP) {
      return;
    }
    const obs = this.device.getLastObservation();
    if (obs !== null && obs.foregroundBundle.length > 0 && obs.foregroundBundle !== this.ownBundle) {
      this.expectedBundle = obs.foregroundBundle;
    }
  }

  /**
   * 失败文案：只说清现象，不重复系统提示已经交代过的东西。
   *
   * 这里的每一个字都进历史段，会随后续每一轮请求反复重发，而系统提示那一段是缓存的、
   * 整个任务只付一次。所以凡是系统提示里已有的话（失败不终止任务、可选的三个动作、
   * 锁屏时重试无意义），都不在这里再说一遍。
   */
  private toolFailureText(toolName: string, message: string): string {
    const lines: string[] = [];
    // 「用户让停」不是「这一步失败了」。此时任务即将结束，不能给出重试建议 ——
    // 那会让续聊时的历史里留下一句「建议你重试」，而用户的意思正相反。
    if (message.indexOf(CANCEL_REASON) >= 0) {
      return `工具 ${toolName} 被取消：${message}。这不是失败，是任务被要求停止，不要重试。`;
    }
    lines.push(`工具 ${toolName} 没有执行成功：${message}`);
    // 只报次数，不加「任务没有结束，你可以继续」这类安抚。系统提示开头就写着
    // 「工具失败不会终止任务」，那句话在系统提示段里按缓存价付一次；写在这儿是进历史段，
    // 每次失败新增一份、此后每轮请求都要重发，说的还是同一件事。
    lines.push(`这是连续第 ${this.consecutiveToolFailures} 次工具失败。`);
    if (message.indexOf('超时') >= 0) {
      // 只留这一条独有信息：「息屏 → 系统降频 → 命令超时」这条因果链系统提示里没有，
      // 而它能让模型判断该等一下还是该换招。
      //
      // 原先这里还有一句「锁屏时动作全无效，重试没意义」，删了：一是系统提示已经写过，
      // 二是它根本到不了这里 —— 锁屏由 DeviceControl.guard 拦成 ok:false 的普通失败，
      // 而本函数只在工具抛异常时才被调用（见 executeSafely 的 catch）。
      lines.push('命令超时通常意味着设备变慢了。常见原因是屏幕已经熄灭，' +
        '系统把后台应用降频；也可能是设备正忙。');
    }
    // 不再罗列「重试 / 改计划 / done」三个选项：系统提示里已经逐字写过同样的三条。
    return lines.join('\n');
  }

  /** 执行一个 tool。所有闸门都在这里，不在各个动作方法里重复。 */
  private async execute(call: ContentPart): Promise<ToolOutcome> {
    const name = call.toolName;
    const args = this.parseArgs(call);
    if (args === null) {
      return { text: '参数不是合法的 JSON，请重新调用。', isError: true, imageBase64: '' };
    }
    this.emit('tool_call', this.describeCall(name, args), name);

    if (name === TOOL_TODO_WRITE) {
      const items = args.items === undefined ? [] : args.items;
      // 界面拿完整列表，模型只在我们改动过它提交的内容时才拿完整列表。理由见 RewriteResult。
      const written = this.todos.rewrite(items);
      this.reportProgress();
      this.emit('todo', written.display);
      return { text: written.forModel, isError: false, imageBase64: '' };
    }

    // 闸门一：没写计划不许动屏幕。观测类不拦，否则模型连现状都看不到。
    if (isActionTool(name) && !this.todos.hasPlan()) {
      return {
        text: '开始操作之前请先调用 todo_write 列出你的计划。',
        isError: true,
        imageBase64: ''
      };
    }

    if (isActionTool(name)) {
      const gate = await this.checkGates();
      if (gate.length > 0) {
        return { text: gate, isError: true, imageBase64: '' };
      }
    }

    if (name === TOOL_OBSERVE) {
      return this.fromAction(await this.device.observeScreen());
    }
    if (name === TOOL_SCREENSHOT) {
      if (this.imagesRejected) {
        return { text: '当前端点不支持图片，请改用 observe。', isError: true, imageBase64: '' };
      }
      const shot: ScreenshotResult = await this.device.screenshot();
      if (!shot.ok) {
        return { text: shot.detail, isError: true, imageBase64: '' };
      }
      this.screenshotSeq += 1;
      return { text: this.captionShot(), isError: false, imageBase64: shot.base64 };
    }
    if (name === TOOL_TAP) {
      return this.needIndex(args, (i: number) => this.device.tap(i));
    }
    if (name === TOOL_CLICK) {
      return await this.clickInside(args);
    }
    if (name === TOOL_LONG_PRESS) {
      return this.needIndex(args, (i: number) => this.device.longPress(i));
    }
    if (name === TOOL_DOUBLE_TAP) {
      return this.needIndex(args, (i: number) => this.device.doubleTap(i));
    }
    if (name === TOOL_SCROLL) {
      if (args.index === undefined || args.direction === undefined) {
        return { text: '缺少 index 或 direction。', isError: true, imageBase64: '' };
      }
      const dir = args.direction;
      if (dir !== 'up' && dir !== 'down' && dir !== 'left' && dir !== 'right') {
        return { text: `direction 只能是 up/down/left/right，收到 ${dir}。`, isError: true, imageBase64: '' };
      }
      return this.fromAction(await this.device.scroll(args.index, dir, args.amount));
    }
    if (name === TOOL_DRAG) {
      if (args.from_index === undefined || args.to_index === undefined) {
        return { text: '缺少 from_index 或 to_index。', isError: true, imageBase64: '' };
      }
      return this.fromAction(await this.device.drag(args.from_index, args.to_index));
    }
    if (name === TOOL_DRAW) {
      if (args.index === undefined || args.strokes === undefined) {
        return { text: '缺少 index 或 strokes。', isError: true, imageBase64: '' };
      }
      return this.fromAction(await this.device.draw(args.index, args.strokes));
    }
    if (name === TOOL_INPUT_TEXT) {
      if (args.index === undefined || args.text === undefined) {
        return { text: '缺少 index 或 text。', isError: true, imageBase64: '' };
      }
      return this.fromAction(await this.device.inputText(args.index, args.text));
    }
    if (name === TOOL_KEY) {
      if (args.name === undefined) {
        return { text: '缺少 name。', isError: true, imageBase64: '' };
      }
      return this.fromAction(await this.device.key(args.name, args.repeat));
    }
    if (name === TOOL_LAUNCH_APP) {
      if (args.app === undefined) {
        return { text: '缺少 app。', isError: true, imageBase64: '' };
      }
      const asked = args.app.trim();
      if (asked.length === 0) {
        return { text: '缺少 app。', isError: true, imageBase64: '' };
      }
      const resolved = await this.resolveApp(asked);
      if (typeof resolved === 'string') {
        return { text: resolved, isError: true, imageBase64: '' };
      }
      const target = resolved.bundleName;
      if (target === this.ownBundle) {
        return { text: '不能启动本应用，那会打断你自己。', isError: true, imageBase64: '' };
      }
      if (this.config.blacklistBundles.indexOf(target) >= 0) {
        return { text: `用户禁止进入 ${resolved.label}。`, isError: true, imageBase64: '' };
      }
      const res = await this.device.launchApp(target);
      if (res.ok) {
        // 主动切换应用是合法的，把期望前台更新掉，否则下一步会被当成"用户抢屏幕"。
        this.expectedBundle = target;
      }
      return this.fromAction(res);
    }
    if (name === TOOL_LIST_APPS) {
      // 只给名字，不给包名。实测这份列表原来是 7440 字符，占整段对话内容的 51%，
      // 其中包名占 5200、名字只占 1449 —— 贵的全是包名，而模型要包名只为了启动，
      // 现在 launch_app 直接收名字。198 个应用里只有一组重名（方舟Web 的两个内核组件，
      // 都不是能启动的应用），所以按名字定位几乎不会撞。
      const apps: AppEntry[] = await this.device.listApps();
      const names: string[] = [];
      for (const app of apps) {
        if (app.label.length > 0) {
          names.push(app.label);
        }
      }
      return { text: names.length === 0 ? '没有读到应用列表。' : names.join('\n'), isError: false, imageBase64: '' };
    }
    if (name === TOOL_WAIT) {
      // 不在这里夹取：夹取只在 DeviceControl.waitMs 一处做，并且会把截断如实告诉模型。
      return this.fromAction(await this.device.waitMs(args.ms === undefined ? 1000 : args.ms));
    }
    return { text: `未知的 tool: ${name}`, isError: true, imageBase64: '' };
  }

  /**
   * 把模型填的那串字解析成一个应用。名字优先，包名也认。
   *
   * 为什么让模型填名字：应用列表原来把包名一起发出去，7440 字符占整段对话内容的 51%，
   * 其中包名占 5200、名字只占 1449。而模型要包名只为了启动这一件事，所以包名不必经过
   * 它的手。198 个应用里只有一组重名（方舟Web 的两个内核组件，都不是能启动的应用）。
   *
   * 包名也认，是因为界面观测里的前台身份写的就是包名，模型会顺手用。
   */
  private async resolveApp(asked: string): Promise<AppEntry | string> {
    let apps: AppEntry[];
    try {
      apps = await this.device.listApps();
    } catch (err) {
      return `读不到应用列表：${(err as Error).message}`;
    }
    for (const app of apps) {
      if (app.bundleName === asked) {
        return app;
      }
    }
    const hits: AppEntry[] = [];
    for (const app of apps) {
      if (app.label === asked) {
        hits.push(app);
      }
    }
    if (hits.length === 1) {
      return hits[0];
    }
    if (hits.length > 1) {
      const bundles: string[] = [];
      for (const app of hits) {
        bundles.push(app.bundleName);
      }
      return `有 ${hits.length} 个应用都叫"${asked}"：${bundles.join('、')}。填包名指定一个。`;
    }
    return `没有找到"${asked}"。`;
  }

  private async needIndex(
    args: ToolArgs,
    run: (index: number) => Promise<ActionResult>
  ): Promise<ToolOutcome> {
    if (args.index === undefined) {
      return { text: '缺少 index。', isError: true, imageBase64: '' };
    }
    return this.fromAction(await run(args.index));
  }

  /**
   * 点元素内部某个位置，然后自动附一张截图回去。
   *
   * 自动附图不是省事，是必需：这个动作的目标画在控件内部，它的状态同样不在界面树里
   * （实测备忘录待办勾选前后 RichEditor 的 text 一字不差），所以界面观测永远无法
   * 判断点中没有。不附图就等于让模型盲点。
   *
   * 附图也顺带省掉一个往返：模型不必再单独调一次 screenshot。
   */
  private async clickInside(args: ToolArgs): Promise<ToolOutcome> {
    if (args.index === undefined || args.x === undefined || args.y === undefined) {
      return { text: '缺少 index、x 或 y。', isError: true, imageBase64: '' };
    }
    if (args.x < 0 || args.x > 1 || args.y < 0 || args.y > 1) {
      return {
        text: `x 和 y 是 0~1 的比例，收到 ${args.x},${args.y}。`,
        isError: true,
        imageBase64: ''
      };
    }
    const res = await this.device.clickInside(args.index, args.x, args.y);
    this.emit('tool_result', res.detail);
    if (!res.ok) {
      return { text: res.detail, isError: true, imageBase64: '' };
    }
    const shot: ScreenshotResult = await this.device.screenshot();
    if (!shot.ok) {
      // 点击本身做完了，只是没截到图。如实说，不要说成失败。
      return {
        text: `${res.detail}\n（点完的确认截图没截到：${shot.detail}）`,
        isError: false,
        imageBase64: ''
      };
    }
    this.screenshotSeq += 1;
    return {
      text: `${res.detail}\n${this.captionShot()}`,
      isError: false,
      imageBase64: shot.base64
    };
  }

  private fromAction(res: ActionResult): ToolOutcome {
    this.emit('tool_result', res.detail);
    return { text: res.detail, isError: !res.ok, imageBase64: '' };
  }

  /**
   * 截图那条 tool_result 的正文。只干一件事：说清这一张拍的是哪个界面。
   *
   * 为什么必须在这里写：screenshot 的入参是空 schema，所以历史里的调用记录就是一个
   * 光秃秃的 `screenshot({})`，本身不含任何信息。图片块一旦被剪掉、被端点拒收、
   * 或者因为存盘而丢失，这一轮就只剩下这行文字 —— 它要是写"截图如下"，
   * 那张图拍的是什么就彻底查无可考了。
   *
   * 收录标准是**能不能认出这张拍的是哪个界面**，不是"这个字段现成能拿到"。
   * 按这个标准只留两样：编号（让摘要能在时间线里引用它、让占位说明能指回它）、
   * 前台应用与页面（这就是界面的身份）。
   *
   * 弹窗、键盘这类瞬时状态一概不写：它们描述的是当时屏幕的状态而不是身份，
   * 换个时刻就变了，对"这张拍的是哪儿"没有帮助，而且观测结果里本来就有，
   * 写进来只是把同一件事说两遍。界面上有什么内容同理，那是观测的活。
   */
  private captionShot(): string {
    const obs = this.device.getLastObservation();
    if (obs === null || obs.foregroundBundle.length === 0) {
      return `第 ${this.screenshotSeq} 张截图，画面如下。`;
    }
    const page = obs.foregroundAbility.length > 0 ?
      `${obs.foregroundBundle} / ${obs.foregroundAbility}` : obs.foregroundBundle;
    return `第 ${this.screenshotSeq} 张截图，前台 ${page}，画面如下。`;
  }

  /**
   * 动作前的闸门：锁屏、前台失配、黑名单。
   * 返回空串表示放行，否则返回要回给模型的拒绝理由。
   */
  private async checkGates(): Promise<string> {
    const state = await this.device.quickState();
    if (state.locked) {
      this.interruptForScreen('设备已锁屏');
      return '设备已锁屏，任务中断。';
    }
    // 「目标页面还在不在最上面」必须**新鲜地**读，但完整观测要 1.2~2.2 秒，
    // 每个动作前都读一次太贵。所以先用焦点窗口 id 当筛子：
    // 它由上面这次 quickState 顺带带回（WMS 转储，几百毫秒，本来就在跑），
    // 用户切走时这个 id 必然变，应用内翻页通常不变。
    //
    // 没变就直接用缓存那份观测放行。变了才花一次完整观测确认 ——
    // 只有筛子和确认都指向"换人了"才暂停，避免应用内新开窗口造成误暂停。
    //
    // 为什么不能只靠缓存：缓存是上一个动作刚结束时的样子，而用户抢屏幕发生在
    // 模型思考的那几十秒里。更要紧的是，"期望前台"也是从同一份缓存里取的，
    // 两个值恒等，这个判据曾因此完全失效过。
    const focusChanged = state.focusWindowId.length > 0 &&
      state.focusWindowId !== this.lastFocusWindowId;
    const bundle = await this.currentBundle(focusChanged);
    if (bundle.length > 0 && this.config.blacklistBundles.indexOf(bundle) >= 0) {
      return `当前前台是被禁止的应用 ${bundle}，不能在这里操作。请先离开它。`;
    }
    this.lastFocusWindowId = state.focusWindowId;
    if (focusChanged && this.expectedBundle.length > 0 && bundle.length > 0 &&
      bundle !== this.expectedBundle) {
      this.emit('paused', `前台变成了 ${bundle}，可能是用户在用手机。已暂停。`);
      const go = await this.hooks.waitForResume(`前台应用变成了 ${bundle}，要继续吗？`);
      if (!go) {
        this.stopRequested = true;
        return '用户选择了放弃任务。';
      }
      this.emit('notice', '已继续。');
      // 期望前台清空，由恢复后的第一个动作重新确立。留着暂停前那个值没有意义：
      // 用户点「继续」时人正看着本应用，屏幕早不是暂停那一刻的样子了。
      // 焦点 id 也清空：恢复之后的第一次闸门必须重新读一遍，不能沿用暂停前那一笔。
      this.lastFocusWindowId = '';
      this.expectedBundle = '';
      this.resumedFromPause = true;
      // 待执行的那个动作不放行。它带的元素编号来自暂停之前那次观测，
      // 而暂停期间用户在别处操作过手机，按旧编号点下去就是照着旧坐标乱点。
      return RESUME_NOTICE;
    }
    return '';
  }

  /**
   * 锁屏一律中断，不再等解锁。
   *
   * 旧行为是「唤亮屏幕、请用户解锁、等到解锁或超时」，其中主动唤亮屏幕这一步
   * 与「用户看不见就停」的规则正面冲突：用户熄屏本身就是要它停手。
   */
  private interruptForScreen(reason: string): void {
    if (this.interrupted) {
      return;
    }
    this.interrupted = true;
    this.stopRequested = true;
    this.api.abort();
    // 长等待会分片检查这个标记，否则一觉睡完之前中断根本落不了地。
    this.device.requestCancel();
    this.emit('interrupted', `${reason}，任务已中断。发消息可以接着上次继续。`);
  }

  private describeCall(name: string, args: ToolArgs): string {
    if (name === TOOL_TAP && args.index !== undefined) {
      return `点击 ${args.index}`;
    }
    if (name === TOOL_INPUT_TEXT && args.index !== undefined) {
      return `在 ${args.index} 输入「${args.text === undefined ? '' : args.text}」`;
    }
    if (name === TOOL_SCROLL && args.index !== undefined) {
      return `滚动 ${args.index} 向 ${args.direction === undefined ? '?' : args.direction}`;
    }
    if (name === TOOL_KEY) {
      return `按键 ${args.name === undefined ? '?' : args.name}`;
    }
    if (name === TOOL_LAUNCH_APP) {
      return `启动 ${args.app === undefined ? '?' : args.app}`;
    }
    if (name === TOOL_WAIT) {
      return `等待 ${args.ms === undefined ? 0 : args.ms} 毫秒`;
    }
    return name;
  }

  private async sendOnce(): Promise<ApiResult> {
    const sink: StreamSink = {
      onTextDelta: (delta: string) => {
        // 逐字显示交给界面自己攒，这里不发事件，避免时间线被刷爆
      },
      onToolUseStart: (toolName: string) => {
        // tool_call 事件在 execute 里发，带参数，比这里更有用
      }
    };
    const options: SendOptions = {
      endpoint: this.config.endpoint,
      apiKey: this.config.apiKey,
      model: this.config.model,
      maxTokens: this.config.maxTokens,
      systemPrompt: this.systemPrompt,
      messages: this.messages,
      tools: this.imagesRejected ? buildTools(false) : this.tools,
      maxRetries: this.limits.maxRetries,
      connectTimeoutMs: this.limits.connectTimeoutMs,
      readTimeoutMs: this.limits.readTimeoutMs,
      enablePromptCache: this.config.enablePromptCache
    };
    return await this.api.send(options, sink);
  }

  /**
   * 达到阈值就折叠。这是**唯一**的折叠触发点。
   * 返回 false 表示折叠失败、任务应当停下（错误已经发过了）。
   */
  private async maybeCompact(): Promise<boolean> {
    const trigger = this.compactionTrigger();
    if (trigger <= 0 || this.lastContextTokens < trigger) {
      return true;
    }
    return await this.compactNow();
  }

  /**
   * 真正的折叠触发点：设置里的阈值减去单次回复上限。
   *
   * 减这一笔是给回复留地方。阈值填的是"上下文最多涨到多少"，而下一发请求除了整段
   * 历史还得装得下模型这一轮的回复；不减，折叠就会挑在窗口刚好被填满的那一刻动手，
   * 那时已经晚了。
   *
   * 返回 0 表示不折叠，两种情况：阈值填 0 是用户明确关闭；减出 0 或负数说明阈值比
   * 回复上限还小、凑不出合理位置。这两种情况下都没有任何兜底，历史会一直涨到端点
   * 自己报错为止 —— 这是明确的取舍，不在这里自作主张改用别的数字。
   */
  private compactionTrigger(): number {
    if (this.config.contextLimitTokens <= 0) {
      return 0;
    }
    const trigger = this.config.contextLimitTokens - this.config.maxTokens;
    return trigger > 0 ? trigger : 0;
  }

  /**
   * 折叠历史：把早先的对话交给模型写成一份摘要，用摘要替换那一段。
   *
   * 折完的形状是 `[摘要, 最近若干个来回]`。任务原话不单独保留，它折进摘要的
   * 「任务目标」段 —— 压缩提示词里专门交代了原话不再保留、目标必须照抄。
   * 也不再单独注入计划：计划本来就在保留的来回里，而且摘要的「下一步」段会覆盖它。
   *
   * 失败不回退。写不出摘要就报错停下，没有"退化成机械拼接"这条路：机械拼接只留得下
   * 动作流水，模型说过的话、看过的界面全丢，醒来后会重走已经证明走不通的路。
   */
  private async compactNow(): Promise<boolean> {
    const cut = this.compactionCut();
    if (cut <= 0) {
      // 上下文已经超过阈值，但对话才几个来回 —— 是单个来回本身太大（一轮里截了好几张图，
      // 或者观测结果极长），能折的东西太少，折了也降不下来。
      //
      // 这里不发提示：按对齐结论静默处理。这个状态每一轮都成立，说了就得防重复，
      // 而它本身也不需要用户做什么。请求原样发出去，超限就由端点自己报错。
      return true;
    }
    const folded = this.messages.slice(0, cut);
    const tail = this.messages.slice(cut);
    this.emit('notice', '正在压缩上下文…');
    const summary = await this.requestSummary(folded);
    if (summary.length === 0) {
      return false;
    }
    this.messages = [userMessage([textBlock(summary)])].concat(tail);
    // 折完之后新历史有多大，只有下一个回包知道。留着旧数字会让下一轮又立刻折一次。
    this.lastContextTokens = 0;
    this.emit('notice', `已压缩上下文，折叠了 ${folded.length} 条历史。`);
    return true;
  }

  /**
   * 算切口：`[0, cut)` 交给摘要，`[cut, end)` 原样留着。返回 0 表示不值得折。
   *
   * 切口必须落在 assistant 消息上，有两个原因，缺一不可：
   * · 留下的第一条是 assistant（装着 tool_use），它的 tool_result 在紧随其后那条
   *   user 里，配对完整。切在 user 上就把结果和调用切散了，服务端直接 400。
   * · 折完的第一条是摘要（user 角色），后面接 assistant 才满足角色交替。
   *   切在 user 上会拼出连着两条 user，同样 400。
   */
  private compactionCut(): number {
    const keep = this.limits.keepRecentRounds * 2;
    const total = this.messages.length;
    // 至少要能折掉一个完整来回才划得来。
    if (total <= keep + 2) {
      return 0;
    }
    let cut = total - keep;
    if (this.messages[cut].role !== 'assistant') {
      // 角色严格交替，所以前一条必然是 assistant。
      cut -= 1;
    }
    return cut > 0 ? cut : 0;
  }

  /**
   * 发一次摘要请求。返回空串表示失败（错误已经发过事件）。
   *
   * 不声明任何 tool：拍平之后请求里没有 tool_use 块，声明工具只会多花 token，
   * 还给了模型"不写摘要改去点屏幕"的机会。也不发缓存标记 —— 一次性请求，
   * 缓存没有收益，反倒可能在不支持的路由上引来 400。
   */
  private async requestSummary(folded: ApiMessage[]): Promise<string> {
    const blocks = this.flattenForSummary(folded);
    if (blocks.length === 0) {
      this.emit('error', '压缩失败：要折叠的这段历史没有可用内容。');
      return '';
    }
    const sink: StreamSink = {
      onTextDelta: (delta: string) => {
        // 摘要正文不逐字上屏，避免时间线被一大段结构化文本刷爆
      },
      onToolUseStart: (toolName: string) => {
        // 摘要请求没声明 tool，走到这里说明端点不老实，交给下面的空文本判定处理
      }
    };
    const options: SendOptions = {
      endpoint: this.config.endpoint,
      apiKey: this.config.apiKey,
      model: this.config.model,
      maxTokens: this.config.maxTokens,
      systemPrompt: buildCompactionPrompt(),
      messages: [userMessage(blocks)],
      tools: [],
      maxRetries: this.limits.maxRetries,
      connectTimeoutMs: this.limits.connectTimeoutMs,
      readTimeoutMs: this.limits.readTimeoutMs,
      enablePromptCache: false
    };
    const result = await this.api.send(options, sink);
    if (this.stopRequested) {
      return '';
    }
    if (!result.ok || result.turn === null) {
      this.emit('error', `压缩失败(${result.errorKind})：${result.errorMessage}`);
      return '';
    }
    const pieces: string[] = [];
    for (const part of result.turn.parts) {
      if (part.kind === 'text' && part.text.trim().length > 0) {
        pieces.push(part.text);
      }
    }
    const summary = pieces.join('\n').trim();
    if (summary.length === 0) {
      // 思考吃光了输出额度，或者模型不写摘要改去调工具，都会落到这里。
      // 不给调参建议：正文为空有两个原因（思考吃光额度、模型改去调工具），
      // 一句建议对不上两种原因，猜错就是把人往沟里带。
      this.emit('error', '压缩失败：模型没有返回摘要正文。');
      return '';
    }
    return summary.startsWith(SUMMARY_HEADER) ? summary : `${SUMMARY_HEADER}\n\n${summary}`;
  }

  /**
   * 把要折掉的那段拍平成一条 user 消息的内容块：文字变成带前缀的纯文本，
   * 图片块原样穿在中间。
   *
   * 不直接把原始消息发给摘要模型，是因为那样请求里会带着 thinking 与 tool_use 块，
   * 而 doc/anthropic-api.md 记着好几个真实 400 都在这一带：Anthropic 要求 thinking
   * 原样回传、DeepSeek 根本不支持 redacted_thinking、思考模式下每条 assistant 消息
   * 都必须带思考块。拍平之后这些都只是普通文字，摘要请求退化成"一条 user 消息里有些
   * 文字和几张图"，是最不容易被端点挑刺的形状。
   *
   * 不截断任何内容：工具输出该有多长就多长。屏幕观测在产出时已经自己限过长度
   * （见 Observer 的标签截断与列表上限），这里再截一刀只会凭空丢信息。
   */
  private flattenForSummary(folded: ApiMessage[]): ApiBlock[] {
    const out: ApiBlock[] = [];
    let pending: string[] = [];
    for (const msg of folded) {
      for (const block of msg.content) {
        if (block.type === 'image') {
          if (pending.length > 0) {
            out.push(textBlock(pending.join('\n')));
            pending = [];
          }
          out.push(block);
          continue;
        }
        const line = AgentLoop.describeForSummary(msg.role, block);
        if (line.length > 0) {
          pending.push(line);
        }
      }
    }
    if (pending.length > 0) {
      out.push(textBlock(pending.join('\n')));
    }
    return out;
  }

  /** 一个内容块拍平成一行带前缀的文字。返回空串表示这个块不值得带进摘要。 */
  private static describeForSummary(role: string, block: ApiBlock): string {
    if (block.type === 'text') {
      const text = block.text !== undefined ? block.text : '';
      if (text.length === 0) {
        return '';
      }
      // 上一次折叠留下的摘要不能加 [用户] 前缀。它虽然占着 user 角色，却不是用户说的话，
      // 而压缩提示词是靠「以 SUMMARY_HEADER 开头」认出它的 —— 前面加了前缀就认不出，
      // 模型会把上一份摘要当成用户的原话，合并规则整条失效。
      if (text.startsWith(SUMMARY_HEADER)) {
        return text;
      }
      return role === 'user' ? `[用户]: ${text}` : `[agent]: ${text}`;
    }
    if (block.type === 'thinking') {
      const think = block.thinking !== undefined ? block.thinking : '';
      return think.length === 0 ? '' : `[agent 思考]: ${think}`;
    }
    if (block.type === 'redacted_thinking') {
      return '[agent 思考]: （这一段思考被端点加密，内容不可见）';
    }
    if (block.type === 'tool_use') {
      const name = block.name !== undefined ? block.name : '未知工具';
      const input = block.input !== undefined ? JSON.stringify(block.input) : '{}';
      return `[agent 操作]: ${name}(${input})`;
    }
    if (block.type === 'tool_result') {
      const body = block.content !== undefined ? block.content : '';
      return block.is_error === true ? `[结果·失败]: ${body}` : `[结果]: ${body}`;
    }
    return '';
  }

  /**
   * 只保留最近若干张截图，更早的换成一行文字。每次追加工具结果之后跑一遍。
   *
   * 截图是历史里最占地方的东西：一张原生分辨率的 jpeg 转成 base64 可达数百 KB。
   * 不剪的话上下文涨得极快，折叠会被频繁触发，而每折一次就要多花一次摘要请求。
   */
  private pruneOldScreenshots(): void {
    const keep = this.config.keepRecentScreenshots;
    // 0 就是不裁剪、全部保留。**不要改回 `keep < 0`。**
    //
    // 这里跑在请求发出之前，所以 keep=0 那一版连"刚拍的那张"也会被换成文字
    // （`seen` 从 1 起，`1 <= 0` 不成立），结果 screenshot 与 click 两个工具
    // 一起变成废功能：模型永远只收到一句"画面已移除"。
    if (keep <= 0) {
      return;
    }
    let seen = 0;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const msg = this.messages[i];
      const kept: ApiBlock[] = [];
      let touched = false;
      // 一条消息里可能有多张图（同一轮并行截了几次），所以块也要从后往前数。
      for (let j = msg.content.length - 1; j >= 0; j--) {
        const block = msg.content[j];
        if (block.type !== 'image') {
          kept.unshift(block);
          continue;
        }
        seen += 1;
        if (seen <= keep) {
          kept.unshift(block);
          continue;
        }
        // 说明必须指回上一行。图片块总是紧跟在它自己那条 tool_result 之后，
        // 而那条 tool_result 写着第几张、前台哪个应用哪个页面（见 captionShot），
        // 所以"上面那行"就是这张图的完整身份，不需要在这里重复一遍。
        //
        // 只陈述事实，不加建议。写"可以再截一次"是骗它做办不到的事（那是当时的画面），
        // 写"再截也拍不回来"又是在教它一件它没问的常识。
        kept.unshift(textBlock('（上面那张截图的画面已移除，只剩说明文字。）'));
        touched = true;
      }
      if (touched) {
        this.messages[i] = { role: msg.role, content: kept };
      }
    }
  }
}

export { RUNNING_PERCENT_CAP };
