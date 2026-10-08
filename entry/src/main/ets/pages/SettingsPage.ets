/**
 * GltuSchedule · 鸿蒙版 —— 设置页
 *
 * 1:1 对齐 Android 版 `ui/settings/SettingsScreen.kt`（界面结构、层级与文案逐字照抄）：
 *   设置标题 / 获取课表（三种方式）/ 当前学期 / 节假日屏蔽课程（三个独立开关 + 已收录假期清单）
 *   / 上课提醒（1–60 分钟，可多选）/ 同步到手机日历 / 关于
 *
 * UI 约定：
 *   · 外层 Scroll + Column(space 12) + padding 16，底色 C.pageBg
 *   · 不用 bindSheet（本机 SDK 上运行时失效）—— 弹窗一律 Stack + 条件渲染自己实现
 *   · 数据直接读 StoreHolder（不走父组件），开关切换后立即落盘
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { C, Col, D } from '../common/Palette';
import { AppInfo } from '../common/AppInfo';
import { DateUtil, Ymd } from '../data/DateUtil';
import { BlockSettings, Holiday, HolidayEntry, HolidayManager, HolidayType } from '../data/Holiday';
import { MakeupResolver } from '../data/MakeupRule';
import { HolidaySync } from '../data/HolidaySync';
import { ClassReminderScheduler } from '../notification/ClassReminderScheduler';
import { CalendarSync, SyncResult } from '../calendar/CalendarSync';
import { StoreHolder } from '../database/CourseStore';
import { SyncDownstream } from '../common/SyncDownstream';
// ==================== 存储键（与 Android 版逐字一致） ====================

/** 节假日屏蔽开关（HolidayManager） */
const KEY_BLOCK_STATUTORY: string = 'block_statutory';
const KEY_BLOCK_SCHOOL: string = 'block_school';
const KEY_BLOCK_WEEKEND: string = 'block_weekend';
/** 学期（SemesterStore / SchedulePreferences） */
const KEY_FIRST_MONDAY: string = 'first_monday';
const KEY_SEMESTER_NAME: string = 'semester_name';

/** 上课提醒（ReminderPreference） */
const KEY_REMINDER_ENABLED: string = 'reminder_enabled';
const KEY_REMINDER_MINUTES: string = 'reminder_advance_minutes';
const REMINDER_MIN_MINUTES: number = 1;
const REMINDER_MAX_MINUTES: number = 60;
/** 默认：课前 30 分钟与 10 分钟各提醒一次 */
const REMINDER_DEFAULT_MINUTES: number[] = [30, 10];

/** 假期数据来源文案 */
const SOURCE_BUILTIN: string = '内置数据（未同步）';
const SOURCE_SYNCED: string = '中国大陆法定节假日（国务院办公厅通知）';

/** 提醒时间可选范围 1…60 */
function buildMinuteRange(): number[] {
  const out: number[] = [];
  for (let i = REMINDER_MIN_MINUTES; i <= REMINDER_MAX_MINUTES; i++) {
    out.push(i);
  }
  return out;
}

/** 「已收录的假期清单」里的一行 */
class HolidayRow {
  name: string;
  dateText: string;
  statusText: string;
  statusColor: string;

  constructor(name: string, dateText: string, statusText: string, statusColor: string) {
    this.name = name;
    this.dateText = dateText;
    this.statusText = statusText;
    this.statusColor = statusColor;
  }
}

/** 「已收录的假期清单」里的一个分组 */
class HolidayGroup {
  label: string;
  items: HolidayRow[];

  constructor(label: string, items: HolidayRow[]) {
    this.label = label;
    this.items = items;
  }
}

/** 分组定义：假期类型 → 组名（顺序与 Android 版一致） */
class HolidayGroupDef {
  type: HolidayType;
  label: string;

  constructor(type: HolidayType, label: string) {
    this.type = type;
    this.label = label;
  }
}

@Component
export struct SettingsPage {
  /** 由父组件注入：'edit' | 'share' | 'import' */
  onNavigate: (route: string) => void = () => {};
  /**
   * 由父组件注入：把本页的滚动位移上报给根页面，用来收起/展开悬浮底栏。
   * 本页是子组件，拿不到底栏状态，只能往上抛。
   */
  onScrollDir: (yOffset: number) => void = () => {};
  /**
   * 由父组件注入：底部要给悬浮胶囊留多少空间。
   * 不能写死 —— 胶囊收起/展开时占用高度不同，写死会在滚到底时多出一块死白。
   */
  navClear: number = D.floatNavClear;

