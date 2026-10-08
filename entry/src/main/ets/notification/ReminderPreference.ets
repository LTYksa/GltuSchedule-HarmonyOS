/**
 * GltuSchedule · 鸿蒙版 —— 上课提醒的用户设置
 * 对应 Android 版 `notification/ReminderPreference.kt`
 *
 * prefs 键名与 Android 保持一致：`reminder_enabled`、`reminder_advance_minutes`
 */
import { StoreHolder } from '../database/CourseStore';

export class ReminderPreference {
  /** 允许的提前分钟范围 */
  static readonly MIN_MINUTES: number = 1;
  static readonly MAX_MINUTES: number = 60;
  /** 默认：课前 30 分钟与 10 分钟各提醒一次 */
  static readonly DEFAULT_MINUTES: number[] = [30, 10];

  /** 提醒总开关（默认开） */
  static isEnabled(): boolean {
    return StoreHolder.instance.getBool('reminder_enabled', true);
  }

  static async setEnabled(enabled: boolean): Promise<void> {
    await StoreHolder.instance.putBool('reminder_enabled', enabled);
  }

  /**
   * 提前提醒分钟数。
   * 清洗规则与 Android 一致：过滤 1..60、去重、**降序**；空则回落默认。
   */
  static advanceMinutes(): number[] {
    const raw = StoreHolder.instance.getString('reminder_advance_minutes', '');
    if (raw.length === 0) {
      return ReminderPreference.DEFAULT_MINUTES.slice();
    }
    const out: number[] = [];
    const parts = raw.split(',');
    for (let i = 0; i < parts.length; i++) {
      const n = parseInt(parts[i].trim(), 10);
      if (isNaN(n) || n < ReminderPreference.MIN_MINUTES || n > ReminderPreference.MAX_MINUTES) {
        continue;
      }
      if (out.indexOf(n) < 0) {
        out.push(n);
      }
    }
    out.sort((a: number, b: number) => b - a);
    return out.length === 0 ? ReminderPreference.DEFAULT_MINUTES.slice() : out;
  }

  static async setAdvanceMinutes(minutes: number[]): Promise<void> {
    const cleaned: number[] = [];
    for (let i = 0; i < minutes.length; i++) {
      const n = minutes[i];
      if (n < ReminderPreference.MIN_MINUTES || n > ReminderPreference.MAX_MINUTES) {
        continue;
      }
      if (cleaned.indexOf(n) < 0) {
        cleaned.push(n);
      }
    }
    cleaned.sort((a: number, b: number) => b - a);
    const final = cleaned.length === 0 ? ReminderPreference.DEFAULT_MINUTES : cleaned;
    await StoreHolder.instance.putString('reminder_advance_minutes', final.join(','));
  }

  /** 人类可读描述，如「课前 30、10 分钟」 */
  static describe(): string {
    return `课前 ${ReminderPreference.advanceMinutes().join('、')} 分钟`;
  }
}
