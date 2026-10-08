/**
 * GltuSchedule · 鸿蒙版 —— 课表分享（导出/导入分享码）
 * 对应 Android 版 `com.ltyksa.gltuschedule.ui.share.CourseShareScreen`
 *
 * UI 约定：返回键由外层置顶返回栏提供，本页不再放"返回"按钮；
 * 宿主页面通过构造参数 `onDone` 决定离开本页时做什么（本页自身不需要调用）。
 *
 * 数据读写全部走 `database/CourseStore`（对应 Android 的 ScheduleRepository），
 * 分享码逻辑全部在 `share/CourseShare`（纯逻辑，与 Android 端逐字节互通）。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { Course } from '../model/Course';
import { CourseShare } from '../share/CourseShare';
import { StoreHolder } from '../database/CourseStore';
import { SyncDownstream } from '../common/SyncDownstream';
import { C, D, Col } from '../common/Palette';

/** 页面外边距（Android: padding(16.dp)） */
const PAGE_GAP: number = 14;   // Android: Arrangement.spacedBy(14.dp)
const CARD_GAP: number = 8;    // Android: 卡片内 Arrangement.spacedBy(8.dp)
const FIELD_H: number = 92;    // 分享码文本框高度（Android: minLines = 3, maxLines = 6）
const BTN_H: number = 40;

@Component
export struct SharePage {
  /** 由宿主页面传入；Android 版本页也未使用（返回栏在外层） */
  onDone: () => void = () => {};

  /** 导出的分享码（只读展示） */
  @State shareCode: string = '';
  /** 导出我的课表（N 门课）里的 N */
  @State courseCount: number = 0;
  /** 导入区的可编辑文本 */
  @State importText: string = '';
  /** 结果消息：成功用 primary 色，失败用 error 色（空串 = 不显示） */
  @State message: string = '';
  @State success: boolean = false;
  /** 导入中：避免重复点击 */
  @State busy: boolean = false;

  aboutToAppear(): void {
    this.refreshExport();
  }

  // ==================== 数据 ====================

  /** 重新生成导出分享码（对应 ShareViewModel.refreshExport） */
  private async refreshExport(): Promise<void> {
    let courses: Course[] = [];
    try {
      courses = await StoreHolder.instance.loadAll();
    } catch (e) {
      courses = [];
    }
    if (courses.length === 0) {
      this.shareCode = '';
      this.courseCount = 0;
      this.message = '当前没有课程可导出';
      this.success = false;
      return;
    }
    this.shareCode = CourseShare.export(courses);
    this.courseCount = courses.length;
    this.message = '';
    this.success = false;
  }

  /**
   * 导入分享码（对应 ShareViewModel.importCode）。
   * [replace] = true 覆盖式导入（导入并替换），false 追加导入。
   */
  private async importCode(code: string, replace: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const courses: Course[] | undefined = CourseShare.import(code);
    if (courses === undefined) {
      const reason: string = CourseShare.lastError;
      this.message = reason.length > 0 ? reason : '导入失败';
      this.success = false;
      this.busy = false;
      return;
    }
    try {
      if (replace) {
        await StoreHolder.instance.clearAll();
      }
      for (let i = 0; i < courses.length; i++) {
        await StoreHolder.instance.insert(courses[i]);
      }
      // 课表已变：同步刷新导出区（Android 版同样在收尾时刷新导出码）
      let all: Course[] = [];
      try {
        all = await StoreHolder.instance.loadAll();
      } catch (e) {
        all = [];
      }
      this.shareCode = all.length > 0 ? CourseShare.export(all) : '';
      this.courseCount = all.length;
      this.message = `导入成功：${courses.length} 门课` + (replace ? '（已替换原课表）' : '（已追加）');
      this.success = true;
      // 课表已被替换/追加 → 卡片上的今日课程要重算（Android：CourseShareScreen 导入成功后 refreshAll）
      SyncDownstream.all(this.getUIContext().getHostContext());
    } catch (e) {
      this.message = '导入失败';
      this.success = false;
    }
    this.busy = false;
  }

  // ==================== 剪贴板 ====================

