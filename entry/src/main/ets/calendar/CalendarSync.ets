/**
 * GltuSchedule · 鸿蒙版 —— 同步课表到系统日历
 * 对应 Android 版 `calendar/CalendarSync.kt`
 *
 * ## 与 Android 的差异
 * | | Android | 鸿蒙 |
 * |---|---|---|
 * | 能力 | `CalendarContract`（自己读写 provider） | `@kit.CalendarKit` 的 `calendarManager` |
 * | 建日历 | 无可用日历时自己建「GLTU 课表」 | 用系统默认日历（`getCalendar()`），**不新建** |
 * | 权限 | `READ_CALENDAR` / `WRITE_CALENDAR` | 同名权限，但**需运行时申请** |
 *
 * ## 调休感知
 * 课的正常日期是「第一周周一 + (W-1)*7 + (星期-1)」。若那天是调休规则的
 * **源日期**（放假、课被搬走），事件就写到调休日那天，并在描述里标注「调休补课」。
 * 另外两种「不上课」的情况要跳过：
 *   ① 名义日期本身是**调休上班日**（那天按别的星期上课 → 本课不上）
 *   ② 名义日期**放假且没有补课安排**
 * 有跳过时**不能用重复规则**，否则会凭空多出几节课。
 */
import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { Course } from '../model/Course';
import { DateUtil } from '../data/DateUtil';
import { GltuTimeTable } from '../data/TimeSlot';
import { Classroom } from '../data/Classroom';
import { MakeupRule, MakeupResolver } from '../data/MakeupRule';
import { StoreHolder } from '../database/CourseStore';

/** 事件描述前缀（用于识别本 App 写入的条目） */
const MARK: string = 'GLTU课表';

/** 日历权限 */
const PERMISSIONS: Permissions[] = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];

/** 同步结果 */
export class SyncResult {
  ok: boolean = false;
  message: string = '';
  count: number = 0;

  constructor(ok: boolean, message: string, count: number) {
    this.ok = ok;
    this.message = message;
    this.count = count;
  }
}

/** 一次上课（日期 + 是否调休补课） */
class ClassDate {
  date: number = 0;
  isMakeup: boolean = false;

  constructor(date: number, isMakeup: boolean) {
    this.date = date;
    this.isMakeup = isMakeup;
  }
}

export class CalendarSync {

  // ==================== 权限 ====================

