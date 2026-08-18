import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { picker, fileUri, fileIo } from '@kit.CoreFileKit';
import { HdcConnection, AuthResult, AuthOutcome, ConnectOptions } from '../hdc/HdcConnection';
import { FILE_CHUNK_BYTES } from '../hdc/HdcFileChannel';
import { DEFAULT_VERSION } from '../hdc/HdcTypes';
import { generateKeyPair, HdcKeyPair } from '../hdc/HdcCrypto';
import { hasKeyPair, loadKeyPair, saveKeyPair, clearKeyPair } from '../hdc/HdcKeyStore';
import { HdcShellChannel } from '../hdc/HdcShellChannel';
import { TerminalEmulator } from '../hdc/TerminalEmulator';
import {
  loadConnection,
  saveConnection,
  loadBundleSystemMap,
  saveBundleSystemMap
} from '../hdc/HdcSettings';
import { listBundles, clearBundleData, installHapFromUri, BundleEntry, ListBundlesResult, HapInstallResult } from '../hdc/BundleManager';
import { DeviceControl, ActionSettings } from '../agent/DeviceControl';
import { ObserveContext } from '../agent/Observer';
import {
  loadAgentConfig, saveAgentConfig, isAgentConfigured, describeMissing, maskApiKey,
  DEFAULT_CONTEXT_LIMIT_TOKENS,
  DEFAULT_KEEP_SCREENSHOTS
} from '../agent/AgentSettings';
import type { AgentConfig } from '../agent/AgentSettings';
import { AnthropicClient } from '../agent/AnthropicClient';
import { AgentLoop, defaultLimits } from '../agent/AgentLoop';
import type { AgentEvent, AgentHooks } from '../agent/AgentLoop';
import {
  saveSession, loadSessionById, loadIndex, registerSession, newSessionId, clearAllSessions
} from '../agent/AgentSession';
import type { StoredTimelineEntry } from '../agent/AgentSession';
import { KeepAlive } from '../agent/KeepAlive';
import type { KeepAliveHooks } from '../agent/KeepAlive';
// 用来把某一段存档里的计划算成「x/y」。复用它而不另写一套计数，
// 免得「放弃的项算不算分母」这类规则在两处走样。
import { TodoStore } from '../agent/TodoStore';
import type { TodoItem } from '../agent/TodoStore';

const MAX_LOG_LINES: number = 500;
const MAX_OUTPUT_BUFFER_CHARS: number = 32000;
const MAX_OUTPUT_RENDER_CHARS: number = 16000;
const TERMINAL_FLUSH_DELAY_MS: number = 80;
const TERMINAL_SCROLL_DELAY_MS: number = 16;
/**
 * 终端逻辑列宽。**必须与 onConnect 发给 shell 的 `COLUMNS=` 同值**，两处共用本常量。
 *
 * daemon 开 PTY 从不设 winsize，mksh 行编辑器回退 80 列并对超宽命令横向滚动——
 * 回显只剩最后 79 列的窗口 + `<` 标记（2026-08-18 真机实测，完整链条见
 * doc/terminal-echo.md）。设备没有 stty 改不了内核 winsize，但 mksh 尊重
 * COLUMNS shell 变量（同样真机实测：设 200 后 155 列命令完整回显、无 `<`）。
 */
const TERMINAL_COLUMNS: number = 200;

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
const AGENT_DUMP_PATH: string = '/data/local/tmp/hdc_agent_layout.json';
// 判稳采样之间的间隙。一次完整观测本身要 1.2~2.2 秒（实测），所以这里只是喘息值。
const AGENT_POLL_INTERVAL_MS: number = 150;
// 必须容得下重页面的两次完整观测（各约 2.2 秒），否则永远采不满两个样本。
const AGENT_STABLE_TIMEOUT_MS: number = 8000;
/**
 * 单条命令超时。**不要往上调。** 这是唯一限制「一条飞在途中的命令卡住循环多久」的值 ——
 * `HdcUnityCommandChannel.execute()` 只有设备回包或本定时器超时两种结局，没有取消接口，
 * 所以它同时决定了屏幕看守发出中断后最坏要等多久才真正生效。
 */
const AGENT_COMMAND_TIMEOUT_MS: number = 10000;
/**
 * 翻会话的手势门槛。轻轻一拉不能翻页，所以距离与速度两个条件都要满足。
 * distance 是手势起判距离，TRIGGER 是真正翻页要拉过的距离。
 *
 * 这组数字是真机手感调出来的：第一版取 120vp / 600vp\/s，实际用起来"太钝、拉不动"。
 * 轻拉的典型量级是 30vp 上下、40vp\/s 左右，所以降到下面这组仍然拉不开轻拉与用力拉。
 */
const AGENT_PULL_MIN_VP: number = 10;
/**
 * 过了这个距离就翻页。**只看距离，不看速度**：空隙里要实时告诉用户「松手就翻」，
 * 若还附带速度条件，用户照着提示慢慢松手却没反应，那句提示就是在骗人。
 *
 * 这个值同时决定淡的节奏 —— 透明度按「拉了多少 / 这个值」算，
 * 所以调大它也让淡变得更缓，两件事一个数字管。
 *
 * 200（约 600px，屏幕高度两成多）是**用户实测后选定的值**：70 被反馈太灵敏会误翻，
 * 200 被反馈「更顺手」。这个值原本是为了排查装机没生效而临时放大的，
 * 结果比我原先打算调的 100~120 更合手，就留下了。不要再按「合理值」往回调。
 */
const AGENT_PULL_TRIGGER_VP: number = 200;
/** 空隙里开始显示提示的距离。比触发线小得多，让人一拉就知道这里有东西。 */
const AGENT_PULL_HINT_VP: number = 12;
// 这里曾有 `AGENT_EDGE_SLACK_VP`（判定贴边允许的像素误差）。**已删除。**
// 贴边现在按可见子项的下标判，不再拿滚动偏移和阈值比 —— 那个比较在「内容不满一屏」
// 和「布局还没完成」两种情形下都会判错。见 timelinePage 里 onScrollIndex 处的注释。
// 这里曾有 `AGENT_LAND_MAX_TRIES`（试够几次就放弃）和 `AGENT_LAND_RETRY_MS`
// （按几个时间点补催落点）两个常量，连同 `pendingLand` / `landPage` / `scheduleLand`
// 一整套「追着布局完成的那一刻去滚到底」的机制。**全部删除，不要重新发明。**
//
// 那套机制修了三次都修不好，因为它想做的事情本身不成立：在某个瞬间判定"我已经在底部了"，
// 而内容高度在那之后还在变 —— 后来量出来布局要**五秒**才完成，任何毫秒级的判据都问不出结果。
//
// 换成 `agentStickBottomUntil`：一段有界的时间窗内，每次布局变化都无条件重贴末尾。
// 它和被删的那套的根本区别是**不判断，也不放弃**。经过见 `doc/agent-session-ui.md`。
/** 键盘弹起时输入行与键盘之间留多少。收起时不用这个值，见输入行处的注释。 */
const AGENT_INPUT_GAP_ON_KEYBOARD_VP: number = 10;
/**
 * 输入框的字号，取系统正文档 `body1`。
 *
 * 全应用的字号都挂在系统 token 上，不写数字：同一个 token 在不同设备与不同字体缩放下
 * 解析成不同的值（本机资源里 `body1` 在手机配置是 16fp、在另一种配置是 18fp），
 * 写死数字在后一种配置上就是错的。
 *
 * 挑 `body1` 的第二个原因：输入框的**灰字**默认用的就是它。真实值挂同一个 token
 * 之后，两者再也不可能一大一小 —— 那正是把它们分开写的老毛病。
 *
 * 试过提到 `sub_title1`（18fp）让输入框变大，观感不好，已改回。要加大输入框请调行数
 * （`AGENT_INPUT_MAX_LINES`）或起步行数，不要动字号 —— 字号一变，灰字、按钮、周围
 * 标签的相对关系全跟着变。
 */
const INPUT_FONT_SIZE: Resource = $r('sys.float.ohos_id_text_size_body1');
/**
 * 任务输入框最多显示几行，超过就在框内自己滚。
 * 不封顶的话一段长描述能把输入行顶到半屏高，把时间线挤没。
 */
const AGENT_INPUT_MAX_LINES: number = 4;
/**
 * 输入框上下内边距的近似值。
 *
 * 它只决定封顶落在 3.9 行还是 4.1 行上，所以不必精确，也**不需要**换设备重新量 ——
 * 真正随设备与系统字号变化的是行高，那个是运行时量出来的（见 `measureInputMaxHeight`）。
 * 同一个值也用来推**一行时的最小高度**，让 AGENT 的 TextArea 和别处的 TextInput 齐平。
 */
const AGENT_INPUT_PAD_SLACK_VP: number = 16;
/**
 * 量不到行高时的退路值。
 *
 * **这是退路，不是依据。** 它来自一次真机测量（`fontSize(14)` 下四行盒子高 264px，
 * 按 3.25 密度折算约 81vp），所以只在那台设备的默认字号下准确。
 * 正常路径永远不会用到它。
 */
const AGENT_INPUT_MAX_HEIGHT_FALLBACK_VP: number = 81;
/**
 * 量不到行高时，一行高度的退路值。
 *
 * **这是退路，不是依据。** 由 81vp 那个四行退路除以行数再加回内边距推得，
 * 只在那台设备的默认字号下准确。正常路径永远不会用到它。
 */
const AGENT_INPUT_MIN_HEIGHT_FALLBACK_VP: number = 40;

/*
 * 这里曾有 `AGENT_KEYBOARD_FOLLOW_MS = 250`：内容跟随键盘上移的动画时长，
 * 注释写着「不带动画时用户看到的是聊天内容直接闪现」。**那句话是我凭想象写的，从未验证。**
 *
 * 真机日志证明键盘、页面、输入行都是一步到位（`beginH == endH`，一次视口变化 18ms 内完成），
 * 带动画只会让内容单独落后，那条滞后就是用户报的「输入行上方一条内容闪一下」。
 * 跟随现在无动画，这个常量没有用处了。理由详见 `followKeyboardScroll`。
 */
/**
 * 模型设置改动后多久落盘。攒一下再写，免得每敲一个字符就落一次盘。
 * 500ms 足够覆盖连续打字的间隔；离开设置页时会立刻补写，所以延迟不会造成丢失。
 */
const AGENT_CONFIG_SAVE_DELAY_MS: number = 500;
/**
 * 会话写盘的攒批时长。
 *
 * 原先只在一整轮任务结束时写盘，而一轮任务可能跑十几分钟。期间进程被杀（系统回收、
 * `install -r`、崩溃）或者任务停在暂停横幅上等用户点「继续」，这段对话就整段消失。
 * 改成任何时间线事件都触发写盘，攒 2 秒合成一次：丢数据的窗口从"一整轮"缩到 2 秒，
 * 而一个回合本来就要好几秒，所以实际写盘频率大约是每回合一到两次。
 */
const AGENT_SESSION_SAVE_DELAY_MS: number = 2000;
/**
 * 内容刚换好之后盯住落点多久。
 *
 * 探针实测：应用被拉回前台时列表内容要**五秒**才布局完（`onReachEnd` 报的偏移从 −360
 * 变成 2769）。所以这个窗口必须明显长于那个量级，否则又是打在空壳上。
 * 见 `agentStickUntil`。
 */
const AGENT_STICK_MS: number = 8000;
/**
 * 追加一条消息之后盯落点多久。
 *
 * 比 `AGENT_STICK_MS` 短两个数量级，因为要盯的事完全不同：这里等的只是**一条新子项的
 * 布局**（一帧的量级），不是"应用从后台回来、整页内容从零布局出来"（实测五秒）。
 * 开长了反而有害 —— 窗口开着时 `onAreaChange` 的键盘补偿会主动让位（见那里的注释），
 * 而任务跑起来消息是一条接一条的，长窗口等于把键盘补偿常态性地关掉。
 */
const AGENT_FOLLOW_STICK_MS: number = 400;
/**
 * 追加消息后补贴落点的两拍（毫秒）。
 *
 * **为什么光靠盯底窗口不够。** 窗口的驱动是 `onReachEnd` / `onScrollIndex`
 * （见 timelinePage 那几个回调）。页面刚进入时它们必然触发 —— 内容从空变满，
 * 子项大量进出视区。但"在底部追加一条"这个时机不一样：新那条整个落在折叠线下面时，
 * 可见范围的首尾下标都没变、列表也不在末尾，两个回调**一个都不来**，窗口就白开了。
 *
 * 所以补两拍不依赖任何回调的定时。60ms 约三四帧，足够一条子项完成布局；
 * 200ms 是保底。两拍都以盯底窗口为判据（`agentStickPage` / `agentStickUntil`），
 * 所以用户一拖（`onWillScroll` 撤掉窗口）这两拍自动作废。
 *
 * 这**不是**被删掉的那套 `pendingLand` 重试机制：没有"判定到位"、没有"试几次就放弃"，
 * 也不自己决定该落在哪 —— 落哪、还该不该落，全由窗口说话。
 */
const AGENT_FOLLOW_CATCHUP_MS: number[] = [60, 200];
/**
 * 只有开关、没有说明文字的那一格的高度。
 * 取 48 是为了和「标题 13 + 说明 11 + 行距」那种两行格子视觉重量相当；
 * 字号在这个高度里自适应放大，不会显得空。
 */
const AGENT_SETTING_ROW_HEIGHT_VP: number = 48;
/*
 * 换段的过渡动效不在这里定义 —— 它由 Swiper 自带的弹簧翻页提供
 * （默认曲线 interpolatingSpring(-1,1,328,34)）。
 *
 * 手写过五种全被否掉：淡入 120ms（花）、瞬现但要等回弹（更难受）、
 * 方向性滑入加淡入（卡顿花眼）、只淡出 120ms（延迟太高）、
 * 零动画零等待（1↔2 极其生硬，2↔3 仍软弹）。之后又试过关掉内层回弹，
 * 结果「一切都变得极其生硬」—— 那点回弹正是「软」的来源，不能删。
 *
 * 真正的缺陷是结构性的：回弹和换内容在同一个滚动容器里抢位置。
 * 官方在 Scroll 的 onScrollFrameBegin 里写明过这类冲突会让嵌套滚动失效。
 * 现在一段一页，回弹只作用在自己那页上，翻页动效由组件负责，两者不再相干。
 */

/**
 * 被划走那一页最多淡到多深。0.55 表示最淡时还剩 45% 不透明。
 *
 * 曾经是 0.95（只剩 5%），用户反馈「被划走的有点太淡了」。
 * 这个值同时管拉动过程中的淡和翻页过程中的淡 —— 都是同一页在变淡。
 */
const AGENT_FADE_OUT_DEPTH: number = 0.55;
/** 新进来那一页起始有多淡。同样是 0.55，起点越亮，浮现所需的距离越短。 */
const AGENT_FADE_IN_DEPTH: number = 0.55;
/**
 * 新那页在滑过多少路程时就完成浮现。0.25 表示滑过四分之一就已经全亮，其余路程保持不变。
 *
 * 不设这个的话，浮现是均摊在整段路程上的，加上 EaseInOut 起步慢，
 * 前段时间几乎没有亮度变化 —— 那就是「新的浮现的速度有点慢」的来源。
 * 依次试过 0.5（仍偏慢）、0.25（当前）。再要快就往 0.15 调，
 * 那基本等于一进来就是全亮，淡入也就看不出来了。
 */
const AGENT_FADE_IN_SPAN: number = 0.25;
/**
 * 滑出视窗后再保留多久才下渲染树。**用 0，也就是一出视窗立刻摘掉。**
 *
 * 官方说明里这个计时是「从页面移出视窗外的第一帧开始」，所以 0 不会摘掉还看得见的页面。
 * 我曾误以为要留足动画时间而设成 1000，结果翻走的那页在屏幕上多留一秒，
 * 它那截溢出可视区的内容就成了「缓缓露出来又消失的一条提示」。
 */
const AGENT_FADE_HOLD_MS: number = 0;
/** 没过线时把淡收回去的时长。只用在这一处，拉动过程中必须是 0。 */
const AGENT_FADE_RESTORE_MS: number = 150;
/**
 * 翻页动画时长，单位毫秒。
 *
 * 必须配非弹簧曲线才有效：弹簧曲线的时长由它自己的参数决定，官方明说 duration 不生效。
 * 所以 Swiper 上用的是 `Curve.EaseInOut` —— 它两头都慢，起步慢正好治
 * 用户反馈的「突然一下就上脸」。
 *
 * 1200 是验证用的夸张值（用来确认动画链路通不通），已确认，现在回到常规档 320。
 * 需要更缓就往 400~500 调，觉得拖沓就往 250 调。
 */
const AGENT_FLIP_DURATION_MS: number = 320;
/**
 * 一次翻页从发起到解除封锁，多给这么久的余量。
 *
 * 封锁的**下限**是动画时长：动画没跑完就不能受理下一次翻页。余量是给
 * 「`onAnimationEnd` 比预期晚一点」留的，正常路径根本用不到它 ——
 * 那个回调一到就提前解封，见 `agentFlipUntil`。
 */
const AGENT_FLIP_GUARD_SLACK_MS: number = 120;
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

/** 时间线最多留这么多条，再多就丢最早的，避免长任务把内存吃光。 */
const AGENT_MAX_TIMELINE: number = 400;

interface BundleItem {
  name: string;
  label: string;
  system: boolean;
  classified: boolean;
  clearable: boolean;
  checked: boolean;
}

