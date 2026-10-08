/**
 * GltuSchedule · 鸿蒙版 —— 中国大陆节假日联网同步
 * 对应 Android 版 `data/HolidaySync.kt`
 *
 * 数据源（与 Android 一致，都只含**中国大陆**节假日）：
 *   主源 `holiday-cn`（由《国务院办公厅关于节假日安排的通知》生成）
 *   备源 `timor.tech`
 *   都失败 → 用内置数据，不影响屏蔽功能
 *
 * ⚠️ 全天候只识别中国大陆法定节假日与调休补班日，
 *    不含任何其他国家或地区的节日。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Holiday, HolidayEntry, HolidayType } from './Holiday';
import { DateUtil } from './DateUtil';
import { StoreHolder } from '../database/CourseStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'GltuSchedule';

export const SOURCE_CN: string = '中国大陆法定节假日（国务院办公厅通知）';
export const SOURCE_BACKUP: string = 'timor.tech 中国大陆节假日接口';

const URL_HOLIDAY_CN: string = 'https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/%d.json';
const URL_TIMOR: string = 'https://timor.tech/api/holiday/year/%d';

/** 同步结果 */
export class HolidaySyncResult {
  ok: boolean = false;
  message: string = '';
  statutory: number = 0;
  makeup: number = 0;

  constructor(ok: boolean, message: string, statutory: number, makeup: number) {
    this.ok = ok;
    this.message = message;
    this.statutory = statutory;
    this.makeup = makeup;
  }
}

/** 同步回来的数据（供 HolidayManager.setSynced 使用） */
export class SyncedHolidays {
  statutory: HolidayEntry[] = [];
  makeup: HolidayEntry[] = [];
}

export class HolidaySync {

  // ==================== 主流程 ====================

