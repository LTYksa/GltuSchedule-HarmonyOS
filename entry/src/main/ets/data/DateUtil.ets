/**
 * GltuSchedule · 鸿蒙版 —— 日期工具
 *
 * 为什么不用 Date 做运算：JS 的 Date 带时区与夏令时，跨时区/跨零点容易出错。
 * 这里把所有日期归一化成「自 1970-01-01 起的天数序号」，纯整数运算，
 * 与时区完全无关（算法来自 Howard Hinnant 的 days_from_civil）。
 */

/** 年月日 */
export class Ymd {
  readonly year: number;
  readonly month: number; // 1-12
  readonly day: number;   // 1-31

  constructor(year: number, month: number, day: number) {
    this.year = year;
    this.month = month;
    this.day = day;
  }
}

export class DateUtil {
  /** 星期几：1=周一 … 7=周日 */
  static readonly MONDAY: number = 1;
  static readonly SUNDAY: number = 7;

  /** 年月日 → 天数序号 */
  static fromYmd(y: number, m: number, d: number): number {
    const yy = m <= 2 ? y - 1 : y;
    const era = Math.floor(yy / 400);
    const yoe = yy - era * 400;
    const mp = m > 2 ? m - 3 : m + 9;
    const doy = Math.floor((153 * mp + 2) / 5) + d - 1;
    const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
    return era * 146097 + doe - 719468;
  }

  /** 天数序号 → 年月日 */
  static toYmd(n: number): Ymd {
    let z = n + 719468;
    const era = Math.floor(z / 146097);
    const doe = z - era * 146097;
    const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
    const mp = Math.floor((5 * doy + 2) / 153);
    const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
    const m = mp < 10 ? mp + 3 : mp - 9;
    return new Ymd(m <= 2 ? y + 1 : y, m, d);
  }

  /** 今天的天数序号（按设备本地时间取年月日） */
  static today(): number {
    const now = new Date();
    return DateUtil.fromYmd(now.getFullYear(), now.getMonth() + 1, now.getDate());
  }

  /** 星期几：1=周一 … 7=周日 */
  static weekday(n: number): number {
    return ((n + 3) % 7 + 7) % 7 + 1;
  }

  /** 该天所在周的周一 */
  static mondayOf(n: number): number {
    return n - (DateUtil.weekday(n) - 1);
  }

  /** "2026-10-29" */
  static key(n: number): string {
    const y = DateUtil.toYmd(n);
    return `${y.year}-${DateUtil.pad(y.month)}-${DateUtil.pad(y.day)}`;
  }

  /** "10月29日" */
  static label(n: number): string {
    const y = DateUtil.toYmd(n);
    return `${y.month}月${y.day}日`;
  }

  /** "2026/10/29" */
  static slash(n: number): string {
    const y = DateUtil.toYmd(n);
    return `${y.year}/${y.month}/${y.day}`;
  }

  /** 周一~周日的中文名 */
  static weekdayLabel(w: number): string {
    switch (w) {
      case 1: return '周一';
      case 2: return '周二';
      case 3: return '周三';
      case 4: return '周四';
      case 5: return '周五';
      case 6: return '周六';
      case 7: return '周日';
      default: return '';
    }
  }

  /** 周一~周日的单字名 */
  static weekdayShort(w: number): string {
    switch (w) {
      case 1: return '一';
      case 2: return '二';
      case 3: return '三';
      case 4: return '四';
      case 5: return '五';
      case 6: return '六';
      case 7: return '日';
      default: return '';
    }
  }

  /** 解析 "2026-10-29" / "2026/10/29" → 天数序号，失败返回 -1 */
  static parse(text: string): number {
    if (text === undefined || text === null) {
      return -1;
    }
    const m = text.trim().match(/^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
    if (m === null) {
      return -1;
    }
    return DateUtil.fromYmd(parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10));
  }

  /** 两个天数序号相差几周（向下取整） */
  static weeksBetween(from: number, to: number): number {
    return Math.floor((to - from) / 7);
  }

  private static pad(v: number): string {
    return v < 10 ? `0${v}` : `${v}`;
  }
}
