import { UIAbility } from '@kit.AbilityKit';
import type { AbilityConstant, Want } from '@kit.AbilityKit';
import type { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {}

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