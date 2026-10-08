/**
 * GltuSchedule · 鸿蒙版 —— 调休（补课）规则推导
 * 对应 Android 版 `com.ltyksa.gltuschedule.data.MakeupRule`
 *
 * 背景：国务院办公厅的放假通知只说「10月11日（星期六）上班」，
 * **不会**说这天补周几的课 ——「补周三」是学校另行通知的。
 * 所以软件只能按历年惯例推导，并允许用户手动覆盖。
 *
 * 推导规则（已用 2025 春节/劳动节/国庆 三组实际通知验证）：
 *   假期区间内被占用的「工作日」，从区间**末尾**往前取 N 个，
 *   N = 关联到该区间的调休日数量；调休日按时间顺序与它们一一对应。
 *
 *   国庆 10/1–10/8 放假，调休 9/28(日) 与 10/11(六)
 *     区间内工作日 = 10/1三 10/2四 10/3五 10/6一 10/7二 10/8三
 *     取末尾 2 个 → [10/7(二), 10/8(三)]
 *     9/28 → 补 10/7，10/11 → 补 10/8
 *
 * **关联方式：优先按「假期名」匹配，其次才按日期邻近。**
 * 原因：GLTU 的寒假（1/18–2/23）会把春节（1/28–2/4）整个包住，
 * 两块在日期上连成一片；只按邻近关联的话，春节的补班日会被错配到寒假块上。
 *
 * **调休日代替的是「具体某一天」，连周次一起搬**：
 * 9/28 在第 4 周、10/7 在第 6 周，补的是第 6 周周二的课，
 * 而不是第 4 周周二的课（那天的课本来就正常上过了）。
 *
 * 实现说明：鸿蒙侧日期一律用 `DateUtil` 的「天数序号」（number），
 * 所以天数的加减就是整数运算，比 Android 的 LocalDate 更直接。
 */
import { DateUtil } from './DateUtil';
import { HolidayEntry, HolidayType } from './Holiday';

/** 一条调休规则：调休上班日 [date] 上 [sourceDate] 那天的课 */
export class MakeupRule {
  /** 调休上班日（天数序号） */
  readonly date: number;
  /** 它代替的那一天（天数序号） */
  readonly sourceDate: number;
  /** 是否由用户手动指定（false = 自动推导） */
  readonly manual: boolean;

  constructor(date: number, sourceDate: number, manual: boolean) {
    this.date = date;
    this.sourceDate = sourceDate;
    this.manual = manual;
  }

  /** 补的是周几（1=周一 … 7=周日） */
  sourceWeekday(): number {
    return DateUtil.weekday(this.sourceDate);
  }

  /** 摘要文本，如「补 10/7（周二）的课」 */
  summary(): string {
    const s = DateUtil.toYmd(this.sourceDate);
    return `补 ${s.month}/${s.day}（${DateUtil.weekdayLabel(this.sourceWeekday())}）的课`;
  }
}

/** 一个假期区间（同名假期合并后按连续日期切块） */
class Block {
  name: string = '';
  dates: number[] = [];

  constructor(name: string, dates: number[]) {
    this.name = name;
    this.dates = dates;
  }

  first(): number {
    return this.dates[0];
  }

  last(): number {
    return this.dates[this.dates.length - 1];
  }

  /** 区间内被占用的工作日（周一~周五） */
  workdays(): number[] {
    return this.dates.filter((d: number) => !MakeupResolver.isWeekendDay(d));
  }
}

export class MakeupResolver {
  /** 按日期邻近兜底关联时，调休日与假期区间的最大距离（天） */
  private static readonly NEAR_DAYS: number = 7;

  /**
   * 按名字关联时的最大距离（天）。
   * 真实数据里补班日离假期很近（春节 1/26 与区间 1/28 差 2 天，2/8 与 2/4 差 4 天），
   * 放宽到 21 天既能过滤掉明显异常的数据，又不会误伤真实安排。
   */
  private static readonly NAME_NEAR_DAYS: number = 21;

  static isWeekendDay(d: number): boolean {
    const w = DateUtil.weekday(d);
    return w === 6 || w === 7;
  }

