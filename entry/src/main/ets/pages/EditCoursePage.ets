/**
 * GltuSchedule · 鸿蒙版 —— 手动添加/编辑课程界面（不依赖教务系统，超级课程表式录入）
 * 对应 Android 版 `com.ltyksa.gltuschedule.ui.edit.EditCourseScreen` + `EditCourseViewModel`
 *
 * UI 约定：返回栏由宿主页面提供，本页只负责表单；保存/删除成功后再回调 `onDone`。
 *
 * ⚠️ 表单里**没有**这些字段：显式周次集合 `weeks`、原始周次文本 `weeksText`、
 * 学分 `credit`、配色分类 `category`（与 Android 版一致）。
 * 编辑保存时必须沿用 `original`，否则"只是改个教室"也会把它们清空：
 *   - `weeks` 丢了 → 不规则周次（如 `4-5周,8周,11-13周(单)`）会退化成连续的 4-16 周，
 *     凭空多出好几周的课。
 *   - `credit` 丢了 → 详情里的学分消失。
 * 但用户若在表单里改过「周次范围 / 单双周」，就以表单为准，丢弃原来的显式周次。
 */
import { Course } from '../model/Course';
import { CourseColor } from '../data/CourseColor';
import { GltuTimeTable, TimeSlot } from '../data/TimeSlot';
import { StoreHolder } from '../database/CourseStore';
import { SyncDownstream } from '../common/SyncDownstream';
import { C, D, Col } from '../common/Palette';

/** 星期胶囊：一~日 */
const WEEK_LABELS: string[] = ['一', '二', '三', '四', '五', '六', '日'];
const WEEK_DAYS: number[] = [1, 2, 3, 4, 5, 6, 7];
/** 单双周胶囊：0=每周 1=单周 2=双周 */
const ODD_EVEN_VALUES: number[] = [0, 1, 2];
const ODD_EVEN_LABELS: string[] = ['每周', '单周', '双周'];

const FIELD_H: number = 44;
const CHIP_H: number = 32;
const PREVIEW_H: number = 52;   // Android: height(52.dp)
const PREVIEW_R: number = 10;   // Android: RoundedCornerShape(10.dp)

/** 夹取到 [lo, hi]（NaN → lo）；对应 Kotlin 的 `coerceIn` */
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

/** Kotlin `String.toIntOrNull()` 的等价物：整串都是（带符号的）十进制数字才算，否则 NaN */
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

@Component
export struct EditCoursePage {
  /** 要编辑的课程 id；<= 0 表示新增 */
  courseId: number = 0;
  /** 由宿主页面传入：保存/删除完成后离开本页 */
  onDone: () => void = () => {};

  /** 表单里的课程 id（课程不存在时归 0，与 Android 版 CourseFormState.id 一致） */
  @State formId: number = 0;
  @State name: string = '';
  @State teacher: string = '';
  @State location: string = '';
  @State dayOfWeek: number = 1;
  @State startIndex: number = 1;
  @State endIndex: number = 1;
  /** 起始周：`startWeekNum` 是最后一次合法输入（对应 Android 表单里的 Int） */
  @State startWeekNum: number = 1;
  @State startWeekText: string = '1';
  /** 结束周：默认 16（与 Android 版一致） */
  @State endWeekNum: number = 16;
  @State endWeekText: string = '16';
  @State oddEven: number = 0;
  @State error: string = '';

  /**
   * 加载进来的原课程（新增 / 课程不存在时为 undefined）。
   * 表单里没有 `weeks` / `weeksText` / `credit` / `category`，保存时要沿用这里的原值。
   */
  private original: Course | undefined = undefined;

  aboutToAppear(): void {
    this.load();
  }

  // ==================== 数据 ====================

