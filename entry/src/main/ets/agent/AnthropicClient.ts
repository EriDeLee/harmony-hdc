/**
 * Anthropic Messages API 客户端（流式 SSE）。
 *
 * 关于传输方式的更正：对齐时定的是用 rcp（RemoteCommunicationKit），但本机 SDK 里
 * **没有** `@kit.RemoteCommunicationKit`，所以改用 `@kit.NetworkKit` 的 http。
 * 流式能力由 `requestInStream` + `on('dataReceive')` 提供，分片是 ArrayBuffer，
 * 用 `util.TextDecoder` 以 stream 模式解码（分片会切断多字节字符，与项目里
 * HdcUnityCommandChannel 的做法一致）。
 *
 * 设计要点：
 * - 端点必填、模型手填，一律来自 AgentConfig，本文件不预设任何默认值。
 * - 系统提示与 tool 定义上打缓存断点：这两段每一步都重复发送，是省钱的主要部分。
 *   会话历史被压缩时只会让历史那一段的缓存失效一次，系统与 tools 段不受影响。
 * - 不抛异常表达业务失败，改用 ApiResult 返回错误种类，便于上层区分"该压缩重试"
 *   与"该停下来问用户"。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import type { BusinessError } from '@kit.BasicServicesKit';
import type { LogSink } from '../hdc/HdcConnection';

/** 协议版本号，与 hdc 的 DEFAULT_VERSION 同性质：属于协议约定，不是可调参数。 */
const ANTHROPIC_VERSION: string = '2023-06-01';
const MESSAGES_PATH: string = '/v1/messages';
const CACHE_EPHEMERAL: string = 'ephemeral';
/** 与 AgentSettings 的默认值一致；options.maxTokens 非法时的兜底。 */
const DEFAULT_MAX_TOKENS: number = 32768;

export type ApiErrorKind =
  'none' | 'auth' | 'rate_limit' | 'server' | 'network' | 'bad_request' | 'aborted';

/** 一个内容块。用单一结构而非联合类型，便于在 ArkTS 里组装与序列化。 */
export interface ContentPart {
  /** 'text' | 'tool_use' | 'thinking' | 'redacted_thinking'。 */
  kind: string;
  text: string;
  toolId: string;
  toolName: string;
  /** tool_use 的参数原文（JSON 字符串），由 input_json_delta 拼接而成。 */
  toolInputJson: string;
  /**
   * thinking 块的签名。**必须原样回传**：Opus 5 默认开启 thinking，若下一轮请求里
   * 的 assistant 消息没有以 thinking 块开头，服务端会直接 400
   * （Expected `thinking` or `redacted_thinking`, but found `tool_use`）。
   */
  signature: string;
  /** redacted_thinking 的密文，人不可读但同样必须原样回传。 */
  redactedData: string;
}

function emptyPart(kind: string): ContentPart {
  return {
    kind,
    text: '',
    toolId: '',
    toolName: '',
    toolInputJson: '',
    signature: '',
    redactedData: ''
  };
}

export interface ApiUsage {
  inputTokens: number;
  outputTokens: number;
  cacheCreationInputTokens: number;
  cacheReadInputTokens: number;
}

export interface AssistantTurn {
  parts: ContentPart[];
  stopReason: string;
  usage: ApiUsage;
}

export interface ApiResult {
  ok: boolean;
  turn: AssistantTurn | null;
  errorKind: ApiErrorKind;
  errorMessage: string;
  httpStatus: number;
}

// ---------- 请求体结构 ----------

interface CacheControl {
  type: string;
}

interface ImageSource {
  type: string;
  media_type: string;
  data: string;
}

/**
 * 请求侧的内容块。各种块类型字段并集放在一个结构里，未赋值的字段
 * 会被 JSON.stringify 自动省略，避免在 ArkTS 里为每种块写一套联合类型。
 */
