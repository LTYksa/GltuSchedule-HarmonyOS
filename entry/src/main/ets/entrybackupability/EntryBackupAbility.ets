/**
 * GltuSchedule · 鸿蒙版 —— 备份扩展（系统「手机克隆」用）
 * 对应 Android 版 `allowBackup` 声明。
 */
import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;

export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup(): Promise<void> {
    hilog.info(DOMAIN, 'GltuSchedule', '%{public}s', 'onBackup ok');
  }

  async onRestore(bundleVersion: BundleVersion): Promise<void> {
    hilog.info(DOMAIN, 'GltuSchedule', 'onRestore ok %{public}s', JSON.stringify(bundleVersion));
  }
}
