/**
 * GltuSchedule · 鸿蒙版 —— 周次解析测试
 * 对应 Android 版 `WebTimetableParserTest` 里周次展开相关的用例
 */
import { describe, it, expect } from '@ohos/hypium';
import { WeekParser, WeekRange } from '../main/ets/importer/WeekParser';

function eq(a: number[], b: number[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

export default function weekParserTest() {
  describe('WeekParser', () => {

    it('教务系统最常见的不规则周次', 0, () => {
      const r = WeekParser.parse('4-5周,8周,11-13周(单),14-16周');
      expect(eq(r, [4, 5, 8, 11, 13, 14, 15, 16])).assertTrue();
    });

    it('连续区间', 0, () => {
      const r = WeekParser.parse('1-16周');
      expect(r.length).assertEqual(16);
      expect(r[0]).assertEqual(1);
      expect(r[15]).assertEqual(16);
    });

    it('带「第」字前缀', 0, () => {
      expect(eq(WeekParser.parse('第1-4周'), [1, 2, 3, 4])).assertTrue();
    });

    it('单周', 0, () => {
      expect(eq(WeekParser.parse('1-16周(单)'), [1, 3, 5, 7, 9, 11, 13, 15])).assertTrue();
    });

    it('双周', 0, () => {
      expect(eq(WeekParser.parse('1-16周(双)'), [2, 4, 6, 8, 10, 12, 14, 16])).assertTrue();
    });

    it('双周另一种写法', 0, () => {
      expect(eq(WeekParser.parse('2-10周(双周)'), [2, 4, 6, 8, 10])).assertTrue();
    });

    it('逗号分隔的离散周', 0, () => {
      expect(eq(WeekParser.parse('第3,5,7周'), [3, 5, 7])).assertTrue();
    });

    it('顿号分隔', 0, () => {
      expect(eq(WeekParser.parse('3、5、7周'), [3, 5, 7])).assertTrue();
    });

    it('空白也当分隔符', 0, () => {
      expect(eq(WeekParser.parse('4-5周 8周'), [4, 5, 8])).assertTrue();
    });

    it('自动去重并升序', 0, () => {
      expect(eq(WeekParser.parse('3,3,1,2'), [1, 2, 3])).assertTrue();
    });

    it('超出 1..30 的被丢弃', 0, () => {
      const r = WeekParser.parse('0,1,30,31,99');
      expect(eq(r, [1, 30])).assertTrue();
    });

    it('解析不出时返回空数组', 0, () => {
      expect(WeekParser.parse('').length).assertEqual(0);
      expect(WeekParser.parse('没有数字').length).assertEqual(0);
    });

    it('inferRange 能还原连续区间', 0, () => {
      const r: WeekRange = WeekParser.inferRange([1, 2, 3, 4, 5]);
      expect(r.startWeek).assertEqual(1);
      expect(r.endWeek).assertEqual(5);
      expect(r.oddEven).assertEqual(0);
    });

    it('inferRange 能识别全单周', 0, () => {
      const r: WeekRange = WeekParser.inferRange([1, 3, 5, 7]);
      expect(r.oddEven).assertEqual(1);
    });

    it('inferRange 能识别全双周', 0, () => {
      const r: WeekRange = WeekParser.inferRange([2, 4, 6, 8]);
      expect(r.oddEven).assertEqual(2);
    });

    it('不规则周次不会被误判成单双周', 0, () => {
      const r: WeekRange = WeekParser.inferRange([4, 5, 8, 11, 13, 14, 15, 16]);
      expect(r.oddEven).assertEqual(0);
      expect(r.startWeek).assertEqual(4);
      expect(r.endWeek).assertEqual(16);
    });
  });
}
