/**
 * 界面观测：把 `uitest dumpLayout -i` 的原始布局树压成模型可直接使用的元素清单。
 *
 * 实测依据（HarmonyOS 6.1.1，Mate 60 Pro，1260x2720）：
 * - `-i` 的输出顶层是**窗口数组**，不是单一根节点；默认（merge）模式才是单对象。
 * - 隐藏页面挂在 `visible=false` 且 bounds 为零面积的容器下，但其**子孙各自仍标着
 *   `visible=true` 且带真实坐标**。因此可见性必须沿树继承，只查节点自身会把隐藏页
 *   的列表项当成可点目标（实测踩过：QQ 会话列表与备忘录列表都会变成幻影）。
 * - 对话框是窗口根节点的直接子节点，与 `Navigation` 平级，**不在 NavDestination 子树内**。
 *   所以不能只取最顶层 NavDestination，否则模型看不见"是否删除此备忘？"这类弹窗。
 * - 无文字的图标按钮靠 `id`/`key` 才有语义（`saveNote`、`sendBtn`、`ptt`）；
 *   但也存在雪花 ID（`7672384215283158462_...`），需过滤。
 * - 一次 dump 约 1 秒，瞬态 UI（toast）观测不到，不能依赖。
 */


/** 布局树里我们用得到的属性；`uitest` 实际会输出约 30 个，其余忽略。 */
interface NodeAttributes {
  accessibilityId?: string;
  abilityName?: string;
  bounds?: string;
  bundleName?: string;
  clickable?: string;
  description?: string;
  enabled?: string;
  /** 窗口是否持有焦点。只在窗口根节点上有意义，用来认出"哪个窗口真在屏幕上"。 */
  focused?: string;
  hint?: string;
  id?: string;
  key?: string;
  longClickable?: string;
  scrollable?: string;
  text?: string;
  type?: string;
  visible?: string;
}

interface LayoutNode {
  attributes: NodeAttributes;
  children: LayoutNode[];
}

export interface Rect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/** 一个可被模型引用的界面元素。`index` 是模型唯一需要说出的东西。 */
export interface ObservedElement {
  index: number;
  label: string;
  accessibilityId: string;
  nodeId: string;
  text: string;
  type: string;
  centerX: number;
  centerY: number;
  bounds: Rect;
  clickable: boolean;
  scrollable: boolean;
  editable: boolean;
  /** false 表示控件存在但被置灰。仍然上报，否则模型会误判"没有这个按钮"而去乱找。 */
  enabled: boolean;
  inModal: boolean;
}

export interface Observation {
  screenWidth: number;
  screenHeight: number;
  foregroundBundle: string;
  foregroundAbility: string;
  keyboardVisible: boolean;
  locked: boolean;
  modalPresent: boolean;
  elements: ObservedElement[];
}

/** 观测所需的运行时信息，全部由调用方在运行时探测，不在此处硬编码。 */
export interface ObserveContext {
  /** 本应用包名，从清单读取；用于把自己从可操作目标中剔除。 */
  ownBundle: string;
  /** 当前输入法包名，由 `ime -g` 探测；用于判断键盘是否弹起。 */
  imeBundle: string;
  /** 布局转储的落盘路径。 */
  dumpPath: string;
  /** 是否对文本做敏感信息打码。 */
  maskSensitiveText: boolean;
}

const MODAL_TYPES: string[] = ['Dialog', 'CustomDialog', 'SheetPage', 'Menu', 'Popup', 'ActionSheet'];
const EDITABLE_TYPES: string[] = ['TextInput', 'TextArea', 'Search', 'SearchField', 'RichEditor'];
const LOCK_ID_HINTS: string[] = ['ScreenLock', 'sl_lock', 'ScreenLockRootComponent'];

const BOUNDS_PATTERN: RegExp = /^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$/;
const INHERITED_LABEL_MAX: number = 40;

/**
 * ArkTS 的 interface 不能按字符串下标取值，所以逐个属性写取值函数，
 * 而不是用一个按名字分派的 switch。
 */
