/**
 * GltuSchedule · 鸿蒙版 —— 壁纸裁切几何测试
 *
 * **本文件的 5 组断言逐条移植自 Android 版 `CropGeometryTest.kt`** ——
 * 用的是同一个夹具 `srcW=4000, srcH=3000, vw=1080, vh=2340`，
 * 所以它同时验证了两件事：算法没写错，且与安卓版**数值一致**。
 *
 * 公共夹具下 `minScale = max(1080/4000, 2340/3000) = max(0.27, 0.78) = 0.78`
 */
import { describe, it, expect } from '@ohos/hypium';
import { CropGeometry, CropMath } from '../main/ets/data/CropGeometry';

const SRC_W: number = 4000;
const SRC_H: number = 3000;
const VW: number = 1080;
const VH: number = 2340;

/** 容差 1px（与 Android 的 assertEquals(expected, actual, 1f) 等价） */
function near(actual: number, expected: number): boolean {
  return Math.abs(actual - expected) <= 1;
}

/** 原图某点 → 输出图坐标 */
function toOutX(g: CropGeometry, px: number): number {
  return px * g.scale + g.tx;
}

function toOutY(g: CropGeometry, py: number): number {
  return py * g.scale + g.ty;
}

/** 图片左上角在视口中的位置 */
function imgLeftInView(scale: number, ox: number): number {
  return VW / 2 + ox - (SRC_W * scale) / 2;
}

function imgTopInView(scale: number, oy: number): number {
  return VH / 2 + oy - (SRC_H * scale) / 2;
}

/** 视口坐标 → 原图坐标 */
function viewToImgX(v: number, left: number, scale: number): number {
  return (v - left) / scale;
}

function viewToImgY(v: number, top: number, scale: number): number {
  return (v - top) / scale;
}

/**
 * 核心不变量：视口四角映射到输出四角。
 * 视口 (0,0) → 输出 (0,0)；视口 (vw,vh) → 输出 (outW,outH)。
 */
function checkRoundTrip(scale: number, ox: number, oy: number): number {
  const g = CropMath.compute(SRC_W, SRC_H, scale, ox, oy, VW, VH)!;
  const left = imgLeftInView(scale, ox);
  const top = imgTopInView(scale, oy);

  const imgX0 = viewToImgX(0, left, scale);
  const imgY0 = viewToImgY(0, top, scale);
  const imgX1 = viewToImgX(VW, left, scale);
  const imgY1 = viewToImgY(VH, top, scale);

  let bad = 0;
  if (!near(toOutX(g, imgX0), 0)) {
    bad++;
  }
  if (!near(toOutY(g, imgY0), 0)) {
    bad++;
  }
  if (!near(toOutX(g, imgX1), g.outW)) {
    bad++;
  }
  if (!near(toOutY(g, imgY1), g.outH)) {
    bad++;
  }
  return bad;
}

