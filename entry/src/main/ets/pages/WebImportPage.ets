/**
 * GltuSchedule · 鸿蒙版 —— 教务系统导入页
 *
 * 1:1 复刻 Android 版 `ui/import/WebImportScreen.kt`：
 *   ① 说明页：选入口 →「进入教务系统」
 *   ② 内嵌浏览器，用户自己登录（验证码/加密/统一认证都由网页处理）
 *   ③ 手动进入「个人课表查询」页
 *   ④ 点「确定导入」→ 二次确认 → 抓当前页 HTML（含同源 iframe）→ 解析 → 覆盖式落库
 *   ⑤ 成功后设定「当前第几周」，反推开学日期
 *
 * 返回键由根页面的置顶返回栏提供，本页不放返回按钮。
 */
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { Course } from '../model/Course';
import { DateUtil } from '../data/DateUtil';
import { TimetableParser, ParseResult } from '../importer/TimetableParser';
import { StoreHolder } from '../database/CourseStore';
import { SyncDownstream } from '../common/SyncDownstream';
import { C, D, Col } from '../common/Palette';

/** 教务系统入口 */
class Entry {
  url: string = '';
  note: string = '';
  constructor(url: string, note: string) {
    this.url = url;
    this.note = note;
  }
}

const ENTRY_LIST: Entry[] = [
  new Entry('https://v.gltu.edu.cn', '学校 WebVPN（校外可用，推荐）'),
  new Entry('http://jwcweb1.gltu.cn', '校内直连 · 入口一'),
  new Entry('http://jwcweb2.gltu.cn', '校内直连 · 入口二'),
  new Entry('http://jwcweb3.gltu.cn', '校内直连 · 入口三'),
  new Entry('http://jwcweb4.gltu.cn', '校内直连 · 入口四'),
  new Entry('http://jwcweb5.gltu.cn', '校内直连 · 入口五'),
  new Entry('http://jwcweb6.gltu.cn', '校内直连 · 入口六')
];

/**
 * 抓取当前页面 HTML（含同源 iframe —— 很多教务系统的课表在 iframe 里）。
 * 用 base64 传输，避免 JS 字符串转义问题（中文必须这样处理）。
 */
const GRAB_JS: string = `(function(){
  try{
    var parts=[];
    try{ parts.push(document.documentElement.outerHTML); }catch(e){}
    var fs=document.getElementsByTagName('iframe');
    for(var i=0;i<fs.length;i++){
      try{
        var d=fs[i].contentDocument;
        if(d && d.documentElement){ parts.push(d.documentElement.outerHTML); }
      }catch(e){}
    }
    var h=parts.join('\\n<!--IFRAME-->\\n');
    return btoa(unescape(encodeURIComponent(h)));
  }catch(e){ return ''; }
})()`;

/** runJavaScript 的超时（毫秒）—— 超过就认为读取失败，不再无限等待 */
const GRAB_TIMEOUT_MS: number = 20000;
/** 超时哨兵值，用来区分「超时」和「页面真的是空的」 */
const GRAB_TIMEOUT_MARK: string = '__GRAB_TIMEOUT__';

@Component
export struct WebImportPage {
  onDone: () => void = () => {};

  @State browsing: boolean = false;
  @State selectedEntry: string = ENTRY_LIST[0].url;
  @State customUrl: string = '';
  @State currentUrl: string = '';
  @State showConfirm: boolean = false;
  @State busy: boolean = false;
  @State message: string = '';
  @State success: boolean = false;
  @State progress: number = 0;

  // 导入结果
  @State importedCount: number = 0;
  @State importedStrategy: string = '';
  @State importedSemester: string = '';
  @State weekInput: string = '';
  /** 是否真的从页面识别到了当前周次（false 时必须让用户手填） */
  @State weekDetected: boolean = false;
  /** 网页是否已加载完 —— 没加载完就 runJavaScript 会一直不返回 */
  @State pageReady: boolean = false;
  @State showSuccess: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();

  // ==================== 启动抓取 ====================

  private startImport(): void {
    this.showConfirm = false;
    this.busy = true;
    this.success = false;
    this.message = '正在努力获取课程表…';
    // ⚠️ runJavaScript 有可能**一直不 settle**（页面还没加载完、Web 组件正忙），
    // 那样 busy 永远为 true，按钮就永远卡在「正在导入…」。
    // 用 Promise.race 加超时兜底，保证一定会给用户一个结果。
    const timeout = new Promise<string>((resolve: (v: string) => void) => {
      setTimeout(() => {
        resolve(GRAB_TIMEOUT_MARK);
      }, GRAB_TIMEOUT_MS);
    });
    Promise.race([this.controller.runJavaScript(GRAB_JS), timeout])
      .then((result: string) => {
        if (result === GRAB_TIMEOUT_MARK) {
          this.busy = false;
          this.message = '读取超时。请等页面完全加载（进度条走完）后再点「确定导入」。';
          return;
        }
        this.onGrabbed(result);
      })
      .catch((e: Object) => {
        this.busy = false;
        this.message = '读取页面内容失败，请等页面加载完再试一次。';
      });
  }

