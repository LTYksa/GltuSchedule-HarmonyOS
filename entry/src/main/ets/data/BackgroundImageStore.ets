/**
 * GltuSchedule · 鸿蒙版 —— 课表背景图（壁纸）
 * 对应 Android 版 `data/BackgroundImageStore.kt`
 *
 * ## 与 Android 的差异
 * | | Android | 鸿蒙 |
 * |---|---|---|
 * | 存哪 | `filesDir/schedule_background.jpg` | 同名同路径（`context.filesDir`） |
 * | 选图 | `PickVisualMedia` | `photoAccessHelper.PhotoViewPicker`（**无需权限**） |
 * | 读图 | `BitmapFactory` + `inSampleSize` | `image.createImageSource` + `sampleSize` |
 * | 存图 | `bitmap.compress(JPEG, 92)` | `imagePacker.packToFile(..., {quality: 92})` |
 * | 显示 | `Image(bitmap).contentScale=Crop` | `Image(pixelMap).objectFit(ImageFit.Cover)` |
 *
 * ⚠️ **交互式裁切（双指缩放/拖动）暂未实现**：本版直接按「铺满屏幕」显示
 * （`ImageFit.Cover`），效果等价于 Android 裁切界面的初始状态。
 * 裁切规格见 `docs/壁纸与主题移植规格.md` 第二节。
 *
 * ⚠️ `packToFile` 的目标 fd **必须带 `TRUNC`** —— 否则会残留旧文件的字节。
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'GltuSchedule';
const FILE_NAME: string = 'schedule_background.jpg';
/** 显示用的最大宽度（与 Android `loadScaled(maxWidth = 1440)` 一致） */
const MAX_WIDTH: number = 1440;
/** 保存前的最大长边（与 Android `decodeForEdit(maxSide = 2400)` 一致） */
const MAX_SIDE: number = 2400;

/** 解码出来的待裁切原图 */
export class DecodedImage {
  pixelMap: image.PixelMap | undefined = undefined;
  /** 原图像素宽 */
  width: number = 0;
  /** 原图像素高 */
  height: number = 0;

  get ok(): boolean {
    return this.pixelMap !== undefined && this.width > 0 && this.height > 0;
  }
}

export class BackgroundImageStore {

  /** 壁纸文件绝对路径 */
  static pathOf(context: common.Context): string {
    return `${context.filesDir}/${FILE_NAME}`;
  }

  /** 是否已设置壁纸 */
  static exists(context: common.Context): boolean {
    try {
      const p = BackgroundImageStore.pathOf(context);
      if (!fs.accessSync(p)) {
        return false;
      }
      return fs.statSync(p).size > 0;
    } catch (e) {
      return false;
    }
  }

