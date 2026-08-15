/**
 * 设备动作层：把 agent 可用的能力封装成一组受控 tool。
 *
 * 三条实测得出的铁律，决定了这里每个方法的写法：
 * 1. `uitest` 的返回码是假的 —— 无焦点时 `uiInput text` 照样回 `No Error` 却一个字都没打进去。
 *    所以任何动作都不能凭返回值判定成功，必须靠动作前后的界面差异。
 * 2. 动作是异步的 —— 退格还在路上时读到的就是旧值。所以用轮询判稳，不用固定 sleep。
 * 3. `aa` 的输出遇管道或重定向即消失，`bm` 可过管道但不可重定向，`uitest` 两者都安全。
 *    并且 `aa start` 失败时**仍然返回 0**，只能解析文本判定。
 *
 * 模型全程只使用元素编号，不接触任何坐标：编号在执行前用三级回退重新解析成当前真实
 * 位置，从而避开"观测到执行之间界面已变"的竞态，也天然跨设备。
 */
import { KeyCode } from '@kit.InputKit';
import type { HdcConnection, LogSink } from '../hdc/HdcConnection';
import type { ObserveContext, Observation, ObservedElement, Rect } from './Observer';
import {
  NO_CHANGE_TEXT, findByIndex, flatLabel, observe, renderObservation, reportAfterAction,
  resolveElement, sameObservation
} from './Observer';

const EXIT_MARKER: string = '__HDC_AGENT_EXIT__=';

interface NamedKey {
  /** 模型使用的名字。 */
  name: string;
  code: number;
  /**
   * 系统键在 `uitest uiInput keyEvent` 下有专门的名字形式，已实测可用；
   * 其余键走 `uinput` 的键码形式，好处是退出码真实且可一次批量发送。
   */
  uitestName?: string;
}

/**
 * 键码全部取自 SDK 的 `KeyCode` 枚举，不写字面量。
 *
 * 这里只列**在本机实测确认能送达**的键，逐个的验证方式是在便签正文里观察文本变化：
 * enter 插入真实换行、left/right 让后续字符落在文本中间或末尾、delete 删除光标之后的
 * 字符、space 与 backspace 直接看增删。
 *
 * up/down 用两行文本验证：光标上移后字符落在第一行、下移后落回第二行。
 *
 * 故意不收录 tab（2049）与 escape（2070）：实测按下后界面毫无变化，送达与否无法确认。
 * 暴露一个按下去什么都不发生的按键，等于给模型一个会说谎的工具，与本层的设计前提相悖。
 */
const NAMED_KEYS: NamedKey[] = [
  { name: 'back', code: KeyCode.KEYCODE_BACK, uitestName: 'Back' },
  { name: 'home', code: KeyCode.KEYCODE_HOME, uitestName: 'Home' },
  { name: 'power', code: KeyCode.KEYCODE_POWER, uitestName: 'Power' },
  { name: 'enter', code: KeyCode.KEYCODE_ENTER },
  { name: 'backspace', code: KeyCode.KEYCODE_DEL },
  { name: 'delete', code: KeyCode.KEYCODE_FORWARD_DEL },
  { name: 'space', code: KeyCode.KEYCODE_SPACE },
  { name: 'left', code: KeyCode.KEYCODE_DPAD_LEFT },
  { name: 'right', code: KeyCode.KEYCODE_DPAD_RIGHT },
  { name: 'up', code: KeyCode.KEYCODE_DPAD_UP },
  { name: 'down', code: KeyCode.KEYCODE_DPAD_DOWN }
];

function findNamedKey(name: string): NamedKey | null {
  const lower = name.toLowerCase();
  for (const entry of NAMED_KEYS) {
    if (entry.name === lower) {
      return entry;
    }
  }
  return null;
}

export function supportedKeyNames(): string[] {
  const names: string[] = [];
  for (const entry of NAMED_KEYS) {
    names.push(entry.name);
  }
  return names;
}

/** wait 的上限。改这里就要同步改 AgentTools 的 wait 描述与 AgentLoop 的夹取。 */
export const WAIT_MAX_MS: number = 60000;

/**
 * 绘制参数。每段的平滑时长直接决定落笔快慢：真机上 40 ms 能稳定出墨，
 * 再短没有验证过，所以不往下调。
 */
const DRAW_SMOOTH_MS: number = 40;
/** 每段一次进程启动的额外开销，用来估算超时预算。 */
const DRAW_PER_SEGMENT_OVERHEAD_MS: number = 120;
const DRAW_BATCH: number = 15;
const DRAW_BATCH_SLACK_MS: number = 4000;
/** 段数上限。按每段约 160 ms 算，400 段大约一分钟，再多模型就该拆成多次画。 */
export const MAX_DRAW_SEGMENTS: number = 400;
/** 小于这个边长的元素画不出可辨认的东西。 */
const MIN_DRAW_SIDE: number = 40;

/**
 * 屏幕看守一拍的上限。它同时就是「用户按下电源键」到「agent 真正停手」的延迟，
 * 所以不能由息屏时长推导：息屏设成 10 分钟时 t/3 是 200 秒，按了电源键要三分多钟
 * 才被发现，「一旦熄屏就中断」就不成立了。
 */
const SCREEN_GUARD_MAX_INTERVAL_MS: number = 7000;
/**
 * 息屏时长低于此值就拒绝启动 agent：心跳再密也很难稳稳跑在息屏前面，
 * 与其让任务随机被误判中断，不如一开始就说清楚。
 */
export const MIN_SCREEN_OFF_MS: number = 15000;

/** 看守一拍的结论。 */
export interface ScreenGuardTick {
  /** 探测本身是否成功。读一次失败不算停止信号，否则一次抖动就杀掉任务。 */
  ok: boolean;
  /** 用户看不见 agent 在做什么，应当中断。 */
  shouldStop: boolean;
  /** 给时间线看的原因。 */
  reason: string;
}

export type ScrollDirection = 'up' | 'down' | 'left' | 'right';

/**
 * 窗口级快照命令。实测约 150 ms / 6 KB，而完整 UI 树是 1.2~2.2 s / 116~650 KB，相差 8 倍以上。
 * 只能用来读窗口级状态（锁屏、键盘、前台应用）：实测它对页面内部变化**完全失明** ——
 * 在搜索框里打字后 UI 树大幅变化，而这条命令的输出逐字节相同。所以绝不能拿它做判稳。
 */
const WINDOW_PROBE_COMMAND: string = 'hidumper -s WindowManagerService -a "-a"';

/**
 * 前台窗口名前缀，用于识别锁屏与软键盘。属于华为 SceneBoard 的命名，已在本机双向实测
 * 并与 UI 树交叉验证；换设备需要重新确认。误判的后果被限制为"多做一次完整校验"，
 * 不会导致错误动作。
 */
const LOCK_WINDOW_PREFIX: string = 'SCBScreenLock';
/** 看守把两条转储拼在一次往返里，用这个标记切开。 */
const GUARD_SPLIT: string = '__HDC_GUARD_SPLIT__';
/** 长等待的分片粒度。它决定中断请求最多被一觉挡多久。 */
const WAIT_SLICE_MS: number = 400;
/**
 * 滚动手势的位移占元素的比例。端点因此落在 30%~70%，离元素边缘和屏幕边缘都远。
 *
 * 不能取满：整屏可滚元素的边缘就是屏幕边缘，而那里是系统手势区（上边下拉通知栏、
 * 下边回桌面）。真机上因此把通知栏拉了下来、任务失败一次。
 */
const SCROLL_TRAVEL_RATIO: number = 0.4;
/** 一档滚动速度。实测 200px 位移下 velocity=800 内容走 328px、2000 走 614px。 */
const SCROLL_BASE_VELOCITY: number = 800;
/** `uitest uiInput swipe` 接受的速度上限，来自 uitest help。 */
const SCROLL_MAX_VELOCITY: number = 40000;
/**
 * 掐掉在飞命令时给出的原因。**必须能被上层认出来**：
 * 这不是「这一步失败了」，而是「用户让停」，所以不该建议模型重试。
 */
