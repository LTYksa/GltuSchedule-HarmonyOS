/**
 * GltuSchedule · 鸿蒙版 —— 周次文本解析
 * 对应 Android 版 `WebTimetableParser.parseWeekSet`（Kotlin 原文见技术报告 §6）
 *
 * 教务系统的周次写法很野，必须准确展开成显式集合：
 *   "4-5周,8周,11-13周(单),14-16周"  →  [4,5,8,11,13,14,15,16]
 *   "1-16周"                          →  [1..16]
 *   "1-16周(双周)"                    →  [2,4,6,8,10,12,14,16]
 *   "第3,5,7周"                       →  [3,5,7]
 *
 * 相对 Kotlin 原版的修正（技术报告 §13-B1 / §13-B2，标准输入行为不变）：
 *   - B1：Kotlin 只按 `, ， 、 ; ；` 切段，"4-5周 8周" 会丢掉 8周。这里把空白也当分隔符
 *     （先把"周"两侧、区间运算符两侧的空白归一，保证 "(单)" 不会跟区间被拆开）；
 *   - B2：Kotlin 的单值分支不看"单/双"标记（"7周(双)" 会被加上），这里两个分支都过滤。
 */

/** 周次区间推断结果 */
export class WeekRange {
  startWeek: number = 1;
  endWeek: number = 16;
  /** 0=每周 1=单周 2=双周 */
  oddEven: number = 0;
}

/** 段内周次区间：`4-5` / `4 ~ 5` / `4至5` ...（非全局，取第一个匹配用） */
const WEEK_SEG_RANGE: RegExp = /(\d{1,2})[ \t\n\v\f\r]*[~\-—－至][ \t\n\v\f\r]*(\d{1,2})/g;
/** 段内首个 1-2 位数 */
const WEEK_SEG_NUMBER: RegExp = /(\d{1,2})/g;