export interface ApiBlock {
  type: string;
  text?: string;
  source?: ImageSource;
  tool_use_id?: string;
  content?: string;
  is_error?: boolean;
  id?: string;
  name?: string;
  input?: Object;
  /** thinking 块正文 */
  thinking?: string;
  /** thinking 块签名，回传时不可改动 */
  signature?: string;
  /** redacted_thinking 块密文，回传时不可改动 */
  data?: string;
  cache_control?: CacheControl;
}

export interface ApiMessage {
  role: string;
  content: ApiBlock[];
}

export interface ApiTool {
  name: string;
  description: string;
  input_schema: Object;
  cache_control?: CacheControl;
}

/**
 * 请求体。**这里刻意只包含各家 Anthropic 兼容端点行为一致的字段。**
 *
 * 被排除的推理控制字段及原因：
 * - `output_config.effort`：官方与 DeepSeek 读这里，阿里百炼读顶层 `reasoning_effort`。
 *   两个都发会让官方端点 400（`Extra inputs are not permitted`），只发一个又会被
 *   另一派静默忽略，而响应体不回显生效值，客户端无法验证。
 * - `thinking.type`：六家都收这个字段，但没有一个取值是全都接受的 —— `enabled`
 *   被 Kiro 上游 400，`adaptive` 只有官方认，`disabled` 会被 Kimi K3 拒绝。
 * - `thinking.budget_tokens`：DeepSeek 明确忽略。
 * - `temperature` / `top_p` / `top_k`：Kimi 会按 0.6 重新缩放，K3 干脆锁死为
 *   服务端默认值，`top_k` 被 DeepSeek 忽略。同一个数字在各家含义不同。
 *
 * 一概不发，全部采用上游默认值。代价是本地没有推理强度旋钮，换来的是不必为任何
 * 一家开分支。详见 doc/anthropic-api.md。
 */
interface ApiRequestBody {
  model: string;
  /**
   * 必发。官方 Anthropic 端点把它列为必填，缺了直接 400；
   * 国内兼容端点则一律标为完全支持。这是唯一必须由客户端给值的参数。
   */
  max_tokens: number;
  stream: boolean;
  /** 字符串或 TextBlock 数组。只有数组形式能携带 cache_control。 */
  system?: Object;
  messages: ApiMessage[];
  tools?: ApiTool[];
}

export interface SendOptions {
  endpoint: string;
  apiKey: string;
  model: string;
  /** 单次回复上限。必发字段；<=0 时回落到 DEFAULT_MAX_TOKENS。 */
  maxTokens: number;
  systemPrompt: string;
  messages: ApiMessage[];
  tools: ApiTool[];
  /** 重试次数上限（不含首次）。 */
  maxRetries: number;
  connectTimeoutMs: number;
  /** 流式读取超时；长任务需要足够大。 */
  readTimeoutMs: number;
  /**
   * 是否发送 cache_control。国内兼容端点对它的支持未文档化，部分网关在路由不支持
   * 缓存时直接返回 400，所以要能关掉。关闭时 system 会退化为纯字符串形式，
   * 那是兼容性最好的写法。
   */
  enablePromptCache: boolean;
}

export interface StreamSink {
  /** 模型文字增量，用于界面上边生成边显示。 */
  onTextDelta: (delta: string) => void;
  /** 模型开始调用某个 tool，用于提前显示"正在做什么"。 */
  onToolUseStart: (toolName: string) => void;
}

// ---------- SSE 解析 ----------

interface SseEvent {
  event: string;
  data: string;
}

/**
 * 从缓冲区里切出完整的 SSE 事件，返回剩余不完整的尾巴。
 * 事件之间以空行分隔；跨分片的半个事件必须留在缓冲区里。
 * 导出以便离线用真实报文验证。
 */
