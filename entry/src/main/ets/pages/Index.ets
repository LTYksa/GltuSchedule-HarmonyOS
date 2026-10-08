/**
 * GltuSchedule · 鸿蒙版 —— 根页面
 *
 * 结构 1:1 对齐 Android 版 `ui/navigation/AppNavigation.kt` + `ui/schedule/ScheduleScreen.kt`：
 *   · 一级页面（课表 / 设置）显示底部导航；二级页面（编辑课程 / 分享 / 教务导入）显示置顶返回栏并隐藏底部导航
 *   · 课表页：☰ 左侧栏(62%宽) / ‹第N周▾› / 周日切换 / ＋ / 日期行 / 节次轴 / 网格线 / 左色条课块 / 日视图
 *   · 周次选择弹窗、课程详情弹窗（编辑/删除/关闭）、删除二次确认
 *
 * 与 Android 的差异（鸿蒙化）：抽屉与弹窗用 Stack 覆盖层自实现
 * （bindSheet 在本机 SDK 上运行时静默失效），其余尺寸/配色/文案逐条对齐。
 */
import { promptAction, window } from '@kit.ArkUI';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { Course } from '../model/Course';
import { GltuTimeTable, TimeSlot } from '../data/TimeSlot';
import { Classroom } from '../data/Classroom';
import { BackgroundImageStore, DecodedImage } from '../data/BackgroundImageStore';
import { CropMath, CropGeometry } from '../data/CropGeometry';
import { HolidaySync } from '../data/HolidaySync';
import { CourseColor } from '../data/CourseColor';
import { DateUtil } from '../data/DateUtil';
import { BlockSettings, HolidayManager } from '../data/Holiday';
import { MakeupRule, MakeupResolver } from '../data/MakeupRule';
import { StoreHolder } from '../database/CourseStore';
import { C, D, Col } from '../common/Palette';
import { SyncDownstream } from '../common/SyncDownstream';
import { SettingsPage } from './SettingsPage';
import { EditCoursePage } from './EditCoursePage';
import { SharePage } from './SharePage';
import { WebImportPage } from './WebImportPage';

/** 星期项（受「每周起始日」影响顺序） */
class WeekDay {
  label: string = '';
  /** 1=周一 … 7=周日 */
  value: number = 1;
  constructor(label: string, value: number) {
    this.label = label;
    this.value = value;
  }
}

const MONDAY_FIRST: WeekDay[] = [
  new WeekDay('一', 1), new WeekDay('二', 2), new WeekDay('三', 3), new WeekDay('四', 4),
  new WeekDay('五', 5), new WeekDay('六', 6), new WeekDay('日', 7)
];

/** 周一~周日（调休补课选择「补周几」用） */
const WEEKDAYS: number[] = [1, 2, 3, 4, 5, 6, 7];

/** 周视图一格内的课块排布 */
class CellLayout {
  course: Course = new Course();
  lane: number = 0;
  lanes: number = 1;
  rowStart: number = 0;
  rowSpan: number = 1;
  dimmed: boolean = false;
  /** 是否是调休日补上来的课（要打「调」字标记） */
  makeup: boolean = false;
}

/** 日期行一项 */
class DateCell {
  label: string = '';
  day: number = 1;
  date: number = 0;
  weekdayValue: number = 1;
  isToday: boolean = false;
  isSelected: boolean = false;
  /** 假期名 / 调休标记（始终显示，不随屏蔽开关变化） */
  holidayLabel: string = '';
  blocked: boolean = false;
  /** 是否是调休上班日（要补课） */
  isMakeup: boolean = false;
}

@Entry
@Component
struct Index {
  // ---------- 路由 ----------
  @State route: string = 'schedule'; // 'schedule' | 'settings' | 'edit' | 'share' | 'import'
  @State navIndex: number = 0;
  /**
   * 底栏是否收起（向上滑时为 true）。
   * 参考鸿蒙电话/联系人应用：向上滑 → 胶囊变矮、去掉文字、沉下去；
   * 向下滑 → 复原。切换页面会重置为展开。
   */
  @State navCollapsed: boolean = false;
  /**
   * 小白条（底部手势指示条）高度，单位 vp。
   * 因为改成了**全屏铺满**（expandSafeArea 到底），胶囊必须自己避开它，
   * 不能再依赖系统自动留白。
   */
  @State navIndicatorH: number = 0;
  /** 上次处理滚动方向的时间戳，用于节流（滚动事件每帧都来） */
  private lastScrollAt: number = 0;
  @State editCourseId: number = 0;

  // ---------- 课程与周次 ----------
  @State courses: Course[] = [];
  @State week: number = 1;
  @State viewMode: number = 0; // 0=周 1=日
  @State selectedDay: number = 1;

  // ---------- 学期 ----------
  @State firstMonday: number = DateUtil.mondayOf(DateUtil.today());
  @State startDateRaw: number = DateUtil.today();
  @State semesterName: string = '';

  // ---------- 偏好 ----------
  @State maxPeriods: number = 13;
  @State weekStart: number = 1;
  @State showAllWeeks: boolean = false;
  @State themeMode: number = 0;
  /**
   * 深浅色开关（由 EntryAbility / 设置页写入 AppStorage）。
   * `@Watch` 里重写色表，`@StorageProp` 本身的变化会触发组件树重建，
   * 重建时各处 `.fontColor(C.xxx)` 就读到新色值 —— 这是本工程不用
   * `$r('app.color.xxx')` 资源引用也能支持深色的关键。
   */
  @StorageProp('themeDark') @Watch('onThemeDarkChanged') themeDark: boolean = false;
  @State blockStatutory: boolean = true;
  @State blockSchool: boolean = true;
  @State blockWeekend: boolean = false;

  // ---------- 覆盖层（'' = 无）----------
  @State panel: string = '';
  @State detail: Course = new Course();

  // ---------- 抽屉子对话框临时值 ----------
  @State tmpSemester: string = '';
  @State tmpStatutory: boolean = true;
  @State tmpSchool: boolean = true;
  @State tmpWeekend: boolean = false;

  // ---------- 调休（补课）----------
  /** 全部调休规则（自动推导 + 手动覆盖） */
  @State makeupRuleList: MakeupRule[] = [];
  /** 弹窗里当前正在改的那一天 */
  @State tmpMakeupDate: number = 0;

  // ---------- 壁纸 ----------
  /** 是否已设置自定义壁纸（影响课块底色透明度） */
  @State hasWallpaper: boolean = false;
  /** 壁纸位图；undefined = 用纯色底 */
  @State wallpaper: image.PixelMap | undefined = undefined;

  // ---------- 壁纸裁切 ----------
  /** 待裁切的原图（选完图、点「使用这张」之前都在这儿） */
  @State cropSrc: DecodedImage = new DecodedImage();
  /** 当前缩放（px/px，与 Android 同量纲） */
  @State cropScale: number = 1;
  /** 铺满所需的最小缩放 */
  @State cropMinScale: number = 1;
  /** 位移（px） */
  @State cropOffX: number = 0;
  @State cropOffY: number = 0;
  /** 课表内容区尺寸（px）—— 必须用**实际显示区**，不能用整屏：
   *  本 App 有底部导航，壁纸只铺内容区，比例算错会导致画面被拉伸。 */
  @State contentW: number = 0;
  @State contentH: number = 0;
  /** 手势起始基准（PinchGesture/PanGesture 的 event 是**累计值**） */
  private pinchBase: number = 1;
  private panBaseX: number = 0;
  private panBaseY: number = 0;
  /** 「设置当前周次」输入框 */
  @State tmpWeekInput: string = '1';
  private makeupOfDate: Map<number, MakeupRule> = new Map<number, MakeupRule>();

  private holiday: HolidayManager = new HolidayManager();

  // ==================== 生命周期 ====================

  async aboutToAppear(): Promise<void> {
    this.loadPrefs();
    this.refreshMakeup();
    await this.loadWallpaper();
    await this.loadNavIndicatorHeight();
    await this.reload();
  }

  /** 读壁纸（没有就保持纯色底） */
  private async loadWallpaper(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    try {
      const pm = await BackgroundImageStore.load(ctx);
      this.wallpaper = pm;
      this.hasWallpaper = pm !== undefined;
    } catch (e) {
      this.wallpaper = undefined;
      this.hasWallpaper = false;
    }
  }

  /** 移除壁纸 */
  private removeWallpaper(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    BackgroundImageStore.clear(ctx);
    this.wallpaper = undefined;
    this.hasWallpaper = false;
  }

  private loadPrefs(): void {
    const s = StoreHolder.instance;
    this.firstMonday = s.getNumber('first_monday', DateUtil.mondayOf(DateUtil.today()));
    this.startDateRaw = s.getNumber('start_date_raw', this.firstMonday);
    this.semesterName = s.getString('semester_name', '');
    this.maxPeriods = s.getNumber('max_periods', 13);
    this.weekStart = s.getNumber('week_start', 1);
    this.showAllWeeks = s.getBool('show_all_weeks', false);
    this.themeMode = s.getNumber('theme_mode', 0);
    this.blockStatutory = s.getBool('block_statutory', true);
    this.blockSchool = s.getBool('block_school', true);
    this.blockWeekend = s.getBool('block_weekend', false);
    this.selectedDay = DateUtil.weekday(DateUtil.today());
    this.week = this.currentWeek();
  }

  /**
   * 重算调休规则（假期数据或手动覆盖变化后调用）。
   *
   * 推导算法在 `data/MakeupRule.ets`；这里是「读覆盖 → 推导 → 建索引」的胶水。
   */
  private refreshMakeup(): void {
    // 先用上次联网同步到的节假日覆盖内置数据（没同步过就沿用内置）
    const synced = HolidaySync.loadFromStore();
    if (synced.statutory.length > 0 || synced.makeup.length > 0) {
      this.holiday.setSynced(synced.statutory, synced.makeup);
    }
    const overrides = MakeupResolver.decodeOverrides(
      StoreHolder.instance.getString('makeup_overrides', ''));
    this.makeupRuleList = MakeupResolver.resolve(this.holiday.allHolidays(), overrides);
    this.makeupOfDate = MakeupResolver.byDate(this.makeupRuleList);
  }