  // ---------- 状态 ----------
  @State blockStatutory: boolean = true;
  @State blockSchool: boolean = true;
  @State blockWeekend: boolean = false;
  @State semesterName: string = '';
  @State currentWeek: number = 1;
  @State courseCount: number = 0;
  @State holidayCount: number = 0;
  @State holidayGroups: HolidayGroup[] = [];
  @State showHolidayList: boolean = false;
  /** 是否已联网同步过权威数据（本阶段无联网，恒为 false → 显示「内置数据（未同步）」） */
  @State syncedFromNetwork: boolean = false;
  @State reminderEnabled: boolean = true;

  /**
   * 深浅色开关（由 EntryAbility / 课表设置页写入 AppStorage）。
   * `@Watch` 重写色表，`@StorageProp` 变化触发重建 → 各处 `C.xxx` 读到新色值。
   */
  @StorageProp('themeDark') @Watch('onThemeDarkChanged') themeDark: boolean = false;
  @State reminderMinutes: number[] = [30, 10];

  // ---------- 同步到日历 ----------
  @State syncingCalendar: boolean = false;
  @State calendarMessage: string = '';

  // ---------- 同步节假日 ----------
  @State syncingHolidays: boolean = false;
  @State holidaySyncMessage: string = '';

  // ---------- 弹窗（提醒时间选择） ----------
  @State showMinutePicker: boolean = false;
  @State pickedMinutes: number[] = [];
  @State wheelValue: number = 10;

  private holiday: HolidayManager = new HolidayManager();
  private firstMonday: number = DateUtil.mondayOf(DateUtil.today());
  private allMinutes: number[] = buildMinuteRange();

  async aboutToAppear(): Promise<void> {
    const store = StoreHolder.instance;
    this.blockStatutory = store.getBool(KEY_BLOCK_STATUTORY, true);
    this.blockSchool = store.getBool(KEY_BLOCK_SCHOOL, true);
    this.blockWeekend = store.getBool(KEY_BLOCK_WEEKEND, false);
    this.firstMonday = store.getNumber(KEY_FIRST_MONDAY, DateUtil.mondayOf(DateUtil.today()));
    this.semesterName = store.getString(KEY_SEMESTER_NAME, '');
    this.reminderEnabled = store.getBool(KEY_REMINDER_ENABLED, true);
    this.reminderMinutes = this.parseMinutes(store.getString(KEY_REMINDER_MINUTES, ''));
    this.currentWeek = this.weekOfToday();
    this.refreshHolidays();
    try {
      const courses = await store.loadAll();
      this.courseCount = courses.length;
    } catch (e) {
      this.courseCount = 0;
    }
  }

  // ==================== 计算 ====================

  /** 当前周（首周周一 → 本周周一） */
  private weekOfToday(): number {
    const w = DateUtil.weeksBetween(DateUtil.mondayOf(this.firstMonday),
      DateUtil.mondayOf(DateUtil.today())) + 1;
    return w < 1 ? 1 : w;
  }

  /** 数据来源文案：同步成功 → 权威来源；否则内置数据 */
  private sourceText(): string {
    return this.syncedFromNetwork ? SOURCE_SYNCED : SOURCE_BUILTIN;
  }

  /** 该类型在当前开关下会不会被屏蔽（补班日恒 false） */
  private willBlock(type: HolidayType): boolean {
    if (type === HolidayType.MAKEUP) {
      return false;
    }
    if (type === HolidayType.SCHOOL) {
      return this.blockSchool;
    }
    if (type === HolidayType.STATUTORY || type === HolidayType.USER_DEFINED) {
      return this.blockStatutory;
    }
    return false;
  }

  /** 单日 →「M月d日」；区间 →「M/D – M/D」（en dash，两侧各一空格） */
  private rangeText(h: Holiday): string {
    if (h.start === h.end) {
      return DateUtil.label(h.start);
    }
    const s: Ymd = DateUtil.toYmd(h.start);
    const e: Ymd = DateUtil.toYmd(h.end);
    return `${s.month}/${s.day} – ${e.month}/${e.day}`;
  }