export function parseSseChunks(buffer: string): SseEventBatch {
  const events: SseEvent[] = [];
  let rest = buffer;
  while (true) {
    const at = rest.indexOf('\n\n');
    if (at < 0) {
      break;
    }
    const raw = rest.substring(0, at);
    rest = rest.substring(at + 2);
    let name = '';
    let data = '';
    for (const line of raw.split('\n')) {
      const trimmed = line.replace(/\r$/, '');
      if (trimmed.startsWith('event:')) {
        name = trimmed.substring(6).trim();
      } else if (trimmed.startsWith('data:')) {
        // 同一事件可能有多行 data，按 SSE 规范用换行拼接
        const piece = trimmed.substring(5).trim();
        data = data.length === 0 ? piece : `${data}\n${piece}`;
      }
    }
    if (name.length > 0 || data.length > 0) {
      events.push({ event: name, data });
    }
  }
  return { events, rest };
}

export interface SseEventBatch {
  events: SseEvent[];
  rest: string;
}

// ---------- 流式事件的负载结构 ----------

interface DeltaPayload {
  type?: string;
  text?: string;
  partial_json?: string;
  /** thinking_delta 携带的正文 */
  thinking?: string;
  /** signature_delta 携带的签名 */
  signature?: string;
  stop_reason?: string;
}

interface UsagePayload {
  input_tokens?: number;
  output_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
}

interface MessagePayload {
  usage?: UsagePayload;
  stop_reason?: string;
}

interface BlockStartPayload {
  type?: string;
  id?: string;
  name?: string;
  text?: string;
  thinking?: string;
  signature?: string;
  data?: string;
}

interface ErrorPayload {
  type?: string;
  message?: string;
}

interface StreamEventPayload {
  type?: string;
  index?: number;
  delta?: DeltaPayload;
  message?: MessagePayload;
  content_block?: BlockStartPayload;
  usage?: UsagePayload;
  error?: ErrorPayload;
}

interface ErrorEnvelope {
  error?: ErrorPayload;
}

/** 把流式事件累积成一个完整回复。导出以便用录制的报文离线验证。 */
export class TurnAssembler {
  private readonly parts: ContentPart[] = [];
  private stopReason: string = '';
  private usage: ApiUsage = {
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationInputTokens: 0,
    cacheReadInputTokens: 0
  };
  private readonly sink: StreamSink | null;

  constructor(sink: StreamSink | null) {
    this.sink = sink;
  }

  private mergeUsage(u: UsagePayload | undefined): void {
    if (u === undefined) {
      return;
    }
    if (u.input_tokens !== undefined) {
      this.usage.inputTokens = u.input_tokens;
    }
    if (u.output_tokens !== undefined) {
      this.usage.outputTokens = u.output_tokens;
    }
    if (u.cache_creation_input_tokens !== undefined) {
      this.usage.cacheCreationInputTokens = u.cache_creation_input_tokens;
    }
    if (u.cache_read_input_tokens !== undefined) {
      this.usage.cacheReadInputTokens = u.cache_read_input_tokens;
    }
  }

