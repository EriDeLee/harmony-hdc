/*
 * AGENT 多会话存盘。
 *
 * 存在的理由：任务一结束、应用在后台且没有长时任务时，系统会把进程杀掉
 * （真机实测 `pidof` 为空，重开是全新未连接状态）。对话必须活过这次回收。
 *
 * 为什么一个会话一个文件：每轮结束都要写盘（进程可能毫无预警被杀，等退出时再写等于没写）。
 * 若把所有会话塞进一个文件，会话越攒越多、每轮都要整包重写，越用越慢。
 * 现在写盘只碰当前那一个文件，索引只在新建或剪枝时才动。
 */

import { fileIo } from '@kit.CoreFileKit';
import type { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import type { AgentSnapshot } from './AgentLoop';

const DIR_NAME: string = 'agent_sessions';
const INDEX_NAME: string = 'index.json';
/** 索引文件的版本。它的形状没变过，所以不跟着会话文件一起抬。 */
const VERSION: number = 2;
/**
 * 会话文件版本。
 *
 * 2：时间线内嵌在会话 JSON 里，每次写盘整包重写，并砍到最后 200 条。
 * 3：时间线搬到同名的 `.timeline` 旁挂文件，一条一行，只追加不重写，因此不再有条数上限。
 *
 * 读的时候两个版本都认：抬版本号不该让用户已有的对话作废。
 */
const SESSION_VERSION: number = 3;
const LEGACY_SESSION_VERSION: number = 2;
/*
 * 这里曾有一条 `MAX_SESSIONS = 30`：段数超过 30 就从最老的开始删文件。**不要加回来。**
 *
 * 两个理由。一是单位错了：它想控制磁盘占用，控制的却是段数，而一段可以是几十 KB
 * 也可以因为一个长任务的时间线涨到几 MB —— 同样是 30 段，占用可以差两个数量级，
 * 这个数字预测不了任何事。二是它悄悄删：对话攒到第 31 段时第 1 段就消失了，
 * 界面上不会说一声，和当年那条把时间线裁到 200 条的规则是同一类毛病。
 *
 * 清理入口已经有了：设置里的「删除全部对话记录」，带二次确认（见 onDeleteAllSessions）。
 * 什么时候删由用户决定，代码不替他删。
 */

export interface StoredTimelineEntry {
  kind: string;
  text: string;
  toolName: string;
}

/** 一段会话的完整内容。 */
export interface StoredSession {
  version: number;
  id: string;
  createdAt: number;
  snapshot: AgentSnapshot;
  timeline: StoredTimelineEntry[];
  keepMode: string;
}

/** 索引：按创建顺序从老到新排列的会话 id。 */
export interface SessionIndex {
  version: number;
  ids: string[];
}

type Logger = (line: string) => void;

function dirOf(ctx: common.UIAbilityContext): string {
  return `${ctx.filesDir}/${DIR_NAME}`;
}
function indexPath(ctx: common.UIAbilityContext): string {
  return `${dirOf(ctx)}/${INDEX_NAME}`;
}
function sessionPath(ctx: common.UIAbilityContext, id: string): string {
  return `${dirOf(ctx)}/${id}.json`;
}
/** 时间线旁挂文件：一条一行的 JSON，只追加。 */
function timelinePath(ctx: common.UIAbilityContext, id: string): string {
  return `${dirOf(ctx)}/${id}.timeline`;
}

function ensureDir(ctx: common.UIAbilityContext, log: Logger): boolean {
  const dir = dirOf(ctx);
  try {
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir);
    }
    return true;
  } catch (err) {
    log(`[session] 建目录失败: ${(err as BusinessError).message}`);
    return false;
  }
}

function writeText(path: string, text: string, log: Logger): boolean {
  let file: fileIo.File | null = null;
  try {
    const mode = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC;
    file = fileIo.openSync(path, mode);
    fileIo.writeSync(file.fd, text);
    return true;
  } catch (err) {
    log(`[session] 写 ${path} 失败: ${(err as BusinessError).message}`);
    return false;
  } finally {
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (err) {
        log(`[session] 关闭文件失败: ${(err as BusinessError).message}`);
      }
    }
  }
}

/**
 * 追加写。文件不存在就建，存在就把内容接到末尾。
 *
 * 用 APPEND 而不是读出来改完再整包写：整包重写的代价随会话总长增长，
 * 而追加的代价只跟这次新增的几条有关。这也是时间线不再需要条数上限的原因 ——
 * 旧条目根本不参与写入，就不存在"为了控制重写体积而裁掉它们"的理由。
 */
function appendText(path: string, text: string, log: Logger): boolean {
  let file: fileIo.File | null = null;
  try {
    const mode = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND;
    file = fileIo.openSync(path, mode);
    fileIo.writeSync(file.fd, text);
    return true;
  } catch (err) {
    log(`[session] 追加 ${path} 失败: ${(err as BusinessError).message}`);
    return false;
  } finally {
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (err) {
        log(`[session] 关闭文件失败: ${(err as BusinessError).message}`);
      }
    }
  }
}

