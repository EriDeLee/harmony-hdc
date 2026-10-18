/**
 * Agent 配置持久化。沿用 HdcKeyStore / HdcSettings 的 Preferences 写法。
 *
 * 按对齐结论：
 * - 端点必填、无默认值；模型 ID 手填。两者都不预设，避免把某个版本写死在代码里。
 * - 上下文压缩阈值也是设置项：模型 ID 由用户填写，应用无法得知其上下文窗口大小，
 *   所以这个数字只能来自用户，不能猜。
 * - 黑名单默认为空，不内置任何条目。
 * - API key 以明文存 Preferences，与本项目现有私钥存储的取舍保持一致。
 */
import { preferences } from '@kit.ArkData';
import type { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';

const STORE_NAME: string = 'hdc_agent';
const KEY_ENDPOINT: string = 'endpoint';
const KEY_API_KEY: string = 'api_key';
const KEY_MODEL: string = 'model';
const KEY_CONTEXT_LIMIT: string = 'context_limit_tokens';
const KEY_BLACKLIST: string = 'blacklist_bundles';
const KEY_PROMPT_CACHE: string = 'prompt_cache';
const KEY_MAX_TOKENS: string = 'max_tokens';
const KEY_KEEP_SCREENSHOTS: string = 'keep_recent_screenshots';

/** 未填写时的占位值；配置是否完整由 isAgentConfigured 判定。 */
const EMPTY: string = '';
/**
 * 压缩阈值默认 128000：主动压缩是**唯一**的压缩触发点，所以必须有个默认值。
 *
 * 原先默认 0（不主动压缩），靠「端点报超限就压缩重试」兜底。那条路已删除 ——
 * 它是拿 Anthropic 官方端点的报错措辞去猜所有兼容端点，猜不准。
 * 默认 0 加上没有兜底，等于历史一直涨到端点报错任务才死，所以默认值必须改。
 *
 * 注意这个数字不是真正的触发点：实际触发点由 AgentLoop 算成「本值 − maxTokens」，
 * 差出来的那一笔留给模型这一轮的回复。默认配置下真正开始折叠的位置是
 * 128000 − 32768 = 95232，和 Cline 在 128K 窗口下取的 98000 基本重合。
 */
export const DEFAULT_CONTEXT_LIMIT_TOKENS: number = 128000;
/**
 * max_tokens 必须发送：官方 Anthropic 端点把它列为必填字段，缺了直接 400，
 * 而所有国内兼容端点都把它标为完全支持。所以这是唯一一个"必须自己给值"的参数。
 *
 * 32768 的取法。已核实的各家输出上限：
 *   DeepSeek V4 Pro / Flash    384K
 *   Claude Fable 5/Opus 5/Sonnet 5  128K
 *   Claude Haiku 4.5             64K  <- 已知最紧的一家
 * 取 32768 是对最紧上限留一倍余量，同时给思考留足空间：思考 token 计入
 * max_tokens（官方原文 "a hard cap on total output for the request, thinking and
 * response text combined"），而本实现不发 effort、一律走上游默认档（Anthropic 与
 * DeepSeek 是 high、Kimi K3 是 max），所以必须假设思考会写得很长。
 * 若这里给得太小，思考会吃光额度、工具调用被截断，表现为 agent 原地停住。
 * 想要更长回复可在设置里调大。
 */
const DEFAULT_MAX_TOKENS: number = 32768;
/**
 * 保留最近几张截图，更早的在历史里退化成一行文字。
 *
 * 取 5 是对着折叠的保留量定的：折叠时原文保留最近 4 个来回，所以留 5 张图意味着
 * 最老的那一张通常正好落在被折掉的那一段里 —— 摘要模型能真看到图并把它写成文字，
 * 而不是只看到「（此处原本有一张截图）」这种什么都没说的占位。
 * 调成 4 或更小，图片就总在保留区内、永远等不到被摘要读一遍就直接消失了。
 */
export const DEFAULT_KEEP_SCREENSHOTS: number = 5;

export interface AgentConfig {
  /** 形如 https://host，必填。 */
  endpoint: string;
  apiKey: string;
  /** 模型 ID，手填。 */
  model: string;
  /**
   * 触发会话压缩的上下文 token 阈值。0 表示彻底不压缩 —— 没有任何兜底，
   * 历史会一直涨到端点自己报错为止。
   *
   * 注意这不是真正的触发点：实际触发点是它减去 maxTokens，给回复留出地方。
   * 减出 0 或负数（两个值填得不合理）时同样不压缩。详见 AgentLoop.maybeCompact。
   */
  contextLimitTokens: number;
  /** 禁止 agent 进入的应用包名。 */
  blacklistBundles: string[];
  /**
   * 是否发送 cache_control。国内兼容端点对提示缓存的支持未文档化，
   * 部分网关在不支持的路由上直接 400，所以要能关。
   * 客户端在遇到与缓存有关的 400 时也会自动去掉标记重试一次。
   */
  enablePromptCache: boolean;
  /**
   * 单次回复的 max_tokens。必填字段，不能省。
   *
   * 这里没有 effort / thinking 之类的推理强度设置，是有意为之：这些参数在各家
   * Anthropic 兼容端点上字段路径与取值都不统一（官方是 output_config.effort，
   * 阿里百炼是顶层 reasoning_effort，取值有的只认 high/max，Kiro 上游不认
   * thinking.type=enabled），发错位置会被静默丢弃、发错取值会 400。
   * 与其为每家开分支，不如一概不发，用上游默认值。详见 doc/anthropic-api.md。
   */
  maxTokens: number;
  /**
   * 历史里保留最近几张截图。更早的换成一行文字。
   *
   * **0 表示不裁剪，全部保留。** 不设"一张都不留"这个档：那会让 screenshot 与 click
   * 变成废功能 —— 裁剪跑在请求发出之前，连刚拍的那张也会被换成文字，模型一张都看不到。
   */
  keepRecentScreenshots: number;
}

async function getStore(context: common.Context): Promise<preferences.Preferences> {
  try {
    return await preferences.getPreferences(context, STORE_NAME);
  } catch (err) {
    throw new Error(`打开 Preferences(${STORE_NAME}) 失败: ${(err as BusinessError).message}`);
  }
}

/** 黑名单以换行分隔存储，避免再引入一层 JSON。 */
function splitBundles(text: string): string[] {
  const out: string[] = [];
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (line.length > 0) {
      out.push(line);
    }
  }
  return out;
}

