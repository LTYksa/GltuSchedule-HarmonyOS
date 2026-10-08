/**
 * GltuSchedule · 鸿蒙版 —— 调休推导测试
 * 对应 Android 版 `app/src/test/java/com/ltyksa/gltuschedule/MakeupResolverTest.kt`
 *
 * 断言全部基于**国务院办公厅实际发布的通知**，不是凭空构造的日期：
 *   2025 春节  ：1月28日至2月4日放假调休；1月26日（周日）、2月8日（周六）上班
 *   2025 劳动节：5月1日至5日放假调休；4月27日（周日）上班
 *   2025 国庆  ：10月1日至8日放假调休；9月28日（周日）、10月11日（周六）上班
 */
import { describe, it, expect } from '@ohos/hypium';
import { Holiday, HolidayEntry, HolidayType } from '../main/ets/data/Holiday';
import { MakeupRule, MakeupResolver } from '../main/ets/data/MakeupRule';
import { DateUtil } from '../main/ets/data/DateUtil';

/** 造一条假期 */
function h(name: string, startY: number, startM: number, startD: number,
           endY: number, endM: number, endD: number, type: HolidayType): HolidayEntry {
  return new HolidayEntry(
    new Holiday(name, DateUtil.fromYmd(startY, startM, startD), DateUtil.fromYmd(endY, endM, endD)),
    type);
}

function d(y: number, m: number, day: number): number {
  return DateUtil.fromYmd(y, m, day);
}

/** 春节：1/28–2/4 放假，1/26 与 2/8 上班 */
function springFestival2025(): HolidayEntry[] {
  return [
    h('春节', 2025, 1, 28, 2025, 2, 4, HolidayType.STATUTORY),
    h('春节', 2025, 1, 26, 2025, 1, 26, HolidayType.MAKEUP),
    h('春节', 2025, 2, 8, 2025, 2, 8, HolidayType.MAKEUP)
  ];
}

/** 劳动节：5/1–5/5 放假，4/27 上班 */
function labourDay2025(): HolidayEntry[] {
  return [
    h('劳动节', 2025, 5, 1, 2025, 5, 5, HolidayType.STATUTORY),
    h('劳动节', 2025, 4, 27, 2025, 4, 27, HolidayType.MAKEUP)
  ];
}

/** 国庆中秋：10/1–10/8 放假，9/28 与 10/11 上班 */
function nationalDay2025(): HolidayEntry[] {
  return [
    h('国庆节', 2025, 10, 1, 2025, 10, 8, HolidayType.STATUTORY),
    h('国庆节', 2025, 9, 28, 2025, 9, 28, HolidayType.MAKEUP),
    h('国庆节', 2025, 10, 11, 2025, 10, 11, HolidayType.MAKEUP)
  ];
}

/** 从结果里按日期取一条 */
function find(rules: MakeupRule[], date: number): MakeupRule | undefined {
  for (let i = 0; i < rules.length; i++) {
    if (rules[i].date === date) {
      return rules[i];
    }
  }
  return undefined;
}