export const CANCEL_REASON: string = '命令已被取消（用户停止或屏幕中断）';
const KEYBOARD_WINDOW_PREFIX: string = 'softKeyboard';

/** 窗口级快照结果。 */
export interface QuickState {
  locked: boolean;
  keyboardVisible: boolean;
  focusWindowId: string;
  foregroundWindows: string[];
}

export interface ActionSettings {
  /**
   * 两次判稳采样之间的间隙，不是采样周期。一次完整观测本身要 1.2~2.2 秒，
   * 所以这里只需一个很小的喘息值；设成 400 毫秒那种"周期"是没有意义的。
   */
  pollIntervalMs: number;
  /**
   * 判稳最长等待。必须容得下最坏情况的两次完整观测（重页面各约 2.2 秒），
   * 否则永远采不满两个样本就超时。
   */
  stableTimeoutMs: number;
  /**
   * 单条命令超时。所有命令共用这一个值，截图也一样。
   *
   * 真机实测（亮屏、内容丰富的页面，各跑三次取最慢）：
   *   看界面树（dumpLayout -i 再 cat 回传）  1496 ms
   *   截图（拍照 + base64 回传 324 KB）      689 ms
   *   列应用 bm dump -a -l                   343 ms
   *   读电源状态 hidumper                    379 ms
   *   冷启动 aa start                        305 ms
   *   空转（纯通道开销）                     154 ms
   * 界面树的耗时随屏幕内容变（树 448 KB 那次单跑 dumpLayout 是 1785 ms），
   * 按最坏组合外推约 2.3 秒，所以这个值留了大约 4 倍余量。
   *
   * 唯一不用这个值的是画图：它按段数自己算预算，见 `draw()`。
   */
  commandTimeoutMs: number;
  /** 禁止 agent 进入的应用包名。 */
  blacklistBundles: string[];
}

export interface ActionResult {
  ok: boolean;
  /** 回给模型的文本：成功时是界面差异，失败时是原因。 */
  detail: string;
  observation: Observation | null;
}

export interface ScreenshotResult {
  ok: boolean;
  detail: string;
  /** JPEG 的 base64，可直接放进 image block；失败时为空串。 */
  base64: string;
}

export interface AppEntry {
  bundleName: string;
  label: string;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/** 单引号包裹并转义内部单引号，防止模型给出的文本被 shell 解析。 */
function shellQuote(value: string): string {
  const quote = String.fromCharCode(39);
  return quote + value.split(quote).join(quote + '\\' + quote + quote) + quote;
}

interface PixelPoint {
  x: number;
  y: number;
}

function clampUnit(value: number): number {
  if (value < 0) {
    return 0;
  }
  return value > 1 ? 1 : value;
}

/**
 * 把一笔 `"x,y x,y ..."` 解析成元素内部的像素点。x/y 是 0~1 的比例，
 * 这样模型不需要知道任何像素尺寸，换设备换分辨率都不用改。
 * 内缩一像素，避免正好落在边界上被判到相邻元素。
 */
function parseStroke(text: string, box: Rect): PixelPoint[] {
  const out: PixelPoint[] = [];
  const width = box.right - box.left - 2;
  const height = box.bottom - box.top - 2;
  const tokens = text.split(' ');
  for (const token of tokens) {
    const piece = token.trim();
    if (piece.length === 0) {
      continue;
    }
    const parts = piece.split(',');
    if (parts.length !== 2) {
      continue;
    }
    const nx = Number.parseFloat(parts[0]);
    const ny = Number.parseFloat(parts[1]);
    if (Number.isNaN(nx) || Number.isNaN(ny)) {
      continue;
    }
    out.push({
      x: box.left + 1 + Math.round(clampUnit(nx) * width),
      y: box.top + 1 + Math.round(clampUnit(ny) * height)
    });
  }
  return out;
}

/** uinput 的返回码不可信，但它拒绝参数时会把原因打在输出里，这里挑第一条出来。 */
function firstInjectionError(output: string): string | null {
  const lines = output.split('\n');
  for (const line of lines) {
    const text = line.trim();
    if (text.length === 0) {
      continue;
    }
    if (text.indexOf('invalid') >= 0 || text.indexOf('wrong number') >= 0) {
      return text;
    }
  }
  return null;
}

/** 仅可打印 ASCII 才能走 uinput；uinput 遇非 ASCII 会返回 `character of index 0 is invalid`。 */
function isPrintableAscii(text: string): boolean {
  for (let i = 0; i < text.length; i += 1) {
    const code = text.charCodeAt(i);
    if (code < 0x20 || code > 0x7e) {
      return false;
    }
  }
  return text.length > 0;
}

interface MarkedOutput {
  output: string;
  exitCode: number;
}

// ---------- 桌面入口解析 ----------
//
// `bm dump -n <包名>` 输出里我们只关心这几个字段。JSON.parse 后没出现的字段
// 就是 undefined，逐个判就行。

interface DumpSkill {
  entities?: string[];
  actions?: string[];
}

interface DumpAbility {
  name?: string;
  moduleName?: string;
  exported?: boolean;
  visible?: boolean;
  iconId?: number;
  labelId?: number;
  skills?: DumpSkill[];
}

interface DumpModule {
  name?: string;
  abilityInfos?: DumpAbility[];
}

interface BundleDump {
  hapModuleInfos?: DumpModule[];
}

/** 一个可以用 `aa start` 拉起的桌面入口。 */
interface LauncherEntry {
  ability: string;
  moduleName: string;
  exported: boolean;
  hasIcon: boolean;
  hasLabel: boolean;
}

const HOME_ENTITY: string = 'entity.system.home';
/** 两种写法都要认：系统应用用前者，DevEco 建的工程用后者。 */
const HOME_ACTIONS: string[] = ['action.system.home', 'ohos.want.action.home'];

/**
 * 判断一个 ability 是不是桌面入口。
 *
 * 关键是两个条件必须落在**同一个 skill** 里。分开判会误收：应用市场的
 * SportWatchAbility 有一个带 home 实体的 skill，但那个 skill 里没有 home 动作，
 * 它不是桌面图标。
 */
function isLauncherAbility(ability: DumpAbility): boolean {
  const skills: DumpSkill[] = ability.skills ?? [];
  for (const skill of skills) {
    const entities: string[] = skill.entities ?? [];
    if (entities.indexOf(HOME_ENTITY) < 0) {
      continue;
    }
    const actions: string[] = skill.actions ?? [];
    for (const action of actions) {
      if (HOME_ACTIONS.indexOf(action) >= 0) {
        return true;
      }
    }
  }
  return false;
}

/**
 * 从 `bm dump -n` 的原始输出里取出所有桌面入口。
 *
 * 输出前面有 `包名:` 前缀，所以从第一个 `{` 开始切。
 * 只遍历 `abilityInfos`，不碰 `extensionInfos` —— 后者里的服务也可能带 home 实体，
 * 但没有界面窗口，启动了屏幕不会变。
 */
function parseLauncherEntries(raw: string): LauncherEntry[] {
  const start = raw.indexOf('{');
  if (start < 0) {
    return [];
  }
  let dump: BundleDump;
  try {
    dump = JSON.parse(raw.slice(start)) as BundleDump;
  } catch (err) {
    return [];
  }
  const out: LauncherEntry[] = [];
  const modules: DumpModule[] = dump.hapModuleInfos ?? [];
  for (const mod of modules) {
    const abilities: DumpAbility[] = mod.abilityInfos ?? [];
    for (const ability of abilities) {
      const name: string = ability.name ?? '';
      if (name.length === 0 || !isLauncherAbility(ability)) {
        continue;
      }
      // 老字段名是 visible，新的是 exported，两者都要看
      const exported: boolean = ability.exported === undefined ?
        ability.visible === true : ability.exported === true;
      out.push({
        ability: name,
        moduleName: ability.moduleName ?? mod.name ?? '',
        exported,
        hasIcon: (ability.iconId ?? 0) !== 0,
        hasLabel: (ability.labelId ?? 0) !== 0
      });
    }
  }
  return out;
}

/**
 * 多个候选时挑一个。四档依次放宽：导出且有图标有标签 → 导出且有图标 → 导出 → 全部。
 *
 * 这套优选是从真机数据倒推的：微信的 VoIPMPSubWindow 没图标没标签也未导出，
 * 天际通三个候选全都未导出（它本就不该出现在桌面上）。
 * 全量 198 个应用里，这四档把 95 个有入口的应用收敛到 85 个唯一确定，
 * 剩下 10 个多为工程测试类应用，取第一个并在日志里列出其余候选。
 */
function pickLauncherEntry(list: LauncherEntry[]): LauncherEntry | null {
  const tiers: LauncherEntry[][] = [
    list.filter((e: LauncherEntry) => e.exported && e.hasIcon && e.hasLabel),
    list.filter((e: LauncherEntry) => e.exported && e.hasIcon),
    list.filter((e: LauncherEntry) => e.exported),
    list
  ];
  for (const tier of tiers) {
    if (tier.length > 0) {
      return tier[0];
    }
  }
  return null;
}

export class DeviceControl {
  private readonly conn: HdcConnection;
  private readonly ctx: ObserveContext;
  private readonly settings: ActionSettings;
  private readonly log: LogSink;
  /**
   * **我们自己**最近一次读到的屏幕。每个动作后自动刷新，用来做前后对比、取屏幕尺寸、
   * 以及给 click 找"那个点落在哪个元素里"。
   *
   * 这行注释原来写的是「模型看到的那一份观测；编号就是在它上面编的」——
   * 那句话是假的，而 resolveTarget 曾经按那句话在这份表上查号。故障经过见 resolveTarget。
   */
  private lastObservation: Observation | null = null;
  /**
   * **模型看过**的那张表。只有真把整张带编号的清单发给它时才更新（见 reportAndRemember、
   * observeScreen、waitMs）。模型报的编号一律在这张上查。
   */
  private shownObservation: Observation | null = null;
  /** 收到中断请求。长等待会分片检查它，好让停手不必等一觉睡完。 */
  private cancelled: boolean = false;
  /**
   * 当前在飞的 agent 命令的通道号。正常只有一条，但 `draw` 会连发多批，所以用集合。
   * 只登记走 `run()` 的命令 —— 屏幕看守走 `runGuard()`，不在这里，不会被中断掐掉。
   */
  private readonly liveAgentChannels: Set<number> = new Set<number>();

