/**
 * GltuSchedule · 鸿蒙版 —— 上课提醒排程
 * 对应 Android 版 `notification/ClassReminderScheduler.kt`
 *
 * ## 为什么用 reminderAgentManager 而不是自排闹钟
 * Android 用 `AlarmManager.setExactAndAllowWhileIdle` 自排闹钟；
 * 鸿蒙的等价物是 **`reminderAgentManager`（系统级日历提醒）**：
 * 提醒由系统托管，**App 被杀掉/未启动也会照常弹出**，比自己拉后台任务省电可靠，
 * 也不用申请后台运行权限。
 *
 * ## ⚠️ 条数上限
 * 单个应用可发布的提醒条数有上限（**30 条**），远比 Android 的 30 天窗口小。
 * 所以这里改成**动态窗口**：从今天开始逐天累加，直到再排一天就会超过上限为止
 * （通常能排 2~4 天），并在每次打开 App / 改设置 / 改课程时**重排**。
 *
 * 副作用要说清楚：**连续多天不打开 App，排程窗口用尽后提醒会停**。
 * 打开一次即可续上。后续可加 `WorkSchedulerExtensionAbility` 每日自动续排
 * （见 docs/移植方案.md 的待办）。
 *
 * ## 调休感知
 * 调休上班日上的是「它代替的那一天」的课，所以用 `eff` 的**星期**匹配课程、
 * 用 `eff` 所在的**周次**判断周次（10/11 周六补 10/8 周三 → 上的必须是第 6 周周三的课）。
 * 触发时刻仍用**当天** `date`。
 */
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { Course } from '../model/Course';
import { DateUtil } from '../data/DateUtil';
import { GltuTimeTable, TimeSlot } from '../data/TimeSlot';
import { HolidayManager, BlockSettings } from '../data/Holiday';
import { MakeupRule, MakeupResolver } from '../data/MakeupRule';
import { AppInfo } from '../common/AppInfo';
import { ReminderPreference } from './ReminderPreference';

/** 一条待发布的提醒 */
class Firing {
  /** 触发时刻（毫秒时间戳） */
  at: number = 0;
  /** 上课那天的天数序号 */
  date: number = 0;
  course: Course = new Course();
  /** 上课的节次（拿 startTime） */
  slot: TimeSlot | undefined = undefined;
  minutesBefore: number = 0;
}

export class ClassReminderScheduler {
  /** 单应用提醒条数上限（系统限制） */
  static readonly MAX_REMINDERS: number = 30;
  /** 最多往后看几天（实际会被 MAX_REMINDERS 卡住，这只是硬上限） */
  static readonly MAX_HORIZON_DAYS: number = 30;
  /** 通知渠道/通知 id 基数 */
  private static readonly NOTIFICATION_ID_BASE: number = 10000;

  // ==================== 权限与通知槽位 ====================

  /**
   * 建立通知槽位。
   *
   * ⚠️ **不建槽位的话，代理提醒会落到 `UNKNOWN_TYPE`（LEVEL_MIN）渠道 ——
   * 无横幅、无铃声、不亮屏，等于提醒没用**。
   * 官方渠道支持矩阵里只有 `SERVICE_INFORMATION` / `SOCIAL_COMMUNICATION` 是全支持的。
   *
   * 对应 Android 版的 `ensureChannel()`（那边建的是 IMPORTANCE_HIGH 的 `class_reminder` 渠道）。
   */
  static async ensureSlot(): Promise<void> {
    try {
      await reminderAgentManager.addNotificationSlot({
        notificationType: notificationManager.SlotType.SERVICE_INFORMATION
      });
    } catch (e) {
      // 槽位已存在时会抛，忽略
    }
  }

