/**
 * GltuSchedule · 鸿蒙版 —— 节假日数据与屏蔽判定
 * 对应 Android 版 `com.ltyksa.gltuschedule.data.Holiday` / `HolidayManager`
 *
 * ⚠️ 只处理**中国大陆**法定节假日与学校校历假期，不含任何其他国家/地区的节日。
 */
import { DateUtil } from './DateUtil';

/** 假期类型 */
export enum HolidayType {
  /** 法定节假日（元旦/春节/清明/劳动/端午/中秋/国庆） */
  STATUTORY = 'STATUTORY',
  /** 学校假期（校运会/寒暑假等，来自 GLTU 校历） */
  SCHOOL = 'SCHOOL',
  /** 调休补班日（周末但要上课） */
  MAKEUP = 'MAKEUP',
  /** 用户自定义 */
  USER_DEFINED = 'USER_DEFINED'
}

/** 一个假期（闭区间） */
export class Holiday {
  readonly name: string;
  readonly start: number; // 天数序号
  readonly end: number;   // 天数序号

  constructor(name: string, start: number, end: number) {
    this.name = name;
    this.start = start;
    this.end = end;
  }

  contains(date: number): boolean {
    return date >= this.start && date <= this.end;
  }
}

/**
 * 内置节假日（离线兜底；联网同步成功后会被权威数据覆盖）。
 * 数据来源：中国大陆法定节假日（国务院办公厅发布）+ 桂林旅游学院校历。
 */
export class GltuHolidays {
  /** 学校假期（GLTU 2026-2027 学年校历） */
  static schoolHolidays(): Holiday[] {
    return [
      new Holiday('校运会', DateUtil.fromYmd(2026, 10, 29), DateUtil.fromYmd(2026, 10, 31)),
      new Holiday('寒假', DateUtil.fromYmd(2027, 1, 18), DateUtil.fromYmd(2027, 2, 28)),
      new Holiday('暑假', DateUtil.fromYmd(2027, 7, 5), DateUtil.fromYmd(2027, 9, 5))
    ];
  }

  /** 中国大陆法定节假日（2026-2027 学年内） */
  static statutoryHolidays(): Holiday[] {
    return [
      new Holiday('国庆节', DateUtil.fromYmd(2026, 10, 1), DateUtil.fromYmd(2026, 10, 7)),
      new Holiday('中秋节', DateUtil.fromYmd(2026, 9, 25), DateUtil.fromYmd(2026, 9, 27)),
      new Holiday('元旦', DateUtil.fromYmd(2027, 1, 1), DateUtil.fromYmd(2027, 1, 3)),
      new Holiday('春节', DateUtil.fromYmd(2027, 2, 6), DateUtil.fromYmd(2027, 2, 12)),
      new Holiday('清明节', DateUtil.fromYmd(2027, 4, 5), DateUtil.fromYmd(2027, 4, 7)),
      new Holiday('劳动节', DateUtil.fromYmd(2027, 5, 1), DateUtil.fromYmd(2027, 5, 5)),
      new Holiday('端午节', DateUtil.fromYmd(2027, 6, 9), DateUtil.fromYmd(2027, 6, 11))
    ];
  }

  /** 调休补班日（周末但要上课） */
  static makeupDays(): Holiday[] {
    return [
      new Holiday('国庆节后补班', DateUtil.fromYmd(2026, 10, 10), DateUtil.fromYmd(2026, 10, 10))
    ];
  }
}

/** 一条假期记录（带类型与来源） */
export class HolidayEntry {
  readonly holiday: Holiday;
  readonly type: HolidayType;

  constructor(holiday: Holiday, type: HolidayType) {
    this.holiday = holiday;
    this.type = type;
  }
}

/**
 * 三类假期各自的屏蔽开关，互不影响。
 * 对应 Android 版 `HolidayManager.BlockSettings`
 */
export class BlockSettings {
  statutory: boolean = true;
  school: boolean = true;
  weekend: boolean = false;

  constructor(statutory: boolean, school: boolean, weekend: boolean) {
    this.statutory = statutory;
    this.school = school;
    this.weekend = weekend;
  }

  anyEnabled(): boolean {
    return this.statutory || this.school || this.weekend;
  }

