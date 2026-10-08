/**
 * GltuSchedule · 鸿蒙版 —— 共享视觉常量
 *
 * 配色取自 Android 版的**静态回退配色**（浅色 primary = #4E6E9E），
 * 尺寸逐条对齐 Android 版（dp → vp 数值相同）。
 *
 * ## 深色模式怎么实现的
 * `C.xxx` 是**可变的静态字段**（不是 readonly）。切主题时调 `C.applyDark(true/false)`
 * 把整张表重写一遍；由于 ArkUI 在 `@StorageProp('themeDark')` 变化时会重建组件树，
 * 而各处 `.fontColor(C.xxx)` 都是**构建时读取**，所以重建后自然拿到新色值。
 *
 * 这样做的好处：**约 200 处 `C.xxx` 用法一行都不用改**，
 * 也不用把颜色改成 `$r('app.color.xxx')` 资源引用（那样 `Col.alpha(C.xxx, a)` 会失效，
 * 因为 `Col.alpha` 要的是 `#RRGGBB` 字符串）。
 *
 * 代价：颜色不随系统资源解析，必须由 `EntryAbility` / 设置页显式调 `applyDark`。
 */
export class C {
  // ---- 主题色 ----
  static primary: string = '#4E6E9E';        // Android Blue40
  static onPrimary: string = '#FFFFFF';
  static primaryContainer: string = '#D6E3FF';
  static onPrimaryContainer: string = '#001B3D';
  static secondary: string = '#5B6472';      // Android BlueGrey40
  static secondaryContainer: string = '#DEE2F0';

  // ---- 表面 ----
  static surface: string = '#FDFBFF';        // 顶栏/日期行/网格底色
  static pageBg: string = '#F5F5F7';         // 设置页底色
  static card: string = '#FFFFFF';           // 设置页卡片
  static surfaceVariant: string = '#E1E2EC'; // 顶栏分段控件底
  static surfaceContainerHighest: string = '#E4E2E6';

  // ---- 文字 ----
  static onSurface: string = '#1A1C1E';
  static onSurfaceVariant: string = '#44474E';

  // ---- 线条 ----
  static outline: string = '#74777F';
  static outlineVariant: string = '#C4C6D0';

  // ---- 状态 ----
  static error: string = '#BA1A1A';
  static errorContainer: string = '#FFDAD6';
  static onErrorContainer: string = '#410002';

  // ---- 课程专用（深浅色都一样）----
  static dimGray: string = '#9E9E9E';        // 非本周课程统一灰

  /** 调休（补课）标记色 —— 浅色与 Android 版 MAKEUP_COLOR 一致 */
  static makeup: string = '#B26A00';

  // ---- 遮罩 ----
  static mask: string = '#66000000';

  /** 当前是否深色（供少数需要判断的地方用） */
  static dark: boolean = false;

  /**
   * 切换深浅色：重写整张色表。
   *
   * 深色取 Material 3 深色基线；其中 primary / secondary 取 Android 版
   * `Color.kt` 里真实存在的深色回退色（Blue80 `#A8C4E0`、BlueGrey80 `#BFC7D4`），
   * 其余 Android 侧是 Material 默认值，这里按 M3 基线补齐。
   */
  static applyDark(dark: boolean): void {
    C.dark = dark;
    if (dark) {
      C.primary = '#A8C4E0';              // Android Blue80
      C.onPrimary = '#1A3352';
      C.primaryContainer = '#34495F';
      C.onPrimaryContainer = '#D6E3FF';
      C.secondary = '#BFC7D4';            // Android BlueGrey80
      C.secondaryContainer = '#3A4048';

      C.surface = '#141218';
      C.pageBg = '#101014';
      C.card = '#1C1B1F';
      C.surfaceVariant = '#2B2930';
      C.surfaceContainerHighest = '#211F26';

      C.onSurface = '#E6E1E5';
      C.onSurfaceVariant = '#CAC4D0';

      C.outline = '#938F99';
      C.outlineVariant = '#49454F';

      C.error = '#F2B8B5';
      C.errorContainer = '#8C1D18';
      C.onErrorContainer = '#FFDAD6';

      C.makeup = '#FFB74D';               // 深底上要亮一点的琥珀
      C.mask = '#8C000000';
    } else {
      C.primary = '#4E6E9E';
      C.onPrimary = '#FFFFFF';
      C.primaryContainer = '#D6E3FF';
      C.onPrimaryContainer = '#001B3D';
      C.secondary = '#5B6472';
      C.secondaryContainer = '#DEE2F0';

      C.surface = '#FDFBFF';
      C.pageBg = '#F5F5F7';
      C.card = '#FFFFFF';
      C.surfaceVariant = '#E1E2EC';
      C.surfaceContainerHighest = '#E4E2E6';

      C.onSurface = '#1A1C1E';
      C.onSurfaceVariant = '#44474E';

      C.outline = '#74777F';
      C.outlineVariant = '#C4C6D0';

      C.error = '#BA1A1A';
      C.errorContainer = '#FFDAD6';
      C.onErrorContainer = '#410002';

      C.makeup = '#B26A00';
      C.mask = '#66000000';
    }
  }

