/**
 * GltuSchedule · 鸿蒙版 —— 课表分享码（超级课程表式"课程格子"互传）
 * 对应 Android 版 `com.ltyksa.gltuschedule.share.CourseShare`
 *
 * 与 Android 版**逐字节互通**：同样的魔术字 `GLTU-SCHEDULE`、同样的短名字段、
 * 同样的标准 Base64（RFC 4648 basic，带 `=` 填充、非 URL-safe）。
 * 全程本地：导出为一段 Base64 分享码，同学之间可复制粘贴导入；不经过任何服务器。
 *
 * ⚠️ 只做逻辑，不含 UI；界面见 `pages/SharePage.ets`。
 */
import { util } from '@kit.ArkTS';
import { Course } from '../model/Course';
import { CourseColor } from '../data/CourseColor';

/** 分享码魔术字（必须与 Android 版逐字一致） */
const MAGIC: string = 'GLTU-SCHEDULE';
/** 分享码格式版本。v1 = 只有起止周；v2 = 增加显式周次集合 / 原始周次文本 / 学分。 */
const VERSION: number = 2;
/** 标准 Base64 字符集（basic：`+` `/` 与 `=` 填充；**不接受** URL-safe 的 `-` `_`） */
const BASE64_CHARS: RegExp = /^[A-Za-z0-9+/=]+$/;
/** 显式周次集合的取值范围（与 Android 版一致） */
const WEEK_MIN: number = 1;
const WEEK_MAX: number = 30;

/**
 * 导出用的课程对象（短名字段）。
 * 字段声明顺序 = Android 版 `JSONObject.put` 顺序，保证 `JSON.stringify` 出来的
 * 键序与 Android 版一致（便于人眼比对，Android 端解析并不依赖键序）。
 */
class ShareCourseJson {
  n: string = '';
  t: string = '';
  l: string = '';
  d: number = 1;
  s: number = 1;
  e: number = 1;
  sw: number = 1;
  ew: number = 16;
  o: number = 0;
  /** 显式周次集合，逗号连接；仅非空才带 */
  w?: string;
  /** 原始周次文本；仅非空才带 */
  wt?: string;
  /** 学分；仅非 null（鸿蒙版用 -1 当"无学分"）才带 */
  cr?: number;
}

/** 导出用的根对象 */
class ShareRootJson {
  app: string = MAGIC;
  v: number = VERSION;
  c: ShareCourseJson[] = [];
}

/**
 * 导入时的原始课程对象。
 * JSON 里的值可能是 string / number / boolean / null / 缺失，故一律按宽类型收，
 * 由 `jsonStr` / `jsonNum` / `jsonInt` 做与 org.json `optString` / `optInt` 等价的容错。
 */
interface ShareCourseRaw {
  n?: string | number | boolean | null;
  t?: string | number | boolean | null;
  l?: string | number | boolean | null;
  d?: string | number | boolean | null;
  s?: string | number | boolean | null;
  e?: string | number | boolean | null;
  sw?: string | number | boolean | null;
  ew?: string | number | boolean | null;
  o?: string | number | boolean | null;
  w?: string | number | boolean | null;
  wt?: string | number | boolean | null;
  cr?: string | number | boolean | null;
}

/** 导入时的根对象 */
interface ShareRootRaw {
  app?: string | number | boolean | null;
  v?: string | number | boolean | null;
  c?: ShareCourseRaw[];
}

/** 等价的 org.json `JSON.toString()`：缺失 / null → ""，其余转字符串 */
function jsonStr(v: string | number | boolean | null | undefined): string {
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v;
  }
  if (typeof v === 'number') {
    return `${v}`;
  }
  return v === true ? 'true' : 'false';
}

/** 等价的 org.json `JSON.toDouble()`：转不出来就返回 def（Android 用 Double.NaN 表示失败） */
function jsonNum(v: string | number | boolean | null | undefined, def: number): number {
  if (v === undefined || v === null) {
    return def;
  }
  if (typeof v === 'number') {
    return isNaN(v) ? def : v;
  }
  if (typeof v === 'boolean') {
    return v ? 1 : 0;
  }
  const text: string = v.trim();
  if (text.length === 0) {
    return def;
  }
  const n: number = Number(text);
  return isNaN(n) ? def : n;
}