  /**
   * 推导全部调休规则。
   * @param holidays 全部假期（含 MAKEUP 补班日）
   * @param overrides 用户手动覆盖：调休日 → 要补的星期（1..7）
   */
  static resolve(holidays: HolidayEntry[], overrides: Map<number, number>): MakeupRule[] {
    const blocks: Block[] = MakeupResolver.buildBlocks(holidays);
    const makeupHolidays: HolidayEntry[] =
      holidays.filter((h: HolidayEntry) => h.type === HolidayType.MAKEUP);

    // 调休日 → 源日期
    const assigned: Map<number, number> = new Map<number, number>();

    // ① 按假期名关联（主路径）
    const makeupByName: Map<string, number[]> = new Map<string, number[]>();
    for (let i = 0; i < makeupHolidays.length; i++) {
      const h = makeupHolidays[i];
      let list = makeupByName.get(h.holiday.name);
      if (list === undefined) {
        list = [];
        makeupByName.set(h.holiday.name, list);
      }
      const days = MakeupResolver.expand(h.holiday.start, h.holiday.end);
      for (let k = 0; k < days.length; k++) {
        if (list.indexOf(days[k]) < 0) {
          list.push(days[k]);
        }
      }
    }

    makeupByName.forEach((dates: number[], name: string) => {
      // 同名、且距离在阈值内的区间里，取最近的
      let block: Block | undefined = undefined;
      let best = -1;
      for (let i = 0; i < blocks.length; i++) {
        const b = blocks[i];
        if (!MakeupResolver.nameMatches(b.name, name)) {
          continue;
        }
        const dist = MakeupResolver.distanceToBlock(b, dates);
        if (dist > MakeupResolver.NAME_NEAR_DAYS) {
          continue;
        }
        if (best < 0 || dist < best) {
          best = dist;
          block = b;
        }
      }
      if (block === undefined) {
        return;
      }
      const workdays = block.workdays();
      if (workdays.length === 0) {
        return;
      }
      const sorted = dates.slice().sort((a: number, b: number) => a - b);
      const n = Math.min(sorted.length, workdays.length);
      const sources = workdays.slice(workdays.length - n);
      for (let i = 0; i < n; i++) {
        assigned.set(sorted[i], sources[i]);
      }
    });

    // ② 名字匹配不上的调休日 → 按日期邻近兜底
    for (let i = 0; i < makeupHolidays.length; i++) {
      const h = makeupHolidays[i];
      const days = MakeupResolver.expand(h.holiday.start, h.holiday.end);
      for (let k = 0; k < days.length; k++) {
        const d = days[k];
        if (assigned.has(d)) {
          continue;
        }
        let block: Block | undefined = undefined;
        let best = -1;
        for (let j = 0; j < blocks.length; j++) {
          const dist = MakeupResolver.distanceToBlock(blocks[j], [d]);
          if (best < 0 || dist < best) {
            best = dist;
            block = blocks[j];
          }
        }
        if (block === undefined || best > MakeupResolver.NEAR_DAYS) {
          continue;
        }
        const workdays = block.workdays();
        if (workdays.length === 0) {
          continue;
        }
        assigned.set(d, workdays[workdays.length - 1]);
      }
    }

    // ③ 手动覆盖优先级最高
    overrides.forEach((weekday: number, date: number) => {
      assigned.set(date, MakeupResolver.sourceFor(date, weekday, blocks));
    });

    const out: MakeupRule[] = [];
    assigned.forEach((source: number, date: number) => {
      out.push(new MakeupRule(date, source, overrides.has(date)));
    });
    out.sort((a: MakeupRule, b: MakeupRule) => a.date - b.date);
    return out;
  }

  /**
   * 给定调休日与目标星期，找出具体的源日期。
   * 优先在最近的假期区间里找同星期的那天；找不到就取**该调休日所在周**的对应星期。
   */
  private static sourceFor(date: number, weekday: number, blocks: Block[]): number {
    let block: Block | undefined = undefined;
    let best = -1;
    for (let j = 0; j < blocks.length; j++) {
      const dist = MakeupResolver.distanceToBlock(blocks[j], [date]);
      if (best < 0 || dist < best) {
        best = dist;
        block = blocks[j];
      }
    }
    if (block !== undefined) {
      // 区间内最后一个同星期的日子
      for (let i = block.dates.length - 1; i >= 0; i--) {
        if (DateUtil.weekday(block.dates[i]) === weekday) {
          return block.dates[i];
        }
      }
    }
    // 兜底：该调休日所在周的对应星期（10/11 周六 + 周三 → 10/8）
    const monday = date - (DateUtil.weekday(date) - 1);
    return monday + (weekday - 1);
  }