  /** 返回错误信息，或 null 表示正常。 */
  feed(event: string, data: string): string | null {
    if (data.length === 0) {
      return null;
    }
    let payload: StreamEventPayload;
    try {
      payload = JSON.parse(data) as StreamEventPayload;
    } catch (err) {
      return `无法解析流式事件: ${(err as Error).message}`;
    }
    const kind = payload.type !== undefined ? payload.type : event;
    if (kind === 'error') {
      const message = payload.error !== undefined && payload.error.message !== undefined ?
        payload.error.message : '服务端返回了未说明的错误';
      return message;
    }
    if (kind === 'message_start') {
      if (payload.message !== undefined) {
        this.mergeUsage(payload.message.usage);
      }
      return null;
    }
    if (kind === 'content_block_start') {
      const block = payload.content_block;
      const blockType = block !== undefined && block.type !== undefined ? block.type : 'text';
      if (blockType === 'tool_use') {
        const name = block !== undefined && block.name !== undefined ? block.name : '';
        const part = emptyPart('tool_use');
        part.toolId = block !== undefined && block.id !== undefined ? block.id : '';
        part.toolName = name;
        this.parts.push(part);
        if (this.sink !== null) {
          this.sink.onToolUseStart(name);
        }
      } else if (blockType === 'thinking') {
        const part = emptyPart('thinking');
        part.text = block !== undefined && block.thinking !== undefined ? block.thinking : '';
        part.signature = block !== undefined && block.signature !== undefined ? block.signature : '';
        this.parts.push(part);
      } else if (blockType === 'redacted_thinking') {
        const part = emptyPart('redacted_thinking');
        part.redactedData = block !== undefined && block.data !== undefined ? block.data : '';
        this.parts.push(part);
      } else {
        const part = emptyPart('text');
        part.text = block !== undefined && block.text !== undefined ? block.text : '';
        this.parts.push(part);
      }
      return null;
    }
    if (kind === 'content_block_delta') {
      if (this.parts.length === 0) {
        return null;
      }
      const current = this.parts[this.parts.length - 1];
      const delta = payload.delta;
      if (delta === undefined) {
        return null;
      }
      if (delta.text !== undefined) {
        current.text += delta.text;
        if (this.sink !== null) {
          this.sink.onTextDelta(delta.text);
        }
      }
      if (delta.partial_json !== undefined) {
        current.toolInputJson += delta.partial_json;
      }
      // thinking 的正文与签名分别由 thinking_delta 与 signature_delta 送达，
      // 两者都要收，签名缺失会导致下一轮被 400 拒绝。
      if (delta.thinking !== undefined) {
        current.text += delta.thinking;
      }
      if (delta.signature !== undefined) {
        current.signature += delta.signature;
      }
      return null;
    }
    if (kind === 'message_delta') {
      if (payload.delta !== undefined && payload.delta.stop_reason !== undefined) {
        this.stopReason = payload.delta.stop_reason;
      }
      this.mergeUsage(payload.usage);
      return null;
    }
    return null;
  }

  result(): AssistantTurn {
    return { parts: this.parts, stopReason: this.stopReason, usage: this.usage };
  }
}

/**
 * 把模型这一轮的回复转回请求侧的 content 数组，用于携带 tool_result 的下一轮。
 *
 * 这一步是带工具的多轮对话能否成立的关键：Opus 5 默认开启 thinking，
 * 官方要求"返回 tool_result 时必须把该 assistant 消息的 thinking 块完整且未经修改地回传"，
 * 否则服务端报 `Expected thinking or redacted_thinking, but found tool_use` 并 400。
 * 所以 thinking 与 redacted_thinking 一律按原样输出，顺序也不能重排。
 *
 * tool_use 的 input 必须是对象而非字符串，所以这里把流式拼接出的 JSON 原文解析回对象；
 * 解析失败时退化为空对象，并由调用方通过 tool_result 告知模型参数无效。
 */
export function assistantTurnToBlocks(turn: AssistantTurn): ApiBlock[] {
  const blocks: ApiBlock[] = [];
  for (const part of turn.parts) {
    if (part.kind === 'thinking') {
      blocks.push({ type: 'thinking', thinking: part.text, signature: part.signature });
    } else if (part.kind === 'redacted_thinking') {
      blocks.push({ type: 'redacted_thinking', data: part.redactedData });
    } else if (part.kind === 'tool_use') {
      let input: Object = {};
      if (part.toolInputJson.length > 0) {
        try {
          input = JSON.parse(part.toolInputJson) as Object;
        } catch (err) {
          input = {};
        }
      }
      blocks.push({ type: 'tool_use', id: part.toolId, name: part.toolName, input });
    } else if (part.text.length > 0) {
      blocks.push({ type: 'text', text: part.text });
    }
  }
  return blocks;
}

