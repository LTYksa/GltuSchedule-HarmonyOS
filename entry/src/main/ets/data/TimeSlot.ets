/**
 * GltuSchedule · 鸿蒙版 —— GLTU 作息时间表（13 个独立小节）
 * 对应 Android 版 `com.ltyksa.gltuschedule.data.TimeSlot` / `GltuTimeTable`
 */

/** 上午 / 下午 / 晚上 */
export enum DaySection {
  MORNING = 'MORNING',
  AFTERNOON = 'AFTERNOON',
  EVENING = 'EVENING'
}

/** 一个节次 */
export class TimeSlot {
  readonly index: number;
  readonly name: string;
  readonly startTime: string;
  readonly endTime: string;
  readonly section: DaySection;

  constructor(index: number, name: string, startTime: string, endTime: string, section: DaySection) {
    this.index = index;
    this.name = name;
    this.startTime = startTime;
    this.endTime = endTime;
    this.section = section;
  }
}

/**
 * 桂林旅游学院作息时间表（13 个独立小节）。
 * 与教务系统课表页逐条对齐。
 */
export class GltuTimeTable {
  static readonly slots: TimeSlot[] = [
    new TimeSlot(1, '第1节', '08:20', '08:50', DaySection.MORNING),
    new TimeSlot(2, '第2节', '09:00', '09:40', DaySection.MORNING),
    new TimeSlot(3, '第3节', '09:50', '10:30', DaySection.MORNING),
    new TimeSlot(4, '第4节', '10:40', '11:20', DaySection.MORNING),
    new TimeSlot(5, '第5节', '11:25', '12:05', DaySection.MORNING),
    new TimeSlot(6, '第6节', '14:00', '14:40', DaySection.AFTERNOON),
    new TimeSlot(7, '第7节', '14:45', '15:25', DaySection.AFTERNOON),
    new TimeSlot(8, '第8节', '15:35', '16:15', DaySection.AFTERNOON),
    new TimeSlot(9, '第9节', '16:20', '17:00', DaySection.AFTERNOON),
    new TimeSlot(10, '第10节', '18:30', '19:10', DaySection.EVENING),
    new TimeSlot(11, '第11节', '19:15', '19:55', DaySection.EVENING),
    new TimeSlot(12, '第12节', '20:05', '20:45', DaySection.EVENING),
    new TimeSlot(13, '第13节', '20:50', '21:30', DaySection.EVENING)
  ];

  /** 按节次序号取作息（取不到返回 undefined） */
  static byIndex(index: number): TimeSlot | undefined {
    for (let i = 0; i < GltuTimeTable.slots.length; i++) {
      if (GltuTimeTable.slots[i].index === index) {
        return GltuTimeTable.slots[i];
      }
    }
    return undefined;
  }

  /** 节次区间 → "第1-2节" */
  static rangeLabel(startIndex: number, endIndex: number): string {
    if (startIndex === endIndex) {
      return `第${startIndex}节`;
    }
    return `第${startIndex}-${endIndex}节`;
  }

  /** 节次区间 → "08:20 - 09:40" */
  static rangeTime(startIndex: number, endIndex: number): string {
    const s = GltuTimeTable.byIndex(startIndex);
    const e = GltuTimeTable.byIndex(endIndex);
    if (s === undefined || e === undefined) {
      return '';
    }
    return `${s.startTime} - ${e.endTime}`;
  }

  /** 该节次的上课时间（HH:mm），取不到返回 undefined */
  static startTimeOf(index: number): string | undefined {
    const s = GltuTimeTable.byIndex(index);
    return s === undefined ? undefined : s.startTime;
  }

  /**
   * 把课表里的节次文本解析成序号列表。
   * 支持 "1-2节"、"第3,4节"、"5" 等写法，用逗号/顿号/空格分隔。
   */
  static parseSlots(text: string): number[] {
    const result: number[] = [];
    if (text === undefined || text === null || text.length === 0) {
      return result;
    }
    const cleaned = text.replace(/[第节\s]/g, '');
    const parts = cleaned.split(/[,，、;；]/);
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if (p.length === 0) {
        continue;
      }
      const dash = p.match(/^(\d+)\s*[-~－]\s*(\d+)$/);
      if (dash !== null) {
        const a = parseInt(dash[1], 10);
        const b = parseInt(dash[2], 10);
        const lo = Math.min(a, b);
        const hi = Math.max(a, b);
        for (let n = lo; n <= hi; n++) {
          if (result.indexOf(n) < 0) {
            result.push(n);
          }
        }
      } else {
        const n = parseInt(p, 10);
        if (!isNaN(n) && result.indexOf(n) < 0) {
          result.push(n);
        }
      }
    }
    result.sort((a: number, b: number) => a - b);
    return result;
  }
}