/** 时间线上的一条。kind 决定颜色与前缀，与 AgentEventKind 一一对应。 */
interface TimelineItem {
  id: number;
  kind: string;
  text: string;
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
  @State showInstallPage: boolean = false;
  // ---------- 安装 HAP ----------
  @State hapUri: string = '';
  @State hapDisplayName: string = '';
  @State hapSizeText: string = '';
  @State hapRealPath: string = '';
  @State installBusy: boolean = false;
  @State installPhaseText: string = '';
  @State installResultOk: boolean = false;
  @State installResultText: string = '';
  /** 待装文件的字节大小（setPendingHap 时 stat 得到）。 */
  private hapFileSize: number = -1;
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
  @State showAgentPage: boolean = false;
  @State showAgentSettings: boolean = false;
  /**
   * 每一段会话一页，下标与 `agentSessionIds` 对齐。历史段按需从磁盘读进来，
   * 没读过的那页是空数组。最新那一段不放在这里 —— 它直接渲染 `agentLiveTimeline`，
   * 否则新消息要同时往两个地方写，早晚对不上。
   */
  @State agentPageItems: TimelineItem[][] = [];
  /**
   * 每页的透明度，下标与页对齐。翻页时逐帧改这里的元素，做出「跟着翻页走的淡」。
   *
   * 必须像官方示例那样在界面里**直接下标读取** `this.agentPageOpacity[idx]`，
   * 不要包一层方法：框架靠渲染时读到的属性来建立依赖，绕一层可能就追踪不到元素级变化。
   * 数组长度必须始终不短于页数，否则下标读出 undefined。
   */
  @State agentPageOpacity: number[] = [1.0];
  /**
   * 每段历史的计划进度（形如「3/3」），下标与页对齐。翻到某段时从它的存档里算出来。
   * 最新那一段不看这里 —— 它用运行时的实时值。
   */
  @State agentPageTodo: string[] = [];
  /**
   * 透明度变化的动画时长。拉动过程中必须是 0 —— 加了动画就跟不上手指，变成拖影；
   * 只有「没过线、把淡收回去」那一下需要动画，否则会「啪」地亮回来。
   */
  @State agentFadeAnimMs: number = 0;
  /**
   * 正在被翻走的那一页。逐帧回调不能把它调亮，否则松手瞬间会先亮一下。
   *
   * 只在**确定会翻**之后才赋值（`switchSession` 越界检查之后）。搁在松手那一刻赋值是错的：
   * 已经在最早/最新那一段时越界返回，这个下标就永远留着，
   * 下一次翻页时逐帧回调会拿它去按暗一个不该暗的页。
   *
   * 是 `@State` 而不是普通字段：`enableScrollInteraction` 要按"这一页是不是正在滑走"
   * 决定冻不冻，而组件属性只认状态变量的变化。
   */
  @State fadingOutIdx: number = -1;
  /**
   * 这个时刻之前不受理新的翻页。0 表示空闲。
   *
   * 为什么必须封锁：Swiper 的索引是**动画结束时由组件回写**的（`$$this.agentViewIdx`），
   * 而 `switchSession` 要拿这个索引算目标页。快速连划时第二下在回写之前就进来了，
   * 于是它读到旧索引、算出和上一次相同的目标页，却又推了 Swiper 一页 ——
   * 页面位置和我这边的记账从此错开。同时 `fadingOutIdx` 被第二下覆盖，
   * 第一页再没人把它恢复成不透明，就留下一张一直是暗的页。这两样合起来就是"动画错乱"。
   *
   * **用时间戳而不是布尔量。** 布尔量只能靠 `onAnimationEnd` 清，那个回调万一没来
   * （或者因为越界压根没发生翻页）就永久锁死 —— 上一个 bug 正是这么卡住的，不重犯。
   * 时间戳到点自己失效，`onAnimationEnd` 只是提前解封的快路径。
   */
  private agentFlipUntil: number = 0;
  /**
   * 翻页动画正在跑。用来在动画期间关掉列表的滚动手势（`enableScrollInteraction`）。
   *
   * 为什么单独开一个 `@State` 而不直接用 `flipBusy()`：这个值要驱动组件属性，
   * 而属性只认状态变量的变化，读方法不会触发重新渲染。
   *
   * **为什么必须关掉滚动手势：** 我们的翻页手势是 `parallelGesture`，与列表自己的滚动
   * 并行。所以动画那 320 毫秒里，用户第二下划的手指仍然在滚动手指底下那个列表 ——
   * 而旧页此刻正半透明地滑出去，于是你看见"上一个会话的部分动画"。
   * 挡住翻页、提示、透明度都不够，得连列表的手指滚动一起挡。
   * 控制器接口不受影响，所以 `snapToEdge` 照旧能摆位置。
   *
   * 卡死防护：正常由 `onAnimationEnd` 清零；万一那个回调没来，
   * 下一次手势进来时会按 `flipBusy()` 已过期把它清掉（见 `onTimelinePanUpdate`）。
   * 手势本身不受这个开关影响，所以一定有机会恢复。
   */
  @State agentFlipping: boolean = false;
  /** 活跃会话的时间线。浏览历史时它继续接收新条目，回到最新就能看到。 */
  @State agentLiveTimeline: TimelineItem[] = [];
  /** 所有会话 id，从老到新。最后一个是活跃会话。 */
  @State agentSessionIds: string[] = [];
  /**
   * 只给 Swiper 的 `index` 做双向绑定用，**别拿它做任何判断**。
   *
   * 它由组件在翻页动画结束时回写，所以动画期间它是旧值。而"现在在第几段"这件事
   * 有七八处代码要用（算目标页、认被翻走的那页、贴边、状态行、要不要往展示列表追加），
   * 一旦有一处在动画期间读它，就是一个 bug。这一轮已经踩了三个：
   * 翻回来翻不动、连划翻错页、连划时旧页全亮闪一下。
   *
   * 所以判断一律读 `agentViewIdx`（那是我自己维护的，翻页发起的同一刻就更新），
   * 这个只负责让组件知道该停在哪一页。
   */
  @State agentSwiperIdx: number = 0;
  /** 当前在看第几段。等于 agentSessionIds.length-1 表示在看最新那段。 */
  /**
   * 当前在看第几段。等于 agentSessionIds.length-1 表示在看最新那段。
   * 起始值必须是 0 而不是 -1：它双向绑在 Swiper 的 index 上，
   * 而负值是非法索引（文档：小于 0 时取 0），留着 -1 会让组件回写一个我没预期的值。
   * 没有任何会话时段号显示「新的一段」，不会露出 0 这个下标。
   */
  @State agentViewIdx: number = 0;
  @State agentTaskInput: string = '';
  /** 软键盘是否弹起。只影响输入行的下边距，见 `watchKeyboard`。 */
  @State keyboardUp: boolean = false;
  /**
   * 任务输入框的高度上限（vp）。按真实行高在运行时算出来，见 `measureInputMaxHeight`。
   * 初值是退路，正常情况下第一次布局前就会被真实值覆盖。
   */
  @State agentInputMaxHeightVp: number = AGENT_INPUT_MAX_HEIGHT_FALLBACK_VP;
  /**
   * 任务输入框的高度下限（vp），也就是空着时的高度。
   *
   * `TextArea` 没有 `TextInput` 那个默认最小高度，实测比全应用其他输入框矮 17px，
   * 空着的时候显得局促。这里按「一行行高 + 内边距」推出来补齐，**不写死像素**：
   * 130px 是这台设备在这个字号下的值，换设备或换系统字号就不对了。
   */
  @State agentInputMinHeightVp: number = AGENT_INPUT_MIN_HEIGHT_FALLBACK_VP;
  @State agentRunning: boolean = false;
  /**
   * 这一轮是不是用户自己按停的。按停止的人就在 AGENT 页上看着，不必再把应用拉回前台。
   * 每次发送时清零，`onStopAgent` 置位。
   */
  private agentStoppedByUser: boolean = false;
  /**
   * 在这个时刻之前，`agentStickPage` 那一页的任何布局变化都把它重新贴到 `agentStickEdge`。
   * 0 表示不盯。
   *
   * 由来是探针量出来的事实：列表**内容刚换好的那一刻还没有布局出来** —— 内容高度接近 0，
   * 偏移是负数（−350），此时 `onReachEnd` 与 `onReachStart` 会在 100 毫秒内先后触发，
   * 而真正的末尾偏移（2769）要**五秒后**才出现。所以那一刻滚一两发必然打在空壳上。
   *
   * 现在不去判断"布局完成没有"（这一轮已经因为猜判据错了四次），改成在一小段时间内
   * **每次布局变化都重贴一次**。重复贴到已经贴住的位置是空操作，代价只有几次无效调用。
   * 用户自己一拖就立刻停手（见 `onWillScroll`）。
   *
   * 三个地方需要它，都是"内容刚换好、马上要摆位置"：
   * · 从后台回到前台（任务在后台追加了几十条）；
   * · 进 AGENT 页（冷启动时这一页刚建，内容是刚从磁盘读回来的）；
   * · **翻会话**（目标页刚被 `loadPage` 灌进内容）—— 这一条是瀑布流的落点，
   *   漏了它就变成"每次往上翻都停在上一段的开头"。
   */
  private agentStickUntil: number = 0;
  /** 正在盯哪一页。-1 表示没有。 */
  private agentStickPage: number = -1;
  /** 盯的是哪一边。往更早的一段翻要盯末尾，往更新的一段翻要盯开头。 */
  private agentStickEdge: Edge = Edge.Bottom;
  /**
   * 一次性标记：页面下一次变可见时回到底部。只由 `returnToAgentPage` 置位。
   *
   * 要对付的情形：任务在**应用处于后台**时追加了几十条，那期间布局是延后的、
   * `scrollEdge` 也滚不动；等应用回到前台，List 恢复的是进后台之前那个偏移 ——
   * 那时内容还很短，所以看起来就停在顶部。
   *
   * `pushTimeline` 里的逐条落底管不了这一种（在后台里滚是空操作），
   * 页面级的 `initialIndex` 也管不了（只在**首次布局**生效，从后台恢复不算首次）。
   *
   * 所以这一下必须补，而且必须落在页面**真正可见**的那一刻（`onPageShow`）——
   * 在后台里滚是空操作。
   *
   * 两条路置位：
   *
   * 1. 自动回页（`returnToAgentPage`，任务跑完应用自己把人拉回来）。
   * 2. **后台期间真有新内容追加**（`pushTimeline` 发现页面不可见时置位）。
   *
   * 第 2 条是 2026-08-17 加的。这里原先写着「只由自动回页那条路置位，用户自己切后台
   * 又切回来时不置位，否则他正翻在历史上方就会被拽到底部」—— 那条把"任务还在跑、
   * 用户自己切回来"整个漏掉了：三条回页的路里只有它没人摆位置，而任务在后台一直追加，
   * 回来就停在离开前那个偏移上。用户报的原话是「在会话运行中的时候切回 agent 依然会
   * 出现之前的不在底部的情况」。
   *
   * 判据取的是「后台期间**真有新内容**」而不是「离开前贴不贴底」：
   * 页面开着时只要在看最新那段就会跟到底，切后台不该换一套规则。代价是离开前翻在
   * 历史上方、期间又真来了新消息时同样会被带到底部 —— 与页面开着时一致，用户拍板接受。
   * 没有新内容时绝不动位置。
   */
  private agentLandBottomOnShow: boolean = false;
  /**
   * 页面此刻是不是**真的**在屏幕上（`onPageShow` 置上、`onPageHide` 撤下）。
   *
   * 不能用 `showAgentPage` 代替：那个只表示"应用内选中的是 AGENT 页"，
   * 用户按 Home 之后它仍然是 true，而那时 `scrollEdge` 是空操作。
   * 两者的差别正是上面那个缺口的成因。
   */
  private agentPageVisible: boolean = false;
  /**
   * 每一页的时间线是否已经贴到上下边缘。只有贴边时的继续拉动才算翻会话。
   *
   * **必须按页存，不能用两个全局标记。** 翻页时 `switchSession` 故意不赋 `agentViewIdx`
   * （索引由 Swiper 在动画结束时自己回写，见那里的注释），而目标页的首屏布局就发生在
   * 这段空档里。用全局标记加一句 `if (idx === agentViewIdx)` 去挡，等于把目标页那一次
   * 贴边上报整个丢掉；等索引回写完，已经没有新的布局变化，回调不会再来。
   * 于是你落在新的一页上，标记还是上一页的值 —— 翻过去几段再翻回来就翻不动了。
   *
   * 按页存之后不需要任何时序配合：哪一页报的就记在哪一页头上，读的时候按当前页取。
   *
   * 默认 true（数组里没有的下标也当 true）：一页还没上报过就是刚建出来、内容撑不满，
   * 那时两边都算贴着。宁可多让一次翻页，也不要卡住翻不动。
   */
  private agentEdgeTop: boolean[] = [];
  private agentEdgeBottom: boolean[] = [];


  /**
   * 键盘弹起**之前**每页的滚动位置。收起时回到这个绝对值。
   * 用绝对位置而不是相对位移：相对位移会与组件自己的夹取叠加，
   * 而且一旦补偿不对称，反复开合键盘就能把内容一路「扭」到另一端。
   */
  private keyboardSavedY: Map<number, number> = new Map();
  /**
   * 这一轮键盘弹起至今，视口一共缩了多少。一次弹起会来好几次视口变化
   * （键盘避让一次、输入行下边距变化一次），目标位置要从 `keyboardSavedY`
   * 加上这个累计量算，不能拿动画中途的 `currentOffset()` 当基准。
   */
  private keyboardShrunk: Map<number, number> = new Map();

  /** 拉动时写在空隙里的提示。空串表示不显示。 */
  @State agentPullHint: string = '';
  /** 提示写在上边还是下边。 */
  @State agentPullHintAtTop: boolean = true;
  @State agentTodoSummary: string = '未制定计划';
  @State agentPercent: number = 0;
  @State agentUsageText: string = '';
  @State agentKeepMode: string = '未保活';
  /** 非空表示正在等用户点「继续」。 */
  @State agentPauseReason: string = '';
  @State cfgEndpoint: string = '';
  @State cfgApiKey: string = '';
  @State cfgModel: string = '';
  @State cfgContextLimit: string = '';
  @State cfgMaxTokens: string = '';
  @State cfgKeepScreenshots: string = '';
  @State cfgBlacklist: string = '';

  @State cfgPromptCache: boolean = true;
  @State cfgSaving: boolean = false;
  /** 待写盘的定时器 id，-1 表示没有待写的改动。 */
  private cfgSaveTimer: number = -1;
  /** 待写盘的会话定时器 id，-1 表示没有待写的改动。 */
  private sessionSaveTimer: number = -1;
  /**
   * 本段会话至今推过多少条时间线，以及其中多少条已经追加到磁盘。
   *
   * 需要两个独立计数器，是因为 `agentLiveTimeline` 不能当依据：它到 AGENT_MAX_TIMELINE
   * 条就开始丢最早的，长度会停住，头部也不再是"第一条"。而追加写要知道的恰恰是
   * "上次写盘之后新产生了几条"，只能靠一个只增不减的总数来算。
   */
  private timelineTotal: number = 0;
  private timelinePersisted: number = 0;
  /**
   * 正在从磁盘把某一段会话灌回界面。此时不许安排写盘。
   *
   * 灌回是逐条走 pushTimeline 的，而 pushTimeline 会把活跃时间线截到
   * AGENT_MAX_TIMELINE 条。读回来再写下去，等于把超出上限的旧条目永久删掉，
   * 而这一趟写盘本来什么新内容都没有，纯亏。
   */
  private restoringTimeline: boolean = false;
  @State powerTimeoutSynced: boolean = false;
  @State powerTimeoutSyncing: boolean = false;