  constructor(conn: HdcConnection, ctx: ObserveContext, settings: ActionSettings, log: LogSink) {
    this.conn = conn;
    this.ctx = ctx;
    this.settings = settings;
    this.log = log;
  }

  getLastObservation(): Observation | null {
    return this.lastObservation;
  }

  /**
   * agent 动作的命令出口。**所有工具动作都必须走这里。**
   *
   * 它做两件事：把通道号登记下来，命令结束后注销。登记的意义在于
   * `requestCancel()` 能立刻掐掉在飞的那条 —— 用户按「停止」或屏幕看守发出中断时，
   * 不必再等满整个超时。
   *
   * 屏幕看守自己的命令**不要**走这里，走 `runGuard`：它不该被自己触发的中断掐掉。
   */
  private async run(command: string, timeoutMs: number): Promise<string> {
    const pending = this.conn.startCommand(command, timeoutMs);
    this.liveAgentChannels.add(pending.channelId);
    try {
      return await pending.result;
    } finally {
      this.liveAgentChannels.delete(pending.channelId);
    }
  }

  /**
   * 屏幕看守与起任务前预检的命令出口。**不登记通道号**，所以中断不会掐它。
   *
   * 为什么要分开：中断是由看守自己发出的，把看守正在读的那条命令一起掐掉，
   * 只会在时间线里多出一句「屏幕看守这一拍失败」，而它下一拍本来就会重来。
   */
  private async runGuard(command: string, timeoutMs: number): Promise<string> {
    return await this.conn.executeCommand(command, timeoutMs);
  }

  /** 追加退出码标记后执行；仅用于会返回真实退出码的命令（uinput、bm clean 等）。 */
  private async runMarked(command: string, timeoutMs: number): Promise<MarkedOutput> {
    const wrapped = `${command}; code=$?; printf '\n${EXIT_MARKER}%s\n' "$code"`;
    const raw = await this.run(wrapped, timeoutMs);
    const at = raw.lastIndexOf(`\n${EXIT_MARKER}`);
    if (at < 0) {
      throw new Error(`命令输出缺少退出码标记: ${raw.trim()}`);
    }
    const body = raw.substring(0, at).trim();
    const tail = raw.substring(at + EXIT_MARKER.length + 1).trim().split('\n')[0];
    const code = Number.parseInt(tail, 10);
    if (Number.isNaN(code)) {
      throw new Error(`退出码无效: ${tail}`);
    }
    return { output: body, exitCode: code };
  }

  private async observeOnce(): Promise<Observation> {
    // 传 run 而不是连接对象：界面转储也是 agent 的动作，按停止时要能立刻掐掉。
    return await observe(
      (command: string, timeoutMs: number) => this.run(command, timeoutMs),
      this.ctx,
      this.settings.commandTimeoutMs
    );
  }

  /**
   * 窗口级快照：约 150 ms，是完整观测的八分之一。
   * 用于只需要窗口级信息的场合（判断锁屏、键盘、前台切换），不用于判稳。
   */
  async quickState(): Promise<QuickState> {
    const raw = await this.run(WINDOW_PROBE_COMMAND, this.settings.commandTimeoutMs);
    const lines = raw.split('\n');
    let headerAt = -1;
    for (let i = 0; i < lines.length; i += 1) {
      if (lines[i].indexOf('WindowName') >= 0 && lines[i].indexOf('ZOrd') >= 0) {
        headerAt = i;
        break;
      }
    }
    const foreground: string[] = [];
    let focusWindowId = '';
    if (headerAt >= 0) {
      for (let i = headerAt + 1; i < lines.length; i += 1) {
        const line = lines[i].trim();
        if (line.length === 0) {
          continue;
        }
        // 前台与后台之间是一条纯短横线分隔行。
        if (/^-{20,}$/.test(line)) {
          break;
        }
        const name = line.split(/\s+/)[0];
        if (name.length > 0) {
          foreground.push(name);
        }
      }
    }
    const focus = /Focus window:\s*(\d+)/.exec(raw);
    if (focus !== null) {
      focusWindowId = focus[1];
    }
    let locked = false;
    let keyboardVisible = false;
    for (const name of foreground) {
      if (name.indexOf(LOCK_WINDOW_PREFIX) === 0) {
        locked = true;
      }
      if (name.indexOf(KEYBOARD_WINDOW_PREFIX) === 0) {
        keyboardVisible = true;
      }
    }
    return { locked, keyboardVisible, focusWindowId, foregroundWindows: foreground };
  }

  /**
   * 轮询直到界面稳定，连续两次完全相同即认为动作已落地。
   *
   * 只能用完整观测：窗口探针虽然便宜 8 倍，但实测对页面内部变化失明（输入文字后
   * 它的输出逐字节不变），拿它判稳会让上层拿着过期状态继续动作。
   * 实测单次完整观测 1.2 秒（轻页面）到 2.2 秒（重页面），所以采样之间只留很小的间隙。
   */
  private async waitStable(): Promise<Observation> {
    let prev = await this.observeOnce();
    const deadline = Date.now() + this.settings.stableTimeoutMs;
    while (Date.now() < deadline) {
      await sleep(this.settings.pollIntervalMs);
      const next = await this.observeOnce();
      if (sameObservation(prev, next)) {
        return next;
      }
      prev = next;
    }
    this.log('[agent] 界面在判稳窗口内始终在变，按最后一次采样继续');
    return prev;
  }