  /** 重建假期清单（4 组，组内按开始日期升序） */
  private refreshHolidays(): void {
    const all: HolidayEntry[] = this.holiday.allHolidays();
    this.holidayCount = all.length;

    const defs: HolidayGroupDef[] = [
      new HolidayGroupDef(HolidayType.STATUTORY, '法定节假日（中国大陆）'),
      new HolidayGroupDef(HolidayType.SCHOOL, '学校假期（GLTU 校历）'),
      new HolidayGroupDef(HolidayType.MAKEUP, '调休补班日'),
      new HolidayGroupDef(HolidayType.USER_DEFINED, '自定义假期')
    ];

    const groups: HolidayGroup[] = [];
    for (let i = 0; i < defs.length; i++) {
      const def: HolidayGroupDef = defs[i];
      const entries: HolidayEntry[] = all.filter((e: HolidayEntry) => e.type === def.type);
      entries.sort((a: HolidayEntry, b: HolidayEntry) => a.holiday.start - b.holiday.start);
      const rows: HolidayRow[] = [];
      for (let j = 0; j < entries.length; j++) {
        const entry: HolidayEntry = entries[j];
        const blocked: boolean = this.willBlock(entry.type);
        let statusText: string = '未屏蔽';
        let statusColor: string = C.outline;
        if (entry.type === HolidayType.MAKEUP) {
          statusText = '照常上课';
          statusColor = C.onSurfaceVariant;
        } else if (blocked) {
          statusText = '已屏蔽';
          statusColor = C.error;
        }
        rows.push(new HolidayRow(entry.holiday.name, this.rangeText(entry.holiday),
          statusText, statusColor));
      }
      if (rows.length > 0) {
        groups.push(new HolidayGroup(`${def.label} · ${rows.length} 条`, rows));
      }
    }
    this.holidayGroups = groups;
  }

  /** "30,10" → [30, 10]（降序、去重、限制 1–60；空则默认） */
  private parseMinutes(raw: string): number[] {
    const out: number[] = [];
    if (raw.length > 0) {
      const parts: string[] = raw.split(',');
      for (let i = 0; i < parts.length; i++) {
        const n: number = parseInt(parts[i].trim(), 10);
        if (!isNaN(n) && n >= REMINDER_MIN_MINUTES && n <= REMINDER_MAX_MINUTES
          && out.indexOf(n) < 0) {
          out.push(n);
        }
      }
    }
    if (out.length === 0) {
      return REMINDER_DEFAULT_MINUTES.slice();
    }
    out.sort((a: number, b: number) => b - a);
    return out;
  }

  // ==================== 交互 ====================

  /** 三个屏蔽开关：切换后立即保存，并刷新清单里的「已屏蔽 / 未屏蔽」 */
  private onStatutory(v: boolean): void {
    this.blockStatutory = v;
    this.refreshHolidays();
    StoreHolder.instance.putBool(KEY_BLOCK_STATUTORY, v);
    // 屏蔽开关直接决定卡片显示「课程已屏蔽」还是课表
    // （Android 版漏了这处：改完设置要等 30 分钟定时刷新才生效）
    SyncDownstream.all(this.getUIContext().getHostContext());
  }

  private onSchool(v: boolean): void {
    this.blockSchool = v;
    this.refreshHolidays();
    StoreHolder.instance.putBool(KEY_BLOCK_SCHOOL, v);
    SyncDownstream.all(this.getUIContext().getHostContext());
  }

  private onWeekend(v: boolean): void {
    this.blockWeekend = v;
    this.refreshHolidays();
    StoreHolder.instance.putBool(KEY_BLOCK_WEEKEND, v);
    SyncDownstream.all(this.getUIContext().getHostContext());
  }

  /** 深浅色变化：重写色表（组件树随后重建） */
  onThemeDarkChanged(): void {
    C.applyDark(this.themeDark);
  }

  /** 同步节假日：从国务院办公厅通知（经 holiday-cn）拉取，失败回落 timor.tech */
  private async onSyncHolidays(): Promise<void> {
    if (this.syncingHolidays) {
      return;
    }
    this.syncingHolidays = true;
    this.holidaySyncMessage = '正在同步…';
    try {
      const r = await HolidaySync.sync();
      this.holidaySyncMessage = r.message;
      if (r.ok) {
        promptAction.showToast({ message: r.message });
      }
    } catch (e) {
      this.holidaySyncMessage = '同步失败：' + JSON.stringify(e);
    } finally {
      this.syncingHolidays = false;
    }
  }

