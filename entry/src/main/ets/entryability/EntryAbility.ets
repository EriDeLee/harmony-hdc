import { UIAbility } from '@kit.AbilityKit';
import type { AbilityConstant, Want } from '@kit.AbilityKit';
import type { window } from '@kit.ArkUI';

/**
 * 「文件管理器点 .hap 用本应用打开」的接收端。
 * skills 已在 module.json5 声明（viewData + file/openharmony.hap/FileOpen），
 * 系统拉起时 want.uri 即文件 URI。此处只存进 AppStorage，由 Index.onPageShow 消费
 * （页面侧打开安装页并预填）。onCreate 覆盖冷启动，onNewWant 覆盖应用已在后台。
 */
const PENDING_HAP_KEY: string = 'pendingHapUri';

function consumeFileOpenWant(want: Want): void {
  const uri = want.uri ?? '';
  const lower = uri.toLowerCase();
  if (lower.startsWith('file://') && lower.endsWith('.hap')) {
    AppStorage.setOrCreate<string>(PENDING_HAP_KEY, uri);
  }
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    consumeFileOpenWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    consumeFileOpenWant(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      windowStage.loadContent('pages/Index');
    } catch (err) {
      console.error(`loadContent 失败: ${(err as Error).message}`);
    }
  }

  onForeground(): void {}

  onBackground(): void {}

  onDestroy(): void {}
}