  /** 同步今年 + 明年的节假日 */
  static async sync(): Promise<HolidaySyncResult> {
    const now = new Date();
    const years: number[] = [now.getFullYear(), now.getFullYear() + 1];

    // 主源
    let all: HolidayEntry[] = [];
    let fromCn = true;
    for (let i = 0; i < years.length; i++) {
      const body = await HolidaySync.getText(URL_HOLIDAY_CN.replace('%d', `${years[i]}`));
      if (body.length === 0) {
        continue;
      }
      const list = HolidaySync.parseHolidayCn(body);
      for (let k = 0; k < list.length; k++) {
        all.push(list[k]);
      }
    }

    if (all.length === 0) {
      // 备源
      fromCn = false;
      for (let i = 0; i < years.length; i++) {
        const body = await HolidaySync.getText(URL_TIMOR.replace('%d', `${years[i]}`));
        if (body.length === 0) {
          continue;
        }
        const list = HolidaySync.parseTimor(years[i], body);
        for (let k = 0; k < list.length; k++) {
          all.push(list[k]);
        }
      }
    }

    if (all.length === 0) {
      return new HolidaySyncResult(false,
        '同步失败：两个数据源都没取到（可能是网络问题或超时）。' +
        '当前使用内置的中国大陆节假日数据，不影响屏蔽功能。', 0, 0);
    }

    const statutory: HolidayEntry[] = [];
    const makeup: HolidayEntry[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].type === HolidayType.MAKEUP) {
        makeup.push(all[i]);
      } else {
        statutory.push(all[i]);
      }
    }

    const source = fromCn ? SOURCE_CN : SOURCE_BACKUP;
    await HolidaySync.saveToStore(statutory, makeup, source);

    const tail = fromCn ? '（国务院办公厅通知）' : '';
    return new HolidaySyncResult(true,
      `同步成功：${statutory.length} 个中国大陆法定假期、${makeup.length} 个调休补班日${tail}`,
      statutory.length, makeup.length);
  }

  // ==================== 持久化 ====================
  // 格式与 Android 一致：`名称:起始天数:结束天数:类型;…`

  private static encode(list: HolidayEntry[], type: HolidayType): string {
    const parts: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const h = list[i].holiday;
      parts.push(`${h.name}:${h.start}:${h.end}:${type}`);
    }
    return parts.join(';');
  }

  private static decode(raw: string, type: HolidayType): HolidayEntry[] {
    const out: HolidayEntry[] = [];
    if (raw === undefined || raw === null || raw.length === 0) {
      return out;
    }
    const parts = raw.split(';');
    for (let i = 0; i < parts.length; i++) {
      const seg = parts[i].split(':');
      if (seg.length < 3) {
        continue;
      }
      const start = parseInt(seg[1], 10);
      const end = parseInt(seg[2], 10);
      if (isNaN(start) || isNaN(end)) {
        continue;
      }
      out.push(new HolidayEntry(new Holiday(seg[0], start, end), type));
    }
    return out;
  }

  static async saveToStore(statutory: HolidayEntry[], makeup: HolidayEntry[], source: string): Promise<void> {
    const s = StoreHolder.instance;
    await s.putString('synced_holidays', HolidaySync.encode(statutory, HolidayType.STATUTORY));
    await s.putString('synced_makeup', HolidaySync.encode(makeup, HolidayType.MAKEUP));
    await s.putString('synced_source', source);
    await s.putNumber('synced_at', new Date().getTime());
  }

  /** 读出上次同步的数据（没有就返回空，调用方沿用内置数据） */
  static loadFromStore(): SyncedHolidays {
    const r = new SyncedHolidays();
    const s = StoreHolder.instance;
    r.statutory = HolidaySync.decode(s.getString('synced_holidays', ''), HolidayType.STATUTORY);
    r.makeup = HolidaySync.decode(s.getString('synced_makeup', ''), HolidayType.MAKEUP);
    return r;
  }

  static syncSource(): string {
    return StoreHolder.instance.getString('synced_source', '');
  }

  static lastSyncAt(): number {
    return StoreHolder.instance.getNumber('synced_at', 0);
  }

  // ==================== 解析（纯函数，便于单测）====================

  /**
   * holiday-cn 格式：
   * ```json
   * { "year": 2026,
   *   "days": [ {"name":"元旦","date":"2026-01-01","isOffDay":true},
   *             {"name":"春节","date":"2026-02-28","isOffDay":false} ] }
   * ```
   * `isOffDay=true` 为放假；`false` 为调休补班。同名的连续放假日合并成一个区间。
   */
  static parseHolidayCn(body: string): HolidayEntry[] {
    let root: Record<string, Object> | undefined = undefined;
    try {
      root = JSON.parse(body) as Record<string, Object>;
    } catch (e) {
      return [];
    }
    if (root === undefined || root === null) {
      return [];
    }
    const days = root.days as Object[];
    if (days === undefined || days === null || days.length === 0) {
      return [];
    }

    const offByName: Map<string, number[]> = new Map<string, number[]>();
    const makeups: HolidayEntry[] = [];

    for (let i = 0; i < days.length; i++) {
      const o = days[i] as Record<string, Object>;
      let name = o.name as string;
      if (name === undefined || name === null || name.length === 0) {
        name = '节假日';
      }
      const date = DateUtil.parse(o.date as string);
      if (date < 0) {
        continue;
      }
      if (o.isOffDay === true) {
        let arr = offByName.get(name);
        if (arr === undefined) {
          arr = [];
          offByName.set(name, arr);
        }
        arr.push(date);
      } else {
        makeups.push(new HolidayEntry(new Holiday(name, date, date), HolidayType.MAKEUP));
      }
    }

    const merged = HolidaySync.mergeOffDays(offByName);
    for (let i = 0; i < makeups.length; i++) {
      merged.push(makeups[i]);
    }
    return merged;
  }

  /**
   * timor.tech 格式：
   * ```json
   * { "code":0, "holiday": { "01-01": {"holiday":true,"name":"元旦","date":"2026-01-01"} } }
   * ```
   * `holiday=false` 且名字含「补班」的是调休上班日。连续放假日合并成一个区间。
   */
  static parseTimor(year: number, body: string): HolidayEntry[] {
    let root: Record<string, Object> | undefined = undefined;
    try {
      root = JSON.parse(body) as Record<string, Object>;
    } catch (e) {
      return [];
    }
    if (root === undefined || root === null) {
      return [];
    }
    const code = root.code as number;
    if (code !== 0) {
      return [];
    }
    const map = root.holiday as Record<string, Object>;
    if (map === undefined || map === null) {
      return [];
    }

    const offByName: Map<string, number[]> = new Map<string, number[]>();
    const makeups: HolidayEntry[] = [];
    const keys = Object.keys(map);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const o = map[key] as Record<string, Object>;
      if (o === undefined || o === null) {
        continue;
      }
      let dateStr = o.date as string;
      if (dateStr === undefined || dateStr === null || dateStr.length === 0) {
        dateStr = `${year}-${key}`;
      }
      const date = DateUtil.parse(dateStr);
      if (date < 0) {
        continue;
      }
      let name = o.name as string;
      if (name === undefined || name === null || name.length === 0) {
        name = '节假日';
      }
      if (o.holiday === true) {
        let arr = offByName.get(name);
        if (arr === undefined) {
          arr = [];
          offByName.set(name, arr);
        }
        arr.push(date);
      } else if (name.indexOf('补班') >= 0) {
        makeups.push(new HolidayEntry(new Holiday(name, date, date), HolidayType.MAKEUP));
      }
    }

    const merged = HolidaySync.mergeOffDays(offByName);
    for (let i = 0; i < makeups.length; i++) {
      merged.push(makeups[i]);
    }
    return merged;
  }

  /** 同名放假日按连续区间合并（1/1、1/2、1/3 → 一个 1/1–1/3） */
  private static mergeOffDays(offByName: Map<string, number[]>): HolidayEntry[] {
    const out: HolidayEntry[] = [];
    offByName.forEach((dates: number[], name: string) => {
      const sorted = dates.slice().sort((a: number, b: number) => a - b);
      if (sorted.length === 0) {
        return;
      }
      let start = sorted[0];
      let end = sorted[0];
      for (let i = 1; i < sorted.length; i++) {
        const d = sorted[i];
        if (d === end || d === end + 1) {
          end = d;
        } else {
          out.push(new HolidayEntry(new Holiday(name, start, end), HolidayType.STATUTORY));
          start = d;
          end = d;
        }
      }
      out.push(new HolidayEntry(new Holiday(name, start, end), HolidayType.STATUTORY));
    });
    return out;
  }

  // ==================== HTTP ====================

  /** 取文本；失败返回空串 */
  private static async getText(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        header: { 'Accept': 'application/json' }
      });
      if (resp.responseCode !== 200) {
        return '';
      }
      const result = resp.result;
      return typeof result === 'string' ? result as string : '';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '拉取节假日失败 %{public}s: %{public}s',
        url, JSON.stringify(e));
      return '';
    } finally {
      req.destroy();
    }
  }
}