  private onReminderEnabled(v: boolean): void {
    this.reminderEnabled = v;
    StoreHolder.instance.putBool(KEY_REMINDER_ENABLED, v);
    // 开关一变就重排：关掉要清掉已发布的提醒，打开要立刻排上
    this.rescheduleReminders();
  }

  /**
   * 重排上课提醒（改了开关 / 提前分钟数后调用）。
   *
   * 调休映射必须一起传进去，否则用户改过的「补周几」在提醒侧会被忽略 ——
   * 那会导致调休的周六响错课、放假的日子反而响。
   */
  private async rescheduleReminders(): Promise<void> {
    try {
      const s = StoreHolder.instance;
      const settings = new BlockSettings(
        s.getBool(KEY_BLOCK_STATUTORY, true),
        s.getBool(KEY_BLOCK_SCHOOL, true),
        s.getBool(KEY_BLOCK_WEEKEND, false),
      );
      const overrides = MakeupResolver.decodeOverrides(s.getString('makeup_overrides', ''));
      const courses = await s.loadAll();
      const firstMonday = s.getNumber(KEY_FIRST_MONDAY, DateUtil.mondayOf(DateUtil.today()));
      const n = await ClassReminderScheduler.reschedule(
        new HolidayManager(), overrides, courses, firstMonday, settings);
      if (!this.reminderEnabled) {
        promptAction.showToast({ message: '已关闭上课提醒' });
      } else if (n === 0) {
        promptAction.showToast({ message: '近期没有要提醒的课' });
      } else {
        promptAction.showToast({ message: `已排 ${n} 条上课提醒` });
      }
    } catch (e) {
      promptAction.showToast({ message: '提醒设置失败，请检查通知权限' });
    }
  }

  private openMinutePicker(): void {
    const picked: number[] = this.reminderMinutes.slice();
    this.pickedMinutes = picked;
    this.wheelValue = picked.length > 0 ? picked[0] : 10;
    this.showMinutePicker = true;
  }

  private addPicked(): void {
    const v: number = this.wheelValue;
    if (this.pickedMinutes.indexOf(v) >= 0) {
      return;
    }
    const next: number[] = this.pickedMinutes.slice();
    next.push(v);
    next.sort((a: number, b: number) => b - a);
    this.pickedMinutes = next;
  }

  private removePicked(m: number): void {
    this.pickedMinutes = this.pickedMinutes.filter((x: number) => x !== m);
  }

  /** 保存（全删则回退默认 30、10），并落盘 */
  private confirmMinutes(): void {
    const list: number[] = this.pickedMinutes.length > 0
      ? this.pickedMinutes.slice()
      : REMINDER_DEFAULT_MINUTES.slice();
    list.sort((a: number, b: number) => b - a);
    this.reminderMinutes = list;
    this.showMinutePicker = false;
    StoreHolder.instance.putString(KEY_REMINDER_MINUTES, list.join(','));
    // 提前分钟数变了 → 必须重排，否则还是按旧时间响
    this.rescheduleReminders();
  }

  // ==================== UI ====================

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column({ space: D.cardGap }) {
          // ---------- 标题 ----------
          Text('设置')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(C.onSurface)
            .width('100%')

          // ---------- 获取课表 ----------
          this.titleCard('获取课表', '三种方式任选，也可以混用')
          this.actionCard('① 手动添加课程',
            '自己录入课程名/地点/时间，最稳妥，不依赖学校系统', '去添加', 'edit')
          this.actionCard('② 课表分享码',
            '导入同学分享的课表，或把自己的课表导出给对方', '导出 / 导入分享码', 'share')
          this.actionCard('③ 教务系统导入',
            'App 里打开教务系统网页，你自己登录并进入课表页，再点「确定导入」自动解析',
            '进入教务系统导入', 'import')

          // ---------- 当前学期 ----------
          this.semesterCard()

          // ---------- 节假日屏蔽课程 ----------
          this.holidayCard()

          // ---------- 上课提醒 ----------
          this.reminderCard()

          // ---------- 同步到手机日历 ----------
          this.calendarCard()

          // ---------- 关于 ----------
          this.aboutCard()
        }
        .width('100%')
        // 底部多留一段，否则最后一张卡片会被悬浮胶囊压住。
        // 长度由父组件按胶囊当前状态传进来。
        .padding({ left: D.pagePad, right: D.pagePad, top: D.pagePad, bottom: this.navClear })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
      .onDidScroll((xOffset: number, yOffset: number, state: ScrollState) => {
        this.onScrollDir(yOffset);
      })
      .backgroundColor(C.pageBg)

