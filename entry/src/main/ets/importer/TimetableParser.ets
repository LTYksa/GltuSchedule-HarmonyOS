/**
 * GltuSchedule · 鸿蒙版 —— 教务系统课表解析器
 * 对应 Android 版 `com.ltyksa.gltuschedule.import.WebTimetableParser`（633 行，按技术报告 1:1 移植）
 *
 * 策略顺序（与 Android 版逐条对齐，"有课就立即返回"，部分成功也算成功）：
 *   ① 列表视图：三列表格「星期 | 节次 | 课表信息」——真实 GLTU「个人课表查询」页面结构。
 *      星期/节次列用 rowspan=2，同一时段的两张卡片分处两个物理行；
 *      HtmlTable.expandTable 会把被 rowspan 覆盖的格子填成**同一个元素引用**，
 *      所以每个物理行都能读到「星期一 / 1-2」，两张卡片都不会丢。
 *   ② 表格视图（按表头星期）：某行有 ≥5 个「星期X」列。
 *   ③ 表格视图（默认列序）：没有表头，硬当第 1..7 列 = 周一..周日。
 *   ④ div 网格（实验性）：页面里没有表格时，扫 div/li/p 里的纯文本条目。
 *   全失败 → strategy='失败'，note 是与 Android 版一致的可读诊断（对用户可见，文案不能改）。
 *
 * 与 Android 版的有意差异（都写在注释里）：
 *   - 保留 ArkTS 版新增的 isNameWord() 例外词表（原版 Kotlin 没有，避免把
 *     "高等数学 概论" 的 "概论" 当成教师名）；
 *   - Kotlin/Java 的 `\s` 不含 \u00a0，而 JS/ArkTS 的 `\s` 含。
 *     这里凡是 Kotlin 用 `\s` 的地方都显式写成 `[ \t\n\v\f\r]`，行为与 Kotlin 一致；
 *   - 修掉技术报告里的高影响缺陷：§13-B1（空格分隔的周次）、§13-B4（启发式把节次括号/学年
 *     当周次）、§13-B9（row[secCol] 越界）、§13-B10（周次片段子串污染）。
 */
import { Course } from '../model/Course';
import { CourseColor } from '../data/CourseColor';
import { WeekParser } from './WeekParser';
import { WeekRange } from './WeekParser';
import { HtmlTable } from './HtmlTable';
import { HtmlElement } from './HtmlTable';

/** 解析结果：courses 为空即失败；strategy 是给用户看的中文策略名 */
export class ParseResult {
  courses: Course[] = [];
  strategy: string = '';
  /** 只在失败时有内容 */
  note: string = '';
}

/** 一次正则匹配：start/end 是 [start, end) 区间，value 是整段匹配 */
class MatchSpan {
  start: number = 0;
  end: number = 0;
  value: string = '';
  group1: string = '';
  group2: string = '';
  group3: string = '';

  constructor(start: number, end: number, value: string,
    group1: string, group2: string, group3: string = '') {
    this.start = start;
    this.end = end;
    this.value = value;
    this.group1 = group1;
    this.group2 = group2;
    this.group3 = group3;
  }
}

/** 节次区间（起, 止） */
class SectionRange {
  start: number = 1;
  end: number = 1;

  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }
}

// =====================================================================
// 正则（全部带 g；配合下面的 hasMatch / findAllN 使用，helper 里会重置 lastIndex）
// 说明：Java/Kotlin 的 `\s` = [ \t\n\x0B\f\r]，**不含 \u00a0**；
//       JS/ArkTS 的 `\s` 含 \u00a0 等 Unicode 空白。为了行为一致，这里全部显式写 ASCII 空白类。
// =====================================================================

/** 节次区间：第1~2节 / 1-2节 */
const SEC_RANGE: RegExp =
  /第?[ \t\n\v\f\r]*(\d{1,2})[ \t\n\v\f\r]*[~\-—－至][ \t\n\v\f\r]*(\d{1,2})[ \t\n\v\f\r]*节/g;
/** 单节次：第3节 / 3节 */
const SEC_SINGLE: RegExp = /第?[ \t\n\v\f\r]*(\d{1,2})[ \t\n\v\f\r]*节/g;
/** 裸区间：1-2 / 01-02（需要 1..20 校验） */
const SEC_BARE_RANGE: RegExp =
  /(\d{1,2})[ \t\n\v\f\r]*[~\-—－至][ \t\n\v\f\r]*(\d{1,2})/g;
/** 裸单值：3（需要 1..20 校验） */
const SEC_BARE_SINGLE: RegExp = /^(\d{1,2})$/g;
/** [01-02节] / (1-2节) / 1-2节 这类节次括号（Kotlin 原文用 \u005B \u005D 转义方括号） */
const SEC_BRACKET: RegExp =
  /[\u005B［(（]?[ \t\n\v\f\r]*\d{1,2}[ \t\n\v\f\r]*[-~—－至][ \t\n\v\f\r]*\d{1,2}[ \t\n\v\f\r]*节[ \t\n\v\f\r]*[\u005D］)）]?/g;
/**
 * 周次片段（含可选的逗号串、区间、单双标记），用于展示文本与剥离。
 * 比 Kotlin 版多一个前导 `(?:\d{1,2}\s*[,，、]\s*)*`，这样 "1,3,5周" 会整体命中，
 * 标准写法（"4-5周,8周,11-13周(单)"）的结果与 Kotlin 完全一致。
 */
const WEEKS_FRAGMENT: RegExp =
  /(?:\d{1,2}[ \t\n\v\f\r]*[,，、][ \t\n\v\f\r]*)*\d{1,2}[ \t\n\v\f\r]*[~\-—－至]?[ \t\n\v\f\r]*\d{0,2}[ \t\n\v\f\r]*[（(]?[ \t\n\v\f\r]*[单双]?[ \t\n\v\f\r]*[）)]?[ \t\n\v\f\r]*周/g;