  private isBlacklisted(bundle: string): boolean {
    for (const item of this.settings.blacklistBundles) {
      if (item.length > 0 && item === bundle) {
        return true;
      }
    }
    return false;
  }

  /**
   * 每个动作前的准入检查。返回拒绝原因，或 null 表示可以继续。
   * 锁屏时一切动作都不可能成功（实测 `aa start` 被系统以 10106102 拒绝、注入穿不过锁屏），
   * 所以这里直接拦掉，而不是让模型去撞墙。
   */
  private guard(obs: Observation): string | null {
    if (obs.locked) {
      // 不要在这里让模型「调 request_unlock」：没有这个 tool。解锁是应用侧的事 ——
      // AgentLoop 发现锁屏会自己暂停任务、等用户解锁，模型什么都不用做。
      return '设备已锁屏，动作不会生效。任务已自动暂停等用户解锁。';
    }
    if (obs.foregroundBundle === this.ctx.ownBundle) {
      // 光说"禁止操作"不够用：任务刚开始时前台必然是本应用，模型第一步调 observe 就撞上
      // 这句，然后只能自己猜出要先 launch_app。真机上撞过两回，各白费一个回合。
      return '当前前台是本应用自身，禁止操作，以免中断 agent 自己的连接。' +
        '要操作哪个应用，先用 launch_app 把它切到前台。';
    }
    if (this.isBlacklisted(obs.foregroundBundle)) {
      return `应用 ${obs.foregroundBundle} 在黑名单中，禁止操作。`;
    }
    return null;
  }

  /**
   * 把模型给的编号解析成当前界面里的真实元素。
   *
   * 查号**只能在模型看过的那张表上查**，不能在我们自己那张上查。这一行的由来是一次
   * 真机故障：原来用的是 `lastObservation`，那份每个动作后都自动重排一次、永远最新，
   * 而模型收到的只有标签差异、一个编号都没有。于是模型下一步必须报号时只能自己编，
   * 编出来的小数字在那张永远最新的表上几乎总能查到个东西 —— 就照点了。实测它报 10，
   * 那张表上 10 号是搜索框图标，便签是 12 号，于是搜索框被点开、白费三个回合。
   *
   * 换成"模型看过那张"之后不需要判断编号新旧：它读的是第几张表，我们就在第几张上查，
   * 查出来的正是它想指的那个东西；再按身份（无障碍 id / 控件 id / 标签文字）在新一次
   * 观测里找回来。下面那三句报错本来就写好了，以前永远触发不到。
   */
  private async resolveTarget(index: number): Promise<ObservedElement | string> {
    const seen = this.shownObservation;
    if (seen === null) {
      return '还没有任何观测结果，请先调用 observe。';
    }
    const remembered = findByIndex(seen, index);
    if (remembered === null) {
      return `编号 ${index} 不在上一次观测结果中。请重新 observe 后再操作。`;
    }
    const fresh = await this.observeOnce();
    this.lastObservation = fresh;
    const blocked = this.guard(fresh);
    if (blocked !== null) {
      return blocked;
    }
    const current = resolveElement(remembered, fresh);
    if (current === null) {
      return `编号 ${index}（${flatLabel(remembered.label)}）在当前界面已经不存在，界面可能已经变化。请重新 observe。`;
    }
    if (!current.enabled) {
      return `编号 ${index}（${flatLabel(current.label)}）当前处于不可用状态，点它不会有任何效果。`;
    }
    return current;
  }

  /** 执行一次注入并回传动作后的界面。注入本身的返回值不可信，成败一律看界面。 */
  private async injectAndReport(command: string, before: Observation, what: string): Promise<ActionResult> {
    try {
      await this.run(command, this.settings.commandTimeoutMs);
    } catch (err) {
      const message = (err as Error).message;
      this.log(`[agent] ${what} 命令失败: ${message}`);
      return { ok: false, detail: `${what} 执行失败: ${message}`, observation: before };
    }
    const after = await this.waitStable();
    this.lastObservation = after;
    return { ok: true, detail: this.reportAndRemember(before, after), observation: after };
  }

  /**
   * 动作结果的正文，并记下"模型看过哪张表"。
   *
   * 界面变了就把整张新表发出去，同时把它记成模型手里那张 —— 编号只能按它读过的表
   * 来解释（见 resolveTarget）。没变就只回一句，模型手里那张继续有效，不动。
   */
  private reportAndRemember(before: Observation, after: Observation): string {
    const text = reportAfterAction(before, after);
    if (text !== NO_CHANGE_TEXT) {
      this.shownObservation = after;
    }
    return text;
  }

  // ---------- 观测 ----------

  /**
   * 只为闸门读一次前台身份。
   *
   * 刻意不走 `observeScreen()`：那个会把这张表记成"模型看过的"，而闸门这一份从不发给
   * 模型。记错了的后果是模型下一个编号被拿到一张它没见过的表上去解析 —— 正是
   * resolveTarget 那个故障。
   */
  async foregroundBundleFresh(): Promise<string> {
    const obs = await this.observeOnce();
    this.lastObservation = obs;
    return obs.foregroundBundle;
  }

  /** 抓取当前界面。模型每一步都从这里开始。 */
  async observeScreen(): Promise<ActionResult> {
    const obs = await this.observeOnce();
    this.lastObservation = obs;
    if (obs.locked) {
      // 锁屏时不输出任何元素，这张表没有编号可用，不能记成"模型看过的表"。
      return { ok: true, detail: renderObservation(obs), observation: obs };
    }
    const blocked = this.guard(obs);
    if (blocked !== null) {
      return { ok: false, detail: blocked, observation: obs };
    }
    this.shownObservation = obs;
    return { ok: true, detail: renderObservation(obs), observation: obs };
  }

  /**
   * 原生分辨率 JPEG 的 base64。按对齐结论不做缩放，交给 API 侧处理，
   * 代价是单张最大约 440 KB 文本要过 shell 通道。
   */
  async screenshot(): Promise<ScreenshotResult> {
    const obs = this.lastObservation ?? await this.observeOnce();
    if (obs.locked) {
      return { ok: false, detail: '设备已锁屏，不提供屏幕内容。', base64: '' };
    }
    const path = this.ctx.dumpPath.replace(/\.json$/, '.jpeg');
    const command =
      `snapshot_display -f ${path} -t jpeg >/dev/null 2>&1; base64 -w0 ${path}`;
    try {
      const raw = await this.run(command, this.settings.commandTimeoutMs);
      const b64 = raw.trim();
      if (b64.length === 0) {
        return { ok: false, detail: '截图为空。', base64: '' };
      }
      return { ok: true, detail: `截图 ${Math.round(b64.length / 1024)} KB（base64）`, base64: b64 };
    } catch (err) {
      return { ok: false, detail: `截图失败: ${(err as Error).message}`, base64: '' };
    }
  }

  // ---------- 点击类 ----------

  async tap(index: number): Promise<ActionResult> {
    return await this.clickLike(index, 'click', '点击');
  }

  async longPress(index: number): Promise<ActionResult> {
    return await this.clickLike(index, 'longClick', '长按');
  }

  async doubleTap(index: number): Promise<ActionResult> {
    return await this.clickLike(index, 'doubleClick', '双击');
  }

  private async clickLike(index: number, verb: string, label: string): Promise<ActionResult> {
    const target = await this.resolveTarget(index);
    if (typeof target === 'string') {
      return { ok: false, detail: target, observation: this.lastObservation };
    }
    const before = this.lastObservation as Observation;
    const command = `uitest uiInput ${verb} ${target.centerX} ${target.centerY}`;
    this.log(`[agent] ${label} ${target.label} @${target.centerX},${target.centerY}`);
    return await this.injectAndReport(command, before, label);
  }

