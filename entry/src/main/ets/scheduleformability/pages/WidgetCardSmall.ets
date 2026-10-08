/**
 * GltuSchedule · 鸿蒙版 —— 今日课程卡片（2*2，≈ Android 110×110dp 小规格）
 * 对应 Android 的 RemoteViews 布局：widget_schedule_list.xml + widget_course_item.xml
 *
 * ⚠️ 卡片 UI 跑在系统"卡片渲染服务进程"里：
 *    不能读数据库/首选项、不能 import 未标注"支持在 ArkTS 卡片中使用"的模块、
 *    不能用 setTimeout。所有内容都由 EntryFormAbility 通过 formBindingData 推来。
 * ⚠️ 三个卡片文件会被打进同一个卡片包，顶层名字（类型/常量/变量）必须全局唯一，
 *    这也是它们不能共用一个 CardCourseItem 名字的原因。
 */

/** 与 ScheduleCardData.CardCourseItem 字段一一对应（卡片侧不能引那边的文件） */
interface CardItemSmall {
  name: string;
  meta: string;
  teacher: string;
  period: string;
  color: string;
}

/** 这张规格能放几行（真正截断在 ScheduleCardData.rowCap 里做，这里只是自查用） */
const ROW_MAX_SMALL: number = 1;

/** 卡片底色 = @drawable/widget_background 的 solid（#E6263040，90% 深蓝灰） */
const CARD_BG_SMALL: string = '#E6263040';
const TXT_WHITE_SMALL: string = '#FFFFFF';
const TXT_WHITE_80_SMALL: string = '#CCFFFFFF';
const TXT_WHITE_60_SMALL: string = '#99FFFFFF';

let cardStorageSmall = new LocalStorage();            // 卡片数据容器（每张卡片实例独立）

@Entry(cardStorageSmall)
@Component
struct WidgetCardSmall {
  // key 必须与 createFormBindingData 里的字段名一致；只支持单向接收（@LocalStorageLink 不可用）
  @LocalStorageProp('title') title: string = '今日课程';
  @LocalStorageProp('items') items: CardItemSmall[] = [];

  build() {
    Column() {
      // ===== 标题栏（widget_title_bar + widget_title）=====
      Row() {
        Text(this.title)
          .fontSize(14)                               // 14sp
          .fontWeight(FontWeight.Bold)
          .fontColor(TXT_WHITE_SMALL)
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
        ForEach(this.items, (item: CardItemSmall) => {
          this.CourseRow(item);
        }, (item: CardItemSmall, index: number) => `${index}-${item.name}-${item.period}`)
      }
      .width('100%')
      .layoutWeight(1)                                // = layout_weight="1"
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CARD_BG_SMALL)                   // = @drawable/widget_background 的 solid
    .borderRadius(16)                                 // = corners radius 16dp
    .clip(true)                                       // 让圆角真正裁掉四角
    .alignItems(HorizontalAlign.Start)
  }

  /** 一行课程（widget_course_item.xml） */
  @Builder
  CourseRow(item: CardItemSmall) {
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
          .fontColor(TXT_WHITE_80_SMALL)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (item.teacher.length > 0) {                // = View.GONE / VISIBLE
          Text(item.teacher)
            .fontSize(11)
            .fontColor(TXT_WHITE_60_SMALL)
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
        .fontColor(TXT_WHITE_80_SMALL)
        .maxLines(1)
        .padding({ right: 10, top: 2 })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })                   // paddingTop/Bottom 6dp
    .alignItems(VerticalAlign.Top)
  }
}
