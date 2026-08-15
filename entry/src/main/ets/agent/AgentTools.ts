/*
 * tool 定义与系统提示。
 *
 * 两条贯穿全文的原则：
 * 1. 模型只用元素编号，**从不接触坐标**。坐标由应用在执行前重新解析界面得到。
 * 2. 面向模型的文案全部中文。
 *
 * 这些定义会被打上 prompt cache 断点（最后一个 tool 上），所以描述写详细一些是划算的：
 * 只有第一次请求为它付费。
 */

import type { ApiTool } from './AnthropicClient';
import { MAX_DRAW_SEGMENTS, supportedKeyNames, WAIT_MAX_MS } from './DeviceControl';

export const TOOL_TODO_WRITE: string = 'todo_write';
export const TOOL_OBSERVE: string = 'observe';
export const TOOL_SCREENSHOT: string = 'screenshot';
export const TOOL_TAP: string = 'tap';
/**
 * 点画面上的某个位置。与 tap 的分工：tap 认元素编号，click 认画面比例坐标。
 *
 * 存在的理由：有些东西画在控件内部，根本不是界面树里的节点，编号点不到。
 * 真机实测过一例 —— 备忘录待办清单的复选框：那个 RichEditor 节点的唯一子节点
 * RichEditorContent 有零个子节点，两行文字连同两个圆圈全在一个叶子里，
 * 而节点的 text 属性只有文字、不含勾选状态。用坐标注入点击能勾上（已验证），
 * 用编号则无从下手。
 *
 * 坐标为什么是"相对画面"而不是"相对元素"：见 DeviceControl.clickInside 的说明 ——
 * 元素高度会随键盘变化 55%，那把尺子在这个交互里本身就不稳定。
 */
export const TOOL_CLICK: string = 'click';
export const TOOL_LONG_PRESS: string = 'long_press';
export const TOOL_DOUBLE_TAP: string = 'double_tap';
export const TOOL_SCROLL: string = 'scroll';
export const TOOL_DRAG: string = 'drag';
export const TOOL_DRAW: string = 'draw';
export const TOOL_INPUT_TEXT: string = 'input_text';
export const TOOL_KEY: string = 'key';
export const TOOL_LAUNCH_APP: string = 'launch_app';
export const TOOL_LIST_APPS: string = 'list_apps';
export const TOOL_WAIT: string = 'wait';
export const TOOL_DONE: string = 'done';

/** 会改变屏幕状态的 tool。首轮没写计划时这些一律拒绝执行。 */
const ACTION_TOOLS: string[] = [
  TOOL_TAP, TOOL_LONG_PRESS, TOOL_DOUBLE_TAP, TOOL_SCROLL,
  TOOL_DRAG, TOOL_DRAW, TOOL_INPUT_TEXT, TOOL_KEY, TOOL_LAUNCH_APP,
  TOOL_CLICK
];

export function isActionTool(name: string): boolean {
  return ACTION_TOOLS.indexOf(name) >= 0;
}

function emptySchema(): Object {
  return { type: 'object', properties: {} as Object };
}

function indexSchema(what: string): Object {
  return {
    type: 'object',
    properties: {
      index: { type: 'integer', description: `要${what}的元素编号，取自最近一次界面观测。` }
    } as Object,
    required: ['index']
  };
}

/**
 * 生成全部 tool 定义。
 *
 * `includeScreenshot` 为 false 时不给出 screenshot —— 用于端点不支持图片内容块的情况
 * （已知 DeepSeek 的 Anthropic 兼容端点把 `type: "image"` 标为 Not Supported）。
 * 与其让模型调用后撞 400，不如根本不告诉它有这个能力。
 */