  /**
   * 点画面上的一个位置。x/y 是**相对整块屏幕**的比例。
   *
   * 为什么不用"相对元素"的比例（那是最初的实现，已删）：元素这把尺子会变长变短。
   * 真机逐帧对照过 —— 备忘录那个富文本编辑器，键盘收起时高 1620 像素，弹起时只有
   * 1046，差 55%；而每点一次都会碰出文字选择菜单、把键盘顶起来。于是模型上一次
   * 标定出的换算关系，下一次就作废了：实测它单调收敛 0.68 → 0.55 → 0.28 → 0.18，
   * 落点却只从画面 48% 挪到 38%，永远追不上 26% 的目标。
   *
   * 目标在**画面**上的位置反而是稳的（编辑器顶边键盘收起 580、弹起 595，差 15 像素）。
   * 而模型唯一能测量的东西就是那张整屏截图。所以尺子必须是屏幕。
   *
   * index 不定参照系，只定边界：那个点必须落在模型声称的元素内。它不额外花钱 ——
   * resolveTarget 本来就要跑一次新鲜观测（注入前绝不能用旧转储的坐标），元素框顺手就有。
   */
  async clickInside(index: number, xRatio: number, yRatio: number): Promise<ActionResult> {
    const target = await this.resolveTarget(index);
    if (typeof target === 'string') {
      return { ok: false, detail: target, observation: this.lastObservation };
    }
    const before = this.lastObservation as Observation;
    const px = Math.round(clampUnit(xRatio) * before.screenWidth);
    const py = Math.round(clampUnit(yRatio) * before.screenHeight);
    const box = target.bounds;
    if (px < box.left || px > box.right || py < box.top || py > box.bottom) {
      // 光说"不在编号 N 里"不够用：模型还得自己猜该填几，实测因此白跑两三轮。
      // 我们手里有完整元素表，直接把那个点真正落在哪个元素里说出来。
      // 取包含该点的**最小**元素：嵌套时最小的那个才是它想点的东西。
      //
      // 几何要用新鲜的这一份算（旧表的框可能已经挪了），但报出去的编号必须换成
      // **模型那张表**上的编号 —— 否则等于又递给它一个它没见过的号，
      // 正是 resolveTarget 那个故障的同一种错。
      let host: ObservedElement | null = null;
      let hostArea = -1;
      for (const e of before.elements) {
        if (px < e.bounds.left || px > e.bounds.right || py < e.bounds.top || py > e.bounds.bottom) {
          continue;
        }
        const area = (e.bounds.right - e.bounds.left) * (e.bounds.bottom - e.bounds.top);
        if (hostArea < 0 || area < hostArea) {
          hostArea = area;
          host = e;
        }
      }
      let hint = '那里没有任何元素。';
      if (host !== null) {
        const seenHost = this.shownObservation === null ?
          null : resolveElement(host, this.shownObservation);
        hint = seenHost !== null ?
          `它落在编号 ${seenHost.index}（${flatLabel(seenHost.label)}）里。` :
          `它落在「${flatLabel(host.label)}」上，那个元素不在你手里这张清单上。请重新 observe。`;
      }
      return {
        ok: false,
        detail: `${xRatio},${yRatio} 不在编号 ${index}（${flatLabel(target.label)}）里。${hint}没有点下去。`,
        observation: before
      };
    }
    const command = `uitest uiInput click ${px} ${py}`;
    this.log(`[agent] 画面点击 ${target.label} 比例${xRatio},${yRatio} @${px},${py}`);
    return await this.injectAndReport(command, before, '画面点击');
  }

  // ---------- 滑动与拖拽 ----------

  /**
   * 在可滚动元素内滚动。方向是"内容移动的方向"的反面，与人的直觉一致：
   * down 表示往下看更多内容，手指从下往上滑。
   *
   * **滑多远靠速度，不靠手势位移。** 这是真机实测出来的：手指位移固定 200 像素，
   * velocity=800 内容走 328 像素、velocity=2000 走 614 像素、velocity=8000 直接超过一屏。
   * 所以手势位移固定在元素中段，`amount` 只调 velocity。
   *
   * 这一条是两次事故换来的：
   *
   * 第一版把 amount 当 0~1 的比例（`amount > 0 && amount <= 1 ? amount : 0.6`），
   * 而 tool 描述说的是「1 约等于一屏的一半，缺省为 1」、schema 标着 integer。
   * 三处对不上，最糟的是**任何 ≥2 的整数都不满足 `<=1`、静默退回 0.6** ——
   * 于是「要得多反而给得少」。
   *
   * 第二版改成"amount 是几个半屏、超过一屏就多滑几手"，于是 amount 大时 ratio 到 1.0，
   * 手势端点正好落在元素边缘。**而整屏可滚元素的边缘就是屏幕边缘，那里是系统手势区。**
   * 真机上模型对一个 `0.045~1.000` 的元素填了 amount:10，算出手势从 y=122 往下滑 ——
   * 而状态栏窗口就是 `[0,0][1260,123]`，那一手是"从状态栏往下拉" = 下拉通知栏。
   * 结果前台变成 sceneboard，之后 launch_app 连试三次都拉不回来，任务失败。
   *
   * 所以端点必须留在元素中段：`SCROLL_TRAVEL_RATIO` 让它们落在 30%~70%，永远不碰边缘。
   */
  async scroll(index: number, direction: ScrollDirection, amount?: number): Promise<ActionResult> {
    const target = await this.resolveTarget(index);
    if (typeof target === 'string') {
      return { ok: false, detail: target, observation: this.lastObservation };
    }
    const before = this.lastObservation as Observation;
    const box = target.bounds;
    const width = box.right - box.left;
    const height = box.bottom - box.top;
    const cx = target.centerX;
    const cy = target.centerY;
    // 手势位移固定：端点落在元素 30%~70% 处，离元素边缘和屏幕边缘都远。
    const stepY = Math.floor((height * SCROLL_TRAVEL_RATIO) / 2);
    const stepX = Math.floor((width * SCROLL_TRAVEL_RATIO) / 2);
    let fromX = cx;
    let fromY = cy;
    let toX = cx;
    let toY = cy;
    if (direction === 'down') {
      fromY = cy + stepY;
      toY = cy - stepY;
    } else if (direction === 'up') {
      fromY = cy - stepY;
      toY = cy + stepY;
    } else if (direction === 'right') {
      fromX = cx + stepX;
      toX = cx - stepX;
    } else {
      fromX = cx - stepX;
      toX = cx + stepX;
    }
    if (fromX === toX && fromY === toY) {
      return { ok: false, detail: `编号 ${index}（${flatLabel(target.label)}）区域太小，无法滚动。`, observation: before };
    }
    // amount 只调速度。设备接受 200~40000，我们的一档是 800。
    const steps = amount !== undefined && amount >= 1 ? Math.floor(amount) : 1;
    const velocity = Math.min(SCROLL_MAX_VELOCITY, SCROLL_BASE_VELOCITY * steps);
    const command = `uitest uiInput swipe ${fromX} ${fromY} ${toX} ${toY} ${velocity}`;
    this.log(`[agent] 滚动 ${target.label} ${direction} 速度 ${velocity}`);
    return await this.injectAndReport(command, before, '滚动');
  }

  async drag(fromIndex: number, toIndex: number): Promise<ActionResult> {
    const source = await this.resolveTarget(fromIndex);
    if (typeof source === 'string') {
      return { ok: false, detail: source, observation: this.lastObservation };
    }
    const seen = this.lastObservation as Observation;
    const destRemembered = findByIndex(seen, toIndex);
    if (destRemembered === null) {
      return { ok: false, detail: `目标编号 ${toIndex} 不在当前观测结果中。`, observation: seen };
    }
    const command =
      `uitest uiInput drag ${source.centerX} ${source.centerY} ` +
        `${destRemembered.centerX} ${destRemembered.centerY} 600`;
    this.log(`[agent] 拖拽 ${source.label} → ${destRemembered.label}`);
    return await this.injectAndReport(command, seen, '拖拽');
  }