/** 按 UTF-8 整体读取。逐字节拼字符串会把中文读坏。 */
function readText(path: string, log: Logger): string | null {
  try {
    if (!fileIo.accessSync(path)) {
      return null;
    }
    const stat = fileIo.statSync(path);
    if (stat.size <= 0) {
      return null;
    }
    return fileIo.readTextSync(path);
  } catch (err) {
    log(`[session] 读 ${path} 失败: ${(err as BusinessError).message}`);
    return null;
  }
}

/**
 * 扫目录，把真实存在的会话 id 找回来。**目录是唯一的事实来源，索引只是它的缓存。**
 *
 * 存在的理由是一次真实的数据丢失风险：索引一旦读不出来（缺文件、0 字节、解析失败），
 * 原来的 `loadIndex` 会返回空列表，而 `registerSession` 紧接着把"只有新 id 那一个"的索引
 * 写回磁盘 —— **一次读失败就把之前所有会话从索引里抹掉了**，文件还在，界面再也找不到。
 * 而 0 字节索引是完全可能出现的：`writeText` 先截断再写，进程在中间挂掉就留下 0 字节。
 *
 * 有了这个重建，那条链就断了：读不出来时按目录重算，最坏结果只是顺序按 id 排而不是按
 * 用户当初的顺序 —— 而 id 是 `s<毫秒>`，本身就是时间序。
 */
function scanSessionIds(ctx: common.UIAbilityContext, log: Logger): string[] {
  try {
    const names = fileIo.listFileSync(dirOf(ctx));
    const ids: string[] = [];
    for (const name of names) {
      // 两种文件都算证据：只有 .json 没有 .timeline 的段也是段（时间线可能真的是空的）。
      const dot = name.lastIndexOf('.');
      if (dot <= 0) {
        continue;
      }
      const stem = name.substring(0, dot);
      const ext = name.substring(dot);
      if (stem.length === 0 || stem.charAt(0) !== 's') {
        continue;
      }
      if (ext !== '.json' && ext !== '.timeline') {
        continue;
      }
      if (ids.indexOf(stem) < 0) {
        ids.push(stem);
      }
    }
    ids.sort();
    return ids;
  } catch (err) {
    log(`[session] 扫目录失败: ${(err as BusinessError).message}`);
    return [];
  }
}

export function loadIndex(ctx: common.UIAbilityContext, log: Logger): SessionIndex {
  const text = readText(indexPath(ctx), log);
  if (text === null) {
    // 读不出来**不等于**没有历史。按目录重建，别让下一次登记把索引覆盖成只剩一个 id。
    const found = scanSessionIds(ctx, log);
    if (found.length > 0) {
      log(`[session] 索引读不出来，按目录重建了 ${found.length} 段`);
    }
    return { version: VERSION, ids: found };
  }
  try {
    const parsed = JSON.parse(text) as SessionIndex;
    if (parsed === null || parsed.version !== VERSION || parsed.ids === undefined) {
      log('[session] 索引版本对不上，按目录重建');
      return { version: VERSION, ids: scanSessionIds(ctx, log) };
    }
    return parsed;
  } catch (err) {
    log(`[session] 索引解析失败: ${(err as BusinessError).message}，按目录重建`);
    return { version: VERSION, ids: scanSessionIds(ctx, log) };
  }
}

function saveIndex(ctx: common.UIAbilityContext, index: SessionIndex, log: Logger): void {
  if (!ensureDir(ctx, log)) {
    return;
  }
  writeText(indexPath(ctx), JSON.stringify(index), log);
}

/** 生成一个单调递增的 id。同一毫秒内连续新建时补后缀，避免撞号。 */
export function newSessionId(existing: string[]): string {
  const base = `s${Date.now()}`;
  if (existing.indexOf(base) < 0) {
    return base;
  }
  for (let i = 1; i < 1000; i += 1) {
    const candidate = `${base}_${i}`;
    if (existing.indexOf(candidate) < 0) {
      return candidate;
    }
  }
  return `${base}_x`;
}

/** 把 id 登记进索引末尾（末尾即最新）。不做任何自动剪枝，理由见文件开头那段。 */
export function registerSession(ctx: common.UIAbilityContext, id: string, log: Logger): SessionIndex {
  const index = loadIndex(ctx, log);
  if (index.ids.indexOf(id) < 0) {
    index.ids.push(id);
  }
  saveIndex(ctx, index, log);
  return index;
}

/**
 * 写一段会话。
 *
 * 分两个文件：
 * · `<id>.json` 装快照与元信息，每次整包重写。它的体积由折叠管着，不会无限涨。
 * · `<id>.timeline` 装时间线，只把 `pendingTimeline` 这几条追加到末尾。
 *
 * `pendingTimeline` 必须是"上次写盘之后新产生的那几条"，由调用方负责算。
 * 这里不去数文件已有多少行来推断：那要把整个文件读回来，追加式省下的开销又还回去了。
 */