function attrs(node: LayoutNode): NodeAttributes {
  const a = node.attributes;
  return a !== undefined && a !== null ? a : {};
}

function aAccessibilityId(n: LayoutNode): string {
  return attrs(n).accessibilityId ?? '';
}

function aAbilityName(n: LayoutNode): string {
  return attrs(n).abilityName ?? '';
}

function aBounds(n: LayoutNode): string {
  return attrs(n).bounds ?? '';
}

function aBundleName(n: LayoutNode): string {
  return attrs(n).bundleName ?? '';
}

function aFocused(n: LayoutNode): boolean {
  return attrs(n).focused === 'true';
}

function aClickable(n: LayoutNode): boolean {
  return attrs(n).clickable === 'true';
}

function aScrollable(n: LayoutNode): boolean {
  return attrs(n).scrollable === 'true';
}

function aEnabled(n: LayoutNode): boolean {
  return attrs(n).enabled !== 'false';
}

function aVisible(n: LayoutNode): boolean {
  return attrs(n).visible !== 'false';
}

function aText(n: LayoutNode): string {
  return (attrs(n).text ?? '').trim();
}

function aType(n: LayoutNode): string {
  return attrs(n).type ?? '';
}

function aDescription(n: LayoutNode): string {
  return (attrs(n).description ?? '').trim();
}

function aHint(n: LayoutNode): string {
  return (attrs(n).hint ?? '').trim();
}

/** id 与 key 在实测中总是同值；取其一即可。 */
function aNodeId(n: LayoutNode): string {
  const id = attrs(n).id ?? '';
  return id.length > 0 ? id : (attrs(n).key ?? '');
}

function parseRect(value: string): Rect | null {
  const m = BOUNDS_PATTERN.exec(value);
  if (m === null) {
    return null;
  }
  return {
    left: Number.parseInt(m[1], 10),
    top: Number.parseInt(m[2], 10),
    right: Number.parseInt(m[3], 10),
    bottom: Number.parseInt(m[4], 10)
  };
}

function intersect(a: Rect, b: Rect): Rect | null {
  const left = Math.max(a.left, b.left);
  const top = Math.max(a.top, b.top);
  const right = Math.min(a.right, b.right);
  const bottom = Math.min(a.bottom, b.bottom);
  if (right <= left || bottom <= top) {
    return null;
  }
  return { left, top, right, bottom };
}

function contains(list: string[], value: string): boolean {
  for (const item of list) {
    if (item === value) {
      return true;
    }
  }
  return false;
}

