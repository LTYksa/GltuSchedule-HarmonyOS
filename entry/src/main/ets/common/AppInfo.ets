/**
 * GltuSchedule · 鸿蒙版 —— 应用信息
 * 对应 Android 版 `com.ltyksa.gltuschedule.AppInfo`
 */
import { bundleManager } from '@kit.AbilityKit';

export class AppInfo {
  static readonly NAME: string = 'GLTU 课表';
  static readonly BUNDLE_NAME: string = 'com.ltyksa.gltuschedule';
  static readonly AUTHOR: string = '木下葵';
  static readonly TECH: string = '全程本地运行 · 无自建服务器\nArkTS + ArkUI + relationalStore';

  /** 兜底版本号：只有读包信息失败时才用得到 */
  private static readonly FALLBACK_VERSION: string = '0.14.0';

  private static cachedVersion: string = '';

  /**
   * 版本号。
   *
   * ⚠️ 原来是 `static readonly VERSION = '0.10.0'` 这样的硬编码常量 ——
   * 发 0.14.0 的包，设置页还显示 v0.10.0，就是因为改 `app.json5` 时忘了同步这里。
   * 现在改成运行时从包信息里读，和 `AppScope/app.json5` 的 `versionName` 永远一致。
   */
  static version(): string {
    if (AppInfo.cachedVersion.length > 0) {
      return AppInfo.cachedVersion;
    }
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
      );
      AppInfo.cachedVersion = info.versionName;
    } catch (e) {
      AppInfo.cachedVersion = AppInfo.FALLBACK_VERSION;
    }
    return AppInfo.cachedVersion;
  }
}