  /** 删除壁纸 */
  static clear(context: common.Context): void {
    try {
      const p = BackgroundImageStore.pathOf(context);
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '删除壁纸失败: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 只弹选择器，返回图片 URI（空串 = 用户取消）。
   * 与 `pickAndSave` 的区别：把「选」和「存」拆开，中间可以插裁切界面。
   */
  static async pick(): Promise<string> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const opt = new photoAccessHelper.PhotoSelectOptions();
      opt.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      opt.maxSelectNumber = 1;
      const res = await picker.select(opt);
      const uris = res.photoUris;
      if (uris === undefined || uris.length === 0) {
        return '';
      }
      return uris[0];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '选图失败: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  /**
   * 把 URI 解码成待裁切的原图（长边压到 `MAX_SIDE` 以内）。
   * 采样是 2 的幂，与 Android 的 `while (longest / sample > maxSide) sample *= 2` 一致。
   */
  static async decodeForEdit(uri: string): Promise<DecodedImage> {
    const out = new DecodedImage();
    let file: fs.File | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(file.fd);
      const info = await imageSource.getImageInfo();
      let sample = 1;
      const longest = Math.max(info.size.width, info.size.height);
      while (longest / sample > MAX_SIDE) {
        sample *= 2;
      }
      const pm = await imageSource.createPixelMap({
        sampleSize: sample,
        editable: true, // 裁切要改它，必须 editable
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const gi = await pm.getImageInfo();
      out.pixelMap = pm;
      out.width = gi.size.width;
      out.height = gi.size.height;
      return out;
    } catch (e) {
      hilog.error(DOMAIN, TAG, '解码图片失败: %{public}s', JSON.stringify(e));
      return out;
    } finally {
      if (imageSource !== undefined) {
        try {
          imageSource.release();
        } catch (e) {
        }
      }
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
  }

  /** 把一个 PixelMap 压缩存为壁纸（JPEG quality 92，与 Android 一致） */
  static async savePixelMap(context: common.Context, pm: image.PixelMap): Promise<boolean> {
    let dst: fs.File | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    try {
      const path = BackgroundImageStore.pathOf(context);
      // ⚠️ TRUNC 不能省，否则覆盖写会残留旧字节
      dst = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      packer = image.createImagePacker();
      await packer.packToFile(pm, dst.fd, { format: 'image/jpeg', quality: 92 });
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, '保存壁纸失败: %{public}s', JSON.stringify(e));
      BackgroundImageStore.clear(context);
      return false;
    } finally {
      if (packer !== undefined) {
        try {
          packer.release();
        } catch (e) {
        }
      }
      if (dst !== undefined) {
        try {
          fs.closeSync(dst);
        } catch (e) {
        }
      }
    }
  }

  /**
   * 弹出系统图片选择器并保存为壁纸（**不做裁切**，直接铺满）。
   * 保留这个快捷路径，裁切界面走 `pick` → `decodeForEdit` → `savePixelMap`。
   */
  static async pickAndSave(context: common.Context): Promise<boolean> {
    let uri: string = '';
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const opt = new photoAccessHelper.PhotoSelectOptions();
      opt.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      opt.maxSelectNumber = 1;
      const res = await picker.select(opt);
      const uris = res.photoUris;
      if (uris === undefined || uris.length === 0) {
        return false; // 用户取消
      }
      uri = uris[0];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '选图失败: %{public}s', JSON.stringify(e));
      return false;
    }
    return await BackgroundImageStore.saveFromUri(context, uri);
  }

  /** 把图片 URI 读成 PixelMap 并压缩存到应用沙箱 */
  private static async saveFromUri(context: common.Context, uri: string): Promise<boolean> {
    let src: fs.File | undefined = undefined;
    let dst: fs.File | undefined = undefined;
    try {
      src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const imageSource = image.createImageSource(src.fd);
      const info = await imageSource.getImageInfo();

      // 采样：长边压到 MAX_SIDE 以内（与 Android 的 while 循环等价，2 的幂）
      let sample = 1;
      const longest = Math.max(info.size.width, info.size.height);
      while (longest / sample > MAX_SIDE) {
        sample *= 2;
      }

      const pm = await imageSource.createPixelMap({
        sampleSize: sample,
        editable: false,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });

      const path = BackgroundImageStore.pathOf(context);
      // ⚠️ TRUNC 不能省，否则覆盖写会残留旧字节
      dst = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      const packer = image.createImagePacker();
      await packer.packToFile(pm, dst.fd, { format: 'image/jpeg', quality: 92 });

      pm.release();
      imageSource.release();
      packer.release();
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, '保存壁纸失败: %{public}s', JSON.stringify(e));
      // 失败时清掉半截文件，避免下次读到一个坏图
      BackgroundImageStore.clear(context);
      return false;
    } finally {
      if (src !== undefined) {
        try {
          fs.closeSync(src);
        } catch (e) {
        }
      }
      if (dst !== undefined) {
        try {
          fs.closeSync(dst);
        } catch (e) {
        }
      }
    }
  }

  /**
   * 读出壁纸 PixelMap 供界面显示；没有或读失败返回 undefined。
   *
   * 采样只看**宽度**（与 Android `loadScaled` 一致）：
   * `while (width / sample > MAX_WIDTH * 2) sample *= 2`
   */
  static async load(context: common.Context): Promise<image.PixelMap | undefined> {
    if (!BackgroundImageStore.exists(context)) {
      return undefined;
    }
    let file: fs.File | undefined = undefined;
    let imageSource: image.ImageSource | undefined = undefined;
    try {
      file = fs.openSync(BackgroundImageStore.pathOf(context), fs.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(file.fd);
      const info = await imageSource.getImageInfo();
      let sample = 1;
      while (info.size.width / sample > MAX_WIDTH * 2) {
        sample *= 2;
      }
      const pm = await imageSource.createPixelMap({
        sampleSize: sample,
        editable: false,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      return pm;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '读取壁纸失败: %{public}s', JSON.stringify(e));
      return undefined;
    } finally {
      if (imageSource !== undefined) {
        try {
          imageSource.release();
        } catch (e) {
        }
      }
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
  }
}
