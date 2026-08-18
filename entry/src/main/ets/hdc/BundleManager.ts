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

// ---------- 安装 HAP ----------

const HAP_STEP_EXIT_MARKER: string = '__HDC_TOOLBOX_HAP_STEP__=';
const HAP_TMP_DIR: string = '/data/local/tmp';
const HAP_NAME_LETTERS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

export interface HapInstallResult {
  /** 临时文件名（6 位随机字母 + .hap），用于日志追踪。 */
  tmpName: string;
  copyOk: boolean;
  /** copyOk 为 false 时本字段无意义（未执行安装）。 */
  installOk: boolean;
  /** bm install 的原始输出；cp 失败时为 cp 的输出。 */
  installOutput: string;
  deleteOk: boolean;
}

interface StepResult {
  code: number;
  output: string;
}

/** 6 位随机字母 + .hap，避免与 /data/local/tmp 里的既有文件冲突。 */
function randomHapName(): string {
  let name = '';
  for (let i = 0; i < 6; i++) {
    name += HAP_NAME_LETTERS.charAt(Math.floor(Math.random() * HAP_NAME_LETTERS.length));
  }
  return `${name}.hap`;
}

/** 执行单条命令并解析 printf 附加的退出码 marker（模式同 clearBundleData）。 */
async function hapStep(conn: HdcConnection, command: string, timeoutMs: number): Promise<StepResult> {
  const wrapped = `${command}; printf '\n${HAP_STEP_EXIT_MARKER}%s\n' "$?"`;
  const output = await conn.executeCommand(wrapped, timeoutMs);
  const markerIndex = output.lastIndexOf(`\n${HAP_STEP_EXIT_MARKER}`);
  if (markerIndex < 0) {
    throw new Error(`命令结果缺少退出码: ${output.trim()}`);
  }
  const stepOutput = output.substring(0, markerIndex).trim();
  const exitText = output.substring(markerIndex + HAP_STEP_EXIT_MARKER.length + 1).trim().split('\n')[0];
  const exitCode = Number.parseInt(exitText, 10);
  if (Number.isNaN(exitCode)) {
    throw new Error(`命令退出码无效: ${exitText}`);
  }
  return { code: exitCode, output: stepOutput };
}

const HAP_INSTALL_TRANSFER_TIMEOUT_MS: number = 600000;

/**
 * 把 HAP 安装包经 FILE 通道推送到所连设备的 /data/local/tmp，`bm install -r` 安装后清理。
 *
 * 文件由应用自己读（readChunk 流式回调，不整块进内存），经协议推到设备——
 * 所以**本地设备与远程设备走同一条路**，不存在「picker 路径只在应用命名空间可见」的问题
 * （那套 osAccount/media 路径解析已随本改造删除）。
 * 阶段经 onPhase 上报：transfer（带进度字节数）→ install → clean。
 *
 * 失败语义：
 * - 传输失败：不安装，无临时文件可清（daemon 收 CHECK 后才建文件，中途断开不会留半截）。
 * - bm install 抛异常（连接断/超时）：finally 里仍执行 rm。
 */
export async function installHapFromUri(
  conn: HdcConnection,
  fileSize: number,
  readChunk: (offset: number, maxLen: number) => Promise<Uint8Array>,
  onPhase?: (phase: string, progressBytes?: number) => void,
  installTimeoutMs: number = 300000,
  cleanTimeoutMs: number = 10000
): Promise<HapInstallResult> {
  const tmpName = randomHapName();
  const dst = `${HAP_TMP_DIR}/${tmpName}`;
  const result: HapInstallResult = { tmpName, copyOk: false, installOk: false, installOutput: '', deleteOk: false };

  if (onPhase !== undefined) {
    onPhase('transfer', 0);
  }
  const channel = conn.openFileChannel();
  try {
    await channel.push(
      fileSize,
      dst,
      tmpName,
      readChunk,
      (sentBytes: number) => {
        if (onPhase !== undefined) {
          onPhase('transfer', sentBytes);
        }
      },
      HAP_INSTALL_TRANSFER_TIMEOUT_MS
    );
    result.copyOk = true;
  } catch (err) {
    result.installOutput = (err as Error).message;
    return result;
  }

  try {
    if (onPhase !== undefined) {
      onPhase('install');
    }
    const install = await hapStep(conn, `bm install -r -p ${shellQuote(dst)}`, installTimeoutMs);
    // bm 的退出码不可信：真机实测（2026-08-18 未签名 hap）失败时输出
    // "error: failed to install bundle. / code:9568320 / error: no signature file."
    // 而退出码仍是 0 —— 官方 daemon 同样只看 exitStatus==0（daemon_app.cpp:103），
    // 所以官方 hdc install 也误报。唯一可靠信号是 bm 输出原文：
    // 成功固定打 "install bundle successfully."（终端实测成功样例）。
    result.installOk = install.code === 0 && install.output.includes('install bundle successfully');
    result.installOutput = install.output;
  } finally {
    if (onPhase !== undefined) {
      onPhase('clean');
    }
    try {
      const clean = await hapStep(conn, `rm -f ${shellQuote(dst)}`, cleanTimeoutMs);
      result.deleteOk = clean.code === 0;
    } catch (err) {
      result.deleteOk = false;
    }
  }
  return result;
}
