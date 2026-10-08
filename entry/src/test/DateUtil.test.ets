/**
 * GltuSchedule · 鸿蒙版 —— 日期工具测试
 *
 * 重点验证「天数序号」算法没算错：它是整个课表周次换算的地基，
 * 算错会导致周次、调休、提醒全部错位。
 */
import { describe, it, expect } from '@ohos/hypium';
import { DateUtil, Ymd } from '../main/ets/data/DateUtil';

export default function dateUtilTest() {
  describe('DateUtil', () => {

    it('已知日期的天数序号', 0, () => {
      // 1970-01-01 是第 0 天
      expect(DateUtil.fromYmd(1970, 1, 1)).assertEqual(0);
      // 2000-01-01 是第 10957 天
      expect(DateUtil.fromYmd(2000, 1, 1)).assertEqual(10957);
    });

    it('年月日往返一致', 0, () => {
      const n = DateUtil.fromYmd(2026, 10, 29);
      const y: Ymd = DateUtil.toYmd(n);
      expect(y.year).assertEqual(2026);
      expect(y.month).assertEqual(10);
      expect(y.day).assertEqual(29);
    });

    it('闰年 2 月 29 日能正确往返', 0, () => {
      const n = DateUtil.fromYmd(2024, 2, 29);
      const y: Ymd = DateUtil.toYmd(n);
      expect(y.year).assertEqual(2024);
      expect(y.month).assertEqual(2);
      expect(y.day).assertEqual(29);
      // 2024 是闰年（366 天），所以 +366 天才到次年 3 月 1 日；
      // +365 天落在 2025-02-28
      const y365: Ymd = DateUtil.toYmd(n + 365);
      expect(y365.year).assertEqual(2025);
      expect(y365.month).assertEqual(2);
      expect(y365.day).assertEqual(28);
      const y366: Ymd = DateUtil.toYmd(n + 366);
      expect(y366.year).assertEqual(2025);
      expect(y366.month).assertEqual(3);
      expect(y366.day).assertEqual(1);
    });

    it('星期几算对', 0, () => {
      // 2025-10-11 是周六（国庆调休上班日）
      expect(DateUtil.weekday(DateUtil.fromYmd(2025, 10, 11))).assertEqual(6);
      // 2025-09-28 是周日
      expect(DateUtil.weekday(DateUtil.fromYmd(2025, 9, 28))).assertEqual(7);
      // 2025-10-08 是周三
      expect(DateUtil.weekday(DateUtil.fromYmd(2025, 10, 8))).assertEqual(3);
    });

    it('1970-01-01 是周四', 0, () => {
      expect(DateUtil.weekday(0)).assertEqual(4);
    });

    it('mondayOf 取所在周的周一', 0, () => {
      const sat = DateUtil.fromYmd(2025, 10, 11); // 周六
      const mon = DateUtil.mondayOf(sat);
      expect(DateUtil.weekday(mon)).assertEqual(1);
      expect(DateUtil.toYmd(mon).day).assertEqual(6); // 10/6
    });

    it('weeksBetween 按整周算', 0, () => {
      const a = DateUtil.mondayOf(DateUtil.fromYmd(2025, 9, 1));
      const b = DateUtil.mondayOf(DateUtil.fromYmd(2025, 10, 6));
      expect(DateUtil.weeksBetween(a, b)).assertEqual(5);
    });

    it('parse 支持 - 与 / 分隔', 0, () => {
      expect(DateUtil.parse('2026-10-29')).assertEqual(DateUtil.fromYmd(2026, 10, 29));
      expect(DateUtil.parse('2026/10/29')).assertEqual(DateUtil.fromYmd(2026, 10, 29));
    });

    it('parse 失败返回 -1', 0, () => {
      expect(DateUtil.parse('')).assertEqual(-1);
      expect(DateUtil.parse('乱写')).assertEqual(-1);
    });

    it('key 输出 yyyy-MM-dd 且补零', 0, () => {
      expect(DateUtil.key(DateUtil.fromYmd(2026, 1, 5))).assertEqual('2026-01-05');
    });

    it('weekdayLabel 输出中文周几', 0, () => {
      expect(DateUtil.weekdayLabel(1)).assertEqual('周一');
      expect(DateUtil.weekdayLabel(3)).assertEqual('周三');
      expect(DateUtil.weekdayLabel(7)).assertEqual('周日');
    });
  });
}
