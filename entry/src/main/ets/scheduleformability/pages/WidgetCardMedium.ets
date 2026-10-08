/**
 * GltuSchedule · 鸿蒙版 —— 今日课程卡片（2*4，≈ Android 250×110dp 标准规格）
 * 对应 Android 的 RemoteViews 布局：widget_schedule_list.xml + widget_course_item.xml
 *
 * ⚠️ 卡片 UI 跑在系统"卡片渲染服务进程"里：
 *    不能读数据库/首选项、不能 import 未标注"支持在 ArkTS 卡片中使用"的模块、
 *    不能用 setTimeout。所有内容都由 EntryFormAbility 通过 formBindingData 推来。
 * ⚠️ 三个卡片文件会被打进同一个卡片包，顶层名字（类型/常量/变量）必须全局唯一，
 *    这也是它们不能共用一个 CardCourseItem 名字的原因。
 */

/** 与 ScheduleCardData.CardCourseItem 字段一一对应（卡片侧不能引那边的文件） */
interface CardItemMedium {
  name: string;
  meta: string;
  teacher: string;
  period: string;
  color: string;
}

/** 这张规格能放几行（真正截断在 ScheduleCardData.rowCap 里做，这里只是自查用） */
const ROW_MAX_MEDIUM: number = 3;

/** 卡片底色 = @drawable/widget_background 的 solid（#E6263040，90% 深蓝灰） */
const CARD_BG_MEDIUM: string = '#E6263040';
const TXT_WHITE_MEDIUM: string = '#FFFFFF';
const TXT_WHITE_80_MEDIUM: string = '#CCFFFFFF';
const TXT_WHITE_60_MEDIUM: string = '#99FFFFFF';

let cardStorageMedium = new LocalStorage();            // 卡片数据容器（每张卡片实例独立）

@Entry(cardStorageMedium)
@Component
struct WidgetCardMedium {
  // key 必须与 createFormBindingData 里的字段名一致；只支持单向接收（@LocalStorageLink 不可用）
  @LocalStorageProp('title') title: string = '今日课程';
  @LocalStorageProp('items') items: CardItemMedium[] = [];

  build() {
    Column() {
      // ===== 标题栏（widget_title_bar + widget_title）=====
      Row() {
        Text(this.title)
          .fontSize(14)                               // 14sp
          .fontWeight(FontWeight.Bold)
          .fontColor(TXT_WHITE_MEDIUM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding(10)                                    // padding="10dp"
      .onClick(() => {
        // = Android 的 setOnClickPendingIntent(title_bar, PendingIntent→MainActivity)
        postCardAction(this, {
          action: 'router',
          bundleName: 'com.ltyksa.gltuschedule',
          moduleName: 'entry',
          abilityName: 'EntryAbility',
          params: { from: 'form' }
        });
      })

      // ===== 课程列表（widget_list）=====
      Column() {
        ForEach(this.items, (item: CardItemMedium) => {
          this.CourseRow(item);
        }, (item: CardItemMedium, index: number) => `${index}-${item.name}-${item.period}`)
      }
      .width('100%')
      .layoutWeight(1)                                // = layout_weight="1"
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CARD_BG_MEDIUM)                   // = @drawable/widget_background 的 solid
    .borderRadius(16)                                 // = corners radius 16dp
    .clip(true)                                       // 让圆角真正裁掉四角
    .alignItems(HorizontalAlign.Start)
  }

  /** 一行课程（widget_course_item.xml） */
  @Builder
  CourseRow(item: CardItemMedium) {
    Row() {
      // 色条：widget_item_bar（4dp 宽、minHeight 42dp、运行时设课色）
      // ⚠️ 这里不能写 height('100%')：Row 是 wrap_content，百分比会被量成 0
      Column()
        .width(4)
        .height(42)
        .backgroundColor(item.color)
        .borderRadius(2)

      // 中间三行（LinearLayout weight=1 + paddingStart 10dp + paddingEnd 6dp）
      Column() {
        Text(item.name)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(item.color)                      // 课程名 = 课色
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })   // singleLine + ellipsize=end
          .width('100%')

        Text(item.meta)
          .fontSize(11)
          .fontColor(TXT_WHITE_80_MEDIUM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (item.teacher.length > 0) {                // = View.GONE / VISIBLE
          Text(item.teacher)
            .fontSize(11)
            .fontColor(TXT_WHITE_60_MEDIUM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)                                // = layout_weight="1"
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 10, right: 6 })

      // 右侧节次（widget_item_period）
      Text(item.period)
        .fontSize(11)
        .fontColor(TXT_WHITE_80_MEDIUM)
        .maxLines(1)
        .padding({ right: 10, top: 2 })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })                   // paddingTop/Bottom 6dp
    .alignItems(VerticalAlign.Top)
  }
}
