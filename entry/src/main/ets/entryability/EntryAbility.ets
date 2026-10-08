/**
 * GltuSchedule · 鸿蒙版 —— 应用入口
 * 对应 Android 版 `GltuScheduleApp` + `MainActivity`
 *
 * 启动时：① 初始化本地存储 ② 重排上课提醒 ③ 加载首页
 *
 * 为什么每次启动都要重排提醒：鸿蒙单应用提醒条数上限是 30 条，
 * 排不下 Android 那样的 30 天窗口，只能动态开窗 + 每次启动续排。
 */
import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { C } from '../common/Palette';
import { StoreHolder } from '../database/CourseStore';
import { DateUtil } from '../data/DateUtil';
import { BlockSettings, HolidayManager } from '../data/Holiday';
import { MakeupResolver } from '../data/MakeupRule';
import { ClassReminderScheduler } from '../notification/ClassReminderScheduler';

const DOMAIN: number = 0x0000;
const TAG: string = 'GltuSchedule';

export default class EntryAbility extends UIAbility {
  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');

    // 初始化本地存储（相当于 Android 版的 Room + SharedPreferences）
    try {
      await StoreHolder.instance.init(this.context);
      hilog.info(DOMAIN, TAG, '%{public}s', 'CourseStore 初始化完成');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'CourseStore 初始化失败: %{public}s', JSON.stringify(e));
      return;
    }

    // 应用主题（深浅色）
    try {
      this.applyTheme();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '应用主题失败: %{public}s', JSON.stringify(e));
    }

    // 重排上课提醒（失败不影响启动）
    try {
      await this.rescheduleReminders();
    } catch (e) {
      hilog.error(DOMAIN, TAG, '重排提醒失败: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 应用深浅色。
   *
   * 「跟随系统」时把 ColorMode 设成 NOT_SET —— 这样系统深浅色变化仍会回调
   * `onConfigurationUpdate`；若显式设成 LIGHT/DARK，按官方说明就**收不到回调**了，
   * 「跟随系统」也就失效了。
   */
  private applyTheme(): void {
    const mode = StoreHolder.instance.getNumber('theme_mode', C.THEME_SYSTEM);
    const systemDark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const dark = C.resolveDark(mode, systemDark);
    C.applyDark(dark);
    // 页面用 @StorageProp('themeDark') 监听它来重建组件树
    AppStorage.setOrCreate('themeDark', dark);

    const appCtx = this.context.getApplicationContext();
    if (mode === C.THEME_LIGHT) {
      appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } else if (mode === C.THEME_DARK) {
      appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } else {
      appCtx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    }
  }

  /** 系统深浅色变化（仅在「跟随系统」时生效） */
  onConfigurationUpdate(newConfig: Configuration): void {
    try {
      const mode = StoreHolder.instance.getNumber('theme_mode', C.THEME_SYSTEM);
      if (mode !== C.THEME_SYSTEM) {
        return;
      }
      const systemDark = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      C.applyDark(systemDark);
      AppStorage.setOrCreate('themeDark', systemDark);
      hilog.info(DOMAIN, TAG, '跟随系统深浅色: %{public}s', systemDark ? '深色' : '浅色');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '处理配置变更失败: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 重排上课提醒。
   * 调休映射必须一起传进去，否则用户改过的「补周几」在提醒侧会被忽略。
   */
  private async rescheduleReminders(): Promise<void> {
    const s = StoreHolder.instance;
    // 先建通知槽位 —— 不建的话提醒落到 LEVEL_MIN 渠道，无横幅无铃声不亮屏
    await ClassReminderScheduler.ensureSlot();
    const enabled = await ClassReminderScheduler.ensureNotificationEnabled(this.context);
    if (!enabled) {
      hilog.warn(DOMAIN, TAG, '%{public}s', '通知未授权，上课提醒不会弹出');
      return;
    }

    const settings = new BlockSettings(
      s.getBool('block_statutory', true),
      s.getBool('block_school', true),
      s.getBool('block_weekend', false),
    );
    const overrides = MakeupResolver.decodeOverrides(s.getString('makeup_overrides', ''));
    const courses = await s.loadAll();
    const firstMonday = s.getNumber('first_monday', DateUtil.mondayOf(DateUtil.today()));

    const n = await ClassReminderScheduler.reschedule(
      new HolidayManager(), overrides, courses, firstMonday, settings);
    hilog.info(DOMAIN, TAG, '已排 %{public}d 条上课提醒', n);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, '加载首页失败: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', '首页加载成功');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