  /** 给 UI 用的一句话摘要 */
  summary(): string {
    if (!this.anyEnabled()) {
      return '不屏蔽';
    }
    const parts: string[] = [];
    if (this.statutory) {
      parts.push('法定节假日');
    }
    if (this.school) {
      parts.push('学校假期');
    }
    if (this.weekend) {
      parts.push('周末');
    }
    return parts.join('+');
  }
}

/** 节假日管理：合并内置 + 用户自定义，按三个开关判定是否屏蔽 */
export class HolidayManager {
  private custom: HolidayEntry[] = [];
  private syncedStatutory: HolidayEntry[] = [];
  private syncedMakeup: HolidayEntry[] = [];

  /** 设置用户自定义假期 */
  setCustom(list: HolidayEntry[]): void {
    this.custom = list;
  }

  /** 设置联网同步回来的数据（覆盖内置法定节假日） */
  setSynced(statutory: HolidayEntry[], makeup: HolidayEntry[]): void {
    this.syncedStatutory = statutory;
    this.syncedMakeup = makeup;
  }

  /** 全部假期（学校假期 + 法定节假日 + 补班日 + 自定义） */
  allHolidays(): HolidayEntry[] {
    const result: HolidayEntry[] = [];
    const school = GltuHolidays.schoolHolidays();
    for (let i = 0; i < school.length; i++) {
      result.push(new HolidayEntry(school[i], HolidayType.SCHOOL));
    }
    const statutory = this.syncedStatutory.length > 0
      ? this.syncedStatutory
      : HolidayManager.wrap(GltuHolidays.statutoryHolidays(), HolidayType.STATUTORY);
    for (let i = 0; i < statutory.length; i++) {
      result.push(statutory[i]);
    }
    const makeup = this.syncedMakeup.length > 0
      ? this.syncedMakeup
      : HolidayManager.wrap(GltuHolidays.makeupDays(), HolidayType.MAKEUP);
    for (let i = 0; i < makeup.length; i++) {
      result.push(makeup[i]);
    }
    for (let i = 0; i < this.custom.length; i++) {
      result.push(this.custom[i]);
    }
    return result;
  }

  /** 是否周末 */
  static isWeekend(date: number): boolean {
    const w = DateUtil.weekday(date);
    return w === 6 || w === 7;
  }

  /** 是否是补班日（周末但要上课） */
  isMakeupDay(date: number): boolean {
    const all = this.syncedMakeup.length > 0
      ? this.syncedMakeup
      : HolidayManager.wrap(GltuHolidays.makeupDays(), HolidayType.MAKEUP);
    for (let i = 0; i < all.length; i++) {
      if (all[i].holiday.contains(date)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 核心判定：某天是否屏蔽课程。
   * 三类开关各自独立；**补班日不受任何开关影响，一律照常上课**。
   */
  isBlocked(date: number, settings: BlockSettings): boolean {
    // 补班日优先
    if (this.isMakeupDay(date)) {
      return false;
    }
    if (settings.weekend && HolidayManager.isWeekend(date)) {
      return true;
    }
    const all = this.allHolidays();
    for (let i = 0; i < all.length; i++) {
      const e = all[i];
      if (e.type === HolidayType.MAKEUP || !e.holiday.contains(date)) {
        continue;
      }
      if (e.type === HolidayType.STATUTORY && settings.statutory) {
        return true;
      }
      if (e.type === HolidayType.SCHOOL && settings.school) {
        return true;
      }
      if (e.type === HolidayType.USER_DEFINED && settings.statutory) {
        return true;
      }
    }
    return false;
  }

  /**
   * 某天的假期名（不区分是否被屏蔽，用于展示）；非假期返回空串。
   *
   * 注意：调休（补课）规则**不在这里**，见 `data/MakeupRule.ets`。
   * 那边单向依赖本文件（`MakeupRule` 需要 `HolidayEntry` 类型），
   * 这里若反过来 import 就成环了，ArkTS 处理不好。
   */
  holidayNameOf(date: number): string {
    const all = this.allHolidays();
    for (let i = 0; i < all.length; i++) {
      const e = all[i];
      if (e.type !== HolidayType.MAKEUP && e.holiday.contains(date)) {
        return e.holiday.name;
      }
    }
    return '';
  }

  private static wrap(list: Holiday[], type: HolidayType): HolidayEntry[] {
    const r: HolidayEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      r.push(new HolidayEntry(list[i], type));
    }
    return r;
  }
}