/** 解析某个 tool_use 的参数；失败返回 null，由调用方回报参数错误。 */
export function parseToolInput(part: ContentPart): Object | null {
  if (part.toolInputJson.length === 0) {
    return {};
  }
  try {
    return JSON.parse(part.toolInputJson) as Object;
  } catch (err) {
    return null;
  }
}

/** 错误文案是否指向 cache_control 不被支持。 */
function mentionsCache(message: string): boolean {
  const lowered = message.toLowerCase();
  return lowered.indexOf('cache_control') >= 0 || lowered.indexOf('cache control') >= 0 ||
    lowered.indexOf('prompt caching') >= 0 || lowered.indexOf('caching') >= 0;
}

/** 复制一份关闭缓存标记的请求参数。 */
function withoutCache(options: SendOptions): SendOptions {
  return {
    endpoint: options.endpoint,
    apiKey: options.apiKey,
    model: options.model,
    maxTokens: options.maxTokens,
    systemPrompt: options.systemPrompt,
    messages: options.messages,
    tools: options.tools,
    maxRetries: options.maxRetries,
    connectTimeoutMs: options.connectTimeoutMs,
    readTimeoutMs: options.readTimeoutMs,
    enablePromptCache: false
  };
}

function classifyStatus(status: number, body: string): ApiErrorKind {
  if (status === 401 || status === 403) {
    return 'auth';
  }
  if (status === 429) {
    return 'rate_limit';
  }
  if (status >= 500) {
    return 'server';
  }
  if (status === 400) {
    // 这里曾按报文里有没有 'too long' / 'exceed' / 'context window' 之类的词
    // 把 400 判成「上下文超限」，再由主循环压缩重试。**已删除，不要加回来。**
    //
    // 那是拿 Anthropic 官方端点的措辞去猜所有兼容端点。措辞不统一，猜错的两个方向
    // 都有害：把普通的请求错误误判成超限，会压掉历史再撞同一个错；把真超限漏判，
    // 又白等一轮。现在 400 一律是 bad_request，原样把端点自己的报文交上去。
    return 'bad_request';
  }
  return status >= 200 && status < 300 ? 'none' : 'bad_request';
}

function extractErrorMessage(body: string, fallback: string): string {
  if (body.length === 0) {
    return fallback;
  }
  try {
    const parsed = JSON.parse(body) as ErrorEnvelope;
    if (parsed.error !== undefined && parsed.error.message !== undefined) {
      return parsed.error.message;
    }
  } catch (err) {
    // 非 JSON 响应体，原样截断返回
  }
  return body.length > 400 ? `${body.substring(0, 400)}…` : body;
}

const sleep = (ms: number): Promise<void> => {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
};

function fail(kind: ApiErrorKind, message: string, status: number): ApiResult {
  return {
    ok: false,
    turn: null,
    errorKind: kind,
    errorMessage: message,
    httpStatus: status
  };
}

function succeed(turn: AssistantTurn, status: number): ApiResult {
  return {
    ok: true,
    turn,
    errorKind: 'none',
    errorMessage: '',
    httpStatus: status
  };
}

export class AnthropicClient {
  private readonly log: LogSink;
  private current: http.HttpRequest | null = null;
  private aborted: boolean = false;

  constructor(log: LogSink) {
    this.log = log;
  }

  /** 紧急停止：立即掐掉正在进行的请求。 */
  abort(): void {
    this.aborted = true;
    const req = this.current;
    if (req !== null) {
      try {
        req.destroy();
      } catch (err) {
        this.log(`[api] 中止请求失败: ${(err as BusinessError).message}`);
      }
    }
  }