/** 等价的 org.json `JSON.toInteger()`：字符串按 double 解析后取整 */
function jsonInt(v: string | number | boolean | null | undefined, def: number): number {
  const n: number = jsonNum(v, def);
  return isNaN(n) ? def : Math.trunc(n);
}

/** 夹取到 [lo, hi]（NaN → lo） */
function clampInt(v: number, lo: number, hi: number): number {
  if (isNaN(v)) {
    return lo;
  }
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return Math.trunc(v);
}

/** Kotlin `String.toIntOrNull()` 的等价物：整串必须都是（带符号的）十进制数字，否则 NaN */
function strictInt(text: string): number {
  const t: string = text.trim();
  if (t.length === 0) {
    return Number.NaN;
  }
  if (!/^[+-]?[0-9]+$/.test(t)) {
    return Number.NaN;
  }
  const n: number = parseInt(t, 10);
  return isNaN(n) ? Number.NaN : n;
}

/** 异常 → 文案（对应 Kotlin 的 `e.message ?: e.javaClass.simpleName`） */
function errorText(err: Error): string {
  if (err !== undefined && err !== null) {
    const m: string = err.message;
    if (m !== undefined && m !== null && m.length > 0) {
      return m;
    }
    const n: string = err.name;
    if (n !== undefined && n !== null && n.length > 0) {
      return n;
    }
  }
  return 'Error';
}

/** `w` 字段 → 显式周次集合（1..30 过滤 + 去重 + 升序） */
function parseWeeks(text: string): number[] {
  const result: number[] = [];
  if (text.length === 0) {
    return result;
  }
  const parts: string[] = text.split(',');
  for (let i = 0; i < parts.length; i++) {
    const n: number = strictInt(parts[i]);
    if (isNaN(n)) {
      continue;
    }
    if (n < WEEK_MIN || n > WEEK_MAX) {
      continue;
    }
    if (result.indexOf(n) < 0) {
      result.push(n);
    }
  }
  result.sort((a: number, b: number): number => a - b);
  return result;
}

/** 导出时的周次集合 → `"4,5,8,11"`（去重 + 升序） */
function joinWeeks(weeks: number[]): string {
  const sorted: number[] = weeks.slice();
  sorted.sort((a: number, b: number): number => a - b);
  const uniq: number[] = [];
  for (let i = 0; i < sorted.length; i++) {
    if (uniq.indexOf(sorted[i]) < 0) {
      uniq.push(sorted[i]);
    }
  }
  const parts: string[] = [];
  for (let i = 0; i < uniq.length; i++) {
    parts.push(`${uniq[i]}`);
  }
  return parts.join(',');
}

/** 一篇分享码的编解码器（纯逻辑） */
export class CourseShare {
  /**
   * 最近一次 `import` 的失败原因；
   * 成功（或还没调用过）时为空串 —— 对应 Android 版的 `lastError = null`。
   */
  static lastError: string = '';

  /** 标准 Base64 编解码器：`util.Type.BASIC` = RFC 4648 basic，带 `=` 填充、无换行 */
  private static readonly codec: util.Base64Helper = new util.Base64Helper();

  /**
   * 导出分享码：JSON → 标准 Base64（无换行），可直接微信/QQ 发给同学。
   * JSON 字段做了短名压缩，避免分享码过长。
   *
   * 注意：**必须带上 `w`（显式周次集合）**。
   * 只带 startWeek/endWeek 的话，像 `4-5周,8周,11-13周(单)` 这种不规则周次
   * 到了对方那边会变成连续的 4-16 周，凭空多出好几周的课。
   */
  static export(courses: Course[]): string {
    const list: ShareCourseJson[] = [];
    for (let i = 0; i < courses.length; i++) {
      const c: Course = courses[i];
      const o: ShareCourseJson = new ShareCourseJson();
      o.n = c.name;
      o.t = c.teacher;
      o.l = c.location;
      o.d = c.dayOfWeek;
      o.s = c.startIndex;
      o.e = c.endIndex;
      o.sw = c.startWeek;
      o.ew = c.endWeek;
      o.o = c.oddEven;
      if (c.weeks.length > 0) {
        o.w = joinWeeks(c.weeks);
      }
      if (c.weeksText.trim().length > 0) {
        o.wt = c.weeksText;
      }
      if (c.credit >= 0) {
        o.cr = c.credit;
      }
      list.push(o);
    }
    const root: ShareRootJson = new ShareRootJson();
    root.c = list;
    const json: string = JSON.stringify(root);
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(json);
    return CourseShare.codec.encodeToStringSync(bytes, util.Type.BASIC);
  }