  /** 主题模式常量（与 Android `SchedulePreferences` 一致） */
  static readonly THEME_SYSTEM: number = 0;
  static readonly THEME_LIGHT: number = 1;
  static readonly THEME_DARK: number = 2;

  /**
   * 由「主题模式 + 系统深浅色」算出最终是否深色。
   * @param themeMode 0=跟随系统 1=浅色 2=深色
   * @param systemDark 系统当前是否深色
   */
  static resolveDark(themeMode: number, systemDark: boolean): boolean {
    if (themeMode === C.THEME_LIGHT) {
      return false;
    }
    if (themeMode === C.THEME_DARK) {
      return true;
    }
    return systemDark;
  }
}

/** 尺寸（与 Android 版的 dp 数值一一对应，单位改成 vp） */
export class D {
  static readonly timeColW: number = 40;    // 节次轴宽度
  static readonly rowH: number = 54;        // 每节高度
  static readonly dateRowH: number = 70;    // 日期行高度
  static readonly dateBox: number = 26;     // 日期方块边长
  static readonly pagePad: number = 16;     // 设置页外边距
  static readonly cardGap: number = 12;     // 卡片间距
  static readonly cardPad: number = 16;     // 卡片内边距
  static readonly cardRadius: number = 12;  // 卡片圆角
  static readonly tabH: number = 56;        // 底部导航高度（旧：通栏）

  // ---- 悬浮胶囊底栏 ----
  // 数值对齐鸿蒙系统应用（电话/联系人）的底部胶囊：
  //   胶囊底 → 小白条顶 ≈ 8vp，小白条高 ≈ 5.5vp，小白条底 → 屏幕底 ≈ 2.4vp
  //   ⇒ 展开态胶囊底距屏幕底 ≈ 16vp（再叠加小白条高度）
  static readonly floatNavH: number = 58;       // 胶囊高度（展开）
  /** 展开态：胶囊底边距屏幕底部 */
  static readonly floatNavBottom: number = 10;
  /** 页面要预留的底部空间（仅作默认值，实际用 Index 的 navClearance()） */
  static readonly floatNavClear: number = 100;

  // ---- 收起态（滚动时）----
  // 收起时胶囊变矮、去掉文字、整体沉下去
  static readonly navMinH: number = 42;         // 收起高度
  static readonly navMinBottom: number = 4;     // 收起时更贴底
  static readonly navItemW: number = 96;        // 单个条目宽度（展开）
  static readonly navItemWMin: number = 72;     // 单个条目宽度（收起）
  static readonly navAnimMs: number = 240;      // 收起/展开动画时长
  /** 网格最后一行与胶囊之间的呼吸间距 */
  static readonly navGap: number = 2;
}

/** 常用颜色工具 */
export class Col {
  /** #RRGGBB → #AARRGGBB（ArkUI 支持 8 位十六进制） */
  static alpha(hex: string, a: number): string {
    const v = Math.max(0, Math.min(255, Math.round(a * 255)));
    const s = v.toString(16);
    return `#${s.length === 1 ? '0' + s : s}${hex.substring(1)}`;
  }

  /** 按比例加深（用于文字，提升浅底上的可读性）—— 与 Android 版 darken 等价 */
  static darken(hex: string, factor: number): string {
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    const f = (v: number): string => {
      const n = Math.max(0, Math.min(255, Math.round(v * factor)));
      const s = n.toString(16);
      return s.length === 1 ? '0' + s : s;
    };
    return `#${f(r)}${f(g)}${f(b)}`;
  }

  /** 按比例提亮（深色模式下文字需要反着来） */
  static lighten(hex: string, factor: number): string {
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    const f = (v: number): string => {
      const n = Math.max(0, Math.min(255, Math.round(255 - (255 - v) * (2 - factor))));
      const s = n.toString(16);
      return s.length === 1 ? '0' + s : s;
    };
    return `#${f(r)}${f(g)}${f(b)}`;
  }
}
