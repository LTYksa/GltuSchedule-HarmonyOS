/**
 * GltuSchedule · 鸿蒙版 —— 数据变更后的下游同步
 * 对应 Android 版各处的 `syncDownstream()`：
 *   「课程数据变化后：重排上课提醒 + 刷新桌面小部件」
 *
 * 为什么必须两个都做：
 *   · 只刷卡片不重排提醒 → **删掉的课还会响**（课程名/时间已固化在已发布的提醒里）、
 *     新加的课不会响
 *   · 只重排提醒不刷卡片 → 桌面卡片显示旧课表
 *
 * 所以页面里凡是改了课程或课表设置的地方，统一调这个，别只调其中一个。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FormRefresh } from '../scheduleformability/FormRefresh';
import { ClassReminderScheduler } from '../notification/ClassReminderScheduler';
import { StoreHolder } from '../database/CourseStore';
import { DateUtil } from '../data/DateUtil';
import { BlockSettings, HolidayManager } from '../data/Holiday';
import { MakeupResolver } from '../data/MakeupRule';

const DOMAIN: number = 0x0000;
const TAG: string = 'GltuSchedule';

export class SyncDownstream {

  /**
   * 课程数据或课表设置变更后调用：刷新桌面卡片 + 重排上课提醒。
   * 两个都是「尽力而为」，失败只记日志 —— 不该影响保存课程这类主流程。
   */
  static all(ctx: common.Context | undefined): void {
    if (ctx === undefined) {
      return;
    }
    // ① 桌面卡片
    FormRefresh.all(ctx);
    // ② 上课提醒（异步，不阻塞调用方）
    SyncDownstream.rescheduleReminders();
  }

  /** 从本地存储读全量状态后重排提醒 */
  private static async rescheduleReminders(): Promise<void> {
    try {
      const s = StoreHolder.instance;
      const settings = new BlockSettings(
        s.getBool('block_statutory', true),
        s.getBool('block_school', true),
        s.getBool('block_weekend', false),
      );
      // 调休覆盖必须带上，否则用户改过的「补周几」在提醒侧会被忽略
      const overrides = MakeupResolver.decodeOverrides(s.getString('makeup_overrides', ''));
      const courses = await s.loadAll();
      const firstMonday = s.getNumber('first_monday', DateUtil.mondayOf(DateUtil.today()));
      const n = await ClassReminderScheduler.reschedule(
        new HolidayManager(), overrides, courses, firstMonday, settings);
      hilog.info(DOMAIN, TAG, '数据变更后重排上课提醒：%{public}d 条', n);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '重排上课提醒失败: %{public}s', JSON.stringify(e));
    }
  }
}
