/**
 * formId → 规格(dimension) 登记表。
 *
 * 用途：卡片被系统回收后，`onUpdateForm` 只给到 formId，
 *      需要靠这张表才能知道它是什么规格（几行）；
 *      也是 App 主进程做"定点推送"时的兜底路径。
 *
 * 对应 Android：`AppWidgetManager` 内部维护的 appWidgetId → 规格 映射。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const FORM_PREF: string = 'gltu_forms';
const KEY_IDS: string = 'ids';

/** 认不出规格时按 2*4 处理（Dimension_2_4 = 3） */
const DEFAULT_DIM: number = 3;

function p(context: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: FORM_PREF });
}

/** preferences 返回联合类型 ValueType，取字符串时统一收口 */
function readString(pref: preferences.Preferences, key: string): string {
  const v: preferences.ValueType = pref.getSync(key, '');
  if (typeof v === 'string') {
    return v as string;
  }
  return '';
}

export class FormRegistry {

  /** 记下这张卡片（onAddForm / onSizeChanged 时调用） */
  static remember(context: common.Context, formId: string, dimension: number): void {
    if (formId.length === 0) {
      return;
    }
    const pref: preferences.Preferences = p(context);
    pref.putSync(`dim_${formId}`, dimension);
    const ids: string[] = FormRegistry.all(context);
    if (ids.indexOf(formId) < 0) {
      ids.push(formId);
      pref.putSync(KEY_IDS, ids.join(','));
    }
    pref.flush();
  }

  /** 这张卡片是什么规格 */
  static dimensionOf(context: common.Context, formId: string): number {
    const v: preferences.ValueType = p(context).getSync(`dim_${formId}`, DEFAULT_DIM);
    if (typeof v === 'number') {
      return v as number;
    }
    return DEFAULT_DIM;
  }

  /** 卡片被移除 */
  static forget(context: common.Context, formId: string): void {
    if (formId.length === 0) {
      return;
    }
    const pref: preferences.Preferences = p(context);
    pref.deleteSync(`dim_${formId}`);
    const kept: string[] = FormRegistry.all(context).filter((x: string) => x !== formId);
    pref.putSync(KEY_IDS, kept.join(','));
    pref.flush();
  }

  /** 全部登记在册的 formId */
  static all(context: common.Context): string[] {
    const raw: string = readString(p(context), KEY_IDS);
    return raw.length > 0 ? raw.split(',') : [];
  }
}
