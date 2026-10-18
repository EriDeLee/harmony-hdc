/*
 * 后台保活与通知栏进度。
 *
 * 为什么必须有：应用退到后台后进程会被挂起，agent 就停了。而 agent 要驱动别的应用，
 * 本应用必然在后台。长时任务是排除画中画之后唯一的路（悬浮窗只支持 2in1，
 * 闪控窗要 API 26，本机 API 24）。
 *
 * 只用 dataTransfer 一种类型。它是唯一允许实况窗进度环的类型，代价是
 * **进度超过 10 分钟未更新，系统会取消长时任务**，所以必须有心跳。
 *
 * 曾经备过 multiDeviceConnection 作为退路（纯文本通知，没有那条 10 分钟规矩），
 * 已删除。理由不是它没用，而是它挡不住任何真实故障：它的触发条件是 publish 抛异常，
 * 而通知开关关着时 publish **不报错**（静默成功），那条链在第二步就断了。
 * 真正的洞改由「进 AGENT 页先验通知授权」堵上，见 Index.ets 的 requireNotifyPermission()。
 *
 * 通知栏按钮：NotificationButton 只有 names 和 icons，**没有任何 action 字段**，
 * 而能接收按钮点击的实况窗订阅能力标注"暂不对外开放使用"。所以按钮即使能画出来
 * 也回不到本应用。这里仍然把它发出去，纯粹为了在真机上把这件事验死；
 * 停止入口不依赖它，而是靠「划掉通知」（系统会自动停止长时任务并回调）与应用内按钮。
 */

