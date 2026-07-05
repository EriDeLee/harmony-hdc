/**
 * 基于 bm（Bundle Manager）的应用管理操作。
 *
 * 性能要点：
 * - 应用名称与标签：`bm dump -a -l` 一次调用即返回全部应用的 {bundleName,label}（~0.2s）。
 * - 是否系统应用：bm 没有批量接口，只能 `bm dump -n <包名>` 逐个查 isSystemApp；
 *   BMS 服务端 IPC 串行，并行帮助有限（实测约 0.06s/个）。因此对结果做持久化缓存，
 *   bundleName→是否系统 基本不变，只需对“未缓存的新包”增量分类，首次之后近乎瞬时。
 */
import type { HdcConnection } from './HdcConnection';

const BM_CLEAN_EXIT_MARKER: string = '__HDC_TOOLBOX_BM_CLEAN_EXIT__=';

export interface BundleEntry {
  name: string;
  label: string;
  system: boolean;
  classified: boolean;
  clearable: boolean;
}

export interface ListBundlesResult {
  entries: BundleEntry[];
  /** 合并后的完整分类缓存，调用方应持久化。 */
  systemMap: Map<string, boolean>;
  unknownCount: number;
}

interface NameLabel {
  bundleName: string;
  label: string;
}

function shellQuote(value: string): string {
  const quote = String.fromCharCode(39);
  return quote + value.split(quote).join(quote + '\\' + quote + quote) + quote;
}

/** 单次 `bm dump -a -l` 取全部应用的包名与标签。 */
async function fetchNameLabels(conn: HdcConnection): Promise<NameLabel[]> {
  const out = await conn.executeCommand('bm dump -a -l', 20000);
  try {
    const parsed = JSON.parse(out) as NameLabel[];
    return parsed;
  } catch (err) {
    throw new Error(`解析应用列表失败: ${(err as Error).message}`);
  }
}

/**
 * 对给定包名并行判定是否系统应用。
 * 输出按行 "flag name"：1=系统应用，0=普通应用。
 */
async function classify(conn: HdcConnection, names: string[]): Promise<Map<string, boolean>> {
  const result = new Map<string, boolean>();
  if (names.length === 0) {
    return result;
  }
  const list = names.join(' ');
  const cmd =
    `printf '%s\\n' ${list} | xargs -P16 -n1 sh -c ` +
    `'bm dump -n "$0" 2>/dev/null | grep -q "\\"isSystemApp\\": false" && echo "0 $0" || echo "1 $0"'`;
  let out = '';
  try {
    out = await conn.executeCommand(cmd, 120000);
  } catch (err) {
    return result;
  }
  for (const raw of out.split('\n')) {
    const line = raw.trim();
    if (line.length === 0) {
      continue;
    }
    const sep = line.indexOf(' ');
    if (sep <= 0) {
      continue;
    }
    const flag = line.substring(0, sep);
    const name = line.substring(sep + 1).trim();
    if (flag !== '0' && flag !== '1') {
      continue;
    }
    if (name.length > 0) {
      result.set(name, flag === '1');
    }
  }
  return result;
}

/**
 * 列举所有应用（含标签与系统应用标记）。
 * @param cache 已知的 bundleName→是否系统 缓存；只对其中没有的包做增量分类。
 */
export async function listBundles(conn: HdcConnection, cache: Map<string, boolean>): Promise<ListBundlesResult> {
  const nameLabels = await fetchNameLabels(conn);

  const uncached: string[] = [];
  for (const nl of nameLabels) {
    if (!cache.has(nl.bundleName)) {
      uncached.push(nl.bundleName);
    }
  }

  const merged = new Map<string, boolean>();
  cache.forEach((value: boolean, key: string) => {
    merged.set(key, value);
  });
  if (uncached.length > 0) {
    const fresh = await classify(conn, uncached);
    fresh.forEach((value: boolean, key: string) => {
      merged.set(key, value);
    });
  }

  const entries: BundleEntry[] = nameLabels.map((nl: NameLabel): BundleEntry => {
    const label = nl.label.length > 0 ? nl.label : nl.bundleName;
    const classified = merged.has(nl.bundleName);
    const system = classified ? (merged.get(nl.bundleName) as boolean) : true;
    return {
      name: nl.bundleName,
      label,
      system,
      classified,
      clearable: classified
    };
  });
  const unknownCount = entries.filter((entry: BundleEntry) => !entry.classified).length;
  entries.sort((a: BundleEntry, b: BundleEntry) => {
    if (a.label === b.label) {
      return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
    }
    return a.label < b.label ? -1 : 1;
  });

  return { entries, systemMap: merged, unknownCount };
}

/** 清空指定应用的数据（bm clean -n <包名> -d）。返回 bm 的原始输出。 */
export async function clearBundleData(
  conn: HdcConnection,
  bundleName: string,
  timeoutMs: number = 20000
): Promise<string> {
  const command =
    `bm clean -n ${shellQuote(bundleName)} -d; ` +
      `code=$?; printf '\n${BM_CLEAN_EXIT_MARKER}%s\n' "$code"`;
  const output = await conn.executeCommand(command, timeoutMs);
  const markerIndex = output.lastIndexOf(`\n${BM_CLEAN_EXIT_MARKER}`);
  if (markerIndex < 0) {
    throw new Error(`清空结果缺少退出码: ${output.trim()}`);
  }
  const commandOutput = output.substring(0, markerIndex).trim();
  const exitText = output.substring(markerIndex + BM_CLEAN_EXIT_MARKER.length + 1).trim().split('\n')[0];
  const exitCode = Number.parseInt(exitText, 10);
  if (Number.isNaN(exitCode)) {
    throw new Error(`清空结果退出码无效: ${exitText}`);
  }
  if (exitCode !== 0) {
    const message = commandOutput.length > 0 ? commandOutput : `bm clean exit=${exitCode}`;
    throw new Error(message);
  }
  return commandOutput;
}