/** 统计一条文本里的"周次命中数"（表格视图分块用） */
const WEEK_HIT: RegExp = /\d[ \t\n\v\f\r]*[~\-—－至]?[ \t\n\v\f\r]*\d*[ \t\n\v\f\r]*周/g;
/** (单) / （双） */
const ODD_EVEN_PAREN: RegExp = /[（(][ \t\n\v\f\r]*[单双][ \t\n\v\f\r]*[）)]/g;
/** 空括号 () / （） */
const EMPTY_PAREN: RegExp = /[（(][ \t\n\v\f\r]*[）)]/g;
/** 学年范围：2026-2027（避免被当成周次区间） */
const YEAR_RANGE: RegExp = /20\d{2}[ \t\n\v\f\r]*[-—~－至][ \t\n\v\f\r]*20\d{2}/g;
/** 日期：2026-09-01 / 2026/9/1 */
const DATE_PATTERN: RegExp = /\d{4}[-\/.]\d{1,2}[-\/.]\d{1,2}/g;
/** 启发式分词（Kotlin: [\s,，;；/|]+ —— 不切顿号、括号、连字符） */
const TOKEN_SPLIT: RegExp = /[ \t\n\v\f\r,，;；\/|]+/g;
/** 地点特征字 */
const LOC_KEYWORD: RegExp = /(楼|教室|馆|场|室|区|机房|报告厅|实训|中心)/g;
/** 2-4 个纯汉字（教师名形态，Kotlin 用 matches() 全串匹配） */
const CHINESE_NAME: RegExp = /^[\u4e00-\u9fa5]{2,4}$/g;
/** 课程名末尾"右括号 + 2-4 汉字"里的教师名 */
const TEACHER_IN_NAME: RegExp = /[)）][ \t\n\v\f\r]*([\u4e00-\u9fa5]{2,4})$/g;
/** 学分值里的第一个数字 */
const CREDIT_NUM: RegExp = /\d+(?:\.\d+)?/g;
/** 当前周次：第N周 */
const CURRENT_WEEK: RegExp = /第[ \t\n\v\f\r]*(\d{1,2})[ \t\n\v\f\r]*周/g;
/** 兼容旧 API 的"周1 / 星期7"数字写法 */
const WEEKDAY_DIGIT: RegExp = /(?:星期|周|礼拜)[ \t\n\v\f\r]*([1-7])/g;
/** 学期名：2026-2027学年第1学期 / 第一学期 */
const SEMESTER_PATTERN_1: RegExp =
  /(20\d{2})[ \t\n\v\f\r]*[-—~－至][ \t\n\v\f\r]*(20\d{2})[^0-9]{0,8}?第[ \t\n\v\f\r]*([12一二])[ \t\n\v\f\r]*学期/g;
/** 学期名：只有学年 2026-2027学年 */
const SEMESTER_PATTERN_2: RegExp =
  /(20\d{2})[ \t\n\v\f\r]*[-—~－至][ \t\n\v\f\r]*(20\d{2})[ \t\n\v\f\r]*学年/g;
/** 学期名：2026-2027-1 */
const SEMESTER_PATTERN_3: RegExp =
  /(20\d{2})[ \t\n\v\f\r]*[-—~－至][ \t\n\v\f\r]*(20\d{2})[ \t\n\v\f\r]*[-—~－至][ \t\n\v\f\r]*([12])(?!\d)/g;

/** 课程卡片里的字段标签（**必须带冒号**才算标签，避免把"教师口语"这类课程名误判成标签） */
const LABEL_NAMES: string[] = [
  '周数', '校区', '上课地点', '上课时间', '上课教室', '教师', '任课教师',
  '教学班组成', '教学班', '考核方式', '考试方式', '选课备注', '课程学时组成',
  '周学时', '总学时', '学分', '课程性质', '开课学院', '选课人数', '容量', '备注',
];
/**
 * 交替顺序就是上面数组的顺序，**不要重排**：
 * 「教学班组成」必须在「教学班」之前，「选课备注」必须在「备注」之前，否则前者会被拆错。
 */
const LABEL_REGEX: RegExp = new RegExp('(' + LABEL_NAMES.join('|') + ')[ \\t\\n\\v\\f\\r]*[：:]', 'g');
/** 一个卡片块的结束标志（无换行时兜底切块用） */
const BLOCK_END: RegExp = /学分[ \t\n\v\f\r]*[：:][ \t\n\v\f\r]*[\d.]{1,6}/g;
/** 判断"一格一行里有多个 周数：" */
const WEEKS_LABEL: RegExp = /周数[ \t\n\v\f\r]*[：:]/g;

/** 星期字 → 1..7（一,二,三,四,五,六,日,天；顺序敏感，「日」和「天」都是周日） */
const DAY_CHARS: string[] = ['一', '二', '三', '四', '五', '六', '日', '天'];
const DAY_VALUES: number[] = [1, 2, 3, 4, 5, 6, 7, 7];

export class TimetableParser {

  // =====================================================================
  // 入口
  // =====================================================================
  // 解析缓存
  //
  // ⚠️ 性能关键：`HtmlTable.parse` 是纯 JS 手写解析器，教务系统课表页有几 MB，
  // 一次全量解析要好几百毫秒、大页面甚至几秒。
  // 原来 `parse` / `guessSemester` / `guessCurrentWeek` **各解析一遍 = 3 遍**，
  // 而且都跑在 UI 线程上 → 点「确定导入」后界面直接卡住不动。
  //
  // 这里按 html 内容缓存「DOM + 纯文本」，让三个入口共用一次解析。
  // =====================================================================

  private static cachedHtml: string = '';
  private static cachedDoc: HtmlElement | undefined = undefined;
  private static cachedText: string = '';

  /** 取 DOM（带缓存） */
  private static docOf(html: string): HtmlElement {
    if (html.length > 0 && html === TimetableParser.cachedHtml
      && TimetableParser.cachedDoc !== undefined) {
      return TimetableParser.cachedDoc;
    }
    const d: HtmlElement = HtmlTable.parse(html);
    TimetableParser.cachedHtml = html;
    TimetableParser.cachedDoc = d;
    TimetableParser.cachedText = '';
    return d;
  }

  /** 取纯文本（带缓存）—— guessSemester / guessCurrentWeek 共用 */
  private static textOf(html: string): string {
    if (html.length > 0 && html === TimetableParser.cachedHtml
      && TimetableParser.cachedText.length > 0) {
      return TimetableParser.cachedText;
    }
    const t: string = TimetableParser.docOf(html).text();
    TimetableParser.cachedHtml = html;
    TimetableParser.cachedText = t;
    return t;
  }