  /** 申请日历权限；返回是否两个都拿到 */
  static async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(context, PERMISSIONS);
      const codes = result.authResults;
      if (codes === undefined || codes.length < PERMISSIONS.length) {
        return false;
      }
      for (let i = 0; i < codes.length; i++) {
        if (codes[i] !== 0) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  // ==================== 同步 ====================

  /**
   * 把整学期课表写进系统日历。
   *
   * @param courses 全部课程
   * @param firstMonday 第一周周一（天数序号）
   * @param makeupRules 调休规则（决定课被搬到哪天 / 哪天不上）
   * @param blockSettings 节假日屏蔽三开关
   */
  static async sync(
    context: common.UIAbilityContext,
    courses: Course[],
    firstMonday: number,
    makeupRules: MakeupRule[],
    isBlocked: (date: number) => boolean,
  ): Promise<SyncResult> {
    if (courses.length === 0) {
      return new SyncResult(false, '还没有课程，先导入或添加课程吧', 0);
    }

    // 调休反查表与停课集合
    const makeupOfSource: Map<number, number> = new Map<number, number>();
    const makeupDays: Set<number> = new Set<number>();
    for (let i = 0; i < makeupRules.length; i++) {
      const r = makeupRules[i];
      if (!makeupOfSource.has(r.sourceDate)) {
        makeupOfSource.set(r.sourceDate, r.date);
      }
      makeupDays.add(r.date);
    }

    let calendar: calendarManager.Calendar | undefined = undefined;
    try {
      const mgr = calendarManager.getCalendarManager(context);
      calendar = await mgr.getCalendar();
    } catch (e) {
      return new SyncResult(false, '没有找到可写入的日历账户', 0);
    }
    if (calendar === undefined) {
      return new SyncResult(false, '没有找到可写入的日历账户', 0);
    }

    // 先清掉上次同步写入的条目
    let removed = 0;
    try {
      removed = await CalendarSync.deletePrevious(calendar, firstMonday);
    } catch (e) {
      removed = 0;
    }

    let count = 0;
    for (let i = 0; i < courses.length; i++) {
      const c = courses[i];
      const slotStart = GltuTimeTable.byIndex(c.startIndex);
      const slotEnd = GltuTimeTable.byIndex(c.endIndex);
      if (slotStart === undefined || slotEnd === undefined) {
        continue;
      }
      const weeks = CalendarSync.courseWeeks(c);
      if (weeks.length === 0) {
        continue;
      }
      const dates = CalendarSync.classDatesOf(
        firstMonday, weeks, c.dayOfWeek, makeupOfSource, makeupDays, isBlocked);
      if (dates.length === 0) {
        continue;
      }

      const loc = Classroom.shortLabel(c.location);
      const baseDesc = c.teacher.length > 0
        ? `${MARK} · ${c.teacher} · ${c.displayWeeks()}`
        : `${MARK} · ${c.displayWeeks()}`;

      const shifted = dates.some((d: ClassDate) => d.isMakeup);
      const contiguous = c.oddEven === 0
        && weeks.length === (weeks[weeks.length - 1] - weeks[0] + 1)
        && dates.length === weeks.length;

      if (contiguous && !shifted) {
        // 未受调休影响 → 用「每周重复」
        const first = dates[0].date;
        const ok = await CalendarSync.addEvent(
          calendar, c.name, loc, baseDesc, first, slotStart.startTime, slotEnd.endTime, weeks.length);
        if (ok) {
          count++;
        }
      } else {
        // 单双周 / 不规则周次 / 含调休 → 逐次写入
        for (let k = 0; k < dates.length; k++) {
          const d = dates[k];
          const desc = d.isMakeup ? `${baseDesc} · 调休补课` : baseDesc;
          const ok = await CalendarSync.addEvent(
            calendar, c.name, loc, desc, d.date, slotStart.startTime, slotEnd.endTime, 0);
          if (ok) {
            count++;
          }
        }
      }
    }

    const tail = removed > 0 ? `（已清理上次同步的 ${removed} 条）` : '';
    return new SyncResult(true, `已同步 ${count} 条课程到系统日历${tail}`, count);
  }

  /** 写入一条事件；repeatCount > 0 时写「每周重复」 */
  private static async addEvent(
    calendar: calendarManager.Calendar,
    title: string,
    location: string,
    description: string,
    date: number,
    startTime: string,
    endTime: string,
    repeatCount: number,
  ): Promise<boolean> {
    const start = CalendarSync.msAt(date, startTime);
    const end = CalendarSync.msAt(date, endTime);
    if (start <= 0 || end <= start) {
      return false;
    }
    const event: calendarManager.Event = {
      type: calendarManager.EventType.NORMAL,
      title: title,
      location: { location: location },
      description: description,
      startTime: start,
      endTime: end,
      reminderTime: [10]
    };
    if (repeatCount > 1) {
      event.recurrenceRule = {
        recurrenceFrequency: calendarManager.RecurrenceFrequency.WEEKLY,
        count: repeatCount
      };
    }
    try {
      await calendar.addEvent(event);
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 清理上次同步写入的条目。
   *
   * Android 用 `DESCRIPTION LIKE 'GLTU课表%'` 批量删；鸿蒙的 `EventFilter` 表达能力有限，
   * 改成**按时间范围取回来再逐条比对描述前缀**，只删本 App 写的。
   */
  private static async deletePrevious(
    calendar: calendarManager.Calendar,
    firstMonday: number,
  ): Promise<number> {
    try {
      // 注意：EventFilter 只能用**静态工厂方法**构造（filterById / filterByTime / filterByTitle），
      // 它没有公开的实例字段，不能 `new EventFilter()` 后赋值。
      const filter = calendarManager.EventFilter.filterByTime(
        CalendarSync.msAt(firstMonday - 30, '00:00'),
        CalendarSync.msAt(firstMonday + 400, '23:59'),
      );
      const events = await calendar.getEvents(filter, ['id', 'description']);
      let n = 0;
      for (let i = 0; i < events.length; i++) {
        const e = events[i];
        const desc = e.description;
        if (desc === undefined || desc.indexOf(MARK) !== 0) {
          continue;
        }
        const id = e.id;
        if (id === undefined) {
          continue;
        }
        try {
          await calendar.deleteEvent(id);
          n++;
        } catch (err) {
          // 单条删除失败不影响整体
        }
      }
      return n;
    } catch (e) {
      return 0;
    }
  }

  // ==================== 日期映射（纯函数，与 Android 版逐行对应）====================

  /**
   * 一门课每一周**实际写进日历的上课日**。
   *
   * ① 命中调休反查表（那天放假、课被搬走）→ 写到调休日，标记 true
   * ② 名义日期本身是调休上班日（那天按别的星期上课）→ 本课不上，跳过
   * ③ 名义日期放假且无补课安排 → 本课不上，跳过
   *
   * 因此返回列表**可能比 weeks 短**；调用方据此决定能否用重复规则。
   */
  static classDatesOf(
    firstMonday: number,
    weeks: number[],
    dayOfWeek: number,
    makeupOfSource: Map<number, number>,
    makeupDays: Set<number>,
    isBlocked: (date: number) => boolean,
  ): ClassDate[] {
    const out: ClassDate[] = [];
    for (let i = 0; i < weeks.length; i++) {
      const nominal = firstMonday + (weeks[i] - 1) * 7 + (dayOfWeek - 1);
      const makeupDate = makeupOfSource.get(nominal);
      if (makeupDate !== undefined) {
        out.push(new ClassDate(makeupDate, true));
        continue;
      }
      if (makeupDays.has(nominal)) {
        continue;
      }
      if (isBlocked(nominal)) {
        continue;
      }
      out.push(new ClassDate(nominal, false));
    }
    return out;
  }

  /** 一门课实际要上的周次（显式集合优先，否则按起止周 + 单双周展开） */
  private static courseWeeks(c: Course): number[] {
    if (c.weeks.length > 0) {
      return c.weeks.slice().sort((a: number, b: number) => a - b);
    }
    const lo = Math.max(1, Math.min(c.startWeek, c.endWeek));
    const hi = Math.min(30, Math.max(c.startWeek, c.endWeek));
    const out: number[] = [];
    for (let w = lo; w <= hi; w++) {
      if (c.oddEven === 1 && w % 2 !== 1) {
        continue;
      }
      if (c.oddEven === 2 && w % 2 !== 0) {
        continue;
      }
      out.push(w);
    }
    return out;
  }

  /** 某天的 HH:mm 对应的毫秒时间戳 */
  private static msAt(date: number, time: string): number {
    const y = DateUtil.toYmd(date);
    const hh = parseInt(time.substring(0, 2), 10);
    const mm = parseInt(time.substring(3, 5), 10);
    const d = new Date(y.year, y.month - 1, y.day, isNaN(hh) ? 0 : hh, isNaN(mm) ? 0 : mm, 0, 0);
    return d.getTime();
  }
}