  /** 加载要编辑的课程（对应 EditCourseViewModel.load） */
  private async load(): Promise<void> {
    const id: number = this.courseId;
    if (isNaN(id) || id <= 0) {
      this.original = undefined;
      this.formId = 0;
      return;
    }
    let found: Course | undefined = undefined;
    try {
      const all: Course[] = await StoreHolder.instance.loadAll();
      for (let i = 0; i < all.length; i++) {
        if (all[i].id === id) {
          found = all[i];
          break;
        }
      }
    } catch (e) {
      found = undefined;
    }
    if (found === undefined) {
      // Android: CourseFormState(loading = false, error = "课程不存在")，id 归 0
      this.original = undefined;
      this.formId = 0;
      this.error = '课程不存在';
      return;
    }
    this.original = found;
    this.formId = found.id;
    this.name = found.name;
    this.teacher = found.teacher;
    this.location = found.location;
    this.dayOfWeek = found.dayOfWeek;
    this.startIndex = found.startIndex;
    this.endIndex = found.endIndex;
    this.startWeekNum = found.startWeek;
    this.startWeekText = `${found.startWeek}`;
    this.endWeekNum = found.endWeek;
    this.endWeekText = `${found.endWeek}`;
    this.oddEven = found.oddEven;
    this.error = '';
  }

  /**
   * 表单 → Course（纯逻辑，对应 Android 的 `mergeCourseForm`）。
   * 这里就是全部业务逻辑所在，务必与 Android 版逐行等价。
   */
  private buildCourse(name: string): Course {
    const startRaw: number = Math.min(this.startIndex, this.endIndex);
    const start: number = startRaw < 1 ? 1 : startRaw;   // 下限 1
    const end: number = Math.max(this.startIndex, this.endIndex);
    // 周次两端都要夹在 1..30，且保证 start <= end。
    // 只夹 end 不夹 start 的话，输入"起始周 40 / 结束周 35"会得到 35..30，
    // 使 occursOnWeek 恒为 false —— 课程在课表里彻底消失。
    const weekLo: number = Math.min(this.startWeekNum, this.endWeekNum);
    const weekHi: number = Math.max(this.startWeekNum, this.endWeekNum);
    const startWeek: number = clampInt(weekLo, 1, 30);
    const endWeek: number = clampInt(weekHi, startWeek, 30);   // 下界是刚算出的 startWeek，不是 1

    const orig: Course | undefined = this.original;
    const weeksTouched: boolean = orig === undefined ||
      orig.startWeek !== startWeek ||
      orig.endWeek !== endWeek ||
      orig.oddEven !== this.oddEven;

    const c: Course = new Course();
    c.id = this.formId > 0 ? this.formId : 0;
    c.name = name;
    c.teacher = this.teacher.trim();
    c.location = this.location.trim();
    c.dayOfWeek = this.dayOfWeek;
    c.startIndex = start;
    c.endIndex = end;
    c.startWeek = startWeek;
    c.endWeek = endWeek;
    c.oddEven = this.oddEven;
    c.category = orig !== undefined ? orig.category : CourseColor.inferCategory(this.name, this.location);
    c.credit = orig !== undefined ? orig.credit : -1;   // -1 = 无学分
    c.weeksText = weeksTouched ? '' : (orig !== undefined ? orig.weeksText : '');
    c.weeks = weeksTouched ? [] : (orig !== undefined ? orig.weeks.slice() : []);
    return c;
  }

  /** 保存（新增或更新，对应 EditCourseViewModel.save） */
  private async save(): Promise<void> {
    const name: string = this.name.trim();
    if (name.length === 0) {
      this.error = '请填写课程名称';
      return;
    }
    const course: Course = this.buildCourse(name);
    try {
      if (this.formId > 0) {
        // 鸿蒙版 CourseStore 没有 upsert/update：先删再插，
        // 等价于 Android 的 `upsertCourse`（同 id 覆盖）
        await StoreHolder.instance.deleteById(this.formId);
      }
      await StoreHolder.instance.insert(course);
      this.error = '';
      // 课程已落库 → 刷新桌面卡片今日课程（Android：EditCourseViewModel.syncDownstream → refreshAll）
      SyncDownstream.all(this.getUIContext().getHostContext());
      this.onDone();
    } catch (e) {
      this.error = '保存失败';
    }
  }

  /** 删除这门课（对应 EditCourseViewModel.delete） */
  private async remove(): Promise<void> {
    const id: number = this.formId;
    if (id <= 0) {
      return;
    }
    try {
      await StoreHolder.instance.deleteById(id);
      this.error = '';
      SyncDownstream.all(this.getUIContext().getHostContext());
      this.onDone();
    } catch (e) {
      this.error = '删除失败';
    }
  }

  // ==================== 颜色预览 ====================