  /** 假期名是否匹配（同名或互相包含：「国庆节」与「国庆节后补班」） */
  private static nameMatches(blockName: string, makeupName: string): boolean {
    if (blockName.length === 0 || makeupName.length === 0) {
      return false;
    }
    return blockName === makeupName
      || blockName.indexOf(makeupName) >= 0
      || makeupName.indexOf(blockName) >= 0;
  }

  /** 调休日到区间的最短距离（落区间内为 0） */
  private static distanceToBlock(block: Block, dates: number[]): number {
    let min = -1;
    for (let i = 0; i < dates.length; i++) {
      const d = dates[i];
      let dist = 0;
      if (d < block.first()) {
        dist = block.first() - d;
      } else if (d > block.last()) {
        dist = d - block.last();
      }
      if (min < 0 || dist < min) {
        min = dist;
      }
    }
    return min < 0 ? 0 : min;
  }

  /** 把假期切成区间：同名假期合并，连续的日期算一块 */
  private static buildBlocks(holidays: HolidayEntry[]): Block[] {
    const byName: Map<string, number[]> = new Map<string, number[]>();
    for (let i = 0; i < holidays.length; i++) {
      const h = holidays[i];
      if (h.type === HolidayType.MAKEUP) {
        continue;
      }
      let days = byName.get(h.holiday.name);
      if (days === undefined) {
        days = [];
        byName.set(h.holiday.name, days);
      }
      const part = MakeupResolver.expand(h.holiday.start, h.holiday.end);
      for (let k = 0; k < part.length; k++) {
        if (days.indexOf(part[k]) < 0) {
          days.push(part[k]);
        }
      }
    }

    const out: Block[] = [];
    byName.forEach((days: number[], name: string) => {
      const sorted = days.slice().sort((a: number, b: number) => a - b);
      let current: number[] = [];
      for (let i = 0; i < sorted.length; i++) {
        const d = sorted[i];
        if (current.length === 0 || d - current[current.length - 1] === 1) {
          current.push(d);
        } else {
          out.push(new Block(name, current));
          current = [];
          current.push(d);
        }
      }
      if (current.length > 0) {
        out.push(new Block(name, current));
      }
    });
    return out;
  }

  /** 展开成一个假期占用的所有日期（闭区间，天数序号） */
  private static expand(start: number, end: number): number[] {
    const out: number[] = [];
    let guard = 0;
    for (let d = start; d <= end && guard < 400; d++) {
      out.push(d);
      guard++;
    }
    return out;
  }

  // ==================== 对外便捷接口（避免 Holiday.ets 反向依赖造成循环 import）====================

  /** 调休日 → 规则 的映射 */
  static byDate(rules: MakeupRule[]): Map<number, MakeupRule> {
    const out: Map<number, MakeupRule> = new Map<number, MakeupRule>();
    for (let i = 0; i < rules.length; i++) {
      out.set(rules[i].date, rules[i]);
    }
    return out;
  }

  /**
   * 某天实际要上「哪一天」的课。
   * 调休日返回它代替的那一天；普通日子返回它自己。
   */
  static effectiveDate(rules: MakeupRule[], date: number): number {
    for (let i = 0; i < rules.length; i++) {
      if (rules[i].date === date) {
        return rules[i].sourceDate;
      }
    }
    return date;
  }

  // ==================== 手动覆盖的持久化编解码 ====================
  // 存储格式：`日期序号:星期;日期序号:星期`（如 `20734:3;20747:7`）

  static encodeOverrides(map: Map<number, number>): string {
    const parts: string[] = [];
    map.forEach((weekday: number, date: number) => {
      parts.push(`${date}:${weekday}`);
    });
    return parts.join(';');
  }

  static decodeOverrides(raw: string): Map<number, number> {
    const out: Map<number, number> = new Map<number, number>();
    if (raw === undefined || raw === null || raw.length === 0) {
      return out;
    }
    const parts = raw.split(';');
    for (let i = 0; i < parts.length; i++) {
      const seg = parts[i].split(':');
      if (seg.length < 2) {
        continue;
      }
      const d = parseInt(seg[0], 10);
      const w = parseInt(seg[1], 10);
      if (isNaN(d) || isNaN(w) || w < 1 || w > 7) {
        continue;
      }
      out.set(d, w);
    }
    return out;
  }
}
