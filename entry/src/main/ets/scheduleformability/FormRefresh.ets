/**
 * 课程/设置变更后刷新桌面卡片。
 *
 * 对应 Android 的 `ScheduleWidgetProvider.refreshAll(ctx)`。
 * 鸿蒙侧：主进程调 `formProvider.reloadAllForms(ctx)`，
 * 由系统通知 FormExtension 进程去批量跑 `onUpdateForm`，
 * **不需要自己保存 formId**。
 *
 * 限制：`reloadAllForms` 要求 UIAbilityContext，
 *      所以只能在页面组件里通过 `getUIContext().getHostContext()` 调用（API 22+）。
 */
import { common } from '@kit.AbilityKit';
import { formProvider } from '@kit.FormKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'GltuSchedule';

export class FormRefresh {

  /**
   * 刷新本应用全部桌面卡片。
   * 失败只记日志：卡片刷不出来不应该影响课程保存这类主流程。
   */
  static all(ctx: common.Context | undefined): void {
    if (ctx === undefined) {
      return;
    }
    formProvider.reloadAllForms(ctx as common.UIAbilityContext)
      .then((count: number) => {
        hilog.info(DOMAIN, TAG, '卡片刷新完成，共 %{public}d 张', count);
      })
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '卡片刷新失败 code=%{public}d msg=%{public}s',
          err.code, err.message);
      });
  }

  /** 只刷新某一个规格（用不上时留着做定点推送） */
  static only(ctx: common.Context | undefined, formName: string): void {
    if (ctx === undefined) {
      return;
    }
    formProvider.reloadForms(ctx as common.UIAbilityContext, 'entry', 'EntryFormAbility', formName)
      .then((count: number) => {
        hilog.info(DOMAIN, TAG, '%{public}s 刷新完成，共 %{public}d 张', formName, count);
      })
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '卡片刷新失败 code=%{public}d msg=%{public}s',
          err.code, err.message);
      });
  }
}
