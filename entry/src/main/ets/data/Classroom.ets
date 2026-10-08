/**
 * GltuSchedule · 鸿蒙版 —— 教室房号 → 教学楼 / 楼层
 * 对应 Android 版 `com.ltyksa.gltuschedule.data.Classroom`
 *
 * 学校房号规则（4 位 ABCD）：
 *   A = 楼（1 旅勤楼 / 2 旅思楼 / 3 旅博楼 / 4 旅齐楼）
 *   B = 楼层
 *   CD = 教室号
 * 例：3217 → 旅博楼 2 楼 17 号教室
 */

/** 教学楼名（下标即首位数字） */
const BUILDINGS: string[] = ['', '旅勤楼', '旅思楼', '旅博楼', '旅齐楼'];

/** 房号匹配：4 位数字，首位 1-4，且左右不能再接数字 */
const ROOM_PATTERN: RegExp = /(?<!\d)([1-4])(\d)(\d{2})(?!\d)/;

/** 校区前缀（用于短标签/详细标签时剥掉） */
const CAMPUS_PATTERN: RegExp = /^[\u4e00-\u9fa5]{2,4}校区\s*/;

export class RoomInfo {
  readonly room: string;
  readonly building: string;
  readonly floor: number;
  readonly roomNo: number;

  constructor(room: string, building: string, floor: number, roomNo: number) {
    this.room = room;
    this.building = building;
    this.floor = floor;
    this.roomNo = roomNo;
  }
}

export class Classroom {
  /**
   * 从地点文本里解析房号信息。
   * 解析不到（虚拟教室、体育馆等）返回 undefined，调用方原样展示即可。
   */
  static find(location: string): RoomInfo | undefined {
    if (location === undefined || location === null || location.length === 0) {
      return undefined;
    }
    const m = location.match(ROOM_PATTERN);
    if (m === null) {
      return undefined;
    }
    const room = m[0];
    const buildingIndex = parseInt(room.charAt(0), 10);
    if (buildingIndex < 1 || buildingIndex > 4) {
      return undefined;
    }
    const floor = parseInt(room.charAt(1), 10);
    const roomNo = parseInt(room.substring(2, 4), 10);
    return new RoomInfo(room, BUILDINGS[buildingIndex], floor, roomNo);
  }

  /**
   * 课表格子/日视图用的短标签：把「校区」换成「楼栋」。
   * "雁山校区 3220（阶7教室）" → "旅博楼 3220（阶7教室）"
   * 解析不到房号时原样返回。
   */
  static shortLabel(location: string): string {
    if (location === undefined || location === null || location.length === 0) {
      return '';
    }
    const info = Classroom.find(location);
    if (info === undefined) {
      return location;
    }
    const withoutCampus = location.replace(CAMPUS_PATTERN, '');
    return withoutCampus.replace(info.room, `${info.building} ${info.room}`);
  }

  /**
   * 课程详情用的完整标签。
   * "雁山校区 3220（阶7教室）" → "雁山校区 · 旅博楼 2 楼 · 3220（阶7教室）"
   */
  static detailLabel(location: string): string {
    if (location === undefined || location === null || location.length === 0) {
      return '';
    }
    const info = Classroom.find(location);
    if (info === undefined) {
      return location;
    }
    const campusMatch = location.match(/^([\u4e00-\u9fa5]{2,4}校区)\s*/);
    const rest = location.replace(CAMPUS_PATTERN, '');
    const parts: string[] = [];
    if (campusMatch !== null) {
      parts.push(campusMatch[1]);
    }
    parts.push(`${info.building} ${info.floor} 楼`);
    parts.push(rest);
    return parts.join(' · ');
  }
}