  /** 某天实际要上「哪一天」的课（调休日 → 源日期） */
  private effectiveDate(date: number): number {
    return MakeupResolver.effectiveDate(this.makeupRuleList, date);
  }

  /** 某天的调休规则；不是调休日返回 undefined */
  private makeupOf(date: number): MakeupRule | undefined {
    return this.makeupOfDate.get(date);
  }

  /** 手动指定某天补周几的课 */
  private async setMakeupOverride(date: number, weekday: number): Promise<void> {
    const overrides = MakeupResolver.decodeOverrides(
      StoreHolder.instance.getString('makeup_overrides', ''));
    overrides.set(date, weekday);
    await StoreHolder.instance.putString('makeup_overrides',
      MakeupResolver.encodeOverrides(overrides));
    this.refreshMakeup();
    // 卡片按调休映射查课，改了覆盖要立刻重算
    SyncDownstream.all(this.getUIContext().getHostContext());
  }

  /** 清除手动覆盖，回到自动推导 */
  private async clearMakeupOverride(date: number): Promise<void> {
    const overrides = MakeupResolver.decodeOverrides(
      StoreHolder.instance.getString('makeup_overrides', ''));
    overrides.delete(date);
    await StoreHolder.instance.putString('makeup_overrides',
      MakeupResolver.encodeOverrides(overrides));
    this.refreshMakeup();
    SyncDownstream.all(this.getUIContext().getHostContext());
  }

  /**
   * 设置当前是第几周。
   * 用「本周周一 − (N−1) 周」反推开学日期 —— 用户往往不知道开学日期，但一定知道这周是第几周。
   */
  private async setCurrentWeek(week: number): Promise<void> {
    const w = Math.max(1, Math.min(30, week));
    const thisMonday = DateUtil.mondayOf(DateUtil.today());
    const startDate = thisMonday - (w - 1) * 7;
    this.startDateRaw = startDate;
    this.firstMonday = DateUtil.mondayOf(startDate);
    // 重新锚定之后，「今天」落在第几周就由 new firstMonday 推出来。
    // 这里用 currentWeek() 而不是直接写 w —— 语义上我们改的是"今天是第几周"，
    // 视图跟着"今天所在的周"走，而不是"跳转到用户填的那个数字"。
    this.week = this.currentWeek();
    const s = StoreHolder.instance;
    await s.putNumber('start_date_raw', this.startDateRaw);
    await s.putNumber('first_monday', this.firstMonday);
    if (this.semesterName.length === 0) {
      this.semesterName = '手动设置';
      await s.putString('semester_name', this.semesterName);
    }
    // 「第一周周一」变了 → 卡片标题里的「第 N 周」和当天要上的课都要重算
    SyncDownstream.all(this.getUIContext().getHostContext());
  }

  async reload(): Promise<void> {
    try {
      this.courses = await StoreHolder.instance.loadAll();
    } catch (e) {
      this.courses = [];
    }
  }

  // ==================== 计算 ====================

  private currentWeek(): number {
    const w = DateUtil.weeksBetween(this.firstMonday, DateUtil.mondayOf(DateUtil.today())) + 1;
    return w < 1 ? 1 : w;
  }

  private settings(): BlockSettings {
    return new BlockSettings(this.blockStatutory, this.blockSchool, this.blockWeekend);
  }

  /** 星期列顺序：起始日为周日时把周日挪到最前 */
  private dayOrder(): WeekDay[] {
    if (this.weekStart === 7) {
      return [MONDAY_FIRST[6], MONDAY_FIRST[0], MONDAY_FIRST[1], MONDAY_FIRST[2],
        MONDAY_FIRST[3], MONDAY_FIRST[4], MONDAY_FIRST[5]];
    }
    return MONDAY_FIRST;
  }

  /** 本周 7 天的日期序号（顺序与 dayOrder 一致） */
  private weekDates(): number[] {
    const monday = this.firstMonday + (this.week - 1) * 7;
    const base = this.weekStart === 7 ? monday - 1 : monday;
    const list: number[] = [];
    for (let i = 0; i < 7; i++) {
      list.push(base + i);
    }
    return list;
  }

  private dateOfWeekday(dow: number): number {
    return this.firstMonday + (this.week - 1) * 7 + (dow - 1);
  }

  /** 日期行数据：假期名始终显示，屏蔽只影响颜色与是否排课 */
  private dateCells(): DateCell[] {
    const dates = this.weekDates();
    const order = this.dayOrder();
    const today = DateUtil.today();
    const result: DateCell[] = [];
    for (let i = 0; i < order.length; i++) {
      const d = dates[i];
      const blocked = this.holiday.isBlocked(d, this.settings());
      // 调休标记优先于假期名（调休日不是假期）
      const mk = this.makeupOf(d);
      let label = '';
      let isMakeup = false;
      if (mk !== undefined) {
        isMakeup = true;
        label = `调·${DateUtil.weekdayLabel(mk.sourceWeekday())}`;
      } else {
        label = this.holiday.holidayNameOf(d);
        if (label.length === 0 && blocked && HolidayManager.isWeekend(d)) {
          label = '周末';
        }
      }
      const cell = new DateCell();
      cell.label = order[i].label;
      cell.day = DateUtil.toYmd(d).day;
      cell.date = d;
      cell.weekdayValue = order[i].value;
      cell.isToday = d === today;
      cell.isSelected = order[i].value === this.selectedDay;
      cell.holidayLabel = label;
      cell.blocked = blocked;
      cell.isMakeup = isMakeup;
      result.push(cell);
    }
    return result;
  }

  /** 某天属于第几周（以 firstMonday 为第 1 周） */
  private weekOf(date: number): number {
    return DateUtil.weeksBetween(this.firstMonday, DateUtil.mondayOf(date)) + 1;
  }

  /** 选壁纸 → 进入裁切（把「选」和「存」拆开，中间插裁切界面） */
  private async onPickWallpaper(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    const uri = await BackgroundImageStore.pick();
    if (uri.length === 0) {
      promptAction.showToast({ message: '未选择图片' });
      return;
    }
    const img = await BackgroundImageStore.decodeForEdit(uri);
    if (!img.ok) {
      promptAction.showToast({ message: '图片读取失败，请换一张试试' });
      return;
    }
    this.cropSrc = img;
    const vw = this.contentW > 0 ? this.contentW : 1080;
    const vh = this.contentH > 0 ? this.contentH : 2000;
    this.cropMinScale = CropMath.minScale(img.width, img.height, vw, vh);
    this.cropScale = this.cropMinScale;
    this.cropOffX = 0;
    this.cropOffY = 0;
    this.panel = 'crop';
  }

  /** 铺满屏幕：回到初始缩放与零位移 */
  private cropFill(): void {
    this.cropScale = this.cropMinScale;
    this.cropOffX = 0;
    this.cropOffY = 0;
  }

  /** 取消裁切（顺手释放原图） */
  private cropCancel(): void {
    const pm = this.cropSrc.pixelMap;
    if (pm !== undefined) {
      try {
        pm.release();
      } catch (e) {
      }
    }
    this.cropSrc = new DecodedImage();
    this.panel = 'theme';
  }

  /**
   * 确认裁切：按 `CropMath.compute` 的结果从原图裁出视口并缩放到输出尺寸，然后存盘。
   *
   * `cropSync` 的区域必须是整数且不能越界 → 向外/向内取整后再夹到图片范围内。
   */
  private async applyCrop(): Promise<void> {
    const img = this.cropSrc;
    const srcPm = img.pixelMap;
    if (srcPm === undefined || !img.ok) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    const vw = this.contentW > 0 ? this.contentW : 1080;
    const vh = this.contentH > 0 ? this.contentH : 2000;
    const g = CropMath.compute(img.width, img.height, this.cropScale, this.cropOffX, this.cropOffY, vw, vh);
    if (g === undefined) {
      promptAction.showToast({ message: '裁切参数异常，请重试' });
      return;
    }

    let out: image.PixelMap | undefined = undefined;
    try {
      out = srcPm.cloneSync();
      // 原图裁剪区：向内取整 + 夹到图片范围（cropSync 越界会抛）
      let cx = Math.ceil(g.cropX());
      let cy = Math.ceil(g.cropY());
      let cw = Math.floor(g.cropW());
      let ch = Math.floor(g.cropH());
      if (cx < 0) {
        cx = 0;
      }
      if (cy < 0) {
        cy = 0;
      }
      if (cx + cw > img.width) {
        cw = img.width - cx;
      }
      if (cy + ch > img.height) {
        ch = img.height - cy;
      }
      if (cw <= 0 || ch <= 0) {
        promptAction.showToast({ message: '裁切区域无效，请重试' });
        return;
      }
      out.cropSync({ x: cx, y: cy, size: { width: cw, height: ch } });
      out.scaleSync(g.outW / cw, g.outH / ch);

      const ok = await BackgroundImageStore.savePixelMap(ctx, out);
      if (ok) {
        this.cropCancel();          // 释放原图并关掉裁切屏
        await this.loadWallpaper();
        promptAction.showToast({ message: '壁纸已设置，已铺满课表区域' });
      } else {
        promptAction.showToast({ message: '壁纸保存失败，请换一张试试' });
      }
    } catch (e) {
      promptAction.showToast({ message: '裁切失败，请换一张试试' });
    } finally {
      if (out !== undefined) {
        try {
          out.release();
        } catch (e) {
        }
      }
    }
  }

  /** px → vp（裁切几何全用 px，ArkUI 布局用 vp） */
  private toVp(px: number): number {
    return this.getUIContext().px2vp(px);
  }