  private conn: HdcConnection | null = null;
  private keyPair: HdcKeyPair | null = null;
  private shell: HdcShellChannel | null = null;
  private agent: DeviceControl | null = null;
  private agentApi: AnthropicClient | null = null;
  private agentConfig: AgentConfig | null = null;
  private agentLoop: AgentLoop | null = null;
  /**
   * 会话里是否已经有对话。**必须是 @State**：界面上的结构性 `if` 只在它依赖的
   * 被追踪状态变化时才重新求值，而 `agentLoop` 是普通字段、框架不追踪它。
   * 真机上「新会话」按钮因此一直不出现，而同样读它的「发送」标签却是对的 ——
   * 属性表达式蹭到了别的 @State 的重渲染，结构性 `if` 没蹭上。
   */
  @State agentHistoryFlag: boolean = false;
  private keepAlive: KeepAlive | null = null;
  /**
   * 翻段由控制器驱动，不用组件自带的跟手滑动（`disableSwipe(true)`）。
   * 原因：跟手翻页的「翻还是弹回」由组件按位移加甩动速度自己判定，我读不到那个门槛，
   * 于是「松手查看上一段」这句提示会与实际结果不一致 —— 提示骗人比没有提示更糟。
   * 手势判定仍是自己那套 70vp，控制器只负责把页翻过去并带上原生动效。
   */
  private agentSwiper: SwiperController = new SwiperController();
  /** 每页一个 Scroller，下标与页对齐。翻段不再换内容，所以每页的位置各自保留。 */
  private pageScrollers: Scroller[] = [];
  private agentSeq: number = 0;
  /** 等用户点「继续」时，这里放着那个 Promise 的 resolve。 */
  private agentResume: ((go: boolean) => void) | null = null;
  private bundleCache: Map<string, boolean> = new Map();
  private terminalScroller: Scroller = new Scroller();
  /** 终端回显模拟器：宽度与连接时下发的 COLUMNS 同值（TERMINAL_COLUMNS）。 */
  private terminal: TerminalEmulator = new TerminalEmulator(TERMINAL_COLUMNS, MAX_OUTPUT_BUFFER_CHARS);
  /** 列宽设置命令的回显吞咽状态（见 setupTerminalColumns）。 */
  private terminalColumnsSwallowing: boolean = false;
  private terminalColumnsSwallow: string = '';
  private terminalColumnsTimer: number = -1;
  private terminalFlushPending: boolean = false;
  private terminalScrollPending: boolean = false;
  private terminalStickToBottom: boolean = true;
  private powerScrollToken: number = 0;

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.measureInputMaxHeight();
    this.watchKeyboard();
    this.refreshKeyState();
    this.restoreConnection();
    this.restoreBundleCache();
  }

  /**
   * 盯着软键盘的升降。两件事：
   *
   * 一、`keyboardHeightChange` 决定输入行下边距 —— 键盘收起时贴着手势条留 2vp 就够
   *    （下面还有系统手势区），键盘弹起时手势区被键盘盖住了，2vp 就变成
   *    「输入框直接贴在键盘上」，侵略性太强。
   *
   */
  /**
   * 算出任务输入框的高度上限：**行高由运行时测量得到**，不写死像素值。
   *
   * 为什么不能写死：`fontSize` 的单位随用户的系统字号设置缩放，字号调大后
   * 同一个 vp 值就装不下四行，会把最后一行切掉一半。设备之间的默认行高也可能不同。
   * 一台设备量出来的数字只对那台设备的那个字号成立。
   *
   * 量一行的高度再乘行数，而不是量一段带换行的文本：这样就不必依赖
   * `measureTextSize` 怎么处理 `\n`（文档没写），而"一行的高度 × 行数"本来就是
   * 行式排版的定义。
   *
   * 在 `aboutToAppear` 与每次 `onPageShow` 各算一次 —— 后者是为了接住
   * "用户切到系统设置改了字号再回来"这种情况。
   */
  private measureInputMaxHeight(): void {
    try {
      const ctx = this.getUIContext();
      const size: SizeOptions = ctx.getMeasureUtils().measureTextSize({
        textContent: '四',
        fontSize: INPUT_FONT_SIZE
      });
      // 返回值官方注明单位是 px，类型是 Length（可能是数字也可能是带单位的串），
      // 所以照本文件处理 `Area.height` 的同一套办法解析。
      const linePx = Number.parseFloat(`${size.height}`);
      if (!Number.isFinite(linePx) || linePx <= 0) {
        this.appendLog(`[ui] 量到的行高不可用（${size.height}），输入框沿用退路高度`);
        return;
      }
      const lineVp = ctx.px2vp(linePx);
      this.agentInputMaxHeightVp = lineVp * AGENT_INPUT_MAX_LINES + AGENT_INPUT_PAD_SLACK_VP;
      // 一行时的高度，用来补上 TextArea 缺的那个默认最小高度。同一套推导，
      // 所以字号或系统字体缩放变了它自己跟着走。
      this.agentInputMinHeightVp = lineVp + AGENT_INPUT_PAD_SLACK_VP;
    } catch (err) {
      this.appendLog(`[ui] 量输入框行高失败，沿用退路高度: ${(err as BusinessError).message}`);
    }
  }

  private async watchKeyboard(): Promise<void> {
    let win: window.Window;
    try {
      win = await window.getLastWindow(this.getCtx());
    } catch (err) {
      this.appendLog(`[ui] 取窗口失败，键盘监听全部跳过: ${(err as BusinessError).message}`);
      return;
    }
    try {
      win.on('keyboardHeightChange', (height: number) => {
        this.keyboardUp = height > 0;
      });
    } catch (err) {
      this.appendLog(`[ui] 监听键盘高度失败: ${(err as BusinessError).message}`);
    }
  }

  /**
   * 内容跟随键盘的那一下滚动。**必须无动画。**
   *
   * 曾经这里带着动画（先是我猜的 250ms EaseInOut，后来换成系统自己的弹簧），
   * 症状是「键盘弹起时输入行上方一条内容闪一下」。真机日志把原因摆平了：
   *
   *   will弹起  animated=true beginH=1089 endH=1089 dur=150
   *   area      h=637.85 -> 322.77  delta=315.08     ← 只有这一次，18ms 内完成
   *
   * 键盘的高度从一开始就是终值（begin 与 end 相等），页面与输入行也是一步到位。
   * 也就是说**除了内容，所有东西都已经瞬间到位**，动画只让内容单独落在后面，
   * 那条被单独看见的滞后就是"闪一下"。
   *
   * 旁证一直在眼前：盯底窗口走的 `snapToEdge` 不带动画，实测不闪。
   *
   * 我当初写下的"不带动画会闪现"那句判断从来没有验证过，是凭想象写的。
   * **不要再给这里加动画。** 要动画就得先解释清楚"为什么内容该比键盘慢"。
   *
   * 顺带说清最终的落点：真正好看的动画不该由这里做，而是把避让模式换成
   * `OFFSET`（见 `openAgentPage`）—— 整页由系统平移，所有东西一起走，
   * 这个函数就只剩下处理输入行下边距那 8vp 的小事了。
   */
  private followKeyboardScroll(scroller: Scroller, yOffset: number): void {
    scroller.scrollTo({ xOffset: 0, yOffset, animation: false });
  }

  onPageShow(): void {
    // 「从文件管理器点 .hap 用本应用打开」的入口：EntryAbility 把 want.uri 存进
    // AppStorage，这里消费。取走即清空，避免下次 onPageShow 重复触发。
    const pendingHap: string = AppStorage.get<string>('pendingHapUri') ?? '';
    if (pendingHap.length > 0) {
      AppStorage.setOrCreate<string>('pendingHapUri', '');
      this.openInstallPage();
      this.setPendingHap(pendingHap);
    }
    // 必须在下面任何 return 之前置上：应用启动时这里也会走一遍，而那时 showAgentPage
    // 还是 false，早退之后这个标记就永远是 false，`pushTimeline` 会把每一条都当成
    // "页面不可见"，于是页面开着的时候反而不跟随了。
    this.agentPageVisible = true;
    // 用户可能刚去系统设置改了字号再回来，行高得重新量。
    this.measureInputMaxHeight();
    if (this.showPowerPage && this.connected) {
      this.syncPowerTimeoutState(false);
    }
    // **绝对不能在这里无条件碰 Scroller。** 应用启动时也会走 onPageShow，而那时 AGENT 页
    // 从没建过，`pageScrollers[0]` 是个从未绑定到任何组件的空 Scroller ——
    // 对它调 currentOffset() 会把进程直接带走，症状是"应用根本打不开"（启动即挂、
    // hilog 里连 JS 异常都没有）。我加诊断日志时就这么崩过一次。
    if (!this.showAgentPage) {
      return;
    }
    // 页面变可见时先贴一次末尾。**这一发几乎总是无效的**：探针实测应用被拉回前台时
    // 列表还没把内容布局出来（21 条内容的高度接近 0、偏移是负数），真正的末尾偏移要
    // 五秒后才出现。真正把位置摆对的是 `agentStickBottomUntil` 那个窗口。
    // 留着它是因为内容短、布局快的时候这一发就够了，省得等第一次布局回调。
    if (this.agentLandBottomOnShow) {
      this.agentLandBottomOnShow = false;
      this.snapToEdge(this.agentViewIdx < 0 ? 0 : this.agentViewIdx, Edge.Bottom);
      // 上面那一发几乎总是无效的（内容还没布局出来），真正管用的是这个窗口。
      // `returnToAgentPage` 自己也开一段，两处重复开是无害的：armStick 只是把
      // 截止时间往后推，盯的还是同一页同一边。而用户自己切回来的那条路上没有别人开，
      // 少了它就等于只剩那一发无效的滚动 —— 正是这次要修的症状。
      this.armStick(this.livePageIdx(), Edge.Bottom);
    }
  }

  /**
   * 页面离开屏幕。只撤 `agentPageVisible` 一个标记，别的什么都不做。
   *
   * 不在这里记"离开前贴不贴底"：`agentEdgeBottom` 一直由滚动回调维护着，
   * 到这一刻它已经是对的，再抄一份只会多一个可能过期的副本。
   */
  onPageHide(): void {
    this.agentPageVisible = false;
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
          this.feedTerminalOutput(text);
        });
        // 等提示符就绪后下发列宽，并吞掉这条设置命令自己的回显
        // （双 COLUMNS 的成因与修法见 setupTerminalColumns 的说明）。
        this.setupTerminalColumns();
        this.appendLog(`[shell] 已打开交互式 shell (channel=${this.shell.channelId})`);
        await this.createAgent(conn);
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

  /**
   * 设备控制层的设置。**建立连接和改设置都要走这一处**，不要在两个地方各写一份 ——
   * 黑名单曾因此有两个持有者：这一层拿的是构造时捕获的副本，用户在设置页删掉一个应用
   * 之后它仍按旧名单拒绝，而且从界面上没法修。
   */
  private buildActionSettings(config: AgentConfig | null): ActionSettings {
    return {
      pollIntervalMs: AGENT_POLL_INTERVAL_MS,
      stableTimeoutMs: AGENT_STABLE_TIMEOUT_MS,
      commandTimeoutMs: AGENT_COMMAND_TIMEOUT_MS,
      blacklistBundles: config !== null ? config.blacklistBundles : []
    };
  }

  /**
   * 建立 agent 的设备控制层。包名与输入法都在运行时探测，不写死：
   * 实测输入法包名只能靠 `ime -g` 拿到，而它决定了"键盘是否弹起"的判断。
   */
  private async createAgent(conn: HdcConnection): Promise<void> {
    let imeBundle = '';
    try {
      const raw = await conn.executeCommand('ime -g', AGENT_COMMAND_TIMEOUT_MS);
      const matched = /input method is:\s*([A-Za-z0-9_.]+)/.exec(raw);
      if (matched !== null) {
        imeBundle = matched[1];
      }
    } catch (err) {
      this.appendLog(`[agent] 探测输入法失败: ${(err as BusinessError).message}`);
    }
    let config: AgentConfig | null = null;
    try {
      config = await loadAgentConfig(this.getCtx());
    } catch (err) {
      this.appendLog(`[agent] 读取配置失败: ${(err as BusinessError).message}`);
    }
    const ownBundle: string = this.getCtx().applicationInfo.name;
    const observeCtx: ObserveContext = {
      ownBundle,
      imeBundle,
      dumpPath: AGENT_DUMP_PATH,
      maskSensitiveText: true
    };
    const settings: ActionSettings = this.buildActionSettings(config);
    this.agent = new DeviceControl(conn, observeCtx, settings, (line: string) => this.appendLog(line));
    this.appendLog(
      `[agent] 设备控制已就绪 本应用=${ownBundle} 输入法=${imeBundle.length > 0 ? imeBundle : '未探测到'} ` +
        `黑名单=${settings.blacklistBundles.length} 项`
    );
    this.agentConfig = config;
    if (config === null) {
      return;
    }
    this.agentApi = new AnthropicClient((line: string) => this.appendLog(line));
    if (isAgentConfigured(config)) {
      this.appendLog(
        `[agent] 模型配置就绪 model=${config.model} key=${maskApiKey(config.apiKey)} ` +
          `缓存=${config.enablePromptCache ? '开' : '关'} ` +
          `max_tokens=${String(config.maxTokens)}`
      );
    } else {
      this.appendLog(`[agent] 模型配置不完整，还缺: ${describeMissing(config).join('、')}`);
    }
  }

  // ---------- AGENT 操控 ----------

  /**
   * 追加一条时间线。始终写进活跃会话；只有当屏幕正看着最新那段时才同步到展示列表，
   * 否则用户翻历史时会被跳走。
   */
  private pushTimeline(kind: string, text: string): void {
    // 时间线动一下就意味着会话有新内容，攒批落盘。放在这里而不是各个调用点，
    // 是因为暂停、报错、压缩、工具结果都要经过这里，漏一个就是一段对话没写下去。
    this.timelineTotal += 1;
    this.scheduleSessionSave();
    this.agentSeq += 1;
    const next = this.agentLiveTimeline.slice(
      Math.max(0, this.agentLiveTimeline.length - (AGENT_MAX_TIMELINE - 1))
    );
    next.push({ id: this.agentSeq, kind, text });
    this.agentLiveTimeline = next;
    if (this.viewingLatest() && this.showAgentPage) {
      if (!this.agentPageVisible) {
        // 应用在后台：这一下滚不动（空操作），所以改成记一笔账，等页面真可见时补。
        // 不补的后果就是用户报的那个 bug —— 任务在后台追加了几十条，切回来还停在
        // 离开前那个偏移上。见 `agentLandBottomOnShow`。
        this.agentLandBottomOnShow = true;
        return;
      }
      // **新消息自动跟到底就是这三句。** 删掉 `stackFromEnd` 之后它是唯一的跟随机制了
      // （那个属性的契约 ② 会在插入时把上方内容往上顶，效果一样，但它捆着不要的契约 ①）。
      //
      // 不带动画：`scrollEdge` 在 List 上默认无动画，正好合用。要是带动画，
      // 每来一条新消息都会播一段滚动，一个任务几十条就是一串抽动。
      //
      // **光第一句是不够的，它永远差最后那一条。** 上一行刚把数组换掉，新那条子项此刻
      // 还没被测量，`scrollEdge` 只能滚到**追加之前**的底部。运行中看不出来 ——
      // 下一条消息又把上一条顶进视野；只有**最后**那一条会一直留在折叠线下面。
      // 用户报的就是这个：按停止之后「已停止。」要往下滑才看得到。
      // （按停止那条路还专门跳过了 `returnToAgentPage`，所以也没有别人来补落点。）
      //
      // 所以再开一段很短的盯底窗口 + 补两拍定时，等新子项真的布局出来再贴一次。
      // 两者的分工写在 `AGENT_FOLLOW_CATCHUP_MS` 的注释里：窗口是判据，定时是驱动。
      const live = this.livePageIdx();
      this.snapToEdge(live, Edge.Bottom);
      this.armStickAtLeast(live, Edge.Bottom, AGENT_FOLLOW_STICK_MS);
      this.catchUpFollow(live);
    }
  }

  private viewingLatest(): boolean {
    return this.agentSessionIds.length === 0 ||
      this.agentViewIdx >= this.agentSessionIds.length - 1;
  }

  /**
   * 取第 idx 页的 Scroller，不够就补齐。
   * 每页必须是**同一个**实例：换成每次新建的话，翻回来时那一页的位置就丢了。
   */
  private scrollerFor(idx: number): Scroller {
    // 夹住负下标。传进 -1 时原先 while 一次都不进，直接返回 pageScrollers[-1]
    // 也就是 undefined，调用方紧接着 .scrollEdge() 就抛异常。
    const safe = idx < 0 ? 0 : idx;
    while (this.pageScrollers.length <= safe) {
      this.pageScrollers.push(new Scroller());
    }
    return this.pageScrollers[safe];
  }

  /**
   * 活跃那一页的下标。**一段会话都还没有时是 0**，因为那时候唯一的那一页就是活跃页。
   *
   * 不能直接写 `length - 1`：会话数为 0 时它是 -1，两个地方都会出事 ——
   * `scrollerFor(-1)` 拿到 undefined 然后抛异常，`itemsForPage` 永远匹配不上活跃页。
   * 真机症状：删掉全部对话记录后发第一条消息，「停止」按钮亮着、输入框没清空、
   * 时间线一片空白，任务其实压根没启动（发送在 pushTimeline 里就崩了）。
   */
  private livePageIdx(): number {
    const last = this.agentSessionIds.length - 1;
    return last < 0 ? 0 : last;
  }

  /**
   * 页数变了就把透明度数组补齐。补齐必须发生在渲染之前，
   * 否则新那一页会去读一个不存在的下标。
   */
  private ensurePageOpacity(): void {
    const need = this.agentSessionIds.length < 1 ? 1 : this.agentSessionIds.length;
    if (this.agentPageOpacity.length >= need) {
      return;
    }
    const next: number[] = this.agentPageOpacity.slice();
    while (next.length < need) {
      next.push(1.0);
    }
    this.agentPageOpacity = next;
  }

  /**
   * 正在看的那一段的计划进度。最新那段用运行时的实时值，
   * 历史段用它自己存档里的计划算出来的值。
   */
  private todoSummaryForView(): string {
    if (this.viewingLatest()) {
      return this.agentTodoSummary;
    }
    const stored = this.agentPageTodo[this.agentViewIdx];
    return stored === undefined ? '未制定计划' : stored;
  }

  /** 把一段存档里的计划算成「x/y」。放弃的项不计入，规则完全由 TodoStore 决定。 */
  private summaryOfSnapshotTodos(items: TodoItem[]): string {
    const store = new TodoStore();
    store.load(items);
    return store.summary();
  }

  /** 当前这一页的内容。最新那段直读活跃时间线，历史段读按需加载的那份。 */
  private itemsForPage(idx: number): TimelineItem[] {
    if (idx === this.livePageIdx()) {
      return this.agentLiveTimeline;
    }
    const loaded = this.agentPageItems[idx];
    return loaded === undefined ? [] : loaded;
  }

  /** 把某一段历史读进对应的那一页。已经读过就不再读。 */
  private loadPage(idx: number): void {
    if (idx < 0 || idx >= this.agentSessionIds.length - 1) {
      return;
    }
    const existing = this.agentPageItems[idx];
    if (existing !== undefined && existing.length > 0) {
      return;
    }
    const stored = loadSessionById(
      this.getCtx() as common.UIAbilityContext,
      this.agentSessionIds[idx],
      (line: string) => this.appendLog(line)
    );
    if (stored === null) {
      this.toast('这一段读不出来');
      return;
    }
    const items: TimelineItem[] = [];
    for (const entry of stored.timeline) {
      this.agentSeq += 1;
      items.push({ id: this.agentSeq, kind: entry.kind, text: entry.text });
    }
    const next: TimelineItem[][] = this.agentPageItems.slice();
    while (next.length < this.agentSessionIds.length) {
      next.push([]);
    }
    next[idx] = items;
    this.agentPageItems = next;
    // 存档已经在手上，顺手把这一段的计划进度算出来，供状态行显示。
    const todos: string[] = this.agentPageTodo.slice();
    while (todos.length < this.agentSessionIds.length) {
      todos.push('未制定计划');
    }
    todos[idx] = this.summaryOfSnapshotTodos(stored.snapshot.todos);
    this.agentPageTodo = todos;
  }

  // 这里原来有个 `updateEdgeFlags()`，靠滚动偏移判断贴不贴边：
  // `agentAtTop = currentOffset().yOffset <= 2`。
  //
  // **这句判错过两种情形**，而两种都不是因为坐标轴反了（轴一直是正常的：
  // 实测 `onReachStart` y=0、`onReachEnd` y=2769）：
  // · 内容不满一屏时没有可滚距离，偏移恒为 0 —— "贴顶"永远为真，而此刻同时也贴着底；
  // · 内容还没布局完时偏移是负数（−350），`<= 2` 同样为真，而那一刻 `onReachEnd` 也在触发。
  // 这两个标记管着"拉到边缘才翻会话"，判错就是翻不动或乱翻。
  //
  // 另外它们**按页存**（`agentEdgeTop` / `agentEdgeBottom`），不是两个全局布尔。
  // 用全局的那一版实测会卡死：翻过去几段再翻回来就再也翻不动了，
  // 原因写在 `agentEdgeTop` 的注释里 —— 翻页途中目标页的上报被时序条件丢掉了。
  //
  // 现在改成按**可见子项的下标**判边（`onScrollIndex` + `onReachStart` / `onReachEnd`），
  // 不再依赖我对坐标系方向的理解 —— 这一轮已经因为猜坐标系错了三次。

  /** 有没有更老／更新的一段可以翻。 */
  private hasOlderSession(): boolean {
    return this.agentViewIdx > 0;
  }
  private hasNewerSession(): boolean {
    return this.agentViewIdx < this.agentSessionIds.length - 1;
  }

  /**
   * 拉到什么程度就淡到什么程度 —— 淡跟着**手指**走。
   *
   * 之前把淡挂在翻页动画上是错的：组件自带手势被关掉了，拉动过程中页面根本不动，
   * 于是整个淡被压进松手后那几百毫秒里，眼睛来不及看见，手上也感觉不到回应。
   * 现在拉动的每一帧都在改透明度，越接近那条线越淡，到线时最淡 ——
   * 这同时把「松手就会翻」这件事变成看得见的，而不只是一行字。
   *
   * 只有真的有段可翻时才淡。到头了还淡，等于承诺一件不会发生的事。
   */
  private setDragFade(dy: number, live: boolean): void {
    if (!live) {
      this.agentFadeAnimMs = 0;
      this.agentPageOpacity[this.fadePageIdx()] = 1.0;
      return;
    }
    const span = dy < 0 ? -dy : dy;
    let progress = span / AGENT_PULL_TRIGGER_VP;
    if (progress > 1) {
      progress = 1;
    }
    // 拉动中不给透明度加动画：加了就跟不上手指，变成拖影。
    this.agentFadeAnimMs = 0;
    this.agentPageOpacity[this.fadePageIdx()] = 1 - AGENT_FADE_OUT_DEPTH * progress;
  }

  private fadePageIdx(): number {
    return this.agentViewIdx < 0 ? 0 : this.agentViewIdx;
  }

  /** 上一次翻页还没跑完。期间不受理新翻页，也不动透明度。见 `agentFlipUntil`。 */
  private flipBusy(): boolean {
    return Date.now() < this.agentFlipUntil;
  }

  /** 当前这一页贴不贴顶。没上报过的按 true 算，理由见 `agentEdgeTop`。 */
  private atTopNow(): boolean {
    const idx = this.fadePageIdx();
    return idx >= this.agentEdgeTop.length ? true : this.agentEdgeTop[idx];
  }

  /** 当前这一页贴不贴底。 */
  private atBottomNow(): boolean {
    const idx = this.fadePageIdx();
    return idx >= this.agentEdgeBottom.length ? true : this.agentEdgeBottom[idx];
  }

  /** 指定页当前记着的贴顶状态。给 `onReachEnd` 那种只知道一边的回调用。 */
  private atTopOf(idx: number): boolean {
    return idx < 0 || idx >= this.agentEdgeTop.length ? true : this.agentEdgeTop[idx];
  }

  /** 指定页当前记着的贴底状态。 */
  private atBottomOf(idx: number): boolean {
    return idx < 0 || idx >= this.agentEdgeBottom.length ? true : this.agentEdgeBottom[idx];
  }

  /**
   * 记下某一页的贴边状态。两个数组各自补齐到够长，补出来的位置填 true（默认贴边）。
   *
   * 不带 `idx === agentViewIdx` 的判断是**故意的**：翻页途中目标页也要能上报，
   * 那正是原先丢失的那一次。见 `agentEdgeTop` 的说明。
   */
  private markEdge(idx: number, top: boolean, bottom: boolean): void {
    if (idx < 0) {
      return;
    }
    while (this.agentEdgeTop.length <= idx) {
      this.agentEdgeTop.push(true);
    }
    while (this.agentEdgeBottom.length <= idx) {
      this.agentEdgeBottom.push(true);
    }
    this.agentEdgeTop[idx] = top;
    this.agentEdgeBottom[idx] = bottom;
  }

  /** 没翻页就把淡收回去。这一下要带动画，否则会「啪」地亮回来。 */
  private restoreDragFade(): void {
    this.agentFadeAnimMs = AGENT_FADE_RESTORE_MS;
    this.agentPageOpacity[this.fadePageIdx()] = 1.0;
  }

  /**
   * 拉动过程中在空隙里写提示，同时按拉动进度改透明度。分三态：
   * 还没到线、已过线（松手即翻）、没有可翻的段。
   * 没有这个提示的话，「用力拉才翻页」这件事没人能猜到。
   */
  private onTimelinePanUpdate(event: GestureEvent): void {
    // 上一次翻页还在跑：不写提示、也不碰透明度。逐帧回调此刻正按动画进度改同一批值，
    // 两边一起写就是互相打断，看到的就是闪一下又跳一下。
    if (this.flipBusy()) {
      this.agentPullHint = '';
      return;
    }
    // 封锁已经到点了，把滚动手势放回来。放在这里是卡死防护：万一 `onAnimationEnd`
    // 没来，只要用户再碰一下就恢复 —— 而手势不受那个开关影响，所以一定碰得到。
    if (this.agentFlipping) {
      this.agentFlipping = false;
    }
    const dy = event.offsetY;
    if (this.atTopNow() && dy >= AGENT_PULL_HINT_VP) {
      this.agentPullHintAtTop = true;
      const canFlip = this.hasOlderSession();
      if (!canFlip) {
        this.agentPullHint = '已经是最早的一段';
      } else {
        this.agentPullHint = dy >= AGENT_PULL_TRIGGER_VP ? '松手查看上一段' : '继续下拉查看上一段';
      }
      this.setDragFade(dy, canFlip);
      return;
    }
    if (this.atBottomNow() && dy <= -AGENT_PULL_HINT_VP) {
      this.agentPullHintAtTop = false;
      const canFlip = this.hasNewerSession();
      if (!canFlip) {
        this.agentPullHint = '已经是最新的一段';
      } else {
        this.agentPullHint = dy <= -AGENT_PULL_TRIGGER_VP ? '松手查看下一段' : '继续上划查看下一段';
      }
      this.setDragFade(dy, canFlip);
      return;
    }
    this.agentPullHint = '';
    this.setDragFade(0, false);
  }

  /**
   * 松手：过线就翻页。只看距离，与提示里承诺的一致。
   *
   * 以前这里是「把当前容器里的内容换成另一段」，那是「软弹」的根源：松手时 Spring
   * 回弹还在跑，一换内容它就按新高度重算目标位置，于是先冲下去一大截再被夹回来。
   * 官方把这条冲突写明过 —— 子滚动节点的边缘回弹动画会让嵌套滚动失效
   * （见 Scroll 的 onScrollFrameBegin 说明）。
   *
   * 现在两段各占一页，旧段留在自己那页把回弹弹完，新段是另一个节点被翻进来，
   * 两个动画不在同一个节点上，抢不起来。内层因此可以继续开 Spring ——
   * 下拉露出的空隙和写在里面的四句提示都保得住。
   */
  private onTimelinePanEnd(event: GestureEvent): void {
    this.agentPullHint = '';
    // 上一次翻页还在跑就直接丢掉这一下。**不能改成排队**：排队等于承认连划有意义，
    // 而这里每一页是一整段会话，连翻三段没人看得清中间那两段。
    // 也不在这里收淡 —— 淡正由逐帧回调管着。
    if (this.flipBusy()) {
      return;
    }
    const dy = event.offsetY;
    let delta = 0;
    if (this.atTopNow() && dy >= AGENT_PULL_TRIGGER_VP) {
      delta = -1;
    } else if (this.atBottomNow() && dy <= -AGENT_PULL_TRIGGER_VP) {
      delta = 1;
    }
    if (delta === 0) {
      // 没过线：把淡收回去，页面留在原处。
      this.restoreDragFade();
      return;
    }
    this.switchSession(delta);
  }

  private timelinePrefix(kind: string): string {
    if (kind === 'thinking') {
      return '思考';
    }
    if (kind === 'model_text') {
      return '模型';
    }
    if (kind === 'tool_call') {
      return '动作';
    }
    if (kind === 'tool_result') {
      return '结果';
    }
    if (kind === 'todo') {
      return '计划';
    }
    if (kind === 'paused') {
      return '暂停';
    }
    if (kind === 'error') {
      return '错误';
    }
    if (kind === 'finished') {
      return '完成';
    }
    if (kind === 'interrupted') {
      return '中断';
    }
    return '提示';
  }

  private timelineColor(kind: string): ResourceColor {
    if (kind === 'error') {
      return '#FF3B30';
    }
    if (kind === 'finished') {
      return '#34C759';
    }
    if (kind === 'paused' || kind === 'interrupted') {
      return '#FF9500';
    }
    if (kind === 'thinking') {
      return $r('app.color.text_secondary');
    }
    if (kind === 'tool_call') {
      return '#0A84FF';
    }
    return $r('app.color.text_primary');
  }

  /**
   * 通知授权闸门。开着直接过；关着就弹系统授权弹窗，弹完再读一次真实状态。
   *
   * 为什么闸门放在「进页面」而不是「按开始」：agent 要驱动别的应用，所以本应用
   * 必然在后台，而后台不被挂起靠的是长时任务，长时任务必然带一条系统通知。
   * 通知被禁用时那条通知不显示 —— 用户既看不见进度，也没有「划掉即停止」这个
   * 入口，而且**没有任何报错**能让我们发现（`publish` 在开关关着时静默成功）。
   * 与其让人以为能用，不如不让进。
   *
   * 返回值一律以 `isNotificationEnabled()` 的实测结果为准，不看 request 有没有抛异常：
   * 用户点「禁止」和「系统记住过拒绝、这次压根没弹」都会抛，两者结果相同。
   */
  private async requireNotifyPermission(): Promise<boolean> {
    let enabled = false;
    try {
      enabled = await notificationManager.isNotificationEnabled();
    } catch (err) {
      this.appendLog(`[agent] 查询通知开关失败: ${(err as BusinessError).message}`);
      enabled = false;
    }
    if (enabled) {
      return true;
    }
    this.appendLog('[agent] 通知未开启，弹窗请求授权');
    try {
      await notificationManager.requestEnableNotification(this.getCtx() as common.UIAbilityContext);
    } catch (err) {
      const e = err as BusinessError;
      this.appendLog(`[agent] 请求通知授权未通过: code=${e.code} ${e.message}`);
    }
    try {
      enabled = await notificationManager.isNotificationEnabled();
    } catch (err) {
      this.appendLog(`[agent] 复查通知开关失败: ${(err as BusinessError).message}`);
      enabled = false;
    }
    this.appendLog(`[agent] 通知开关现在=${enabled ? '开' : '关'}`);
    return enabled;
  }

  private async openAgentPage(): Promise<void> {
    if (!this.connected) {
      this.toast('先连接设备');
      return;
    }
    // 没拿到通知权限就不开页面，留在功能页。每次点进来都重走一遍 ——
    // 用户可能刚拒绝完，去系统设置里开了，再点一次就该能进。
    const allowed: boolean = await this.requireNotifyPermission();
    if (!allowed) {
      this.toast('没有通知权限，AGENT 操控用不了。到系统设置里打开本应用的通知再试。');
      return;
    }
    this.showTerminalPage = false;
    this.showClearPage = false;
    this.showPowerPage = false;
    this.showInstallPage = false;
    this.showAgentPage = true;
    // 【试验中】这一页改用 OFFSET：键盘弹起时整页由系统平移，时间线高度不变。
    //
    // 为什么不用全局那个 RESIZE：RESIZE 下键盘一步到位地把页面压矮（实测 18ms、
    // 时间线高度 637.85→322.77vp），而内容只能由我们事后滚 —— 于是内容永远比
    // 键盘慢半拍，带动画是"输入行上方一条内容闪一下"，不带动画是"一次性跳过去"。
    // OFFSET 下头部、时间线、输入行一起被平移，相对位置天然不变，也不存在错的那一帧。
    //
    // 代价：头部那一条（返回 / 标题 / 状态行）会被顶出屏幕外，打字时看不见。
    //
    // 全局那句 `setKeyboardAvoidMode(RESIZE)` 在 `aboutToAppear` 里，是终端页当年设的，
    // 早于 AGENT 功能存在。所以这里按页覆盖，离开时改回去，别的页行为不变。
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    this.restoreAgentSession();
    // 进页面就开一段盯底窗口，让位置落在最新那条上。
    //
    // 这一下原先不用写：`stackFromEnd` 会把 `initialIndex` 默认成最后一项，首次布局
    // 天然落底。删掉它之后 `initialIndex` 回到 0，也就是从头看 —— 所以缺口要补在这里。
    //
    // **补的是窗口，不是一发滚动。** 冷启动这条路（`restoreAgentSession` 里新建 loop 的
    // 那个分支）不经过 `jumpToLatest`，而它里面那些 pushTimeline 的落底调用此刻全是空的
    // （页面还在建）。窗口能等到内容真的布局出来，一发滚动等不到 —— 这正是
    // `agentStickUntil` 当初为「布局要五秒」设计的能力，这里直接复用。
    //
    // 不必担心把想看历史的人拽走：只盯这一页，而且用户一拖就立刻停手（见 onWillScroll）。
    this.armStick(this.livePageIdx(), Edge.Bottom);
  }

  private closeAgentPage(): void {
    this.showAgentPage = false;
    // 键盘避让模式是 UIContext 级别的全局设置，只在 AGENT 页覆盖成 OFFSET，
    // 离开就还给终端页原来那套（见 openAgentPage 里的说明）。
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
  }

  private async openAgentSettings(): Promise<void> {
    try {
      const cfg = await loadAgentConfig(this.getCtx());
      this.cfgEndpoint = cfg.endpoint;
      this.cfgApiKey = cfg.apiKey;
      this.cfgModel = cfg.model;
      // 0 也要显示成 "0"，不能显示成空。
      // 0 的含义是「关掉折叠」，是用户的明确选择；显示成空就跟「没填」混在一起，
      // 而没填要按默认 128000 处理，下次保存就会把他关掉的折叠又打开。
      this.cfgContextLimit = `${cfg.contextLimitTokens}`;
      this.cfgMaxTokens = `${cfg.maxTokens}`;
      // 同上，0 的含义是「不裁剪、全部保留」，也是明确选择，不能显示成空。
      this.cfgKeepScreenshots = `${cfg.keepRecentScreenshots}`;
      this.cfgBlacklist = cfg.blacklistBundles.join('\n');
      this.cfgPromptCache = cfg.enablePromptCache;
    } catch (err) {
      this.appendLog(`[agent] 读取配置失败: ${(err as BusinessError).message}`);
    }
    this.showAgentSettings = true;
  }

  /**
   * 把界面上的输入攒成一份配置。**不做完整性校验**：
   * 自动保存意味着用户打字到一半就会存一次，此刻配置当然是不完整的。
   * 「缺哪几项」在开始任务时才判定（见 onSendAgent 里的 isAgentConfigured）。
   */
  private collectAgentConfig(): AgentConfig {
    const bundles: string[] = [];
    for (const raw of this.cfgBlacklist.split('\n')) {
      const line = raw.trim();
      if (line.length > 0) {
        bundles.push(line);
      }
    }
    // 压缩阈值要区分「留空」和「填了 0」这两件事：
    //   留空  → 用默认 128000
    //   填 0  → 用户明确要关掉折叠，就照办
    // 不能把两者都算成 0：那样留空就等于悄悄关掉折叠，
    // 而主动压缩现在是唯一的压缩时机，关掉之后历史会一直涨到端点报错。
    const limitText = this.cfgContextLimit.trim();
    const limitParsed = Number.parseInt(limitText, 10);
    let contextLimit = DEFAULT_CONTEXT_LIMIT_TOKENS;
    if (limitText.length > 0 && !Number.isNaN(limitParsed) && limitParsed >= 0) {
      contextLimit = limitParsed;
    }
    const maxTok = Number.parseInt(this.cfgMaxTokens.trim(), 10);
    // 截图保留数同样要区分「留空」和「填了 0」：留空取默认 5，填 0 是不裁剪、全部保留。
    const shotsText = this.cfgKeepScreenshots.trim();
    const shotsParsed = Number.parseInt(shotsText, 10);
    let keepShots = DEFAULT_KEEP_SCREENSHOTS;
    if (shotsText.length > 0 && !Number.isNaN(shotsParsed) && shotsParsed >= 0) {
      keepShots = shotsParsed;
    }
    return {
      endpoint: this.cfgEndpoint.trim(),
      apiKey: this.cfgApiKey.trim(),
      model: this.cfgModel.trim(),
      contextLimitTokens: contextLimit,
      blacklistBundles: bundles,
      enablePromptCache: this.cfgPromptCache,
      maxTokens: Number.isNaN(maxTok) || maxTok <= 0 ? 0 : maxTok,
      keepRecentScreenshots: keepShots
    };
  }

  /**
   * 改动后延迟写盘。攒一下再写，避免每敲一个字符就落一次盘。
   * 离开设置页时会调 flushAgentConfig 立刻补写，所以延迟不会造成丢失。
   */
  private scheduleAgentConfigSave(): void {
    if (this.cfgSaveTimer !== -1) {
      clearTimeout(this.cfgSaveTimer);
    }
    this.cfgSaveTimer = setTimeout(() => {
      this.cfgSaveTimer = -1;
      this.persistAgentConfig();
    }, AGENT_CONFIG_SAVE_DELAY_MS);
  }

  /**
   * 会话延迟写盘。任务跑的全程都会被时间线事件推着走，所以不必再等任务结束。
   *
   * 攒批是必要的：一个回合会连着推好几条事件（思考、动作、结果、计划），
   * 每条都写一次等于把整段对话反复序列化好几遍，而写盘是同步的、占 UI 线程。
   */
  private scheduleSessionSave(): void {
    if (this.restoringTimeline) {
      return;
    }
    if (this.sessionSaveTimer !== -1) {
      clearTimeout(this.sessionSaveTimer);
    }
    this.sessionSaveTimer = setTimeout(() => {
      this.sessionSaveTimer = -1;
      this.saveAgentSnapshot();
    }, AGENT_SESSION_SAVE_DELAY_MS);
  }

  /**
   * 换段、清空、开新任务时都要把两个计数器归零。
   *
   * 漏掉任何一处的后果是具体的：计数器留着上一段的值，新段第一次写盘时
   * 「新增几条」算成负数或者算少，那几条就永远不会被追加到文件里。
   */
  private resetTimelineCounters(): void {
    this.timelineTotal = 0;
    this.timelinePersisted = 0;
  }

  /** 立刻把待写的会话落盘，并取消待触发的定时器。 */
  private flushSessionSave(): void {
    if (this.sessionSaveTimer !== -1) {
      clearTimeout(this.sessionSaveTimer);
      this.sessionSaveTimer = -1;
    }
    this.saveAgentSnapshot();
  }

  /** 立刻把待写的改动落盘。离开设置页必须调它，否则最后几个字符会丢。 */
  private flushAgentConfig(): void {
    if (this.cfgSaveTimer !== -1) {
      clearTimeout(this.cfgSaveTimer);
      this.cfgSaveTimer = -1;
      this.persistAgentConfig();
    }
  }

  private async persistAgentConfig(): Promise<void> {
    if (this.cfgSaving) {
      // 正在写就再排一次，别丢掉这一次的改动。
      this.scheduleAgentConfigSave();
      return;
    }
    this.cfgSaving = true;
    try {
      const cfg = this.collectAgentConfig();
      await saveAgentConfig(this.getCtx(), cfg);
      this.agentConfig = cfg;
    } catch (err) {
      this.toast(`保存失败: ${(err as BusinessError).message}`);
    } finally {
      this.cfgSaving = false;
    }
  }

  /**
   * 离开模型设置页。必须在这里补写一次 ——
   * 输入是延迟落盘的，最后敲的那几个字符可能还没写下去。
   */
  private closeAgentSettings(): void {
    this.flushAgentConfig();
    this.showAgentSettings = false;
  }

  private buildAgentHooks(): AgentHooks {
    return {
      onEvent: (ev: AgentEvent): void => {
        this.pushTimeline(ev.kind, ev.text);
      },
      onProgress: (percent: number, summary: string): void => {
        this.agentPercent = percent;
        this.agentTodoSummary = summary;
        const alive = this.keepAlive;
        if (alive !== null) {
          alive.update(percent, summary.length > 0 ? `计划 ${summary}` : '进行中')
            .then(() => {
            })
            .catch((err: BusinessError) => {
              this.appendLog(`[agent] 更新通知失败: ${err.message}`);
            });
        }
      },
      onUsage: (inputTokens: number, outputTokens: number, cachedTokens: number): void => {
        this.agentUsageText = `入 ${inputTokens} / 出 ${outputTokens} / 缓存命中 ${cachedTokens}`;
      },
      waitForResume: (reason: string): Promise<boolean> => {
        this.agentPauseReason = reason;
        return new Promise<boolean>((resolve: (go: boolean) => void) => {
          this.agentResume = resolve;
        });
      }
    };
  }

  private resolvePause(go: boolean): void {
    const resume = this.agentResume;
    this.agentResume = null;
    this.agentPauseReason = '';
    if (resume !== null) {
      resume(go);
    }
  }

  /**
   * 发送一条消息。有历史就接着上次聊，没有就当新任务开始。
   * AgentLoop 实例跨任务存活，只有「清空上下文」和断开连接才丢掉它 ——
   * 屏幕熄灭中断之后要能接着继续，靠的就是这个实例还在。
   */
  private async onSendAgent(): Promise<void> {
    if (this.agentRunning) {
      return;
    }
    // 第二道保险：历史模式下发送按钮本来就不渲染，但输入框里可能还留着翻页前打的字，
    // 任何别的路径调到这里都不能把那串字发进最新那段 —— 屏幕上显示的明明是历史。
    if (!this.viewingLatest()) {
      this.toast('正在看历史会话，先回到最新');
      return;
    }
    const task = this.agentTaskInput.trim();
    if (task.length === 0) {
      this.toast(this.agentLoop !== null && this.agentLoop.hasHistory() ? '先写点什么' : '先说要做什么');
      return;
    }
    const device = this.agent;
    const api = this.agentApi;
    const config = this.agentConfig;
    if (device === null || api === null || config === null) {
      this.toast('设备或模型未就绪');
      return;
    }
    if (!isAgentConfigured(config)) {
      this.toast(`配置不完整，还缺: ${describeMissing(config).join('、')}`);
      return;
    }

    const continuing = this.agentLoop !== null && this.agentLoop.hasHistory();
    if (!continuing) {
      this.resetTimelineCounters();
      this.agentLiveTimeline = [];
      this.agentPercent = 0;
      this.agentTodoSummary = '未制定计划';
      this.agentUsageText = '';
    }
    this.agentRunning = true;
    this.agentStoppedByUser = false;
    this.pushTimeline('notice', continuing ? `你说：${task}` : `任务：${task}`);
    this.agentTaskInput = '';

    // 一按开始就申请保活：保活拿不到要立刻知道，而不是等切走那一刻才暴露。
    const hooks: KeepAliveHooks = {
      onCancelledByUser: (reason: string): void => {
        this.pushTimeline('notice', `${reason}，任务停止。`);
        const loop = this.agentLoop;
        if (loop !== null) {
          loop.stop();
        }
      },
      onSuspended: (reason: string): void => {
        this.pushTimeline('error', reason);
      }
    };
    const alive = new KeepAlive(
      this.getCtx() as common.UIAbilityContext, hooks, (line: string) => this.appendLog(line)
    );
    this.keepAlive = alive;
    const gotAlive = await alive.start();
    this.agentKeepMode = alive.mode() +
      (alive.notificationEnabled() ? '' : ' · 通知被关') +
      (alive.supportsProgress() ? (alive.hasNotificationButton() ? ' · 有按钮' : ' · 无按钮') : '');
    if (!gotAlive) {
      this.pushTimeline('error', '没有拿到后台保活，切到别的应用后任务会被系统挂起。');
    }

    let loop = this.agentLoop;
    if (loop === null) {
      loop = new AgentLoop(
        device, api, config, this.getCtx().applicationInfo.name, this.buildAgentHooks(), defaultLimits()
      );
      this.agentLoop = loop;
    }
    this.syncHistoryFlag();
    // 每次发送都推入最新配置，否则改完设置还在用建实例时那一份。
    loop.applyConfig(config);
    // 设备控制层持有自己的一份设置副本，也要一起换掉。只更新 loop 的话，黑名单会有
    // 两个答案：加条目被闸门挡住看不出问题，删条目则表现为「已解禁的应用仍被拒绝」。
    device.applySettings(this.buildActionSettings(config));
    try {
      if (continuing) {
        await loop.continueWith(task);
      } else {
        await loop.run(task);
      }
    } catch (err) {
      this.pushTimeline('error', `任务异常: ${(err as BusinessError).message}`);
    } finally {
      this.agentRunning = false;
      this.resolvePause(false);
      // **先写盘，再停保活。顺序不能反。**
      //
      // 反过来写会有概率丢掉最后那条「完成」消息，用户实测遇到过两次：
      // `alive.stop()` 一停，本应用就变成一个没有长时任务保护的后台应用，
      // 系统可以随时把它挂起；而 stop 本身还是个 await，中间多一个让出点。
      // 原先写盘排在 stop 之后，于是"任务跑完了、最后一条却没落盘"是个真实的概率事件 ——
      // 而任务在后台跑完的那一刻恰恰是最危险的时刻。
      //
      // keepMode 也顺势变准了：在 stop 之前读 `alive.mode()` 拿到的是这一轮真实的保活方式，
      // 原先在 stop 之后读，于是每一段存档都固定记着「未保活」。
      this.agentKeepMode = alive.mode();
      // 这一轮无论怎么结束都立刻写盘：中断、跑完、出错，之后都要能接着聊。
      // 用 flush 而不是等攒批到点，免得最后几条事件卡在定时器里。
      this.flushSessionSave();
      await alive.stop(true);
      // 停完必须再读一次，因为 `agentKeepMode` **同时**是界面顶部那行状态。
      // 上面为了让存档记住"这一轮是怎么保活的"，在 stop 之前先读了一次；
      // 少了这一句，任务结束后状态行就一直挂着「保活中」—— 实测出现过。
      //
      // 两次读各有各的用处，别为了省一行合成一次：
      // · stop 之前那次给存档（这一轮真实的保活方式）
      // · stop 之后这次给界面（现在已经不保活了）
      this.agentKeepMode = alive.mode();
      this.keepAlive = null;
      this.syncHistoryFlag();
      // 跑完/出错就把用户带回来看结果。挂在这里而不是挂 'finished' 事件上，有两个原因：
      //
      // 一、任务**中途**也会推 'error'（拿不到保活那条就是在开跑前推的），
      //    按事件类型触发会在任务还在跑的时候把人拽回来。
      // 二、恢复会话时会把存档里的时间线逐条重放，其中就有历史上的 'finished'，
      //    挂事件等于每次开应用都自己拉一次前台。
      //
      // 这里是 agentRunning 由 true 变 false 的唯一一处，每轮任务恰好经过一次。
      if (!this.agentStoppedByUser) {
        await this.returnToAgentPage();
      }
    }
  }

  private agentHasHistory(): boolean {
    return this.agentHistoryFlag;
  }

  /** 每次 agentLoop 变动或跑完一轮都要调，让界面条件跟得上真实状态。 */
  private syncHistoryFlag(): void {
    const loop = this.agentLoop;
    this.agentHistoryFlag = loop !== null && loop.hasHistory();
  }

  /** 段号常显，形如「第 2/3 段」。没有任何会话时显示「新的一段」。 */
  private sessionPositionText(): string {
    const total = this.agentSessionIds.length;
    if (total === 0) {
      return '新的一段';
    }
    return `第 ${this.agentViewIdx + 1}/${total} 段`;
  }

  /**
   * 标题栏下面那行状态。每一段都保持短且长度稳定，避免任务跑起来之后忽长忽短。
   * 「计划 未制定计划」这种重复说法也一并压掉。
   */
  private agentStatusLine(): string {
    const parts: string[] = [this.sessionPositionText()];
    // 计划进度要跟着**正在看的那一段**走，不能只报最新那段的。
    // 原先整行只读一个全局值，于是翻到历史段时显示的是最新那段的进度 ——
    // 最新那段常常是刚开的空会话，结果每一段都显示「无计划」。
    const todo = this.todoSummaryForView();
    parts.push(todo === '未制定计划' ? '无计划' : `计划 ${todo}`);
    // 保活方式原文可能很长（带「通知被关」「有按钮」等后缀），标题栏只要一个字的结论。
    parts.push(this.agentKeepMode.indexOf('未保活') >= 0 ? '未保活' : '保活中');
    return parts.join(' · ');
  }

  /** 只在最新一段才有输入框，所以不必再有历史那一支。 */
  private agentInputHint(): string {
    return this.agentHasHistory() ? '接着说' : '要我做什么';
  }

  /**
   * 还没落盘的那几条时间线，按时间顺序返回。
   *
   * 取的是活跃时间线的尾巴：截断只丢头部，所以尾巴永远是最新的那几条。
   * 万一一次攒批里的新增条数超过了界面持有上限（AGENT_MAX_TIMELINE），
   * 就只能写下手里还有的这些 —— 那要求 2 秒内推进四百条事件，实际不会发生，
   * 但夹一个下限总比越界取值安全。
   */
  private pendingTimelineForStore(): StoredTimelineEntry[] {
    const pending = Math.min(
      this.timelineTotal - this.timelinePersisted,
      this.agentLiveTimeline.length
    );
    if (pending <= 0) {
      return [];
    }
    const tail = this.agentLiveTimeline.slice(this.agentLiveTimeline.length - pending);
    return tail.map((e: TimelineItem): StoredTimelineEntry => {
      return { kind: e.kind, text: e.text, toolName: '' };
    });
  }

  /** 活跃会话的 id。还没有任何会话时现场登记一个。 */
  private activeSessionId(): string {
    if (this.agentSessionIds.length > 0) {
      return this.agentSessionIds[this.agentSessionIds.length - 1];
    }
    const id = newSessionId([]);
    const index = registerSession(
      this.getCtx() as common.UIAbilityContext, id, (line: string) => this.appendLog(line)
    );
    this.agentSessionIds = index.ids;
    this.ensurePageOpacity();
    // 新开一段就把视图切到它。两个都赋：这是无动效的切换，绑定那个要跟着走。
    this.agentViewIdx = index.ids.length - 1;
    this.agentSwiperIdx = this.agentViewIdx;
    return id;
  }

  /**
   * 写盘。进程可能毫无预警被杀，所以不等任务结束，全程被时间线事件推着走。
   *
   * 快照整包重写，时间线只追加新增的那几条。追加成功之后才推进已落盘计数 ——
   * 写失败就保持原值，下一次攒批会把这几条连着后面的一起重发，不会静默丢一段。
   */
  private saveAgentSnapshot(): void {
    const loop = this.agentLoop;
    if (loop === null || !loop.hasHistory()) {
      return;
    }
    const pending = this.pendingTimelineForStore();
    const ok = saveSession(
      this.getCtx() as common.UIAbilityContext,
      this.activeSessionId(),
      loop.snapshot(),
      pending,
      this.agentKeepMode,
      (line: string) => this.appendLog(line)
    );
    if (ok) {
      this.timelinePersisted += pending.length;
    }
  }

  /**
   * 进入 AGENT 页时回到最新那段会话的最后一条。
   * 只在还没有活跃实例时恢复，避免覆盖正在进行的对话。
   */
  private restoreAgentSession(): void {
    const log: (line: string) => void = (line: string) => this.appendLog(line);
    const index = loadIndex(this.getCtx() as common.UIAbilityContext, log);
    this.agentSessionIds = index.ids;
    this.ensurePageOpacity();
    // 恢复会话：直接停在最新那一段，无动效，两个都赋。
    this.agentViewIdx = index.ids.length - 1;
    this.agentSwiperIdx = this.agentViewIdx;
    this.agentPageItems = [];
    this.agentPageTodo = [];
    if (this.agentLoop !== null) {
      // 已有活跃实例：只把展示切回最新那段，不重建时间线。
      this.jumpToLatest();
      return;
    }
    if (index.ids.length === 0) {
      return;
    }
    const latestId = index.ids[index.ids.length - 1];
    const stored = loadSessionById(this.getCtx() as common.UIAbilityContext, latestId, log);
    if (stored === null) {
      return;
    }
    const device = this.agent;
    const api = this.agentApi;
    const config = this.agentConfig;
    if (device === null || api === null || config === null) {
      return;
    }
    const loop = new AgentLoop(
      device, api, config, this.getCtx().applicationInfo.name, this.buildAgentHooks(), defaultLimits()
    );
    loop.restore(stored.snapshot);
    this.agentLoop = loop;
    this.syncHistoryFlag();
    this.resetTimelineCounters();
    this.agentLiveTimeline = [];
    this.restoringTimeline = true;
    for (const entry of stored.timeline) {
      this.pushTimeline(entry.kind, entry.text);
    }
    this.restoringTimeline = false;
    // 刚灌回来的这些本来就在磁盘上，标记成已落盘，否则下一次写盘会把它们再追加一遍。
    this.timelinePersisted = this.timelineTotal;
    // 冷启动（杀掉应用后重进）这条路径不在这里请求落点，尽管它确实需要落点 ——
    // 上面那些 pushTimeline 里的落底调用此刻全是空的（页面还在建），而这条路
    // 又不经过 jumpToLatest，所以没有任何人把位置摆到底部。
    //
    // 落点统一交给 `openAgentPage` 开的那段盯底窗口，就在调用本函数的下一行。
    // 放那边的理由：这里发一发滚动是没用的（页面还没建完），而窗口能等到布局真的完成。

    // 这里曾追加一句「已恢复上次的对话，发消息接着继续。」**不要加回来。**
    //
    // 它会被写进存档：要保存的时间线就是这条活跃时间线，追加的这句也在里面。
    // 于是每「重启应用 + 进一次页面」就在历史里多存一句，第 3 段实测已攒到 2 份
    // （第 3 条和第 34 条）。更糟的是它成了那一段的最后一行 ——
    // 从这一段往下翻时，留在夹缝里最后可见的就是它，用户看到的就是
    // 一句莫名其妙、还被切掉一半的话。
    //
    // 代价：重启后进页面，上次的对话直接列出来，没有一行字解释原因。
    // 输入行的按钮文案已经是「发送」而不是「开始」，本身就表示接着聊。
  }

  /**
   * 盯住某一页的落点，直到布局真的完成。见 `agentStickUntil`。
   *
   * 谁需要它：**任何"内容刚换好、马上要摆位置"的时机。**那一刻列表还没布局，
   * 直接 `snapToEdge` 是空操作（内容高度接近 0，滚到哪儿都等于没滚）。
   *
   * 原先它只管活跃页、只管底部，叫 `stickBottomIfWanted`。翻会话时目标页也要摆位置，
   * 而且往下翻要摆到**开头**，所以推广成任意页、任意边。
   */
  private armStick(idx: number, edge: Edge, ms: number = AGENT_STICK_MS): void {
    this.agentStickPage = idx;
    this.agentStickEdge = edge;
    this.agentStickUntil = Date.now() + ms;
  }

  /**
   * 开窗口，但**只延长、不缩短**。
   *
   * 追加消息那条路要用它，不能直接用 `armStick`：进页面 / 从后台回来时开的是 8 秒窗口
   * （内容从零布局出来实测要五秒），而任务一跑，消息一条接一条地来。每条都用 400ms
   * 覆盖一次的话，那 8 秒窗口在第一条消息到达时就被砍成 400ms —— 五秒后才完成的布局
   * 再也等不到落点，"从后台回来停在最上方"那个 bug 就换个形式回来了。
   *
   * 只在盯的是同一页同一边时才让步。页面变了或要盯的边变了（往上翻要盯开头），
   * 最新那次请求必须赢，那是 `armStick` 原来的语义。
   */
  private armStickAtLeast(idx: number, edge: Edge, ms: number): void {
    const until = Date.now() + ms;
    if (idx === this.agentStickPage && edge === this.agentStickEdge &&
      this.agentStickUntil > until) {
      return;
    }
    this.armStick(idx, edge, ms);
  }

  /**
   * 追加一条消息之后，补两拍不依赖回调的落点。理由见 `AGENT_FOLLOW_CATCHUP_MS`。
   *
   * 判据完全借用盯底窗口：只要窗口还开着、盯的还是这一页，就再贴一次。
   * 于是"用户自己动手了"这一种不必在这里重新判断 —— `onWillScroll` 撤窗口时
   * 这两拍就一起失效了。
   */
  private catchUpFollow(idx: number): void {
    for (const ms of AGENT_FOLLOW_CATCHUP_MS) {
      setTimeout(() => {
        if (idx !== this.agentStickPage || this.agentStickUntil === 0 ||
          Date.now() >= this.agentStickUntil) {
          return;
        }
        this.snapToEdge(idx, this.agentStickEdge);
      }, ms);
    }
  }

  /** 布局相关的回调都调它。不是在盯的那一页就什么都不做。 */
  private stickIfWanted(idx: number): void {
    if (this.agentStickUntil === 0 || idx !== this.agentStickPage) {
      return;
    }
    if (Date.now() >= this.agentStickUntil) {
      this.agentStickUntil = 0;
      this.agentStickPage = -1;
      return;
    }
    this.snapToEdge(idx, this.agentStickEdge);
  }

  /**
   * 立刻把某一页摆到首条或末条，**不带动画**。所有落点最终都走这里。
   *
   * 用 `scrollEdge`：在 `List` 上它默认无动画（官方原话是只有 `Scroll` 默认带动画），
   * 而且官方注明首次布局前调用不带动画的 `scrollEdge` 同样生效。原先为了避开 `Scroll`
   * 的动画而绕的「滚到一个极大偏移让它自己夹到底」已经不需要了。
   *
   * **这个函数只负责"现在就滚"，不负责"等到能滚"。** 页面刚建好或刚从后台回来时
   * 布局要五秒才完成，那种时机单独调它是没用的，得靠 `agentStickUntil` 那个窗口
   * 反复调它。别把重试逻辑加进这里 —— 那正是被删掉的 `scheduleLand` 那套。
   *
   * 包 try/catch 是因为这里可能对一个**还没绑定到任何组件**的 Scroller 下命令：
   * `switchSession` 在翻页动作之前就先请求落点，而目标那一页可能还没被 Swiper 建出来。
   * 同一类事情已经让应用启动即挂过一次（对空 Scroller 调 `currentOffset()`），
   * 不能再来一遍。
   */
  private snapToEdge(idx: number, edge: Edge): void {
    const count = this.itemsForPage(idx).length;
    if (count === 0) {
      return;
    }
    try {
      // 竖向 List 上 `Edge.End` 就是 `Edge.Bottom`、`Edge.Start` 就是 `Edge.Top`，
      // 这个映射是恒等的，写成哪一对都一样。保留它只是因为落点这条路刚稳定下来，
      // 不想为了省一次三元运算再动一遍执行行。
      //
      // **这里曾经写着一段"stackFromEnd 把布局原点搬到末尾，所以 Start/End 与 Bottom/Top
      // 不再是一回事"，以及三条"换过三版"的实测记录。那段话是错的，已删。**
      // 组件自己报的偏移是：`onReachStart` → y=0，`onReachEnd` → y=2769。
      // 轴是正常的，从头到尾没被反转过。
      //
      // 那三条记录（`scrollEdge(Edge.Bottom)` 偏移从 −350 变 +1295 而屏幕停在开头、
      // `scrollToIndex` 和 `scrollTo` 偏移一动不动）全是在**内容还没布局出来**的状态下测的
      // —— 偏移是负数就是证据。那个状态下内容高度接近 0，任何目标值都退化成当前位置，
      // 所以它们证明的不是"这种写法不行"，只是"这一刻还没东西可滚"。
      // 真正的原因是布局要五秒，解法是 `agentStickUntil` 那个窗口。
      this.scrollerFor(idx).scrollEdge(edge === Edge.Bottom ? Edge.End : Edge.Start);
    } catch (err) {
      this.appendLog(`[ui] 落点失败(第 ${idx} 页): ${(err as BusinessError).message}`);
    }
  }



  /**
   * 翻到相邻的一段会话。delta 为 -1 是更老的一段，+1 是更新的一段。
   * 落点按瀑布方向：往上翻落在那段的末尾，往下翻落在那段的开头。
   *
   * 内容**不换**：目标段本来就在它自己那一页上，这里只让组件把页翻过去。
   * 动效是组件自带的弹簧翻页（默认曲线 interpolatingSpring(-1,1,328,34)），
   * 不是手写的位移或透明度 —— 手写那五种全被否过。
   */
  private switchSession(delta: number): void {
    const target = this.agentViewIdx + delta;
    if (target < 0 || target >= this.agentSessionIds.length) {
      // 到头了不弹 toast：拖动过程中空隙里已经写着「已经是最早/最新的一段」，
      // 而 toast 落在屏幕下方，正好压住底部那两条拉动提示。说两遍还互相遮挡。
      return;
    }
    // 确定会翻了，现在才封锁并记下被翻走的那一页。**顺序不能提前到越界检查之前** ——
    // 到头了那一下什么都没发生，封锁和 fadingOutIdx 就都成了留在原地的脏值。
    this.agentFlipUntil = Date.now() + AGENT_FLIP_DURATION_MS + AGENT_FLIP_GUARD_SLACK_MS;
    // 动画期间关掉列表的手指滚动，否则第二下划会滚动正在滑出去的旧页。见 `agentFlipping`。
    this.agentFlipping = true;
    // 这一页此刻已经淡到最暗（拉动进度被夹在 1），翻页动画接着从这里往下走，
    // 中间不会有「先亮回来再淡下去」的跳变。记下它是哪一页，好让逐帧回调别把它调亮。
    this.fadingOutIdx = this.fadePageIdx();
    // 先把那一段读进它自己那页，再翻。顺序反了会翻到一张空页上。
    this.loadPage(target);
    // 落点按瀑布方向：往上翻（看更早的一段）落在那段**末尾**，往下翻落在那段开头。
    // 这就是"瀑布流"的接缝 —— 往上翻接的是上一段的尾巴，不是它的开头。
    const landing: Edge = delta < 0 ? Edge.Bottom : Edge.Top;
    // 三道保险，各管一种情形。**arm 必须排在推动 Swiper 之前**，
    // 因为目标页可能在翻页过程中才被建出来，而 onAttach 要靠 arm 的值决定落哪一边。
    //
    // ① 这一页之前访问过、布局还在 → 下面这一句立刻就摆好了。
    this.armStick(target, landing);
    this.snapToEdge(target, landing);
    // ② 这一页是现在才建的 → 由它的 `onAttach` 在**首次布局前**落点（见那里的注释）。
    //    这是唯一能让动画从第一帧起就显示正确位置的时机。
    // ③ 上面两条都没赶上（已建但还没布局）→ 盯窗口在随后的布局回调里把它拽对。
    //    这一条会露馅，但它是兜底，不是主路。
    // 进来那页先压暗，再开始翻。不压的话它第一帧是全亮的 ——
    // 逐帧回调要等动画跑起来才触发，那一帧的全亮就是「一下子怼到眼前」。
    this.agentFadeAnimMs = 0;
    if (target < this.agentPageOpacity.length) {
      this.agentPageOpacity[target] = 1 - AGENT_FADE_IN_DEPTH;
    }
    // **现在就把"在第几段"改成目标页**，不等组件回写。
    //
    // 这一句以前是禁止的，因为那时 `agentViewIdx` 双向绑在 Swiper 的 index 上，
    // 一赋值组件就瞬跳过去，动画就没了。现在绑定换成了 `agentSwiperIdx`
    // （见那个字段的注释），赋这个不会碰到组件，动画照旧。
    //
    // 必须现在赋：否则动画那 320 毫秒里所有判断读到的都是旧页号。
    // 上面 `fadingOutIdx` 已经先把旧页号取走了，顺序不能反。
    this.agentViewIdx = target;
    // 翻页只发命令，让组件自己走完动画。
    if (delta < 0) {
      this.agentSwiper.showPrevious();
    } else {
      this.agentSwiper.showNext();
    }
  }

  /**
   * 直接回到最新那一段。**不带动效**：这是按钮点出来的跳转，
   * 中间隔着几段的话，逐页翻过去只会看到一串闪动。
   */
  private jumpToLatest(): void {
    if (this.agentSessionIds.length === 0) {
      return;
    }
    const target = this.agentSessionIds.length - 1;
    // 无动效跳转：两个都要赋。绑定那个负责让组件停在正确的页，
    // `changeIndex(target, false)` 是为了组件已经建好时也能立刻过去。
    this.agentViewIdx = target;
    this.agentSwiperIdx = target;
    this.agentSwiper.changeIndex(target, false);
    // 这一下对付的是"这一页之前被用户翻到过中间"，也就是布局已经稳定、只是位置不对。
    // 而"页面刚建好/刚从后台回来"那几种时机它够不着（那时布局还没完成，滚了等于没滚），
    // 归 `agentStickUntil` 那个窗口管。两者互补，别把其中一个删了。
    this.snapToEdge(target, Edge.Bottom);
  }

  /**
   * 开一段新会话。旧会话**不删**，只是不再是活跃的那一段，
   * 之后可以从顶部用力下拉翻回去。
   */
  private onNewAgentSession(): void {
    if (this.agentRunning) {
      this.toast('任务还在跑，先停止');
      return;
    }
    // 当前这段先落盘，否则刚说的话会随着实例一起丢掉。
    // 必须 flush：待触发的定时器会在 agentLoop 被清空之后才醒，那一趟就白跑了。
    this.flushSessionSave();
    const log: (line: string) => void = (line: string) => this.appendLog(line);
    const id = newSessionId(this.agentSessionIds);
    const index = registerSession(this.getCtx() as common.UIAbilityContext, id, log);
    this.agentSessionIds = index.ids;
    this.ensurePageOpacity();
    this.agentLoop = null;
    this.syncHistoryFlag();
    this.resetTimelineCounters();
    this.agentLiveTimeline = [];
    this.agentPercent = 0;
    this.agentTodoSummary = '未制定计划';
    this.agentUsageText = '';
    // 刚才那段已经不是活跃段了，它变成倒数第二页。页里的内容与计划都清掉，
    // 翻回去时再从磁盘读 —— 上面 saveAgentSnapshot 已经把它写下去了。
    this.agentPageItems = [];
    this.agentPageTodo = [];
    // 无动效跳到新那一段，两个都赋。
    this.agentViewIdx = index.ids.length - 1;
    this.agentSwiperIdx = this.agentViewIdx;
    this.agentSwiper.changeIndex(this.agentViewIdx, false);
    this.toast('已开始新会话');
  }

  private onStopAgent(): void {
    // 记下"这一轮是用户自己按停的"。按停止意味着人就在 AGENT 页上看着，
    // 不需要再把应用拉回前台。见 `returnToAgentPage` 的调用处。
    this.agentStoppedByUser = true;
    const loop = this.agentLoop;
    if (loop !== null) {
      loop.stop();
    }
    this.resolvePause(false);
  }

  /**
   * 一轮任务跑完后把用户带回 AGENT 页看结果。
   *
   * 两步，顺序要紧：先切本应用内的页面，再把应用拉到前台。反了的话窗口出现的那一刻
   * 显示的还是终端页或电源页，会看到一次跳变。
   *
   * 拉前台走 shell 的 `aa start`，不走系统 API —— 我们本来就握着一条 shell 通道，
   * 而应用自己把自己拉到前台在系统 API 那边是受限的。
   *
   * 屏幕熄灭或锁屏时 `aa start` 会被系统以 `10106102` 拒绝。**只记一行日志，
   * 不唤醒屏幕、不重试** —— 用户没要这个，而唤醒屏幕是抢屏。
   */
  private async returnToAgentPage(): Promise<void> {
    this.showTerminalPage = false;
    this.showClearPage = false;
    this.showPowerPage = false;
    this.showAgentSettings = false;
    this.showAgentPage = true;
    this.jumpToLatest();
    // 应用可能整个在后台（用户按了 Home 或切去了别的应用）。这时上面那一下 scrollEdge
    // 是空操作 —— 后台里滚不动。留个一次性标记，等页面真正可见时再滚一次。
    this.agentLandBottomOnShow = true;
    // 真正把位置摆对的是这个窗口：应用被拉回前台后内容要好几秒才布局完，
    // 期间每次布局变化都重贴一次末尾。见 `agentStickUntil`。
    this.armStick(this.livePageIdx(), Edge.Bottom);
    const conn = this.conn;
    if (conn === null) {
      return;
    }
    try {
      const ctx = this.getCtx() as common.UIAbilityContext;
      // 三个名字都从清单里读，不写死。
      const command = `aa start -b ${ctx.applicationInfo.name}` +
        ` -a ${ctx.abilityInfo.name} -m ${ctx.abilityInfo.moduleName}`;
      const out = await conn.executeCommand(command, AGENT_COMMAND_TIMEOUT_MS);
      if (out.indexOf('successfully') < 0) {
        this.appendLog(`[agent] 自动回到界面没成: ${out.trim()}`);
        return;
      }
    } catch (err) {
      this.appendLog(`[agent] 自动回到界面没成: ${(err as BusinessError).message}`);
      return;
    }
  }

  private async onDisconnect(): Promise<void> {
    const loop = this.agentLoop;
    if (loop !== null) {
      loop.stop();
      this.agentLoop = null;
      this.syncHistoryFlag();
    }
    const alive = this.keepAlive;
    if (alive !== null) {
      await alive.stop(false);
      this.keepAlive = null;
    }
    this.agentRunning = false;
    this.showAgentPage = false;
    // 断开连接也会把人踢出 AGENT 页，键盘避让模式同样要还回去。
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    if (this.agentApi !== null) {
      this.agentApi.abort();
      this.agentApi = null;
    }
    this.agentConfig = null;
    this.agent = null;
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
    // 用户插话优先于一切隐藏逻辑：列宽设置的回显若还在吞咽，立即放行
    this.flushColumnsSwallow();
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
    this.terminal.reset();
    if (this.terminalColumnsTimer >= 0) {
      clearTimeout(this.terminalColumnsTimer);
      this.terminalColumnsTimer = -1;
    }
    this.terminalColumnsSwallowing = false;
    this.terminalColumnsSwallow = '';
    this.terminalFlushPending = false;
    this.terminalScrollPending = false;
    this.terminalStickToBottom = true;
    this.outputText = '';
  }

  /**
   * 回显进入模拟器，不再直接拼字符串。
   *
   * 旧做法把 mksh 重画长命令时的 `\r`、补位空格、`<` 标记全当文字拼进来，
   * 长命令回显变成碎片拼接（2026-08-18 实测，见 doc/terminal-echo.md）。
   * 模拟器按 80 列终端的语义消化这些控制码，吐出「屏幕上该有的样子」。
   */
  private feedTerminalOutput(text: string): void {
    if (text.length === 0) {
      return;
    }
    if (this.terminalColumnsSwallowing) {
      this.terminalColumnsSwallow += text;
      if (this.columnsSwallowDone()) {
        this.completeColumnsSwallow();
      }
      return;
    }
    this.terminal.feed(text);
    if (this.showTerminalPage && this.terminalStickToBottom) {
      this.scheduleTerminalOutputFlush();
    }
  }

  /**
   * 连接建立后把终端列宽下发到 shell（为什么需要见 TERMINAL_COLUMNS）。
   *
   * 时机与显示各有一条教训：
   * - **等第一个提示符画出来再发。** 第一版连接成功立刻发，命令抢在提示符前，
   *   内核回显先落一行裸的 `COLUMNS=200`，mksh 行编辑器接管后又带着提示符重画
   *   一遍——终端里出现两行 COLUMNS（2026-08-18 用户当场抓到）。
   * - **吞掉这条命令自己的回显。** 它是内部设置不是用户输入：从发送起把回显
   *   攒在旁边不进模拟器，直到执行完的下一个提示符出现，整段丢弃，终端从发送前
   *   那个干净提示符继续。3 秒兜底：没等到就全部放行，宁可显示出来也不丢输出；
   *   用户在吞咽期间插话也立即放行。
   */
  private async setupTerminalColumns(): Promise<void> {
    const shell = this.shell;
    if (shell === null) {
      return;
    }
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline && !this.terminal.getActiveLine().endsWith('$ ')) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 50));
    }
    this.terminalColumnsSwallowing = true;
    this.terminalColumnsSwallow = '';
    this.terminalColumnsTimer = setTimeout(() => {
      this.flushColumnsSwallow();
    }, 3000);
    try {
      await shell.sendCommand(`COLUMNS=${TERMINAL_COLUMNS}`);
    } catch (err) {
      this.appendLog(`[shell] 设置列宽失败: ${(err as BusinessError).message}`);
      this.flushColumnsSwallow();
    }
  }

  /** 吞咽是否到头：攒下的字节里，最后一个换行之后恰好是新的提示符。 */
  private columnsSwallowDone(): boolean {
    const buf = this.terminalColumnsSwallow;
    const idx = buf.lastIndexOf('\n');
    return idx >= 0 && buf.substring(idx + 1) === '$ ';
  }

  private clearColumnsTimer(): void {
    if (this.terminalColumnsTimer >= 0) {
      clearTimeout(this.terminalColumnsTimer);
      this.terminalColumnsTimer = -1;
    }
  }

  /** 正常完成：攒下的只是设置命令自己的回显与执行后的新提示符，整段丢弃。 */
  private completeColumnsSwallow(): void {
    this.clearColumnsTimer();
    this.terminalColumnsSwallowing = false;
    const echoed = this.terminalColumnsSwallow;
    this.terminalColumnsSwallow = '';
    // 屏上保留发送前的提示符；万一它没画上（竞态兜底）补一个
    if (echoed.length > 0 && !this.terminal.getActiveLine().endsWith('$ ')) {
      this.terminal.feed('$ ');
      if (this.showTerminalPage && this.terminalStickToBottom) {
        this.scheduleTerminalOutputFlush();
      }
    }
  }

  /** 异常放行（超时/用户插话/发送失败）：把攒下的字节全部喂给模拟器，不丢输出。 */
  private flushColumnsSwallow(): void {
    this.clearColumnsTimer();
    if (!this.terminalColumnsSwallowing) {
      return;
    }
    this.terminalColumnsSwallowing = false;
    const pending = this.terminalColumnsSwallow;
    this.terminalColumnsSwallow = '';
    this.terminal.feed(pending);
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
    let text = this.terminal.getDisplayText();
    const renderTruncated = text.length > MAX_OUTPUT_RENDER_CHARS;
    if (renderTruncated) {
      text = text.slice(text.length - MAX_OUTPUT_RENDER_CHARS);
    }
    const rendered = (this.terminal.isTruncated() || renderTruncated) ?
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
    this.showInstallPage = false;
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
    this.showInstallPage = false;
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
    this.showInstallPage = false;
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

  // ---------- 安装 HAP ----------

  /**
   * 安装页不检查 connected：选文件不需要连接。
   * 「从文件管理器点 .hap 打开」进来时应用多半还没连接，所以连接检查放在点安装时。
   */
  private openInstallPage(): void {
    this.showTerminalPage = false;
    this.showClearPage = false;
    this.showPowerPage = false;
    this.showAgentPage = false;
    this.showInstallPage = true;
  }

  private closeInstallPage(): void {
    this.showInstallPage = false;
  }

  /** 系统文件选择器选 .hap（无需任何权限）。 */
  private async pickHapFile(): Promise<void> {
    try {
      const ctx = this.getCtx() as common.UIAbilityContext;
      const docPicker = new picker.DocumentViewPicker(ctx);
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['.hap'];
      const uris: Array<string> = await docPicker.select(opt);
      if (uris.length === 0) {
        return;
      }
      this.setPendingHap(uris[0]);
    } catch (err) {
      const msg = (err as BusinessError).message ?? `${err}`;
      this.appendLog(`[install] 选择文件失败: ${msg}`);
      this.toast(`选择文件失败: ${msg}`);
    }
  }

  /** 记下待安装文件：uri、显示名、真实路径（给 shell cp 用）、大小。 */
  private setPendingHap(uri: string): void {
    this.hapUri = uri;
    this.installBusy = false;
    this.installPhaseText = '';
    this.installResultOk = false;
    this.installResultText = '';
    let name = uri;
    let realPath = '';
    try {
      const fu = new fileUri.FileUri(uri);
      // name/path 属性自带 ASCII 解码：uri 尾段编码过的文件名直接可读。
      name = fu.name;
      realPath = fu.path;
    } catch (err) {
      // 构造失败时退回手解 uri 尾段，路径留空（点安装时会提示先选文件）
      const slash = name.lastIndexOf('/');
      if (slash >= 0) {
        name = name.substring(slash + 1);
      }
      try {
        name = decodeURIComponent(name);
      } catch (decodeErr) {
        // 文件名本身含 % 等字符时解码失败，保留原样
      }
    }
    this.hapDisplayName = name;
    this.hapRealPath = realPath;
    this.hapFileSize = -1;
    let sizeText = '';
    if (realPath.length > 0) {
      try {
        const stat = fileIo.statSync(realPath);
        sizeText = this.formatHapSize(stat.size);
        this.hapFileSize = stat.size;
      } catch (err) {
        sizeText = '';
      }
    }
    this.hapSizeText = sizeText;
    this.appendLog(`[install] 已选择 ${name}${sizeText.length > 0 ? `（${sizeText}）` : ''}`);
  }

  private formatHapSize(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes < 0) {
      return '';
    }
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    const units: string[] = ['KB', 'MB', 'GB'];
    let value = bytes;
    let unit = -1;
    do {
      value /= 1024;
      unit += 1;
    } while (value >= 1024 && unit < units.length - 1);
    return `${value.toFixed(value >= 100 ? 0 : 1)} ${units[unit]}`;
  }

  private onInstallHapClick(): void {
    if (this.installBusy) {
      return;
    }
    if (this.hapUri.length === 0) {
      this.toast('请先选择 HAP 文件');
      return;
    }
    if (this.hapRealPath.length === 0) {
      // 选了文件但 FileUri 解析不出路径（picker 罕见失败路径）——别再说「请先选择」
      this.toast('无法解析所选文件的路径，请重新选择');
      return;
    }
    if (!this.connected) {
      this.toast('请先连接设备');
      return;
    }
    const sizeLine = this.hapSizeText.length > 0 ? `（${this.hapSizeText}）` : '';
    this.getUIContext().showAlertDialog({
      title: '确认安装',
      message: `将安装 ${this.hapDisplayName}${sizeLine}\n同名应用会被覆盖。`,
      autoCancel: false,
      primaryButton: {
        value: '安装',
        fontColor: Color.Red,
        action: () => { this.doInstallHap(); }
      },
      secondaryButton: {
        value: '取消',
        action: () => {}
      }
    });
  }

  private async doInstallHap(): Promise<void> {
    const conn = this.conn;
    if (conn === null || this.hapUri.length === 0 || this.installBusy) {
      return;
    }
    if (this.hapFileSize <= 0) {
      // stat 失败过：重新拿一次大小（传输协议必须要 fileSize）
      try {
        const fu = new fileUri.FileUri(this.hapUri);
        this.hapFileSize = fileIo.statSync(fu.path).size;
      } catch (err) {
        this.installResultOk = false;
        this.installResultText = `无法读取文件大小: ${(err as BusinessError).message ?? `${err}`}`;
        return;
      }
    }
    this.installBusy = true;
    this.installResultOk = false;
    this.installResultText = '';
    const totalSize = this.hapFileSize;
    // 读缓冲复用：传输是顺序 await 的，一块读完才读下一块，单缓冲安全。
    // 返回视图（不 slice 拷贝），通道侧自己 set 进帧缓冲。
    const readBuf = new ArrayBuffer(FILE_CHUNK_BYTES);
    try {
      const file = fileIo.openSync(this.hapUri, fileIo.OpenMode.READ_ONLY);
      let transferText = '正在传输到设备...';
      try {
        const result: HapInstallResult = await installHapFromUri(
          conn,
          totalSize,
          (offset: number, maxLen: number): Promise<Uint8Array> => {
            return new Promise<Uint8Array>((resolve: (data: Uint8Array) => void, reject: (err: Error) => void) => {
              try {
                const n = fileIo.readSync(file.fd, readBuf, { offset, length: maxLen });
                resolve(new Uint8Array(readBuf, 0, n));
              } catch (err) {
                reject(new Error(`读文件失败: ${(err as BusinessError).message ?? `${err}`}`));
              }
            });
          },
          (phase: string, progressBytes?: number) => {
            if (phase === 'transfer' && progressBytes !== undefined && totalSize > 0) {
              transferText = `正在传输到设备... ${this.formatHapSize(progressBytes)} / ${this.formatHapSize(totalSize)}`;
              this.installPhaseText = transferText;
            } else if (phase === 'install') {
              this.installPhaseText = '正在安装...';
            } else if (phase === 'clean') {
              this.installPhaseText = '正在清理临时文件...';
            }
          }
        );
        this.installPhaseText = '';
        if (!result.copyOk) {
          this.appendLog(`[install] 传输失败: ${result.installOutput}`);
          this.installResultOk = false;
          this.installResultText = `传输失败\n${result.installOutput}`;
        } else if (result.installOk) {
          this.appendLog(`[install] 安装成功: ${this.hapDisplayName}`);
          this.installResultOk = true;
          this.installResultText = '安装成功';
        } else {
          this.appendLog(`[install] 安装失败: ${result.installOutput}`);
          this.installResultOk = false;
          this.installResultText =
            `安装失败\n${result.installOutput.length > 0 ? result.installOutput : 'bm install 返回非零'}`;
        }
        if (result.copyOk && result.deleteOk) {
          this.appendLog(`[install] 删除成功: ${result.tmpName}`);
        } else if (result.copyOk && !result.deleteOk) {
          this.appendLog(`[install] 删除失败: ${result.tmpName}`);
          this.installResultText += `\n临时文件删除失败（${result.tmpName}）`;
        }
        this.toast(!result.copyOk ? '传输失败' : (result.installOk ? '安装成功' : '安装失败'));
      } finally {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          // 关闭失败不影响结果
        }
      }
    } catch (err) {
      const msg = (err as BusinessError).message ?? `${err}`;
      this.appendLog(`[install] 安装中断: ${msg}`);
      this.installPhaseText = '';
      this.installResultOk = false;
      this.installResultText = `安装中断: ${msg}`;
      this.toast('安装中断');
    } finally {
      this.installBusy = false;
    }
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

  /**
   * 提示只说「已发送」，**不说「已应用」**。
   *
   * 命令退出码正常不等于挡位真的切了，而这一点无法回读验证：设备上没有任何
   * shell 途径能读出当前电源挡位（见上面那行大字处的注释，列了探过的四个来源）。
   * 隔壁的息屏超时能说「已应用」，是因为它写完能再读一次 OverrideTimeout 核对；
   * 这里没有可核对的东西，就不许声称成功。
   */
  /**
   * 删除全部对话记录。作用与早先那个「清空」相同：把所有会话从磁盘上抹掉。
   *
   * 与「新会话」的区别：新会话只是再开一段，旧的还能翻回去；这个是真删。
   */
  private onDeleteAllSessions(): void {
    if (this.agentRunning) {
      this.toast('任务还在跑，先停止');
      return;
    }
    const total = this.agentSessionIds.length;
    if (total === 0) {
      this.toast('没有对话记录');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除全部对话记录',
      message: `删除后无法恢复。全部 ${total} 段会话将被清空。`,
      autoCancel: false,
      primaryButton: {
        value: '确认删除',
        fontColor: Color.Red,
        action: () => { this.doDeleteAllSessions(); }
      },
      secondaryButton: {
        value: '取消',
        action: () => {}
      }
    });
  }

  /**
   * 真正执行删除。**磁盘和内存必须一起清。**
   *
   * 只删文件的话，内存里还记着旧的会话 id，下一条消息会被追加进一个已经不存在的
   * 那一段，而后重新登记索引时又把它丢掉 —— 早先在设备上清盘时踩过这个坑：
   * 一个会话文件里同时出现了两轮测试的内容。
   */
  private doDeleteAllSessions(): void {
    const log: (line: string) => void = (line: string) => this.appendLog(line);
    clearAllSessions(this.getCtx() as common.UIAbilityContext, log);
    this.agentLoop = null;
    this.syncHistoryFlag();
    this.resetTimelineCounters();
    this.agentLiveTimeline = [];
    this.agentSessionIds = [];
    this.agentPageItems = [];
    this.agentPageTodo = [];
    this.agentViewIdx = 0;
    this.agentSwiperIdx = 0;
    this.agentPercent = 0;
    this.agentTodoSummary = '未制定计划';
    this.agentUsageText = '';
    this.toast('已删除全部对话记录');
  }

  private async onApplyPowerMode(): Promise<void> {
    const mode = this.clampPowerMode(this.pendingPowerMode);
    await this.runPowerCommand(`power-shell setmode ${mode}`, `已发送 setmode ${mode}`);
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
    }
    if (!updatePicker) {
      return;
    }
    // 滚轮要显示**当前生效**的那个值。存在一次性覆盖时，生效的是覆盖值而不是系统 Timeout。
    // 原先这里无论如何都用系统 Timeout 初始化，于是出现自相矛盾的画面：
    // 「恢复系统屏幕超时」按钮说明检测到了覆盖，滚轮却显示系统默认的 30 秒。
    let effective: number | null = state.timeoutMs;
    let source = '系统 Timeout';
    if (state.overrideMs !== null && state.overrideMs > 0) {
      effective = state.overrideMs;
      source = 'OverrideTimeout';
    }
    if (effective === null) {
      return;
    }
    this.setTimeoutFromMillis(effective);
    this.appendLog(`[power] 已用${source}初始化滚轮: ` +
      `${this.timeoutHours}h ${this.timeoutMinutes}m ${this.timeoutSeconds}s`);
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

  /**
   * 返回手势。顺序必须与叠放顺序相反：先关最上面那层。
   * 漏掉任何一层，返回就会落到系统默认行为直接退到桌面 —— AGENT 页曾经就是这样。
   * 关闭 AGENT 页只是收起界面，不停止任务：任务本来就该能在后台继续跑。
   */
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
    if (this.showAgentSettings) {
      this.closeAgentSettings();
      return true;
    }
    if (this.showAgentPage) {
      this.closeAgentPage();
      return true;
    }
    if (this.showInstallPage) {
      this.closeInstallPage();
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
      Text(label).fontSize($r('sys.float.ohos_id_text_size_body2')).width(72).fontColor($r('app.color.text_secondary'));
      TextInput({ text: value })
        .fontSize(INPUT_FONT_SIZE)
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
          .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
          .fontSize(INPUT_FONT_SIZE)
          .placeholderFont({ size: INPUT_FONT_SIZE })
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
            .fontSize($r('sys.float.ohos_id_text_size_caption1'))
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

  // 下面四行右端那个 `›` 的 22fp 是**故意写死的**，不是漏改。
  //
  // 全应用其他字号都挂在系统 token 上，但这个 `›` 不是文字，是拿字形当图标用的箭头 ——
  // 22 是按「压得住左边标题加副标题两行」的视觉重量挑的，它没有对应的文字角色，
  // 挂 body/sub_title 哪一档都是错配。系统文字档最大也只到 20fp（dialog_tittle），
  // 够不到 22。
  //
  // 唯一"正确"的挂法是换成系统图标（SymbolGlyph + ohos_id_arrow_height_width），
  // 但那会把箭头形状换成系统标准那个，四行的观感一起变。用户选择保持现状。
  @Builder
  featureList() {
    Column() {
      Row() {
        Column() {
          Text('终端')
            .fontSize($r('sys.float.ohos_id_text_size_sub_title2'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('使用交互式 shell')
            .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
          Text('安装 HAP')
            .fontSize($r('sys.float.ohos_id_text_size_sub_title2'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('选择 .hap 安装包，传输到所连设备并安装')
            .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
      .onClick(() => { this.openInstallPage(); });

      Row() {
        Column() {
          Text('清空应用数据')
            .fontSize($r('sys.float.ohos_id_text_size_sub_title2'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('多选应用，通过 bm 清除其数据')
            .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
            .fontSize($r('sys.float.ohos_id_text_size_sub_title2'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('熄屏、电源挡位与屏幕超时')
            .fontSize($r('sys.float.ohos_id_text_size_body3'))
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

      Row() {
        Column() {
          Text('AGENT 操控')
            .fontSize($r('sys.float.ohos_id_text_size_sub_title2'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text(this.agentRunning ?
            `正在执行 · 计划 ${this.agentTodoSummary}` :
            '说一句话，剩下的交给 AI')
            .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
      .onClick(() => { this.openAgentPage(); });
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  powerSection(title: string, subtitle: string) {
    Column() {
      Text(title)
        .fontSize($r('sys.float.ohos_id_text_size_sub_title2'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      Text(subtitle)
        .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
        .fontSize($r('sys.float.ohos_id_text_size_body3'))
        .fontWeight(this.pendingPowerMode === option.value ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.pendingPowerMode === option.value ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.text_secondary'));
      Text(option.title)
        .fontSize($r('sys.float.ohos_id_text_size_caption1'))
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
        .fontSize($r('sys.float.ohos_id_text_size_body2'))
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
        .fontSize($r('sys.float.ohos_id_text_size_body2'))
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
        .fontSize($r('sys.float.ohos_id_text_size_body2'))
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
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.closePowerPage(); });
        Text('电源控制')
          .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.text_primary'));
        Text('返回')
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .opacity(0);
      }
      .width('100%')
      .padding({ top: 4, bottom: 12 });

      Scroll() {
        Column() {
          Column() {
            this.powerSection('电源挡位', '滑动只选择挡位，点“应用挡位”后才会切换电源计划');
            // 必须带「将切换到」这个前缀。没有它的话，这行 20px 粗体读起来就是
            // 「当前挡位」，而系统真正的挡位**读不到**：探过 param get 里的
            // powersave/powermode 类属性、PowerManagerService 的 -a 全模块转储、
            // 以及 ThermalService / BatteryService / XpowerManager，全都没有该字段。
            // 这个值只是滑块上待应用的选择，默认停在 600，与系统实际状态无关。
            Text(`将切换到：${this.powerModeInfo(this.pendingPowerMode).title}（${this.pendingPowerMode}）`)
              .fontSize($r('sys.float.ohos_id_text_size_dialog_tittle'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ bottom: 12 });
            Text(`将执行：power-shell setmode ${this.pendingPowerMode}`)
              .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
              .fontSize($r('sys.float.ohos_id_text_size_body2'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .margin({ top: 14 });
            Text(`将执行：${this.timeoutCommandPreview()}`)
              .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
      // 圆角窗口：让滚动区域自己带一个 16 的圆角框，内容沿这个圆角被裁。
      // 卡片进出时看着像从一个圆角窗口里进出，永远不会露出直角。
      // 半径与卡片一致（都是 16），两者贴在一起时圆弧重合，不会显出两层边。
      //
      // 用 borderRadius + clip，而不是 clipContent(RectShape)：后者要显式给出
      // 裁切矩形的宽高，而那正是视口尺寸、得先量出来再回填；borderRadius 自动
      // 跟着组件尺寸走，少一套测量代码。
      //
      // 先前这里用的是 fadingEdge（边缘淡出），已按要求删掉 —— 圆角窗口已经把
      // 硬边解决了，再叠一层淡出会发灰。
      .borderRadius(16)
      .clip(true)
      .onWillScroll((_xOffset: number, _yOffset: number, _state: ScrollState, source: ScrollSource) => {
        this.markPowerPageScrolling(source);
      });
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16 })
    .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  terminalPage() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontColor(Color.White)
          .onClick(() => { this.closeTerminalPage(); });
        Text('终端')
          .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontColor(Color.White);
        Text(this.connected ? '已连接' : '未连接')
          .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
      .padding({ left: 16, right: 16, bottom: 4 });
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.terminal_background'))
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
  }

  /**
   * 一段会话一页。每页自己一个 Scroller，所以翻走再翻回来位置还在。
   *
   * 内层保持 `EdgeEffect.Spring`：下拉露出的那道空隙就是它给的，
   * 四句拉动提示写在那块空隙里。以前这个回弹会跟「换内容」抢位置（软弹），
   * 现在内容不换了，回弹只作用在自己这一页上，没有可抢的对手。
   *
   * **用 `List` 而不是 `Scroll`，为的是 `onScrollIndex` 和以后能上 `LazyForEach`。**
   *
   * 换容器最初的动机是 `stackFromEnd`，那一句后来又删掉了（理由写在下面属性列表那里）。
   * 但容器**没有跟着退回 `Scroll`**，因为 `List` 另外两样东西已经在承重：
   *
   * · `onScrollIndex(start, end)` —— 贴边标记靠它撤下。`Scroll` 没有"子项下标"这个概念，
   *   退回去只能改回按滚动偏移判，而那套写法已经因为内容不满一屏、以及布局未完成时
   *   偏移为负，判错过两种情形。下标是离散的，与坐标系和布局进度都无关。
   * · 历史页的条数**没有上限**（存档端也没有，见 `AgentSession.ts` 顶部说明），
   *   一段跑了几小时的任务翻回去可能上千条。`LazyForEach` 只支持 List / Grid / WaterFlow，
   *   退回 `Scroll` 等于把这条路堵死。现在用的还是 `ForEach`，但门留着。
   *
   * 另外 `scrollEdge` 在 `List` 上默认无动画（`Scroll` 默认带动画），所以不需要
   * `scrollTo(一个极大值)` 那个老绕法，新消息落底也不会播动画。
   *
   * 原先那两条来自 FAQ「Swiper嵌套Scroll组件滑动问题」的将就（内层 Column 不能设高度、
   * Scroll 要 `align(Alignment.Top)`）随 Scroll 一起去掉了：List 自己管排布。
   */
  @Builder
  timelinePage(idx: number) {
    List({ scroller: this.scrollerFor(idx) }) {
      if (this.itemsForPage(idx).length === 0) {
        ListItem() {
          Text('说一句要做什么，例如「打开备忘录，新建一条写上今天要买的东西」。')
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding(12);
        }
      }
      ForEach(this.itemsForPage(idx), (item: TimelineItem) => {
        ListItem() {
          this.timelineRow(item);
        }
        .width('100%');
      }, (item: TimelineItem) => `${item.id}`);
    }
    .width('100%')
    .height('100%')
    // 这里曾有 `.stackFromEnd(true)`。**已删除，不要加回来。**
    //
    // 官方契约是三件事捆在一起（`List` 参考手册原文）：
    //   ① 内容小于组件高度时，内容底部对齐；
    //   ② 显示区内有插入时，上方内容往上移动；
    //   ③ `initialIndex` 默认值变成「总数 − 1」。
    //
    // 我们只想要 ②③，而 ① 是不能单独关掉的：会话只有两三条消息时，它们贴在输入框上方、
    // 上面一大片空白，那是聊天软件的样子，用户明确不要。
    //
    // 退掉它的代价很小，因为 ②③ 我们自己的代码本来就在做：
    //   ② → `pushTimeline` 每追加一条就显式落底（正在看最新页时）；
    //   ③ → `openAgentPage` 进页面、`switchSession` 翻页时各开一段盯落点窗口，
    //        见 `agentStickUntil`。**翻页那一处漏掉过一次，症状是瀑布流断掉：
    //        每次往上翻都停在上一段的开头，而不是接着它的末尾。**
    // 换句话说，采纳这个官方能力时它顶替掉的工作，其实一直是我们自己在做的。
    //
    // 容器仍然是 `List` 而不是退回 `Scroll`，理由见上面 timelinePage 的注释。
    // 圆角窗口，与电源页同一套：内容沿 16 的圆角被裁，消息块进出边界时不会露出直角。
    // 半径与消息块自身的圆角一致，贴到边缘时圆弧重合。
    .borderRadius(16)
    .clip(true)
    /**
     * 视口高度变化时，把内容跟着挪同样的距离，**保持你正在看的那一块不被盖住**。
     *
     * 键盘避让用的是 RESIZE：键盘弹起时整页变矮，这个滚动视口也跟着变矮。视口矮了
     * 而滚动位置没动，底部那一截内容就被挤到可视区外面 —— 你把 observe 结果停在
     * 输入框旁边正要看，一点输入框，它就被输入框和键盘盖住了。
     *
     * 规则只有一条：视口矮了多少，内容就往下走多少（变高时反向）。
     * 这条规则天然覆盖「原本贴着底」的情形 —— 贴底时这个位移刚好等于新的底部。
     *
     * 早先我写的是「只在原本贴着底时才回到底部」。那是错的：它只照顾了
     * 「在看最新消息」这一种用法，而用户翻上去看历史时反而什么都不做、任凭内容被盖住。
     *
     * 初次布局不算（旧高度为 0），否则页面刚建起来时会被当成"视口变高"而把内容拽到顶。
     */
    .onAreaChange((oldValue: Area, newValue: Area) => {
      if (idx !== this.agentViewIdx) {
        return;
      }
      const was = Number.parseFloat(`${oldValue.height}`);
      const now = Number.parseFloat(`${newValue.height}`);
      if (Number.isNaN(was) || Number.isNaN(now) || was <= 0 || now <= 0) {
        return;
      }
      const delta = was - now;
      if (delta === 0) {
        return;
      }
      // 盯底窗口还开着的时候让位，不要插手。
      //
      // 理由是**避免两个写者操作同一个 Scroller**：那一页此刻正被 `stickIfWanted`
      // 反复贴到某一边（它挂在 onScrollIndex / onReachStart / onReachEnd 上），
      // 而贴边给出的结果在视口变化后本来就是对的（底就是底），不需要补偿再插一手。
      //
      // 清掉记下的原位是配套的：这一轮我们没挪过内容，收起时也就没有什么要还原。
      // 万一窗口在弹起与收起之间到期，收起那一下会因为查不到原位而直接返回，
      // 内容留在贴边处 —— 那正是想要的位置。
      //
      // **这个块当初是为了修「输入行上方一条内容闪一下」而加的，而那个诊断是错的。**
      // 真因是内容带动画、别的东西瞬间到位（详见 `followKeyboardScroll` 与
      // doc/agent-session-ui.md）。用户实测「盯底窗口开着时不闪、到期后才闪」，
      // 与"打架"的预测正好相反 —— 打架从来不是原因。
      // 留着它只因为上面那条卫生理由成立，别把它当成闪烁的解药。
      const stickOn = this.agentStickUntil !== 0 && idx === this.agentStickPage &&
        Date.now() < this.agentStickUntil;
      if (stickOn) {
        this.keyboardSavedY.delete(idx);
        this.keyboardShrunk.delete(idx);
        return;
      }
      const scroller = this.scrollerFor(idx);
      if (delta > 0) {
        // 视口变矮（键盘弹起）：把内容往下挪同样的距离，
        // 这样原本贴在输入行上方的那一块仍然贴在输入行上方。
        //
        // **AGENT 页现在用 OFFSET 避让，键盘那一大截位移不会走到这里。**
        // 整页由系统平移，列表高度不变。真正还会到这里的只有 8vp：
        // `keyboardUp` 翻转让输入行的下边距从 2vp 变成 10vp，而输入行和 Swiper 是
        // 同一个 Column 里的兄弟，它变高列表就变矮。实测日志：
        //
        //   area h=637.85->629.85 delta=8      ← OFFSET 下只剩这一条
        //   area h=637.85->322.77 delta=315.08 ← RESIZE 时代是这样
        //
        // 目标位置从**一个固定基准**算：原位 + 至今缩掉的总量。
        // 绝对不能写 `currentOffset() + delta` —— 多次触发时读到的可能是上一次
        // 滚动还没落定的中间值，于是新目标算错。这与当初那个「反复开合把内容
        // 一路扭到底」是同一个病根：拿正在变化的值当基准。
        // 现在虽然只剩 8vp，这条纪律仍然要守：别人把避让模式改回 RESIZE 时，
        // 这里要立刻还能算对。
        if (!this.keyboardSavedY.has(idx)) {
          this.keyboardSavedY.set(idx, scroller.currentOffset().yOffset);
          this.keyboardShrunk.set(idx, 0);
        }
        const base = this.keyboardSavedY.get(idx) ?? 0;
        const total = (this.keyboardShrunk.get(idx) ?? 0) + delta;
        this.keyboardShrunk.set(idx, total);
        // 位移量只信 `onAreaChange` 量出来的这些 delta 之和，不去读键盘高度：
        // 键盘多高与视口缩多少不是一回事（安全区、手势区都要分摊），
        // 而这里量到的就是列表真实少掉的那部分。
        this.followKeyboardScroll(scroller, base + total);
        return;
      }
      // 视口变高（键盘收起）：回到**记下的那个绝对位置**。
      //
      // 这里绝对不能写「再减一个 delta」。相对位移有两个致命毛病，我都踩过：
      // 一是与滚动组件自己的夹取叠加，变成往上冲一大截；
      // 二是补偿一旦不对称（只在变矮时补），开合一轮就净增一个 delta，
      //    反复开合能把内容从顶端一点一点「扭」到底端。
      // 用绝对位置恢复，这两个毛病在数学上都不可能出现。
      const saved = this.keyboardSavedY.get(idx);
      if (saved === undefined) {
        return;
      }
      this.keyboardSavedY.delete(idx);
      this.keyboardShrunk.delete(idx);
      this.followKeyboardScroll(scroller, saved);
    })
    // List 的 onWillScroll 是**三个**参数（主轴偏移、状态、来源）；Scroll 那个是四个
    // （xOffset、yOffset、状态、来源），换容器时按 List 的签名写。
    .onWillScroll((_offset: number, _state: ScrollState, source: ScrollSource) => {
      // 键盘弹着的时候用户自己滑过了，就不要再把他拽回原位 ——
      // 那个原位是「弹键盘之前」的，他已经不想回去了。
      if (source === ScrollSource.DRAG || source === ScrollSource.FLING ||
        source === ScrollSource.OTHER_USER_INPUT || source === ScrollSource.SCROLL_BAR ||
        source === ScrollSource.SCROLL_BAR_FLING) {
        this.keyboardSavedY.delete(idx);
        // 用户自己动手了就立刻停止盯落点，否则他一翻就被拽回去。
        // 只在**他动的正是被盯的那一页**时停：翻页动画里目标页也会收到非用户来源的滚动，
        // 而别的页被拖动跟这个窗口无关。
        if (idx === this.agentStickPage) {
          this.agentStickUntil = 0;
          this.agentStickPage = -1;
        }
      }
    })
    // 直接下标读，不包方法：框架要靠渲染时读到的属性建立元素级依赖。
    .opacity(this.agentPageOpacity[idx])
    // 属性动画只作用于**写在它之前**的那些属性。上面的宽高与对齐从不变化，
    // 所以这里实际只影响透明度。时长在拉动时是 0（跟手），收回时才有值。
    .animation({ duration: this.agentFadeAnimMs, curve: Curve.EaseOut })
    .edgeEffect(EdgeEffect.Spring)
    // 翻页动画期间，**只冻住正在滑走的那一页**的手指滚动。
    //
    // 为什么要冻：翻页手势与列表滚动是并行的（故意的，否则时间线滑不动），
    // 所以动画那 320 毫秒里第二下划的手指仍在滚手指底下那一页。旧页此刻正半透明地
    // 滑出去，被滚一下就成了"漏出上一个会话的部分动画"。
    //
    // 为什么只冻这一页：一开始我把两页一起冻了，结果是"等新会话过来时有几毫秒不跟手"——
    // 多冻的那一页正是进来的新页，而跟手要的恰恰是它跟着动。
    // 漏出来的是旧页在动，跟手要的是新页在动，两件事本来就分得开。
    //
    // 官方注明这个开关"不影响控制器 Scroller 的滚动接口"，所以 `snapToEdge` 摆位置照旧。
    // 用户在新页上自己滑一下会取消盯落点的窗口（见 onWillScroll），那是他自己的选择。
    .enableScrollInteraction(!(this.agentFlipping && idx === this.fadingOutIdx))
    // 贴不贴边由这三个回调共同维护，**不看滚动偏移**：
    //
    // · onReachStart / onReachEnd 负责置上。List 没有带「哪一侧」参数的 onScrollEdge，
    //   到边只能靠这两个分开的回调。官方对 onReachEnd 的说明正好覆盖我们要的场景：
    //   「当最后一个子组件因滚动**或内容/布局变化**出现在列表视窗中时触发」、
    //   「当子组件未撑满列表…首次加载也会触发」。
    // · onScrollIndex 负责撤下：可见的第一项不是 0 就不算贴顶，最后一项不是末项就不算贴底。
    //
    // 为什么不看偏移 —— 老写法 `agentAtTop = yOffset <= 2` 有两种情形会判错，
    // 而**两种都不是因为坐标轴反了**（实测 `onReachStart` y=0、`onReachEnd` y=2769，轴是正常的）：
    //
    // · 内容不满一屏时根本没有可滚的距离，偏移恒为 0 —— 于是"贴顶"永远为真，
    //   而此刻同时也贴着底，两个标记该同时成立，一个阈值判不出来。
    // · 内容还没布局完时偏移是负数（−350），`<= 2` 同样为真，而那一刻 `onReachEnd` 也在触发。
    //
    // 换成看下标就没有这些坑：下标是离散的、与坐标系和布局进度都无关。
    /**
     * **落点真正该发生的地方：这一页刚建好、还没首次布局的那一刻。**
     *
     * 官方在 `initialIndex` 的说明里写明了这条路：「从 API version 14 开始，如果在 List
     * 组件创建完成后首次布局前（如 List 的 onAttach 事件中），调用 Scroller 中不带动画的
     * scrollToIndex 或 scrollEdge 方法，会覆盖 initialIndex 设置的值」。
     * 我们的 `snapToEdge` 用的正是不带动画的 `scrollEdge`。
     *
     * 为什么非得在这里：翻页是「先滑，滑完再落点」的话，动画播的必然是一张**还没落好
     * 位置的页** —— 内容刚灌进去时布局要好几秒才完成，而滑动立刻就开始。慢慢翻时
     * 盯窗口来得及在下一次翻页前把它拽对，所以看不出来；翻快了就露出邻页的头或尾。
     * 在这里落点，动画开始时页面已经在正确位置，快慢都不露馅。
     *
     * 落在哪一边由 `switchSession` 先 arm 好（往更早的一段盯末尾，往更新的一段盯开头），
     * 所以这里只认「正在盯的就是我这一页」。
     */
    .onAttach(() => {
      if (idx === this.agentStickPage) {
        this.snapToEdge(idx, this.agentStickEdge);
      }
    })
    // 内容撑不满时官方保证首次加载也会触发这两个，那种情况下两边同时贴着。
    .onReachStart(() => {
      this.markEdge(idx, true, this.atBottomOf(idx));
      // 往下翻时盯的是**开头**，所以这一侧也要能触发重贴。
      this.stickIfWanted(idx);
    })
    .onReachEnd(() => {
      this.markEdge(idx, this.atTopOf(idx), true);
      this.stickIfWanted(idx);
    })
    .onScrollIndex((start: number, end: number) => {
      // 两个方向都**正向**算出来，不是只负责置 false。这样单靠这一个回调就能把状态
      // 完整刷新一遍，不必依赖前面两个恰好也触发过。
      const count = this.itemsForPage(idx).length;
      if (count === 0) {
        // 只有那句空态提示，没有可滚的东西，两边都算贴着。
        this.markEdge(idx, true, true);
      } else {
        this.markEdge(idx, start <= 0, end >= count - 1);
      }
      // 内容刚换好之后的一小段时间里，每次可见范围变化都把这一页重贴到该落的边。
      // 这是唯一能等到"内容真的布局出来"的办法：那一刻会有子项进出视区，
      // 于是这个回调必然触发，而内容刚灌进去那一刻列表还是空壳。见 `agentStickUntil`。
      this.stickIfWanted(idx);
    })
    // 与滚动并行：手势不能把滚动吞掉，否则时间线就滑不动了。
    .parallelGesture(
      PanGesture({ direction: PanDirection.Vertical, distance: AGENT_PULL_MIN_VP })
        // 这里原来有个 `.onActionStart(() => this.updateEdgeFlags())`，手势一起就现场重算
        // 贴边状态。现在不需要了：贴边由 onReachStart / onReachEnd / onScrollIndex
        // 持续维护，随时都是最新的。
        .onActionUpdate((event: GestureEvent) => { this.onTimelinePanUpdate(event); })
        .onActionEnd((event: GestureEvent) => { this.onTimelinePanEnd(event); })
        .onActionCancel(() => {
          this.agentPullHint = '';
          // 翻页跑着的时候别收淡：那批透明度正由逐帧回调管着，这一下会把它拽亮。
          if (!this.flipBusy()) {
            this.restoreDragFade();
          }
        })
    );
  }

  @Builder
  timelineRow(item: TimelineItem) {
    Column() {
      Text(this.timelinePrefix(item.kind))
        .fontSize($r('sys.float.ohos_id_text_size_caption1'))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.timelineColor(item.kind));
      Text(item.text)
        .fontSize(item.kind === 'thinking' ? 12 : 14)
        .fontColor(item.kind === 'thinking' ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
        .fontFamily(item.kind === 'tool_call' || item.kind === 'todo' ? 'monospace' : '')
        .width('100%')
        .margin({ top: 2 })
        .textAlign(TextAlign.Start);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .margin({ bottom: 6 })
    .borderRadius(10)
    .backgroundColor($r('app.color.log_background'));
  }

  @Builder
  agentPage() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.closeAgentPage(); });
        Column() {
          Text('AGENT 操控')
            .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'));
          // 段号常显：会话位置以前只在历史模式下才看得见，
          // 排查「新会话按钮为什么不出现」时完全看不到当前状态，只能靠猜。
          //
          // 必须锁死一行：这行字里三段内容在任务跑起来之后都会变长
          // （未制定计划→2/5、未保活→保活方式名），换行会把整个标题栏顶高，
          // 运行过程中不停抖。宁可省略号截断，也不让布局跳。
          Text(this.agentStatusLine())
            .fontSize($r('sys.float.ohos_id_text_size_caption1'))
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Center);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center);
        if (this.agentHasHistory() && !this.agentRunning && this.viewingLatest()) {
          Text('新会话')
            .fontSize($r('sys.float.ohos_id_text_size_button2'))
            .fontColor($r('app.color.text_secondary'))
            .margin({ right: 12 })
            .onClick(() => { this.onNewAgentSession(); });
        }
        Text('设置')
          .fontSize($r('sys.float.ohos_id_text_size_button2'))
          .fontColor($r('sys.color.ohos_id_color_emphasize'))
          .onClick(() => { this.openAgentSettings(); });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 18, bottom: 10 });

      if (this.agentRunning) {
        Progress({ value: this.agentPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .margin({ left: 16, right: 16, bottom: 6 });
      }

      if (this.agentUsageText.length > 0) {
        Text(this.agentUsageText)
          .fontSize($r('sys.float.ohos_id_text_size_caption1'))
          .fontFamily('monospace')
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 6 });
      }

      if (this.agentPauseReason.length > 0) {
        Row() {
          Text(this.agentPauseReason)
            .fontSize($r('sys.float.ohos_id_text_size_body2'))
            .fontColor('#FF9500')
            .layoutWeight(1);
          Button('继续')
            .fontSize($r('sys.float.ohos_id_text_size_button2'))
            .height(32)
            .onClick(() => { this.resolvePause(true); });
          Button('放弃')
            .fontSize($r('sys.float.ohos_id_text_size_button2'))
            .height(32)
            .backgroundColor('#FF3B30')
            .margin({ left: 8 })
            .onClick(() => { this.resolvePause(false); });
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 6 });
      }

      // 提示叠在滚动区之上：下拉时内容整体下移露出空隙，提示正好落在那块空隙里。
      Stack({ alignContent: this.agentPullHintAtTop ? Alignment.Top : Alignment.Bottom }) {
        // 一段会话一页。翻段不再换内容，而是让组件把页翻过去 ——
        // 旧段留在自己那页把回弹弹完，新段是另一个节点，两个动画抢不到同一个位置。
        Swiper(this.agentSwiper) {
          ForEach(this.agentSessionIds, (_id: string, idx: number) => {
            this.timelinePage(idx);
          }, (id: string) => id);
          // 一段会话都还没有时也要有一页，否则 Swiper 是空的、什么都不显示。
          if (this.agentSessionIds.length === 0) {
            this.timelinePage(0);
          }
        }
        .width('100%')
        .height('100%')
        .vertical(true)
        .loop(false)
        .indicator(false)
        // 关掉组件自带的跟手滑动：翻不翻页由我的 70vp 判定，
        // 否则「松手查看上一段」这句提示会与组件自己的判定不一致。
        .disableSwipe(true)
        // 双向绑定，绑的是**专门给组件用的那个索引**（`agentSwiperIdx`），
        // 不是判断用的 `agentViewIdx`。两者拆开的理由写在 `agentSwiperIdx` 那里：
        // 绑定的这个在动画期间是旧值，拿它做判断已经出过三个 bug。
        // 单向写法会让「赋值」本身变成一次无动画的瞬跳，所以这里必须是 `$$`。
        .index($$this.agentSwiperIdx)
        // 换成非弹簧曲线，duration 才有效（弹簧曲线的时长由自身参数决定）。
        .curve(Curve.EaseInOut)
        .duration(AGENT_FLIP_DURATION_MS)
        // 跟着翻页走的淡：旧段边滑走边变淡，新段边滑进来边变清楚。
        // 它与翻页共用同一段时间，不额外增加等待 —— 这是它和之前那五版的根本区别，
        // 那几版的淡是独立的一段时长，加在翻页前后，所以是「延迟太高」。
        .customContentTransition({
          // 页面滑出视窗后延后一段再下渲染树。设太小会在还看得见的时候被摘掉，出现突跳。
          timeout: AGENT_FADE_HOLD_MS,
          transition: (proxy: SwiperContentTransitionProxy) => {
            this.agentFadeAnimMs = 0;
            // 被翻走的那一页：手指已经把它拉到最暗了，整段动画里就保持最暗。
            // 不这么做的话，它的 position 从 0 开始，算出来是「不透明」，
            // 于是松手瞬间先亮一下再淡走 —— 比不做淡更难看。
            if (proxy.index === this.fadingOutIdx) {
              this.agentPageOpacity[proxy.index] = 1 - AGENT_FADE_OUT_DEPTH;
              return;
            }
            // 进来的那一页：position 是它离静止位置的距离，单位是「一页」。
            // 从 1 走到 0。弹簧过冲时会超过 1，所以要夹住。
            let away = proxy.position < 0 ? -proxy.position : proxy.position;
            if (away > 1) {
              away = 1;
            }
            // 浮现只用前半程走完，不摊在整段路程上，否则起步那段几乎看不出在变亮。
            let shown = (1 - away) / AGENT_FADE_IN_SPAN;
            if (shown > 1) {
              shown = 1;
            }
            this.agentPageOpacity[proxy.index] = 1 - AGENT_FADE_IN_DEPTH * (1 - shown);
          }
        })
        .onAnimationEnd(() => {
          // 翻完了：**把每一页都恢复成全亮**，不只是翻走那一页。
          //
          // 静止状态下每一页本来都该是全亮的，所以这是把状态推回一个已知的干净值，
          // 而不是"多恢复了几页"。只恢复 `fadingOutIdx` 会漏掉进来那一页：
          // 它的亮度是逐帧回调按动画进度算的，而最后一帧未必正好落在位置 0 上，
          // 差一点就永久停在偏暗的值上，翻几次攒下来就是一片灰。
          this.agentFadeAnimMs = 0;
          for (let i = 0; i < this.agentPageOpacity.length; i++) {
            if (this.agentPageOpacity[i] !== 1.0) {
              this.agentPageOpacity[i] = 1.0;
            }
          }
          this.fadingOutIdx = -1;
          // 提前解封，并把列表的滚动手势放回来。
          // 这只是快路径，`agentFlipUntil` 到点也会自己失效。
          this.agentFlipUntil = 0;
          this.agentFlipping = false;
        });

        if (this.agentPullHint.length > 0) {
          Text(this.agentPullHint)
            .fontSize($r('sys.float.ohos_id_text_size_body3'))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .hitTestBehavior(HitTestMode.Transparent);
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16 })
      // 翻页过程中相邻页会露到这块区域外，不裁掉会溢到上下的横幅与输入行上面。
      .clip(true);

      // 这里曾有一行橙色横幅「第 x/y 段历史会话 · 只能看」。**不要加回来。**
      //
      // 它只在浏览历史时存在，于是翻进／翻出历史段会让上面那块时间线区域
      // 高度一涨一缩约 30px。而「落到底部」是在高度变化**之前**算的
      // （段号在翻页动画结束时才更新，横幅也才出现），偏移量因此过时：
      //   · 翻到历史段后，最后一行被挤到可视区下面，看着像被下面的东西遮住了
      //   · 再翻走时，那截溢出的内容正好落进可视区顶部，缓缓露一下再消失，
      //     像凭空冒出一条提示
      // 位置和「只能看」现在都在标题下那行常显状态里，两种模式高度完全一致。

      if (this.viewingLatest()) {
        Row() {
          // 用 `TextArea` 而不是 `TextInput`：任务描述经常是一整句话，
          // 单行框里只能看见最后十几个字，改完前半句就看不见了。
          //
          // 一行起步，长到约四行就封顶，再多在框内自己滚。
          //
          // **封顶用 `constraintSize`，不能用 `maxLines`。** 两者机制不同：
          // `maxLines` 是"限制显示行数、超出截断"，`TextArea` 自己的内部滚动是
          // "内容超过组件高度"才触发。我先写的是
          // `maxLines(4, { overflowMode: MaxLinesMode.SCROLL })`，@since 20 的文档
          // 写着"behavior can be displayed as the scrolling capability"，但真机上
          // 界面树里那个节点是 `scrollable: "false"` —— 高度确实限在 4 行了，
          // 滚动能力压根没打开，9 行内容里后 5 行既看不见也滑不到。
          TextArea({
            placeholder: this.agentInputHint(),
            text: $$this.agentTaskInput
          })
            .enabled(!this.agentRunning)
            .layoutWeight(1)
            .fontSize(INPUT_FONT_SIZE)
            .placeholderFont({ size: INPUT_FONT_SIZE })
            .minLines(1)
            .constraintSize({
              minHeight: this.agentInputMinHeightVp,
              maxHeight: this.agentInputMaxHeightVp
            });
          if (this.agentRunning) {
            Button('停止')
              .fontSize($r('sys.float.ohos_id_text_size_button2'))
              .height(40)
              .backgroundColor('#FF3B30')
              .margin({ left: 8 })
              .onClick(() => { this.onStopAgent(); });
          } else {
            Button(this.agentHasHistory() ? '发送' : '开始')
              .fontSize($r('sys.float.ohos_id_text_size_button2'))
              .height(40)
              .margin({ left: 8 })
              .onClick(() => { this.onSendAgent(); });
          }
        }
        .width('100%')
        // 输入框会随内容长高，按钮必须钉在底边，否则它会跟着一起往上飘、
        // 停在多行文本的正中间。
        .alignItems(VerticalAlign.Bottom)
        // 下边距分两档。键盘收起时压到 2vp：这一行下面还有约 95px 系统手势区，
        // 那块地板动不了（试过让根容器扩进去，反而把每页底部撑出更大的空白）。
        // 键盘弹起时手势区被键盘盖住，2vp 就变成输入框直接贴在键盘上，所以要留出余地。
        .padding({
          left: 16,
          right: 16,
          top: 8,
          bottom: this.keyboardUp ? AGENT_INPUT_GAP_ON_KEYBOARD_VP : 2
        });
      } else {
        // 历史会话里不摆一个禁用的输入框：那句「历史会话只能看，回到最新才能说话」
        // 在输入框里放不下，会被切成「…才能」，观感很差。换成一个整宽按钮，
        // 既把话说全又直接可点。高度与内边距沿用输入行原值，所以翻页不会跳版。
        Row() {
          Button('回到最新以继续对话')
            .fontSize($r('sys.float.ohos_id_text_size_button2'))
            .height(40)
            .width('100%')
            .onClick(() => { this.jumpToLatest(); });
        }
        .width('100%')
        // 下边距分两档。键盘收起时压到 2vp：这一行下面还有约 95px 系统手势区，
        // 那块地板动不了（试过让根容器扩进去，反而把每页底部撑出更大的空白）。
        // 键盘弹起时手势区被键盘盖住，2vp 就变成输入框直接贴在键盘上，所以要留出余地。
        .padding({
          left: 16,
          right: 16,
          top: 8,
          bottom: this.keyboardUp ? AGENT_INPUT_GAP_ON_KEYBOARD_VP : 2
        });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
  }

  @Builder
  settingField(label: string, hint: string) {
    Column() {
      Text(label)
        .fontSize($r('sys.float.ohos_id_text_size_body2'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      if (hint.length > 0) {
        Text(hint)
          .fontSize($r('sys.float.ohos_id_text_size_caption1'))
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 2 });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 14, bottom: 4 });
  }

  @Builder
  agentSettingsPage() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.closeAgentSettings(); });
        Text('模型设置')
          .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.text_primary'));
        // 不再是「保存」按钮。改动自动落盘，这里只是把这件事说出来 ——
        // 有人改完直接按返回，以为没保存，或者压根没注意到右上角有个按钮。
        Text(this.cfgSaving ? '保存中' : '自动保存')
          .fontSize($r('sys.float.ohos_id_text_size_body2'))
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 18, bottom: 10 });

      Scroll() {
        Column() {
          // 只给一个例子，任何屏宽都是一行。原先列了两个地址，窄屏上会折成两行。
          // 「例如」两个字不能省：只有一个地址时更容易被读成「只支持这一家」。
          this.settingField('接口地址', '例如 https://api.anthropic.com/');
          TextInput({ placeholder: 'https://api.anthropic.com/', text: $$this.cfgEndpoint })
            .fontSize(INPUT_FONT_SIZE)
            .placeholderFont({ size: INPUT_FONT_SIZE })
            .width('100%')
            .onChange(() => { this.scheduleAgentConfigSave(); });

          this.settingField('API key', '明文存在应用沙箱里，只有本应用能读');
          TextInput({ placeholder: 'sk-…', text: $$this.cfgApiKey })
            .type(InputType.Password)
            .fontSize(INPUT_FONT_SIZE)
            .placeholderFont({ size: INPUT_FONT_SIZE })
            .width('100%')
            .onChange(() => { this.scheduleAgentConfigSave(); });

          this.settingField('模型 ID', '手填，区分大小写。例如 claude-opus-5、kimi-k3');
          TextInput({ placeholder: 'claude-opus-5', text: $$this.cfgModel })
            .fontSize(INPUT_FONT_SIZE)
            .placeholderFont({ size: INPUT_FONT_SIZE })
            .width('100%')
            .onChange(() => { this.scheduleAgentConfigSave(); });

          this.settingField('单次回复上限', '一次回答的长度上限，默认 32768');
          TextInput({ placeholder: '32768', text: $$this.cfgMaxTokens })
            .type(InputType.Number)
            .fontSize(INPUT_FONT_SIZE)
            .placeholderFont({ size: INPUT_FONT_SIZE })
            .width('100%')
            .onChange(() => { this.scheduleAgentConfigSave(); });

          this.settingField('压缩阈值', '超过时执行上下文压缩，留空默认 128000，填 0 禁用压缩');
          TextInput({ placeholder: '128000', text: $$this.cfgContextLimit })
            .type(InputType.Number)
            .fontSize(INPUT_FONT_SIZE)
            .placeholderFont({ size: INPUT_FONT_SIZE })
            .width('100%')
            .onChange(() => { this.scheduleAgentConfigSave(); });

          this.settingField('截图保留数', '历史里留最近几张截图，更早的换成一行文字。留空默认 5，填 0 全部保留');
          TextInput({ placeholder: '5', text: $$this.cfgKeepScreenshots })
            .type(InputType.Number)
            .fontSize(INPUT_FONT_SIZE)
            .placeholderFont({ size: INPUT_FONT_SIZE })
            .width('100%')
            .onChange(() => { this.scheduleAgentConfigSave(); });

          this.settingField('禁止进入的应用', '一行一个包名，留空表示不限制');
          TextArea({ placeholder: 'com.example.app', text: $$this.cfgBlacklist })
            .fontSize(INPUT_FONT_SIZE)
            .placeholderFont({ size: INPUT_FONT_SIZE })
            .height(90)
            .width('100%')
            .onChange(() => { this.scheduleAgentConfigSave(); });

          // 这里曾有一个「认证头」三选项（both / x-api-key / bearer）。**已删除。**
          // 现在两个认证头一律都发：多发一个请求头是安全的，服务端认哪个读哪个。
          // 实测所有端点用 both 都能过，别的同类工具也不问这个 ——
          // 留着只是让人对着一个永远不用改的开关发愁。

          Row() {
            // 只留标题占住这一格，不写说明。开关的作用一句话说不清，
            // 而说不清的话不如不说：不支持的端点会自己忽略它，用户不需要做判断。
            //
            // 没有说明文字，这一格本来会比上面那些「标题 + 说明」的两行格子矮一截、
            // 看着像漏了东西。所以整格给足高度，字号交给自适应：
            // 在 13~20 之间按可用空间自己放大，把这一格填满。
            Text('提示词缓存')
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .height('100%')
              .maxLines(1)
              // 上限 15，不是 20。20 能填满这一格，但比别处的标题（13）大了一半，
              // 在一列 13 号标题里显得突兀 —— 填满格子不值得牺牲整页字号的一致。
              .minFontSize(13)
              .maxFontSize(15)
              .heightAdaptivePolicy(TextHeightAdaptivePolicy.MAX_LINES_FIRST);
            Toggle({ type: ToggleType.Switch, isOn: $$this.cfgPromptCache })
              .onChange(() => { this.scheduleAgentConfigSave(); });
          }
          .width('100%')
          .height(AGENT_SETTING_ROW_HEIGHT_VP)
          .margin({ top: 18 });

          // 这里曾有一整段解释「为什么没有推理强度设置」的小字。**已删除。**
          // 用户不需要知道我们为什么没做某件事 —— 界面上不存在的东西不必解释。
          // 理由留在 AnthropicClient 的请求体注释与 doc/anthropic-api.md 里。

          this.settingField('对话记录', '删除后无法恢复');
          Button('删除全部对话记录')
            .fontSize($r('sys.float.ohos_id_text_size_button2'))
            .height(40)
            .width('100%')
            .backgroundColor('#FF3B30')
            .margin({ bottom: 24 })
            .onClick(() => { this.onDeleteAllSessions(); });
        }
        .width('100%');
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      // 上下边缘虚化。这一页是长表单、内容在边界处被直直切断很难看。
      //
      // 它曾被删过一次：当时电源页选了「圆角窗口」并要求删掉淡出，我把两处一起清了。
      // 电源页那边圆角窗口已经把硬边化开，再叠淡出会发灰，所以那边不要；
      // 这一页没有圆角窗口，虚化是这里唯一的边缘处理，必须留着。
      .fadingEdge(true)
      .padding({ left: 16, right: 16 });
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
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
          .fontSize($r('sys.float.ohos_id_text_size_body2'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary'));
        Text(item.name)
          .fontSize($r('sys.float.ohos_id_text_size_caption1'))
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
          .fontSize($r('sys.float.ohos_id_text_size_caption1'))
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
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.closeClearPage(); });
        Text('清空应用数据')
          .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.text_primary'));
        // 右侧占位，保持标题居中
        Text('返回')
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .opacity(0);
      }
      .width('100%')
      .padding({ top: 4, bottom: 12 });

      // 筛选与刷新
      Row() {
        Text('包含系统应用')
          .fontSize($r('sys.float.ohos_id_text_size_body2'))
          .fontColor($r('app.color.text_primary'));
        Toggle({ type: ToggleType.Switch, isOn: this.includeSystem })
          .enabled(!this.toolsBusy)
          .onChange((isOn: boolean) => { this.includeSystem = isOn; });
        Blank();
        Button('刷新')
          .fontSize($r('sys.float.ohos_id_text_size_button2'))
          .enabled(this.connected && !this.toolsBusy)
          .onClick(() => { this.onRefreshBundles(); });
      }
      .width('100%')
      .margin({ bottom: 6 });

      Row() {
        Text(this.toolsStatus)
          .fontSize($r('sys.float.ohos_id_text_size_body3'))
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`已选 ${this.selectedCount()}`)
          .fontSize($r('sys.float.ohos_id_text_size_body3'))
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .margin({ bottom: 6 });

      Row() {
        Button('全选')
          .fontSize($r('sys.float.ohos_id_text_size_button2'))
          .layoutWeight(1)
          .type(ButtonType.Normal)
          .borderRadius(8)
          .backgroundColor($r('app.color.log_background'))
          .fontColor($r('app.color.text_primary'))
          .enabled(!this.toolsBusy)
          .onClick(() => { this.setAllChecked(true); });
        Button('全不选')
          .fontSize($r('sys.float.ohos_id_text_size_button2'))
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
    .padding({ left: 16, right: 16, top: 16 })
    .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  installHapPage() {
    Column() {
      // 顶部栏（与清空应用数据页同款）
      Row() {
        Text('‹ 返回')
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => { this.closeInstallPage(); });
        Text('安装 HAP')
          .fontSize($r('sys.float.ohos_id_text_size_sub_title1'))
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.text_primary'));
        // 右侧占位，保持标题居中
        Text('返回')
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .opacity(0);
      }
      .width('100%')
      .padding({ top: 4, bottom: 12 });

      Scroll() {
        Column() {
          Text('选择本机的 .hap 安装包。应用会把它传输到所连设备并安装，完成后自动清理临时文件。')
            .fontSize($r('sys.float.ohos_id_text_size_body3'))
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          Button(this.hapUri.length === 0 ? '选择 HAP 文件' : '重新选择')
            .width('100%')
            .margin({ top: 12 })
            .type(ButtonType.Normal)
            .borderRadius(8)
            .backgroundColor($r('app.color.log_background'))
            .fontColor($r('app.color.text_primary'))
            .enabled(!this.installBusy)
            .onClick(() => { this.pickHapFile(); });

          if (this.hapUri.length > 0) {
            Column() {
              Text(this.hapDisplayName)
                .fontSize($r('sys.float.ohos_id_text_size_body1'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              if (this.hapSizeText.length > 0) {
                Text(this.hapSizeText)
                  .fontSize($r('sys.float.ohos_id_text_size_body3'))
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ top: 2 });
              }
              if (this.hapRealPath.length > 0) {
                Text(this.hapRealPath)
                  .fontSize($r('sys.float.ohos_id_text_size_caption1'))
                  .fontFamily('monospace')
                  .fontColor($r('app.color.text_secondary'))
                  .margin({ top: 2 })
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(12)
            .borderRadius(12)
            .backgroundColor($r('app.color.log_background'))
            .margin({ top: 10 });
          }

          Button(this.installBusy ? '安装中...' : '开始安装')
            .width('100%')
            .margin({ top: 12 })
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .enabled(this.hapUri.length > 0 && this.connected && !this.installBusy)
            .onClick(() => { this.onInstallHapClick(); });

          if (!this.connected) {
            Text('设备未连接：请先返回主页连接设备')
              .fontSize($r('sys.float.ohos_id_text_size_body3'))
              .fontColor(Color.Red)
              .width('100%')
              .margin({ top: 6 });
          }

          if (this.installPhaseText.length > 0) {
            Row() {
              LoadingProgress()
                .width(18)
                .height(18)
                .color($r('app.color.text_secondary'));
              Text(this.installPhaseText)
                .fontSize($r('sys.float.ohos_id_text_size_body3'))
                .fontColor($r('app.color.text_secondary'))
                .margin({ left: 8 });
            }
            .width('100%')
            .margin({ top: 12 });
          }

          if (this.installResultText.length > 0) {
            Text(this.installResultText)
              .fontSize($r('sys.float.ohos_id_text_size_body2'))
              .fontColor(Color.White)
              .width('100%')
              .padding(12)
              .borderRadius(12)
              .margin({ top: 12 })
              .textAlign(TextAlign.Start)
              .backgroundColor(this.installResultOk ? '#34C759' : '#E8404A');
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .align(Alignment.TopStart);
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16 })
    .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  mainPage() {
    Column() {
      // 这个 22fp 也是故意写死的：系统文字档最大到 20fp（dialog_tittle），够不到 22。
      // 挂 20 会让主标题缩一号、与页面顶栏标题（18fp）拉不开差距，主页的层级感变弱。
      // 用户选择保持现在的大小。
      Text('HDC Toolbox')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: 4 });
      Text(`${this.status} · ${this.keyState}`)
        .fontSize($r('sys.float.ohos_id_text_size_body3'))
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
    .padding({ left: 16, right: 16, top: 16 });
  }

  build() {
    Stack() {
      this.mainPage();
      if (this.showInstallPage) {
        this.installHapPage();
      }
      if (this.showTerminalPage) {
        this.terminalPage();
      }
      if (this.showClearPage) {
        this.clearDataPage();
      }
      if (this.showPowerPage) {
        this.powerPage();
      }
      if (this.showAgentPage) {
        this.agentPage();
      }
      if (this.showAgentSettings) {
        this.agentSettingsPage();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'));
  }
}