export function buildTools(includeScreenshot: boolean): ApiTool[] {
  const tools: ApiTool[] = [];

  tools.push({
    name: TOOL_TODO_WRITE,
    description:
      '提交或更新你的执行计划。开始任何操作之前必须先调用一次。\n' +
      '每次调用都要传【完整的】计划列表，它会整体覆盖上一份，所以增加、删除、重排、' +
      '改写状态都在这一个调用里完成。\n' +
      '完成一步就把那一项改成 done。计划可以随时改：发现原计划不对就重写它，' +
      '这是被鼓励的，不是失败。\n' +
      '注意：勾选比例会显示为通知栏的进度环，所以计划的粒度决定进度好不好看。' +
      '建议 3 到 8 项，每项是用户能看懂的一件事，不要写成"点第 5 个按钮"这种机械步骤。\n' +
      '任务结束时计划里不应再有未完成项。',
    input_schema: {
      type: 'object',
      properties: {
        items: {
          type: 'array',
          description: '完整的计划列表，按执行顺序排列。',
          items: {
            type: 'object',
            properties: {
              text: { type: 'string', description: '这一步要做什么，一句话。' },
              status: {
                type: 'string',
                enum: ['pending', 'active', 'done'],
                description: 'pending 待办、active 正在做、done 已完成。缺省为 pending。'
              }
            } as Object,
            required: ['text']
          }
        }
      } as Object,
      required: ['items']
    }
  });

  tools.push({
    name: TOOL_OBSERVE,
    description:
      '读取当前屏幕，返回可交互元素的编号清单。\n' +
      // 这里原先写的是「不需要也无法使用坐标」。那是断言，而 click 恰恰要坐标 ——
      // 模型每一轮都同时读到"你无法使用坐标"和"用比例坐标点"，两条互相否定。
      '每个元素形如「编号 可点 可输入 标签」。你之后的操作都用这些编号来指定目标。' +
      '唯一用到坐标的是 click，它要的是画面上的比例，不是像素。\n' +
      // 标记名必须和 Observer.describeFlags 的输出逐字一致。原来这里写「可滚」而输出是
      // 「可滚动」，而且从没提过「文本」这个标记。
      '标记含义：可点=能点击，可滚动=能滚动，可输入=是输入框，' +
      '文本=只是文字、点不动，不可用=控件存在但当前是灰的。\n' +
      // 括号是 Observer.buildLabel 给 hint 加的。实测模型把 (华为智能眼镜 2) 当成框里
      // 已有的内容，先按了 20 次退格去清空 —— 而那一轮它手里就有搜索页的截图，
      // 图上那行字是灰的，它照样读错了。
      '标签包在圆括号里的，是这个空框的占位提示，不是框里的内容 —— 那个框是空的。\n' +
      '每行末尾那两个数是这个元素在画面上的纵向位置，写成 上边~下边，' +
      '0 是画面顶边、1 是底边。只有 click 用得到。\n' +
      '出现【弹窗】时它会排在最前面并遮挡下层界面，必须先处理弹窗，' +
      '点被遮挡的元素不会有反应。\n' +
      // 原先这句是「所以通常不需要主动再调 observe」。那时动作结果里只有标签、没有编号，
      // 于是这句话把模型推向"手里没有编号却必须报编号"，只能自己编。现在动作结果直接
      // 带回新清单，这句话才成立。
      '每次动作之后，界面变了系统会把新的编号清单直接回给你，编号可以立刻用；' +
      '界面没变会明确告诉你没变，你手上这份清单继续有效。' +
      '所以通常不需要主动再调 observe。',
    input_schema: emptySchema()
  });

  if (includeScreenshot) {
    tools.push({
      name: TOOL_SCREENSHOT,
      description:
        '截取当前屏幕画面。\n' +
        '默认你只能看到元素清单，看不到画面。只在清单不足以判断时才截图，' +
        '例如需要辨认图片内容、颜色、验证码，或者清单里的标签含义含混。\n' +
        '截图很贵（一张原生分辨率的图相当于几千个 token），不要每步都截。',
      input_schema: emptySchema()
    });
    // 与 screenshot 同一个开关：这个动作要先看图才能算出坐标，点完也要靠图确认。
    // 端点不支持图片时留着它只会让模型瞎点。
    tools.push({
      name: TOOL_CLICK,
      description:
        // 三个参数都是必填，描述里不能把 index 说成"附属的、只用来核对的"——
        // 那样写过一版，实测模型两次都在第一次调用里漏掉它。
        '点击画面上的某个位置。用来点画在控件里面、不在清单上、没有编号的东西。\n' +
        'x、y、index 三个都必填。\n' +
        'x、y 是相对整块画面的比例，0~1：0,0 是画面左上角，1,1 是右下角。' +
        '和你在截图上看到的位置一一对应。先 screenshot，直接从图上量。\n' +
        // 实测纵向估偏过一次：0.426 对 0.257，落进正文下方的空白，白费三个回合。
        // 清单里每行末尾那两个数就是现成的纵向标尺，这一句只是指出它能这么用。
        '清单里每行末尾那两个数是那个元素在画面上的纵向位置，' +
        '看图找出目标紧挨着哪个元素，拿它的数去对齐 y。\n' +
        '坐标必须落在 index 那个元素里，否则不会点出去。\n' +
        '点完会附一张新截图。',
      input_schema: {
        type: 'object',
        properties: {
          index: { type: 'integer', description: '那个位置属于哪个元素，编号取自最近一次界面观测。' },
          x: { type: 'number', description: '画面横向比例，0~1，0 是画面左边缘。' },
          y: { type: 'number', description: '画面纵向比例，0~1，0 是画面上边缘。' }
        } as Object,
        required: ['index', 'x', 'y']
      }
    });
  }

  tools.push({
    name: TOOL_TAP,
    description: '点击一个元素。最常用的动作。',
    input_schema: indexSchema('点击')
  });

  tools.push({
    name: TOOL_LONG_PRESS,
    description: '长按一个元素，通常用来呼出上下文菜单（例如长按列表项出现删除、置顶等选项）。',
    input_schema: indexSchema('长按')
  });

  tools.push({
    name: TOOL_DOUBLE_TAP,
    description: '双击一个元素。用得很少，多数界面里双击和单击效果相同。',
    input_schema: indexSchema('双击')
  });

  tools.push({
    name: TOOL_SCROLL,
    description:
      '在一个可滚动元素内滚动。\n' +
      'direction 指的是【内容移动的方向】：想看下面的内容用 down。\n' +
      '滚出可视区的元素是点不到的，所以要点的东西不在清单里时，先滚动再看。',
    input_schema: {
      type: 'object',
      properties: {
        index: { type: 'integer', description: '要滚动的元素编号，应当带有「可滚动」标记。' },
        direction: {
          type: 'string',
          enum: ['up', 'down', 'left', 'right'],
          description: '内容移动的方向。'
        },
        // 滑多远由速度决定：实测手指位移固定 200px 时，velocity 800 → 内容走 328px、
        // 2000 → 614px、8000 → 超过一屏。所以 amount 只调速度，不改手势位移。
        // 不写"一段等于多少"是因为那取决于应用自己的惯性，我们量不出一个通用值。
        amount: {
          type: 'integer',
          description: '滚动力度，越大滚得越远。1 大约三分之一屏，缺省 1。要翻很远就填大一点。'
        }
      } as Object,
      required: ['index', 'direction']
    }
  });

  tools.push({
    name: TOOL_DRAG,
    description:
      '把一个元素拖到另一个元素的位置上，用于排序、拖拽移动这类交互。' +
      '两个编号都取自同一次观测。',
    input_schema: {
      type: 'object',
      properties: {
        from_index: { type: 'integer', description: '被拖动的元素编号。' },
        to_index: { type: 'integer', description: '拖到哪个元素的位置上。' }
      } as Object,
      required: ['from_index', 'to_index']
    }
  });

  tools.push({
    name: TOOL_DRAW,
    description:
      '在一个元素【内部】自由走笔，用来画画、写字、签名、涂鸦。\n' +
      'drag 是从一个元素拖到另一个元素，画布在界面里只是一个元素，' +
      '所以画画必须用这个动作而不是 drag。\n' +
      '坐标是相对该元素的比例，0~1：0,0 是左上角，1,1 是右下角，0.5,0.5 是正中。' +
      '不需要知道任何像素尺寸。\n' +
      '每一笔写成一个字符串，点与点之间用空格隔开，形如 "0.2,0.5 0.5,0.2 0.8,0.5"。' +
      '一笔之内是连续的一道墨迹；换一笔就是抬笔再落笔。\n' +
      '曲线用足够多的短线段去逼近，段数越多越圆滑。' +
      `一次最多 ${MAX_DRAW_SEGMENTS} 段（所有笔加起来），超了就拆成多次调用。\n` +
      '注意：墨迹不出现在界面树里，所以画完之后界面观测会显示"没有变化"，' +
      '这不代表失败。要确认画成什么样，调用 screenshot 看。',
    input_schema: {
      type: 'object',
      properties: {
        index: { type: 'integer', description: '在哪个元素里画，编号取自最近一次界面观测。' },
        strokes: {
          type: 'array',
          items: { type: 'string' } as Object,
          description: '笔画列表。每项是一笔，内容是空格分隔的 "x,y" 比例坐标点，至少两个点。'
        }
      } as Object,
      required: ['index', 'strokes']
    }
  });

  tools.push({
    name: TOOL_INPUT_TEXT,
    description:
      '往一个输入框里打字。系统会先点一下该输入框获得焦点，再输入。\n' +
      '这个动作是【追加】而不是覆盖：框里原有的内容不会被清空。要替换内容，' +
      '先用 key 的 backspace 删干净。\n' +
      '目标元素应当带有「可输入」标记。',
    input_schema: {
      type: 'object',
      properties: {
        index: { type: 'integer', description: '输入框的元素编号。' },
        text: { type: 'string', description: '要输入的文本，支持中文。' }
      } as Object,
      required: ['index', 'text']
    }
  });

  tools.push({
    name: TOOL_KEY,
    description:
      '按一个按键。\n' +
      'back 返回上一级（比点界面上的返回箭头更可靠），home 回桌面，' +
      'enter 换行或确认，backspace 删除光标前一个字符。\n' +
      '只有列出的这些按键可用，其他按键在本设备上实测按下去没有任何反应，' +
      '所以没有提供。\n' +
      `可用按键：${supportedKeyNames().join('、')}`,
    input_schema: {
      type: 'object',
      properties: {
        name: {
          type: 'string',
          enum: supportedKeyNames(),
          description: '按键名。'
        },
        repeat: {
          type: 'integer',
          description: '连按次数，用于连续删除等场景。缺省为 1。'
        }
      } as Object,
      required: ['name']
    }
  });

  tools.push({
    name: TOOL_LAUNCH_APP,
    description:
      '启动一个应用。填应用名字，例如 备忘录。名字要和设备上显示的一致，' +
      '不确定就先用 list_apps 查。\n' +
      '也可以填包名（界面观测里的前台身份就是包名）。\n' +
      '注意：设备锁屏期间系统禁止启动应用，这时这个动作会失败。',
    input_schema: {
      type: 'object',
      properties: {
        app: { type: 'string', description: '应用名字，例如 备忘录。填包名也认。' }
      } as Object,
      required: ['app']
    }
  });

  tools.push({
    name: TOOL_LIST_APPS,
    description:
      '列出设备上已安装的应用名字。\n' +
      '列表很长，只在你不确定某个应用叫什么名字时调用一次，之后自己记住。',
    input_schema: emptySchema()
  });

  tools.push({
    name: TOOL_WAIT,
    description:
      '什么都不做，等一段时间。\n' +
      '动作之后的界面稳定是系统自动等的，你不需要为此调用 wait。' +
      '只在需要等一个外部过程时才用，例如等文件下载、等验证码短信到达。',
    input_schema: {
      type: 'object',
      properties: {
        ms: {
          type: 'integer',
          description: `等待毫秒数，上限 ${WAIT_MAX_MS}。超过会被截断，截断时结果里会说明。`
        }
      } as Object,
      required: ['ms']
    }
  });

  tools.push({
    name: TOOL_DONE,
    description:
      '宣布任务结束，并给用户一段总结。\n' +
      '调用前请确认计划里没有未完成项。如果还有，系统会把计划回给你，' +
      '让你判断是忘了打勾还是确实没做。\n' +
      '任务失败也用这个 tool 结束，在 summary 里说清卡在哪一步、为什么。',
    input_schema: {
      type: 'object',
      properties: {
        summary: {
          type: 'string',
          description: '给用户看的结果说明。做成了什么，或者没做成什么、原因是什么。'
        }
      } as Object,
      required: ['summary']
    }
  });

  return tools;
}