  /**
   * 确保通知已开启。返回是否可用。
   * 鸿蒙首次需要用户同意通知授权，未开启时提醒不会弹出。
   */
  static async ensureNotificationEnabled(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return true;
      }
      // 弹授权框；用户拒绝时后续调用不会再弹，需要去系统设置里开
      await notificationManager.requestEnableNotification(context);
      // 必须**复检**：requestEnableNotification 在用户拒绝时不抛异常
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      return false;
    }
  }

  /** 通知是否已开启（不弹授权框） */
  static async isNotificationEnabled(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      return false;
    }
  }

  // ==================== 排程 ====================

  /**
   * 重排提醒：先清掉本 App 已发布的全部提醒，再按当前设置重新发布。
   *
   * @param holiday 假期管理器（提供 allHolidays / isBlocked）
   * @param overrides 用户手动指定的调休映射（调休日 → 补周几），
   *                  必须传进来 —— 否则用户改过的「补周几」在提醒侧会被忽略
   * @param courses 全部课程（**不要预筛周次**，周次要按调休后的源日期算）
   * @param firstMonday 第一周周一（天数序号）
   * @param settings 节假日屏蔽三开关
   * @returns 实际发布的提醒条数
   */
  static async reschedule(
    holiday: HolidayManager,
    overrides: Map<number, number>,
    courses: Course[],
    firstMonday: number,
    settings: BlockSettings,
  ): Promise<number> {
    await ClassReminderScheduler.cancelAll();

    if (!ReminderPreference.isEnabled()) {
      return 0;
    }
    const minutes = ReminderPreference.advanceMinutes();
    if (minutes.length === 0) {
      return 0;
    }

    const rules: MakeupRule[] = MakeupResolver.resolve(holiday.allHolidays(), overrides);
    const today = DateUtil.today();
    const nowMs = new Date().getTime();

    // 逐天收集，直到超过条数上限
    const firings: Firing[] = [];
    for (let offset = 0; offset < ClassReminderScheduler.MAX_HORIZON_DAYS; offset++) {
      const date = today + offset;
      // 被屏蔽的日子不排提醒；补班日在 isBlocked 里一律放行
      if (holiday.isBlocked(date, settings)) {
        continue;
      }
      const eff = MakeupResolver.effectiveDate(rules, date);
      const effWeek = DateUtil.weeksBetween(firstMonday, DateUtil.mondayOf(eff)) + 1;
      if (effWeek < 1) {
        continue;
      }
      const effDow = DateUtil.weekday(eff);

      const dayFirings: Firing[] = [];
      for (let i = 0; i < courses.length; i++) {
        const c = courses[i];
        if (c.dayOfWeek !== effDow) {
          continue;
        }
        if (!c.occursOnWeek(effWeek)) {
          continue;
        }
        const slot = GltuTimeTable.byIndex(c.startIndex);
        if (slot === undefined) {
          continue;
        }
        for (let k = 0; k < minutes.length; k++) {
          const at = ClassReminderScheduler.fireTimeMs(date, slot.startTime, minutes[k]);
          if (at <= nowMs + 30000) {
            continue; // 已经过了（或马上就到）就不排
          }
          const f = new Firing();
          f.at = at;
          f.date = date;
          f.course = c;
          f.slot = slot;
          f.minutesBefore = minutes[k];
          dayFirings.push(f);
        }
      }
      if (dayFirings.length === 0) {
        continue;
      }
      // 排不下这一整天就停（保证不半途截断某天）
      if (firings.length + dayFirings.length > ClassReminderScheduler.MAX_REMINDERS) {
        break;
      }
      for (let i = 0; i < dayFirings.length; i++) {
        firings.push(dayFirings[i]);
      }
      if (firings.length >= ClassReminderScheduler.MAX_REMINDERS) {
        break;
      }
    }

    firings.sort((a: Firing, b: Firing) => a.at - b.at);

    let count = 0;
    for (let i = 0; i < firings.length; i++) {
      const ok = await ClassReminderScheduler.publish(firings[i], i);
      if (ok) {
        count++;
      }
    }
    return count;
  }

  /** 发布一条提醒 */
  private static async publish(f: Firing, index: number): Promise<boolean> {
    const slot = f.slot;
    if (slot === undefined) {
      return false;
    }
    const fire = new Date(f.at);
    const loc = f.course.location;
    const req: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: fire.getFullYear(),
        month: fire.getMonth() + 1,
        day: fire.getDate(),
        hour: fire.getHours(),
        minute: fire.getMinutes(),
        second: 0
      },
      // 文案与 Android 版逐字一致
      title: `${f.minutesBefore} 分钟后上课：${f.course.name}`,
      content: loc.length > 0 ? `${slot.startTime} 开始 · ${loc}` : `${slot.startTime} 开始`,
      expiredContent: `${f.course.name} 已经开始`,
      notificationId: ClassReminderScheduler.NOTIFICATION_ID_BASE + index,
      // 不指定 slotType 会落到 UNKNOWN_TYPE(LEVEL_MIN)：无横幅、无铃声、不亮屏
      slotType: notificationManager.SlotType.SERVICE_INFORMATION,
      ringDuration: 5,
      snoozeTimes: 0,
      actionButton: [
        {
          title: '知道了',
          type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE
        }
      ],
      wantAgent: {
        pkgName: AppInfo.BUNDLE_NAME,
        abilityName: 'EntryAbility'
      }
    };
    try {
      await reminderAgentManager.publishReminder(req);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 取消本 App 已发布的全部提醒 */
  static async cancelAll(): Promise<void> {
    try {
      await reminderAgentManager.cancelAllReminders();
    } catch (e) {
      // 没有已发布提醒时会抛，忽略
    }
  }

  /** 当前已发布的提醒条数 */
  static async count(): Promise<number> {
    try {
      const list = await reminderAgentManager.getValidReminders();
      return list === undefined ? 0 : list.length;
    } catch (e) {
      return 0;
    }
  }

  // ==================== 工具 ====================

  /** 某天的 HH:mm 往前推 minutesBefore 分钟的毫秒时间戳 */
  private static fireTimeMs(date: number, startTime: string, minutesBefore: number): number {
    const y = DateUtil.toYmd(date);
    const hh = parseInt(startTime.substring(0, 2), 10);
    const mm = parseInt(startTime.substring(3, 5), 10);
    const d = new Date(y.year, y.month - 1, y.day, isNaN(hh) ? 0 : hh, isNaN(mm) ? 0 : mm, 0, 0);
    return d.getTime() - minutesBefore * 60 * 1000;
  }
}