  /**
   * 内容滚动 → 底栏收起 / 展开。
   *
   * 阈值 1.5vp 滤掉惯性滚动末尾的抖动；120ms 最小间隔避免来回抖时反复打断动画。
   */
  private onContentScroll(yOffset: number): void {
    if (this.isSecondary()) {
      return;
    }
    const now = new Date().getTime();
    if (now - this.lastScrollAt < 120) {
      return;
    }
    if (yOffset > 1.5 && !this.navCollapsed) {
      this.lastScrollAt = now;
      this.animateNav(true);
    } else if (yOffset < -1.5 && this.navCollapsed) {
      this.lastScrollAt = now;
      this.animateNav(false);
    }
  }

  /** 收起/展开底栏（带动画） */
  private animateNav(collapsed: boolean): void {
    this.getUIContext().animateTo({
      duration: D.navAnimMs,
      // Friction 是鸿蒙做这类「跟手→回弹」动效的常用曲线，
      // 起步快、收尾缓，与视频里的手感一致
      curve: Curve.Friction
    }, () => {
      this.navCollapsed = collapsed;
    });
  }

  /** vp → px（手势事件是 vp） */
  private toPx(vp: number): number {
    return this.getUIContext().vp2px(vp);
  }

  // ==================== 悬浮胶囊的占位计算 ====================