  /** 主入口：按 ①列表 ②表格(表头) ③表格(默认列序) ④div 网格 的顺序尝试 */
  static parse(html: string): ParseResult {
    const out: ParseResult = new ParseResult();
    if (HtmlTable.isBlank(html)) {
      out.courses = [];
      out.strategy = '无';
      out.note = '抓到的网页内容为空';
      return out;
    }

    const doc: HtmlElement = TimetableParser.docOf(html);
    const tables: HtmlElement[] = HtmlTable.directTables(doc);

    // ① 列表视图（星期 / 节次 / 课表信息）—— GLTU 实际页面
    for (let i = 0; i < tables.length; i++) {
      const grid: (HtmlElement | undefined)[][] = HtmlTable.expandTable(tables[i]);
      const r: ParseResult = TimetableParser.tryListLayout(grid);
      if (r.courses.length > 0) {
        return r;
      }
    }

    // ② 表格视图（表头含 星期一…星期日）
    for (let i = 0; i < tables.length; i++) {
      const grid: (HtmlElement | undefined)[][] = HtmlTable.expandTable(tables[i]);
      const r: ParseResult = TimetableParser.tryGridLayout(grid, true);
      if (r.courses.length > 0) {
        return r;
      }
    }

    // ③ 表格视图（无表头，默认第 1..7 列 = 周一..周日）
    for (let i = 0; i < tables.length; i++) {
      const grid: (HtmlElement | undefined)[][] = HtmlTable.expandTable(tables[i]);
      const r: ParseResult = TimetableParser.tryGridLayout(grid, false);
      if (r.courses.length > 0) {
        return r;
      }
    }

    // ④ 没有表格可用了：从 div 网格里抓
    const divs: ParseResult = TimetableParser.tryDivGrid(doc);
    if (divs.courses.length > 0) {
      return divs;
    }

    out.courses = [];
    out.strategy = '失败';
    out.note = '没有识别到课表。当前页面表格数：' + tables.length + '。\n' +
      '请确认：\n' +
      '① 已登录成功；\n' +
      '② 停留在『个人课表查询 / 学生课表查询 / 我的课表』页面；\n' +
      '③ 页面上能看到『星期 / 节次 / 课表信息』或完整课表格子。\n' +
      '确认后再点『确定导入』。';
    return out;
  }

  /** 学期名识别："2026-2027学年第1学期" → "2026-2027 第1学期"；识别不出返回 '' */
  static guessSemester(html: string): string {
    if (HtmlTable.isBlank(html)) {
      return '';
    }
    const text: string = TimetableParser.textOf(html).replace(/\u00a0/g, ' ');
    // 三个正则按顺序试，命中第一个就返回（与 Kotlin 一致）
    let ms: MatchSpan[] = TimetableParser.findAll3(SEMESTER_PATTERN_1, text);
    if (ms.length > 0) {
      return TimetableParser.joinSemester(ms[0].group1, ms[0].group2, ms[0].group3);
    }
    ms = TimetableParser.findAll2(SEMESTER_PATTERN_2, text);
    if (ms.length > 0) {
      return ms[0].group1 + '-' + ms[0].group2;
    }
    ms = TimetableParser.findAll3(SEMESTER_PATTERN_3, text);
    if (ms.length > 0) {
      return TimetableParser.joinSemester(ms[0].group1, ms[0].group2, ms[0].group3);
    }
    return '';
  }

  private static joinSemester(year1: string, year2: string, term: string): string {
    const year: string = year1 + '-' + year2;
    if (term === '1' || term === '一') {
      return year + ' 第1学期';
    }
    if (term === '2' || term === '二') {
      return year + ' 第2学期';
    }
    return year;
  }

  /** 当前周次识别："当前第6周" → 6；识别不出返回 -1（只认 第N周，不认 周数：4-5周） */
  static guessCurrentWeek(html: string): number {
    if (HtmlTable.isBlank(html)) {
      return -1;
    }
    const text: string = TimetableParser.textOf(html);
    const ms: MatchSpan[] = TimetableParser.findAll1(CURRENT_WEEK, text);
    if (ms.length === 0) {
      return -1;
    }
    const w: number = parseInt(ms[0].group1, 10);
    if (isNaN(w) || w < 1 || w > 30) {
      return -1;
    }
    return w;
  }

  // =====================================================================
  // ① 列表视图：星期 | 节次 | 课表信息
  // =====================================================================

  private static tryListLayout(grid: (HtmlElement | undefined)[][]): ParseResult {
    const out: ParseResult = new ParseResult();
    out.strategy = '列表视图';
    if (grid.length < 2) {
      return out;
    }

    // 找表头行：同一行里同时出现"星期"列与"节次"列
    let headerIdx: number = -1;
    let dayCol: number = -1;
    let secCol: number = -1;
    for (let idx = 0; idx < grid.length; idx++) {
      const row: (HtmlElement | undefined)[] = grid[idx];
      let d: number = -1;
      let s: number = -1;
      for (let i = 0; i < row.length; i++) {
        const cell: HtmlElement | undefined = row[i];
        if (cell === undefined) {
          continue;
        }
        const t: string = cell.text().trim();
        if (t.length === 0) {
          continue;
        }
        const isDayHeader: boolean = (t.indexOf('星期') >= 0 || t === '周'
          || t.indexOf('礼拜') >= 0) && TimetableParser.dayOf(t) < 0;
        if (isDayHeader && d < 0) {
          d = i;
        }
        if (t.indexOf('节次') >= 0 && s < 0) {
          s = i;
        }
      }
      if (d >= 0 && s >= 0) {
        headerIdx = idx;
        dayCol = d;
        secCol = s;
        break;
      }
    }
    if (headerIdx < 0) {
      return out;
    }

    const courses: Course[] = [];
    for (let idx = headerIdx + 1; idx < grid.length; idx++) {
      const row: (HtmlElement | undefined)[] = grid[idx];
      // 列表视图里唯一的越界保护（行长度可能参差不齐）
      if (row.length <= Math.max(dayCol, secCol)) {
        continue;
      }
      const dayCell: HtmlElement | undefined = row[dayCol];
      const secCell: HtmlElement | undefined = row[secCol];
      const day: number = dayCell === undefined ? -1 : TimetableParser.dayOfLoose(dayCell.text());
      if (day < 0) {
        continue;
      }
      const section: SectionRange | undefined =
        secCell === undefined ? undefined : TimetableParser.parseSectionLoose(secCell.text());
      if (section === undefined) {
        continue;
      }

      // 其余列都当作课程信息列（通常只有一列；colspan 跨列时同一元素会被解析多次，靠 dedupe 兜住）
      for (let i = 0; i < row.length; i++) {
        if (i === dayCol || i === secCol) {
          continue;
        }
        const cell: HtmlElement | undefined = row[i];
        if (cell === undefined) {
          continue;
        }
        const cards: Course[] = TimetableParser.extractCoursesFromInfoCell(
          cell, day, section.start, section.end);
        for (let k = 0; k < cards.length; k++) {
          courses.push(cards[k]);
        }
      }
    }
    out.courses = TimetableParser.dedupe(courses);
    out.strategy = '列表视图（星期 / 节次 / 课表信息）';
    return out;
  }

