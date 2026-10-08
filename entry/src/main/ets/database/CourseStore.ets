/**
 * GltuSchedule · 鸿蒙版 —— 本地存储
 * 对应 Android 版 Room（`AppDatabase` + `CourseDao`）+ SharedPreferences
 *
 * 鸿蒙用 relationalStore（内置 SQLite）与 preferences，同样**全程本地**。
 */
import { relationalStore } from '@kit.ArkData';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Course } from '../model/Course';
import { CourseCategory } from '../data/CourseColor';

const DB_NAME: string = 'gltu_schedule.db';
const TABLE: string = 'courses';
const PREF_NAME: string = 'gltu_prefs';

const CREATE_TABLE: string = `CREATE TABLE IF NOT EXISTS ${TABLE} (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  teacher TEXT,
  location TEXT,
  day_of_week INTEGER NOT NULL,
  start_index INTEGER NOT NULL,
  end_index INTEGER NOT NULL,
  start_week INTEGER NOT NULL,
  end_week INTEGER NOT NULL,
  odd_even INTEGER NOT NULL DEFAULT 0,
  category TEXT,
  credit REAL DEFAULT -1,
  weeks_text TEXT,
  weeks_csv TEXT
)`;

export class CourseStore {
  private store: relationalStore.RdbStore | undefined = undefined;
  private pref: preferences.Preferences | undefined = undefined;

  /** 初始化数据库与首选项（在 EntryAbility 里调用一次） */
  async init(context: common.Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    this.store = await relationalStore.getRdbStore(context, config);
    await this.store.executeSql(CREATE_TABLE);
    this.pref = await preferences.getPreferences(context, PREF_NAME);
  }

  private requireStore(): relationalStore.RdbStore {
    if (this.store === undefined) {
      throw new Error('CourseStore 尚未初始化，请先调用 init()');
    }
    return this.store;
  }

  // ==================== 课程 CRUD ====================

  /** 覆盖式写入整张课表（导入用） */
  async replaceAll(courses: Course[]): Promise<void> {
    const store = this.requireStore();
    await store.executeSql(`DELETE FROM ${TABLE}`);
    for (let i = 0; i < courses.length; i++) {
      await this.insert(courses[i]);
    }
  }

  /** 追加写入（分享码导入 / 手动添加） */
  async insert(course: Course): Promise<number> {
    const store = this.requireStore();
    const bucket: relationalStore.ValuesBucket = {
      'name': course.name,
      'teacher': course.teacher,
      'location': course.location,
      'day_of_week': course.dayOfWeek,
      'start_index': course.startIndex,
      'end_index': course.endIndex,
      'start_week': course.startWeek,
      'end_week': course.endWeek,
      'odd_even': course.oddEven,
      'category': course.category,
      'credit': course.credit,
      'weeks_text': course.weeksText,
      'weeks_csv': course.weeks.length > 0 ? course.weeks.join(',') : ''
    };
    return await store.insert(TABLE, bucket);
  }

  /** 读取全部课程 */
  async loadAll(): Promise<Course[]> {
    const store = this.requireStore();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.orderByAsc('day_of_week');
    predicates.orderByAsc('start_index');
    const rs = await store.query(predicates, [
      'id', 'name', 'teacher', 'location', 'day_of_week', 'start_index', 'end_index',
      'start_week', 'end_week', 'odd_even', 'category', 'credit', 'weeks_text', 'weeks_csv'
    ]);
    const list: Course[] = [];
    while (rs.goToNextRow()) {
      list.push(CourseStore.fromResultSet(rs));
    }
    rs.close();
    return list;
  }

  /** 删除一门课 */
  async deleteById(id: number): Promise<void> {
    const store = this.requireStore();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    await store.delete(predicates);
  }

  /** 清空课表 */
  async clearAll(): Promise<void> {
    const store = this.requireStore();
    await store.executeSql(`DELETE FROM ${TABLE}`);
  }

  private static fromResultSet(rs: relationalStore.ResultSet): Course {
    const c = new Course();
    c.id = rs.getLong(rs.getColumnIndex('id'));
    c.name = rs.getString(rs.getColumnIndex('name'));
    c.teacher = rs.getString(rs.getColumnIndex('teacher'));
    c.location = rs.getString(rs.getColumnIndex('location'));
    c.dayOfWeek = rs.getLong(rs.getColumnIndex('day_of_week'));
    c.startIndex = rs.getLong(rs.getColumnIndex('start_index'));
    c.endIndex = rs.getLong(rs.getColumnIndex('end_index'));
    c.startWeek = rs.getLong(rs.getColumnIndex('start_week'));
    c.endWeek = rs.getLong(rs.getColumnIndex('end_week'));
    c.oddEven = rs.getLong(rs.getColumnIndex('odd_even'));
    const cat = rs.getString(rs.getColumnIndex('category'));
    c.category = CourseStore.toCategory(cat);
    c.credit = rs.getDouble(rs.getColumnIndex('credit'));
    c.weeksText = rs.getString(rs.getColumnIndex('weeks_text'));
    const csv = rs.getString(rs.getColumnIndex('weeks_csv'));
    if (csv !== undefined && csv !== null && csv.length > 0) {
      const parts = csv.split(',');
      const weeks: number[] = [];
      for (let i = 0; i < parts.length; i++) {
        const n = parseInt(parts[i].trim(), 10);
        if (!isNaN(n) && weeks.indexOf(n) < 0) {
          weeks.push(n);
        }
      }
      weeks.sort((a: number, b: number) => a - b);
      c.weeks = weeks;
    }
    return c;
  }

  private static toCategory(text: string): CourseCategory {
    if (text === '理论课') { return CourseCategory.THEORY; }
    if (text === '实验/实践') { return CourseCategory.LAB; }
    if (text === '体育') { return CourseCategory.SPORT; }
    if (text === '公共课') { return CourseCategory.PUBLIC; }
    if (text === '专业课') { return CourseCategory.MAJOR; }
    if (text === '选修课') { return CourseCategory.ELECTION; }
    return CourseCategory.OTHER;
  }

  // ==================== 设置项（SharedPreferences 对应物） ====================

  getString(key: string, def: string): string {
    if (this.pref === undefined) {
      return def;
    }
    const v = this.pref.getSync(key, def) as string;
    return v === undefined || v === null ? def : v;
  }

  async putString(key: string, value: string): Promise<void> {
    if (this.pref === undefined) {
      return;
    }
    await this.pref.put(key, value);
    await this.pref.flush();
  }

  getNumber(key: string, def: number): number {
    if (this.pref === undefined) {
      return def;
    }
    const v = this.pref.getSync(key, def) as number;
    return v === undefined || v === null ? def : v;
  }

  async putNumber(key: string, value: number): Promise<void> {
    if (this.pref === undefined) {
      return;
    }
    await this.pref.put(key, value);
    await this.pref.flush();
  }

  getBool(key: string, def: boolean): boolean {
    if (this.pref === undefined) {
      return def;
    }
    const v = this.pref.getSync(key, def) as boolean;
    return v === undefined || v === null ? def : v;
  }

  async putBool(key: string, value: boolean): Promise<void> {
    if (this.pref === undefined) {
      return;
    }
    await this.pref.put(key, value);
    await this.pref.flush();
  }
}

/** 全局单例（由 EntryAbility 初始化） */
export class StoreHolder {
  static readonly instance: CourseStore = new CourseStore();
}