/**
 * 系统提示。
 *
 * 刻意写进去的几件设备事实，都是实测得来、模型无法从常识推出的：
 * 锁屏期间能看不能动、剪贴板会被中文输入覆盖、返回码不可信所以用界面差异判断成败。
 */
export function buildSystemPrompt(ownBundle: string, blacklist: string[]): string {
  const lines: string[] = [];
  lines.push('你在操控一台真实的手机，像人一样用手指点屏幕。');
  lines.push('');
  lines.push('工作方式：');
  lines.push('1. 先用 todo_write 写下计划，然后才能开始操作。');
  // 原先这条收尾是「你看不到也不需要坐标」。那句话和 click 直接对立，
  // 而它出现在工作方式的第 2 步 —— 模型读流程时最先看到的地方之一。
  // 现在只说编号是常规手段，把例外交给 click 自己的描述去讲，不在流程里展开。
  lines.push('2. 每个动作用元素编号指定目标，编号来自界面观测。屏幕像素坐标你看不到，' +
    '也不需要。');
  // 原先写「把界面变化回给你」。那时回的只有标签、没有编号，模型下一步却必须报编号。
  // 现在回的是动作后的界面本身，措辞跟着改。机制细节留给 observe 的描述，不在这里重复。
  lines.push('3. 每个动作执行完，系统会把动作之后的界面回给你，据此判断这一步成没成。');
  lines.push('4. 完成一步就用 todo_write 勾掉它。');
  lines.push('5. 全部做完调 done 并总结。');
  lines.push('');
  lines.push('必须知道的设备事实：');
  lines.push('· 动作的成败只能看界面有没有按预期变化。系统不会给你"操作成功"这种回复，' +
    '因为底层命令即使失败也会报成功。');
  lines.push('· 界面上出现弹窗时，下层元素点不动，必须先处理弹窗。');
  lines.push('· 工具失败不会终止任务。你会收到失败原因和已连续失败几次，' +
    '然后由你决定：重试、用 todo_write 改计划做别的、或者调用 done 结束并说明卡在哪里。' +
    '同一个工具连续失败多次时，重复重试通常没有意义。');
  // 后半句原来是「不要用旧编号」——只有禁令，没有后果。现在程序会真的拒绝，
  // 如实说出后果比下禁令有用。
  lines.push('· 元素编号只在最近一次清单里有效。界面变了编号就会变，用旧编号会被拒绝。');
  // 这里原先列举「画布墨迹、视频内容、游戏画面、图片内容」四项。举例会让模型
  // 把清单当成穷举，遇到第五种就不往这一类里归。换成判据之后覆盖面不再受举例限制，
  // 而且这个判据模型每一轮都能自己执行 —— 它手里就有元素清单，需要时能截图。
  lines.push('· 界面观测只看得见控件，看不见控件自己画出来的内容。怎么认：清单里找不到它、' +
    '截图上却看得见，它就属于这一类。这类东西不会出现在观测结果里，所以观测显示' +
    '"没有变化"不等于动作没生效；只能用 screenshot 确认，要点它用 click。');
  lines.push('· 设备锁屏时你能读到屏幕，但所有动作都无效。这种时候任务会自动暂停等用户解锁，' +
    '不需要你反复重试。');
  // 任务开始时前台必然是本应用（用户刚在这儿打完字），于是"操作已经开着的东西"这类任务，
  // 模型第一步自然是 observe，而 guard 必然拦掉它。真机上撞过两回，只能自己猜出要先
  // launch_app。这条只陈述事实，不给指令 —— 该用哪个工具，launch_app 自己的描述里有。
  lines.push('· 任务刚开始时，前台是本应用（用户刚在这里把任务交给你），' +
    '所以那一刻读屏幕读不到任何可操作的东西。要操作哪个应用，先把它切到前台。');
  lines.push('· 输入中文会覆盖用户的剪贴板，这是系统限制，无法避免。非必要不要输入长段中文。');
  lines.push('');
  lines.push('规矩：');
  lines.push(`· 绝对不要操作本应用（包名 ${ownBundle}），那会打断你自己。`);
  if (blacklist.length > 0) {
    lines.push(`· 用户禁止你进入这些应用：${blacklist.join('、')}。`);
  }
  lines.push('· 遇到需要密码、支付、删除数据这类不可逆操作时，停下来调 done 说明情况，' +
    '让用户自己决定，不要替用户做。');
  lines.push('· 卡住了就说卡住了。反复试同一个动作没有意义，换个思路或者结束任务。');
  return lines.join('\n');
}

