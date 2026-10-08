/**
 * GltuSchedule · 鸿蒙版 —— 壁纸裁切几何
 * 对应 Android 版 `ui/schedule/BackgroundCropDialog.kt` 里的 `computeCropGeometry`
 *
 * 这里**只放纯计算**，不碰任何 UI/图片 API —— 好处是可以直接用 Android 侧
 * `CropGeometryTest` 的 5 组断言验证移植正确性（见 `src/test/CropGeometry.test.ets`）。
 *
 * ## 单位
 * Android 全用 px。鸿蒙的 `GestureEvent.offsetX/offsetY` 和 ArkUI 布局是 **vp**，
 * 所以约定：**本文件的输入输出一律是 px**，只在手势/布局的边界上换算。
 *
 * ## 不变量（整个算法的正确性就靠它）
 * 视口 (0,0) 恰好映射到输出 (0,0)；视口 (vw,vh) 恰好映射到输出 (outW,outH)。
 *
 * 推导：图片左上角在视口中 = `视口中心 + offset - 原始尺寸*scale/2`；
 * 视口点映射到输出 `out = k*(p - 视口中心) + 输出中心`；
 * 合并得 `p_out = p_img*(scale*k) + offset*k + 输出中心 - 原始尺寸*(scale*k)/2`，
 * 即**先按 scale*k 缩放、再平移** —— 顺序不能反（反了位移会被二次缩放）。
 */

/** 裁切参数（输出尺寸 + 绘制矩阵的 scale/tx/ty） */
export class CropGeometry {
  outW: number = 0;
  outH: number = 0;
  scale: number = 0;
  tx: number = 0;
  ty: number = 0;

  constructor(outW: number, outH: number, scale: number, tx: number, ty: number) {
    this.outW = outW;
    this.outH = outH;
    this.scale = scale;
    this.tx = tx;
    this.ty = ty;
  }

  /** 本图对应的原图裁剪区（供 cropSync 用） */
  cropX(): number {
    return this.scale <= 0 ? 0 : -this.tx / this.scale;
  }

  cropY(): number {
    return this.scale <= 0 ? 0 : -this.ty / this.scale;
  }

  cropW(): number {
    return this.scale <= 0 ? 0 : this.outW / this.scale;
  }

  cropH(): number {
    return this.scale <= 0 ? 0 : this.outH / this.scale;
  }
}

export class CropMath {
  /** 输出宽度的允许区间（与 Android 一致） */
  static readonly MIN_OUT_W: number = 720;
  static readonly MAX_OUT_W: number = 1440;
  /** 最大放大倍数 */
  static readonly MAX_ZOOM: number = 8;

  /**
   * 「铺满视口」的最小缩放 = max(vw/srcW, vh/srcH)，永不露黑边。
   * 视口非法时返回 1。
   */
  static minScale(srcW: number, srcH: number, vw: number, vh: number): number {
    if (srcW <= 0 || srcH <= 0 || vw <= 0 || vh <= 0) {
      return 1;
    }
    return Math.max(vw / srcW, vh / srcH);
  }

  /** 缩放钳制到 [minScale, minScale*8] */
  static clampScale(scale: number, minS: number): number {
    const lo = minS;
    const hi = minS * CropMath.MAX_ZOOM;
    if (scale < lo) {
      return lo;
    }
    return scale > hi ? hi : scale;
  }

  /**
   * 拖动范围限制：图片边缘不能拖进视口内。
   * `maxX = max(0, (srcW*s - vw) / 2)`
   */
  static clampOffsetX(offX: number, srcW: number, scale: number, vw: number): number {
    const maxX = Math.max(0, (srcW * scale - vw) / 2);
    if (offX < -maxX) {
      return -maxX;
    }
    return offX > maxX ? maxX : offX;
  }

  static clampOffsetY(offY: number, srcH: number, scale: number, vh: number): number {
    const maxY = Math.max(0, (srcH * scale - vh) / 2);
    if (offY < -maxY) {
      return -maxY;
    }
    return offY > maxY ? maxY : offY;
  }

  /**
   * 由「原图尺寸 + 当前缩放/位移 + 视口尺寸」算出输出图与绘制矩阵。
   *
   * 非法输入（任一 <= 0）返回 `undefined`。
   */
  static compute(
    srcW: number, srcH: number,
    scale: number, ox: number, oy: number,
    vw: number, vh: number,
  ): CropGeometry | undefined {
    if (vw <= 0 || vh <= 0 || srcW <= 0 || srcH <= 0 || scale <= 0) {
      return undefined;
    }
    // 输出宽度钳到 [720, 1440]，高度按视口比例推（不钳）
    let outW = Math.round(vw);
    if (outW < CropMath.MIN_OUT_W) {
      outW = CropMath.MIN_OUT_W;
    } else if (outW > CropMath.MAX_OUT_W) {
      outW = CropMath.MAX_OUT_W;
    }
    const outH = Math.max(1, Math.round(outW * (vh / vw)));

    const k = outW / vw;
    const s = scale * k;
    const tx = ox * k + outW / 2 - (srcW * s) / 2;
    const ty = oy * k + outH / 2 - (srcH * s) / 2;
    return new CropGeometry(outW, outH, s, tx, ty);
  }
}
