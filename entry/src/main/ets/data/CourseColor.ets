/**
 * GltuSchedule · 鸿蒙版 —— 课程配色
 * 对应 Android 版 `com.ltyksa.gltuschedule.data.CourseColor` / `CourseCategory`
 *
 * 同名同色、不同课不同色：按课程名哈希在 16 色调色板里稳定取色。
 */

/** 课程分类 */
export enum CourseCategory {
  THEORY = '理论课',
  LAB = '实验/实践',
  SPORT = '体育',
  PUBLIC = '公共课',
  MAJOR = '专业课',
  ELECTION = '选修课',
  OTHER = '其他'
}

/** 16 色柔和调色板（浅色/深色主题下都清晰） */
const PALETTE: string[] = [
  '#4E6E9E', '#2E8B6E', '#D97706', '#7C5CBF',
  '#C24444', '#0E8A8A', '#5B6472', '#8E5A9E',
  '#2F7D3A', '#B05A2A', '#3A6FB0', '#A03D6E',
  '#5E7C2F', '#7A5C3E', '#456B7A', '#95527A'
];

export class CourseColor {
  /** 按课程名稳定取色（同一门课永远同色） */
  static of(courseName: string): string {
    if (courseName === undefined || courseName === null || courseName.length === 0) {
      return PALETTE[0];
    }
    let hash = 0;
    for (let i = 0; i < courseName.length; i++) {
      hash = (hash * 31 + courseName.charCodeAt(i)) | 0;
    }
    const idx = Math.abs(hash) % PALETTE.length;
    return PALETTE[idx];
  }

  /** 把颜色调深（用于文字，浅底上更清晰） */
  static darken(hex: string, factor: number): string {
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    const dr = Math.max(0, Math.min(255, Math.round(r * factor)));
    const dg = Math.max(0, Math.min(255, Math.round(g * factor)));
    const db = Math.max(0, Math.min(255, Math.round(b * factor)));
    return `#${CourseColor.hex2(dr)}${CourseColor.hex2(dg)}${CourseColor.hex2(db)}`;
  }

  /** 带透明度的 ARGB 字符串（ArkUI 支持 #AARRGGBB） */
  static withAlpha(hex: string, alpha: number): string {
    const a = Math.max(0, Math.min(255, Math.round(alpha * 255)));
    return `#${CourseColor.hex2(a)}${hex.substring(1)}`;
  }

  /** 根据课程名/地点粗略推断分类 */
  static inferCategory(name: string, location: string): CourseCategory {
    const n = (name === undefined || name === null) ? '' : name;
    const l = (location === undefined || location === null) ? '' : location;
    if (/体育|健美操|篮球|足球|排球|羽毛球|乒乓球|垒球|网球|武术|瑜伽/.test(n)) {
      return CourseCategory.SPORT;
    }
    if (/实验|实训|实践|实习|上机/.test(n) || /实训|实验/.test(l)) {
      return CourseCategory.LAB;
    }
    if (/思想道德|马克思主义|毛泽东|习近平|近代史|形势与政策|大学英语|体育|军训|心理健康|职业生涯|创新创业|劳动/.test(n)) {
      return CourseCategory.PUBLIC;
    }
    if (/概论|原理|理论|学$|导论/.test(n)) {
      return CourseCategory.THEORY;
    }
    if (/选修|任选|公选/.test(n)) {
      return CourseCategory.ELECTION;
    }
    return CourseCategory.MAJOR;
  }

  private static hex2(v: number): string {
    const s = v.toString(16);
    return s.length === 1 ? `0${s}` : s;
  }
}