/** 读回这一段原来的创建时间。没有或读不出来返回 null，由调用方填当前时间。 */
function readCreatedAt(ctx: common.UIAbilityContext, id: string): number | null {
  const text = readText(sessionPath(ctx, id), () => {});
  if (text === null) {
    return null;
  }
  try {
    const parsed = JSON.parse(text) as StoredSession;
    if (parsed === null || parsed.createdAt === undefined || parsed.createdAt <= 0) {
      return null;
    }
    return parsed.createdAt;
  } catch (err) {
    return null;
  }
}

export function saveSession(
  ctx: common.UIAbilityContext,
  id: string,
  snapshot: AgentSnapshot,
  pendingTimeline: StoredTimelineEntry[],
  keepMode: string,
  log: Logger
): boolean {
  if (!ensureDir(ctx, log)) {
    return false;
  }
  // createdAt 要保住原值。原先每次写盘都填 `Date.now()`，而快照是**整包重写**、
  // 一段会话跑一轮要写好几十次 —— 于是"创建时间"实际记的是最后一次写盘的时间。
  const born = readCreatedAt(ctx, id);
  const payload: StoredSession = {
    version: SESSION_VERSION,
    id,
    createdAt: born === null ? Date.now() : born,
    snapshot,
    timeline: [],
    keepMode
  };
  writeText(sessionPath(ctx, id), JSON.stringify(payload), log);
  if (pendingTimeline.length === 0) {
    return true;
  }
  const lines: string[] = [];
  for (const entry of pendingTimeline) {
    // 正文里的换行必须靠 JSON 转义扛住，否则一条记录会被拆成多行、读回来解析失败。
    lines.push(JSON.stringify(entry));
  }
  // 返回值只反映时间线追加成功没有：调用方靠它决定该不该推进"已落盘"计数。
  // 快照那半边写失败无所谓，下一次攒批会整包重写一遍。
  return appendText(timelinePath(ctx, id), `${lines.join('\n')}\n`, log);
}

/**
 * 读回一段会话的时间线。版本 2 的会话没有旁挂文件，时间线在会话 JSON 里。
 *
 * 单行解析失败只跳过那一行：追加写有可能在进程被杀的瞬间留下半条记录，
 * 为了半条坏记录丢掉整段历史不值得。
 */
function loadTimeline(ctx: common.UIAbilityContext, id: string, log: Logger): StoredTimelineEntry[] {
  const text = readText(timelinePath(ctx, id), log);
  if (text === null) {
    return [];
  }
  const out: StoredTimelineEntry[] = [];
  let broken = 0;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (line.length === 0) {
      continue;
    }
    try {
      const entry = JSON.parse(line) as StoredTimelineEntry;
      if (entry !== null && entry.kind !== undefined && entry.text !== undefined) {
        out.push(entry);
      } else {
        broken += 1;
      }
    } catch (err) {
      broken += 1;
    }
  }
  if (broken > 0) {
    log(`[session] 会话 ${id} 的时间线有 ${broken} 行读不出来，已跳过`);
  }
  return out;
}

export function loadSessionById(
  ctx: common.UIAbilityContext,
  id: string,
  log: Logger
): StoredSession | null {
  const text = readText(sessionPath(ctx, id), log);
  if (text === null) {
    return null;
  }
  try {
    const parsed = JSON.parse(text) as StoredSession;
    if (parsed === null || parsed.snapshot === undefined) {
      log(`[session] 会话 ${id} 内容不完整，丢弃`);
      return null;
    }
    if (parsed.version === LEGACY_SESSION_VERSION) {
      // 旧格式：时间线内嵌在这份 JSON 里，原样用。它最多只有 200 条，
      // 更早的在当年写盘时就已经被裁掉了，这里补不回来。
      return parsed;
    }
    if (parsed.version !== SESSION_VERSION) {
      log(`[session] 会话 ${id} 版本对不上，丢弃`);
      return null;
    }
    parsed.timeline = loadTimeline(ctx, id, log);
    return parsed;
  } catch (err) {
    log(`[session] 会话 ${id} 解析失败: ${(err as BusinessError).message}`);
    return null;
  }
}

/** 一段会话现在占两个文件，删的时候两个都要删，否则旁挂文件会永远留在磁盘上。 */
function removeSessionFiles(ctx: common.UIAbilityContext, id: string, log: Logger): void {
  const paths: string[] = [sessionPath(ctx, id), timelinePath(ctx, id)];
  for (const p of paths) {
    try {
      if (fileIo.accessSync(p)) {
        fileIo.unlinkSync(p);
      }
    } catch (err) {
      log(`[session] 删除 ${p} 失败: ${(err as BusinessError).message}`);
    }
  }
}

/** 删掉全部历史。目前只在需要彻底重来时用，正常「新会话」不会调它。 */
export function clearAllSessions(ctx: common.UIAbilityContext, log: Logger): void {
  const index = loadIndex(ctx, log);
  for (const id of index.ids) {
    removeSessionFiles(ctx, id, log);
  }
  saveIndex(ctx, { version: VERSION, ids: [] }, log);
}
