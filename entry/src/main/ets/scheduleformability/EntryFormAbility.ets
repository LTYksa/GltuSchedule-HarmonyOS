/**
 * GltuSchedule · 鸿蒙版 —— 服务卡片生命周期
 * 对应 Android：ScheduleWidgetProvider（onUpdate / onReceive）+ ScheduleWidgetService
 *
 * 一个 FormExtensionAbility 挂 3 个规格（form_config.json 里的三个 forms 条目），
 * 等价于 Android 的三个 AppWidgetProvider 子类。
 *
 * ⚠️ 本能力空闲 10 秒会被系统回收，所有回调都要"轻、快"。
 * ⚠️ 不要引用 particleAbility / audio / camera / media / backgroundTaskManager（会崩）。
 */
import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CardPayload, ScheduleCardData } from './ScheduleCardData';
import { FormRegistry } from './FormRegistry';

const DOMAIN: number = 0x0000;
const TAG: string = 'GLTUForm';

export default class EntryFormAbility extends FormExtensionAbility {

  /** 卡片被添加到桌面：**必须同步返回**首屏数据（签名里没有 Promise） */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const params: Record<string, Object> | undefined = want.parameters;
    let formId: string = '';
    let dimension: number = 3;
    if (params !== undefined) {
      const idValue: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
      if (idValue !== undefined) {
        formId = idValue as string;
      }
      const dimValue: Object | undefined = params[formInfo.FormParam.DIMENSION_KEY];
      if (dimValue !== undefined) {
        dimension = dimValue as number;
      }
    }
    FormRegistry.remember(this.context, formId, dimension);
    hilog.info(DOMAIN, TAG, 'onAddForm formId=%{public}s dim=%{public}d', formId, dimension);
    return formBindingData.createFormBindingData(this.payload(dimension));
  }

  /** 定时刷新（updateDuration，1 小时一次）、定点刷新、系统请求刷新都走这里 */
  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    this.push(formId);
  }

  /** 卡片内 postCardAction({action:'message'}) 触发（手动刷新入口） */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent %{public}s', message);
    this.push(formId);
  }

  /** 卡片尺寸被拖拽改变（API 20+；本工程三个规格 resizable=false，正常不会触发） */
  onSizeChanged(formId: string, newDimension: formInfo.FormDimension,
                newRect: formInfo.Rect): void {
    FormRegistry.remember(this.context, formId, newDimension);
    this.push(formId);
  }

  onRemoveForm(formId: string): void {
    FormRegistry.forget(this.context, formId);
  }

  onCastToNormalForm(formId: string): void {}

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  /** 算数据；算不出来（数据库/首选项异常）也要给一份能看的降级数据 */
  private payload(dimension: number): CardPayload {
    try {
      return ScheduleCardData.build(this.context, dimension);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '读取课表失败，使用降级数据: %{public}s', JSON.stringify(e));
      return ScheduleCardData.emptyPayload();
    }
  }

  private push(formId: string): void {
    const dimension: number = FormRegistry.dimensionOf(this.context, formId);
    const data: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(this.payload(dimension));
    formProvider.updateForm(formId, data).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'updateForm 失败 code=%{public}d msg=%{public}s',
        err.code, err.message);
    });
    this.scheduleNextFlip(formId);
  }

  /**
   * 排下一次「准点刷新」。
   *
   * 系统给的 updateDuration 只能做到**整点附近的周期刷新**（现在配的是 1 小时），
   * 偏偏有两个时刻最好准时：
   *   · 23:30 —— 内容要从「今天」翻转成「明天」
   *   · 当天最后一节课下课 —— 要从课程列表变成「今天的课都上完啦」
   *
   * `setFormNextRefreshTime` 最短 5 分钟，所以比 5 分钟还近的就不排了
   * （下一轮周期刷新能兜住）。
   *
   * ⚠️ 配额：单卡每天约 50 次刷新。updateDuration=2 已经用掉 24 次，
   *    这里一次只排**一个**最近的点，不会叠加，够用。
   */
  private scheduleNextFlip(formId: string): void {
    try {
      const minutes: number = ScheduleCardData.minutesToNextFlip(new Date());
      if (minutes < 5 || minutes > 24 * 60) {
        return;
      }
      formProvider.setFormNextRefreshTime(formId, minutes, (err: BusinessError) => {
        if (err && err.code !== 0) {
          hilog.warn(DOMAIN, TAG, 'setFormNextRefreshTime 失败 code=%{public}d', err.code);
        }
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '排准点刷新异常: %{public}s', JSON.stringify(e));
    }
  }
}