  /**
   * 导入分享码。失败返回 `undefined`，并给出 [lastError] 便于提示用户。
   * 支持容错：用户粘贴时可能带空格/换行；也兼容 v1 的老分享码。
   */
  static import(code: string): Course[] | undefined {
    CourseShare.lastError = '';
    const cleaned: string = code.trim().replace(/\s/g, '');
    if (cleaned.length === 0) {
      CourseShare.lastError = '分享码为空';
      return undefined;
    }

    // ① Base64 解码（basic 解码器，不接受 URL-safe 的 `-` `_`）
    let bytes: Uint8Array = new Uint8Array(0);
    try {
      if (!BASE64_CHARS.test(cleaned)) {
        throw new Error('invalid base64 characters');
      }
      bytes = CourseShare.codec.decodeSync(cleaned, util.Type.BASIC);
      if (bytes.length === 0) {
        throw new Error('empty base64 payload');
      }
    } catch (e) {
      CourseShare.lastError = '分享码格式不正确（不是有效的分享码）';
      return undefined;
    }

    // ② UTF-8 解码
    let jsonText: string = '';
    try {
      jsonText = util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (e) {
      jsonText = '';
    }

    // ③ JSON → Course[]
    try {
      const root: ShareRootRaw = JSON.parse(jsonText) as ShareRootRaw;
      if (root === undefined || root === null || jsonStr(root.app) !== MAGIC) {
        CourseShare.lastError = '这不是 GLTU 课表的分享码';
        return undefined;
      }
      const result: Course[] = [];
      const arr: ShareCourseRaw[] | undefined = root.c;
      if (arr !== undefined && arr !== null && Array.isArray(arr)) {
        for (let i = 0; i < arr.length; i++) {
          const course: Course | undefined = CourseShare.parseCourse(arr[i]);
          if (course !== undefined) {
            result.push(course);
          }
        }
      }
      if (result.length === 0) {
        CourseShare.lastError = '分享码里没有课程';
        return undefined;
      }
      return result;
    } catch (e) {
      CourseShare.lastError = `分享码解析失败：${errorText(e as Error)}`;
      return undefined;
    }
  }

  /** 单条课程解析（课程名为空 → 跳过，返回 undefined） */
  private static parseCourse(o: ShareCourseRaw): Course | undefined {
    if (o === undefined || o === null) {
      return undefined;
    }
    const name: string = jsonStr(o.n).trim();
    if (name.length === 0) {
      return undefined;
    }
    const day: number = clampInt(jsonInt(o.d, 1), 1, 7);
    const start: number = jsonInt(o.s, 1);
    const end: number = jsonInt(o.e, start);
    const location: string = jsonStr(o.l);
    const credit: number = jsonNum(o.cr, Number.NaN);

    const c: Course = new Course();
    c.id = 0;
    c.name = name;
    c.teacher = jsonStr(o.t);
    c.location = location;
    c.dayOfWeek = day;
    // 自动纠正倒序
    c.startIndex = Math.min(start, end);
    c.endIndex = Math.max(start, end);
    c.startWeek = Math.max(jsonInt(o.sw, 1), 1);
    c.endWeek = Math.max(jsonInt(o.ew, 16), 1);
    c.oddEven = jsonInt(o.o, 0);
    // 分享码不带分类，导入端重新推断
    c.category = CourseColor.inferCategory(name, location);
    c.credit = isNaN(credit) ? -1 : credit;
    c.weeksText = jsonStr(o.wt);
    c.weeks = parseWeeks(jsonStr(o.w));
    return c;
  }
}