  /** 预览用的取色关键字：课程名空 → Android 的 `ifBlank { "课程" }` */
  private previewKey(): string {
    return this.name.trim().length > 0 ? this.name : '课程';
  }

  private previewColor(): string {
    return CourseColor.of(this.previewKey());
  }

  private previewText(): string {
    return this.name.trim().length > 0 ? this.name : '课程预览（颜色随课程名自动分配）';
  }

  // ==================== 视图 ====================

  @Builder
  sectionLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor(C.onSurfaceVariant)
      .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: D.cardGap }) {
        // ① 标题
        Text(this.formId > 0 ? '编辑课程' : '添加课程')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')

        // ② 颜色预览条：底色 = 课程色 alpha 0.28，文字 = 课程色不透明加粗居中
        Column() {
          Text(this.previewText())
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.previewColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height(PREVIEW_H)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Col.alpha(this.previewColor(), 0.28))
        .borderRadius(PREVIEW_R)

        // ③ 课程名称 *
        Text('课程名称 *')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
        TextInput({ text: this.name })
          .width('100%')
          .height(FIELD_H)
          .fontSize(14)
          .fontColor(C.onSurface)
          .backgroundColor(C.surface)
          .borderWidth(1)
          .borderColor(C.outlineVariant)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onChange((value: string) => {
            this.name = value;
            // Android: copy(name = v, error = null)
            if (this.error.length > 0) {
              this.error = '';
            }
          })

        // ④ 授课教师
        Text('授课教师')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
        TextInput({ text: this.teacher })
          .width('100%')
          .height(FIELD_H)
          .fontSize(14)
          .fontColor(C.onSurface)
          .backgroundColor(C.surface)
          .borderWidth(1)
          .borderColor(C.outlineVariant)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onChange((value: string) => {
            this.teacher = value;
          })

        // ⑤ 上课地点
        Text('上课地点')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
        TextInput({ text: this.location })
          .width('100%')
          .height(FIELD_H)
          .fontSize(14)
          .fontColor(C.onSurface)
          .backgroundColor(C.surface)
          .borderWidth(1)
          .borderColor(C.outlineVariant)
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onChange((value: string) => {
            this.location = value;
          })

        // ⑥⑦ 星期 + 7 个胶囊（一~日）
        this.sectionLabel('星期')
        Scroll() {
          Row({ space: 6 }) {
            ForEach(WEEK_DAYS, (day: number) => {
              Text(WEEK_LABELS[day - 1])
                .fontSize(13)
                .fontColor(this.dayOfWeek === day ? C.onPrimaryContainer : C.onSurfaceVariant)
                .backgroundColor(this.dayOfWeek === day ? C.primaryContainer : C.surfaceVariant)
                .borderRadius(CHIP_H / 2)
                .height(CHIP_H)
                .padding({ left: 14, right: 14 })
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.dayOfWeek = day;
                })
            }, (day: number) => `day-${day}`)
          }
          .padding({ top: 2, bottom: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Start)

        // ⑧⑨ 开始节次 + 13 个胶囊（点击时若 endIndex < index 则同时改 endIndex）
        this.sectionLabel('开始节次')
        Scroll() {
          Row({ space: 6 }) {
            ForEach(GltuTimeTable.slots, (slot: TimeSlot) => {
              Text(slot.name)
                .fontSize(13)
                .fontColor(this.startIndex === slot.index ? C.onPrimaryContainer : C.onSurfaceVariant)
                .backgroundColor(this.startIndex === slot.index ? C.primaryContainer : C.surfaceVariant)
                .borderRadius(CHIP_H / 2)
                .height(CHIP_H)
                .padding({ left: 12, right: 12 })
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.startIndex = slot.index;
                  if (this.endIndex < slot.index) {
                    this.endIndex = slot.index;
                  }
                })
            }, (slot: TimeSlot) => `start-${slot.index}`)
          }
          .padding({ top: 2, bottom: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Start)

        // ⑩⑪ 结束节次 + 13 个胶囊（点击时若 startIndex > index 则同时改 startIndex）
        this.sectionLabel('结束节次')
        Scroll() {
          Row({ space: 6 }) {
            ForEach(GltuTimeTable.slots, (slot: TimeSlot) => {
              Text(slot.name)
                .fontSize(13)
                .fontColor(this.endIndex === slot.index ? C.onPrimaryContainer : C.onSurfaceVariant)
                .backgroundColor(this.endIndex === slot.index ? C.primaryContainer : C.surfaceVariant)
                .borderRadius(CHIP_H / 2)
                .height(CHIP_H)
                .padding({ left: 12, right: 12 })
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.endIndex = slot.index;
                  if (this.startIndex > slot.index) {
                    this.startIndex = slot.index;
                  }
                })
            }, (slot: TimeSlot) => `end-${slot.index}`)
          }
          .padding({ top: 2, bottom: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.Start)

        // ⑫⑬⑭ 周次范围 + 两个数字输入框
        this.sectionLabel('周次范围')
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('起始周')
              .fontSize(12)
              .fontColor(C.onSurfaceVariant)
              .width('100%')
            TextInput({ text: this.startWeekText })
              .type(InputType.Number)
              .width('100%')
              .height(FIELD_H)
              .fontSize(14)
              .fontColor(C.onSurface)
              .backgroundColor(C.surface)
              .borderWidth(1)
              .borderColor(C.outlineVariant)
              .borderRadius(8)
              .padding({ left: 10, right: 10 })
              .onChange((value: string) => {
                this.startWeekText = value;
                const n: number = strictInt(value);
                if (!isNaN(n)) {
                  this.startWeekNum = n;   // 非法/空输入不改动（对应 toIntOrNull 的忽略行为）
                }
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 4 }) {
            Text('结束周')
              .fontSize(12)
              .fontColor(C.onSurfaceVariant)
              .width('100%')
            TextInput({ text: this.endWeekText })
              .type(InputType.Number)
              .width('100%')
              .height(FIELD_H)
              .fontSize(14)
              .fontColor(C.onSurface)
              .backgroundColor(C.surface)
              .borderWidth(1)
              .borderColor(C.outlineVariant)
              .borderRadius(8)
              .padding({ left: 10, right: 10 })
              .onChange((value: string) => {
                this.endWeekText = value;
                const n: number = strictInt(value);
                if (!isNaN(n)) {
                  this.endWeekNum = n;
                }
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')

        // ⑮⑯ 单双周 + 3 个胶囊（每周 / 单周 / 双周）
        this.sectionLabel('单双周')
        Row({ space: 6 }) {
          ForEach(ODD_EVEN_VALUES, (value: number) => {
            Text(ODD_EVEN_LABELS[value])
              .fontSize(13)
              .fontColor(this.oddEven === value ? C.onPrimaryContainer : C.onSurfaceVariant)
              .backgroundColor(this.oddEven === value ? C.primaryContainer : C.surfaceVariant)
              .borderRadius(CHIP_H / 2)
              .height(CHIP_H)
              .padding({ left: 14, right: 14 })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.oddEven = value;
              })
          }, (value: number) => `oe-${value}`)
        }
        .width('100%')

        // ⑰ 错误文字（error 色）
        if (this.error.length > 0) {
          Text(this.error)
            .fontSize(12)
            .fontColor(C.error)
            .width('100%')
        }

        // ⑱ 主按钮 + （编辑时）删除按钮
        Button(this.formId > 0 ? '保存修改' : '添加课程')
          .width('100%')
          .height(FIELD_H)
          .fontSize(15)
          .fontColor(C.onPrimary)
          .backgroundColor(C.primary)
          .onClick(() => {
            this.save();
          })

        if (this.formId > 0) {
          Button('删除这门课')
            .width('100%')
            .height(FIELD_H)
            .fontSize(15)
            .fontColor(C.error)
            .backgroundColor(Color.Transparent)
            .borderWidth(1)
            .borderColor(C.error)
            .onClick(() => {
              this.remove();
            })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(D.pagePad)
    }
    // 内容不满一屏时 Scroll 默认**垂直居中**，必须显式顶对齐，
    // 否则列表会被居中、上下各空一大块（侧边栏那个显示 bug 就是它）
    .align(Alignment.TopStart)
    .width('100%')
    // 根节点必须是 layoutWeight(1)：上面有 52vp 的置顶返回栏（兄弟节点），
    // 用 height('100%') 会让「返回栏 + 页面」超出屏幕，页面底部被切掉
    .layoutWeight(1)
    .align(Alignment.Top)
    .backgroundColor(C.surface)
    .scrollBar(BarState.Off)
  }
}
