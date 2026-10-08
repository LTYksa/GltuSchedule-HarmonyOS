/**
 * GltuSchedule · 鸿蒙版 —— 服务卡片数据构建
 * 对应 Android：
 *   ScheduleWidgetService.ScheduleWidgetFactory.loadTodayCourses()  （行数据）
 *   ScheduleWidgetProvider.buildTitle()                             （标题）
 *
 * ⚠️ 本文件只被 EntryFormAbility（卡片提供方进程）引用，卡片 UI 不引用它，
 *    因此可以自由使用 relationalStore / preferences。
 *    卡片渲染进程读不到数据库与首选项，所有内容必须由这里算好后推过去。
 */
import { preferences, relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { DateUtil } from '../data/DateUtil';
import { GltuTimeTable } from '../data/TimeSlot';
import { Classroom } from '../data/Classroom';
import { BlockSettings, HolidayManager } from '../data/Holiday';
import { MakeupResolver } from '../data/MakeupRule';
import { Course, Semester } from '../model/Course';

/** 卡片里的一行（对应 Android 的 widget_course_item + WidgetItem） */
export interface CardCourseItem {
  /** 课程名 / 提示语 */
  name: string;
  /** "08:20–09:40 · 旅博楼 3220"（U+2013，与 Android 一致） */
  meta: string;
  /** 空串 = 不渲染这一行（= Android 的 View.GONE） */
  teacher: string;
  /** "第1-2节" */
  period: string;
  /** "#E57373" */
  color: string;
}

/** 推给卡片的数据，key 必须和卡片里 @LocalStorageProp 的名字完全一致 */
export interface CardPayload {
  title: string;
  items: CardCourseItem[];
}

const DB_NAME: string = 'gltu_schedule.db';
const PREF_NAME: string = 'gltu_prefs';
const TABLE: string = 'courses';
const GRAY: string = '#9E9E9E';                    // = Android 的 0xFF9E9E9E

const COLUMNS: string[] = [
  'id', 'name', 'teacher', 'location', 'day_of_week', 'start_index', 'end_index',
  'start_week', 'end_week', 'odd_even', 'category', 'credit', 'weeks_text', 'weeks_csv'
];

/**
 * 卡片专用调色板：与 Android `CourseColor.palette` 逐色对齐。
 * ⚠️ 鸿蒙现有 `data/CourseColor.ets` 用的是另一套更深沉的 16 色（#4E6E9E…），
 *    直接拿来当深色卡片上的**文字色**会看不清。哈希算法两边一致（都是 h*31+code），
 *    所以下标相同、只是色值不同 —— 卡片要用 Android 这套浅色（Material 300）。
 */
const CARD_PALETTE: string[] = [
  '#E57373', '#F06292', '#BA68C8', '#9575CD', '#7986CB', '#64B5F6', '#4FC3F7', '#4DD0E1',
  '#4DB6AC', '#81C784', '#AED581', '#DCE775', '#FFD54F', '#FFB74D', '#FF8A65', '#A1887F'
];

/** 按课程名取色（同名永远同色）。哈希与 Java/Kotlin 的 String.hashCode() 完全一致。 */
function cardColorOf(name: string): string {
  if (name === undefined || name === null || name.length === 0) {
    return CARD_PALETTE[0];
  }
  let h: number = 0;
  for (let i = 0; i < name.length; i++) {
    h = (h * 31 + name.charCodeAt(i)) | 0;
  }
  return CARD_PALETTE[((h % 16) + 16) % 16];
}

/**
 * 卡片提供方与主应用**同沙箱、不同进程**，内存隔离，
 * 所以这里必须自己做一次同步初始化（主进程的 StoreHolder 在这个进程里是空的）。
 */
let rdb: relationalStore.RdbStore | undefined = undefined;
let pref: preferences.Preferences | undefined = undefined;

function getPref(): preferences.Preferences {
  if (pref === undefined) {
    pref = preferences.getPreferencesSync(globalThis.getContext(), { name: PREF_NAME });
  }
  return pref;
}

function getRdb(): relationalStore.RdbStore {
  if (rdb === undefined) {
    rdb = relationalStore.getRdbStoreSync(globalThis.getContext(),
      { name: DB_NAME, securityLevel: relationalStore.SecurityLevel.S1 });
  }
  return rdb;
}

// preferences 的 getSync 返回联合类型 ValueType，ArkTS 不允许直接当基本类型用，
// 统一在这里收口（取不到就是默认值）。
function prefNumber(p: preferences.Preferences, key: string, def: number): number {
  const v: preferences.ValueType = p.getSync(key, def);
  if (typeof v === 'number') {
    return v as number;
  }
  return def;
}

function prefBool(p: preferences.Preferences, key: string, def: boolean): boolean {
  const v: preferences.ValueType = p.getSync(key, def);
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  return def;
}

function prefString(p: preferences.Preferences, key: string, def: string): string {
  const v: preferences.ValueType = p.getSync(key, def);
  if (typeof v === 'string') {
    return v as string;
  }
  return def;
}

function textOf(rs: relationalStore.ResultSet, column: string): string {
  const s: string = rs.getString(rs.getColumnIndex(column));
  return (s === undefined || s === null) ? '' : s;
}

function readWeeksCsv(rs: relationalStore.ResultSet): number[] {
  const weeks: number[] = [];
  const csv: string = textOf(rs, 'weeks_csv');
  if (csv.length === 0) {
    return weeks;
  }
  const parts: string[] = csv.split(',');
  for (let i = 0; i < parts.length; i++) {
    const n: number = parseInt(parts[i].trim(), 10);
    if (!isNaN(n) && weeks.indexOf(n) < 0) {
      weeks.push(n);
    }
  }
  weeks.sort((a: number, b: number) => a - b);
  return weeks;
}

function queryAllCourses(): Course[] {
  const list: Course[] = [];
  const p = new relationalStore.RdbPredicates(TABLE);
  p.orderByAsc('day_of_week');
  p.orderByAsc('start_index');
  const rs: relationalStore.ResultSet = getRdb().querySync(p, COLUMNS);
  while (rs.goToNextRow()) {
    const c = new Course();
    c.id = rs.getLong(rs.getColumnIndex('id'));
    c.name = textOf(rs, 'name');
    c.teacher = textOf(rs, 'teacher');
    c.location = textOf(rs, 'location');
    c.dayOfWeek = rs.getLong(rs.getColumnIndex('day_of_week'));
    c.startIndex = rs.getLong(rs.getColumnIndex('start_index'));
    c.endIndex = rs.getLong(rs.getColumnIndex('end_index'));
    c.startWeek = rs.getLong(rs.getColumnIndex('start_week'));
    c.endWeek = rs.getLong(rs.getColumnIndex('end_week'));
    c.oddEven = rs.getLong(rs.getColumnIndex('odd_even'));
    c.weeksText = textOf(rs, 'weeks_text');
    c.weeks = readWeeksCsv(rs);
    list.push(c);
  }
  rs.close();
  return list;
}

export class ScheduleCardData {

  /** 一行能放几门课：由卡片规格决定（对应 Android 里 ListView 高度决定可见行数） */
  static rowCap(dimension: number): number {
    // formInfo.FormDimension: Dimension_1_2=1, Dimension_2_2=2, Dimension_2_4=3, Dimension_4_4=4,
    //                         DIMENSION_1_1=6, DIMENSION_6_4=7
    if (dimension === 2) { return 1; }   // 2*2 ≈ Android 110×110dp
    if (dimension === 3) { return 3; }   // 2*4 ≈ Android 250×110dp
    if (dimension === 4) { return 6; }   // 4*4 ≈ Android 250×250dp
    if (dimension === 7) { return 9; }   // 6*4
    return 3;
  }

  /** 只有标题的"降级数据"：数据库/首选项读不到时用，保证 onAddForm 一定能同步返回 */
  static emptyPayload(): CardPayload {
    const today: number = DateUtil.today();
    const dateText: string = `${DateUtil.label(today)} ${DateUtil.weekdayLabel(DateUtil.weekday(today))}`;
    const items: CardCourseItem[] = [{
      name: '点击进入 App 并导入课表',
      meta: '支持手动添加 / 分享码 / 教务系统导入',
      teacher: '', period: '', color: GRAY
    }];
    return { title: dateText, items: items };
  }

  static build(context: common.Context, dimension: number): CardPayload {
    const now: Date = new Date();
    const today: number = DateUtil.today();
    // 23:30 之后卡片显示「明天」的课 —— 这个点用户基本睡了，
    // 再显示今天的课没意义；提前切成明天，第二天解锁就能直接看到。
    const display: number = ScheduleCardData.displayDate(now, today);
    const isTomorrow: boolean = display !== today;
    const dayTag: string = isTomorrow ? '明天 · ' : '';

    const p: preferences.Preferences = getPref();
    // 这里就把首选项句柄准备好：下面的读库若失败，降级数据也能拿到正确的标题
    const firstMonday: number = prefNumber(p, 'first_monday', DateUtil.mondayOf(today));

    const holiday: HolidayManager = new HolidayManager();
    const settings: BlockSettings = new BlockSettings(
      prefBool(p, 'block_statutory', true),
      prefBool(p, 'block_school', true),
      prefBool(p, 'block_weekend', false)
    );

    // ---------- 标题：等价于 ScheduleWidgetProvider.buildTitle() ----------
    // 用 display 而不是 today —— 23:30 后日期与「第 N 周」都要跟着切
    const dateText: string =
      `${DateUtil.label(display)} ${DateUtil.weekdayLabel(DateUtil.weekday(display))}`;
    const holidayName: string = holiday.holidayNameOf(display);
    const blocked: boolean = holiday.isBlocked(display, settings);
    const title: string = (holidayName.length > 0 && blocked)
      ? `${dayTag}${dateText} · ${holidayName}`
      : `第 ${Semester.weekOf(firstMonday, display)} 周 · ${dateText}`;

    // ---------- 分支①：节假日/周末屏蔽 ----------
    if (blocked) {
      const name: string = holidayName.length > 0
        ? holidayName
        : (HolidayManager.isWeekend(display) ? '周末' : '假期');
      const items: CardCourseItem[] = [{
        name: name === '周末'
          ? (isTomorrow ? '明天是周末' : '今天是周末')
          : `假期：${name}`,
        meta: '课程已屏蔽，好好休息 🎉',
        teacher: '', period: '', color: GRAY
      }];
      return { title: title, items: items };
    }

    const all: Course[] = queryAllCourses();

    // ---------- 分支②：课表为空（≈ Android 的数据源未就绪） ----------
    if (all.length === 0) {
      const items: CardCourseItem[] = [{
        name: '点击进入 App 并导入课表',
        meta: '支持手动添加 / 分享码 / 教务系统导入',
        teacher: '', period: '', color: GRAY
      }];
      return { title: title, items: items };
    }

    // ---------- 分支③：调休日 → 上"被替代那一天"的课 ----------
    // ⚠️ Android 版这里用「今天本身的星期几」查课，调休补班日会查错；
    //    鸿蒙跟随 Index.ets 的正确做法：先映射到被替代的那一天（连周次一起搬）。
    const overrides: Map<number, number> = MakeupResolver.decodeOverrides(
      prefString(p, 'makeup_overrides', ''));
    const rules = MakeupResolver.resolve(holiday.allHolidays(), overrides);
    const effDate: number = MakeupResolver.effectiveDate(rules, display);
    const effWeekday: number = DateUtil.weekday(effDate);
    const effWeek: number = Semester.weekOf(firstMonday, effDate);

    const courses: Course[] = all.filter((c: Course) =>
      c.dayOfWeek === effWeekday && c.occursOnWeek(effWeek));
    courses.sort((a: Course, b: Course) => a.startIndex - b.startIndex);

    // 顺手存下「显示日课程」，供 minutesToNextFlip 排准点闹钟时复用
    ScheduleCardData.lastCourses = courses;

    // ---------- 分支④：没有课 ----------
    if (courses.length === 0) {
      const items: CardCourseItem[] = [{
        name: isTomorrow ? '明天没有课' : '今天没有课',
        meta: '享受你的休息日', teacher: '', period: '', color: GRAY
      }];
      return { title: title, items: items };
    }

    // ---------- 分支⑤：今天的课全上完了 ----------
    // 不再罗列已结束的课，直接提示休息。（显示"明天"时不适用：那时的课还没开始）
    if (!isTomorrow && ScheduleCardData.allDone(now, courses)) {
      const items: CardCourseItem[] = [{
        name: '今天的课都上完啦', meta: '好好休息 🎉',
        teacher: '', period: '', color: GRAY
      }];
      return { title: title, items: items };
    }

    // ---------- 分支⑥：正常行 ----------
    const cap: number = ScheduleCardData.rowCap(dimension);    const items: CardCourseItem[] = [];
    const n: number = Math.min(courses.length, cap);
    for (let i = 0; i < n; i++) {
      const c: Course = courses[i];
      const start = GltuTimeTable.byIndex(c.startIndex);
      const end = GltuTimeTable.byIndex(c.endIndex);
      const time: string = (start !== undefined && end !== undefined)
        ? `${start.startTime}–${end.endTime}` : '';                 // U+2013 EN DASH
      const shortLoc: string = Classroom.shortLabel(c.location);
      const place: string = shortLoc.length > 0 ? shortLoc : '地点待定';
      const meta: string = (time.length > 0 ? `${time} · ${place}` : place);
      items.push({
        name: c.name,
        meta: meta,
        teacher: c.teacher,
        period: GltuTimeTable.rangeLabel(c.startIndex, c.endIndex),
        color: cardColorOf(c.name)
      });
    }
    return { title: title, items: items };
  }

  // ==================== 时间规则（与安卓 WidgetTiming 一一对应）====================

  /** 过了 23:30 就算第二天 */
  static readonly NEXT_DAY_HOUR: number = 23;
  static readonly NEXT_DAY_MINUTE: number = 30;

  /** 卡片当前该显示哪一天（天数序号） */
  static displayDate(now: Date, today: number): number {
    const late: boolean = now.getHours() > ScheduleCardData.NEXT_DAY_HOUR
      || (now.getHours() === ScheduleCardData.NEXT_DAY_HOUR
        && now.getMinutes() >= ScheduleCardData.NEXT_DAY_MINUTE);
    return late ? today + 1 : today;
  }

  /**
   * 「显示日」的课是否全部上完了。
   * 用最后一节课的**下课时间**判定；没课或查不到节次返回 false
   * （那种情况归"没有课"分支，不该在这里冒充"上完了"）。
   */
  static allDone(now: Date, courses: Course[]): boolean {
    if (courses.length === 0) {
      return false;
    }
    let lastEnd: number = 0;
    for (let i = 0; i < courses.length; i++) {
      if (courses[i].endIndex > lastEnd) {
        lastEnd = courses[i].endIndex;
      }
    }
    const slot = GltuTimeTable.byIndex(lastEnd);
    if (slot === undefined) {
      return false;
    }
    const hm: string = slot.endTime;              // "21:30"
    const hh: number = parseInt(hm.substring(0, 2), 10);
    const mm: number = parseInt(hm.substring(3, 5), 10);
    if (isNaN(hh) || isNaN(mm)) {
      return false;
    }
    return (now.getHours() * 60 + now.getMinutes()) >= (hh * 60 + mm);
  }

  /**
   * 距离下一次「需要准点刷新」还有多少分钟。
   * 两个准点：23:30（翻明天）和当天最后一节课下课（报休息）。
   * 供 FormExtensionAbility 调 setFormNextRefreshTime 用。
   *
   * 课程列表复用 [lastCourses]（由 `build()` 顺手存下），
   * 免得为了排个闹钟把查库、调休映射那一整套再跑一遍。
   */
  static minutesToNextFlip(now: Date): number {
    let best: number = -1;

    // ① 下一个 23:30
    const nowMin: number = now.getHours() * 60 + now.getMinutes();
    const flipMin: number = ScheduleCardData.NEXT_DAY_HOUR * 60
      + ScheduleCardData.NEXT_DAY_MINUTE;
    let toFlip: number = flipMin - nowMin;
    if (toFlip <= 0) {
      toFlip += 24 * 60;
    }
    best = toFlip;

    // ② 今天最后一节课下课（只算还没到的）
    const courses: Course[] = ScheduleCardData.lastCourses;
    if (courses.length > 0) {
      let lastEnd: number = 0;
      for (let i = 0; i < courses.length; i++) {
        if (courses[i].endIndex > lastEnd) {
          lastEnd = courses[i].endIndex;
        }
      }
      const slot = GltuTimeTable.byIndex(lastEnd);
      if (slot !== undefined) {
        const hh: number = parseInt(slot.endTime.substring(0, 2), 10);
        const mm: number = parseInt(slot.endTime.substring(3, 5), 10);
        if (!isNaN(hh) && !isNaN(mm)) {
          const toEnd: number = (hh * 60 + mm) - nowMin;
          if (toEnd > 0 && toEnd < best) {
            best = toEnd;
          }
        }
      }
    }
    return best;
  }

  /** `build()` 顺手存下的「显示日课程」，供 minutesToNextFlip 复用 */
  private static lastCourses: Course[] = [];
}