      // ---------- 弹窗：提醒时间选择 ----------
      if (this.showMinutePicker) {
        this.minutePickerOverlay()
      }
    }
    .width('100%')
    // ⚠️ 必须是 layoutWeight(1)，不能用 height('100%')：
    // 底部 Tab 栏是本组件的**兄弟节点**（同在根 Column 里），
    // 用 height('100%') 会变成「本页 100% + 底栏 58vp」超出屏幕，
    // 底栏被挤到屏幕外 —— 这就是「点设置后工具栏位移」的 bug。
    .layoutWeight(1)
    .backgroundColor(C.pageBg)
  }

  /** 只有标题 + 副标题的卡片 */
  @Builder
  titleCard(title: string, subtitle: string) {
    Column() {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(C.onSurface)
      Text(subtitle)
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(D.cardPad)
    .backgroundColor(C.card)
    .borderRadius(D.cardRadius)
  }

  /** 标题 + 副标题 + 文字按钮（TextButton 观感） */
  @Builder
  actionCard(title: string, subtitle: string, action: string, route: string) {
    Column() {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(C.onSurface)
      Text(subtitle)
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .margin({ top: 4 })
      Text(action)
        .fontSize(14)
        .fontColor(C.primary)
        .padding({ left: 0, right: 12, top: 8, bottom: 4 })
        .onClick(() => {
          this.onNavigate(route);
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(D.cardPad)
    .backgroundColor(C.card)
    .borderRadius(D.cardRadius)
  }

  /** 当前学期 */
  @Builder
  semesterCard() {
    Column() {
      Text('当前学期')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(C.onSurface)
      Text(`${this.semesterName.length > 0 ? this.semesterName : '未设置'} · 第 ${this.currentWeek} 周`)
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .margin({ top: 4 })
      Text(`课表共 ${this.courseCount} 门课`)
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(D.cardPad)
    .backgroundColor(C.card)
    .borderRadius(D.cardRadius)
  }

  /** 节假日屏蔽课程（三个独立开关 + 同步 + 已收录假期清单） */
  @Builder
  holidayCard() {
    Column({ space: 8 }) {
      Text('节假日屏蔽课程')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(C.onSurface)

      Text('只识别【中国大陆】法定节假日（元旦 / 春节 / 清明节 / 劳动节 / 端午节 / 中秋节 / 国庆节）' +
        '以及国务院办公厅公布的调休补班日，不含任何其他国家或地区的节日。')
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)

      Text(`已收录 ${this.holidayCount} 条记录，来源：${this.sourceText()}`)
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)

      Text('自动同步：打开 App 时检查一次，另外每天凌晨 3:30 后台自动更新一次；' +
        '国务院办公厅通常在前一年 11 月发布次年放假安排，那段时间若还没拿到次年数据会每 3 天重试一次。')
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)

      // 三个互相独立的屏蔽开关（整行不可点，只有开关可切换）
      Column() {
        this.switchRow('屏蔽法定节假日',
          '元旦 / 春节 / 清明节 / 劳动节 / 端午节 / 中秋节 / 国庆节',
          this.blockStatutory, (v: boolean) => {
            this.onStatutory(v);
          })
        this.switchRow('屏蔽学校假期',
          '校运会 / 寒假 / 暑假（来自 GLTU 校历）',
          this.blockSchool, (v: boolean) => {
            this.onSchool(v);
          })
        this.switchRow('屏蔽日常周末',
          '周六、周日',
          this.blockWeekend, (v: boolean) => {
            this.onWeekend(v);
          })
        Text('补班日（调休上班的周末）不受以上开关影响，一律照常上课；' +
          '三个开关互相独立，可任意组合。')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .margin({ top: 2 })
      }
      .width('100%')

      // 同步节假日
      Row() {
        Text('同步节假日')
          .fontSize(14)
          .fontColor(C.primary)
          .padding({ left: 0, right: 12, top: 6, bottom: 6 })
          .onClick(() => {
            this.onSyncHolidays();
          })
        Text('尚未同步（使用内置数据）')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 已收录假期清单（用户可自行核对是不是中国大陆的节日）
      Text(this.showHolidayList ? '收起假期清单'
        : `查看已收录的假期清单（${this.holidayCount} 条）`)
        .fontSize(14)
        .fontColor(C.primary)
        .padding({ top: 6, bottom: 6 })
        .onClick(() => {
          this.showHolidayList = !this.showHolidayList;
        })

      if (this.showHolidayList) {
        Column({ space: 2 }) {
          ForEach(this.holidayGroups, (group: HolidayGroup) => {
            Text(group.label)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(C.primary)
              .margin({ top: 10, bottom: 2 })
            ForEach(group.items, (row: HolidayRow) => {
              Row() {
                Text(row.name)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(C.onSurface)
                  .width(96)
                Text(row.dateText)
                  .fontSize(12)
                  .fontColor(C.onSurfaceVariant)
                  .layoutWeight(1)
                Text(row.statusText)
                  .fontSize(10)
                  .fontColor(row.statusColor)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: 2, bottom: 2 })
            }, (row: HolidayRow, idx: number) => `hr-${group.label}-${idx}`)
          }, (group: HolidayGroup) => `hg-${group.label}`)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(D.cardPad)
    .backgroundColor(C.card)
    .borderRadius(D.cardRadius)
  }

  /** 上课提醒 */
  @Builder
  reminderCard() {
    Column() {
      Row() {
        Column() {
          Text('上课提醒')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(C.onSurface)
          Text(`课前 ${this.reminderMinutes.join('、')} 分钟各提醒一次`)
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.reminderEnabled })
          .selectedColor(C.primary)
          .onChange((v: boolean) => {
            this.onReminderEnabled(v);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('选择提醒时间（1–60 分钟）')
        .fontSize(14)
        .fontColor(this.reminderEnabled ? C.primary : C.outline)
        .padding({ left: 0, right: 12, top: 8, bottom: 4 })
        .onClick(() => {
          if (this.reminderEnabled) {
            this.openMinutePicker();
          }
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(D.cardPad)
    .backgroundColor(C.card)
    .borderRadius(D.cardRadius)
  }

  /**
   * 一键同步课表到系统日历。
   *
   * 日历是「先清理上次同步的条目，再写入」；调休规则一起传进去，
   * 课被搬到调休日的会在描述里标注「调休补课」。
   */
  private async onSyncCalendar(): Promise<void> {
    if (this.syncingCalendar) {
      return;
    }
    this.syncingCalendar = true;
    this.calendarMessage = '';
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (ctx === undefined) {
        this.calendarMessage = '同步失败：拿不到应用上下文';
        return;
      }
      // 鸿蒙的日历权限是 user_grant，必须运行时申请
      const granted = await CalendarSync.requestPermission(ctx);
      if (!granted) {
        this.calendarMessage = '未授予日历权限，无法同步';
        return;
      }

      const s = StoreHolder.instance;
      const courses = await s.loadAll();
      const firstMonday = s.getNumber(KEY_FIRST_MONDAY, DateUtil.mondayOf(DateUtil.today()));
      const overrides = MakeupResolver.decodeOverrides(s.getString('makeup_overrides', ''));
      const holiday = new HolidayManager();
      const rules = MakeupResolver.resolve(holiday.allHolidays(), overrides);
      const settings = new BlockSettings(
        s.getBool(KEY_BLOCK_STATUTORY, true),
        s.getBool(KEY_BLOCK_SCHOOL, true),
        s.getBool(KEY_BLOCK_WEEKEND, false),
      );
      const r: SyncResult = await CalendarSync.sync(
        ctx, courses, firstMonday, rules,
        (d: number) => holiday.isBlocked(d, settings));
      this.calendarMessage = r.message;
    } catch (e) {
      this.calendarMessage = '同步失败：' + JSON.stringify(e);
    } finally {
      this.syncingCalendar = false;
    }
  }

  /** 同步到手机日历 */
  @Builder
  calendarCard() {    Column() {
      Text('同步到手机日历')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(C.onSurface)
      Text('把课表一次性写进系统日历，可在日历 App 里查看、也能随账号同步到其他设备。' +
        '周次连续的课会写成「每周重复」，单双周等不规则周次会逐次写入。')
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .margin({ top: 4 })
      Row() {
        Text(this.syncingCalendar ? '同步中…' : '一键同步课表到日历')
          .fontSize(14)
          .fontColor(this.syncingCalendar ? C.outline : C.primary)
          .padding({ left: 0, right: 12, top: 6, bottom: 6 })
          .onClick(() => {
            this.onSyncCalendar();
          })
        Text('重复点击会先清理上次同步的条目，不会重复')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(D.cardPad)
    .backgroundColor(C.card)
    .borderRadius(D.cardRadius)
  }

  /** 关于 */
  @Builder
  aboutCard() {
    Column({ space: 6 }) {
      Row() {
        Text(AppInfo.NAME)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
        Text(`v${AppInfo.version()}`)
          .fontSize(12)
          .fontColor(C.onPrimaryContainer)
          .backgroundColor(C.primaryContainer)
          .borderRadius(6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider()
        .strokeWidth(0.5)
        .color(C.outlineVariant)

      Row() {
        Text('作者：')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
        Text(AppInfo.AUTHOR)
          .fontSize(12)
          .fontColor(C.onSurface)
      }
      .width('100%')

      Row() {
        Text('开源：')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
        Text('本软件已在 GitHub 开源，欢迎 Star / Issue / PR')
          .fontSize(12)
          .fontColor(C.onSurface)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Text(AppInfo.TECH)
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(D.cardPad)
    .backgroundColor(C.card)
    .borderRadius(D.cardRadius)
    .margin({ bottom: 8 })
  }

  /** 一行设置项：左标题 + 说明，右开关（整行不可点，只有开关可切换） */
  @Builder
  switchRow(title: string, subtitle: string, checked: boolean, onToggle: (v: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(C.onSurface)
        Text(subtitle)
          .fontSize(11)
          .fontColor(C.onSurfaceVariant)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(C.primary)
        .onChange((v: boolean) => {
          onToggle(v);
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  // ==================== 弹窗：提醒时间（1–60 分钟，可多选） ====================

  @Builder
  minutePickerOverlay() {
    Column() {
      // 遮罩（点击关闭）
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.showMinutePicker = false;
        })

      // 弹窗主体
      Column() {
        Text('提醒时间')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .margin({ bottom: 12 })

        Text('已选提醒（点一下可删除）')
          .fontSize(12)
          .fontColor(C.onSurface)
          .width('100%')

        if (this.pickedMinutes.length === 0) {
          Text('还没有选任何时间')
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .width('100%')
            .margin({ top: 6 })
        } else {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.pickedMinutes, (m: number) => {
              Text(`${m} 分钟 ✕`)
                .fontSize(13)
                .fontColor(C.primary)
                .backgroundColor(Col.alpha(C.primary, 0.12))
                .borderRadius(14)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ right: 6, bottom: 6 })
                .onClick(() => {
                  this.removePicked(m);
                })
            }, (m: number) => `pm-${m}`)
          }
          .width('100%')
          .margin({ top: 6 })
        }

        Text('滚动选择要添加的分钟数')
          .fontSize(12)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ top: 10 })

        Scroll() {
          Row() {
            ForEach(this.allMinutes, (m: number) => {
              Text(`${m}`)
                .fontSize(14)
                .fontColor(this.wheelValue === m ? Color.White : C.onSurface)
                .backgroundColor(this.wheelValue === m ? C.primary : C.surfaceVariant)
                .borderRadius(16)
                .width(44)
                .height(40)
                .textAlign(TextAlign.Center)
                .margin({ right: 6 })
                .onClick(() => {
                  this.wheelValue = m;
                })
            }, (m: number) => `wm-${m}`)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(56)
        .margin({ top: 6 })

        Button(`添加：课前 ${this.wheelValue} 分钟`)
          .width('100%')
          .height(42)
          .margin({ top: 10 })
          .onClick(() => {
            this.addPicked();
          })

        if (this.pickedMinutes.length > 4) {
          Text('提示：选太多会收到很多通知，建议不超过 3 个')
            .fontSize(12)
            .fontColor(C.error)
            .margin({ top: 6 })
        }

        Row() {
          Text('取消')
            .fontSize(14)
            .fontColor(C.primary)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              this.showMinutePicker = false;
            })
          Text('保存')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(C.primary)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              this.confirmMinutes();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 22, topRight: 22 })
    }
    .width('100%')
    .height('100%')
  }
}
