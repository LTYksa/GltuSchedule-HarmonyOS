/**
 * GltuSchedule · 鸿蒙版 —— 节假日联网同步的数据解析测试
 *
 * 只测**纯函数**（不联网）：两路数据源的 JSON 解析与连续日合并。
 * 断言用的 JSON 是两路接口的**真实报文结构**。
 */
import { describe, it, expect } from '@ohos/hypium';
import { HolidayEntry, HolidayType } from '../main/ets/data/Holiday';
import { HolidaySync } from '../main/ets/data/HolidaySync';
import { DateUtil } from '../main/ets/data/DateUtil';

/** 按名字 + 类型找一条 */
function find(list: HolidayEntry[], name: string, type: HolidayType): HolidayEntry | undefined {
  for (let i = 0; i < list.length; i++) {
    if (list[i].holiday.name === name && list[i].type === type) {
      return list[i];
    }
  }
  return undefined;
}

export default function holidaySyncTest() {
  describe('HolidaySync', () => {

    it('holiday-cn 解析放假与补班', 0, () => {
      const body = '{"year":2025,"papers":["https://www.gov.cn/"],"days":[' +
        '{"name":"元旦","date":"2025-01-01","isOffDay":true},' +
        '{"name":"春节","date":"2025-01-26","isOffDay":false},' +
        '{"name":"春节","date":"2025-02-08","isOffDay":false}]}';
      const list = HolidaySync.parseHolidayCn(body);
      expect(list.length).assertEqual(3);

      const ny = find(list, '元旦', HolidayType.STATUTORY)!;
      expect(ny.holiday.start).assertEqual(DateUtil.fromYmd(2025, 1, 1));
      expect(ny.holiday.end).assertEqual(DateUtil.fromYmd(2025, 1, 1));

      const mk1 = find(list, '春节', HolidayType.MAKEUP)!;
      expect(mk1.holiday.start).assertEqual(DateUtil.fromYmd(2025, 1, 26));
      expect(mk1.holiday.end).assertEqual(DateUtil.fromYmd(2025, 1, 26));
    });

    it('holiday-cn 把连续放假日合并成区间', 0, () => {
      const body = '{"year":2025,"days":[' +
        '{"name":"国庆节","date":"2025-10-01","isOffDay":true},' +
        '{"name":"国庆节","date":"2025-10-02","isOffDay":true},' +
        '{"name":"国庆节","date":"2025-10-03","isOffDay":true},' +
        '{"name":"国庆节","date":"2025-10-06","isOffDay":true}]}';
      const list = HolidaySync.parseHolidayCn(body);
      // 10/1–10/3 合并成一条，10/6 另起一条
      expect(list.length).assertEqual(2);
      const a = find(list, '国庆节', HolidayType.STATUTORY)!;
      expect(a.holiday.start).assertEqual(DateUtil.fromYmd(2025, 10, 1));
      let found: HolidayEntry | undefined = undefined;
      for (let i = 0; i < list.length; i++) {
        if (list[i].holiday.contains(DateUtil.fromYmd(2025, 10, 6))) {
          found = list[i];
        }
      }
      expect(found !== undefined).assertTrue();
      expect(found!.holiday.start).assertEqual(DateUtil.fromYmd(2025, 10, 6));
    });

    it('holiday-cn 名字为空时回落「节假日」', 0, () => {
      const body = '{"year":2025,"days":[{"name":"","date":"2025-05-01","isOffDay":true}]}';
      const list = HolidaySync.parseHolidayCn(body);
      expect(list.length).assertEqual(1);
      expect(list[0].holiday.name).assertEqual('节假日');
    });

    it('holiday-cn 坏 JSON 返回空而不是崩溃', 0, () => {
      expect(HolidaySync.parseHolidayCn('{ 这不是 JSON').length).assertEqual(0);
      expect(HolidaySync.parseHolidayCn('{}').length).assertEqual(0);
      expect(HolidaySync.parseHolidayCn('{"days":[]}').length).assertEqual(0);
    });

    it('holiday-cn 非法日期被跳过', 0, () => {
      const body = '{"days":[{"name":"X","date":"乱写","isOffDay":true},' +
        '{"name":"Y","date":"2025-01-01","isOffDay":true}]}';
      const list = HolidaySync.parseHolidayCn(body);
      expect(list.length).assertEqual(1);
      expect(list[0].holiday.name).assertEqual('Y');
    });

    it('timor 解析放假与补班', 0, () => {
      const body = '{"code":0,"holiday":{' +
        '"01-01":{"holiday":true,"name":"元旦","date":"2025-01-01"},' +
        '"01-26":{"holiday":false,"name":"春节补班","date":"2025-01-26"}}}';
      const list = HolidaySync.parseTimor(2025, body);
      expect(list.length).assertEqual(2);
      expect(find(list, '元旦', HolidayType.STATUTORY) !== undefined).assertTrue();
      expect(find(list, '春节补班', HolidayType.MAKEUP) !== undefined).assertTrue();
    });

    it('timor 只把名字含「补班」的当补班日', 0, () => {
      const body = '{"code":0,"holiday":{' +
        '"03-08":{"holiday":false,"name":"妇女节","date":"2025-03-08"}}}';
      const list = HolidaySync.parseTimor(2025, body);
      expect(list.length).assertEqual(0);
    });

    it('timor code 非 0 时返回空', 0, () => {
      expect(HolidaySync.parseTimor(2025, '{"code":1,"holiday":{}}').length).assertEqual(0);
      expect(HolidaySync.parseTimor(2025, '{"code":0}').length).assertEqual(0);
    });

    it('timor 缺 date 字段时用年+键拼出来', 0, () => {
      const body = '{"code":0,"holiday":{"05-01":{"holiday":true,"name":"劳动节"}}}';
      const list = HolidaySync.parseTimor(2025, body);
      expect(list.length).assertEqual(1);
      expect(list[0].holiday.start).assertEqual(DateUtil.fromYmd(2025, 5, 1));
    });

    it('timor 坏 JSON 返回空而不是崩溃', 0, () => {
      expect(HolidaySync.parseTimor(2025, '不是 JSON').length).assertEqual(0);
    });

    it('两路数据源解析出的结果一致（同一天同类型）', 0, () => {
      const cn = HolidaySync.parseHolidayCn('{"days":[' +
        '{"name":"劳动节","date":"2025-05-01","isOffDay":true},' +
        '{"name":"劳动节","date":"2025-05-02","isOffDay":true},' +
        '{"name":"劳动节","date":"2025-04-27","isOffDay":false}]}');
      const ti = HolidaySync.parseTimor(2025, '{"code":0,"holiday":{' +
        '"05-01":{"holiday":true,"name":"劳动节","date":"2025-05-01"},' +
        '"05-02":{"holiday":true,"name":"劳动节","date":"2025-05-02"},' +
        '"04-27":{"holiday":false,"name":"劳动节补班","date":"2025-04-27"}}}');
      expect(cn.length).assertEqual(2);
      expect(ti.length).assertEqual(2);
      // 假期区间一致
      const cnOff = find(cn, '劳动节', HolidayType.STATUTORY)!;
      const tiOff = find(ti, '劳动节', HolidayType.STATUTORY)!;
      expect(cnOff.holiday.start).assertEqual(tiOff.holiday.start);
      expect(cnOff.holiday.end).assertEqual(tiOff.holiday.end);
      // 补班日一致
      let cnMk: HolidayEntry | undefined = undefined;
      let tiMk: HolidayEntry | undefined = undefined;
      for (let i = 0; i < cn.length; i++) {
        if (cn[i].type === HolidayType.MAKEUP) {
          cnMk = cn[i];
        }
      }
      for (let i = 0; i < ti.length; i++) {
        if (ti[i].type === HolidayType.MAKEUP) {
          tiMk = ti[i];
        }
      }
      expect(cnMk!.holiday.start).assertEqual(tiMk!.holiday.start);
    });
  });
}