  // ---------- 自由绘制 ----------

  /**
   * 在一个元素内部按归一化坐标走笔。drag 只能元素到元素，画布在界面树里是单个节点，
   * 于是 from 与 to 必然同一个点，退化成零长度拖拽（只落一个墨点）—— 这就是加这个动作的原因。
   *
   * 平台限制（真机实测，ALN-AL00 / API 24）：
   * - `uinput -T -m x1 y1 x2 y2 <ms>` 能出墨，是唯一可靠的画线原语；
   * - `-d ... -m ... -u ...` 串联报 `invalid keep times`，不可用；
   * - 一次调用里串多个 `-m` 会被当成多指坐标一起吞掉，报 `wrong number of parameters`。
   * 所以形状只能拆成一段段短直线，相邻段端点重合，视觉上即为连续笔迹。
   */
  async draw(index: number, strokes: string[]): Promise<ActionResult> {
    const target = await this.resolveTarget(index);
    if (typeof target === 'string') {
      return { ok: false, detail: target, observation: this.lastObservation };
    }
    const before = this.lastObservation as Observation;
    if (strokes.length === 0) {
      return { ok: false, detail: 'strokes 是空的，没有任何笔画可画。', observation: before };
    }
    const box = target.bounds;
    const width = box.right - box.left;
    const height = box.bottom - box.top;
    if (width < MIN_DRAW_SIDE || height < MIN_DRAW_SIDE) {
      return {
        ok: false,
        detail: `编号 ${index}（${target.label}）只有 ${width}x${height} 像素，太小，画不出东西。`,
        observation: before
      };
    }
    const commands: string[] = [];
    const problems: string[] = [];
    for (let s = 0; s < strokes.length; s += 1) {
      const points = parseStroke(strokes[s], box);
      if (points.length === 0) {
        problems.push(`第 ${s + 1} 笔没有解析出坐标点，格式应为 "x,y x,y ..."，x/y 是 0~1 的小数。`);
        continue;
      }
      if (points.length === 1) {
        commands.push(`uinput -T -c ${points[0].x} ${points[0].y}`);
        continue;
      }
      for (let i = 0; i + 1 < points.length; i += 1) {
        const a = points[i];
        const b = points[i + 1];
        if (a.x === b.x && a.y === b.y) {
          continue;
        }
        commands.push(`uinput -T -m ${a.x} ${a.y} ${b.x} ${b.y} ${DRAW_SMOOTH_MS}`);
      }
    }
    if (commands.length === 0) {
      const why = problems.length > 0 ? problems.join(' ') : '所有点都重合，没有任何一段有长度。';
      return { ok: false, detail: `没有可执行的笔画：${why}`, observation: before };
    }
    if (commands.length > MAX_DRAW_SEGMENTS) {
      return {
        ok: false,
        detail: `一次最多画 ${MAX_DRAW_SEGMENTS} 段，这次是 ${commands.length} 段。` +
          '请减少点数，或者拆成多次 draw。',
        observation: before
      };
    }
    this.log(`[agent] 绘制 ${target.label} ${strokes.length} 笔 / ${commands.length} 段`);
    // 攒批下发：每段都单独走一次 shell 往返的话，一朵花要多花十几秒。
    let injected = 0;
    const failures: string[] = [];
    for (let i = 0; i < commands.length; i += DRAW_BATCH) {
      const chunk = commands.slice(i, i + DRAW_BATCH);
      const budget = chunk.length * (DRAW_SMOOTH_MS + DRAW_PER_SEGMENT_OVERHEAD_MS) + DRAW_BATCH_SLACK_MS;
      try {
        const out = await this.run(chunk.join('; '), budget);
        injected += chunk.length;
        const bad = firstInjectionError(out);
        if (bad !== null && failures.length < 3) {
          failures.push(bad);
        }
      } catch (err) {
        return {
          ok: false,
          detail: `绘制在第 ${injected + 1} 段失败: ${(err as Error).message}。前 ${injected} 段已经画上去了。`,
          observation: before
        };
      }
    }
    const after = await this.waitStable();
    this.lastObservation = after;
    const notes: string[] = [`已注入 ${strokes.length} 笔 / ${injected} 段。`];
    if (problems.length > 0) {
      notes.push(problems.join(' '));
    }
    if (failures.length > 0) {
      notes.push(`其中有段被拒绝: ${failures.join(' / ')}`);
    }
    // 墨迹在画布节点内部，界面树里看不到，所以这里不拿界面差异当成败依据。
    notes.push('墨迹不会出现在界面树里，界面树没变化不代表没画上。要确认效果请调用 screenshot。');
    return { ok: true, detail: notes.join('\n'), observation: after };
  }

  // ---------- 文本输入 ----------

  /**
   * 先点目标聚焦再输入。实测无焦点时 `uiInput text` 会静默失败却报成功，所以聚焦不能省。
   * 纯可打印 ASCII 走 `uinput -K -t`：不碰剪贴板且退出码真实，实测也能正确处理
   * 带空格的文本（引号包裹后 `a b` 原样落地），不需要另发空格键。
   * 含非 ASCII 只能走 `uitest uiInput text`，它对非 ASCII 是**经由剪贴板粘贴**实现的，
   * 会覆盖用户剪贴板，且 shell 无法读回原值，无法还原。
   */
  async inputText(index: number, text: string): Promise<ActionResult> {
    if (text.length === 0) {
      return { ok: false, detail: '要输入的文本为空。', observation: this.lastObservation };
    }
    const target = await this.resolveTarget(index);
    if (typeof target === 'string') {
      return { ok: false, detail: target, observation: this.lastObservation };
    }
    const before = this.lastObservation as Observation;

    // 聚焦
    try {
      await this.run(
        `uitest uiInput click ${target.centerX} ${target.centerY}`,
        this.settings.commandTimeoutMs
      );
    } catch (err) {
      return { ok: false, detail: `聚焦失败: ${(err as Error).message}`, observation: before };
    }
    await sleep(this.settings.pollIntervalMs * 2);

    const ascii = isPrintableAscii(text);
    if (ascii) {
      try {
        const res = await this.runMarked(`uinput -K -t ${shellQuote(text)}`, this.settings.commandTimeoutMs);
        if (res.exitCode !== 0) {
          this.log(`[agent] uinput 输入失败(${res.exitCode})，回退到 uitest: ${res.output}`);
          await this.run(
            `uitest uiInput text ${shellQuote(text)}`,
            this.settings.commandTimeoutMs
          );
        }
      } catch (err) {
        return { ok: false, detail: `输入失败: ${(err as Error).message}`, observation: before };
      }
    } else {
      this.log('[agent] 含非 ASCII 字符，经剪贴板输入，用户剪贴板会被覆盖');
      try {
        await this.run(
          `uitest uiInput text ${shellQuote(text)}`,
          this.settings.commandTimeoutMs
        );
      } catch (err) {
        return { ok: false, detail: `输入失败: ${(err as Error).message}`, observation: before };
      }
    }

    const after = await this.waitStable();
    this.lastObservation = after;
    const diff = this.reportAndRemember(before, after);
    const landed = this.containsText(after, text);
    if (!landed) {
      return {
        ok: false,
        detail: `未能在界面上确认输入内容。uitest 会谎报成功，所以按未生效处理。\n${diff}`,
        observation: after
      };
    }
    return { ok: true, detail: diff, observation: after };
  }

  private containsText(obs: Observation, text: string): boolean {
    for (const e of obs.elements) {
      if (e.label.indexOf(text) >= 0 || e.text.indexOf(text) >= 0) {
        return true;
      }
    }
    return false;
  }

  // ---------- 按键 ----------

