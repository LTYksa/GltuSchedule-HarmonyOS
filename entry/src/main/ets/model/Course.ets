/**
 * GltuSchedule · 鸿蒙版 —— 课程领域模型
 * 对应 Android 版 `com.ltyksa.gltuschedule.model.Course`
 */
import { CourseCategory } from '../data/CourseColor';
import { DateUtil } from '../data/DateUtil';

/**
 * 一门课。
 * weeks 是**显式周次集合**，用于表达教务系统里不规则的上课周次
 * （如 GLTU 的 `4-5周,8周,11-13周(单),14-16周`）；非空时优先于 startWeek/endWeek/oddEven。
 */
export class Course {
  id: number = 0;
  name: string = '';
  teacher: string = '';
  location: string = '';
  /** 1=周一 … 7=周日 */
  dayOfWeek: number = 1;
  startIndex: number = 1;
  endIndex: number = 1;
  startWeek: number = 1;
  endWeek: number = 16;
  /** 0=每周 1=单周 2=双周 */
  oddEven: number = 0;
  category: CourseCategory = CourseCategory.OTHER;
  credit: number = -1; // -1 表示无学分
  /** 原始周次文本，如 "4-5周,8周,11-13周(单)" */
  weeksText: string = '';
  /** 解析后的显式周次集合（升序去重） */
  weeks: number[] = [];

  /** 这门课在第 week 周是否要上 */
  occursOnWeek(week: number): boolean {
    if (this.weeks.length > 0) {
      return this.weeks.indexOf(week) >= 0;
    }
    if (week < this.startWeek || week > this.endWeek) {
      return false;
    }
    if (this.oddEven === 1) {
      return week % 2 === 1;
    }
    if (this.oddEven === 2) {
      return week % 2 === 0;
    }
    return true;
  }

  /** 展示用周次文本 */
  displayWeeks(): string {
    if (this.weeksText.length > 0) {
      return this.weeksText;
    }
    if (this.weeks.length > 0) {
      return `${this.weeks.join(',')}周`;
    }
    if (this.oddEven === 1) {
      return `${this.startWeek}-${this.endWeek}周(单)`;
    }
    if (this.oddEven === 2) {
      return `${this.startWeek}-${this.endWeek}周(双)`;
    }
    return `${this.startWeek}-${this.endWeek}周`;
  }

  /** 该课在上课日的具体日期（给定第一周周一的天数序号） */
  dateInWeek(firstMonday: number, week: number): number {
    return firstMonday + (week - 1) * 7 + (this.dayOfWeek - 1);
  }

  copy(): Course {
    const c = new Course();
    c.id = this.id;
    c.name = this.name;
    c.teacher = this.teacher;
    c.location = this.location;
    c.dayOfWeek = this.dayOfWeek;
    c.startIndex = this.startIndex;
    c.endIndex = this.endIndex;
    c.startWeek = this.startWeek;
    c.endWeek = this.endWeek;
    c.oddEven = this.oddEven;
    c.category = this.category;
    c.credit = this.credit;
    c.weeksText = this.weeksText;
    c.weeks = this.weeks.slice();
    return c;
  }
}

/** 周次换算（给定「第一周周一」） */
export class Semester {
  /** 某天属于第几周（早于开学返回 0 或负数） */
  static weekOf(firstMonday: number, date: number): number {
    return DateUtil.weeksBetween(DateUtil.mondayOf(firstMonday), DateUtil.mondayOf(date)) + 1;
  }

  /** 当前第几周（至少 1） */
  static currentWeek(firstMonday: number): number {
    const w = Semester.weekOf(firstMonday, DateUtil.today());
    return w < 1 ? 1 : w;
  }
}