  private buildBody(options: SendOptions): string {
    // max_tokens 必发：官方端点必填。非法值回落到默认，不允许省略。
    const body: ApiRequestBody = {
      model: options.model,
      max_tokens: options.maxTokens > 0 ? options.maxTokens : DEFAULT_MAX_TOKENS,
      stream: true,
      messages: options.messages
    };
    if (options.systemPrompt.length > 0) {
      if (options.enablePromptCache) {
        // 缓存断点打在系统提示末尾：这一段永不变化，压缩历史不会影响它。
        // 只有数组形式的 system 能携带 cache_control。
        const systemBlocks: ApiBlock[] = [{
          type: 'text',
          text: options.systemPrompt,
          cache_control: { type: CACHE_EPHEMERAL }
        }];
        body.system = systemBlocks;
      } else {
        // 纯字符串是兼容性最好的形式，部分国内端点只认这一种。
        body.system = options.systemPrompt;
      }
    }
    if (options.tools.length > 0) {
      const tools: ApiTool[] = [];
      for (let i = 0; i < options.tools.length; i += 1) {
        const t = options.tools[i];
        const copy: ApiTool = { name: t.name, description: t.description, input_schema: t.input_schema };
        // 只在最后一个 tool 上打断点，等于缓存"系统提示 + 全部 tool 定义"这一整段前缀。
        if (options.enablePromptCache && i === options.tools.length - 1) {
          copy.cache_control = { type: CACHE_EPHEMERAL };
        }
        tools.push(copy);
      }
      body.tools = tools;
    }
    // 到此为止。不追加 output_config / thinking / temperature 等各家不统一的字段，
    // 理由见 ApiRequestBody 的注释。
    return JSON.stringify(body);
  }

  /**
   * 发一轮请求。失败时按错误种类决定是否重试：
   * 429 优先遵守 retry-after，5xx 与网络错误用 1/2/4 秒退避；
   * 鉴权失败、请求非法、上下文超限一律不重试，直接交给上层处理。
   */
  async send(options: SendOptions, sink: StreamSink | null): Promise<ApiResult> {
    this.aborted = false;
    let attempt = 0;
    let effective: SendOptions = options;
    let cacheAlreadyDropped = false;
    let lastResult: ApiResult = fail('network', '尚未发起请求', 0);
    while (attempt <= options.maxRetries) {
      if (this.aborted) {
        return fail('aborted', '已被用户停止', 0);
      }
      lastResult = await this.attemptOnce(effective, sink);
      if (lastResult.ok) {
        return lastResult;
      }
      const kind = lastResult.errorKind;
      // 兼容端点常因不认 cache_control 而直接 400。自动去掉缓存标记重试一次，
      // 这一次不计入重试次数，因为它修的是请求形态而不是临时故障。
      if (!cacheAlreadyDropped && effective.enablePromptCache && kind === 'bad_request' &&
        mentionsCache(lastResult.errorMessage)) {
        cacheAlreadyDropped = true;
        effective = withoutCache(effective);
        this.log('[api] 端点疑似不支持 cache_control，已去掉缓存标记并重试');
        continue;
      }
      const retryable = kind === 'rate_limit' || kind === 'server' || kind === 'network';
      if (!retryable || attempt === options.maxRetries) {
        return lastResult;
      }
      const waitMs = lastResult.httpStatus === 429 && lastResult.errorMessage.indexOf('retry-after=') >= 0 ?
        this.parseRetryAfterMs(lastResult.errorMessage) : Math.round(1000 * Math.pow(2, attempt));
      this.log(`[api] ${kind} 第 ${attempt + 1} 次失败，${waitMs} 毫秒后重试`);
      await sleep(waitMs);
      attempt += 1;
    }
    return lastResult;
  }

  private parseRetryAfterMs(message: string): number {
    const matched = /retry-after=(\d+)/.exec(message);
    if (matched === null) {
      return 1000;
    }
    const seconds = Number.parseInt(matched[1], 10);
    return Number.isNaN(seconds) ? 1000 : Math.max(1000, seconds * 1000);
  }