import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent } from '@kit.AbilityKit';
import type { WantAgent, common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';

export type LogSink = (line: string) => void;

/** dataTransfer 的实况窗固定用这个 typeCode，官方注明"当前仅支持此类型"。 */
const DATA_TRANSFER_TYPE_CODE: number = 8;
/** 官方注明模板名"当前只支持 downloadTemplate"。 */
const DOWNLOAD_TEMPLATE: string = 'downloadTemplate';
const MODE_DATA_TRANSFER: string = 'dataTransfer';

/**
 * 心跳间隔。10 分钟是系统取消 dataTransfer 长时任务的门槛，
 * 这里取三分之一，给等待解锁这类长停顿留足余量。
 *
 * 未验证：10 分钟规则到底看"有没有 publish"还是"值有没有变"。按前者实现，
 * 因为等待解锁期间进度不会变，若系统看的是值，那段时间就顶不住。装机时要验。
 */
const HEARTBEAT_MS: number = 200000;

/**
 * 把系统给的暂停原因码翻成人话。
 *
 * 原先日志里就是个裸数字（`reason=12`），查表才知道是什么。而这个枚举里
 * 与我们有关的只有两三条 —— 我们只申请 dataTransfer，音频、定位、蓝牙那些
 * 原因码永远不会出现，所以不必把十几条全列出来，认不出的原样带上数字即可。
 */
function describeSuspendReason(reason: number): string {
  if (reason === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED) {
    return `传输速度过低（原因码 ${reason}）`;
  }
  if (reason === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_SYSTEM_LOAD_WARNING) {
    return `系统负载告警（原因码 ${reason}）`;
  }
  if (reason === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_USED_ILLEGALLY) {
    return `被判定为不当使用（原因码 ${reason}）`;
  }
  return `原因码 ${reason}`;
}

export interface KeepAliveHooks {
  /** 用户划掉了通知栏那条通知 —— 系统会自动停止长时任务，这里要把 agent 也停掉。 */
  onCancelledByUser: (reason: string) => void;
  /** 系统把长时任务标记为暂停（例如判定负载超标）。用于诊断，不自动恢复。 */
  onSuspended: (reason: string) => void;
}

export class KeepAlive {
  private readonly context: common.UIAbilityContext;
  private readonly log: LogSink;
  private readonly hooks: KeepAliveHooks;

  private active: boolean = false;
  /**
   * 进度环能不能用。由 probeProgress 实测填写，不是推断。
   *
   * 从前这件事是靠「申请下来的是哪个类型」间接表达的（只有 dataTransfer 有进度）。
   * 退路删掉之后类型只剩一种，那个字段就退化成常量了，改用这个直说。
   */
  private progressUsable: boolean = false;
  /** 系统创建的那条通知的 id；更新进度必须用它，用别的 id 会失败。 */
  private notificationId: number = -1;
  private timer: number = -1;
  private lastPercent: number = 0;
  private lastText: string = '';
  /** 端点是否接受 systemLiveView.button。由 probeProgress 实测填写。 */
  private buttonUsable: boolean = false;
  /** 通知开关是否开着。关着时 publish 不报错但什么都不显示。 */
  private notifyEnabled: boolean = false;
  private cancelListener: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | null = null;
  private suspendListener: ((info: backgroundTaskManager.ContinuousTaskSuspendInfo) => void) | null = null;
  private activeListener: ((info: backgroundTaskManager.ContinuousTaskActiveInfo) => void) | null = null;

  constructor(context: common.UIAbilityContext, hooks: KeepAliveHooks, log: LogSink) {
    this.context = context;
    this.hooks = hooks;
    this.log = log;
  }

  isActive(): boolean {
    return this.active;
  }

  /** 保活状态，界面上显示出来便于诊断。 */
  mode(): string {
    if (!this.active) {
      return '未保活';
    }
    return this.progressUsable ? '数据传输（带进度环）' : '数据传输（进度环不可用）';
  }

  /** 进度环是否可用；不可用时界面不必显示百分比。 */
  supportsProgress(): boolean {
    return this.progressUsable;
  }

  /** 通知栏按钮是否被端点接受。实测结果，不是推断。 */
  hasNotificationButton(): boolean {
    return this.buttonUsable;
  }

  /** 通知开关是否开着。关着时长时任务仍然保活，只是通知栏看不到任何东西。 */
  notificationEnabled(): boolean {
    return this.notifyEnabled;
  }

  /**
   * 确保通知开关是开的。
   *
   * 这一步不能省：`publish` 在通知被关闭时**不报错**，只是什么都不显示。
   * 实测过一次 —— 长时任务申请成功、publish 也成功，通知栏里却什么都没有，
   * 原因就是从没申请过通知授权。
   */
  private async ensureNotifyEnabled(): Promise<void> {
    try {
      this.notifyEnabled = await notificationManager.isNotificationEnabled();
    } catch (err) {
      this.log(`[keepalive] 查询通知开关失败: ${(err as BusinessError).message}`);
      this.notifyEnabled = false;
    }
    if (this.notifyEnabled) {
      return;
    }
    this.log('[keepalive] 通知未开启，弹窗请求授权');
    try {
      await notificationManager.requestEnableNotification(this.context);
    } catch (err) {
      this.log(`[keepalive] 请求通知授权失败: ${(err as BusinessError).message}`);
    }
    try {
      this.notifyEnabled = await notificationManager.isNotificationEnabled();
    } catch (err) {
      this.notifyEnabled = false;
    }
    this.log(`[keepalive] 通知开关现在=${this.notifyEnabled ? '开' : '关'}`);
  }

  private async buildWantAgent(): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: this.context.abilityInfo.name
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      return await wantAgent.getWantAgent(info);
    } catch (err) {
      throw new Error(`获取 WantAgent 失败: ${(err as BusinessError).message}`);
    }
  }

  /**
   * 申请保活。只有 dataTransfer 一种类型，拿不到就是拿不到。
   *
   * 一按开始就申请（而不是等切到后台），代价是通知会提前出现，好处是保活能不能拿到
   * 立刻就知道 —— 否则要等用户切走那一刻才暴露，而那时 agent 可能正在半路。
   */
  async start(): Promise<boolean> {
    if (this.active) {
      return true;
    }
    // 通知开关按说在进 AGENT 页时已经验过（没给授权压根进不来）。这里再读一次，
    // 是因为用户可能在页面开着的时候去系统设置里关掉它 —— 而那种情况下
    // publish 不报错、通知栏却是空的，属于"成功但看不见"，最难查。
    await this.ensureNotifyEnabled();
    let agent: WantAgent;
    try {
      agent = await this.buildWantAgent();
    } catch (err) {
      this.log(`[keepalive] 构造 WantAgent 失败: ${(err as BusinessError).message}`);
      return false;
    }

    try {
      const res: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(this.context, [MODE_DATA_TRANSFER], agent);
      this.notificationId = res.notificationId;
      this.active = true;
      this.log(
        `[keepalive] 已申请 ${MODE_DATA_TRANSFER}，通知 id=${res.notificationId} ` +
        `slot=${res.slotType} content=${res.contentType}`
      );
      this.attachListeners();
      // 申请刚成功就问一次系统，把它眼里的状态记下来，作为后面对账的起点。
      await this.logSystemState();
    } catch (err) {
      const e = err as BusinessError;
      this.log(
        `[keepalive] 申请 ${MODE_DATA_TRANSFER} 失败: code=${e.code} ${e.message}，` +
        `切到后台后 agent 会被挂起。`
      );
      return false;
    }

    // 长时任务已经拿到了。进度通知是另一件事，它失败不能被误当成"申请失败" ——
    // 保活本身照样成立，只是通知栏没有进度环。
    //
    // 但 10 分钟不更新进度会被系统取消，所以这里必须把后果说清楚：届时会走
    // onCancelledByUser，agent 被正常停掉并在时间线里留话，不是静默卡死。
    this.progressUsable = await this.probeProgress();
    if (this.progressUsable) {
      this.startHeartbeat();
    } else {
      this.log('[keepalive] 进度通知发不出去，10 分钟后系统会取消长时任务并回调停止。');
    }
    return true;
  }

  /**
   * 试发一次进度通知，顺便把"通知栏按钮能不能用"这件事验死。
   *
   * 先带 button 发；被拒就去掉 button 再发一次。两次结果组合起来就能区分
   * "publish 整条不可用" 与 "只是 button 不被接受"，一次运行给出结论。
   */
  private async probeProgress(): Promise<boolean> {
    try {
      await this.publish(0, '正在准备', true);
      this.buttonUsable = true;
      this.log('[keepalive] 进度通知可用，且接受 button 字段');
      return true;
    } catch (err) {
      this.log(`[keepalive] 带 button 的进度通知被拒: ${(err as Error).message}`);
    }
    try {
      await this.publish(0, '正在准备', false);
      this.buttonUsable = false;
      this.log('[keepalive] 进度通知可用，但不接受 button 字段（停止只能靠划掉通知与应用内按钮）');
      return true;
    } catch (err) {
      this.log(`[keepalive] 进度通知整条不可用: ${(err as Error).message}`);
      return false;
    }
  }

  /**
   * 把系统眼里我们名下的长时任务打一行日志。
   *
   * 为什么需要：`this.active` 是我们自己记的账。账和真实情况不符时，
   * 原先没有任何办法发现 —— 界面显示"已保活"而系统那边其实已经没有了，
   * 两种情况在日志里长得一模一样。这里读的是系统的答案。
   *
   * **只做诊断，不参与控制。** 不拿它去纠正 `this.active`：那需要想清楚
   * "系统说没有、我们以为有"时该继续跑还是该停，而这个判断没有依据支撑，
   * 现在也没有观察到这种情形。先把事实记下来。
   *
   * `includeSuspended` 传 true，否则被暂停的任务不出现在列表里 ——
   * 那恰好是最需要看见的一种。
   */
  private async logSystemState(): Promise<void> {
    let tasks: backgroundTaskManager.ContinuousTaskInfo[];
    try {
      tasks = await backgroundTaskManager.getAllContinuousTasks(this.context, true);
    } catch (err) {
      // API 20 起才有，低版本拿不到属预期
      this.log(`[keepalive] 读系统长时任务列表失败（可忽略）: ${(err as BusinessError).message}`);
      return;
    }
    if (tasks.length === 0) {
      this.log('[keepalive] 系统那边一个长时任务都没有（我们自己记的是已保活）');
      return;
    }
    for (const task of tasks) {
      this.log(
        `[keepalive] 系统记录 taskId=${task.continuousTaskId} 通知id=${task.notificationId} ` +
        `类型=[${task.backgroundModes.join(',')}] 被暂停=${task.suspendState} ` +
        `ability=${task.abilityName}`
      );
    }
  }

  private attachListeners(): void {
    this.cancelListener = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      // 用户划掉通知走的就是这条路。系统已经停了长时任务，这里负责把 agent 也停掉。
      this.log(`[keepalive] 长时任务被取消 id=${info.id} reason=${info.reason}`);
      this.active = false;
      this.stopHeartbeat();
      this.hooks.onCancelledByUser(`长时任务被取消（原因码 ${info.reason}）`);
    };
    this.suspendListener = (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
      // 注意字段名与 CancelInfo 不同：这里是 continuousTaskId，那里是 id。
      const why = describeSuspendReason(info.suspendReason);
      this.log(
        `[keepalive] 长时任务被暂停 id=${info.continuousTaskId} ` +
        `suspended=${info.suspendState} reason=${why}`
      );
      this.hooks.onSuspended(`长时任务被系统暂停（${why}）`);
    };
    this.activeListener = (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
      // 与暂停配对的另一半。没有它的话只知道被暂停、不知道什么时候恢复，
      // 而"一直没恢复"和"恢复了但任务已经停了"在日志里长得一模一样。
      this.log(`[keepalive] 长时任务已恢复 id=${info.id}`);
    };
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelListener);
    } catch (err) {
      this.log(`[keepalive] 注册取消回调失败: ${(err as BusinessError).message}`);
    }
    try {
      backgroundTaskManager.on('continuousTaskSuspend', this.suspendListener);
    } catch (err) {
      // API 20 起才有，低版本注册失败属预期
      this.log(`[keepalive] 注册暂停回调失败（可忽略）: ${(err as BusinessError).message}`);
    }
    try {
      backgroundTaskManager.on('continuousTaskActive', this.activeListener);
    } catch (err) {
      this.log(`[keepalive] 注册恢复回调失败（可忽略）: ${(err as BusinessError).message}`);
    }
  }

  private detachListeners(): void {
    if (this.cancelListener !== null) {
      try {
        backgroundTaskManager.off('continuousTaskCancel', this.cancelListener);
      } catch (err) {
        this.log(`[keepalive] 注销取消回调失败: ${(err as BusinessError).message}`);
      }
      this.cancelListener = null;
    }
    if (this.suspendListener !== null) {
      try {
        backgroundTaskManager.off('continuousTaskSuspend', this.suspendListener);
      } catch (err) {
        this.log(`[keepalive] 注销暂停回调失败: ${(err as BusinessError).message}`);
      }
      this.suspendListener = null;
    }
    if (this.activeListener !== null) {
      try {
        backgroundTaskManager.off('continuousTaskActive', this.activeListener);
      } catch (err) {
        this.log(`[keepalive] 注销恢复回调失败: ${(err as BusinessError).message}`);
      }
      this.activeListener = null;
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    // 即使百分比没变也要重发，否则 10 分钟不更新会被系统取消。
    this.timer = setInterval(() => {
      if (!this.active) {
        return;
      }
      this.publish(this.lastPercent, this.lastText, this.buttonUsable).then(() => {
      }).catch((err: Error) => {
        this.log(`[keepalive] 心跳更新失败: ${err.message}`);
      });
    }, HEARTBEAT_MS);
  }

  private stopHeartbeat(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /**
   * 更新进度环与文字。
   *
   * percent 由 TodoStore 的计划完成度换算而来 —— downloadTemplate 的 progressValue
   * 是百分比，而 agent 的总步数事先不知道，所以拿模型自己的计划当分母。
   * 运行中封顶 99：>=100 会让进度环消失，中途消失会被误读成跑完了。
   */
  async update(percent: number, text: string): Promise<void> {
    this.lastPercent = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    this.lastText = text;
    if (!this.active || !this.progressUsable) {
      return;
    }
    try {
      await this.publish(this.lastPercent, this.lastText, this.buttonUsable);
    } catch (err) {
      this.log(`[keepalive] 更新通知失败: ${(err as Error).message}`);
    }
  }

  private async publish(percent: number, text: string, withButton: boolean): Promise<void> {
    if (this.notificationId < 0) {
      return;
    }
    const template: notificationManager.NotificationTemplate = {
      name: DOWNLOAD_TEMPLATE,
      data: {
        // 这三个字段名是模板固定的下载语义，只能借用
        title: 'AGENT 操控',
        fileName: text.length > 0 ? text : '进行中',
        progressValue: percent
      }
    };
    const live: notificationManager.NotificationSystemLiveViewContent = {
      typeCode: DATA_TRANSFER_TYPE_CODE,
      title: 'AGENT 操控',
      text
    };
    if (withButton) {
      // 按钮大概回不到本应用（NotificationButton 没有 action 字段，
      // 而能收按钮点击的实况窗订阅标注"暂不对外开放使用"）。
      // 发它是为了把这件事验死；停止入口不依赖它。
      live.button = { names: ['停止'] };
    }
    const request: notificationManager.NotificationRequest = {
      id: this.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: live
      }
    };
    try {
      await notificationManager.publish(request);
    } catch (err) {
      const e = err as BusinessError;
      // 这里是判死"通知栏按钮能不能用"的关键日志：若因 button 字段被拒，
      // 错误码会点明是哪个字段。装机后第一次跑就看这一行。
      throw new Error(`publish 失败 code=${e.code} ${e.message}`);
    }
  }

  /** 任务结束时调用：把进度写满、撤销长时任务。规范要求业务做完就及时取消。 */
  async stop(finished: boolean): Promise<void> {
    this.stopHeartbeat();
    if (this.active && this.progressUsable && finished) {
      try {
        // 100 会让进度环消失，正好表示完成
        await this.publish(100, '已完成', this.buttonUsable);
      } catch (err) {
        this.log(`[keepalive] 收尾更新失败: ${(err as Error).message}`);
      }
    }
    this.detachListeners();
    if (!this.active) {
      return;
    }
    this.active = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.log('[keepalive] 已取消长时任务');
    } catch (err) {
      this.log(`[keepalive] 取消长时任务失败: ${(err as BusinessError).message}`);
    }
    this.progressUsable = false;
    this.notificationId = -1;
  }
}