  /** 周次输入是否有效（1–30） */
  private weekInputValid(): boolean {
    const n = parseInt(this.weekInput, 10);
    return !isNaN(n) && n >= 1 && n <= 30;
  }

  private onGrabbed(raw: string): void {
    let s = (raw === undefined || raw === null) ? '' : raw.trim();
    // runJavaScript 返回的是 JSON 字符串（带引号）
    if (s.length >= 2 && s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') {
      s = s.substring(1, s.length - 1);
    }
    if (s.length === 0 || s === 'null' || s === '\\"\\"') {
      this.busy = false;
      this.message = '读取页面内容失败，请等页面加载完再试一次。';
      return;
    }

    let html = '';
    try {
      const helper = new util.Base64Helper();
      const bytes = helper.decodeSync(s);
      html = util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (e) {
      html = '';
    }
    if (html.trim().length === 0) {
      this.busy = false;
      this.message = '读取页面内容失败，请等页面加载完再试一次。';
      return;
    }
    this.handleHtml(html);
  }

  private async handleHtml(html: string): Promise<void> {
    const outcome: ParseResult = TimetableParser.parse(html);
    if (outcome.courses.length > 0) {
      // 覆盖式导入（与 Android 一致：会清掉手动添加的课）
      await StoreHolder.instance.replaceAll(outcome.courses);
      this.importedCount = outcome.courses.length;
      this.importedStrategy = outcome.strategy;
      this.importedSemester = TimetableParser.guessSemester(html);
      this.message = `成功导入课程表！共 ${outcome.courses.length} 门课`;
      this.success = true;
      // guessCurrentWeek 识别不出时返回 -1。
      // 原来写 `w > 0 ? w : 1` —— 把「没认出来」伪装成了「识别到第 1 周」，
      // 用户看不出来，直接点完成就把开学日期锚错了。
      const w = TimetableParser.guessCurrentWeek(html);
      this.weekDetected = w > 0;
      this.weekInput = w > 0 ? `${w}` : '';
      this.busy = false;
      this.showSuccess = true;
      // 课表已被覆盖导入 → 立刻让桌面卡片显示新数据
      // （Android：WebImportScreen 导入成功后 refreshAll）
      SyncDownstream.all(this.getUIContext().getHostContext());
    } else {
      this.success = false;
      this.busy = false;
      this.message = outcome.note.length > 0
        ? outcome.note
        : '没有识别到课程，请确认当前停留在课表页面。';
    }
  }

  /** 「完成」：用「当前第几周」反推开学日期并保存 */
  private async finishImport(): Promise<void> {
    if (!this.weekInputValid()) {
      promptAction.showToast({ message: '请先填写当前是第几周（1–30）' });
      return;
    }
    let w = parseInt(this.weekInput, 10);
    w = Math.max(1, Math.min(30, w));
    const thisMonday = DateUtil.mondayOf(DateUtil.today());
    const startDate = thisMonday - (w - 1) * 7;
    const s = StoreHolder.instance;
    await s.putNumber('start_date_raw', startDate);
    await s.putNumber('first_monday', DateUtil.mondayOf(startDate));
    const name = this.importedSemester.length > 0 ? this.importedSemester : '教务系统导入';
    await s.putString('semester_name', name);
    // 第一周周一被反推出来 → 卡片标题里的「第 N 周」和当天要上的课都要重算
    SyncDownstream.all(this.getUIContext().getHostContext());
    this.showSuccess = false;
    promptAction.showToast({ message: `已导入 ${this.importedCount} 门课` });
    this.onDone();
  }

  private enterSystem(): void {
    const u = this.customUrl.trim().length > 0 ? this.customUrl.trim() : this.selectedEntry;
    const full = u.startsWith('http') ? u : `http://${u}`;
    this.browsing = true;
    this.currentUrl = full;
    this.message = '';
    try {
      this.controller.loadUrl(full);
    } catch (e) {
      this.message = '打开网页失败，请检查网络或网址。';
    }
  }

  private openTyped(): void {
    const u = this.currentUrl.startsWith('http') ? this.currentUrl : `http://${this.currentUrl}`;
    try {
      this.controller.loadUrl(u);
    } catch (e) {
      this.message = '打开网页失败，请检查网址。';
    }
  }

  // ==================== UI ====================

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.browsing) {
        this.guidePage()
      } else {
        this.browserPage()
      }