  private attemptOnce(options: SendOptions, sink: StreamSink | null): Promise<ApiResult> {
    return new Promise<ApiResult>((resolve: (value: ApiResult) => void) => {
      const url = `${options.endpoint.replace(/\/+$/, '')}${MESSAGES_PATH}`;
      const request = http.createHttp();
      this.current = request;

      const decoder = util.TextDecoder.create('utf-8', { fatal: false, ignoreBOM: true });
      const assembler = new TurnAssembler(sink);
      let buffer = '';
      /** 非 200 时响应体不是 SSE，需要原样收集用于报错。 */
      let rawBody = '';
      let status = 0;
      let streamError: string | null = null;
      let settled = false;
      let retryAfter = '';

      const finish = (result: ApiResult): void => {
        if (settled) {
          return;
        }
        settled = true;
        try {
          request.off('headersReceive');
          request.off('dataReceive');
          request.off('dataEnd');
        } catch (err) {
          // 注销失败不影响结果
        }
        try {
          request.destroy();
        } catch (err) {
          // 同上
        }
        this.current = null;
        resolve(result);
      };

      request.on('headersReceive', (headers: Object) => {
        // 头部里可能带 retry-after，429 时要遵守它而不是用固定退避。
        try {
          const text = JSON.stringify(headers);
          const matched = /"retry-after"\s*:\s*"?(\d+)"?/i.exec(text);
          if (matched !== null) {
            retryAfter = matched[1];
          }
        } catch (err) {
          // 头部无法序列化时忽略
        }
      });

      request.on('dataReceive', (chunk: ArrayBuffer) => {
        const bytes = new Uint8Array(chunk);
        const text = decoder.decodeToString(bytes, { stream: true });
        if (text.length === 0) {
          return;
        }
        rawBody += text;
        if (status !== 0 && status !== http.ResponseCode.OK) {
          return;
        }
        buffer += text;
        const batch = parseSseChunks(buffer);
        buffer = batch.rest;
        for (const ev of batch.events) {
          const problem = assembler.feed(ev.event, ev.data);
          if (problem !== null && streamError === null) {
            streamError = problem;
          }
        }
      });

      request.on('dataEnd', () => {
        if (this.aborted) {
          finish(fail('aborted', '已被用户停止', status));
          return;
        }
        if (status !== 0 && status !== http.ResponseCode.OK) {
          const kind = classifyStatus(status, rawBody);
          let message = extractErrorMessage(rawBody, `HTTP ${status}`);
          if (kind === 'rate_limit' && retryAfter.length > 0) {
            message = `${message} (retry-after=${retryAfter})`;
          }
          finish(fail(kind, message, status));
          return;
        }
        if (streamError !== null) {
          finish(fail(classifyStatus(status, streamError), streamError, status));
          return;
        }
        finish(succeed(assembler.result(), status));
      });

      // 两个认证头一起发，没有开关。
      //
      // 官方端点读 x-api-key，Kimi、GLM、MiniMax 等兼容端点读 Authorization: Bearer。
      // 多发一个**请求头**是安全的：服务端认哪个读哪个，不认的直接忽略。
      // 这和请求体不一样 —— 请求体里多一个字段官方会 400（Extra inputs are not permitted），
      // 所以那边才必须一个都不多发。
      //
      // 原先这里有个「认证头」三选项设置。已删除：实测所有端点用 both 都能过，
      // 别的工具也不问这个，留着只是让用户对着一个永远不用改的开关发愁。
      const headers: Record<string, string> = {
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        'anthropic-version': ANTHROPIC_VERSION,
        'Authorization': `Bearer ${options.apiKey}`,
        'x-api-key': options.apiKey
      };

      request.requestInStream(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: this.buildBody(options),
        connectTimeout: options.connectTimeoutMs,
        readTimeout: options.readTimeoutMs
      }).then((code: number) => {
        status = code;
        if (code !== http.ResponseCode.OK) {
          this.log(`[api] HTTP ${code}`);
        }
      }).catch((err: BusinessError) => {
        finish(fail('network', `网络请求失败: ${err.message}`, 0));
      });
    });
  }
}
