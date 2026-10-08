# GltuSchedule · HarmonyOS

> **为桂林旅游学院（GLTU）同学做的课程表 App —— 纯血鸿蒙（HarmonyOS NEXT）版**
> 版本 **0.14.0** · 作者 **木下葵**

这是 Android 版 [GltuSchedule-Android](https://github.com/LTYksa/GltuSchedule-Android) 的**鸿蒙原生重写**。
纯血鸿蒙不再兼容 Android，APK 装不上，所以整个 App 用 **ArkTS + ArkUI** 重写了一遍。

> ⚠️ **当前进度：可编译运行的骨架 + 核心逻辑已完整移植，UI 完成课表主界面。**
> 详细的功能对照与待办清单见 **[docs/移植方案.md](docs/移植方案.md)**。

---

## ✅ 当前状态

**已在本机真实编译通过**：

```
hvigor  BUILD SUCCESSFUL
  :entry:default@CompileArkTS ... 6 s 52 ms
产物：entry/build/default/outputs/default/entry-default-unsigned.hap （686 KB）
```

> **本版是逐行读完 Android 源码后的忠实移植**：导航结构、界面层级、全部文案、
> 尺寸常量（dp→vp 数值相同）、正则表达式、业务逻辑均按原版 1:1 复刻。

| 模块 | 状态 | 说明 |
|---|---|---|
| 工程骨架 / 构建配置 | ✅ 完成 | 可在 DevEco Studio 直接打开 |
| **导航结构** | ✅ 完成 | 底部常驻 Tab（课表/设置）+ 二级页置顶返回栏，与 Android `AppNavigation.kt` 一致 |
| 作息时间表（13 小节） | ✅ 完成 | 与教务系统逐条对齐 |
| 教室楼号识别 | ✅ 完成 | 房号 → 旅勤/旅思/旅博/旅齐楼；`shortLabel`/`detailLabel` 同原版 |
| 课程配色（16 色） | ✅ 完成 | 同名同色；复刻 Java `String.hashCode` + 双取模 |
| 日期工具 | ✅ 完成 | 用「天数序号」纯整数运算，**无时区坑** |
| 节假日屏蔽（三开关） | ✅ 完成 | 判定顺序与补班日例外同原版 |
| 周次解析 | ✅ 完成 | `4-5周,8周,11-13周(单),14-16周` → `[4,5,8,11,13,14,15,16]` |
| **教务课表解析器** | ✅ 完成 | **1076 行**，4 种策略 + 失败诊断；**已修 rowspan 展开** |
| HTML 表格提取 | ✅ 完成 | **855 行**，鸿蒙无 Jsoup 故自写；支持 rowspan/colspan/`<br>`/实体 |
| 本地存储 | ✅ 完成 | relationalStore + preferences |
| **课表主界面** | ✅ 完成 | 1637 行；☰侧边栏 / 周次选择 / 详情弹窗 / 删除确认 / 日视图 |
| **课表设置侧边栏** | ✅ 完成 | 62% 宽左侧栏，8 个条目 + 7 个子对话框 |
| **设置页** | ✅ 完成 | 754 行，10 个区块**文案逐字照抄** |
| **添加/编辑课程页** | ✅ 完成 | 474 行；含 `mergeCourseForm` 全部业务逻辑 |
| **课表分享码** | ✅ 完成 | **导出与 Android 逐字节一致（34 项对拍实测）** |
| **教务系统导入页** | ✅ 完成 | 说明页 + 7 个入口 + 内嵌浏览器 + 二次确认 + 成功设周次 |
| **教务系统内嵌导入** | ✅ 完成 | ArkWeb `Web` 组件 + 抓 `outerHTML`（含同源 iframe）→ 解析 → 覆盖式落库 |
| **桌面服务卡片** | ✅ 完成 | `FormExtensionAbility` + 三个规格（2×2 / 2×4 / 4×4） |
| **上课提醒** | ✅ 完成 | `reminderAgentManager` 系统级代理提醒 + 通知槽位 |
| **同步到系统日历** | ✅ 完成 | `@kit.CalendarKit`，调休感知、含清理与 RRULE 策略 |
| **自定义壁纸 / 裁切** | ✅ 完成 | PhotoViewPicker + PixelMap + 双指缩放/拖动裁切 + 渐变蒙层 |
| **深色模式** | ✅ 完成 | 运行时可切色表，跟随系统 / 浅色 / 深色三档 |
| **单元测试** | ✅ 70 个 | `@ohos/hypium`，`hvigorw test` 可跑 |

**统计**：35 个 ArkTS 文件 / 10593 行 + 6 个测试文件 / 70 个用例

> ⚠️ **ArkTS 只编译「入口可达」的模块**。解析器写完时没被任何页面 import，
> 结果是 `BUILD SUCCESSFUL` 但 `importer/*` **根本没进包**（HAP 686 KB）。
> 接上导入页后才真正编进去（HAP → 944 KB，`modules.abc` 411 → 566 KB）。
> 验证方法：在 HAP 字节码里搜策略串（`列表视图` / `表格视图（按表头星期）` / `div 网格`）。

---

## 🎨 UI 设计：逐项对齐 Android

信息架构与 Android 版**完全一致**，尺寸常量按 dp→vp 数值照搬（40/54/70/26/62%…）。

| 位置 | Android 版 | 鸿蒙版 | 是否一致 |
|---|---|---|---|
| **底部导航** | 常驻 Tab：课表 / 设置 | 常驻 Tab：课表 / 设置 | ✅ 一致 |
| **二级页** | 置顶返回栏 + 隐藏底部导航 | 同左 | ✅ 一致 |
| 左上角 | ☰ 打开课表设置 | ☰ 打开课表设置 | ✅ 一致 |
| 周次 | ‹ 第 N 周 ▾ ›，点周次开选择框 | ‹ 第 N 周 ▾ ›，点周次开选择框 | ✅ 一致 |
| 学期灰字 | 紧跟「第 N 周」下方（左缩进 58dp） | 同左 | ✅ 一致 |
| 视图切换 | 周/日 紧凑分段 | 同左 | ✅ 一致 |
| 右上角 | ＋ 添加课程 | ＋ 添加课程 | ✅ 一致 |
| 日期行 | 高 70、方块 26dp/圆角 7；被屏蔽红底、今天实心、假期名下标 | 同左 | ✅ 一致 |
| 节次轴 | 节次号 + `上课\n下课`（8sp / 行高 9.5） | 同左 | ✅ 一致 |
| 网格线 | 每行顶部 0.5dp 横线（从节次轴右侧起）+ 竖线 | 同左 | ✅ 一致 |
| 课程块 | 左色条 3dp + 圆角 6 + 边框 0.8dp；非本周统一灰 `#9E9E9E` | 同左 | ✅ 一致 |
| 周次选择 | 弹窗列出 1–24 周 + 日期区间 | 同左 | ✅ 一致 |
| 课程详情 | 教师/地点/时间/周次/学分 + 编辑/删除/关闭 | 同左 | ✅ 一致 |
| 删除确认 | 二次确认「确定删除「X」吗？」 | 同左 | ✅ 一致 |
| 课表设置 | 左侧栏，占屏宽 **62%** | 左侧栏，占屏宽 **62%** | ✅ 一致 |
| **抽屉/弹窗实现** | ModalNavigationDrawer / AlertDialog | **Stack 覆盖层自实现** | 🔷 鸿蒙化 |

| 课程块 | 左侧色条 + 浅色底 + 细边框，跨节次 | 同左 | ✅ 一致 |
| 非本周课程 | 灰显 + 去重（可开关） | 灰显 + 去重（可开关） | ✅ 一致 |
**鸿蒙化的两处**（只在实现手段上，外观/文案不变）：

1. **抽屉与弹窗用 `Stack` 覆盖层自实现** —— 圆角上沿 + 遮罩 + 点遮罩关闭，观感与 Material 的抽屉/对话框一致，但行为完全可控
2. **`expandSafeArea` 处理全面屏安全区** —— 顶部内容不被状态栏遮挡

> 主题色沿用 Android 版的静态回退色 `#4E6E9E`（Material You 动态取色在鸿蒙无对应能力）。

### 踩坑 1：不要用 `bindSheet`

第一版用 ArkUI 的 `bindSheet($$this.showXxx, ...)` 做底部半模态，**编译能过但运行时点了没反应**（`$$` 双向绑定在本机 SDK 26 上静默失效）。
现已全部改为 **`Stack` 覆盖层自己实现**。

### 踩坑 2：`tabIndex` / `overlay` 是 ArkUI 保留属性名

```
Property 'tabIndex' in type 'Index' is not assignable to the same property in base type 'CustomComponent'.
Property 'overlay'  in type 'Index' is not assignable to the same property in base type 'CustomComponent'.
```

`tabIndex`（焦点导航）、`overlay`（`.overlay()` 属性方法）都是 ArkUI `CustomComponent` 基类已有的成员名。
**给 `@State` 起名时要避开**：已改名为 `navIndex` / `panel`。

---

## 📱 安装

### 普通用户

> 🏪 **安装包将通过华为应用市场（AppGallery）发布**，届时直接搜索「GLTU 课表」安装即可。

**本仓库不提供可直接下载的安装包**，原因如下（这不是偷懒，是鸿蒙的机制）：

| 包类型 | 签名 | 能否侧载安装 |
|---|---|---|
| 调试签名 | debug 证书 + **绑定设备 UDID** | 只能装到证书里登记过的那一台设备 |
| 发布签名 | release 证书 | **不能侧载**，只能通过应用市场安装 |

也就是说：
- 调试包传上来，除开发者本人外**谁都装不上**
- 发布包传上来，下载了也**装不上**（系统只认应用市场的分发渠道）

所以正确做法就是走应用市场。

### 开发者 / 想自己编译

见下方 [🔨 构建](#-构建)，编译出 HAP 后用 DevEco 的签名配置签一下，
再 `hdc install xxx.hap` 装到自己的设备上。

---

## 🔨 构建

### 用 DevEco Studio（推荐）

1. 打开 DevEco Studio → `File → Open` → 选**本目录**
2. 首次打开会提示 Sync，等它跑完
3. `Build → Build Hap(s)/APP(s) → Build Hap(s)`
4. 产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

> 装到真机需要在 DevEco 里配置签名（`File → Project Structure → Signing Configs → Automatically generate signature`，需登录华为账号）。

### 用命令行

```powershell
# 三个环境变量指向 DevEco 自带工具链
$env:DEVECO_SDK_HOME = 'D:\DevEco Studio\sdk'
$env:NODE_HOME       = 'D:\DevEco Studio\tools\node'
$env:JAVA_HOME       = 'D:\DevEco Studio\jbr'      # hvigor 打包需要 java

$env:PATH = "$env:JAVA_HOME\bin;$env:NODE_HOME;$env:PATH"
Set-Location <本目录>
& 'D:\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap --no-daemon
```

或直接用仓库里的 `build.ps1`：

```powershell
.\build.ps1
```

---

## 🧱 技术栈对照

| 能力 | Android 版 | 鸿蒙版 |
|---|---|---|
| 语言 | Kotlin 2.0.21 | **ArkTS** |
| UI | Jetpack Compose + Material 3 | **ArkUI（声明式）+ @Component/@Builder** |
| 架构 | MVVM + Repository | 同样的分层，State 驱动 |
| 数据库 | Room（SQLite） | **relationalStore（内置 SQLite）** |
| 键值存储 | SharedPreferences | **preferences** |
| HTML 解析 | Jsoup | **自写 HTML 表格提取器** |
| 网络 | OkHttp | `@kit.NetworkKit` 的 http |
| 组件 | Activity / BroadcastReceiver | **UIAbility / ExtensionAbility** |
| 构建 | Gradle + AGP | **hvigor** |
| 产物 | APK | **HAP** |

### 版本要求

| 项 | 值 |
|---|---|
| 开发工具 | DevEco Studio **26.0.0.851** 及以上 |
| SDK | HarmonyOS **26.0.0（API 26）** |
| `compatibleSdkVersion` | **`"26.0.0"`**（字符串，**不带括号**！见下） |
| 包名（bundleName） | `com.ltyksa.gltuschedule` |

> **踩坑记录**：`build-profile.json5` 里的版本号格式随 API 版本变化——
> API 10~25 用 `"5.0.0(12)"` 这种带括号的写法；
> **API 26 起改成 `"26.0.0"`**，填 `"26"` 或 `"26.0.0(26)"` 都会报
> `Specification Limit Violation`。

---

## 📂 项目结构

```
GltuSchedule-HarmonyOS/
├── AppScope/
│   ├── app.json5                    应用级配置（bundleName / 版本 / 图标）
│   └── resources/base/              应用级资源
├── entry/                           主模块
│   ├── src/main/
│   │   ├── module.json5             模块配置（Ability / 权限）
│   │   ├── ets/
│   │   │   ├── common/AppInfo.ets            应用信息
│   │   │   ├── data/TimeSlot.ets             13 小节作息表
│   │   │   ├── data/Classroom.ets            房号 → 教学楼/楼层
│   │   │   ├── data/CourseColor.ets          16 色配色
│   │   │   ├── data/DateUtil.ets             日期工具（无时区坑）
│   │   │   ├── data/Holiday.ets              节假日 + 三开关屏蔽
│   │   │   ├── model/Course.ets              课程模型 + 周次换算
│   │   │   ├── importer/WeekParser.ets       周次文本解析
│   │   │   ├── importer/HtmlTable.ets        HTML 表格提取（替代 Jsoup）
│   │   │   ├── importer/TimetableParser.ets  课表解析（双策略）
│   │   │   ├── database/CourseStore.ets      relationalStore + preferences
│   │   │   ├── entryability/EntryAbility.ets 入口（启动时初始化数据库）
│   │   │   ├── entrybackupability/           备份扩展
│   │   │   └── pages/Index.ets               主页面
│   │   └── resources/               资源（字符串/颜色/图标/页面表）
│   ├── build-profile.json5          模块构建配置
│   ├── hvigorfile.ts                模块构建脚本
│   └── oh-package.json5             模块依赖
├── build-profile.json5              工程构建配置（SDK 版本在这里）
├── hvigorfile.ts                    工程构建脚本
├── oh-package.json5                 工程依赖
├── hvigor/hvigor-config.json5       hvigor 配置
├── build.ps1                        一键构建脚本
└── docs/移植方案.md                  功能对照 + 待办清单
```

---

## ⚠️ 免责声明

- **第三方非官方客户端**，与桂林旅游学院及教务系统厂商无任何关系。
- 全程本地运行：无服务器、无账号、无埋点；数据只存在你的设备上。
- 节假日/校历信息来自公开渠道，**请以学校正式通知为准**。

## 📄 开源协议

MIT License © 2026 木下葵