  /** 从"课表信息"单元格里提取（可能多张）课程卡片 */
  private static extractCoursesFromInfoCell(cell: HtmlElement, day: number,
    secStart: number, secEnd: number): Course[] {
    const result: Course[] = [];
    const lines: string[] = HtmlTable.cellLines(cell);
    if (lines.length === 0) {
      return result;
    }

    // 按"非标签行 = 新卡片开始"切块：非标签行开新块，标签行并入当前块
    const blocks: string[][] = [];
    let cur: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const isLabelLine: boolean = TimetableParser.hasMatch(LABEL_REGEX, line);
      if (!isLabelLine || blocks.length === 0 && cur.length === 0) {
        if (cur.length > 0) {
          blocks.push(cur);
        }
        cur = [line];
      } else {
        cur.push(line);
      }
    }
    if (cur.length > 0) {
      blocks.push(cur);
    }

    let blockTexts: string[] = [];
    for (let i = 0; i < blocks.length; i++) {
      const text: string = blocks[i].join('\n');
      if (!HtmlTable.isBlank(text)) {
        blockTexts.push(text);
      }
    }

    // 兜底：整格只有一行但有多个"周数："时，按"学分：x"再切
    if (blockTexts.length === 1) {
      const hits: MatchSpan[] = TimetableParser.findAll0(WEEKS_LABEL, blockTexts[0]);
      if (hits.length > 1) {
        blockTexts = TimetableParser.splitByBlockEnd(blockTexts[0]);
      }
    }