export class WeekParser {
  /**
   * 把周次文本解析成显式周次集合（升序、去重、限定 1..30）。
   * 解析不出来返回空数组。
   */
  static parse(text: string): number[] {
    const out: number[] = [];
    if (text === undefined || text === null || WeekParser.isBlank(text)) {
      return out;
    }

    // 兼容调用方直接传 "周数：4-5周,8周" 这类带标签的文本（Kotlin 收到的是标签后的值）
    let s: string = text.replace(/^[^：:]*[：:]/, ' ');

    // 归一空白，避免把同一个周次表达式拆散：
    //   "4 - 5 周(单)" → "4-5周(单)"；"1-16 周 (单)" → "1-16周(单)"
    s = s.replace(/(\d)[ \t\n\v\f\r]*([~\-—－至])[ \t\n\v\f\r]*(\d)/g, '$1$2$3');
    s = s.replace(/[ \t\n\v\f\r]+周/g, '周');
    s = s.replace(/周[ \t\n\v\f\r]*([（(])/g, '周$1');

    // 分隔符：Kotlin 是 `, ， 、 ; ；`，这里额外把空白当分隔符（修 §13-B1）
    const segs: string[] = s.split(/[,，、;； \t\n\v\f\r]+/);

    for (let i = 0; i < segs.length; i++) {
      const seg: string = segs[i].trim();
      if (seg.length === 0) {
        continue;
      }
      const odd: boolean = seg.indexOf('单') >= 0;
      const even: boolean = seg.indexOf('双') >= 0;

      // 区间分支（段内第一个区间）
      let rangeStart: number = -1;
      let rangeEnd: number = -1;
      WEEK_SEG_RANGE.lastIndex = 0;
      seg.replace(WEEK_SEG_RANGE, (m: string, g1: string, g2: string): string => {
        if (rangeStart < 0) {
          const a: number = parseInt(g1, 10);
          const b: number = parseInt(g2, 10);
          if (!isNaN(a) && !isNaN(b)) {
            rangeStart = Math.min(a, b);
            rangeEnd = Math.max(a, b);
          }
        }
        return m;
      });
      WEEK_SEG_RANGE.lastIndex = 0;

      if (rangeStart >= 0) {
        for (let w = rangeStart; w <= rangeEnd; w++) {
          if (odd && w % 2 === 0) {
            continue;
          }
          if (even && w % 2 === 1) {
            continue;
          }
          if (w >= 1 && w <= 30) {
            WeekParser.push(out, w);
          }
        }
        continue;
      }

      // 单值分支：段内第一个 1-2 位数（"1,3,5周" 切开后各段各取一个）
      let value: number = -1;
      WEEK_SEG_NUMBER.lastIndex = 0;
      seg.replace(WEEK_SEG_NUMBER, (m: string, g1: string): string => {
        if (value < 0) {
          const n: number = parseInt(g1, 10);
          if (!isNaN(n)) {
            value = n;
          }
        }
        return m;
      });
      WEEK_SEG_NUMBER.lastIndex = 0;
      if (value < 0) {
        continue;
      }
      // 修 §13-B2：单值分支同样要过"单/双"过滤（Kotlin 漏了这一步）
      if (odd && value % 2 === 0) {
        continue;
      }
      if (even && value % 2 === 1) {
        continue;
      }
      if (value >= 1 && value <= 30) {
        WeekParser.push(out, value);
      }
    }

    out.sort((a: number, b: number): number => a - b);
    return out;
  }

  /** 由显式周次集合反推 startWeek / endWeek / oddEven（编辑表单回填用） */
  static inferRange(weeks: number[]): WeekRange {
    const r = new WeekRange();
    if (weeks.length === 0) {
      return r;
    }
    r.startWeek = weeks[0];
    r.endWeek = weeks[weeks.length - 1];
    // 判断是否全单/全双
    let allOdd = true;
    let allEven = true;
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i] % 2 === 0) {
        allOdd = false;
      } else {
        allEven = false;
      }
    }
    // 必须"集合恰好等于区间内的全部单/双周"才算单双周，避免误判。
    //
    // ⚠️ 这里**不能**用 `Math.ceil(span/2)` / `Math.floor(span/2)` 估算 ——
    // 那种写法假设区间从奇数周开始。区间起点是偶数时会数错：
    // `[2,4,6,8]` 在 2..8 里有 4 个双周，而 floor(7/2) = 3，于是被误判成"每周"。
    // 所以老老实实数一遍区间内的单/双周个数。
    let oddCount = 0;
    let evenCount = 0;
    for (let w = r.startWeek; w <= r.endWeek; w++) {
      if (w % 2 === 1) {
        oddCount++;
      } else {
        evenCount++;
      }
    }
    if (allOdd && weeks.length === oddCount) {
      r.oddEven = 1;
    } else if (allEven && weeks.length === evenCount) {
      r.oddEven = 2;
    } else {
      r.oddEven = 0;
    }
    return r;
  }

  /** 周次集合 → "4-5,8,11-13,14-16 周" 这样的紧凑文本 */
  static format(weeks: number[]): string {
    if (weeks.length === 0) {
      return '';
    }
    const parts: string[] = [];
    let start = weeks[0];
    let prev = weeks[0];
    for (let i = 1; i < weeks.length; i++) {
      const w = weeks[i];
      if (w === prev + 1) {
        prev = w;
        continue;
      }
      parts.push(start === prev ? `${start}` : `${start}-${prev}`);
      start = w;
      prev = w;
    }
    parts.push(start === prev ? `${start}` : `${start}-${prev}`);
    return `${parts.join(',')}周`;
  }

  private static push(list: number[], w: number): void {
    if (list.indexOf(w) < 0) {
      list.push(w);
    }
  }

  /** Kotlin 的 String.isBlank()：全空白（含 \u00a0）算空 */
  private static isBlank(s: string): boolean {
    if (s.length === 0) {
      return true;
    }
    return /^[\s\u0085\u001c-\u001f]*$/.test(s);
  }
}