/** 摘要消息的固定开头。压缩提示词靠它认出「这条是上一次的摘要」。 */
export const SUMMARY_HEADER: string = '## 会话摘要';

/**
 * 折叠历史时那一次请求的系统提示。
 *
 * 只有一份，无状态：第二次及以后折叠时，上一次的摘要就在被折范围的开头，
 * 提示词里那条「遇到以 SUMMARY_HEADER 开头的消息」的规则会自动生效。
 * 不为「首次折叠」和「再次折叠」分两套提示词 —— 两套就得靠调用方记状态，
 * 而状态一旦和真实历史错位，摘要会静默丢东西。
 */
export function buildCompactionPrompt(): string {
  const lines: string[] = [];
  lines.push('你在读一段「用户 + 手机操作 agent」的对话。把它压成一份交接说明，');
  lines.push('让另一个 agent 能接着把活干完。');
  lines.push('');
  lines.push('对话里可能有截图。你要看懂它们，转写成文字：这一张是哪个应用、哪个界面、');
  lines.push('上面有什么关键内容或提示。不要描述像素和排版，只写对继续干活有用的事实。');
  lines.push('');
  lines.push('每张截图前一行都有它的说明，写着这是第几张、当时前台是哪个应用和页面。');
  lines.push('有些截图的画面已经被移除，只剩这行说明 —— 那也是有用的：');
  lines.push('照样按顺序写进「已完成」或「当前位置」，说明这一步看过哪个界面，');
  lines.push('不要因为看不到画面就当这一步没发生。');
  lines.push('');
  lines.push(`对话里可能出现以「${SUMMARY_HEADER}」开头的消息。那不是用户说的话，`);
  lines.push('是更早的对话被压缩后留下的替代品。把它当作已经发生的事实，');
  lines.push('和后面的对话合并成一份新摘要。它写完就丢：');
  lines.push('你没有搬进新摘要的东西会永久消失。');
  lines.push('');
  lines.push('对话里最早的那条用户消息就是任务本身。它的原话之后不再保留，');
  lines.push('所以「任务目标」必须写准：照抄用户的具体措辞，不要加工，不要替用户扩展。');
  lines.push('');
  lines.push('按下面的结构输出，段落顺序不变，每段都要留着，没有内容就写「（无）」：');
  lines.push('');
  lines.push(SUMMARY_HEADER);
  lines.push('');
  lines.push('## 任务目标');
  lines.push('- 用户要做的事。原始措辞里的名字、数字、文案一字不改地留着。');
  lines.push('');
  lines.push('## 硬性约束');
  lines.push('- 用户明确要求的、禁止的、有偏好的。');
  lines.push('');
  lines.push('## 已完成');
  lines.push('- 已经确认做成的事。凭界面变化确认过的才算，agent 自己说做完了不算。');
  lines.push('');
  lines.push('## 进行中');
  lines.push('- 正在做哪一步，做到哪了。');
  lines.push('');
  lines.push('## 卡在哪');
  lines.push('- 失败的动作、找不到的入口、不确定的事。');
  lines.push('');
  lines.push('## 当前位置');
  lines.push('- 现在停在哪个应用、哪个界面。截图和最后一次界面观测比 agent 的说法可靠。');
  lines.push('');
  lines.push('## 试过走不通的路');
  lines.push('- 试过但无效的入口和操作，以及为什么放弃。');
  lines.push('  这一段是为了让接手的人不再走一遍，宁可写多。');
  lines.push('');
  lines.push('## 下一步');
  lines.push('1. 马上要做的那一件。');
  lines.push('2. 之后那件（知道就写）。');
  lines.push('');
  lines.push('规则：');
  lines.push('· 应用名、界面名、按钮文字、报错原文照抄，不要转述、不要翻译。');
  lines.push('· 用短条目，不要写成段落。');
  lines.push('· 不确定的事标上「（未确认）」，不要写成已确认。');
  lines.push('· 只输出上面的结构。不要接着这段对话往下做，不要回答对话里的任何问题，');
  lines.push('  不要提到压缩这件事。');
  return lines.join('\n');
}