  /**
   * 读小白条高度。
   * `AvoidAreaType.TYPE_NAVIGATION_INDICATOR`（=4）就是底部那条手势指示条。
   *
   * 这一步的关系重大：全屏铺满后系统不再帮忙留白，
   * 胶囊的位置**完全**由这个值决定，读错了胶囊就会离底部过远或压住小白条。
   */
  private async loadNavIndicatorHeight(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      let h = this.toVp(area.bottomRect.height);
      // 小白条本身很薄（几 vp）。若系统返回的是整个手势区高度（几十 vp），
      // 那属于「安全区」而不是「小白条」，直接拿来当留白会让胶囊离底太远。
      // 所以这里只取到 10vp 封顶。
      if (h < 0 || h > 10) {
        h = 0;
      }
      this.navIndicatorH = h;
    } catch (e) {
      // 拿不到就按 0 处理（不避让也比崩了强）
      this.navIndicatorH = 0;
    }
  }

  /** 胶囊底边距屏幕底部的距离（含小白条避让） */
  private navBottomMargin(): number {
    const base = this.navCollapsed ? D.navMinBottom : D.floatNavBottom;
    return base + this.navIndicatorH;
  }

  /**
   * 胶囊当前占用的总高度 —— 页面据此预留尾部空间。
   *
   * ⚠️ 必须**跟着收起状态变**：之前固定写死 100，收起时胶囊只占 58，
   * 于是滚到底会多出 40 多 vp 的死白，就是「最后一行和胶囊间距不对」那个 bug。
   */
  private navClearance(): number {
    const base = this.navCollapsed
      ? D.navMinH + D.navMinBottom
      : D.floatNavH + D.floatNavBottom;
    return base + this.navIndicatorH + D.navGap;
  }

  // ==================== 覆盖层：壁纸裁切 ====================

  /**
   * 壁纸裁切屏。
   *
   * 交互与 Android 版一致：双指缩放、单指拖动、所见即所得。
   * 关键点：
   *   · 视口尺寸 = **课表内容区**（不是整屏）—— 本 App 有底部导航，
   *     壁纸只铺内容区，用整屏比例算出来的图会被拉伸
   *   · 手势 `event.scale` / `event.offsetX` 是**自手势起的累计值且单位 vp**，
   *     所以每次 onActionStart 记基准，onActionUpdate 在基准上叠加
   *   · 定位用 `.position()` 手算，不用 `.scale()/.translate()` ——
   *     后者的变换顺序在缩放后会让拖动手感变味（位移被一起放大）
   */
  @Builder
  cropOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor('#000000')

      // ---------- 视口：所见即最终壁纸 ----------
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.cropSrc.pixelMap !== undefined) {
          Image(this.cropSrc.pixelMap)
            .objectFit(ImageFit.Fill)
            .width(this.toVp(this.cropSrc.width * this.cropScale))
            .height(this.toVp(this.cropSrc.height * this.cropScale))
            .position({
              x: this.toVp((this.contentW - this.cropSrc.width * this.cropScale) / 2 + this.cropOffX),
              y: this.toVp((this.contentH - this.cropSrc.height * this.cropScale) / 2 + this.cropOffY)
            })
        }
      }
      .width(this.toVp(this.contentW))
      .height(this.toVp(this.contentH))
      .clip(true)
      .borderWidth(1)
      .borderColor('#33FFFFFF')
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.pinchBase = this.cropScale;
            })
            .onActionUpdate((e: GestureEvent) => {
              const next = CropMath.clampScale(this.pinchBase * e.scale, this.cropMinScale);
              this.cropScale = next;
              this.cropOffX = CropMath.clampOffsetX(
                this.cropOffX, this.cropSrc.width, next, this.contentW);
              this.cropOffY = CropMath.clampOffsetY(
                this.cropOffY, this.cropSrc.height, next, this.contentH);
            }),
          PanGesture({ fingers: 1, distance: 1 })
            .onActionStart(() => {
              this.panBaseX = this.cropOffX;
              this.panBaseY = this.cropOffY;
            })
            .onActionUpdate((e: GestureEvent) => {
              const nx = this.panBaseX + this.toPx(e.offsetX);
              const ny = this.panBaseY + this.toPx(e.offsetY);
              this.cropOffX = CropMath.clampOffsetX(
                nx, this.cropSrc.width, this.cropScale, this.contentW);
              this.cropOffY = CropMath.clampOffsetY(
                ny, this.cropSrc.height, this.cropScale, this.contentH);
            })
        )
      )

      // ---------- 顶部标题 ----------
      Column() {
        Text('裁切壁纸')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width('100%')
        Text('双指缩放、单指拖动。框内所见即最终壁纸，会自动铺满课表区域。')
          .fontSize(13)
          .fontColor('#D9FFFFFF')
          .width('100%')
          .margin({ top: 4 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 14 })
      .linearGradient({
        angle: 180,
        colors: [['#B8000000', 0.0], ['#00000000', 1.0]]
      })
      .position({ x: 0, y: 0 })

      // ---------- 底部按钮 ----------
      Column() {
        Blank()
        Column() {
          Row() {
            Text('取消')
              .fontSize(15)
              .fontColor('#FFFFFF')
              .padding(10)
              .onClick(() => {
                this.cropCancel();
              })
            Text('铺满屏幕')
              .fontSize(15)
              .fontColor('#FFFFFF')
              .padding(10)
              .onClick(() => {
                this.cropFill();
              })
            Text('使用这张')
              .fontSize(15)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
              .backgroundColor(C.primary)
              .borderRadius(20)
              .padding({ left: 20, right: 20, top: 10, bottom: 10 })
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.applyCrop();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text('输出比例 = 课表区域比例，设置后不会二次裁切')
            .fontSize(11)
            .fontColor('#A6FFFFFF')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 24 })
        .linearGradient({
          angle: 0,
          colors: [['#00000000', 0.0], ['#C7000000', 1.0]]
        })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  /** 深浅色变化：重写色表（组件树随后会重建，从而读到新色值） */
  onThemeDarkChanged(): void {
    C.applyDark(this.themeDark);
  }

  /** 切换深浅色并立即生效 */
  private applyThemeMode(mode: number): void {
    let sysDark = false;
    // Context 上没有 config，要转成 UIAbilityContext
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (ctx !== undefined && ctx !== null) {
      sysDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    C.applyDark(C.resolveDark(mode, sysDark));
    AppStorage.setOrCreate('themeDark', C.dark);
  }

  private visibleSlots(): TimeSlot[] {
    return GltuTimeTable.slots.slice(0, this.maxPeriods);
  }

  private rowIndexOf(index: number): number {
    const slots = this.visibleSlots();
    for (let i = 0; i < slots.length; i++) {
      if (slots[i].index === index) {
        return i;
      }
    }
    return -1;
  }

  private coursesOfWeek(): Course[] {
    if (this.showAllWeeks) {
      return this.courses.slice();
    }
    return this.courses.filter((c: Course) => c.occursOnWeek(this.week));
  }

  /**
   * 某天的课块排布（调休感知）。
   *
   * 调休日要**当成被补的那一天**来画：星期与**周次**都跟着源日期走
   * （9/28 在第 4 周、10/7 在第 6 周，补的是第 6 周周二的课）。
   * 所以这里用 `this.courses` 全量课程自己筛，而不是用已按本周筛过的 `coursesOfWeek()`。
   */
  private layoutOfDay(dow: number, date: number): CellLayout[] {
    const out: CellLayout[] = [];
    if (this.holiday.isBlocked(date, this.settings())) {
      return out; // 节假日屏蔽
    }
    const eff = this.effectiveDate(date);
    const effWeek = this.weekOf(eff);
    const effDow = DateUtil.weekday(eff);

    const slots = this.visibleSlots();
    const list = this.courses.filter((c: Course) => c.dayOfWeek === effDow);

    // 起始节次超出显示范围的课直接跳过（不要画到第 0 行）
    const groups = new Map<number, Course[]>();
    for (let i = 0; i < list.length; i++) {
      const c = list[i];
      const row = this.rowIndexOf(c.startIndex);
      if (row < 0) {
        continue;
      }
      const arr = groups.get(row);
      if (arr === undefined) {
        groups.set(row, [c]);
      } else {
        arr.push(c);
      }
    }

    groups.forEach((arr: Course[], rowStart: number) => {
      const current = arr.filter((c: Course) => c.occursOnWeek(effWeek));
      const names: string[] = [];
      for (let i = 0; i < current.length; i++) {
        names.push(current[i].name);
      }
      const others = this.showAllWeeks
        ? arr.filter((c: Course) => !c.occursOnWeek(effWeek) && names.indexOf(c.name) < 0)
        : [];
      const ordered: Course[] = current.concat(others);
      if (ordered.length === 0) {
        return;
      }
      for (let lane = 0; lane < ordered.length; lane++) {
        const c = ordered[lane];
        // 结束节次超出显示范围时画到最后一行，而不是跳回第 0 行
        let endRow = this.rowIndexOf(c.endIndex);
        if (endRow < 0) {
          endRow = slots.length - 1;
        }
        if (endRow < rowStart) {
          endRow = rowStart;
        }
        const item = new CellLayout();
        item.course = c;
        item.lane = lane;
        item.lanes = ordered.length;
        item.rowStart = rowStart;
        item.rowSpan = endRow - rowStart + 1;
        item.dimmed = lane >= current.length;
        item.makeup = this.makeupOf(date) !== undefined;
        out.push(item);
      }
    });
    return out;
  }

  /** 日视图课程（调休感知：调休日显示源日期那天的课，周次也按源日期算） */
  private dayCourses(): Course[] {
    const date = this.dateOfWeekday(this.selectedDay);
    const eff = this.effectiveDate(date);
    const effWeek = this.weekOf(eff);
    const effDow = DateUtil.weekday(eff);
    const raw = this.courses.filter((c: Course) => c.dayOfWeek === effDow);
    return (this.showAllWeeks ? raw : raw.filter((c: Course) => c.occursOnWeek(effWeek)))
      .sort((a: Course, b: Course) => a.startIndex - b.startIndex);
  }

  private selectedDayLabel(): string {
    const d = this.dateOfWeekday(this.selectedDay);
    const y = DateUtil.toYmd(d);
    return `${y.month}月${y.day}日 ${DateUtil.weekdayLabel(this.selectedDay)}`;
  }

  private selectedHolidayName(): string {
    const d = this.dateOfWeekday(this.selectedDay);
    let label = this.holiday.holidayNameOf(d);
    if (label.length === 0 && this.holiday.isBlocked(d, this.settings())
      && HolidayManager.isWeekend(d)) {
      label = '周末';
    }
    return label;
  }

  private selectedBlocked(): boolean {
    return this.holiday.isBlocked(this.dateOfWeekday(this.selectedDay), this.settings());
  }

  /** 选中日是否是调休上班日；不是则返回 undefined */
  private selectedMakeup(): MakeupRule | undefined {
    return this.makeupOf(this.dateOfWeekday(this.selectedDay));
  }

  /** 选中日的调休摘要，如「补 10/8（周三）的课」 */
  private selectedMakeupText(): string {
    const mk = this.selectedMakeup();
    return mk === undefined ? '' : mk.summary();
  }

  private holidaySummary(): string {
    return this.settings().summary();
  }

  /** 侧边栏「调休补课」右侧的值：识别到几天 */
  private makeupSummary(): string {
    if (this.makeupRuleList.length === 0) {
      return '未识别到调休日';
    }
    return `${this.makeupRuleList.length} 天`;
  }

  private themeLabel(): string {
    if (this.themeMode === 1) {
      return '浅色';
    }
    if (this.themeMode === 2) {
      return '深色';
    }
    return '跟随系统';
  }

  // ==================== 交互 ====================

  private async persistPrefs(): Promise<void> {
    const s = StoreHolder.instance;
    await s.putNumber('max_periods', this.maxPeriods);
    await s.putNumber('week_start', this.weekStart);
    await s.putBool('show_all_weeks', this.showAllWeeks);
    await s.putNumber('theme_mode', this.themeMode);
    await s.putBool('block_statutory', this.blockStatutory);
    await s.putBool('block_school', this.blockSchool);
    await s.putBool('block_weekend', this.blockWeekend);
    // 三个屏蔽开关直接影响卡片显示「课程已屏蔽」还是课表
    SyncDownstream.all(this.getUIContext().getHostContext());
  }

  private async saveSemester(name: string): Promise<void> {
    this.semesterName = name.trim();
    await StoreHolder.instance.putString('semester_name', this.semesterName);
  }

  private async saveStartDate(date: number): Promise<void> {
    this.startDateRaw = date;
    this.firstMonday = DateUtil.mondayOf(date);
    this.week = this.currentWeek();
    const s = StoreHolder.instance;
    await s.putNumber('start_date_raw', this.startDateRaw);
    await s.putNumber('first_monday', this.firstMonday);
    // 「第一周周一」变了 → 卡片标题里的「第 N 周」和当天要上的课都要重算
    SyncDownstream.all(this.getUIContext().getHostContext());
  }

  private async deleteCourse(id: number): Promise<void> {
    if (id <= 0) {
      return;
    }
    await StoreHolder.instance.deleteById(id);
    await this.reload();
    this.panel = '';
    promptAction.showToast({ message: '已删除' });
    // 课程已删：卡片上的今日课程要跟着变（Android 侧 ScheduleViewModel.syncDownstream）
    SyncDownstream.all(this.getUIContext().getHostContext());
  }

  private openEdit(id: number): void {
    this.editCourseId = id;
    this.panel = '';
    this.route = 'edit';
  }

  // ==================== 根结构 ====================

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.isSecondary()) {
          this.secondaryTopBar()
        }

        if (this.route === 'schedule') {
          this.schedulePage()
        } else if (this.route === 'settings') {
          SettingsPage({
            onNavigate: (r: string) => {
              if (r === 'edit') {
                this.openEdit(0);
              } else {
                this.route = r;
              }
            },
            onScrollDir: (yOffset: number) => {
              this.onContentScroll(yOffset);
            },
            navClear: this.navClearance()
          })
        } else if (this.route === 'edit') {
          EditCoursePage({
            courseId: this.editCourseId,
            onDone: () => {
              this.route = this.navIndex === 1 ? 'settings' : 'schedule';
              this.loadPrefs();
              this.reload();
              // 课程增删改已落库（EditCoursePage 内部同步刷新过一次，这里兜底重刷）
              SyncDownstream.all(this.getUIContext().getHostContext());
            }
          })
        } else if (this.route === 'share') {
          SharePage({
            onDone: () => {
              this.route = 'settings';
              this.reload();
              SyncDownstream.all(this.getUIContext().getHostContext());
            }
          })
        } else if (this.route === 'import') {
          WebImportPage({
            onDone: () => {
              this.route = 'settings';
              this.loadPrefs();
              this.reload();
              SyncDownstream.all(this.getUIContext().getHostContext());
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.route === 'schedule' ? C.surface : C.pageBg)

      // ---------- 悬浮胶囊底栏（叠在内容之上，不在 Column 里占位）----------
      // 放在这一层：位于页面之上、覆盖层之下。
      // 外层 Column 只用来把胶囊压到底部；HitTestMode.Transparent 让
      // 它上方那片空白不拦截点击，页面照常能滑能点。
      if (!this.isSecondary()) {
        Column() {
          Blank()
          this.bottomNav()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ---------- 覆盖层 ----------
      if (this.panel === 'drawer') {
        this.drawerOverlay()
      }
      if (this.panel === 'weekPicker') {
        this.weekPickerOverlay()
      }
      if (this.panel === 'detail') {
        this.detailOverlay()
      }
      if (this.panel === 'deleteConfirm') {
        this.deleteConfirmOverlay()
      }
      if (this.panel === 'semester') {
        this.semesterOverlay()
      }
      if (this.panel === 'periods') {
        this.choiceOverlay('课表显示节数', [6, 8, 10, 12, 13], this.maxPeriods)
      }
      if (this.panel === 'weekStartDlg') {
        this.choiceOverlay('每周起始日', [1, 7], this.weekStart)
      }
      if (this.panel === 'makeup') {
        this.makeupOverlay()
      }
      if (this.panel === 'crop') {
        this.cropOverlay()
      }
      if (this.panel === 'currentWeek') {
        this.currentWeekOverlay()
      }
      if (this.panel === 'theme') {
        this.themeOverlay()
      }
      if (this.panel === 'widget') {
        this.widgetOverlay()
      }
    }
      .width('100%')
      .height('100%')
      // 全屏铺满：上下都铺进安全区，胶囊位置靠自己算（见 navBottomMargin）
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private isSecondary(): boolean {
    return this.route !== 'schedule' && this.route !== 'settings';
  }

  private secondaryTitle(): string {
    if (this.route === 'edit') {
      return this.editCourseId > 0 ? '编辑课程' : '添加课程';
    }
    if (this.route === 'share') {
      return '课表分享';
    }
    if (this.route === 'import') {
      return '教务系统导入';
    }
    return '';
  }

  @Builder
  secondaryTopBar() {
    Row() {
      Text('←')
        .fontSize(22)
        .fontColor(C.onSurface)
        .width(46)
        .height(52)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.route = this.navIndex === 1 ? 'settings' : 'schedule';
          this.reload();
        })
      Text(this.secondaryTitle())
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(C.onSurface)
    }
    .width('100%')
    .height(52)
    .backgroundColor(C.surface)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 底部导航 —— 悬浮胶囊样式（对齐鸿蒙系统应用，如「联系人」）。
   *
   * 关键点：
   *   · 胶囊**居中且不占满宽度**（宽度由条目决定），四周留白 → 悬浮感
   *   · 白底 + 大圆角（= 高度一半）+ 投影
   *   · 图标在上、文字在下，选中项整组变主题色
   *
   * 它仍是根 Column 的**兄弟节点**而不是叠在页面上 ——
   * 这样会为它预留高度，课表最后一节和设置页底部内容不会被挡住。
   */
  @Builder
  bottomNav() {
    Row() {
      // ⚠️ 这两个条目**不能**抽成带参数的 @Builder：
      // ArkUI 里 @Builder 按值传参时，参数变化不会触发内部 UI 刷新，
      // 会出现「点了课表、页面切了、但高亮还停在设置」这种不同步。
      // 所以这里显式展开，图标 Builder 也无参、直接读 this.navIndex。
      Column() {
        this.navIconSchedule()
        Text('课表')
          .fontSize(11)
          .fontWeight(this.navIndex === 0 ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.navIndex === 0 ? C.primary : C.onSurfaceVariant)
          .margin({ top: 3 })
          .height(this.navCollapsed ? 0 : 15)
          .opacity(this.navCollapsed ? 0 : 1)
          .scale({ x: this.navCollapsed ? 0.6 : 1, y: this.navCollapsed ? 0.6 : 1 })
      }
      .width(this.navCollapsed ? D.navItemWMin : D.navItemW)
      .height(this.navCollapsed ? D.navMinH : D.floatNavH)
      .justifyContent(FlexAlign.Center)
      .clip(true)
      .onClick(() => {
        this.switchTab(0);
      })

      Column() {
        this.navIconSettings()
        Text('设置')
          .fontSize(11)
          .fontWeight(this.navIndex === 1 ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.navIndex === 1 ? C.primary : C.onSurfaceVariant)
          .margin({ top: 3 })
          .height(this.navCollapsed ? 0 : 15)
          .opacity(this.navCollapsed ? 0 : 1)
          .scale({ x: this.navCollapsed ? 0.6 : 1, y: this.navCollapsed ? 0.6 : 1 })
      }
      .width(this.navCollapsed ? D.navItemWMin : D.navItemW)
      .height(this.navCollapsed ? D.navMinH : D.floatNavH)
      .justifyContent(FlexAlign.Center)
      .clip(true)
      .onClick(() => {
        this.switchTab(1);
      })
    }
    .height(this.navCollapsed ? D.navMinH : D.floatNavH)
    .padding({ left: 8, right: 8 })
    .backgroundColor(C.card)
    .borderRadius((this.navCollapsed ? D.navMinH : D.floatNavH) / 2)
    // 用系统预设的「悬浮」投影（ShadowStyle.OUTER_FLOATING_*）——
    // 这正是鸿蒙给联系人底栏这类悬浮元素用的效果，比手写参数更贴。
    // 注意 shadow() 只接受单个 ShadowOptions/ShadowStyle，不能传数组做双层。
    .shadow(ShadowStyle.OUTER_FLOATING_SM)
    // 收起时同时「变矮 + 沉下去」，再叠加小白条避让
    .margin({ bottom: this.navBottomMargin() })
  }

  /** 切页：一次把高亮、路由、收起状态都对齐，避免三处不同步 */
  private switchTab(index: number): void {
    this.navIndex = index;
    this.route = index === 0 ? 'schedule' : 'settings';
    // 切页后回到展开态：否则新页面一开始就是收起的，很奇怪
    this.animateNav(false);
  }

  /**
   * 底部栏图标 —— **手绘**，不用 `sys.symbol.*`。
   *
   * 为什么不用系统符号：`$r('sys.symbol.xxx')` 是**运行时**从系统资源包解析的，
   * SDK 里查不到名字清单（只确认了 7 个，如 `chevron_down`、`ohos_wifi`），
   * 名字写错的话编译照过、真机上图标却是空白。手绘没有这个风险。
   *
   * ⚠️ 这几个 Builder **一律不接「跟状态有关」的参数**（连 bool 也不行）。
   * ArkUI 里 @Builder 按值传参时参数变化不触发内部刷新，
   * 会表现为「点了 tab、页面切了、图标颜色却不变」。颜色直接读 this.navIndex。
   */

  /** 课表图标：日历（外框 + 顶部标题条 + 两行日期格） */
  @Builder
  navIconSchedule() {
    Column() {
      Row()
        .width('100%')
        .height(5)
        .backgroundColor(this.navIndex === 0 ? C.primary : C.onSurfaceVariant)
      Column({ space: 2.5 }) {
        Row({ space: 2.5 }) {
          this.navDotSchedule()
          this.navDotSchedule()
          this.navDotSchedule()
        }
        Row({ space: 2.5 }) {
          this.navDotSchedule()
          this.navDotSchedule()
          this.navDotSchedule()
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
    .width(20)
    .height(20)
    .borderRadius(5)
    .borderWidth(1.8)
    .borderColor(this.navIndex === 0 ? C.primary : C.onSurfaceVariant)
    .clip(true)
  }

  @Builder
  navDotSchedule() {
    Row()
      .width(3.5)
      .height(3.5)
      .backgroundColor(this.navIndex === 0 ? C.primary : C.onSurfaceVariant)
      .borderRadius(1)
  }

  /** 设置图标：三条滑杆（旋钮位置各不相同） */
  @Builder
  navIconSettings() {
    // 行高 5 + 间距 2.5：3*5 + 2*2.5 = 20，正好填满图标高度，不溢出
    Column({ space: 2.5 }) {
      this.navSliderSettings(2)
      this.navSliderSettings(9)
      this.navSliderSettings(5)
    }
    .width(22)
    .height(20)
    .justifyContent(FlexAlign.Center)
  }

  /** knobPos 是常量，跟状态无关，可以安全地按值传 */
  @Builder
  navSliderSettings(knobPos: number) {
    Row() {
      Row()
        .width(knobPos)
        .height(2)
        .backgroundColor(this.navIndex === 1 ? C.primary : C.onSurfaceVariant)
        .borderRadius(1)
      Row()
        .width(5)
        .height(5)
        .backgroundColor(this.navIndex === 1 ? C.primary : C.onSurfaceVariant)
        .borderRadius(2.5)
      Row()
        .layoutWeight(1)
        .height(2)
        .backgroundColor(this.navIndex === 1 ? C.primary : C.onSurfaceVariant)
        .borderRadius(1)
    }
    .width(22)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  importPlaceholder() {
    Column() {
      Text('教务系统导入').fontSize(18).fontWeight(FontWeight.Bold).fontColor(C.onSurface)
      Text('内嵌浏览器登录 + 抓取课表页 HTML 的页面开发中。\n解析器已完成，只差接 ArkWeb 的 Web 组件。')
        .fontSize(13)
        .fontColor(C.onSurfaceVariant)
        .textAlign(TextAlign.Center)
        .margin({ top: 10 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding(24)
  }

  // ==================== 课表页 ====================

  @Builder
  schedulePage() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ① 壁纸铺满内容区（Crop 等价 Android 的 ContentScale.Crop）
      if (this.wallpaper !== undefined) {
        Image(this.wallpaper)
          .objectFit(ImageFit.Cover)
          .width('100%')
          .height('100%')
        // ② 渐变蒙层：顶栏/日期行稍重，保证花哨壁纸上文字依然清晰
        //    （三段 stop 与 Android 逐字一致：0.66 / 0.40 / 0.32）
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            // ArkUI 的 angle 0 度是从下往上，从上到下要写 180
            angle: 180,
            colors: [
              [Col.alpha(C.surface, 0.66), 0.00],
              [Col.alpha(C.surface, 0.40), 0.28],
              [Col.alpha(C.surface, 0.32), 1.00]
            ]
          })
      }

      // ③ 课表本身
      Column() {
        this.scheduleTopBar()
        if (this.viewMode === 0) {
          this.dateRow()
          Divider().strokeWidth(0.5).color(C.outlineVariant)
          this.weekGrid()
        } else {
          Divider().strokeWidth(0.5).color(C.outlineVariant)
          this.dayList()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.wallpaper === undefined ? C.surface : Color.Transparent)
    }
    .width('100%')
    .layoutWeight(1)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      // 记下课表内容区的真实尺寸（px）—— 裁切比例必须用它，不能用整屏：
      // 本 App 有底部导航，壁纸只铺内容区
      const w = Number(newArea.width);
      const h = Number(newArea.height);
      if (!isNaN(w) && !isNaN(h) && w > 0 && h > 0) {
        this.contentW = this.toPx(w);
        this.contentH = this.toPx(h);
      }
    })
  }

  @Builder
  scheduleTopBar() {
    Column() {
      Row() {
        // ☰ 课表设置侧边栏
        Text('☰')
          .fontSize(22)
          .fontColor(C.onSurface)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.panel = 'drawer';
          })
        // 上一周
        Text('‹')
          .fontSize(24)
          .fontColor(C.onSurface)
          .width(28)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            if (this.week > 1) {
              this.week = this.week - 1;
            }
          })
        // 第 N 周 ▾（点击选周次）
        Row() {
          Text(`第 ${this.week} 周`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(C.onSurface)
          Text('▾').fontSize(13).fontColor(C.onSurface).margin({ left: 1 })
        }
        .height(40)
        .padding({ left: 4, right: 4 })
        .onClick(() => {
          this.panel = 'weekPicker';
        })
        // 下一周
        Text('›')
          .fontSize(24)
          .fontColor(C.onSurface)
          .width(28)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            if (this.week < 30) {
              this.week = this.week + 1;
            }
          })

        Blank()

        // 周 / 日 紧凑切换
        Row() {
          this.modeChip('周', 0)
          this.modeChip('日', 1)
        }
        .backgroundColor(C.surfaceVariant)
        .borderRadius(10)
        .padding(2)

        Text('＋')
          .fontSize(23)
          .fontColor(C.onSurface)
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .margin({ left: 6 })
          .onClick(() => {
            this.openEdit(0);
          })
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 2, right: 6 })

      Text(this.semesterName.length > 0 ? this.semesterName : '未设置学期（课表设置里可手动填写）')
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .width('100%')
        .padding({ left: 58, bottom: 4 })
    }
    .width('100%')
    .padding({ top: 4 })
    .backgroundColor(C.surface)
  }

  @Builder
  modeChip(label: string, mode: number) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.viewMode === mode ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.viewMode === mode ? C.onPrimary : C.onSurfaceVariant)
      .backgroundColor(this.viewMode === mode ? C.primary : Color.Transparent)
      .borderRadius(8)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .onClick(() => {
        this.viewMode = mode;
      })
  }

  /** 日期行：左侧月份 + 7 天（今天实心、被屏蔽红底、假期名下标） */
  @Builder
  dateRow() {
    Row() {
      Column() {
        Text(`${DateUtil.toYmd(this.weekDates()[0]).month}`)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
        Text('月')
          .fontSize(11)
          .fontColor(C.onSurface)
      }
      .width(D.timeColW)
      .height(D.dateRowH)
      .justifyContent(FlexAlign.Center)

      ForEach(this.dateCells(), (cell: DateCell) => {
        Column() {
          Text(cell.label)
            .fontSize(11)
            .fontColor(cell.isSelected ? C.primary : C.onSurfaceVariant)
          Row().height(5)
          Text(`${cell.day}`)
            .fontSize(12)
            .fontWeight(cell.isToday ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(cell.blocked ? C.onErrorContainer
              : (cell.isToday ? C.onPrimary : C.onSurface))
            .backgroundColor(cell.blocked ? C.errorContainer
              : (cell.isToday ? C.primary
                : (cell.isMakeup ? Col.alpha(C.makeup, 0.16)
                  : (cell.isSelected ? C.primaryContainer : Color.Transparent))))
            .borderRadius(7)
            .width(D.dateBox)
            .height(D.dateBox)
            .textAlign(TextAlign.Center)
          Row().height(3)
          if (cell.holidayLabel.length > 0) {
            Text(cell.holidayLabel)
              .fontSize(9)
              .lineHeight(12)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontWeight(cell.blocked || cell.isMakeup ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(cell.blocked ? C.error
                : (cell.isMakeup ? C.makeup : C.onSurfaceVariant))
              .padding({ left: 1, right: 1 })
          } else {
            Row().height(12)
          }
        }
        .layoutWeight(1)
        .height(D.dateRowH)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          // 只切换选中日期，不跳日视图
          this.selectedDay = cell.weekdayValue;
        })
      }, (cell: DateCell) => `dt-${cell.date}`)
    }
    .width('100%')
    .backgroundColor(C.surface)
  }

  /** 周视图网格 */
  @Builder
  weekGrid() {
    Scroll() {
      Stack({ alignContent: Alignment.TopStart }) {
        // ① 横向网格线（从节次轴右侧开始，画在每行顶部）
        Row() {
          Row().width(D.timeColW)
          Column() {
            ForEach(this.visibleSlots(), (slot: TimeSlot) => {
              Row().width('100%').height(D.rowH)
                .border({ width: { top: 0.5 }, color: C.outlineVariant })
            }, (slot: TimeSlot) => `gl-${slot.index}`)
          }
          .layoutWeight(1)
        }
        .width('100%')

        // ② 节次轴 + 7 天
        Row() {
          Column() {
            ForEach(this.visibleSlots(), (slot: TimeSlot) => {
              Column() {
                Text(`${slot.index}`)
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(C.onSurface)
                Text(`${slot.startTime}\n${slot.endTime}`)
                  .fontSize(8)
                  .lineHeight(9.5)
                  .textAlign(TextAlign.Center)
                  .fontColor(C.onSurfaceVariant)
              }
              .width(D.timeColW)
              .height(D.rowH)
              .justifyContent(FlexAlign.Center)
            }, (slot: TimeSlot) => `tc-${slot.index}`)
          }
          .width(D.timeColW)
          .border({ width: { right: 0.5 }, color: C.outlineVariant })

          ForEach(this.dayOrder(), (wd: WeekDay) => {
            Stack({ alignContent: Alignment.TopStart }) {
              ForEach(this.layoutOfDay(wd.value, this.dateOfWeekday(wd.value)), (item: CellLayout) => {
                this.courseCell(item)
              }, (item: CellLayout, idx: number) => `cc-${wd.value}-${item.course.id}-${idx}`)
            }
            .layoutWeight(1)
            .height(this.maxPeriods * D.rowH)
          }, (wd: WeekDay) => `col-${wd.value}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      // 尾部留白加在**滚动内容里**（不是容器上）：这样网格能一直铺到屏幕底、
      // 从悬浮胶囊下方穿过，最后一节也能滚到胶囊上方 —— 与设置页表现一致。
      // 高度取 navClearance()，跟着胶囊的收起/展开实时变，滚到底时正好卡住。
      .height(this.maxPeriods * D.rowH + this.navClearance())
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .onDidScroll((xOffset: number, yOffset: number, state: ScrollState) => {
      this.onContentScroll(yOffset);
    })
    // 有壁纸时透明，否则会挡住壁纸
    .backgroundColor(this.wallpaper === undefined ? C.surface : Color.Transparent)
  }

  /**
   * 课程格子：左侧色条 + 浅底 + 细边框。
   * 文字优先级 课程名 > 地点 > 教师；空间不足时只显示课程名。
   */
  @Builder
  courseCell(item: CellLayout) {
    Column() {
      Text(item.course.name)
        .fontSize(this.cellFontSize(item.lanes))
        .lineHeight(this.cellFontSize(item.lanes) * 1.24)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.cellTextColor(item))
        .maxLines(item.rowSpan + 1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (item.rowSpan > 1 && Classroom.shortLabel(item.course.location).length > 0) {
        Text(Classroom.shortLabel(item.course.location))
          .fontSize(this.cellFontSize(item.lanes) - 0.5)
          .lineHeight(this.cellFontSize(item.lanes) * 1.24)
          .fontColor(this.cellTextColor(item))
          .opacity(0.9)
          .maxLines(item.rowSpan + 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      if (item.rowSpan > 2 && item.course.teacher.length > 0) {
        Text(item.course.teacher)
          .fontSize(this.cellFontSize(item.lanes) - 0.5)
          .lineHeight(this.cellFontSize(item.lanes) * 1.24)
          .fontColor(this.cellTextColor(item))
          .opacity(0.9)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Blank()
      // 调休标记：右下角的「调」字（Blank 把内容顶到上方，右下是空的，不会挡住课程名）
      if (item.makeup) {
        Row() {
          Text('调')
            .fontSize(8)
            .lineHeight(9)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Bold)
        }
        .backgroundColor(C.makeup)
        .borderRadius(3)
        .padding({ left: 2, right: 2, top: 0.5, bottom: 0.5 })
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width(`${100 / item.lanes}%`)
    .height(item.rowSpan * D.rowH)
    .padding({ left: 5, right: 2, top: 2, bottom: 2 })
    .border({
      width: { left: 3, top: 0.8, right: 0.8, bottom: 0.8 },
      color: {
        left: Col.alpha(this.cellBase(item), item.dimmed ? 0.55 : 0.9),
        top: Col.alpha(this.cellBase(item), item.dimmed ? 0.28 : 0.42),
        right: Col.alpha(this.cellBase(item), item.dimmed ? 0.28 : 0.42),
        bottom: Col.alpha(this.cellBase(item), item.dimmed ? 0.28 : 0.42)
      }
    })
    .borderRadius(6)
    // 有壁纸时底色更实（0.13 → 0.34），避免被照片干扰；非本周仍用 0.10
    .backgroundColor(Col.alpha(this.cellBase(item),
      item.dimmed ? 0.10 : (this.hasWallpaper ? 0.34 : 0.13)))
    .position({ x: `${item.lane * 100 / item.lanes}%`, y: item.rowStart * D.rowH + 1 })
    .onClick(() => {
      this.detail = item.course;
      this.panel = 'detail';
    })
  }

  private cellBase(item: CellLayout): string {
    return item.dimmed ? C.dimGray : CourseColor.of(item.course.name);
  }

  private cellTextColor(item: CellLayout): string {
    return Col.darken(this.cellBase(item), item.dimmed ? 0.75 : 0.62);
  }

  /** 按列宽定字号（宽 360vp 估算：7 列再分 lanes 份） */
  private cellFontSize(lanes: number): number {
    const w = 360 / 7 / lanes;
    if (w < 30) {
      return 8.5;
    }
    if (w < 42) {
      return 9;
    }
    if (w < 60) {
      return 9.5;
    }
    return 10;
  }

  /** 日视图 */
  @Builder
  dayList() {
    Column() {
      Row() {
        Text(this.selectedDayLabel())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
        // 调休优先展示：说明这天补的是哪天的课
        if (this.selectedMakeup() !== undefined) {
          Text('调')
            .fontSize(10)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Bold)
            .backgroundColor(C.makeup)
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 8 })
          Text(this.selectedMakeupText())
            .fontSize(12)
            .fontColor(C.makeup)
            .margin({ left: 4 })
        } else if (this.selectedHolidayName().length > 0) {
          Text(this.selectedBlocked()
            ? `${this.selectedHolidayName()} · 不排课`
            : this.selectedHolidayName())
            .fontSize(12)
            .fontColor(this.selectedBlocked() ? C.error : C.onSurfaceVariant)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.selectedBlocked()) {
        Column() {
          Text(`今天是${this.selectedHolidayName().length > 0 ? this.selectedHolidayName() : '周末'}，课程已屏蔽 🎉`)
            .fontSize(16)
            .fontColor(C.onSurface)
          Text('可在课表设置里调整节假日屏蔽方式')
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.dayCourses().length === 0) {
        Column() {
          Text('这一天没有课')
            .fontSize(16)
            .fontColor(C.onSurface)
          Text('添加课程')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.openEdit(0);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.dayCourses(), (c: Course) => {
              this.dayCourseRow(c)
            }, (c: Course) => `dr-${c.id}-${c.startIndex}`)
          }
          .width('100%')
          .padding({ left: 8, right: 12, bottom: this.navClearance() })
        }
        .layoutWeight(1)
        // Scroll 内容不满一屏时默认**垂直居中**，必须显式顶对齐；
        // 否则列表被居中、上下各空一大块（侧边栏那个显示 bug 就是它）
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .onDidScroll((xOffset: number, yOffset: number, state: ScrollState) => {
          this.onContentScroll(yOffset);
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  dayCourseRow(c: Course) {
    Row() {
      // 左侧时间轴
      Column() {
        Text(this.startTextOf(c.startIndex))
          .fontSize(11)
          .fontColor(C.onSurfaceVariant)
        Column()
          .width(1)
          .height(30)
          .backgroundColor(c.occursOnWeek(this.week) ? C.outlineVariant : Col.alpha(C.dimGray, 0.5))
        Text(this.endTextOf(c.endIndex))
          .fontSize(11)
          .fontColor(C.onSurfaceVariant)
      }
      .width(54)
      .alignItems(HorizontalAlign.Center)

      // 课程卡片
      Row() {
        Column()
          .width(4)
          .height(96)
          .backgroundColor(Col.alpha(this.rowAccent(c), c.occursOnWeek(this.week) ? 0.9 : 0.5))

        Column() {
          Text(c.name)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.rowAccent(c))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(Classroom.shortLabel(c.location).length > 0
            ? Classroom.shortLabel(c.location) : '地点待定')
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 3 })
          if (c.teacher.length > 0) {
            Text(c.teacher)
              .fontSize(12)
              .fontColor(this.rowAccent(c))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })

        Column() {
          Text(GltuTimeTable.rangeLabel(c.startIndex, c.endIndex))
            .fontSize(12)
            .fontColor(this.rowAccent(c))
          if (!c.occursOnWeek(this.week)) {
            Text('非本周')
              .fontSize(11)
              .fontColor(C.dimGray)
              .margin({ top: 4 })
          }
        }
        .alignItems(HorizontalAlign.End)
        .padding({ right: 10, top: 8, bottom: 8 })
      }
      .layoutWeight(1)
      .backgroundColor(Col.alpha(this.rowAccent(c),
        c.occursOnWeek(this.week) ? (this.hasWallpaper ? 0.34 : 0.13) : 0.10))
      .borderRadius(10)
      .onClick(() => {
        this.detail = c;
        this.panel = 'detail';
      })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  private rowAccent(c: Course): string {
    return c.occursOnWeek(this.week) ? CourseColor.of(c.name) : C.dimGray;
  }

  private startTextOf(index: number): string {
    const s = GltuTimeTable.byIndex(index);
    return s === undefined ? '' : s.startTime;
  }

  private endTextOf(index: number): string {
    const s = GltuTimeTable.byIndex(index);
    return s === undefined ? '' : s.endTime;
  }

  // ==================== 覆盖层：周次选择 ====================

  @Builder
  weekPickerOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = '';
        })

      Column() {
        Text('选择周次')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ bottom: 8 })

        Scroll() {
          Column() {
            ForEach(this.weekChoices(), (w: number) => {
              Row() {
                Text(`第 ${w} 周`)
                  .fontSize(14)
                  .fontWeight(w === this.week ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(w === this.week ? C.primary : C.onSurface)
                  .width(80)
                Text(this.weekRangeText(w))
                  .fontSize(12)
                  .fontColor(C.onSurfaceVariant)
              }
              .width('100%')
              .padding({ top: 12, bottom: 12, left: 4, right: 4 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.week = w;
                this.panel = '';
              })
            }, (w: number) => `wk-${w}`)
          }
          .width('100%')
        }
        .height(320)
        // Scroll 内容不满一屏时默认**垂直居中**，必须显式顶对齐；
        // 否则列表被居中、上下各空一大块（侧边栏那个显示 bug 就是它）
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)

        Row() {
          Blank()
          Button('关闭')
            .fontSize(14)
            .height(40)
            .backgroundColor(Color.Transparent)
            .fontColor(C.primary)
            .onClick(() => {
              this.panel = '';
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 16 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }

  private weekChoices(): number[] {
    const list: number[] = [];
    for (let i = 1; i <= 24; i++) {
      list.push(i);
    }
    return list;
  }

  private weekRangeText(w: number): string {
    const s = this.firstMonday + (w - 1) * 7;
    const e = s + 6;
    const a = DateUtil.toYmd(s);
    const b = DateUtil.toYmd(e);
    return `${a.month}/${a.day} – ${b.month}/${b.day}`;
  }

  // ==================== 覆盖层：课程详情 / 删除确认 ====================

  @Builder
  detailOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = '';
        })

      Column() {
        Text(this.detail.name)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ bottom: 10 })

        this.infoRow('教师', this.detail.teacher.length > 0 ? this.detail.teacher : '—')
        this.infoRow('地点', Classroom.detailLabel(this.detail.location).length > 0
          ? Classroom.detailLabel(this.detail.location) : '—')
        this.infoRow('时间', `${DateUtil.weekdayLabel(this.detail.dayOfWeek)} ` +
          `${GltuTimeTable.rangeLabel(this.detail.startIndex, this.detail.endIndex)} ` +
          `${GltuTimeTable.rangeTime(this.detail.startIndex, this.detail.endIndex)}`)
        this.infoRow('周次', this.detail.displayWeeks())
        if (this.detail.credit >= 0) {
          this.infoRow('学分', `${this.detail.credit}`)
        }

        Row() {
          Text('删除')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = 'deleteConfirm';
            })
          Blank()
          Text('关闭')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = '';
            })
          Text('编辑')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.openEdit(this.detail.id);
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 20, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(`${label}：`)
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
      Text(value)
        .fontSize(12)
        .fontColor(C.onSurface)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  deleteConfirmOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = 'detail';
        })

      Column() {
        Text('删除课程')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
        Text(`确定删除「${this.detail.name}」吗？`)
          .fontSize(14)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
          .margin({ top: 10, bottom: 16 })
        Row() {
          Blank()
          Text('取消')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = 'detail';
            })
          Text('删除')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.deleteCourse(this.detail.id);
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 20, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 覆盖层：课表设置侧边栏（62% 宽，左侧）====================

  @Builder
  drawerOverlay() {
    Row() {
      Column() {
        Column() {
          Row() {
            Text('←')
              .fontSize(20)
              .fontColor(C.onSurface)
              .width(34)
              .height(34)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.panel = '';
              })
            Text('课表设置')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(C.onSurface)
              .margin({ left: 6 })
          }
          .alignItems(VerticalAlign.Center)

          Text(this.semesterName.length > 0 ? this.semesterName : '未设置学期')
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .width('100%')
            .padding({ left: 40, top: 2 })
        }
        .width('100%')
        .padding({ left: 8, right: 12, top: 10, bottom: 6 })

        Divider().strokeWidth(0.5).color(C.outlineVariant)

        Scroll() {
          Column() {
            this.drawerItem('设置开学日期', DateUtil.slash(this.startDateRaw), () => {
              this.pickStartDate();
            })
            this.drawerItem('设置学期',
              this.semesterName.length > 0 ? this.semesterName : '未设置学期', () => {
                this.tmpSemester = this.semesterName;
                this.panel = 'semester';
              })
            // 用户往往不知道"开学日期"，但一定知道"这周是第几周"。
            // ⚠️ 显示的是**今天实际是第几周**（currentWeek()），不是 this.week
            // —— 后者是"正在浏览的那一周"，用户翻周就会变，会误导用户把开学日期锚错。
            this.drawerItem('设置当前周次', `第 ${this.currentWeek()} 周`, () => {
              this.tmpWeekInput = `${this.currentWeek()}`;
              this.panel = 'currentWeek';
            })

            this.sectionHeader('通用设置')

            this.drawerItem('课表显示节数', `前 ${this.maxPeriods} 节`, () => {
              this.panel = 'periods';
            })
            this.drawerItem('每周起始日', this.weekStart === 7 ? '周日' : '周一', () => {
              this.panel = 'weekStartDlg';
            })
            this.switchItem('显示非本周课程', this.showAllWeeks, (v: boolean) => {
              this.showAllWeeks = v;
              this.persistPrefs();
            })
            this.drawerItem('调休补课', this.makeupSummary(), () => {
              this.panel = 'makeup';
            })
            this.drawerItem('个性换肤', this.themeLabel(), () => {
              this.panel = 'theme';
            })
            this.drawerItem('添加桌面小部件', '', () => {
              this.panel = 'widget';
            })
            // 节假日屏蔽已移到「设置」标签页（含假期清单、同步按钮），侧边栏不再重复

            Row().height(24)
          }
          .width('100%')
        }
        .layoutWeight(1)
        // Scroll 内容不满一屏时默认**垂直居中**，必须显式顶对齐；
        // 否则列表被居中、上下各空一大块（侧边栏那个显示 bug 就是它）
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      }
      .width('62%')
      .height('100%')
      .backgroundColor(C.card)

      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = '';
        })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  drawerItem(title: string, value: string, onClick: () => void) {
    Row() {
      Text(title)
        .fontSize(14)
        .fontColor(C.onSurface)
        .layoutWeight(1)
      if (value.length > 0) {
        Text(value)
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 120 })
      }
      Text('›')
        .fontSize(16)
        .fontColor(C.outline)
        .margin({ left: 4 })
    }
    .width('100%')
    .padding({ left: 16, right: 8, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .onClick(onClick)
  }

  @Builder
  sectionHeader(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor(C.onSurfaceVariant)
      .width('100%')
      .padding({ left: 16, top: 14, bottom: 2 })
  }

  @Builder
  switchItem(title: string, checked: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(title)
        .fontSize(14)
        .fontColor(C.onSurface)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(C.primary)
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  /** 设置开学日期：系统日期选择器 */
  private pickStartDate(): void {
    const y = DateUtil.toYmd(this.startDateRaw);
    DatePickerDialog.show({
      start: new Date(2020, 0, 1),
      end: new Date(2035, 11, 31),
      selected: new Date(y.year, y.month - 1, y.day),
      onDateAccept: (value: Date) => {
        const n = DateUtil.fromYmd(value.getFullYear(), value.getMonth() + 1, value.getDate());
        this.saveStartDate(n);
      }
    });
  }

  // ==================== 覆盖层：设置学期 ====================

  @Builder
  semesterOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = 'drawer';
        })

      Column() {
        Text('设置学期')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
        Text('导入课表时会自动识别学期；识别不到就在这里手动填。')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
          .margin({ top: 8 })
        TextInput({ text: this.tmpSemester, placeholder: '如：2026-2027 第1学期' })
          .fontSize(14)
          .height(48)
          .margin({ top: 12 })
          .onChange((v: string) => {
            this.tmpSemester = v;
          })
        Row() {
          Blank()
          Text('取消')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = 'drawer';
            })
          Text('保存')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.saveSemester(this.tmpSemester);
              this.panel = 'drawer';
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 20, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 覆盖层：单选（显示节数 / 每周起始日）====================

  @Builder
  choiceOverlay(title: string, options: number[], selected: number) {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = 'drawer';
        })

      Column() {
        Text(title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ bottom: 8 })

        ForEach(options, (opt: number) => {
          Row() {
            Text(title === '课表显示节数' ? `前 ${opt} 节` : (opt === 7 ? '周日' : '周一'))
              .fontSize(15)
              .fontColor(C.onSurface)
            Blank()
            if (opt === selected) {
              Text('✓').fontSize(16).fontColor(C.primary)
            }
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            if (title === '课表显示节数') {
              this.maxPeriods = opt;
            } else {
              this.weekStart = opt === 7 ? 7 : 1;
            }
            this.persistPrefs();
            this.panel = 'drawer';
          })
        }, (opt: number) => `op-${opt}`)

        Row() {
          Blank()
          Text('取消')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = 'drawer';
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 20, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 覆盖层：节假日屏蔽 ====================

  @Builder
  holidayOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = 'drawer';
        })

      Column() {
        Text('节假日屏蔽')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')

        this.switchRow('屏蔽法定节假日',
          '元旦 / 春节 / 清明节 / 劳动节 / 端午节 / 中秋节 / 国庆节',
          this.tmpStatutory, (v: boolean) => {
            this.tmpStatutory = v;
          })
        this.switchRow('屏蔽学校假期',
          '校运会 / 寒假 / 暑假（来自 GLTU 校历）',
          this.tmpSchool, (v: boolean) => {
            this.tmpSchool = v;
          })
        this.switchRow('屏蔽日常周末',
          '周六、周日',
          this.tmpWeekend, (v: boolean) => {
            this.tmpWeekend = v;
          })

        Text('说明：补班日（调休上班的周末）不受以上开关影响，一律照常上课；三个开关互相独立，可任意组合。')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
          .margin({ top: 4 })

        Row() {
          Blank()
          Text('取消')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = 'drawer';
            })
          Text('保存')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.blockStatutory = this.tmpStatutory;
              this.blockSchool = this.tmpSchool;
              this.blockWeekend = this.tmpWeekend;
              this.persistPrefs();
              this.panel = 'drawer';
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 20, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  switchRow(title: string, subtitle: string, checked: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(C.onSurface)
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor(C.primary)
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  // ==================== 覆盖层：设置当前周次 ====================

  /**
   * 「设置当前周次」。
   * 交互与「教务系统导入」成功后的那次输入保持一致：直接填周数，不弹列表让用户翻。
   */
  @Builder
  currentWeekOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = 'drawer';
        })

      Column() {
        Text('设置当前周次')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
        Text('用来校准「这周是第几周」。填完之后，课表周次和开学日期都会跟着调整。')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
          .margin({ top: 8 })
        TextInput({ text: this.tmpWeekInput, placeholder: '当前第几周' })
          .type(InputType.Number)
          .fontSize(14)
          .height(48)
          .margin({ top: 12 })
          .onChange((v: string) => {
            let digits = v.replace(/[^0-9]/g, '');
            if (digits.length > 2) {
              digits = digits.substring(0, 2);
            }
            this.tmpWeekInput = digits;
          })
        Row() {
          Blank()
          Text('取消')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = 'drawer';
            })
          Text('确定')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              let n = parseInt(this.tmpWeekInput, 10);
              if (isNaN(n)) {
                n = this.week;
              }
              this.setCurrentWeek(n);
              this.panel = 'drawer';
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 覆盖层：调休补课 ====================

  /**
   * 「调休补课」：列出放假期间要补课的调休上班日，让用户自己指定补周几的课。
   *
   * 为什么必须能手动改：放假通知只说「X月X日（星期六）上班」，
   * 不会说补周几 —— 那是学校另行通知的，App 只能按惯例猜。
   */
  @Builder
  makeupOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = 'drawer';
        })

      Column() {
        Text('调休补课')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
        Text('放假的调休上班日要补某一天的课（如「10月11日（周六）补10月8日（周三）的课」）。通知里不写补周几，App 按惯例猜一个；猜得不对，点下面的星期自己选。')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
          .margin({ top: 8 })

        if (this.makeupRuleList.length === 0) {
          Text('当前没有识别到调休日。放假安排公布后会按内置数据自动出现。')
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .width('100%')
            .margin({ top: 12 })
        } else {
          Scroll() {
            Column() {
              ForEach(this.makeupRuleList, (rule: MakeupRule) => {
                this.makeupRuleRow(rule)
              }, (rule: MakeupRule) => `mk-${rule.date}`)
            }
            .width('100%')
          }
          .constraintSize({ maxHeight: '58%' })
          .margin({ top: 8 })
          .align(Alignment.TopStart)
        }

        Row() {
          Blank()
          Text('完成')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = 'drawer';
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }

  /** 一条调休规则：日期 + 自动/手动 + 「补周几」按钮 */
  @Builder
  makeupRuleRow(rule: MakeupRule) {
    Column() {
      Divider().strokeWidth(0.5).color(C.outlineVariant).margin({ top: 10, bottom: 8 })
      Row() {
        Text(`${DateUtil.label(rule.date)}（${DateUtil.weekdayLabel(DateUtil.weekday(rule.date))}）`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(C.onSurface)
          .layoutWeight(1)
        Text(rule.manual ? '手动' : '自动')
          .fontSize(11)
          .fontColor(rule.manual ? C.primary : C.onSurfaceVariant)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(`现在补 ${DateUtil.label(rule.sourceDate)}（${DateUtil.weekdayLabel(rule.sourceWeekday())}）的课`)
        .fontSize(12)
        .fontColor(C.makeup)
        .width('100%')
        .margin({ top: 2 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(WEEKDAYS, (wd: number) => {
          Text(DateUtil.weekdayLabel(wd))
            .fontSize(12)
            .fontColor(rule.sourceWeekday() === wd ? Color.White : C.primary)
            .backgroundColor(rule.sourceWeekday() === wd ? C.primary : C.surfaceVariant)
            .borderRadius(8)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .margin({ right: 4, top: 4 })
            .onClick(() => {
              this.setMakeupOverride(rule.date, wd);
            })
        }, (wd: number) => `wd-${rule.date}-${wd}`)
        if (rule.manual) {
          Text('恢复自动')
            .fontSize(12)
            .fontColor(C.primary)
            .padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .margin({ top: 4 })
            .onClick(() => {
              this.clearMakeupOverride(rule.date);
            })
        }
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ==================== 覆盖层：个性换肤 ====================

  @Builder
  themeOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = 'drawer';
        })

      Column() {
        Text('个性换肤')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')

        Text('主题')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ top: 12 })

        this.themeOption('跟随系统', 0)
        this.themeOption('浅色', 1)
        this.themeOption('深色', 2)

        Text('课表壁纸')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ top: 14 })
        Text(this.hasWallpaper ? '当前：已设置自定义壁纸' : '当前：默认背景')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
          .margin({ top: 4 })
        Row() {
          Text(this.hasWallpaper ? '更换壁纸' : '选择壁纸')
            .fontSize(14)
            .fontColor(C.primary)
            .padding({ left: 0, right: 12, top: 6, bottom: 6 })
            .onClick(() => {
              this.onPickWallpaper();
            })
          if (this.hasWallpaper) {
            Text('移除壁纸')
              .fontSize(14)
              .fontColor(C.error)
              .padding({ left: 0, right: 12, top: 6, bottom: 6 })
              .onClick(() => {
                this.removeWallpaper();
                promptAction.showToast({ message: '已移除壁纸' });
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('选好后进入裁切：双指缩放、拖动，自动铺满课表区域')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
          .margin({ top: 4 })

        Row() {
          Blank()
          Text('完成')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = 'drawer';
            })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 20, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  themeOption(label: string, mode: number) {
    Row() {
      Text(this.themeMode === mode ? '◉' : '○')
        .fontSize(18)
        .fontColor(this.themeMode === mode ? C.primary : C.outline)
      Text(label)
        .fontSize(14)
        .fontColor(C.onSurface)
        .margin({ left: 8 })
      Blank()
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.themeMode = mode;
      this.persistPrefs();
      // 立即生效：换色表 + 写 AppStorage 触发页面重建
      this.applyThemeMode(mode);
    })
  }

  // ==================== 覆盖层：小部件说明 ====================

  @Builder
  widgetOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.panel = 'drawer';
        })

      Column() {
        Text('添加桌面小部件')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
        Text('1. 长按桌面空白处\n' +
          '2. 选择「服务卡片 / 添加工具」\n' +
          '3. 搜索「GLTU 课表」\n' +
          '4. 选规格拖到桌面\n\n' +
          '鸿蒙服务卡片（FormExtensionAbility）开发中；\n' +
          '做好后这里会显示实际入口。')
          .fontSize(12)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ top: 12 })
        Row() {
          Blank()
          Text('知道了')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.panel = 'drawer';
            })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 20, bottom: 20 })
      .backgroundColor(C.card)
      .borderRadius({ topLeft: 24, topRight: 24 })
    }
    .width('100%')
    .height('100%')
  }
}