    for (let i = 0; i < blockTexts.length; i++) {
      const c: Course | undefined = TimetableParser.parseCourseBlock(
        blockTexts[i], day, secStart, secEnd);
      if (c !== undefined) {
        result.push(c);
      }
    }
    return result;
  }

  /** 按"学分：x"切块（切点落在学分数字之后，尾部残余单独成块） */
  private static splitByBlockEnd(text: string): string[] {
    const out: string[] = [];
    const hits: MatchSpan[] = TimetableParser.findAll0(BLOCK_END, text);
    let cursor: number = 0;
    for (let i = 0; i < hits.length; i++) {
      out.push(text.substring(cursor, hits[i].end));
      cursor = hits[i].end;
    }
    if (cursor < text.length) {
      out.push(text.substring(cursor));
    }
    const cleaned: string[] = [];
    for (let i = 0; i < out.length; i++) {
      const t: string = out[i].trim();
      if (t.length > 0) {
        cleaned.push(t);
      }
    }
    return cleaned;
  }

  /**
   * 解析一张标签式课程卡片。文本形如：
   *   中华民族共同体概论*
   *   周数：4-5周,8周,11-13周(单),14-16周
   *   校区:雁山校区  上课地点：1226（阶4教室）
   *   教师：文娟(讲师)  教学班：TB29129006-...
   *   学分：2.0
   */
  private static parseCourseBlock(block: string, day: number,
    secStart: number, secEnd: number): Course | undefined {
    // 块内换行 → 空格；ASCII 空白折叠；trim（与 Kotlin 一致：\s 不动 \u00a0）
    const text: string = TimetableParser.foldWs(block.split('\n').join(' ')).trim();
    if (text.length === 0) {
      return undefined;
    }

    const matches: MatchSpan[] = TimetableParser.findAll1(LABEL_REGEX, text);

    // 课程名 = 全文第一个标签之前的内容（去掉末尾的 * 等标记）
    let rawName: string = text;
    if (matches.length > 0) {
      rawName = text.substring(0, matches[0].start);
    }
    const name: string = TimetableParser.trimWs(
      TimetableParser.trimSet(TimetableParser.trimWs(rawName), '*＊· \u00a0'));
    if (name.length === 0 || name.length > 60) {
      return undefined;
    }

    const weeksRaw: string | undefined = TimetableParser.labelValue(matches, text, ['周数']);
    let weeks: number[] = [];
    if (weeksRaw !== undefined) {
      weeks = WeekParser.parse(weeksRaw);
    }

    const campusRaw: string | undefined = TimetableParser.labelValue(matches, text, ['校区']);
    let campus: string = '';
    if (campusRaw !== undefined) {
      campus = TimetableParser.take(TimetableParser.removeAsciiWs(campusRaw), 12);
    }
    const roomRaw: string | undefined =
      TimetableParser.labelValue(matches, text, ['上课地点', '上课教室']);
    let room: string = '';
    if (roomRaw !== undefined) {
      room = TimetableParser.cleanLocation(roomRaw);
    }
    // 拼成"雁山校区 1226（阶4教室）"，与教务系统/超级课程表的展示一致
    let location: string = '';
    if (campus.length === 0) {
      location = room;
    } else if (room.length === 0) {
      location = campus;
    } else if (room.indexOf(campus) >= 0) {
      location = room;
    } else {
      location = campus + ' ' + room;
    }

    const teacherRaw: string | undefined =
      TimetableParser.labelValue(matches, text, ['教师', '任课教师']);
    let teacher: string = '';
    if (teacherRaw !== undefined) {
      teacher = TimetableParser.cleanTeacher(teacherRaw);
    }

    const creditRaw: string | undefined = TimetableParser.labelValue(matches, text, ['学分']);
    let credit: number = -1;
    if (creditRaw !== undefined) {
      const nums: MatchSpan[] = TimetableParser.findAll0(CREDIT_NUM, creditRaw);
      if (nums.length > 0) {
        const d: number = parseFloat(nums[0].value);
        if (!isNaN(d)) {
          credit = d;
        }
      }
    }

    // 既没周次也没地点 → 不像一张课程卡片
    if (weeks.length === 0 && location.length === 0) {
      return undefined;
    }

    const c: Course = new Course();
    c.id = 0;
    c.name = name;
    c.teacher = teacher;
    c.location = location;
    c.dayOfWeek = day;
    c.startIndex = secStart;
    c.endIndex = secEnd;
    // 周次全空但地点存在时按整学期处理（Kotlin 原版是 1..1，只在第 1 周显示，见报告 §13-B3）
    c.startWeek = 1;
    c.endWeek = 16;
    c.oddEven = 0;
    if (weeks.length > 0) {
      const range: WeekRange = WeekParser.inferRange(weeks);
      c.startWeek = range.startWeek;
      c.endWeek = range.endWeek;
      c.oddEven = range.oddEven;
    }
    c.category = CourseColor.inferCategory(name, location);
    c.credit = credit;
    c.weeksText = weeksRaw === undefined ? '' : weeksRaw;
    c.weeks = weeks;
    return c;
  }

  /** 取标签值：按参数顺序找第一个"标签名完全相等"的匹配，值到下一个标签起点为止 */
  private static labelValue(matches: MatchSpan[], text: string,
    labels: string[]): string | undefined {
    for (let li = 0; li < labels.length; li++) {
      const label: string = labels[li];
      let m: MatchSpan | undefined = undefined;
      for (let i = 0; i < matches.length; i++) {
        if (matches[i].group1 === label) {
          m = matches[i];
          break;
        }
      }
      if (m === undefined) {
        continue;
      }
      let end: number = text.length;
      for (let i = 0; i < matches.length; i++) {
        if (matches[i].start > m.start) {
          end = matches[i].start;
          break;
        }
      }
      const v: string = TimetableParser.trimWs(
        TimetableParser.trimSet(TimetableParser.trimWs(text.substring(m.end, end)), '；;，,|'));
      if (v.length > 0) {
        return v;
      }
    }
    return undefined;
  }

  /** 地点清洗：空白折叠 + trim + 最多 30 字 */
  private static cleanLocation(v: string): string {
    return TimetableParser.take(TimetableParser.foldWs(v).trim(), 30);
  }

  /** 教师：去掉职称括号（"文娟(讲师)" → "文娟"）+ trim + 最多 20 字 */
  private static cleanTeacher(v: string): string {
    const stripped: string = v.replace(/[（(][^）)]{0,10}[）)]/g, '');
    return TimetableParser.take(TimetableParser.trimWs(stripped), 20);
  }

  // =====================================================================
  // ② ③ 表格视图：节次行 × 星期列
  // =====================================================================

  private static tryGridLayout(grid: (HtmlElement | undefined)[][],
    useHeaderDays: boolean): ParseResult {
    const out: ParseResult = new ParseResult();
    out.strategy = '表格视图';
    if (grid.length < 2) {
      return out;
    }

    let dayCols: Map<number, number> | undefined = undefined;
    let secCol: number = 0;
    if (useHeaderDays) {
      for (let r = 0; r < grid.length; r++) {
        const row: (HtmlElement | undefined)[] = grid[r];
        const map: Map<number, number> = new Map<number, number>();
        for (let i = 0; i < row.length; i++) {
          const c: HtmlElement | undefined = row[i];
          if (c === undefined) {
            continue;
          }
          const d: number = TimetableParser.dayOf(c.text());
          if (d >= 0) {
            map.set(i, d);
          }
        }
        if (map.size >= 5) {
          dayCols = map;
          // 节次列 = 0..max(星期列) 里第一个不属于星期列的列号；找不到就 0（与 Kotlin 一致）
          let maxCol: number = -1;
          map.forEach((v: number, k: number): void => {
            if (k > maxCol) {
              maxCol = k;
            }
          });
          secCol = 0;
          for (let i = 0; i <= maxCol; i++) {
            if (!map.has(i)) {
              secCol = i;
              break;
            }
          }
          break;
        }
      }
      if (dayCols === undefined) {
        return out;
      }
    }

    const courses: Course[] = [];
    for (let r = 0; r < grid.length; r++) {
      const row: (HtmlElement | undefined)[] = grid[r];
      if (row.length < 3) {
        continue;
      }
      const defaultCols: Map<number, number> = TimetableParser.buildDefaultDayCols(row.length);
      const mapping: Map<number, number> = dayCols === undefined ? defaultCols : dayCols;
      // 报告 §13-B9：expandTable 允许参差不齐的行，这里必须补越界检查
      if (secCol >= row.length) {
        continue;
      }
      const secCell: HtmlElement | undefined = row[secCol];
      const section: SectionRange | undefined =
        secCell === undefined ? undefined : TimetableParser.parseSectionLoose(secCell.text());
      if (section === undefined) {
        continue;
      }
      // 按列号升序遍历（Kotlin 用 HashMap 顺序不保证；升序结果更稳定，dedupe 保留首见顺序）
      const cols: number[] = [];
      mapping.forEach((v: number, k: number): void => {
        cols.push(k);
      });
      cols.sort((a: number, b: number): number => a - b);
      for (let ci = 0; ci < cols.length; ci++) {
        const colIdx: number = cols[ci];
        if (colIdx >= row.length) {
          continue;
        }
        const cell: HtmlElement | undefined = row[colIdx];
        if (cell === undefined) {
          continue;
        }
        const d: number | undefined = mapping.get(colIdx);
        if (d === undefined) {
          continue;
        }
        const entries: string[] = TimetableParser.extractEntriesFromGridCell(cell);
        for (let k = 0; k < entries.length; k++) {
          const c: Course | undefined = TimetableParser.parseGridEntry(
            entries[k], d, section.start, section.end);
          if (c !== undefined) {
            courses.push(c);
          }
        }
      }
    }
    out.courses = TimetableParser.dedupe(courses);
    out.strategy = useHeaderDays ? '表格视图（按表头星期）' : '表格视图（默认列序）';
    return out;
  }

  /** 没有表头时：第 1..7 列 = 周一..周日（列 0 是节次，列 8+ 忽略） */
  private static buildDefaultDayCols(cellCount: number): Map<number, number> {
    const map: Map<number, number> = new Map<number, number>();
    for (let i = 1; i <= 7; i++) {
      if (i < cellCount) {
        map.set(i, i);
      }
    }
    return map;
  }

  /**
   * 表格视图单元格 → 若干"课程条目文本"。
   * 有 div 就用 div（优先叶子 div，再优先含"周"的那些）；否则用 cellLines 按周次行分块。
   */
  private static extractEntriesFromGridCell(cell: HtmlElement): string[] {
    const divs: HtmlElement[] = [];
    const allDivs: HtmlElement[] = cell.descendants('div');
    for (let i = 0; i < allDivs.length; i++) {
      if (!HtmlTable.isBlank(allDivs[i].text())) {
        divs.push(allDivs[i]);
      }
    }
    if (divs.length > 0) {
      const leaf: HtmlElement[] = [];
      for (let i = 0; i < divs.length; i++) {
        if (divs[i].descendants('div').length === 0) {
          leaf.push(divs[i]);
        }
      }
      const source: HtmlElement[] = leaf.length > 0 ? leaf : divs;
      const chosen: string[] = [];
      for (let i = 0; i < source.length; i++) {
        chosen.push(source[i].text().trim());
      }
      const withWeeks: string[] = [];
      for (let i = 0; i < chosen.length; i++) {
        if (chosen[i].indexOf('周') >= 0) {
          withWeeks.push(chosen[i]);
        }
      }
      return TimetableParser.distinct(withWeeks.length > 0 ? withWeeks : chosen);
    }

    const lines: string[] = HtmlTable.cellLines(cell);
    if (lines.length === 0) {
      return [];
    }
    if (lines.length === 1) {
      return lines;
    }
    let totalHits: number = 0;
    for (let i = 0; i < lines.length; i++) {
      totalHits += TimetableParser.findAll0(WEEK_HIT, lines[i]).length;
    }
    if (totalHits <= 1) {
      return [lines.join(' ')];
    }
    // 多段：按"含周次"行分块
    const out: string[] = [];
    let cur: string[] = [];
    let curWeeks: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const w: number = TimetableParser.findAll0(WEEK_HIT, lines[i]).length;
      if (curWeeks > 0 && w > 0) {
        out.push(cur.join(' ').trim());
        cur = [];
        curWeeks = 0;
      }
      cur.push(lines[i]);
      curWeeks += w;
    }
    if (!HtmlTable.isBlank(cur.join(' '))) {
      out.push(cur.join(' ').trim());
    }
    return out;
  }

  /** 表格视图单元格条目：优先用标签式解析，退化到通用启发式 */
  private static parseGridEntry(raw: string, day: number,
    secStart: number, secEnd: number): Course | undefined {
    if (TimetableParser.hasMatch(LABEL_REGEX, raw)) {
      const c: Course | undefined =
        TimetableParser.parseCourseBlock(raw, day, secStart, secEnd);
      if (c !== undefined) {
        return c;
      }
    }
    return TimetableParser.parseHeuristic(raw, day, secStart, secEnd);
  }

  /** 通用启发式：`高等数学(分组A)张三 1-16周[01-02节]明德楼B104` 这类纯文本 */
  private static parseHeuristic(raw: string, day: number,
    secStart: number, secEnd: number): Course | undefined {
    // 0 归一化：\u00a0 → 普通空格（Kotlin 版显式做了），ASCII 空白折叠，trim
    const text: string = TimetableParser.foldWs(raw.replace(/\u00a0/g, ' ')).trim();
    if (text.length === 0) {
      return undefined;
    }

    // 1 周次：报告 §13-B4 —— 先剥掉节次括号/节次写法/学年/日期，再解析周次，
    //   否则 "[01-02节]"、"2026-2027学年" 会被当成周次区间。
    let cleaned: string = text;
    cleaned = cleaned.replace(SEC_BRACKET, ' ');
    cleaned = cleaned.replace(SEC_RANGE, ' ');
    cleaned = cleaned.replace(SEC_SINGLE, ' ');
    cleaned = cleaned.replace(YEAR_RANGE, ' ');
    cleaned = cleaned.replace(DATE_PATTERN, ' ');

    let weeks: number[] = [];
    let frags: MatchSpan[] = [];
    if (cleaned.indexOf('周') >= 0) {
      frags = TimetableParser.findAll0(WEEKS_FRAGMENT, cleaned);
    }
    if (frags.length > 0) {
      // 只从"含周"的片段里取周次（"1,3,5周" 这种逗号串会整体命中）
      const parts: string[] = [];
      for (let i = 0; i < frags.length; i++) {
        parts.push(frags[i].value);
      }
      weeks = WeekParser.parse(parts.join(','));
    } else {
      // 一个"周"字都没有（如"高等数学 张三 1-16 明德楼B104"）：只认 "x-y" 区间写法。
      // 单独的号码绝不能当周次——"明德楼B104" 的 104、"3305" 这类教室号都在这里被挡住
      // （报告 §13-B4 的"教室号"）。
      const bareRanges: MatchSpan[] = TimetableParser.findAll2(SEC_BARE_RANGE, cleaned);
      const parts: string[] = [];
      for (let i = 0; i < bareRanges.length; i++) {
        parts.push(bareRanges[i].value);
      }
      if (parts.length > 0) {
        weeks = WeekParser.parse(parts.join(','));
      }
    }
    if (weeks.length === 0) {
      return undefined;
    }

    // 2 原始周次片段与单双周标记（用于展示；奇数优先于偶数，与 Kotlin 一致）
    const weekFrags: MatchSpan[] = TimetableParser.findAll0(WEEKS_FRAGMENT, text);
    const parts: string[] = [];
    for (let i = 0; i < weekFrags.length; i++) {
      parts.push(weekFrags[i].value.trim());
    }
    let oddEven: number = 0;
    if (text.indexOf('单周') >= 0 || text.indexOf('(单)') >= 0 || text.indexOf('（单）') >= 0) {
      oddEven = 1;
    } else if (text.indexOf('双周') >= 0
      || text.indexOf('(双)') >= 0 || text.indexOf('（双）') >= 0) {
      oddEven = 2;
    }
    let suffix: string = '';
    if (oddEven === 1) {
      suffix = '(单)';
    } else if (oddEven === 2) {
      suffix = '(双)';
    }
    let weeksText: string = TimetableParser.trimSet(parts.join(',') + suffix, ', ');
    if (HtmlTable.isBlank(weeksText)) {
      weeksText = weeks[0] + '-' + weeks[weeks.length - 1] + '周';
    }

    // 3 剥离：周次片段（按匹配位置整体替换，修 §13-B10 的子串污染）→ 节次 → 单双/空括号 → 折叠空白
    let rest: string = text;
    rest = rest.replace(WEEKS_FRAGMENT, ' ');
    rest = rest.replace(SEC_BRACKET, ' ');
    rest = rest.replace(SEC_RANGE, ' ');
    rest = rest.replace(SEC_SINGLE, ' ');
    rest = rest.replace(ODD_EVEN_PAREN, ' ');
    rest = rest.replace(EMPTY_PAREN, ' ');
    rest = TimetableParser.foldWs(rest).trim();

    const tokens: string[] = TimetableParser.splitTokens(rest);
    if (tokens.length === 0) {
      return undefined;
    }

    // 4 地点：第一个"含地点特征字且长度 2..20"的 token
    let location: string = '';
    let locIdx: number = -1;
    for (let i = 0; i < tokens.length; i++) {
      if (TimetableParser.hasMatch(LOC_KEYWORD, tokens[i])
        && tokens[i].length >= 2 && tokens[i].length <= 20) {
        locIdx = i;
        break;
      }
    }
    if (locIdx >= 0) {
      location = tokens[locIdx];
      tokens.splice(locIdx, 1);
    }

    // 5 教师：剩下的 token 里"最靠后的形态像人名"的那个（下标 0 永远是课程名，不当教师）。
    //   这里比 Kotlin 多一层 isNameWord() 例外词表：末位若是"概论/原理/教程"这类课程名词，
    //   说明它本来就是课程名的一部分，**不再往前找**（否则会把课程名当成教师）。
    let teacher: string = '';
    let tIdx: number = -1;
    for (let i = tokens.length - 1; i >= 1; i--) {
      if (TimetableParser.hasMatch(CHINESE_NAME, tokens[i])) {
        if (!TimetableParser.isNameWord(tokens[i])) {
          tIdx = i;
        }
        break;
      }
    }
    if (tIdx >= 0) {
      teacher = tokens[tIdx];
      tokens.splice(tIdx, 1);
    }

    // 6 课程名：剩下的第一个 token；没有 token 就用整段（最多 30 字）
    let name: string = tokens.length > 0 ? tokens[0].trim() : '';
    if (name.length === 0) {
      name = TimetableParser.take(rest.trim(), 30);
    }
    if (name.length === 0) {
      return undefined;
    }

    // 7 教师兜底："高等数学(分组A)张三" → 教师"张三"，课程名"高等数学(分组A)"（保留左括号）
    if (teacher.length === 0) {
      const ms: MatchSpan[] = TimetableParser.findAll1(TEACHER_IN_NAME, name);
      if (ms.length > 0) {
        teacher = ms[0].group1;
        name = name.substring(0, ms[0].start + 1).trim();
      }
    }
    if (name.length === 0) {
      return undefined;
    }

    const c: Course = new Course();
    c.id = 0;
    c.name = name;
    c.teacher = teacher;
    c.location = location;
    c.dayOfWeek = day;
    c.startIndex = secStart;
    c.endIndex = secEnd;
    c.startWeek = weeks[0];
    c.endWeek = weeks[weeks.length - 1];
    c.oddEven = oddEven;
    c.category = CourseColor.inferCategory(name, location);
    c.credit = -1;
    c.weeksText = weeksText;
    c.weeks = weeks;
    return c;
  }

  // =====================================================================
  // ④ div 网格（实验性）
  // =====================================================================

  private static tryDivGrid(doc: HtmlElement): ParseResult {
    const courses: Course[] = [];
    const blocks: HtmlElement[] = doc.descendantsAny(['div', 'li', 'p']);
    for (let i = 0; i < blocks.length; i++) {
      const t: string = blocks[i].text().trim();
      if (t.length < 8 || t.length > 600) {
        continue;
      }
      const day: number = TimetableParser.dayOf(t);
      if (day < 0) {
        continue;
      }
      const section: SectionRange | undefined = TimetableParser.parseSectionLoose(t);
      if (section === undefined) {
        continue;
      }
      const c: Course | undefined =
        TimetableParser.parseGridEntry(t, day, section.start, section.end);
      if (c !== undefined) {
        courses.push(c);
      }
    }
    const out: ParseResult = new ParseResult();
    out.courses = TimetableParser.dedupe(courses);
    out.strategy = 'div 网格（实验性）';
    return out;
  }

  // =====================================================================
  // 工具
  // =====================================================================

  /** 严格星期：文本里必须含 星期/周/礼拜，再按 DAY_CHARS 的固定顺序取第一个命中的日名 */
  private static dayOf(text: string): number {
    const t: string = text.trim().replace(/ /g, '');
    if (t.length === 0) {
      return -1;
    }
    if (!(t.indexOf('星期') >= 0 || t.indexOf('周') >= 0 || t.indexOf('礼拜') >= 0)) {
      return -1;
    }
    for (let i = 0; i < DAY_CHARS.length; i++) {
      if (t.indexOf(DAY_CHARS[i]) >= 0) {
        return DAY_VALUES[i];
      }
    }
    return -1;
  }

  /** 宽松星期：已知该列是"星期"列时，允许只写"一/周一"（长度 ≤4 且恰好命中 1 个日名） */
  private static dayOfLoose(text: string): number {
    const strict: number = TimetableParser.dayOf(text);
    if (strict >= 0) {
      return strict;
    }
    const t: string = text.trim().replace(/ /g, '').replace(/\n/g, '');
    if (t.length === 0 || t.length > 4) {
      return -1;
    }
    let found: number = -1;
    let count: number = 0;
    for (let i = 0; i < DAY_CHARS.length; i++) {
      if (t.indexOf(DAY_CHARS[i]) >= 0) {
        found = DAY_VALUES[i];
        count++;
      }
    }
    return count === 1 ? found : -1;
  }

  /** 节次：第X~Y节 → 第X节 → 裸 X-Y（须 1..20）→ 裸 X（1..20） */
  private static parseSectionLoose(text: string): SectionRange | undefined {
    const t: string = text.trim();
    if (t.length === 0) {
      return undefined;
    }
    const range: MatchSpan[] = TimetableParser.findAll2(SEC_RANGE, t);
    if (range.length > 0) {
      const a: number = parseInt(range[0].group1, 10);
      const b: number = parseInt(range[0].group2, 10);
      if (!isNaN(a) && !isNaN(b)) {
        return new SectionRange(Math.min(a, b), Math.max(a, b));
      }
    }
    const single: MatchSpan[] = TimetableParser.findAll1(SEC_SINGLE, t);
    if (single.length > 0) {
      const a: number = parseInt(single[0].group1, 10);
      if (!isNaN(a)) {
        return new SectionRange(a, a);
      }
    }
    const bare: MatchSpan[] = TimetableParser.findAll2(SEC_BARE_RANGE, t);
    if (bare.length > 0) {
      const a: number = parseInt(bare[0].group1, 10);
      const b: number = parseInt(bare[0].group2, 10);
      if (!isNaN(a) && !isNaN(b) && a >= 1 && a <= 20 && b >= 1 && b <= 20) {
        return new SectionRange(Math.min(a, b), Math.max(a, b));
      }
    }
    const bareSingle: MatchSpan[] = TimetableParser.findAll1(SEC_BARE_SINGLE, t);
    if (bareSingle.length > 0) {
      const a: number = parseInt(bareSingle[0].group1, 10);
      if (!isNaN(a) && a >= 1 && a <= 20) {
        return new SectionRange(a, a);
      }
    }
    return undefined;
  }

  /** 按复合 key 去重，保留首见顺序（key 不含 credit/weeksText） */
  private static dedupe(list: Course[]): Course[] {
    const seen: Map<string, Course> = new Map<string, Course>();
    for (let i = 0; i < list.length; i++) {
      const c: Course = list[i];
      const key: string = c.name + '|' + c.teacher + '|' + c.location + '|' + c.dayOfWeek
        + '|' + c.startIndex + '-' + c.endIndex + '|' + c.weeks.join(',');
      if (!seen.has(key)) {
        seen.set(key, c);
      }
    }
    const out: Course[] = [];
    seen.forEach((v: Course, k: string): void => {
      out.push(v);
    });
    return out;
  }

  // =====================================================================
  // 兼容旧 API（旧版 TimetableParser 的公开方法，调用方可能还在用）
  // =====================================================================

  /**
   * 这些词出现在末尾时是课程名的一部分，不是教师名。
   * 原版 Kotlin 没有这张表（会把"高等数学 概论"的"概论"当成教师），这是 ArkTS 版的改进，保留。
   */
  static isNameWord(w: string): boolean {
    return /^(概论|原理|基础|教程|导论|理论|实践|实验|研究|专题|讲座|训练|教育|技术|设计|分析|写作|英语|数学|物理|化学|体育|课程)$/.test(w);
  }

  /** 兼容旧 API："星期一" / "周一" / "礼拜三" / "周3" → 1..7；识别不出返回 -1 */
  static parseWeekday(text: string): number {
    if (text === undefined || text === null || text.length === 0) {
      return -1;
    }
    const strict: number = TimetableParser.dayOf(text);
    if (strict >= 0) {
      return strict;
    }
    const loose: number = TimetableParser.dayOfLoose(text);
    if (loose >= 0) {
      return loose;
    }
    const ms: MatchSpan[] = TimetableParser.findAll1(WEEKDAY_DIGIT, text);
    if (ms.length > 0) {
      const d: number = parseInt(ms[0].group1, 10);
      if (!isNaN(d)) {
        return d;
      }
    }
    return -1;
  }

  /** 兼容旧 API：把单元格文本（\n 分行）当"课表信息格"解析出若干张卡片 */
  static extractCards(cell: string, day: number,
    startIndex: number, endIndex: number): Course[] {
    if (cell === undefined || cell === null || HtmlTable.isBlank(cell)) {
      return [];
    }
    const el: HtmlElement = HtmlTable.fromText(cell);
    return TimetableParser.extractCoursesFromInfoCell(el, day, startIndex, endIndex);
  }

  // =====================================================================
  // 内部小工具
  // =====================================================================

  /** 重置 lastIndex 后做全串/子串匹配 */
  private static hasMatch(re: RegExp, s: string): boolean {
    re.lastIndex = 0;
    const ok: boolean = re.test(s);
    re.lastIndex = 0;
    return ok;
  }

  private static findAll0(re: RegExp, text: string): MatchSpan[] {
    const out: MatchSpan[] = [];
    re.lastIndex = 0;
    text.replace(re, (m: string, offset: number): string => {
      out.push(new MatchSpan(offset, offset + m.length, m, '', ''));
      return m;
    });
    re.lastIndex = 0;
    return out;
  }

  private static findAll1(re: RegExp, text: string): MatchSpan[] {
    const out: MatchSpan[] = [];
    re.lastIndex = 0;
    text.replace(re, (m: string, g1: string, offset: number): string => {
      const a: string = g1 === undefined ? '' : g1;
      out.push(new MatchSpan(offset, offset + m.length, m, a, ''));
      return m;
    });
    re.lastIndex = 0;
    return out;
  }

  private static findAll2(re: RegExp, text: string): MatchSpan[] {
    const out: MatchSpan[] = [];
    re.lastIndex = 0;
    text.replace(re, (m: string, g1: string, g2: string, offset: number): string => {
      const a: string = g1 === undefined ? '' : g1;
      const b: string = g2 === undefined ? '' : g2;
      out.push(new MatchSpan(offset, offset + m.length, m, a, b));
      return m;
    });
    re.lastIndex = 0;
    return out;
  }

  /** 三个捕获组（只用于 guessSemester 的模式 1/3） */
  private static findAll3(re: RegExp, text: string): MatchSpan[] {
    const out: MatchSpan[] = [];
    re.lastIndex = 0;
    text.replace(re, (m: string, g1: string, g2: string, g3: string,
      offset: number): string => {
      const a: string = g1 === undefined ? '' : g1;
      const b: string = g2 === undefined ? '' : g2;
      const c: string = g3 === undefined ? '' : g3;
      out.push(new MatchSpan(offset, offset + m.length, m, a, b, c));
      return m;
    });
    re.lastIndex = 0;
    return out;
  }

  /** 折叠 ASCII 空白为单空格（Kotlin 的 `\s+`，不含 \u00a0） */
  private static foldWs(s: string): string {
    return s.replace(/[ \t\n\v\f\r]+/g, ' ');
  }

  /** 去掉全部 ASCII 空白（Kotlin 的 `replace(Regex("\\s+"), "")`） */
  private static removeAsciiWs(s: string): string {
    return s.replace(/[ \t\n\v\f\r]+/g, '');
  }

  /** trim（Kotlin 的 trim() 会去掉 \u00a0 等 Unicode 空白，JS 的 trim() 同样是） */
  private static trimWs(s: string): string {
    return s.trim();
  }

  /** 只修剪首尾出现在 chars 里的字符（JS 没有 Kotlin 的 trim(vararg chars)） */
  private static trimSet(s: string, chars: string): string {
    let start: number = 0;
    let end: number = s.length;
    while (start < end && chars.indexOf(s.charAt(start)) >= 0) {
      start++;
    }
    while (end > start && chars.indexOf(s.charAt(end - 1)) >= 0) {
      end--;
    }
    return s.substring(start, end);
  }

  private static take(s: string, n: number): string {
    if (s.length <= n) {
      return s;
    }
    return s.substring(0, n);
  }

  private static splitTokens(s: string): string[] {
    const raw: string[] = s.split(TOKEN_SPLIT);
    const out: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      if (!HtmlTable.isBlank(raw[i])) {
        out.push(raw[i]);
      }
    }
    return out;
  }

  private static distinct(list: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < list.length; i++) {
      if (out.indexOf(list[i]) < 0) {
        out.push(list[i]);
      }
    }
    return out;
  }
}