      if (this.showConfirm) {
        this.confirmOverlay()
      }
      if (this.showSuccess) {
        this.successOverlay()
      }
    }
    .width('100%')
    // 根节点必须是 layoutWeight(1)：上面有 52vp 的置顶返回栏（兄弟节点），
    // 用 height('100%') 会让「返回栏 + 页面」超出屏幕，页面底部被切掉
    .layoutWeight(1)
    .backgroundColor(this.browsing ? C.surface : C.pageBg)
  }

  // ---------- 说明页 ----------
  @Builder
  guidePage() {
    Scroll() {
      Column() {
        Text('Hi，欢迎使用课表导入功能 👋')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ top: 12, bottom: 12 })

        Column() {
          Text('这样做为什么最稳')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(C.onSurface)
            .width('100%')
          Text('① App 里打开学校教务系统网页\n' +
            '② 你像平时一样正常登录（验证码、密码加密、统一认证都由网页自己处理）\n' +
            '③ 进入「个人课表查询 / 课表查询」页面\n' +
            '④ 点「确定导入」，App 读取该页面并解析成课表\n\n' +
            '不依赖任何私有接口，学校系统改版也不容易失效。')
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .width('100%')
            .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(D.cardPad)
        .backgroundColor(C.card)
        .borderRadius(D.cardRadius)

        Text('选择教务系统入口')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ top: 18, bottom: 6 })

        Column() {
          ForEach(ENTRY_LIST, (entry: Entry, idx: number) => {
            Column() {
              Row() {
                Text(entry.url === this.selectedEntry ? '◉' : '○')
                  .fontSize(18)
                  .fontColor(entry.url === this.selectedEntry ? C.primary : C.outline)
                  .width(26)
                Column() {
                  Text(this.displayHost(entry.url))
                    .fontSize(14)
                    .fontWeight(entry.url === this.selectedEntry ? FontWeight.Bold : FontWeight.Normal)
                    .fontColor(C.onSurface)
                    .width('100%')
                  Text(entry.note)
                    .fontSize(12)
                    .fontColor(C.onSurfaceVariant)
                    .width('100%')
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 12, bottom: 12 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.selectedEntry = entry.url;
                this.customUrl = '';
              })
              if (idx < ENTRY_LIST.length - 1) {
                Divider().strokeWidth(0.5).color(C.outlineVariant)
              }
            }
            .width('100%')
          }, (entry: Entry) => `en-${entry.url}`)
        }
        .width('100%')
        .backgroundColor(C.card)
        .borderRadius(D.cardRadius)
        .clip(true)

        TextInput({ placeholder: '或手动输入教务系统网址（可留空）' })
          .fontSize(14)
          .height(48)
          .margin({ top: 14 })
          .onChange((v: string) => {
            this.customUrl = v;
          })

        Button('进入教务系统')
          .width('100%')
          .height(46)
          .backgroundColor(C.primary)
          .fontColor(C.onPrimary)
          .margin({ top: 16, bottom: 30 })
          .onClick(() => {
            this.enterSystem();
          })
      }
      .width('100%')
      .padding({ left: D.pagePad, right: D.pagePad })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
  }

  private displayHost(url: string): string {
    return url.replace(/^https?:\/\//, '');
  }

  // ---------- 浏览器页 ----------
  @Builder
  browserPage() {
    Column() {
      // 网址栏
      Row() {
        TextInput({ text: this.currentUrl })
          .fontSize(12)
          .height(40)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.currentUrl = v;
          })
        Button('打开')
          .fontSize(13)
          .height(34)
          .backgroundColor(Color.Transparent)
          .fontColor(C.primary)
          .margin({ left: 6 })
          .onClick(() => {
            this.openTyped();
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      // 进度
      if (this.progress < 1) {
        Progress({ value: this.progress * 100, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(3)
      }

      // 操作提示
      Text('登录后进入「个人课表查询」，把学期选成要导入的学期；页面小可双指缩放。确认后点下方「确定导入」。')
        .fontSize(12)
        .fontColor(C.onSurfaceVariant)
        .width('100%')
        .padding(8)
        .backgroundColor(C.surfaceVariant)

      // 网页
      Web({ src: this.currentUrl, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .mixedMode(MixedMode.All)
        .zoomAccess(true)
        .layoutMode(WebLayoutMode.FIT_CONTENT)
        .onPageBegin(() => {
          this.progress = 0;
          this.pageReady = false;
        })
        .onPageEnd(() => {
          this.progress = 1;
          this.pageReady = true;
        })
        .onProgressChange((event) => {
          this.progress = event.newProgress / 100;
        })
        .onErrorReceive(() => {
          this.progress = 1;
          this.pageReady = true;
        })
        .width('100%')
        .layoutWeight(1)

      // 状态消息
      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(12)
          .fontColor(this.success ? C.primary : C.error)
          .width('100%')
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }

      // 底部工具栏
      Row() {
        Button('后退')
          .fontSize(13)
          .height(38)
          .layoutWeight(1)
          .backgroundColor(Color.Transparent)
          .fontColor(C.primary)
          .borderRadius(8)
          .border({ width: 1, color: C.outline })
          .onClick(() => {
            try {
              if (this.controller.accessBackward()) {
                this.controller.backward();
              }
            } catch (e) {
            }
          })
        Button('刷新')
          .fontSize(13)
          .height(38)
          .layoutWeight(1)
          .margin({ left: 8 })
          .backgroundColor(Color.Transparent)
          .fontColor(C.primary)
          .borderRadius(8)
          .border({ width: 1, color: C.outline })
          .onClick(() => {
            try {
              this.controller.refresh();
            } catch (e) {
            }
          })
        Button(this.busy ? '正在导入…' : '确定导入')
          .fontSize(13)
          .height(38)
          .layoutWeight(2)
          .margin({ left: 8 })
          .backgroundColor(this.busy ? C.outlineVariant : C.primary)
          .fontColor(this.busy ? C.onSurfaceVariant : C.onPrimary)
          .enabled(!this.busy)
          .onClick(() => {
            // 页面没加载完就去 runJavaScript，很容易一直不返回（表现为「长时间不动」）
            if (!this.pageReady) {
              promptAction.showToast({ message: '页面还没加载完，请等进度条走完再试' });
              return;
            }
            this.showConfirm = true;
          })
      }
      .width('100%')
      .padding(8)
      .backgroundColor(C.surface)
      .border({ width: { top: 0.5 }, color: C.outlineVariant })
    }
    .width('100%')
    .height('100%')
  }

  // ---------- 二次确认 ----------
  @Builder
  confirmOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)
        .onClick(() => {
          this.showConfirm = false;
        })

      Column() {
        Text('确认导入课表')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
        Text('请确认是否登录成功，且处于课程表页面。\n' +
          '同时，请检查课程表对应的学期是否一致。\n' +
          '如果已经确认，点击「确定导入」即可导入课表。')
          .fontSize(13)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
          .margin({ top: 10, bottom: 12 })
        Row() {
          Blank()
          Text('取消')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.showConfirm = false;
            })
          Text('确定导入')
            .fontSize(14)
            .fontColor(C.primary)
            .padding(10)
            .onClick(() => {
              this.startImport();
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

  // ---------- 导入成功 ----------
  @Builder
  successOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(C.mask)

      Column() {
        Text('导入成功')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C.onSurface)
          .width('100%')
        Text(`已成功导入 ${this.importedCount} 门课程。`)
          .fontSize(14)
          .fontColor(C.onSurface)
          .width('100%')
          .margin({ top: 10 })
        if (this.importedStrategy.length > 0) {
          Text(`识别方式：${this.importedStrategy}`)
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .width('100%')
            .margin({ top: 4 })
        }
        if (this.importedSemester.length > 0) {
          Text(`识别到学期：${this.importedSemester}`)
            .fontSize(12)
            .fontColor(C.onSurfaceVariant)
            .width('100%')
            .margin({ top: 4 })
        }
        Text('请设置「当前是第几周」，用于正确显示单双周与不规则周次：')
          .fontSize(12)
          .fontColor(C.onSurfaceVariant)
          .width('100%')
          .margin({ top: 10 })
        // 识别不出来时必须**明说**，不能默默填个 1 蒙混过去 ——
        // 用户会以为那是识别结果，直接点完成就把开学日期锚错了。
        if (!this.weekDetected) {
          Text('⚠️ 未能从页面识别出当前周次，请手动填写（可对照教务系统的周次下拉框）')
            .fontSize(12)
            .fontColor(C.error)
            .width('100%')
            .margin({ top: 6 })
        } else {
          Text(`已从页面识别到：第 ${this.weekInput} 周（不对可直接改）`)
            .fontSize(12)
            .fontColor(C.primary)
            .width('100%')
            .margin({ top: 6 })
        }
        TextInput({ text: this.weekInput, placeholder: '当前第几周' })
          .fontSize(14)
          .type(InputType.Number)
          .height(48)
          .margin({ top: 8 })
          .onChange((v: string) => {
            let digits = v.replace(/[^0-9]/g, '');
            if (digits.length > 2) {
              digits = digits.substring(0, 2);
            }
            this.weekInput = digits;
          })
        Row() {
          Blank()
          Text('完成')
            .fontSize(14)
            // 周次没填就不让点，避免把开学日期锚错
            .fontColor(this.weekInputValid() ? C.primary : C.outline)
            .padding(10)
            .onClick(() => {
              if (!this.weekInputValid()) {
                promptAction.showToast({ message: '请先填写当前是第几周' });
                return;
              }
              this.finishImport();
            })
        }
        .width('100%')
        .margin({ top: 10 })
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