export default function makeupResolverTest() {
  describe('MakeupResolver', () => {

    it('春节_1月26日补2月3日周一', 0, () => {
      const r = find(MakeupResolver.resolve(springFestival2025(), new Map<number, number>()), d(2025, 1, 26));
      expect(r !== undefined).assertTrue();
      expect(r!.sourceDate).assertEqual(d(2025, 2, 3));
      expect(r!.sourceWeekday()).assertEqual(1);
      expect(r!.manual).assertFalse();
    });

    it('春节_2月8日补2月4日周二', 0, () => {
      const r = find(MakeupResolver.resolve(springFestival2025(), new Map<number, number>()), d(2025, 2, 8));
      expect(r !== undefined).assertTrue();
      expect(r!.sourceDate).assertEqual(d(2025, 2, 4));
      expect(r!.sourceWeekday()).assertEqual(2);
    });

    it('劳动节_4月27日补5月5日周一', 0, () => {
      const r = find(MakeupResolver.resolve(labourDay2025(), new Map<number, number>()), d(2025, 4, 27));
      expect(r !== undefined).assertTrue();
      expect(r!.sourceDate).assertEqual(d(2025, 5, 5));
      expect(r!.sourceWeekday()).assertEqual(1);
    });

    it('国庆_9月28日补10月7日周二', 0, () => {
      const r = find(MakeupResolver.resolve(nationalDay2025(), new Map<number, number>()), d(2025, 9, 28));
      expect(r !== undefined).assertTrue();
      expect(r!.sourceDate).assertEqual(d(2025, 10, 7));
      expect(r!.sourceWeekday()).assertEqual(2);
    });

    it('国庆_10月11日补10月8日周三', 0, () => {
      const r = find(MakeupResolver.resolve(nationalDay2025(), new Map<number, number>()), d(2025, 10, 11));
      expect(r !== undefined).assertTrue();
      expect(r!.sourceDate).assertEqual(d(2025, 10, 8));
      expect(r!.sourceWeekday()).assertEqual(3);
      expect(r!.summary().indexOf('周三') >= 0).assertTrue();
    });

    it('国庆_9月28日与其源日期不在同一周', 0, () => {
      const r = find(MakeupResolver.resolve(nationalDay2025(), new Map<number, number>()), d(2025, 9, 28))!;
      const makeupMonday = DateUtil.mondayOf(r.date);
      const sourceMonday = DateUtil.mondayOf(r.sourceDate);
      expect(makeupMonday === sourceMonday).assertFalse();
    });

    it('没有补班日时不产生规则', 0, () => {
      const list: HolidayEntry[] = [h('元旦', 2025, 1, 1, 2025, 1, 1, HolidayType.STATUTORY)];
      expect(MakeupResolver.resolve(list, new Map<number, number>()).length).assertEqual(0);
    });

    it('只有补班日没有假期区间时不崩溃', 0, () => {
      const list: HolidayEntry[] = [h('国庆节', 2025, 10, 11, 2025, 10, 11, HolidayType.MAKEUP)];
      expect(MakeupResolver.resolve(list, new Map<number, number>()).length).assertEqual(0);
    });

    it('补班日离假期太远时不关联', 0, () => {
      const list: HolidayEntry[] = [
        h('国庆节', 2025, 10, 1, 2025, 10, 8, HolidayType.STATUTORY),
        h('国庆节', 2025, 12, 6, 2025, 12, 6, HolidayType.MAKEUP)
      ];
      expect(MakeupResolver.resolve(list, new Map<number, number>()).length).assertEqual(0);
    });

    it('越靠近区间末尾的工作日补得越晚', 0, () => {
      const rules = MakeupResolver.resolve(nationalDay2025(), new Map<number, number>());
      expect(rules.length).assertEqual(2);
      expect(rules[0].sourceDate).assertEqual(d(2025, 10, 7));
      expect(rules[1].sourceDate).assertEqual(d(2025, 10, 8));
    });

    it('周末不计入被占用的工作日', 0, () => {
      const rules = MakeupResolver.resolve(nationalDay2025(), new Map<number, number>());
      for (let i = 0; i < rules.length; i++) {
        const w = DateUtil.weekday(rules[i].sourceDate);
        expect(w !== 6 && w !== 7).assertTrue();
      }
    });

    it('手动覆盖优先于自动推导', 0, () => {
      const ov = new Map<number, number>();
      ov.set(d(2025, 10, 11), 5); // 改成补周五
      const r = find(MakeupResolver.resolve(nationalDay2025(), ov), d(2025, 10, 11))!;
      expect(r.sourceWeekday()).assertEqual(5);
      expect(r.manual).assertTrue();
    });

    it('手动指定后其他调休日仍按自动推导', 0, () => {
      const ov = new Map<number, number>();
      ov.set(d(2025, 10, 11), 5);
      const r = find(MakeupResolver.resolve(nationalDay2025(), ov), d(2025, 9, 28))!;
      expect(r.sourceDate).assertEqual(d(2025, 10, 7));
      expect(r.manual).assertFalse();
    });

    it('可以手动为推导不出的补班日指定', 0, () => {
      const list: HolidayEntry[] = [h('国庆节', 2025, 10, 11, 2025, 10, 11, HolidayType.MAKEUP)];
      const ov = new Map<number, number>();
      ov.set(d(2025, 10, 11), 3);
      const rules = MakeupResolver.resolve(list, ov);
      expect(rules.length).assertEqual(1);
      expect(rules[0].sourceWeekday()).assertEqual(3);
      expect(rules[0].manual).assertTrue();
    });

    it('寒假包住春节时仍按假期名关联', 0, () => {
      // 真实的 GLTU 校历里寒假(1/18–2/23) 会把春节(1/28–2/4) 整个包住，
      // 只按日期邻近关联会把春节的补班日错配到寒假块上
      const list = springFestival2025();
      list.push(h('寒假', 2025, 1, 18, 2025, 2, 23, HolidayType.SCHOOL));
      list.push(h('校运会', 2025, 10, 29, 2025, 10, 31, HolidayType.USER_DEFINED));
      const rules = MakeupResolver.resolve(list, new Map<number, number>());
      expect(find(rules, d(2025, 1, 26))!.sourceDate).assertEqual(d(2025, 2, 3));
      expect(find(rules, d(2025, 2, 8))!.sourceDate).assertEqual(d(2025, 2, 4));
    });

    it('结果按日期升序', 0, () => {
      const list = springFestival2025().concat(labourDay2025());
      const rules = MakeupResolver.resolve(list, new Map<number, number>());
      for (let i = 1; i < rules.length; i++) {
        expect(rules[i].date > rules[i - 1].date).assertTrue();
      }
    });

    it('summary 是「补 M/D（周X）的课」', 0, () => {
      const r = find(MakeupResolver.resolve(nationalDay2025(), new Map<number, number>()), d(2025, 10, 11))!;
      expect(r.summary()).assertEqual('补 10/8（周三）的课');
    });

    it('空输入返回空结果', 0, () => {
      expect(MakeupResolver.resolve([], new Map<number, number>()).length).assertEqual(0);
    });

    it('手动覆盖的编解码可往返', 0, () => {
      const m = new Map<number, number>();
      m.set(d(2025, 10, 11), 3);
      m.set(d(2025, 9, 28), 2);
      const text = MakeupResolver.encodeOverrides(m);
      const back = MakeupResolver.decodeOverrides(text);
      expect(back.size).assertEqual(2);
      expect(back.get(d(2025, 10, 11))).assertEqual(3);
      expect(back.get(d(2025, 9, 28))).assertEqual(2);
    });

    it('损坏的覆盖数据被跳过而不是崩溃', 0, () => {
      const back = MakeupResolver.decodeOverrides('123:3;bad;456:99;789:5');
      expect(back.size).assertEqual(2);
      expect(back.get(123)).assertEqual(3);
      expect(back.get(789)).assertEqual(5);
    });
  });
}