  /** 写入剪贴板（对应 copyToClipboard） */
  private async copyCode(): Promise<void> {
    try {
      const data: pasteboard.PasteData = pasteboard.createPlainTextData(this.shareCode);
      await pasteboard.getSystemPasteboard().setData(data);
    } catch (e) {
      // 与 Android 版一致：写入失败不做额外提示
    }
  }

  /** 读取剪贴板（对应 getFromClipboard，取不到就是空串） */
  private async pasteCode(): Promise<void> {
    let text: string = '';
    try {
      const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
      text = data.getPrimaryText();
    } catch (e) {
      text = '';
    }
    this.importText = (text === undefined || text === null) ? '' : text;
  }

  // ==================== 视图 ====================

  @Builder
  exportCard() {
    Column({ space: CARD_GAP }) {
      Text(`导出我的课表（${this.courseCount} 门课）`)
        .fontSize(16)
        .fontColor(C.onSurface)
        .width('100%')

      Text('分享码')
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .width('100%')

      // 只读文本框：`enableKeyboardOnFocus(false)` 挡掉软键盘，内容由 this.shareCode 决定
      TextArea({ text: this.shareCode })
        .width('100%')
        .height(FIELD_H)
        .fontSize(12)
        .fontColor(C.onSurface)
        .backgroundColor(C.surface)
        .borderWidth(1)
        .borderColor(C.outlineVariant)
        .borderRadius(8)
        .padding(8)
        .enableKeyboardOnFocus(false)
        .onChange((value: string) => {
          // 只读：忽略用户改动
        })

      Row({ space: CARD_GAP }) {
        Button('复制分享码')
          .fontSize(14)
          .height(BTN_H)
          .fontColor(C.onPrimary)
          .backgroundColor(this.shareCode.length > 0 ? C.primary : Col.alpha(C.primary, 0.4))
          .enabled(this.shareCode.length > 0)
          .onClick(() => {
            this.copyCode();
          })
        Button('刷新')
          .fontSize(14)
          .height(BTN_H)
          .fontColor(C.primary)
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor(C.outline)
          .onClick(() => {
            this.refreshExport();
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(D.cardPad)
    .backgroundColor(C.card)
    .borderRadius(D.cardRadius)
  }

  @Builder
  importCard() {
    Column({ space: CARD_GAP }) {
      Text('导入同学的课表')
        .fontSize(16)
        .fontColor(C.onSurface)
        .width('100%')

      Text('粘贴分享码')
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .width('100%')

      TextArea({ text: this.importText })
        .width('100%')
        .height(FIELD_H)
        .fontSize(12)
        .fontColor(C.onSurface)
        .backgroundColor(C.surface)
        .borderWidth(1)
        .borderColor(C.outlineVariant)
        .borderRadius(8)
        .padding(8)
        .onChange((value: string) => {
          this.importText = value;
        })

      Text('提示：导入会替换当前课表；如需保留请先导出备份')
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        Button('导入并替换')
          .fontSize(14)
          .height(BTN_H)
          .fontColor(C.onPrimary)
          .backgroundColor(this.busy ? Col.alpha(C.primary, 0.4) : C.primary)
          .enabled(!this.busy)
          .margin({ right: CARD_GAP, top: 4, bottom: 4 })
          .onClick(() => {
            this.importCode(this.importText, true);
          })
        Button('追加导入')
          .fontSize(14)
          .height(BTN_H)
          .fontColor(C.primary)
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor(C.outline)
          .enabled(!this.busy)
          .margin({ right: CARD_GAP, top: 4, bottom: 4 })
          .onClick(() => {
            this.importCode(this.importText, false);
          })
        Button('从剪贴板粘贴')
          .fontSize(14)
          .height(BTN_H)
          .fontColor(C.primary)
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor(C.outline)
          .margin({ top: 4, bottom: 4 })
          .onClick(() => {
            this.pasteCode();
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(D.cardPad)
    .backgroundColor(C.card)
    .borderRadius(D.cardRadius)
  }

  build() {
    Scroll() {
      Column({ space: PAGE_GAP }) {
        Text('课表分享')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')

        Text('把课表导出成一段分享码发给同学，对方粘贴即可导入。全程本地，不经过任何服务器。')
          .fontSize(14)
          .fontColor(C.onSurfaceVariant)
          .width('100%')

        this.exportCard()

        this.importCard()

        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(14)
            .fontColor(this.success ? C.primary : C.error)
            .width('100%')
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