  /**
   * 系统按键。仅暴露已实测确认的几个：
   * - back / home / power 走 `uitest uiInput keyEvent`，按名字即可
   * - backspace 走 uinput 键码 2055（已实测），支持一次调用批量发送 N 次，
   *   比循环调用快一个数量级
   */
  async key(name: string, repeat?: number): Promise<ActionResult> {
    // 按键不需要解析元素，所以先用 150 ms 的窗口探针挡掉锁屏，省下一次完整观测。
    const quick = await this.quickState();
    if (quick.locked) {
      return {
        ok: false,
        detail: '设备已锁屏，动作不会生效。任务已自动暂停等用户解锁。',
        observation: this.lastObservation
      };
    }
    const obs = await this.observeOnce();
    this.lastObservation = obs;
    const blocked = this.guard(obs);
    if (blocked !== null) {
      return { ok: false, detail: blocked, observation: obs };
    }
    const times = repeat !== undefined && repeat > 0 ? Math.min(repeat, 200) : 1;
    const entry = findNamedKey(name);
    if (entry === null) {
      return {
        ok: false,
        detail: `不支持的按键 ${name}。可用的是: ${supportedKeyNames().join('、')}`,
        observation: obs
      };
    }
    let command = '';
    if (entry.uitestName !== undefined) {
      const parts: string[] = [];
      for (let i = 0; i < times; i += 1) {
        parts.push(`uitest uiInput keyEvent ${entry.uitestName}`);
      }
      command = parts.join('; ');
    } else {
      // uinput 支持一次调用批量发送，比循环调用快一个数量级。
      let batch = 'uinput -K';
      for (let i = 0; i < times; i += 1) {
        batch += ` -d ${entry.code} -u ${entry.code}`;
      }
      command = batch;
    }
    this.log(`[agent] 按键 ${entry.name} x${times}`);
    return await this.injectAndReport(command, obs, `按键 ${entry.name}`);
  }

  // ---------- 应用 ----------

  /** `bm dump -a -l` 一次返回全部应用的包名与标签。bm 可以过管道，但不可重定向到文件。 */
  async listApps(): Promise<AppEntry[]> {
    const raw = await this.run('bm dump -a -l', this.settings.commandTimeoutMs);
    try {
      return JSON.parse(raw.trim()) as AppEntry[];
    } catch (err) {
      throw new Error(`解析应用列表失败: ${(err as Error).message}`);
    }
  }

  /**
   * 启动应用。入口 ability 必须运行时查，而且**不能读 mainAbility 字段** ——
   * 那个字段不可靠，实测 198 个应用里有四种存法：短名、包名前缀+短名、
   * 源码文件路径（`./ets/mainAbility/X.ets`）、空。有桌面入口的 95 个应用里，
   * 按它启动只有 62 个是对的，33 个错。
   *
   * 正确的信息源是 `abilityInfos` 里**同一个 skill** 同时满足两条的那个 ability：
   *   - entities 含 `entity.system.home`
   *   - actions  含 `action.system.home` 或 `ohos.want.action.home`
   *
   * 两个 action 写法都要认：系统应用用前者，用 DevEco 建的工程用后者。
   * 必须"同一个 skill"，因为有的 ability 有多个 skill，别的 skill 里也可能带 home
   * 实体但没有 home 动作（应用市场的 SportWatchAbility 就是）。
   *
   * 只在 `abilityInfos` 里找，**不看 `extensionInfos`** —— 时钟的 AlarmService、
   * TimerService 也带 home 实体，但它们是服务扩展，没有界面窗口。启动它们
   * `aa start` 会返回成功而屏幕毫无变化，是最难查的一种"假成功"。
   */
  async launchApp(bundleName: string): Promise<ActionResult> {
    if (this.isBlacklisted(bundleName)) {
      return { ok: false, detail: `应用 ${bundleName} 在黑名单中，禁止启动。`, observation: this.lastObservation };
    }
    if (bundleName === this.ctx.ownBundle) {
      return { ok: false, detail: '禁止启动本应用自身。', observation: this.lastObservation };
    }
    const before = await this.observeOnce();
    this.lastObservation = before;
    if (before.locked) {
      return {
        ok: false,
        detail: '设备已锁屏，系统会拒绝启动应用。任务已自动暂停等用户解锁。',
        observation: before
      };
    }

    const entry = await this.resolveLauncherEntry(bundleName);
    if (entry === null) {
      return {
        ok: false,
        detail:
          `${bundleName} 没有桌面入口（清单里没有带 home 标记的页面 ability），` +
          `用 aa 启动不了。改为回到桌面后按名字找图标点击。`,
        observation: before
      };
    }

    // aa 不能被管道或重定向，否则输出会消失；并且 aa start 失败时仍返回 0，只能解析文本。
    // -m 带上模块名：实测 19 个应用的入口不在第一个模块里（招行有 40 个模块）。
    const raw = await this.run(
      `aa start -a ${shellQuote(entry.ability)} -b ${shellQuote(bundleName)}` +
      ` -m ${shellQuote(entry.moduleName)}`,
      this.settings.commandTimeoutMs
    );
    const text = raw.trim();
    if (text.indexOf('successfully') < 0) {
      const locked = text.indexOf('10106102') >= 0;
      // 10107102 是权限拒绝，与 ability 名对不对无关：换名字重试没有意义。
      // 实测有应用的桌面入口就是不允许外部启动（多设备协同、手机克隆、智慧助手）。
      const denied = text.indexOf('10107102') >= 0;
      let detail = `启动失败：${text}`;
      if (locked) {
        detail = '设备锁屏导致启动被拒。任务已自动暂停等用户解锁。';
      } else if (denied) {
        detail =
          `系统拒绝启动 ${bundleName} 的入口 ${entry.ability}（10107102，进程无权限）。` +
          `这不是入口名找错了，换名字重试没有意义。改为回到桌面后按名字找图标点击。`;
      }
      return { ok: false, detail, observation: before };
    }
    const after = await this.waitStable();
    this.lastObservation = after;
    return { ok: true, detail: this.reportAndRemember(before, after), observation: after };
  }

  /**
   * 找出桌面入口。返回 null 表示这个应用没有能用 aa 启动的入口。
   *
   * 要把整份 `bm dump -n` 拉回来解析 JSON。实测体积 19 KB ~ 302 KB，
   * 回传约 350 ms —— 相比 grep 一行多花的这点时间换来的是正确率从 65% 到 100%。
   * 输出前面有个 `包名:` 前缀，从第一个 `{` 开始才是 JSON。
   *
   * `bm dump` 的输出**不能重定向到文件**（写出来是空的），管道是可以的。
   */
  private async resolveLauncherEntry(bundleName: string): Promise<LauncherEntry | null> {
    let raw = '';
    try {
      raw = await this.run(`bm dump -n ${shellQuote(bundleName)}`, this.settings.commandTimeoutMs);
    } catch (err) {
      this.log(`[agent] 查询 ${bundleName} 的应用信息失败: ${(err as Error).message}`);
      return null;
    }
    const entries = parseLauncherEntries(raw);
    if (entries.length === 0) {
      return null;
    }
    const picked = pickLauncherEntry(entries);
    if (entries.length > 1 && picked !== null) {
      const others = entries
        .filter((e: LauncherEntry) => e.ability !== picked.ability)
        .map((e: LauncherEntry) => e.ability)
        .join('、');
      this.log(`[agent] ${bundleName} 有多个桌面入口，选 ${picked.ability}，其余：${others}`);
    }
    return picked;
  }

  // ---------- 锁屏与保活 ----------