function includesAny(value: string, needles: string[]): boolean {
  for (const needle of needles) {
    if (value.indexOf(needle) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 雪花 ID（如 `7672384215283158462_7672384215283158463`）对模型毫无意义，
 * 只保留读起来像名字的 id。
 */
function usableId(value: string): string {
  if (value.length === 0 || value.length > 40) {
    return '';
  }
  if (!/[A-Za-z]/.test(value)) {
    return '';
  }
  if (/^\d+(_\d+)*$/.test(value)) {
    return '';
  }
  if (/\d{12,}/.test(value)) {
    return '';
  }
  return value;
}

/** 手机号、身份证、银行卡打码。顺序固定：身份证优先于银行卡，避免 18 位被当成卡号。 */
export function maskSensitive(text: string): string {
  let out = text;
  out = out.replace(/\d{6}(\d{8})(\d{3})([\dXx])/g, (match: string): string => {
    return match.substring(0, 6) + '********' + match.substring(match.length - 4);
  });
  out = out.replace(/\d{12,15}(\d{4})/g, (match: string): string => {
    return '****' + match.substring(match.length - 4);
  });
  out = out.replace(/1[3-9]\d{9}/g, (match: string): string => {
    return match.substring(0, 3) + '****' + match.substring(7);
  });
  return out;
}

/** 收集节点子树内所有可见文本，用于给无文字的可点容器补标签。 */
function descendantTexts(node: LayoutNode, limit: number): string[] {
  const acc: string[] = [];
  const visit = (n: LayoutNode): void => {
    if (acc.length >= limit) {
      return;
    }
    if (!aVisible(n)) {
      return;
    }
    const t = aText(n);
    if (t.length > 0) {
      acc.push(t);
    }
    const kids = n.children ?? [];
    for (const kid of kids) {
      visit(kid);
    }
  };
  visit(node);
  return acc;
}

/**
 * 标签优先级：text → 后代文本上提 → description → hint → id/key。都没有则丢弃。
 * 上提的文本会被截断：容器的后代文本往往是整段正文，原样拼接会把同一句话重复三遍。
 * 节点自己的 text 不截断，那是真正的内容。
 *
 * `description` 原来排在后代文本**之前**，那是错的。厂商把读屏用的手势说明写在这个
 * 字段里，于是备忘录列表页每条便签的外层 Stack 都拿到同一句
 * 「单指双击即可执行 双击并按住即可弹出更多选项。双击并按住左滑可进行更多操作。」——
 * 5 条便签 5 份，一字不差，各占一个编号，模型无从区分。转储证实那些 Stack 正是便签行
 * （Row）的直接父节点，所以让后代文本先说话之后，它们会被 skipBorrowedContainer 丢掉。
 * 真机转储离线对照：35 个元素降到 30，丢的正好是那 5 条，没有别的变化。
 */
function buildLabel(node: LayoutNode): string {
  const own = aText(node);
  if (own.length > 0) {
    return own;
  }
  const inherited = descendantTexts(node, 3);
  if (inherited.length > 0) {
    // 内部另有可点元素时，绝不偷它们的文字当标签。
    //
    // 偷来的标签会让容器冒充自己的第一个子项：备忘录列表页那个横跨全列表的滚动容器，
    // 标签变成「Todo 刚刚 做升学宴视频」，与第一条便签一字不差。模型据此选中容器，
    // 而点击落在容器中心（(531+2719)/2 = 1625 像素），那里是列表正中间的
    // 「红点涂复方炉甘石」—— 位置固定，所以每次都点进同一条错误便签。
    //
    // 可滚动容器不能像可点容器那样直接丢掉（scroll 需要它作目标），
    // 所以这里给一个中性名字：留住它的可滚动身份，去掉它的冒充能力。
    // 中性名字还要带上控件类型。真机上一屏出现过两个都叫「（可滚动区域）」的元素
    // （编号 1 和 6），模型无法区分，只能猜。类型在采集时本来就拿到了，不额外花钱，
    // 而 List / Scroll / Column 对模型是有意义的区分：哪个是列表、哪个是外层。
    if (hasClickableDescendant(node)) {
      const base = aScrollable(node) ? '可滚动区域' : '容器';
      const kind = aType(node);
      return kind.length > 0 ? `（${base}·${kind}）` : `（${base}）`;
    }
    const joined = inherited.join(' ');
    return joined.length > INHERITED_LABEL_MAX ? `${joined.substring(0, INHERITED_LABEL_MAX)}…` : joined;
  }
  // 自己没文字、子树里也没文字，才轮到这两个字段。无文字图标按钮靠它们才有语义。
  const desc = aDescription(node);
  if (desc.length > 0) {
    return desc;
  }
  const hint = aHint(node);
  if (hint.length > 0) {
    return `(${hint})`;
  }
  const id = usableId(aNodeId(node));
  if (id.length > 0) {
    return `#${id}`;
  }
  return '';
}

/**
 * 标签是不是靠"上提后代文本"来的。只有自己带文字才不算。
 *
 * 这个判断必须跟 buildLabel 的优先级一致。原来它把"有 description 或 hint"也算成
 * 自己有标签 —— 那是 description 还排在后代文本之前时的对应写法。降序之后没同步改，
 * 结果那 5 个手势说明容器仍然不算"偷标签"、仍然不被丢，只是标签从手势说明变成 5 个
 * 一样的「（容器·Stack）」。两处必须一起改，改一处等于没改。
 */
function labelIsBorrowed(node: LayoutNode): boolean {
  if (aText(node).length > 0) {
    return false;
  }
  return descendantTexts(node, 1).length > 0;
}

/** 子树里（不含自己）有没有可见且可点的节点。 */
function hasClickableDescendant(node: LayoutNode): boolean {
  let found = false;
  const visit = (n: LayoutNode): void => {
    if (found || !aVisible(n)) {
      return;
    }
    if (aClickable(n)) {
      found = true;
      return;
    }
    const kids = n.children ?? [];
    for (const kid of kids) {
      visit(kid);
    }
  };
  const kids = node.children ?? [];
  for (const kid of kids) {
    visit(kid);
  }
  return found;
}

/**
 * 该不该跳过这个"可点容器"。
 *
 * 由来是一个真机故障：备忘录列表页有一个 `Column b=[0,531][1260,2719] click=true`，
 * 横跨整个列表、自己没有文字也没有 id。它的标签只能靠上提后代文本，而深度优先
 * 第一个碰到的就是第一条便签，于是标签变成「Todo 昨天 做升学宴视频」——
 * 与第一条便签那一行**一字不差**。模型看到编号更小的那个，理所当然以为是第一条便签，
 * 而点击落在元素中心（(531+2719)/2 = 1625 像素），那里正是列表正中间的
 * 「红点涂复方炉甘石」。位置固定，所以每次都点进同一条错误便签。
 *
 * 判据：可点、标签是偷来的、而且内部已经有可点的东西。这三条同时成立时，
 * 它的可点性完全被子项覆盖，标签又是冒充子项的，报给模型只会造成误选。
 * 可滚动的容器不在此列 —— 那是 scroll 的目标，必须留。
 */
function skipBorrowedContainer(node: LayoutNode, clickable: boolean, scrollable: boolean): boolean {
  if (!clickable || scrollable) {
    return false;
  }
  return labelIsBorrowed(node) && hasClickableDescendant(node);
}

function detectLocked(windows: LayoutNode[]): boolean {
  let found = false;
  const visit = (n: LayoutNode): void => {
    if (found) {
      return;
    }
    if (includesAny(aNodeId(n), LOCK_ID_HINTS)) {
      found = true;
      return;
    }
    const kids = n.children ?? [];
    for (const kid of kids) {
      visit(kid);
    }
  };
  for (const w of windows) {
    visit(w);
  }
  return found;
}

interface Collected {
  normal: ObservedElement[];
  modal: ObservedElement[];
}

/**
 * 递归收集可操作与带文字的节点。
 * - 可见性沿树继承：祖先 `visible=false` 或零面积则整棵子树丢弃。
 * - bounds 被祖先裁剪：滚出可视区的节点不可点，一并丢弃。
 */
function collect(
  node: LayoutNode,
  clip: Rect,
  inModal: boolean,
  screenW: number,
  screenH: number,
  seen: Set<string>,
  out: Collected,
  mask: boolean
): void {
  if (!aVisible(node)) {
    return;
  }
  const raw = parseRect(aBounds(node));
  if (raw === null) {
    return;
  }
  if (raw.right - raw.left <= 0 || raw.bottom - raw.top <= 0) {
    return;
  }
  const box = intersect(raw, clip);
  if (box === null) {
    return;
  }
  const centerX = Math.floor((box.left + box.right) / 2);
  const centerY = Math.floor((box.top + box.bottom) / 2);
  if (centerX < 0 || centerY < 0 || centerX > screenW || centerY > screenH) {
    return;
  }

  const type = aType(node);
  const modalHere = inModal || contains(MODAL_TYPES, type);
  const clickable = aClickable(node);
  const scrollable = aScrollable(node);
  const editable = contains(EDITABLE_TYPES, type);
  const enabled = aEnabled(node);
  const ownText = aText(node);
  // 置灰控件既不可点也没有文字，但仍要上报，否则模型会以为按钮不存在。
  const disabledControl = !enabled && usableId(aNodeId(node)).length > 0;

  const borrowed = skipBorrowedContainer(node, clickable, scrollable);
  if (!borrowed && (clickable || scrollable || editable || ownText.length > 0 || disabledControl)) {
    const rawLabel = buildLabel(node);
    if (rawLabel.length > 0) {
      // 同标签且中心点相近（16px 网格）视为同一个东西，只保留一条。
      const dedupe = `${rawLabel}|${centerX >> 4},${centerY >> 4}`;
      if (!seen.has(dedupe)) {
        seen.add(dedupe);
        const element: ObservedElement = {
          index: 0,
          label: mask ? maskSensitive(rawLabel) : rawLabel,
          accessibilityId: aAccessibilityId(node),
          nodeId: aNodeId(node),
          text: mask ? maskSensitive(ownText) : ownText,
          type,
          centerX,
          centerY,
          bounds: box,
          clickable,
          scrollable,
          editable,
          enabled,
          inModal: modalHere
        };
        if (modalHere) {
          out.modal.push(element);
        } else {
          out.normal.push(element);
        }
      }
    }
  }

  const kids = node.children ?? [];
  for (const kid of kids) {
    collect(kid, box, modalHere, screenW, screenH, seen, out, mask);
  }
}

/** 把原始布局树 JSON 转成观测结果。导出以便用离线转储做验证。 */
export function buildObservation(rawJson: string, ctx: ObserveContext): Observation {
  let windows: LayoutNode[];
  try {
    windows = JSON.parse(rawJson) as LayoutNode[];
  } catch (err) {
    throw new Error(`解析布局树失败: ${(err as Error).message}`);
  }
  if (windows.length === 0) {
    throw new Error('布局树为空，设备可能未就绪');
  }

  const rootRect = parseRect(aBounds(windows[0]));
  const screenW = rootRect !== null ? rootRect.right : 0;
  const screenH = rootRect !== null ? rootRect.bottom : 0;

  const locked = detectLocked(windows);

  // 哪个窗口才是"屏幕"，必须看 focused，不能看它在数组里排第几。
  //
  // dumpLayout -i 返回的是所有窗口，包括后台的、以及桌面自己那一堆（壁纸、状态栏、
  // 手势条、锁屏）。数组顺序不代表层级：真机上出现过状态栏排在最前面的一次，
  // 结果 agent 拿到的"屏幕"是那个高 188 像素的状态栏窗口，元素清单只有时钟、
  // 网速、电量和灵动胶囊，而它以为那就是整个界面，于是在一块不存在的界面上乱点。
  //
  // 窗口根节点上有 focused 属性，实测与 hidumper 的 `Focus window: <WinId>` 一致
  // （dump 里的 hostWindowId 就是那个 WinId）。所以答案本来就在手里。
  //
  // 哪个窗口是"屏幕"：**面积最大的那个**；面积相同时才由 focused 决定。
  //
  // 这个顺序是三次真机故障换来的，每一版错法都记在这里，免得有人再走回去。
  //
  // 错法一：取数组里第一个。数组顺序不代表层级，状态栏（高一两百像素的独立窗口）
  // 排到最前面时，agent 拿到的"屏幕"只有时钟、网速、电量和灵动胶囊，
  // 它以为那就是整个界面，于是在一块不存在的界面上乱点。
  //
  // 错法二：没有窗口 focused 就报错。**本应用自己经常就是持有焦点的那个** ——
  // 用户点发送时人正看着这个 app，而候选里必须排除本应用（绝不能操作自己）。
  // 于是"没有别的窗口持有焦点"是常态而非异常，实测两次任务的每一个工具调用全灭。
  //
  // 错法三：优先选 focused，没有才比面积。应用退出的瞬间**状态栏自己会持有焦点**，
  // 于是错法一那个幻觉界面照样重演一次。focused 只能说明"谁在收按键"，
  // 不能说明"谁是那块内容"。
  //
  // 所以以面积为主：状态栏在任何全屏窗口面前永远输。桌面和真正的应用都是全屏、
  // 面积相等，这时候 focused 恰好是对的裁判。全程没有任何阈值，只有两个数比大小。
  //
  // 锁屏例外：锁屏时本来就不提供屏幕内容，选中谁都无所谓。
  // 本应用**不再**被排除在这场比较之外。
  //
  // 以前排除它，于是 foregroundBundle 在结构上永远不可能等于本应用 —— 用户把 agent
  // 页面切到前台时，观测报的是它背后那个应用，看起来"目标还在最上面"，
  // 于是"目标页面被切走"这个判据对最常见的一种切走完全失灵。藏起自己就是对判据撒谎。
  //
  // 安全性来自另一处：本应用的窗口只在它真的显示时才出现在 dump 里（实测备忘录在
  // 前台时，dump 里只有备忘录和状态栏两个窗口，没有本应用）。所以把它放进比较
  // 不会误判，而一旦它赢了，下面就不采集任何元素 —— 本应用的界面绝不能成为可点目标。
  let keyboardVisible = false;
  let appWindow: LayoutNode | null = null;
  let bestArea = -1;
  for (const w of windows) {
    const bundle = aBundleName(w);
    if (bundle.length === 0) {
      continue;
    }
    if (ctx.imeBundle.length > 0 && bundle === ctx.imeBundle) {
      keyboardVisible = true;
      continue;
    }
    const rect = parseRect(aBounds(w));
    const area = rect !== null ? (rect.right - rect.left) * (rect.bottom - rect.top) : 0;
    if (appWindow === null || area > bestArea) {
      appWindow = w;
      bestArea = area;
      continue;
    }
    // 面积打平：持有焦点的那个胜出。桌面与前台应用都是全屏，靠这一条区分。
    if (area === bestArea && aFocused(w) && !aFocused(appWindow)) {
      appWindow = w;
    }
  }
  if (appWindow === null) {
    appWindow = windows[0];
  }
  const ownOnTop = aBundleName(appWindow) === ctx.ownBundle;

  const collected: Collected = { normal: [], modal: [] };
  if (!locked && !ownOnTop) {
    const screenRect: Rect = { left: 0, top: 0, right: screenW, bottom: screenH };
    collect(appWindow, screenRect, false, screenW, screenH, new Set<string>(), collected, ctx.maskSensitiveText);
  }

  // 弹窗内容排在前面：它遮挡了下层，是模型唯一能操作的东西。
  const elements: ObservedElement[] = [];
  let index = 1;
  for (const e of collected.modal) {
    e.index = index;
    index += 1;
    elements.push(e);
  }
  for (const e of collected.normal) {
    e.index = index;
    index += 1;
    elements.push(e);
  }

  return {
    screenWidth: screenW,
    screenHeight: screenH,
    foregroundBundle: aBundleName(appWindow),
    foregroundAbility: aAbilityName(appWindow),
    keyboardVisible,
    locked,
    modalPresent: collected.modal.length > 0,
    elements
  };
}

/**
 * 抓取一次界面。`uitest` 对重定向安全，先静音其提示再读文件。
 *
 * 第一个参数收的是**执行命令的函数**而不是连接对象：这条命令属于 agent 的动作，
 * 必须能在用户按停止时被立刻掐掉，而那个能力在 `DeviceControl.run()` 里。
 * 这里只用连接发这一条命令，所以换成函数没有别的代价。
 */
export async function observe(
  run: (command: string, timeoutMs: number) => Promise<string>,
  ctx: ObserveContext,
  timeoutMs: number = 20000
): Promise<Observation> {
  const command = `uitest dumpLayout -i -p ${ctx.dumpPath} >/dev/null 2>&1; cat ${ctx.dumpPath}`;
  const raw = await run(command, timeoutMs);
  return buildObservation(raw.trim(), ctx);
}

function describeFlags(e: ObservedElement): string {
  if (!e.enabled) {
    return '不可用';
  }
  const flags: string[] = [];
  if (e.clickable) {
    flags.push('可点');
  }
  if (e.scrollable) {
    flags.push('可滚动');
  }
  if (e.editable) {
    flags.push('可输入');
  }
  return flags.length > 0 ? flags.join(' ') : '文本';
}

/**
 * 标签里的换行压成一个符号。
 *
 * 元素清单是"一行一个元素"的格式，而节点自己的 text 不截断也不加工（那是真正的内容），
 * 于是多行文本会把一行撑成好几行：真机上出现过
 * `11 可点 可输入 做升学宴视频⏎买去北京的用品套装`，第二行看上去像一个没有编号的条目。
 *
 * 只在渲染时替换。`label` 原值必须保留 —— resolveElement 靠它在新一次观测里
 * 按文字找回同一个元素，改了就对不上。
 */
export function flatLabel(label: string): string {
  return label.replace(/\s*\r?\n\s*/g, '⏎');
}

/**
 * 元素在画面上的纵向位置，接在清单行尾。只有 `click` 用得到。
 *
 * 由来是一次真机故障：模型要点富文本里第二行待办的勾选框，那个勾选框画在控件内部、
 * 不在界面树里，只能靠 `click` 报画面比例。它给了 0.426，真实位置是 0.257 ——
 * 落在正文下方的空白里，把光标放到末尾、弹出粘贴菜单，白费三个回合。
 *
 * 横向它从来没错过（六次全在 0.103~0.104），因为屏幕左边缘就是 0，是现成的参照。
 * 纵向没有任何参照，只能凭感觉估。所以只给纵向，不给横向。
 *
 * 只给上下边，**不给中心**：那次出事的正文块中心恰好是 0.407，而它给的是 0.426 ——
 * 给中心有可能反而强化这个错误。有用的是上边（正文从 0.213 开始）。
 *
 * 也不给元素自己的范围当唯一参照：正文块是 0.213~0.600，0.426 正在里面，拦不住。
 * 真正起作用的是**紧邻目标那几个元素**（「今天 12:01」在 0.175~0.194），模型在图上
 * 看得见目标就贴在它下面，于是不会给出 0.426。所以每一行都给，不做挑选。
 */
function verticalSpan(e: ObservedElement, screenHeight: number): string {
  if (screenHeight <= 0) {
    return '';
  }
  const top = (e.bounds.top / screenHeight).toFixed(3);
  const bottom = (e.bounds.bottom / screenHeight).toFixed(3);
  // 不加记号。曾经带一个 ↕ 前缀，用户嫌怪，而它并不必要：这两个数在行末，
  // 描述里指的就是"每行最后那两个数"。
  return ` ${top}~${bottom}`;
}

/** 渲染成发给模型的文本。锁屏时不输出任何屏幕内容。 */
export function renderObservation(obs: Observation): string {
  const lines: string[] = [];
  lines.push(`屏幕 ${obs.screenWidth}x${obs.screenHeight}`);
  if (obs.locked) {
    lines.push('设备已锁屏。当前无法执行任何操作，也不提供屏幕内容。');
    return lines.join('\n');
  }
  lines.push(`前台应用 ${obs.foregroundBundle}${obs.foregroundAbility.length > 0 ? ' / ' + obs.foregroundAbility : ''}`);
  lines.push(`键盘 ${obs.keyboardVisible ? '已弹起' : '已收起'}`);
  if (obs.elements.length === 0) {
    lines.push('未找到可操作元素。');
    return lines.join('\n');
  }
  let modalHeaderWritten = false;
  let normalHeaderWritten = false;
  for (const e of obs.elements) {
    if (e.inModal && !modalHeaderWritten) {
      lines.push('【弹窗】遮挡下层界面，只能先处理这里');
      modalHeaderWritten = true;
    }
    if (!e.inModal && !normalHeaderWritten) {
      lines.push(obs.modalPresent ? '【被遮挡的界面】' : '【界面】');
      normalHeaderWritten = true;
    }
    lines.push(`${e.index} ${describeFlags(e)} ${flatLabel(e.label)}${verticalSpan(e, obs.screenHeight)}`);
  }
  return lines.join('\n');
}

/**
 * 在新一次观测里重新定位旧元素。三级回退：accessibilityId → id/key → 标签文本。
 * 每个动作执行前都要重新定位，`uitest` 的成功返回码不可信，位置也可能已经变了。
 */
export function resolveElement(target: ObservedElement, fresh: Observation): ObservedElement | null {
  if (target.accessibilityId.length > 0) {
    for (const e of fresh.elements) {
      if (e.accessibilityId === target.accessibilityId) {
        return e;
      }
    }
  }
  if (target.nodeId.length > 0) {
    for (const e of fresh.elements) {
      if (e.nodeId === target.nodeId) {
        return e;
      }
    }
  }
  if (target.label.length > 0) {
    for (const e of fresh.elements) {
      if (e.label === target.label) {
        return e;
      }
    }
  }
  return null;
}

export function findByIndex(obs: Observation, index: number): ObservedElement | null {
  for (const e of obs.elements) {
    if (e.index === index) {
      return e;
    }
  }
  return null;
}

/**
 * 界面树没变时那唯一的一句话。
 *
 * 只能说明界面树没变，不能推断动作失败。画布墨迹、视频画面、游戏内容都在单个节点
 * 内部，永远不进界面树 —— 早先这句话断言「可能未生效」，曾让模型把画成功的手写笔
 * 误判成接口不支持而放弃。
 *
 * 那次事故是保留后半句的理由：这段文字进的是历史段，每次无变化动作都新增一份，
 * 系统提示里也已经把原因、判据、和「只能用 screenshot 确认」全写过一遍。但系统提示
 * 离得远，而模型是当场读到「没有变化」当场下判断的，所以那一句挡在误判前面的话
 * 必须留在原地。留最短的一句，枚举和补救手段交给系统提示。
 */
export const NO_CHANGE_TEXT: string = '界面树没有变化（不代表动作没生效）。';

/**
 * 动作做完回给模型的正文：界面变了就给**整张带编号的新表**，没变就只说一句。
 *
 * 为什么不再回"哪些标签新出现、哪些消失"（那是原来的做法，已删）：
 *
 * 模型每一步都要报元素编号，而编号是我们这边现编的、每个动作后都重排一次。原来的
 * 差异文本只有标签、**一个编号都没有** —— 于是模型下一步必须报号时只能自己编。
 * 真机实测：一次任务里它在没有表的时候报了 2 个号，2 个全错（把搜索框图标当成便签、
 * 把编辑器遮罩当成正文），有表的时候报了 3 个号，3 个全对。差别不在它聪明不聪明，
 * 只在手里到底有没有那张表。
 *
 * 换成整张表之后，"哪里变了"由模型自己比对前后两条结果得出。原来那些状态行
 * （前台变了 / 键盘弹起 / 出现弹窗 / 进入锁屏）一并删掉，因为这四样在表里本来就都
 * 写着 —— 它们当初存在只是因为没有表。现在模型要么得知没变，要么拿到整张表，
 * 不存在第三种形状。
 */
export function reportAfterAction(before: Observation, after: Observation): string {
  const rendered = renderObservation(after);
  // 比的是渲染后的文本而不是标签集合：顺序变了、键盘变了、弹窗来了都会让文本不同，
  // 而那些情况下编号或前提已经变了，必须重新发表。按标签集合比会漏掉"集合相同、
  // 顺序变了"这一种，那一种恰恰是编号错位最危险的情形。
  return rendered === renderObservation(before) ? NO_CHANGE_TEXT : rendered;
}

/** 两次观测是否已经稳定，用于动作后的轮询判定。 */
export function sameObservation(a: Observation, b: Observation): boolean {
  if (a.locked !== b.locked || a.keyboardVisible !== b.keyboardVisible) {
    return false;
  }
  if (a.foregroundBundle !== b.foregroundBundle || a.foregroundAbility !== b.foregroundAbility) {
    return false;
  }
  if (a.elements.length !== b.elements.length) {
    return false;
  }
  for (let i = 0; i < a.elements.length; i += 1) {
    const x = a.elements[i];
    const y = b.elements[i];
    if (x.label !== y.label || x.centerX !== y.centerX || x.centerY !== y.centerY) {
      return false;
    }
  }
  return true;
}