export default function cropGeometryTest() {
  describe('CropGeometry', () => {

    it('minScale 取「铺满视口」所需的最小缩放', 0, () => {
      const m = CropMath.minScale(SRC_W, SRC_H, VW, VH);
      // max(1080/4000, 2340/3000) = max(0.27, 0.78)
      expect(near(m, 0.78)).assertTrue();
    });

    it('铺满时的四角映射', 0, () => {
      const m = CropMath.minScale(SRC_W, SRC_H, VW, VH);
      expect(checkRoundTrip(m, 0, 0)).assertEqual(0);
    });

    it('放大并拖动后四角仍然对齐', 0, () => {
      const m = CropMath.minScale(SRC_W, SRC_H, VW, VH);
      expect(checkRoundTrip(m * 2.5, 120, -230)).assertEqual(0);
      expect(checkRoundTrip(m * 5, -400, 160)).assertEqual(0);
    });

    it('输出比例等于屏幕比例', 0, () => {
      const g = CropMath.compute(SRC_W, SRC_H, 1, 0, 0, VW, VH)!;
      const want = VH / VW;
      const got = g.outH / g.outW;
      expect(Math.abs(want - got) < 0.002).assertTrue();
    });

    it('竖屏输出高大于宽', 0, () => {
      const g = CropMath.compute(1080, 2400, 1, 0, 0, 1080, 2340)!;
      expect(g.outW).assertEqual(1080);
      expect(g.outH).assertEqual(2340);
      expect(g.outH > g.outW).assertTrue();
    });

    it('横屏输出宽大于高且被钳到 1440', 0, () => {
      const g = CropMath.compute(SRC_W, SRC_H, 1, 0, 0, 2000, 1200)!;
      expect(g.outW).assertEqual(1440);
      expect(g.outH).assertEqual(864);
      expect(g.outH < g.outW).assertTrue();
    });

    it('窄视口的输出宽度被抬到 720', 0, () => {
      const g = CropMath.compute(SRC_W, SRC_H, 1, 0, 0, 400, 800)!;
      expect(g.outW).assertEqual(720);
    });

    it('非法输入返回 undefined', 0, () => {
      expect(CropMath.compute(0, 100, 1, 0, 0, VW, VH) === undefined).assertTrue();
      expect(CropMath.compute(100, 100, 0, 0, 0, VW, VH) === undefined).assertTrue();
      expect(CropMath.compute(100, 100, 1, 0, 0, 0, VH) === undefined).assertTrue();
      expect(CropMath.compute(100, 100, 1, 0, 0, VW, 0) === undefined).assertTrue();
      expect(CropMath.compute(-1, 100, 1, 0, 0, VW, VH) === undefined).assertTrue();
    });

    it('缩放被钳在 [minScale, minScale*8]', 0, () => {
      const m = CropMath.minScale(SRC_W, SRC_H, VW, VH);
      expect(near(CropMath.clampScale(m * 0.1, m), m)).assertTrue();
      expect(near(CropMath.clampScale(m * 100, m), m * 8)).assertTrue();
      expect(near(CropMath.clampScale(m * 3, m), m * 3)).assertTrue();
    });

    it('铺满时不允许拖动（无可拖空间）', 0, () => {
      const m = CropMath.minScale(SRC_W, SRC_H, VW, VH);
      // 铺满时图片宽度 4000*0.78 = 3120 > 1080，宽度方向可拖
      const maxX = Math.max(0, (SRC_W * m - VW) / 2);
      expect(near(CropMath.clampOffsetX(99999, SRC_W, m, VW), maxX)).assertTrue();
      expect(near(CropMath.clampOffsetX(-99999, SRC_W, m, VW), -maxX)).assertTrue();
      // 高度方向正好铺满 → maxY = 0，完全不能拖
      const maxY = Math.max(0, (SRC_H * m - VH) / 2);
      expect(near(maxY, 0)).assertTrue();
      expect(near(CropMath.clampOffsetY(500, SRC_H, m, VH), 0)).assertTrue();
    });

    it('cropX/cropY/cropW/cropH 给出原图裁剪区', 0, () => {
      const m = CropMath.minScale(SRC_W, SRC_H, VW, VH);
      const g = CropMath.compute(SRC_W, SRC_H, m, 0, 0, VW, VH)!;
      // 铺满 + 不拖动 → 裁剪区宽度应等于原图宽度（高度方向正好铺满）
      expect(near(g.cropH(), SRC_H)).assertTrue();
      // 裁剪区不能超出原图
      expect(g.cropX() >= -1).assertTrue();
      expect(g.cropY() >= -1).assertTrue();
      expect(g.cropX() + g.cropW() <= SRC_W + 1).assertTrue();
    });

    it('输出的长宽比与输入视口一致（多种视口）', 0, () => {
      const views: number[][] = [[1080, 2340], [1080, 1920], [2000, 1200], [720, 1600]];
      for (let i = 0; i < views.length; i++) {
        const vw = views[i][0];
        const vh = views[i][1];
        const g = CropMath.compute(SRC_W, SRC_H, 1, 0, 0, vw, vh)!;
        const want = vh / vw;
        const got = g.outH / g.outW;
        expect(Math.abs(want - got) < 0.002).assertTrue();
      }
    });
  });
}