  /**
   * 读取系统当前的息屏时长，用于按真实值安排保活心跳，而不是猜一个间隔。
   *
   * 注意 `hidumper` 与 `aa` 同类：输出一旦经过管道就会消失，所以这里必须裸跑，
   * 由本地解析取值。返回 0 表示读取失败。
   */
  async readScreenOffTimeoutMs(): Promise<number> {
    let raw = '';
    try {
      raw = await this.runGuard('hidumper -s PowerManagerService -a "-s"', this.settings.commandTimeoutMs);
    } catch (err) {
      this.log(`[agent] 读取息屏时长失败: ${(err as Error).message}`);
      return 0;
    }
    // OverrideTimeout 存在时它才是生效值。只读 Timeout 会在本应用自己写过
    // 一次性覆盖之后拿到偏短的数字，推导出的心跳间隔也就跟着错。
    const override = /OverrideTimeout\s*=\s*(\d+)ms/.exec(raw);
    if (override !== null) {
      const overrideValue = Number.parseInt(override[1], 10);
      if (!Number.isNaN(overrideValue) && overrideValue > 0) {
        return overrideValue;
      }
    }
    const matched = /ScreenOffTime:[^\n\r]*?\bTimeout\s*=\s*(\d+)ms/.exec(raw);
    if (matched === null) {
      return 0;
    }
    const value = Number.parseInt(matched[1], 10);
    return Number.isNaN(value) ? 0 : value;
  }

  /**
   * 看守一拍的间隔，由设备真实息屏时长推导，不写死。两个约束取更小的那个：
   *
   * - `t/3` 保证亮屏心跳明显跑在息屏前面。取三分之一是安全系数而非设备参数：
   *   实测 `power-shell wakeup` **不会**重置空闲计时器（电源转储里的 `Last Refresh`
   *   调用前后完全不变），它只是每次强行把屏幕再点亮一次；间隔一旦接近息屏时长，
   *   两次心跳之间屏幕就会先变暗甚至睡过去。
   * - 上限 7 秒保证按下电源键之后很快被发现。
   *
   * 读不到息屏时长时**退回上限**，由调用方决定要不要提示。
   *
   * 这里原先叠着两份注释，前一份说"读不到时长时返回 0" —— 与代码相反（返回的是上限）。
   * 通读全文时发现的，已合成一份。
   */
  async suggestGuardIntervalMs(): Promise<number> {
    const timeout = await this.readScreenOffTimeoutMs();
    if (timeout <= 0) {
      return SCREEN_GUARD_MAX_INTERVAL_MS;
    }
    const third = Math.floor(timeout / 3);
    return third < SCREEN_GUARD_MAX_INTERVAL_MS ? third : SCREEN_GUARD_MAX_INTERVAL_MS;
  }

  /**
   * 看守一拍：先判断该不该停，只有不该停才去点亮屏幕。
   *
   * 顺序不能颠倒。早先设想的是无脑每拍 `wakeup`，那样用户按电源键熄屏想停下 agent 时，
   * 下一拍会把屏幕又点亮、任务继续跑，等于用户按不停它。
   *
   * 已知残留竞态：如果用户恰好在「读到 AWAKE」与「发出 wakeup」之间那约 150 毫秒里
   * 按下电源键，这一拍会把屏幕重新点亮，这次按键就丢了。没有采用「只在 DIM 时点亮」
   * 来消除它 —— DIM 窗口只有几秒，一旦某拍错过就会睡过去造成**误中断**，
   * 丢掉一次按键只是要用户再按一次，误杀任务的代价大得多。
   */
  async screenGuardTick(): Promise<ScreenGuardTick> {
    let raw = '';
    try {
      raw = await this.runGuard(
        `hidumper -s PowerManagerService -a "-s"; echo ${GUARD_SPLIT}; ${WINDOW_PROBE_COMMAND}`,
        this.settings.commandTimeoutMs
      );
    } catch (err) {
      this.log(`[guard] 读取屏幕状态失败: ${(err as Error).message}`);
      return { ok: false, shouldStop: false, reason: '' };
    }
    const parts = raw.split(GUARD_SPLIT);
    const powerPart = parts[0];
    const windowPart = parts.length > 1 ? parts[1] : '';

    const state = /Current State:\s*(\w+)/.exec(powerPart);
    if (state === null) {
      this.log('[guard] 电源转储里没有 Current State，这一拍作废');
      return { ok: false, shouldStop: false, reason: '' };
    }
    // DIM 是即将熄灭的中间态，屏幕还看得见，算亮着并且要立刻点回去。
    if (state[1] !== 'AWAKE' && state[1] !== 'DIM') {
      return { ok: true, shouldStop: true, reason: `屏幕已熄灭（${state[1]}）` };
    }
    if (this.lockWindowInForeground(windowPart)) {
      return { ok: true, shouldStop: true, reason: '设备处于锁屏状态' };
    }
    try {
      await this.runGuard('power-shell wakeup', this.settings.commandTimeoutMs);
    } catch (err) {
      this.log(`[guard] 点亮屏幕失败: ${(err as Error).message}`);
    }
    return { ok: true, shouldStop: false, reason: '' };
  }

  /** 只看前台段里有没有锁屏窗口；后台段里那条常驻的不算。 */
  private lockWindowInForeground(windowDump: string): boolean {
    const lines = windowDump.split('\n');
    let headerAt = -1;
    for (let i = 0; i < lines.length; i += 1) {
      if (lines[i].indexOf('WindowName') >= 0 && lines[i].indexOf('ZOrd') >= 0) {
        headerAt = i;
        break;
      }
    }
    if (headerAt < 0) {
      return false;
    }
    for (let i = headerAt + 1; i < lines.length; i += 1) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      if (/^-{20,}$/.test(line)) {
        break;
      }
      if (line.split(/\s+/)[0].indexOf(LOCK_WINDOW_PREFIX) === 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 上限必须与 AgentTools 里 wait 的描述、以及 AgentLoop 的夹取值三者一致。
   * 早先这里是 30000 而描述写 60000，模型要求等 60 秒只等到 30 秒，
   * 回复还写着"已等待 30000 毫秒"—— 夹取了就要说，不然模型会以为自己等够了。
   */
  /**
   * 请求取消。两条中断路径都走这里：用户按「停止」，以及屏幕看守发现该停了。
   *
   * 做两件事：
   * 1. 置标记 —— 长等待（`waitMs`）分片检查它，好让停手不必等一觉睡完
   * 2. 掐掉在飞的那条命令 —— 否则主循环卡在 `await` 上，最坏要等满整个超时
   *    才回到检查点。这是「按停止要等 20 秒」的根源
   *
   * 只掐登记过的（即 `run()` 发出的 agent 动作）。屏幕看守、终端页、电源页的命令
   * 都不在登记里，不受影响。
   */
  requestCancel(): void {
    this.cancelled = true;
    const ids: number[] = [];
    this.liveAgentChannels.forEach((id: number) => {
      ids.push(id);
    });
    for (const id of ids) {
      this.conn.abortCommand(id, CANCEL_REASON);
    }
  }

  clearCancel(): void {
    this.cancelled = false;
  }

  async waitMs(ms: number): Promise<ActionResult> {
    const capped = Math.max(0, Math.min(ms, WAIT_MAX_MS));
    // 切片睡而不是一觉睡到底：真机实测里屏幕看守在 wait 中途发出中断，
    // 而整觉睡完才返回，于是「停手」被这一觉拖了 30 秒。
    const started = Date.now();
    let slept = 0;
    while (slept < capped && !this.cancelled) {
      const slice = Math.min(WAIT_SLICE_MS, capped - slept);
      await sleep(slice);
      slept = Date.now() - started;
    }
    if (this.cancelled) {
      return {
        ok: true,
        detail: `等待被中断，实际只等了 ${slept} 毫秒（请求 ${ms} 毫秒）。`,
        observation: this.lastObservation
      };
    }
    const obs = await this.observeOnce();
    this.lastObservation = obs;
    // wait 之所以也发整张表：等的就是屏幕自己变（下载完、短信到），等完编号很可能已经变了。
    if (!obs.locked) {
      this.shownObservation = obs;
    }
    const note = capped < ms ? `（请求 ${ms} 毫秒，已按上限 ${WAIT_MAX_MS} 截断）` : '';
    return {
      ok: true,
      detail: `已等待 ${capped} 毫秒。${note}\n${renderObservation(obs)}`,
      observation: obs
    };
  }
}