function joinBundles(list: string[]): string {
  const cleaned: string[] = [];
  for (const item of list) {
    const line = item.trim();
    if (line.length > 0) {
      cleaned.push(line);
    }
  }
  return cleaned.join('\n');
}

/** 读取配置；从未保存过时各字段为空值。 */
export async function loadAgentConfig(context: common.Context): Promise<AgentConfig> {
  const store = await getStore(context);
  try {
    const endpoint = await store.get(KEY_ENDPOINT, EMPTY) as string;
    const apiKey = await store.get(KEY_API_KEY, EMPTY) as string;
    const model = await store.get(KEY_MODEL, EMPTY) as string;
    const contextLimitTokens = await store.get(KEY_CONTEXT_LIMIT, DEFAULT_CONTEXT_LIMIT_TOKENS) as number;
    const blacklistText = await store.get(KEY_BLACKLIST, EMPTY) as string;
    const enablePromptCache = await store.get(KEY_PROMPT_CACHE, true) as boolean;
    const maxTokens = await store.get(KEY_MAX_TOKENS, DEFAULT_MAX_TOKENS) as number;
    const keepShots = await store.get(KEY_KEEP_SCREENSHOTS, DEFAULT_KEEP_SCREENSHOTS) as number;
    return {
      endpoint,
      apiKey,
      model,
      contextLimitTokens,
      blacklistBundles: splitBundles(blacklistText),
      enablePromptCache,
      maxTokens: maxTokens > 0 ? maxTokens : DEFAULT_MAX_TOKENS,
      keepRecentScreenshots: keepShots >= 0 ? keepShots : DEFAULT_KEEP_SCREENSHOTS
    };
  } catch (err) {
    throw new Error(`读取 agent 配置失败: ${(err as BusinessError).message}`);
  }
}

/** 覆写保存配置。 */
export async function saveAgentConfig(context: common.Context, config: AgentConfig): Promise<void> {
  const store = await getStore(context);
  try {
    await store.put(KEY_ENDPOINT, config.endpoint.trim());
    await store.put(KEY_API_KEY, config.apiKey.trim());
    await store.put(KEY_MODEL, config.model.trim());
    await store.put(KEY_CONTEXT_LIMIT, config.contextLimitTokens);
    await store.put(KEY_BLACKLIST, joinBundles(config.blacklistBundles));
    await store.put(KEY_PROMPT_CACHE, config.enablePromptCache);
    await store.put(KEY_MAX_TOKENS, config.maxTokens > 0 ? config.maxTokens : DEFAULT_MAX_TOKENS);
    await store.put(
      KEY_KEEP_SCREENSHOTS,
      config.keepRecentScreenshots >= 0 ? config.keepRecentScreenshots : DEFAULT_KEEP_SCREENSHOTS
    );
    await store.flush();
  } catch (err) {
    throw new Error(`保存 agent 配置失败: ${(err as BusinessError).message}`);
  }
}

/** 删除全部 agent 配置，含 API key。 */
export async function clearAgentConfig(context: common.Context): Promise<void> {
  const store = await getStore(context);
  try {
    await store.delete(KEY_ENDPOINT);
    await store.delete(KEY_API_KEY);
    await store.delete(KEY_MODEL);
    await store.delete(KEY_CONTEXT_LIMIT);
    await store.delete(KEY_BLACKLIST);
    await store.delete(KEY_PROMPT_CACHE);
    await store.delete(KEY_MAX_TOKENS);
    await store.delete(KEY_KEEP_SCREENSHOTS);
    await store.flush();
  } catch (err) {
    throw new Error(`删除 agent 配置失败: ${(err as BusinessError).message}`);
  }
}

/** 配置是否足以发起请求。缺哪一项由 describeMissing 说明。 */
export function isAgentConfigured(config: AgentConfig): boolean {
  return config.endpoint.length > 0 && config.apiKey.length > 0 && config.model.length > 0;
}

/** 列出缺失项，用于在界面上直接告诉用户还差什么。 */
export function describeMissing(config: AgentConfig): string[] {
  const missing: string[] = [];
  if (config.endpoint.length === 0) {
    missing.push('接口地址');
  }
  if (config.apiKey.length === 0) {
    missing.push('API key');
  }
  if (config.model.length === 0) {
    missing.push('模型 ID');
  }
  return missing;
}

/**
 * API key 的展示形态。只留首尾各 4 位，其余打码。
 * 用于日志与界面回显，避免把完整密钥写进屏幕或日志。
 */
export function maskApiKey(apiKey: string): string {
  if (apiKey.length === 0) {
    return '未设置';
  }
  if (apiKey.length <= 8) {
    return '********';
  }
  return `${apiKey.substring(0, 4)}****${apiKey.substring(apiKey.length - 4)}`;
}
