# GLTU 课表 HTML 解析器 `WebTimetableParser.kt` —— 全量技术报告（供鸿蒙 ArkTS 移植）

- 源文件：`D:\dshcj\gltu-schedule\app-android\app\src\main\java\com\ltyksa\gltuschedule\import\WebTimetableParser.kt`
- 规模：633 行 / 28,735 字节（最后修改 2026-10-07 15:46）
- 语言/依赖：Kotlin `object`，依赖 `org.jsoup`（Jsoup）、`java.time.DayOfWeek`、`com.ltyksa.gltuschedule.model.Course`、`com.ltyksa.gltuschedule.data.CoursePalette`
- 报告约定：所有 `kotlin` 代码块都是**原文照抄**（含注释），括号内为原文件行号。

---

## 1. 整体结构

### 1.1 对外 API（全部 public）

| 签名 | 职责 |
|---|---|
| `data class Outcome(val courses: List<Course>, val strategy: String, val note: String = "")` (25-29) | 解析结果。`courses` 为空即失败；`strategy` 是**给用户看的中文策略名**；`note` 只在失败时有内容 |
| `fun parse(html: String): Outcome` (63) | 主入口：4 种策略顺序尝试 |
| `fun guessSemester(html: String): String?` (464) | 从整页文本猜学期名，如 `"2026-2027 第1学期"`；识别不出返回 `null` |
| `fun guessCurrentWeek(html: String): Int?` (492) | 从整页文本猜"当前第几周"，1..30，否则 `null` |

调用方：`ui/import/WebImportScreen.kt`（395/406/409）——先 `parse` 成功则 `clearCourses()` + `upsertCourses()`；
`importedStrategy`、`importedSemester`、`guessCurrentWeek(html) ?: SemesterStore.currentWeek(app)` 都直接展示在"导入成功"对话框里，
**因此 `strategy` 字符串是对用户可见的文案，移植时要原样保留**。

### 1.2 私有常量与正则（31-58）

```kotlin
private const val NL = "\u0001"   // 行分隔哨兵（Jsoup.text() 不会吃掉它）
```
| 名称 | 行 | 说明 |
|---|---|---|
| `NL` | 32 | U+0001 哨兵，用于在"HTML→文本"过程中保住换行结构（Jsoup 的 `text()` 会把 `\n` 折叠成空格，但不会动 U+0001，因为 `Character.isWhitespace('\u0001') == false`） |
| `SEC_RANGE` / `SEC_SINGLE` / `SEC_BARE_RANGE` / `SEC_BARE_SINGLE` / `SEC_BRACKET` | 34-39 | 节次识别 |
| `WEEKS_FRAGMENT` | 41 | 周次片段（用于从启发式文本里"剥掉"周次） |
| `DAY_CHAR` | 43-47 | `一→MONDAY … 日/天→SUNDAY`，**顺序敏感**（见 §13-B12） |
| `LABEL_NAMES` | 50-54 | 21 个卡片字段标签 |
| `LABEL_REGEX` | 55 | 标签 + 冒号（**必须带冒号**） |
| `BLOCK_END` | 58 | `学分：x`，用于把"压成一行"的多卡切成块 |

```kotlin
/** 课程卡片里的字段标签（带冒号才算，避免把"教师口语"这类课程名误判成标签）。 */
private val LABEL_NAMES = listOf(
    "周数", "校区", "上课地点", "上课时间", "上课教室", "教师", "任课教师",
    "教学班组成", "教学班", "考核方式", "考试方式", "选课备注", "课程学时组成",
    "周学时", "总学时", "学分", "课程性质", "开课学院", "选课人数", "容量", "备注",
)
private val LABEL_REGEX = Regex("(" + LABEL_NAMES.joinToString("|") + """)\s*[：:]""")
```

> 交替顺序即上表顺序。**只有在"某个标签是另一个标签的前缀"时才影响结果**，当前表里需要保证的顺序对：
> `上课地点` 在 `上课时间`/`上课教室` 之前（互不为前缀，安全）；`教学班组成` 在 `教学班` 之前（**必要**：否则 `教学班组成：` 会被拆成 `教学班` + 值 `组成：…`）；`选课备注` 在 `备注` 之前（**必要**）。移植时不要重排这个数组。

### 1.3 私有函数总览（21 个）

| 行 | 签名 | 职责 |
|---|---|---|
| 108 | `tryListLayout(grid: List<List<Element?>>): Outcome` | 策略①：`星期 / 节次 / 课表信息` 列表视图 |
| 151 | `extractCoursesFromInfoCell(cell: Element, day: DayOfWeek, secStart: Int, secEnd: Int): List<Course>` | 信息格 → 多张卡片 |
| 174 | `splitByBlockEnd(text: String): List<String>` | 按 `学分：x` 切块（兜底） |
| 194 | `parseCourseBlock(block: String, day: DayOfWeek, secStart: Int, secEnd: Int): Course?` | 单张标签式卡片 → `Course` |
| 270 | `parseWeekSet(raw: String): List<Int>` | 周次文本 → 升序去重周次集合 |
| 295 | `cleanLocation(v: String): String` | 地点清洗（≤30 字） |
| 299 | `cleanTeacher(v: String): String` | 教师去职称括号（≤20 字） |
| 305 | `tryGridLayout(grid: List<List<Element?>>, useHeaderDays: Boolean): Outcome` | 策略②③：节次行 × 星期列 |
| 342 | `buildDefaultDayCols(cellCount: Int): Map<Int, DayOfWeek>` | 无表头时假定第 1..7 列 = 周一..周日 |
| 349 | `extractEntriesFromGridCell(cell: Element): List<String>` | 表格格 → 若干"课程条目文本" |
| 378 | `parseGridEntry(raw: String, day, secStart, secEnd): Course?` | 条目文本 → 先标签解析，退化到启发式 |
| 389 | `parseHeuristic(raw: String, day, secStart, secEnd): Course?` | 通用启发式（纯文本行） |
| 503 | `tryDivGrid(doc: Document): Outcome` | 策略④：无表格时扫 `div, li, p` |
| 520 | `directTables(doc: Document): List<Element>` | 只取顶层 `table` |
| 524 | `directRows(table: Element): List<Element>` | 只取直接 `tr`（含 tbody/thead/tfoot 内的直接 tr） |
| 535 | `directCells(row: Element): List<Element>` | `td` / `th` |
| 542 | `expandTable(table: Element): List<List<Element?>>` | 展开 rowspan/colspan 为矩形网格 |
| 570 | `cellLines(cell: Element): List<String>` | 保留行结构的单元格文本行 |
| 580 | `dayOf(text: String): DayOfWeek?` | 严格星期（必须含 星期/周/礼拜） |
| 589 | `dayOfLoose(text: String): DayOfWeek?` | 宽松星期（已知是星期列，允许只写"一"） |
| 600 | `parseSectionLoose(text: String): Pair<Int, Int>?` | 节次（起, 止） |
| 624 | `dedupe(list: List<Course>): List<Course>` | 按复合 key 去重，保留首见顺序 |

---

## 2. `parse()` 主入口的完整流程

原文（63-103）：

```kotlin
fun parse(html: String): Outcome {
    if (html.isBlank()) return Outcome(emptyList(), "无", "抓到的网页内容为空")

    val doc = Jsoup.parse(html)
    val tables = directTables(doc)

    // ① 列表视图（星期 / 节次 / 课表信息）—— GLTU 实际页面
    for (t in tables) {
        val grid = expandTable(t)
        val r = tryListLayout(grid)
        if (r.courses.isNotEmpty()) return r
    }

    // ② 表格视图（表头含 星期一…星期日）
    for (t in tables) {
        val grid = expandTable(t)
        val r = tryGridLayout(grid, useHeaderDays = true)
        if (r.courses.isNotEmpty()) return r
    }

    // ③ 表格视图（无表头，默认第 1..7 列 = 周一..周日）
    for (t in tables) {
        val grid = expandTable(t)
        val r = tryGridLayout(grid, useHeaderDays = false)
        if (r.courses.isNotEmpty()) return r
    }

    // ④ 无表格：从 div 网格里抓
    val divs = tryDivGrid(doc)
    if (divs.courses.isNotEmpty()) return divs

    return Outcome(
        emptyList(), "失败",
        "没有识别到课表。当前页面表格数：${tables.size}。\n" +
            "请确认：\n" +
            "① 已登录成功；\n" +
            "② 停留在『个人课表查询 / 学生课表查询 / 我的课表』页面；\n" +
            "③ 页面上能看到『星期 / 节次 / 课表信息』或完整课表格子。\n" +
            "确认后再点『确定导入』。"
    )
}
```

**逐条判定与返回值**

1. `html.isBlank()` → `Outcome(emptyList(), "无", "抓到的网页内容为空")`。注意 `isBlank()` 是 Kotlin 语义（含 `\u00a0` 等 Unicode 空白）。
2. 用 `Jsoup.parse(html)` 造文档；`directTables(doc)` 取**顶层表格**（`t.parents().none { it.tagName() == "table" }`，520-521），保持文档顺序。
3. 策略① 对**每一个**表格试 `tryListLayout`，只要有课程就**立即 return**（返回的是该表的 Outcome，`strategy = "列表视图（星期 / 节次 / 课表信息）"`）。
4. 策略② 同法试 `tryGridLayout(grid, useHeaderDays = true)`；成功时 `strategy = "表格视图（按表头星期）"`。
5. 策略③ 同法试 `tryGridLayout(grid, useHeaderDays = false)`；成功时 `strategy = "表格视图（默认列序）"`（`secCol` 固定为 0）。
6. 策略④ `tryDivGrid(doc)`（**只用 `doc`，不再用表格**），成功时 `strategy = "div 网格（实验性）"`。
7. 全失败 → `Outcome(emptyList(), "失败", <上面那段多行诊断>)`。

**关键点**

- 判定条件永远是 `r.courses.isNotEmpty()`，**不看 `note`**。
- `tryListLayout` / `tryGridLayout` 在"没识别到表头/布局"时返回的 `Outcome(emptyList(), "列表视图")` / `"表格视图"` 会被丢弃——**这两个 strategy 字符串永远不会出现在最终结果里**（只有 4 个成功串 + `"无"` + `"失败"` 会出现）。
- 部分成功也算成功：策略① 只要在**任意一张表**里解析出 ≥1 门课就返回，不会再去试其它表/其它策略，也不做"哪个策略结果更多"的比较。
- `expandTable(t)` 在每个策略里被重复计算（同一张表最多算 3 次），纯性能问题。
- 成功时 `note` 恒为 `""`（默认参数）。

---

## 3. 基础设施层（表格 → 网格 → 文本）

### 3.1 `directTables` (520-521)
```kotlin
private fun directTables(doc: Document): List<Element> =
    doc.select("table").filter { t -> t.parents().none { it.tagName() == "table" } }
```
排除嵌套在别的表格里的表（课程卡片内部常有小表）。

### 3.2 `directRows` (524-533)
```kotlin
private fun directRows(table: Element): List<Element> {
    val rows = ArrayList<Element>()
    for (child in table.children()) {
        when (child.tagName()) {
            "tr" -> rows.add(child)
            "tbody", "thead", "tfoot" -> rows.addAll(child.children().filter { it.tagName() == "tr" })
        }
    }
    return rows
}
```
**只认直接子 `tr`**，或直接子 `tbody/thead/tfoot` 的**直接子 `tr`**；嵌套表格的行不会被误取。
（Jsoup 会按 HTML5 规则自动补 `<tbody>`，所以这段是必需的。）

### 3.3 `directCells` (535-536)
```kotlin
private fun directCells(row: Element): List<Element> =
    row.children().filter { it.tagName() == "td" || it.tagName() == "th" }
```

### 3.4 `expandTable`（重点，542-567）原文
```kotlin
private fun expandTable(table: Element): List<List<Element?>> {
    val rows = directRows(table)
    if (rows.isEmpty()) return emptyList()
    val grid = ArrayList<MutableList<Element?>>()
    for (rIdx in rows.indices) {
        while (grid.size <= rIdx) grid.add(ArrayList())
        var cIdx = 0
        for (cell in directCells(rows[rIdx])) {
            // 跳过已被上方 rowspan 占用的位置
            while (cIdx < grid[rIdx].size && grid[rIdx][cIdx] != null) cIdx++
            val rowspan = cell.attr("rowspan").toIntOrNull()?.coerceIn(1, 200) ?: 1
            val colspan = cell.attr("colspan").toIntOrNull()?.coerceIn(1, 20) ?: 1
            for (dr in 0 until rowspan) {
                val rr = rIdx + dr
                while (grid.size <= rr) grid.add(ArrayList())
                for (dc in 0 until colspan) {
                    val cc = cIdx + dc
                    while (grid[rr].size <= cc) grid[rr].add(null)
                    grid[rr][cc] = cell
                }
            }
            cIdx += colspan
        }
    }
    return grid.map { it.toList() }
}
```
要点（移植必须一比一复刻）：

1. 网格是**矩形展开**；`rowspan` 覆盖到的下方格子**放的是同一个 `Element` 引用**，不是 `null`。
   → 所以"星期一"/"1-2"（`rowspan="2"`）在被覆盖的每一行都能读到同样的 `text()`。**这是列表视图能工作、并且同一时段两张卡片都能被解析的前提。**
2. `rowspan` 钳制 `1..200`，`colspan` 钳制 `1..20`；属性缺失或非数字 → 1。
3. 每次放格之前先 `while (cIdx < row.size && row[cIdx] != null) cIdx++`：跳过被上方 rowspan 占用的列。
4. **行长度可能参差不齐**（某行单元格少 → 该行 `List` 短）。因此任何 `row[i]` 访问都必须自己判边界，见 §13-B9。
5. 同一 `Element` 可能出现在多个格子里 → 引用相等；列表视图里若某格 `colspan` 跨越"信息列"，同一格会被解析两次（靠 `dedupe` 兜住）。

### 3.5 `cellLines`（保留换行的单元格文本，570-577）原文
```kotlin
private fun cellLines(cell: Element): List<String> {
    val html = cell.html()
        .replace(Regex("""<br\s*/?>""", RegexOption.IGNORE_CASE), NL)
        .replace(Regex("""</(div|p|li|tr|h[1-6]|table)>""", RegexOption.IGNORE_CASE), NL)
        .replace(Regex("""<(div|p|li|tr|h[1-6]|table)[^>]*>""", RegexOption.IGNORE_CASE), NL)
    val text = Jsoup.parse(html).text()
    return text.split(NL).map { it.trim() }.filter { it.isNotEmpty() }
}
```
- 取 `cell.html()`（Jsoup 会**重新序列化**：`<br/>` 归一为 `<br>`、属性加引号、实体转义），再把 `<br>` 与块级标签的开/闭标签替换成 U+0001，最后 `Jsoup.parse(...).text()` 并切分。
- 注意顺序：先替换闭标签，再替换开标签；两个正则都带 `IGNORE_CASE`。
- **不处理** `<br class="x">`、`</div >`（闭标签正则不允许标签名后有空格）、`<td>`/`<span>` 边界。
- Jsoup 的 `text()` 会在块级元素处补空格、折叠空白，但**不会**动 U+0001；`&nbsp;` 解码成 `\u00a0`（≠ 普通空格，见 §14）。
- `<script>/<style>` 的内容不会被 `text()` 带进来（DataNode 不算 TextNode）。
- 结果：去空行、每行 `trim()`。**注意 `trim()` 是 Kotlin 语义，会剥掉 `\u00a0`。**

### 3.6 `dayOf`（严格，580-586）原文
```kotlin
private fun dayOf(text: String): DayOfWeek? {
    val t = text.trim().replace(" ", "")
    if (t.isEmpty()) return null
    if (!(t.contains("星期") || t.contains("周") || t.contains("礼拜"))) return null
    for ((c, d) in DAY_CHAR) if (t.contains(c)) return d
    return null
}
```
- 必须先含 `星期` / `周` / `礼拜`；再去掉**半角空格**（不动 `\u00a0`、不动其它空白）。
- `for ((c, d) in DAY_CHAR)` 是**映射插入顺序**（一,二,三,四,五,六,日,天），不是文本顺序 → 合并单元格 `"星期三、星期五"` 得到 WEDNESDAY。`dayOf("周")`、`dayOf("课表信息")` → null（没有日名字）。
- 不识数字写法：`"周1"`、`"星期1"` → null（**ArkTS 现有版本认 1-7，行为不同**）。

### 3.7 `dayOfLoose`（宽松，589-597）原文
```kotlin
private fun dayOfLoose(text: String): DayOfWeek? {
    dayOf(text)?.let { return it }
    val t = text.trim().replace(" ", "").replace("\n", "")
    if (t.isEmpty() || t.length > 4) return null
    var found: DayOfWeek? = null
    var count = 0
    for ((c, d) in DAY_CHAR) if (t.contains(c)) { found = d; count++ }
    return if (count == 1) found else null
}
```
已知该列是星期列时放宽：允许只写 `一 / 周一`。**长度必须 ≤4 且恰好命中 1 个日名字**，否则 null。

### 3.8 `parseSectionLoose`（节次，600-622）原文
```kotlin
private fun parseSectionLoose(text: String): Pair<Int, Int>? {
    val t = text.trim()
    if (t.isEmpty()) return null
    SEC_RANGE.find(t)?.let {
        val a = it.groupValues[1].toIntOrNull() ?: return@let
        val b = it.groupValues[2].toIntOrNull() ?: return@let
        return minOf(a, b) to maxOf(a, b)
    }
    SEC_SINGLE.find(t)?.let {
        val a = it.groupValues[1].toIntOrNull() ?: return@let
        return a to a
    }
    SEC_BARE_RANGE.find(t)?.let {
        val a = it.groupValues[1].toIntOrNull() ?: return@let
        val b = it.groupValues[2].toIntOrNull() ?: return@let
        if (a in 1..20 && b in 1..20) return minOf(a, b) to maxOf(a, b)
    }
    SEC_BARE_SINGLE.find(t)?.let {
        val a = it.groupValues[1].toIntOrNull() ?: return@let
        if (a in 1..20) return a to a
    }
    return null
}
```
优先级：`第X~Y节` → `第X节` → 裸 `X-Y`（**必须都在 1..20**）→ 裸 `X`（1..20）。
- 前两级**没有 1..20 守卫**：`"第99节"` → `(99,99)`。
- 裸范围只要**子串**匹配即可：`"01-02"` → `(1,2)`；`"2026-09-01"` → 首个裸范围是 `"26-09"`，26 不在 1..20 → 该分支不返回，继续落到 `SEC_BARE_SINGLE`（全串 `^(\d{1,2})$` 不匹配）→ `null`（这个守卫是**故意**用来挡日期的）。
- `"1、2节"` → 落到 `SEC_SINGLE` 命中 `"2节"` → `(2,2)`（**错的，应为 1-2**）。

### 3.9 `dedupe`（624-632）原文
```kotlin
private fun dedupe(list: List<Course>): List<Course> {
    val seen = LinkedHashMap<String, Course>()
    for (c in list) {
        val key = "${c.name}|${c.teacher}|${c.location}|${c.dayOfWeek}|" +
            "${c.startIndex}-${c.endIndex}|${c.weeks.joinToString(",")}"
        if (!seen.containsKey(key)) seen[key] = c
    }
    return seen.values.toList()
}
```
key = 课程名|教师|地点|星期|起止节|周次集合（升序 CSV）。**不含 credit、weeksText、category、raw** → 仅学分不同的两张卡会被合并。

---

## 4. 策略①：列表视图 `tryListLayout`（108-148）原文

```kotlin
private fun tryListLayout(grid: List<List<Element?>>): Outcome {
    if (grid.size < 2) return Outcome(emptyList(), "列表视图")

    // 找表头行：同时出现"星期"列与"节次"列
    var headerIdx = -1
    var dayCol = -1
    var secCol = -1
    for ((idx, row) in grid.withIndex()) {
        var d = -1
        var s = -1
        row.forEachIndexed { i, cell ->
            val t = cell?.text()?.trim() ?: return@forEachIndexed
            if (t.isEmpty()) return@forEachIndexed
            val isDayHeader = (t.contains("星期") || t == "周" || t.contains("礼拜")) && dayOf(t) == null
            when {
                isDayHeader && d < 0 -> d = i
                (t.contains("节次")) && s < 0 -> s = i
            }
        }
        if (d >= 0 && s >= 0) { headerIdx = idx; dayCol = d; secCol = s; break }
    }
    if (headerIdx < 0) return Outcome(emptyList(), "列表视图")

    val out = ArrayList<Course>()
    for (idx in (headerIdx + 1) until grid.size) {
        val row = grid[idx]
        if (row.size <= maxOf(dayCol, secCol)) continue
        val day = dayOfLoose(row[dayCol]?.text() ?: "") ?: continue
        val section = parseSectionLoose(row[secCol]?.text() ?: "") ?: continue

        // 其余列都当作课程信息列（通常只有一列）
        for (i in row.indices) {
            if (i == dayCol || i == secCol) continue
            val cell = row[i] ?: continue
            for (course in extractCoursesFromInfoCell(cell, day, section.first, section.second)) {
                out.add(course)
            }
        }
    }
    return Outcome(dedupe(out), "列表视图（星期 / 节次 / 课表信息）")
}
```

### 4.1 表头识别规则（精确）
1. 遍历**每一行**（含被 rowspan 复制出来的行），在行内找两个位置：
   - `isDayHeader`：`cell.text().trim()` 满足 `(含"星期" 或 == "周" 或 含"礼拜") 且 dayOf(t) == null`。也就是"星期"/"周"/"礼拜"这类**泛称**，而不是"星期一"。
   - `s`：`t.contains("节次")`（**只认"节次"两字连写**，不认"节"、"时间"、"节数"）。
2. 同一行**同时**有 `d >= 0` 与 `s >= 0` 才算表头行，取**第一个**满足的行，`break`。
3. 空 cell / null cell 直接跳过；`d`、`s` 各自只取第一次出现（`d < 0` / `s < 0` 守卫）。
4. 找不到表头 → `Outcome(emptyList(), "列表视图")`（被 `parse` 丢弃）。
5. `grid.size < 2` → 同样返回空（**单行表永远不会走列表视图**）。

### 4.2 数据行规则
- 数据行 = 表头行之后的**所有**行。
- 行长度守卫：`row.size <= maxOf(dayCol, secCol) → continue`（**这是列表视图里唯一的越界保护**）。
- 星期：`dayOfLoose(row[dayCol].text())`，取不到 → **整行丢弃**（`continue`）。所以空/`—`/`合计` 行天然被过滤。
- 节次：`parseSectionLoose(row[secCol].text())`，取不到 → 整行丢弃。
- 其余**所有列**（除 dayCol/secCol）都当"课表信息"列，逐格 `extractCoursesFromInfoCell`，结果追加。
  - 由于 `expandTable` 让 `colspan` 覆盖的格子复用同一 `Element`，"信息列"跨列时会被解析多次 → 靠 `dedupe` 去重。
  - 若某行 `colspan` 把"星期/节次"和信息列并成一个 `Element`，该 `Element` 会被当成信息格再解析一次（垃圾卡片可能产生，但 `parseCourseBlock` 的 `weeks/location` 校验多半会拒掉）。

---

## 5. 单张课程卡片解析：`extractCoursesFromInfoCell` → `parseCourseBlock`

### 5.1 切块 `extractCoursesFromInfoCell`（151-172）原文
```kotlin
private fun extractCoursesFromInfoCell(
    cell: Element, day: DayOfWeek, secStart: Int, secEnd: Int,
): List<Course> {
    val lines = cellLines(cell)
    if (lines.isEmpty()) return emptyList()

    // 按"非标签行 = 新卡片开始"切块
    val blocks = ArrayList<StringBuilder>()
    for (line in lines) {
        val isLabelLine = LABEL_REGEX.containsMatchIn(line)
        if (!isLabelLine || blocks.isEmpty()) blocks.add(StringBuilder(line))
        else blocks.last().append('\n').append(line)
    }
    var blockTexts = blocks.map { it.toString() }.filter { it.isNotBlank() }

    // 兜底：整格只有一行但有多个"周数："时，按"学分：x"再切
    if (blockTexts.size == 1 && Regex("""周数\s*[：:]""").findAll(blockTexts[0]).count() > 1) {
        blockTexts = splitByBlockEnd(blockTexts[0])
    }

    return blockTexts.mapNotNull { parseCourseBlock(it, day, secStart, secEnd) }
}
```

**切块算法（精确）**：逐行扫描 `cellLines` 的结果；
- `isLabelLine = LABEL_REGEX.containsMatchIn(line)`（**行内任意位置**含"标签+冒号"即算标签行，不要求行首）。
- 新块的条件：`!isLabelLine || blocks.isEmpty()`。即：**非标签行开新块；标签行并入当前块；第一个块即使是标签行也照开。**
- 块内多行用 `'\n'` 连接（随后在 `parseCourseBlock` 里被压成空格）。

**兜底切分**：仅当"整格只剩 1 块" **且** 该块里 `周数：` 出现 ≥2 次时，才按 `学分：x` 切（`splitByBlockEnd`）。注意判据用的是 `周数`，切分用的是 `学分`——两者不一致。

```kotlin
private fun splitByBlockEnd(text: String): List<String> {
    val out = ArrayList<String>()
    var cursor = 0
    for (m in BLOCK_END.findAll(text)) {
        out.add(text.substring(cursor, m.range.last + 1))
        cursor = m.range.last + 1
    }
    if (cursor < text.length) out.add(text.substring(cursor))
    return out.map { it.trim() }.filter { it.isNotEmpty() }
}
```
`BLOCK_END = Regex("""学分\s*[：:]\s*[\d.]{1,6}""")`：**切点落在"学分数字"之后**（含 `学分：2.0` 本身）；尾部残余总是单独成块；每块 `trim()`、去空。若卡片没有"学分："标签则不产生切点 → 返回单块。

### 5.2 卡片解析 `parseCourseBlock`（194-263）原文
```kotlin
private fun parseCourseBlock(
    block: String, day: DayOfWeek, secStart: Int, secEnd: Int,
): Course? {
    val text = block.replace('\n', ' ').replace(Regex("""\s+"""), " ").trim()
    if (text.isEmpty()) return null

    val matches = LABEL_REGEX.findAll(text).toList()

    // 课程名 = 第一个标签之前的内容（去掉末尾的 * 等标记）
    val rawName = if (matches.isEmpty()) text else text.substring(0, matches.first().range.first)
    val name = rawName.trim().trim('*', '＊', '·', ' ', '\u00a0').trim()
    if (name.isEmpty() || name.length > 60) return null

    fun valueOf(vararg labels: String): String? {
        for (label in labels) {
            val m = matches.firstOrNull { it.groupValues[1] == label } ?: continue
            val start = m.range.last + 1
            val next = matches.firstOrNull { it.range.first > m.range.first }
            val end = next?.range?.first ?: text.length
            val v = text.substring(start, end).trim().trim('；', ';', ',', '，', '|').trim()
            if (v.isNotEmpty()) return v
        }
        return null
    }

    val weeksRaw = valueOf("周数")
    val weeks = weeksRaw?.let { parseWeekSet(it) } ?: emptyList()
    val campus = valueOf("校区")?.let { it.replace(Regex("""\s+"""), "").take(12) }
    val room = valueOf("上课地点", "上课教室")?.let(::cleanLocation).orEmpty()
    // 拼接成"雁山校区 3220（阶7教室）"，与教务系统/超级课程表的展示一致
    val location = when {
        campus.isNullOrBlank() -> room
        room.isBlank() -> campus
        room.contains(campus) -> room
        else -> "$campus $room"
    }
    val teacher = valueOf("教师", "任课教师")?.let(::cleanTeacher).orEmpty()
    val credit = valueOf("学分")?.let { Regex("""\d+(?:\.\d+)?""").find(it)?.value?.toDoubleOrNull() }

    // 既没周次也没地点 → 不像一张课程卡片
    if (weeks.isEmpty() && location.isEmpty()) return null

    val sw = weeks.minOrNull() ?: 1
    val ew = weeks.maxOrNull() ?: 1
    // 若整个周次集合全是奇数/偶数，顺便记录单双周（便于展示）
    val oddEven = when {
        weeks.isEmpty() -> 0
        weeks.all { it % 2 == 1 } -> 1
        weeks.all { it % 2 == 0 } -> 2
        else -> 0
    }

    return Course(
        id = 0,
        name = name,
        teacher = teacher,
        location = location,
        dayOfWeek = day,
        startIndex = secStart,
        endIndex = secEnd,
        startWeek = sw,
        endWeek = ew,
        oddEven = oddEven,
        category = CoursePalette.inferCategory(name, location),
        credit = credit,
        weeksText = weeksRaw.orEmpty(),
        weeks = weeks,
        raw = text,
    )
}
```

**逐字段精确规则**

| 字段 | 规则 |
|---|---|
| `text` | 块内 `'\n'` → 空格；再 `\s+` → 单空格（**Java/Kotlin 的 `\s` 不含 `\u00a0`**）；`trim()`（**含 `\u00a0`**） |
| `matches` | `LABEL_REGEX.findAll(text)`，非重叠、按出现顺序 |
| `rawName` | `matches` 为空 → 整段；否则 = **第一个标签匹配起点之前**的所有内容（是"全文第一个标签"，不限于第一行） |
| `name` | `rawName.trim().trim('*','＊','·',' ','\u00a0').trim()`；**空 或 `length > 60` → 整卡 return null** |
| `valueOf(labels…)` | 按**参数顺序**找第一个"标签名完全相等"的匹配；值 = 该匹配后缀到"下一个匹配起点"（或文本末尾）；`trim()` + 修剪首尾 `；;，,|` + 再 `trim()`；为空则试下一个候选标签 |
| `weeksRaw` | `valueOf("周数")` —— **只认"周数"，不认"周次"** |
| `weeks` | `parseWeekSet(weeksRaw)`，见 §6 |
| `campus` | `valueOf("校区")` → **删除全部 ASCII 空白** → `take(12)` |
| `room` | `valueOf("上课地点","上课教室")` → `cleanLocation` = `\s+`→单空格 + `trim()` + `take(30)` |
| `location` | 见下面 when 分支（`isNullOrBlank` 用 Kotlin 空白语义） |
| `teacher` | `valueOf("教师","任课教师")` → `cleanTeacher` = 去掉 `[（(][^）)]{0,10}[）)]` + `trim()` + `take(20)` |
| `credit` | `valueOf("学分")` → 首个 `\d+(?:\.\d+)?` → `toDoubleOrNull()`（"2." → 2.0；无数字 → null） |
| 有效性 | **`weeks.isEmpty() && location.isEmpty()` → null**（只有教师/学分的卡片被丢弃） |
| `sw/ew` | `weeks.minOrNull() ?: 1` / `maxOrNull() ?: 1`（**周次为空时都是 1**，见 §13-B3） |
| `oddEven` | 空集合→0；**全奇→1；全偶→2**；混合→0（单元素集合也算"全奇/全偶"） |
| `weeksText` | `weeksRaw.orEmpty()`（**原样保留**，如 `4-5周,8周,11-13周(单),14-16周`） |
| `raw` | 上面归一化后的 `text`（调试用；含 `\u00a0`） |
| `category` | `CoursePalette.inferCategory(name, location)`（实现在 `data/CourseCategory.kt`；**第二个参数在函数体内未被使用**，绝大多数课落到 `MAJOR`） |

`location` 拼接（222-229）：
```kotlin
val location = when {
    campus.isNullOrBlank() -> room
    room.isBlank() -> campus
    room.contains(campus) -> room      // 教室文本里已含校区名 → 直接用教室文本
    else -> "$campus $room"            // 例："雁山校区 1226（阶4教室）"
}
```

`cleanLocation` / `cleanTeacher`（295-300）原文：
```kotlin
private fun cleanLocation(v: String): String =
    v.replace(Regex("""\s+"""), " ").trim().take(30)

/** 教师：去掉职称括号，"文娟(讲师)" → "文娟"。 */
private fun cleanTeacher(v: String): String =
    v.replace(Regex("""[（(][^）)]{0,10}[）)]"""), "").trim().take(20)
```
- `cleanTeacher` 删掉**所有**"括号 + 括号内不含括号且长度 ≤10 的内容"；`马景峰(副教授,硕士研究生导师)`（括号内 12 字）**不会**被删。
- 不拆多个教师：`"文娟,李四"` → 原样保留（ArkTS 现有版本只取第一个，行为不同）。

---

## 6. 周次解析 `parseWeekSet`（270-293）原文

```kotlin
private fun parseWeekSet(raw: String): List<Int> {
    if (raw.isBlank()) return emptyList()
    val weeks = sortedSetOf<Int>()
    for (seg in raw.split(',', '，', '、', ';', '；')) {
        val s = seg.trim()
        if (s.isEmpty()) continue
        val odd = s.contains("单")
        val even = s.contains("双")
        val range = Regex("""(\d{1,2})\s*[~\-—－至]\s*(\d{1,2})""").find(s)
        if (range != null) {
            val a = range.groupValues[1].toIntOrNull() ?: continue
            val b = range.groupValues[2].toIntOrNull() ?: continue
            for (w in minOf(a, b)..maxOf(a, b)) {
                if (odd && w % 2 == 0) continue
                if (even && w % 2 == 1) continue
                if (w in 1..30) weeks.add(w)
            }
        } else {
            val n = Regex("""(\d{1,2})""").find(s)?.groupValues?.get(1)?.toIntOrNull() ?: continue
            if (n in 1..30) weeks.add(n)
        }
    }
    return weeks.toList()
}
```

### 6.1 支持的输入格式
| 输入 | 结果 | 说明 |
|---|---|---|
| `4-5周,8周,11-13周(单),14-16周` | `[4,5,8,11,13,14,15,16]` | 官方测试用例 |
| `1-16周` | `1..16` | |
| `6-7周,9-10周,12周` | `[6,7,9,10,12]` | |
| `1,3,5周` | `[1,3,5]` | 单段内的裸数字**只取第一个**：`"1,3,5周"` 在 split 后是 `1` / `3` / `5周` ✓ |
| `第3周` / `第3,5周` | `[3]` / split 后 `第3`→3、`第5周`→5 | `第` 不参与匹配 |
| `1~16周` / `1至16周` / `1—16周` / `1－16周` | `1..16` | 分隔符类 `[~\-—－至]` |
| `（单）` `(单)` `单周` 出现在**区间段** | 过滤偶数 | `contains("单")` |
| `（双）` `(双)` `双周` 出现在**区间段** | 过滤奇数 | `contains("双")` |

### 6.2 边界与异常
1. `raw.isBlank()` → `emptyList()`；空段（连续逗号）跳过。
2. 分隔符**只有** `, ， 、 ; ；`；**没有空白**（见 §13-B1）。
3. 区间端点自动纠正方向（`16-1` → `1..16`）；两处 `toIntOrNull()` 在 `\d{1,2}` 下不会失败（防御性死代码）。
4. 逐周过滤 `w in 1..30`；单值分支 `n in 1..30`。**超出 30 的周次静默丢弃**（如 `1-32周` → 只到 30）。
5. **单值分支不看 `单`/`双`**（§13-B2）。
6. 同一段里**同时**含"单"和"双"（如 `1-16周(单双)`）→ 两个过滤都生效 → 该段**一个周次都不加**。
7. 段内含两个不相邻数字但无分隔符（`第3周 第5周`）→ 走单值分支只取 `3`。
8. 返回 `sortedSetOf` → **升序、去重**的 `List<Int>`（`Course.weeks` 的契约：非空时优先生效，见 `Course.occursOnWeek`）。

---

## 7. 策略②③：表格视图 `tryGridLayout`（305-340）原文

```kotlin
private fun tryGridLayout(grid: List<List<Element?>>, useHeaderDays: Boolean): Outcome {
    if (grid.size < 2) return Outcome(emptyList(), "表格视图")

    var dayCols: Map<Int, DayOfWeek>? = null
    var secCol = 0
    if (useHeaderDays) {
        for (row in grid) {
            val map = HashMap<Int, DayOfWeek>()
            row.forEachIndexed { i, c -> dayOf(c?.text() ?: "")?.let { map[i] = it } }
            if (map.size >= 5) {
                dayCols = map
                secCol = (0 until (map.keys.max() + 1)).firstOrNull { it !in map.keys } ?: 0
                break
            }
        }
        if (dayCols == null) return Outcome(emptyList(), "表格视图")
    }

    val out = ArrayList<Course>()
    for (row in grid) {
        if (row.size < 3) continue
        val mapping = dayCols ?: buildDefaultDayCols(row.size)
        val section = parseSectionLoose(row[secCol]?.text() ?: "") ?: continue
        for ((colIdx, day) in mapping) {
            if (colIdx >= row.size) continue
            val cell = row[colIdx] ?: continue
            for (entry in extractEntriesFromGridCell(cell)) {
                parseGridEntry(entry, day, section.first, section.second)?.let { out.add(it) }
            }
        }
    }
    return Outcome(
        dedupe(out),
        if (useHeaderDays) "表格视图（按表头星期）" else "表格视图（默认列序）",
    )
}
```

### 7.1 表头识别（`useHeaderDays = true`）
- 逐行统计"用 `dayOf`（**严格**）能识别出的列数"，**某行 ≥5 个**即认定为表头行，记 `dayCols = {列号→星期}`，并 `break`（取第一个满足的行）。
  - `dayOf` 要求文本含 `星期/周/礼拜` + 一个日名字 → `"周一"…"周日"` ✓，`"星期天"` ✓，`"周1"` ✗，空单元格 ✗。
  - `map.size >= 5` 意味着**只显示 3~4 天的表无法用策略②**（会落到策略③，把 1..7 列硬当周一到周日）。
- 节次列 `secCol` = **在 `0..max(dayCols)` 内第一个不属于星期列的列号**；若 0..max 全是星期列（例如节次列在最右）→ `?: 0` → 于是用第 0 列当节次列 → 解析失败 → 0 门课。
  - 典型 `节次 + 星期一..星期日`：dayCols = {1..7}，max=7，第一个不在其中的是 0 → `secCol = 0` ✓。
  - `时间 + 周一..周日`（8 列）：dayCols = {1..7} → `secCol = 0` ✓。
  - `星期一..星期日 + 节次`（节次在最后）：dayCols = {0..6}，`firstOrNull{...}` 在 0..6 内找不到 → `?: 0` → `secCol = 0` → 每行 `parseSectionLoose(星期一)` = null → **全部 continue，0 门课**。
- `map.keys.max()` 在 `map.size >= 5` 保护下不会对空集合调用（否则 `max()` 抛 `NoSuchElementException`）。

### 7.2 无表头（`useHeaderDays = false`，策略③）
- 不找表头；`dayCols` 保持 `null` → 每行用 `buildDefaultDayCols(row.size)`：
```kotlin
private fun buildDefaultDayCols(cellCount: Int): Map<Int, DayOfWeek> {
    val map = HashMap<Int, DayOfWeek>()
    for (i in 1..7) if (i < cellCount) map[i] = DayOfWeek.of(i)
    return map
}
```
即**列 1..7 = 周一..周日**（`DayOfWeek.of(1)=MONDAY` … `of(7)=SUNDAY`），且 `i < cellCount` 保证列存在；列 0 = 节次；列 8+（备注等）被忽略。
- `secCol` 恒为 0（初始化值 `var secCol = 0`）。

### 7.3 行/列循环
- 行遍历**从第 0 行开始**（表头行也会被扫，但 `parseSectionLoose("节次")` = null → 跳过）。
- `if (row.size < 3) continue`；随后 `row[secCol]` **没有 secCol < row.size 的守卫**（§13-B9）。
- 节次取自**行**（`row[secCol]`），单元格内部形如 `[01-02节]` 的括号在启发式里会被**剥掉**，不参与定位。
- 遍历 `mapping`（**HashMap，遍历顺序不保证**），`colIdx >= row.size` 跳过，空格子跳过。

### 7.4 `extractEntriesFromGridCell`（349-375）原文
```kotlin
private fun extractEntriesFromGridCell(cell: Element): List<String> {
    val divs = cell.select("div").filter { it.text().isNotBlank() }
    if (divs.isNotEmpty()) {
        val leaf = divs.filter { it.select("div").isEmpty() }
        val chosen = (if (leaf.isNotEmpty()) leaf else divs).map { it.text().trim() }
        val withWeeks = chosen.filter { Regex("""周""").containsMatchIn(it) }
        return (if (withWeeks.isNotEmpty()) withWeeks else chosen).distinct()
    }
    val lines = cellLines(cell)
    if (lines.isEmpty()) return emptyList()
    if (lines.size == 1) return lines
    val totalHits = lines.sumOf { Regex("""\d\s*[~\-—－至]?\s*\d*\s*周""").findAll(it).count() }
    if (totalHits <= 1) return listOf(lines.joinToString(" "))
    // 多段：按"含周次"行分块
    val out = ArrayList<String>()
    val cur = StringBuilder()
    var curWeeks = 0
    for (line in lines) {
        val w = Regex("""\d\s*[~\-—－至]?\s*\d*\s*周""").findAll(line).count()
        if (curWeeks > 0 && w > 0) { out.add(cur.toString().trim()); cur.clear(); curWeeks = 0 }
        if (cur.isNotEmpty()) cur.append(' ')
        cur.append(line)
        curWeeks += w
    }
    if (cur.isNotBlank()) out.add(cur.toString().trim())
    return out
}
```
两种模式：
1. **有 `<div>`**：取所有非空白 div；优先取**叶子 div**（自身不含 div）；若没有叶子则用全部 div。文本 `trim()` 后：
   - 先筛出**含"周"字的那些**；非空则**只返回它们**（`.distinct()`），否则返回全部。
   - ⚠ 这一步是"一个 div 一条目"的假设：一门课被拆成 `<div>课程名</div><div>教师</div><div>1-16周</div><div>教室</div>` 时只会留下 `1-16周`（§13-B5）。
2. **无 `<div>`（用 `cellLines`）**：
   - 1 行 → 直接返回该行。
   - 全格"周次命中数"（`\d\s*[~\-—－至]?\s*\d*\s*周` 的 `findAll().count()` 之和）≤1 → **所有行合成一条**（空格连接）。
   - 否则按"含周次的行"分块：当**当前块已有周次行**且**本行也是周次行**时，先收尾、再以本行开新块；每行以空格拼接；`curWeeks` 累加本行命中数。
   - ⚠ 由于新块**从周次行开始**，下一门课的名字行会被粘进上一块（§13-B6）。

### 7.5 `parseGridEntry`（378-386）原文
```kotlin
private fun parseGridEntry(
    raw: String, day: DayOfWeek, secStart: Int, secEnd: Int,
): Course? {
    // 含标签 → 走标签解析
    if (LABEL_REGEX.containsMatchIn(raw)) {
        parseCourseBlock(raw, day, secStart, secEnd)?.let { return it }
    }
    return parseHeuristic(raw, day, secStart, secEnd)
}
```
**含标签先走 `parseCourseBlock`，若它返回 null（名字空/超 60 字、或既无周次又无地点），会继续退化到 `parseHeuristic`。**

---

## 8. 通用启发式 `parseHeuristic`（389-454）原文 + 逐行说明

```kotlin
/** 通用启发式：`高等数学(分组A)张三 1-16周[01-02节]明德楼B104` 这类纯文本。 */
private fun parseHeuristic(
    raw: String, day: DayOfWeek, secStart: Int, secEnd: Int,
): Course? {
    val text = raw.replace('\u00a0', ' ').replace(Regex("""\s+"""), " ").trim()
    val weeks = parseWeekSet(text)
    if (weeks.isEmpty()) return null

    // 原始周次片段与单双周标记（用于展示）
    val weekFragments = WEEKS_FRAGMENT.findAll(text).map { it.value.trim() }.toList()
    val oddEven = when {
        text.contains("单周") || text.contains("(单)") || text.contains("（单）") -> 1
        text.contains("双周") || text.contains("(双)") || text.contains("（双）") -> 2
        else -> 0
    }
    val weeksText = (
        weekFragments.joinToString(",") +
            when (oddEven) { 1 -> "(单)"; 2 -> "(双)"; else -> "" }
        ).trim(',', ' ')

    var rest = text
    WEEKS_FRAGMENT.findAll(rest).toList().forEach { rest = rest.replace(it.value, " ") }
    rest = rest.replace(SEC_BRACKET, " ")
    rest = rest.replace(SEC_RANGE, " ").replace(SEC_SINGLE, " ")
    rest = rest.replace(Regex("""[（(]\s*[单双]\s*[）)]"""), " ")
    rest = rest.replace(Regex("""[（(]\s*[）)]"""), " ")
    rest = rest.replace(Regex("""\s+"""), " ").trim()

    val tokens = rest.split(Regex("""[\s,，;；/|]+""")).filter { it.isNotBlank() }.toMutableList()
    if (tokens.isEmpty()) return null

    var location = ""
    var teacher = ""
    val locIdx = tokens.indexOfFirst {
        Regex("""(楼|教室|馆|场|室|区|机房|报告厅|实训|中心)""").containsMatchIn(it) && it.length in 2..20
    }
    if (locIdx >= 0) location = tokens.removeAt(locIdx)

    val tIdx = tokens.indices.lastOrNull {
        it > 0 && Regex("""^[\u4e00-\u9fa5]{2,4}$""").matches(tokens[it])
    }
    if (tIdx != null) teacher = tokens.removeAt(tIdx)

    var name = tokens.firstOrNull()?.trim().orEmpty()
    if (name.isEmpty()) name = rest.trim().take(30)
    if (name.isEmpty()) return null

    if (teacher.isEmpty()) {
        val m = Regex("""[)）]\s*([\u4e00-\u9fa5]{2,4})$""").find(name)
        if (m != null) {
            teacher = m.groupValues[1]
            name = name.substring(0, m.range.first + 1).trim()
        }
    }
    if (name.isEmpty()) return null

    return Course(
        id = 0, name = name, teacher = teacher, location = location,
        dayOfWeek = day, startIndex = secStart, endIndex = secEnd,
        startWeek = weeks.min(), endWeek = weeks.max(),
        oddEven = oddEven,
        category = CoursePalette.inferCategory(name, location),
        weeksText = weeksText.ifBlank { "${weeks.min()}-${weeks.max()}周" },
        weeks = weeks,
        raw = text,
    )
}
```

### 8.1 步骤表
| 步骤 | 规则 |
|---|---|
| 0 归一化 | `\u00a0` → 普通空格（**这一步 Kotlin 版做了**，与 `parseCourseBlock` 不同）；`\s+` → 单空格；`trim()` |
| 1 周次 | `parseWeekSet(text)`——**直接吃整段文本**；解析不出周次 → `null`（丢弃）。⚠ 见 §13-B4 |
| 2 周次原文 | `WEEKS_FRAGMENT.findAll(text)` 的值逐个 `trim()`，用 `,` 连接 |
| 3 单双 | 全文 `contains`：`单周`/`(单)`/`（单）` → 1；否则 `双周`/`(双)`/`（双）` → 2；否则 0（**单优先于双**） |
| 4 `weeksText` | `片段CSV + "(单)"/"(双)"`，再 `trim(',',' ')`；空 → 后面用 `"min-max周"` 兜底 |
| 5 剥离 | ① 逐个 `WEEKS_FRAGMENT` 匹配做 **`String.replace`（全部替换）**；② `SEC_BRACKET`（带"节"的括号）；③ `SEC_RANGE` → `SEC_SINGLE`；④ `[（(]\s*[单双]\s*[）)]`；⑤ 空括号 `[（(]\s*[）)]`；⑥ 折叠空白 |
| 6 分词 | `split(Regex("""[\s,，;；/|]+"""))`（**不切 `、`、括号、`-`**），去空 |
| 7 地点 | 第一个"含 `楼/教室/馆/场/室/区/机房/报告厅/实训/中心` 之一 **且** 长度 2..20"的 token（`indexOfFirst`），取出并移除 |
| 8 教师 | 在**剩余 token** 中，取最后一个"下标 > 0 **且** 完全匹配 `^[\u4e00-\u9fa5]{2,4}$`"的 token，取出并移除 |
| 9 课程名 | 移除后剩下的**第一个** token；若已无 token → 用 `rest.trim().take(30)`；仍空 → `null` |
| 10 教师兜底 | 教师为空时，用 `[)）]\s*([\u4e00-\u9fa5]{2,4})$` 从**课程名里**抠出"右括号后的 2-4 个汉字"（`高等数学(分组A)张三` → 教师 `张三`，课程名 `高等数学(分组A)`，注意**保留了左括号**） |
| 11 产出 | `startWeek = weeks.min()`，`endWeek = weeks.max()`，`oddEven`，`credit` **不设置（= null）**，`weeksText` 兜底 `"min-max周"` |

### 8.2 官方示例（测试用例 `qiangzhiHtml`）的完整推演
输入条目：`高等数学(分组A)张三 1-16周[01-02节]明德楼B104`
1. `parseWeekSet` → 首个 `\d-\d` 是 `1-16` → `[1..16]`。
2. `WEEKS_FRAGMENT` 命中 `1-16周`；`oddEven = 0`；`weeksText = "1-16周"`。
3. 剥掉 `1-16周` 与 `[01-02节]` 后：`高等数学(分组A)张三   明德楼B104`。
4. tokens = `[高等数学(分组A)张三, 明德楼B104]`；`locIdx=1`（含"楼"，长度 8）→ `location = 明德楼B104`。
5. 剩下 `[高等数学(分组A)张三]`：`tIdx` 要求 `it > 0` → **null** → `teacher = ""`。
6. `name = "高等数学(分组A)张三"` → 教师兜底正则命中 `)张三` → `teacher = 张三`，`name = "高等数学(分组A)"`。

---

## 9. 策略④：`tryDivGrid`（503-513）原文

```kotlin
private fun tryDivGrid(doc: Document): Outcome {
    val out = ArrayList<Course>()
    for (b in doc.select("div, li, p")) {
        val t = b.text().trim()
        if (t.length < 8 || t.length > 600) continue
        val day = dayOf(t) ?: continue
        val section = parseSectionLoose(t) ?: continue
        parseGridEntry(t, day, section.first, section.second)?.let { out.add(it) }
    }
    return Outcome(dedupe(out), "div 网格（实验性）")
}
```
- 只扫 `div, li, p`（**含所有嵌套层级**，父节点会被重复处理）。
- 文本长度必须 **8..600**（含端点）。
- 必须**同一段文本里同时**含严格星期（`dayOf`）和节次（`parseSectionLoose`）。
- 然后走 `parseGridEntry`（标签优先 → 启发式）。
- 结果 `dedupe`；返回策略名 `"div 网格（实验性）"`。`parse` 只在它非空时采用。

---

## 10. 学期名 / 当前周

### 10.1 `guessSemester`（464-489）原文
```kotlin
fun guessSemester(html: String): String? {
    if (html.isBlank()) return null
    val text = Jsoup.parse(html).text().replace('\u00a0', ' ')

    val patterns = listOf(
        // 2026-2027学年第1学期 / 2026-2027 学年 第一学期
        Regex("""(20\d{2})\s*[-—~－至]\s*(20\d{2})[^0-9]{0,8}?第\s*([12一二])\s*学期"""),
        // 允许"学年"与"第X学期"之间被打断
        Regex("""(20\d{2})\s*[-—~－至]\s*(20\d{2})\s*学年"""),
        // 2026-2027-1
        Regex("""(20\d{2})\s*[-—~－至]\s*(20\d{2})\s*[-—~－至]\s*([12])(?!\d)"""),
    )
    for (p in patterns) {
        val m = p.find(text) ?: continue
        val year = "${m.groupValues[1]}-${m.groupValues[2]}"
        val term = m.groupValues.getOrNull(3)?.let {
            when (it) {
                "1", "一" -> "第1学期"
                "2", "二" -> "第2学期"
                else -> ""
            }
        } ?: ""
        return listOf(year, term).filter { it.isNotBlank() }.joinToString(" ")
    }
    return null
}
```
- 文本 = 整页 `text()`，`\u00a0` → 空格。
- **按顺序**试三个正则，命中第一个就返回，**不再往下试**。
- 返回格式：`"2026-2027 第1学期"`（年份 + 空格 + 学期）；若命中的是模式 2（无学期组）→ 只有 `"2026-2027"`。
- 模式 1 的 `[^0-9]{0,8}?`（惰性，最多 8 个非数字字符）用来容忍 `学年第` / ` 学年 第` 之间的噪声。
- 分隔符类 `[-—~－至]` 含 `-`、`—`(U+2014)、`~`、`－`(U+FF0D)、`至`；**不含** `–`(U+2013 en dash) 与全角 `～`(U+FF5E)。模式 3 的 `(?!\d)` 防止 `2026-2027-11` 之类误匹配。
- 全部失败 → `null`（UI 里 `orEmpty()`）。

### 10.2 `guessCurrentWeek`（491-498）原文
```kotlin
fun guessCurrentWeek(html: String): Int? {
    if (html.isBlank()) return null
    val text = Jsoup.parse(html).text()
    val m = Regex("""第\s*(\d{1,2})\s*周""").find(text) ?: return null
    val w = m.groupValues[1].toIntOrNull() ?: return null
    return if (w in 1..30) w else null
}
```
- 全页文本里**第一个** `第N周`（N 为 1-2 位数字），范围 1..30，否则 `null`。
- **不会**匹配 `周数：4-5周,8周`（`第` 后面必须是数字再紧跟"周"；`第1-2周` 也不匹配，因为 `1` 后是 `-`）——官方测试断言了这两点。
- ⚠ 只要页面上**任何地方**（含下拉框 `<option>第1周</option>`、课程卡片）先出现 `第N周`，就会把它当当前周（§13-B11）。

---

## 11. 全部正则表达式清单（原文照抄 + 用途）

> 说明：「Kotlin 字面量」= 源码里的写法；「实际 pattern」= 送进 `java.util.regex` 的字符串（三引号原样、双引号已解转义）。

| # | 行 | 名称 | Kotlin 字面量 | 实际 pattern | 用途 |
|---|---|---|---|---|---|
| 1 | 34 | `SEC_RANGE` | `"""第?\s*(\d{1,2})\s*[~\-—－至]\s*(\d{1,2})\s*节"""` | `第?\s*(\d{1,2})\s*[~\-—－至]\s*(\d{1,2})\s*节` | `第1~2节`/`1-2节` → 节次区间；`parseSectionLoose` 首选；启发式剥离 |
| 2 | 35 | `SEC_SINGLE` | `"""第?\s*(\d{1,2})\s*节"""` | `第?\s*(\d{1,2})\s*节` | `第3节`/`3节` → 单节次；启发式剥离 |
| 3 | 36 | `SEC_BARE_RANGE` | `"""(\d{1,2})\s*[~\-—－至]\s*(\d{1,2})"""` | `(\d{1,2})\s*[~\-—－至]\s*(\d{1,2})` | 裸区间 `1-2`、`01-02`（需 1..20 校验），仅 `parseSectionLoose` 用 |
| 4 | 37 | `SEC_BARE_SINGLE` | `"""^(\d{1,2})$"""` | `^(\d{1,2})$` | 裸单值 `3`（需 1..20），仅 `parseSectionLoose` 用 |
| 5 | 39 | `SEC_BRACKET` | `"[\\u005B［(（]?\\s*\\d{1,2}\\s*[-~—－至]\\s*\\d{1,2}\\s*节\\s*[\\u005D］)）]?"` | `[\u005B［(（]?\s*\d{1,2}\s*[-~—－至]\s*\d{1,2}\s*节\s*[\u005D］)）]?` | 剥掉 `[01-02节]`/`(1-2节)`/`（1~2节）`；`\u005B`=`[`、`\u005D`=`]`（字符类里必须转义，否则正则报错）。**整段可选**，所以裸 `1-2节` 也会被剥 |
| 6 | 41 | `WEEKS_FRAGMENT` | `"""\d{1,2}\s*[~\-—－至]?\s*\d{0,2}\s*[（(]?\s*[单双]?\s*[）)]?\s*周"""` | `\d{1,2}\s*[~\-—－至]?\s*\d{0,2}\s*[（(]?\s*[单双]?\s*[）)]?\s*周` | 抓周次片段（`1-16周`、`5周`、`1-16（单）周`）；用于展示文本与剥离 |
| 7 | 55 | `LABEL_REGEX` | `"(" + LABEL_NAMES.joinToString("\|") + """)\s*[：:]"""` | `(周数\|校区\|上课地点\|上课时间\|上课教室\|教师\|任课教师\|教学班组成\|教学班\|考核方式\|考试方式\|选课备注\|课程学时组成\|周学时\|总学时\|学分\|课程性质\|开课学院\|选课人数\|容量\|备注)\s*[：:]` | 识别卡片字段标签（**必须带 `：`/`:`**） |
| 8 | 58 | `BLOCK_END` | `"""学分\s*[：:]\s*[\d.]{1,6}"""` | `学分\s*[：:]\s*[\d.]{1,6}` | 兜底切块点（含数字，防止匹配到"学分："后面没数字的情况） |
| 9 | 167 | 匿名 | `"""周数\s*[：:]"""` | `周数\s*[：:]` | 判断"一格一行里有多个 `周数：`" |
| 10 | 197 | 匿名 | `"""\s+"""` | `\s+` | 空白折叠（`parseCourseBlock`） |
| 11 | 221 | 匿名 | `"""\s+"""` | `\s+` | 校区名去空白 |
| 12 | 231 | 匿名 | `"""\d+(?:\.\d+)?"""` | `\d+(?:\.\d+)?` | 从"学分"值里取数字 |
| 13 | 278 | 匿名（周次区间） | `"""(\d{1,2})\s*[~\-—－至]\s*(\d{1,2})"""` | `(\d{1,2})\s*[~\-—－至]\s*(\d{1,2})` | `parseWeekSet` 段内区间 |
| 14 | 288 | 匿名（周次单值） | `"""(\d{1,2})"""` | `(\d{1,2})` | `parseWeekSet` 段内首个 1-2 位数 |
| 15 | 296 | 匿名 | `"""\s+"""` | `\s+` | `cleanLocation` 空白折叠 |
| 16 | 300 | 匿名 | `"""[（(][^）)]{0,10}[）)]"""` | `[（(][^）)]{0,10}[）)]` | `cleanTeacher` 去职称括号 |
| 17 | 354 | 匿名 | `"""周"""` | `周` | div 条目是否含"周" |
| 18 | 360/367 | 匿名 | `"""\d\s*[~\-—－至]?\s*\d*\s*周"""` | `\d\s*[~\-—－至]?\s*\d*\s*周` | 统计一条文本里的"周次命中数"（分块用） |
| 19 | 392 | 匿名 | `"""\s+"""` | `\s+` | 启发式空白折叠 |
| 20 | 412 | 匿名 | `"""[（(]\s*[单双]\s*[）)]"""` | `[（(]\s*[单双]\s*[）)]` | 剥 `(单)`/`（双）` |
| 21 | 413 | 匿名 | `"""[（(]\s*[）)]"""` | `[（(]\s*[）)]` | 剥空括号 `()`/`（）` |
| 22 | 414 | 匿名 | `"""\s+"""` | `\s+` | 收尾空白折叠 |
| 23 | 416 | 匿名（分词） | `"""[\s,，;；/\|]+"""` | `[\s,，;；/\|]+` | 启发式分词（**不切 `、`**） |
| 24 | 422 | 匿名（地点特征） | `"""(楼\|教室\|馆\|场\|室\|区\|机房\|报告厅\|实训\|中心)"""` | `(楼\|教室\|馆\|场\|室\|区\|机房\|报告厅\|实训\|中心)` | 判断 token 是否像地点 |
| 25 | 427 | 匿名（教师名） | `"""^[\u4e00-\u9fa5]{2,4}$"""` | `^[\u4e00-\u9fa5]{2,4}$` | token 是否为 2-4 个纯汉字（用 `matches()` = 全串匹配） |
| 26 | 436 | 匿名（名内教师） | `"""[)）]\s*([\u4e00-\u9fa5]{2,4})$"""` | `[)）]\s*([\u4e00-\u9fa5]{2,4})$` | 从课程名末尾"右括号 + 2-4 汉字"里抠教师 |
| 27 | 470 | `guessSemester[0]` | `"""(20\d{2})\s*[-—~－至]\s*(20\d{2})[^0-9]{0,8}?第\s*([12一二])\s*学期"""` | `(20\d{2})\s*[-—~－至]\s*(20\d{2})[^0-9]{0,8}?第\s*([12一二])\s*学期` | `2026-2027学年第1学期` / `第一学期` |
| 28 | 472 | `guessSemester[1]` | `"""(20\d{2})\s*[-—~－至]\s*(20\d{2})\s*学年"""` | `(20\d{2})\s*[-—~－至]\s*(20\d{2})\s*学年` | 只有学年、没有学期 |
| 29 | 474 | `guessSemester[2]` | `"""(20\d{2})\s*[-—~－至]\s*(20\d{2})\s*[-—~－至]\s*([12])(?!\d)"""` | `(20\d{2})\s*[-—~－至]\s*(20\d{2})\s*[-—~－至]\s*([12])(?!\d)` | `2026-2027-1` |
| 30 | 495 | 匿名 | `"""第\s*(\d{1,2})\s*周"""` | `第\s*(\d{1,2})\s*周` | 当前周次 |
| 31 | 572 | 匿名 | `"""<br\s*/?>"""`+IGNORE_CASE | `<br\s*/?>` | `<br>`/`<br/>`/`<br />` → 哨兵 |
| 32 | 573 | 匿名 | `"""</(div\|p\|li\|tr\|h[1-6]\|table)>"""`+IGNORE_CASE | `</(div\|p\|li\|tr\|h[1-6]\|table)>` | 块级闭标签 → 哨兵 |
| 33 | 574 | 匿名 | `"""<(div\|p\|li\|tr\|h[1-6]\|table)[^>]*>"""`+IGNORE_CASE | `<(div\|p\|li\|tr\|h[1-6]\|table)[^>]*>` | 块级开标签 → 哨兵 |

---

## 12. 课程名 / 教师名的拆分规则（回答"怎么判断末位词是教师名"）

**结论：Kotlin 原版中不存在"末位词可能是教师名"的通用的启发式，也没有任何例外词表（白名单/黑名单）。**
教师名只有三个来源：

1. **标签来源（主路径）**：卡片里 `教师：` 或 `任课教师：` 标签的值 → `cleanTeacher`（只做"去括号职称 + 截断 20 字"）。
   - 是否被误判成**课程名的一部分**？不存在这个问题——名字只取"第一个标签之前"的文本，标签之后的内容绝不会进名字。
   - 反过来，**课程名里若含"标签名 + 冒号"**（例如 `大学英语：综合教程`），名字会被截断成 `大学英语`（§13-B14）。
2. **启发式 token 规则**：在"剥掉周次/节次/单双括号"后的 token 列表里，取**最后一个**满足以下条件的 token：
   ```kotlin
   tokens.indices.lastOrNull {
       it > 0 && Regex("""^[\u4e00-\u9fa5]{2,4}$""").matches(tokens[it])
   }
   ```
   - 位置守卫 `it > 0`：**第 0 个 token 永远被当作课程名**，不会被当教师。
   - 形态守卫：**整串恰好 2~4 个汉字**（`matches` 是全串匹配 → 不能含数字/字母/括号/空格）。
   - 方向：`lastOrNull` → 取**最靠后**的候选（默认教师写在后面）。
   - ⚠ **它无法区分"末位是课程名的一部分"**：`"高等数学 概论"` 会把 `概论` 当成教师；`"大学英语 听说教程"` 中 `听说教程` 是 4 字 → 被当成教师。**原版没有 `概论/原理/基础/教程…` 这类例外词表**（ArkTS 现有版本**加了** `isNameWord()`，见 §15——这是移植时必须保留的改进）。
3. **括号兜底**：教师仍为空时，用
   ```kotlin
   Regex("""[)）]\s*([\u4e00-\u9fa5]{2,4})$""")
   ```
   从**课程名**里抠出"右括号后紧跟到字符串末尾的 2-4 个汉字"，赋给教师，并把课程名截到"右括号（含）"为止。
   - 只在"名末以**右括号**结尾"时成立（`高等数学(分组A)张三` → 教师 `张三`，名 `高等数学(分组A)`）。
   - 例外/风险：名字本身正常以括号结尾且没有教师时不会误伤（因为需要括号后还有 2-4 汉字）；但 `"体育(二)健美操"` → 教师 `健美操`（3 字），名字 `体育(二)` ——**误判**。

另外注意：**教师 token 检索在"地点 token 已被移除"之后进行**，且 `it > 0` 的判定基于**移除后的下标**。因此当列表只剩 1 个 token 时（如 `"1-16周 王五 明德楼B104"` 分块后），`tIdx` 为 null → 教师为空 → 第 9 步把 `王五` 当成课程名（§13-B7）。

---

## 13. Bug 与可疑点清单

### A. 高影响（会丢课/错课，移植时建议修）

**B1. 空格分隔的周次会丢数据**
`parseWeekSet` 只按 `, ， 、 ; ；` 切段。`"4-5周 8周"` 是一个段 → 命中区间 `4-5` → 只加 4、5，`8周` 被完全忽略。
同理 `"第3周 第5周"` → 只加 3。真实教务页面用空格/换行分隔周次时必错。

**B2. 单值周次分支忽略"单/双"标记**
```kotlin
} else {
    val n = Regex("""(\d{1,2})""").find(s)?.groupValues?.get(1)?.toIntOrNull() ?: continue
    if (n in 1..30) weeks.add(n)      // ← 没有 odd/even 过滤
}
```
`"7周(双)"` → 加 7（错）；`"12周(单)"` → 加 12（错）。区间分支有过滤、单值分支没有 —— 不一致。

**B3. 周次解析为空但地点存在时，`startWeek = endWeek = 1`**
```kotlin
val sw = weeks.minOrNull() ?: 1
val ew = weeks.maxOrNull() ?: 1
```
`Course.occursOnWeek()` 的语义是：`weeks` 非空则用集合；**为空则退化成 `startWeek..endWeek` + oddEven**。于是这种卡片只在**第 1 周**显示（`1..1`），而不是"每周"。
`Course` 的文档写"0=每周"，但这里把 `startWeek/endWeek` 置 1，没有表达"每周"的方式。
（ArkTS 现有版本用了 `1..16` 兜底，比原版更合理，但仍是猜的——移植时应该显式定义这种卡片的语义。）

**B4. 启发式把"节次括号/年份/教室号"当周次**
`parseHeuristic` 第一句就是 `parseWeekSet(text)`，而 `parseWeekSet` 的区间正则是**无锚点**的 `(\d{1,2})\s*[~\-—－至]\s*(\d{1,2})`，取全串**第一个**匹配：
- `"[01-02节]高等数学 张三 1-16周"` → 首个区间是 `01-02` → 周次变成 `[1,2]`（错）。
  官方测试里能过只是因为 `1-16周` 恰好写在 `[01-02节]` **之前**。
- `"2026-2027学年"` 出现在单元格里 → `26-20` → 20..26（错）。
- `tryDivGrid` 会把整段 div 文本喂进来，`"星期一 第1-2节 高等数学"`（无周次）→ 周次 `[1,2]` → **凭空造出一门课**（`weeks` 非空即通过校验）。
建议移植时：先剥掉 `SEC_*`、`（…）`，再在**含"周"的片段**里解析周次。

**B5. 表格视图 div 分支会"只留含周的那一个 div"，导致整门课丢失**
```kotlin
val withWeeks = chosen.filter { Regex("""周""").containsMatchIn(it) }
return (if (withWeeks.isNotEmpty()) withWeeks else chosen).distinct()
```
若一格是 `<div>高等数学</div><div>张三</div><div>1-16周</div><div>明德楼B104</div>` → 只返回 `["1-16周"]` → `parseHeuristic` 剥完周次后 `rest` 为空 → `tokens.isEmpty()` → `return null` → **这门课彻底消失**。
（只有"一个 div 里包含全部字段"或"没有 div"时才安全。）

**B6. 表格视图多段分块会把下一门课的名字粘到上一块**
```kotlin
if (curWeeks > 0 && w > 0) { out.add(cur.toString().trim()); cur.clear(); curWeeks = 0 }
```
行序列 `[A名, A周, A师, A地, B名, B周, B师, B地]` → 块1 = `A名 A周 A师 A地 B名`（B 的名字丢了）、块2 = `B周 B师 B地`（B 没有名字 → `name` 变成周次被剥后的第一个 token，很可能是教师名）。建议：以"含周次的行"为**卡片结束**标志，或把周次行**之前**的行归到本卡。

**B7. 教师识别 `it > 0` 的副作用**
移除地点后只剩 1 个 token 时，教师识别直接放弃 → 该 token 变成课程名：
`"1-16周 王五 明德楼B104"` → `location=明德楼B104`、`teacher=""`、`name="王五"`。正确结果应是 `name` 缺失（该条应丢弃或另作处理），但绝不能把教师当课名。

**B8. 没有例外词表 → 末尾的课程名词会被当教师**
见 §12。`"高等数学 概论"`、`"大学英语 听说教程"` 都会被误拆。移植时保留 ArkTS 版新增的 `isNameWord()`（并可扩充）。

**B9. `tryGridLayout` 缺 `row[secCol]` 的边界检查 → 可能抛 `IndexOutOfBoundsException`**
```kotlin
if (row.size < 3) continue
val mapping = dayCols ?: buildDefaultDayCols(row.size)
val section = parseSectionLoose(row[secCol]?.text() ?: "") ?: continue   // ← row[secCol] 直接用下标
```
`expandTable` 允许**参差不齐的行**；当 `secCol ≥ 3`（表头里星期列不连续、中间有"空洞"时可能出现）而某行长度在 `3..secCol` 之间 → 崩溃。
对比 `tryListLayout` 有 `if (row.size <= maxOf(dayCol, secCol)) continue` 的保护。虽然概率低，但**移植时务必补上 `secCol < row.size` 判断**（ArkTS 里抛异常会直接让导入失败）。

**B10. 周次片段用 `String.replace` 剥离 → 子串污染**
```kotlin
WEEKS_FRAGMENT.findAll(rest).toList().forEach { rest = rest.replace(it.value, " ") }
```
`replace` 是**全局字面替换**。文本 `"6周 16周"`：片段列表 = `["6周","16周"]`；先替换 `"6周"` 会把 `"16周"` 里的 `"6周"` 一起吃掉 → `"1 "`，随后再找 `"16周"` 已不存在 → 残留 `"1"` 变成课程名 token。
建议：按 `MatchResult` 的区间从后往前拼接删除，或用 `replaceFirst`/`StringBuilder`。

**B11. `guessCurrentWeek` 取全页第一个"第N周"**
真实课表页常有"周次选择"下拉（`<option>第1周</option>…`），`Jsoup.text()` 会把这些 option 文本拼进文档文本 → **第一个永远是"第1周"** → 当前周恒为 1。
官方测试只验证了"不匹配 `周数：4-5周`"。移植时建议优先在"当前周/第 N 周"附近的上下文里找，或用"出现次数最多/带上下文关键词"的启发式。

### B. 中影响（结果偏差/字段丢失）

**B12. `dayOf` 取的是 `DAY_CHAR` 的插入顺序，不是文本顺序** → 合并单元格 `"星期三、星期五"` → WEDNESDAY（静默取第一个）。

**B13. 表头关键字过窄**
- 列表视图：星期列必须是 `含"星期"` 或 `== "周"` 或 `含"礼拜"`；节次列必须是 `含"节次"`。`"节"`/`"时间"`/`"节数"` 都不行。
- 表格视图严格 `dayOf`：`"周1"`…`"周7"`、`"星期1"`、`"MON"` 全都不认（ArkTS 现有版本认数字，行为不同）。

**B14. 卡片标题行含"标签名+冒号"时名字被截断**
`name = text.substring(0, matches.first().range.first)` 取的是**全文第一个标签**之前的内容。若课程名里出现 `备注：`/`学分：`/`教师：` 之类的子串（如 `"大学英语：综合教程"` 里的 `英语：` 不匹配；但 `"备注：xxx"` 会），名字只剩前半截。
另外：**若卡片第一行就是标签行**（标题缺失），`rawName` 为空 → `return null` → 整卡被丢弃（ArkTS 版本是"扫所有行找第一个非标签行"，更健壮）。

**B15. `cleanTeacher` 的括号内长度上限 10**
`马景峰(副教授,硕士研究生导师)`（括号内 12 字）→ 不剥离 → 教师字段带上一长串职称，再 `take(20)` 截断。

**B16. 地点 token 的关键字集合过宽**
`(楼|教室|馆|场|室|区|机房|报告厅|实训|中心)` + 长度 2..20 → 课程名 token 含这些字（`"图书馆学概论"`、`"粤港澳大湾区概论"`、`"会展策划"`含"场"? 否；但 `"区域经济学"` 含"区"）会被当成地点并**从 token 列表移除**，随后 name 变成下一个 token。

**B17. 地点必须含关键字，否则房间丢失**
`"高等数学 张三 1-16周 B104"` → `B104` 不含任何关键字 → `location = ""`（且不会被当教师，因为不是纯汉字）→ 课程没有地点，且 `parseHeuristic` **不校验地点**（只校验周次）→ 卡片仍会入库但地点为空。

**B18. `\s` 不含 `\u00a0`（Java/Kotlin 默认）**
`parseCourseBlock`、`cleanLocation`、`campus` 的 `\s+` 处理都不动 `\u00a0`（也不会 `\u00a0`→空格），因此经 `Jsoup` 解码后的 `&nbsp;` 会残留在 `raw`、`location`、`campus` 中（首尾的 `\u00a0` 会被 Kotlin 的 `trim()` 吃掉，因为 Kotlin 的 `Char.isWhitespace()` 包含 `\u00a0`）。
例：`上课地点：1226&nbsp;（阶4教室）` → `location = "1226\u00a0（阶4教室）"`（中间是非断空格）。
⚠ **ArkTS/JS 的 `\s` 包含 `\u00a0`**，行为会不一样（见 §14）。

**B19. `dedupe` 的 key 不含 credit** → 只有学分不同的两张卡被合并。

**B20. `campus.take(12)` / `room.take(30)` / `teacher.take(20)` / `name.length > 60` 都是硬截断**（超长直接砍，不报错）。

**B21. `parseSectionLoose` 前两级无范围校验** → `"第99节"` → `(99,99)`；`"1、2节"` → `(2,2)`。

**B22. 单双周优先级**：`text.contains("单周")/"(单)"/"（单）"` 先判 → 一段文本里同时有单周课和双周课时（多卡同格）只记"单"。

**B23. `CoursePalette.inferCategory(name, location)` 的第二个参数未被使用** → 除了名字关键词命中的课，其余全部落到 `MAJOR`（专业课），不是 `OTHER`。

**B24. 策略抢占**：① 只要任意一张表出 ≥1 门课就返回。页面里若有一个小的"星期/节次"示意表排在真正课表之前，可能用它产生错误结果（或产生 0 门课而放过，继续走 ②）。

**B25. `guessSemester` 只返回第一个命中的模式**：页面里若同时出现两个学期（如页眉的上一学期 + 正文的本学期），返回的是**文档顺序靠前**的那个，且三个模式的优先级是固定的（模式 1 永远优先）。

**B26. `parseHeuristic` 的 `weeksText` 可能丢掉单双标记**：`WEEKS_FRAGMENT` 的括号在 `周` **之前**（`1-16（单）周`），而真实写法是 `1-16周(单)` → 片段只抓到 `1-16周`，靠第 3 步的 `contains` 补 `"(单)"`。若文本里没有 `(单)`/`单周` 而写的是 `单`（如 `1-16周单`、`单周1-16`）→ `oddEven=0` 且文本丢失该信息。

### C. 低影响 / 观察项

- **B27.** `parse` 对每张表重复 `expandTable` 最多 3 次（性能）。
- **B28.** `tryDivGrid` 扫所有层级的 `div/li/p`，父节点重复解析（靠 dedupe）。
- **B29.** `cellLines` 不处理 `<br class="x">`、`</div >`（标签名后空格）、`<td>`/`<span>` 边界。
- **B30.** `NL = U+0001` 哨兵若与页面真实字符冲突会多出空行（概率极低）。
- **B31.** `expandTable` 的 rowspan/colspan 上限 200/20，异常值静默钳制。
- **B32.** `valueOf` 只修剪首尾 `；;，,|`，不修剪 `。`、`/`、`、`。
- **B33.** `credit` 只取"学分"值里的**第一个**数字（`学分：2.0/3.0` → 2.0）。
- **B34.** `parseWeekSet` 的 `toIntOrNull()` 永远不会失败（`\d{1,2}` 保证），是死防御代码。
- **B35.** `tryGridLayout` 在 `useHeaderDays = true` 找不到表头时**提前返回**（不会退化成默认列序），默认列序是策略③独立再跑一遍。
- **B36.** 列表视图里"其余列都当信息列"：若表格有"备注/教师"等额外列，可能重复解析同一门课（dedupe 兜住）或产生垃圾卡片。

---

## 14. 移植到 ArkTS 的关键坑（Kotlin/Jsoup → ArkTS）

1. **没有 Jsoup**。必须自己实现（现有 `HtmlTable.ets` 就是干这个的），但要补齐 Jsoup 的语义：
   - `Element.text()`：折叠空白、**在块级元素处插入一个空格**、解码实体、跳过 `script/style`；
   - `Element.html()`：**重新序列化**（`<br/>`→`<br>`、属性加引号、实体转义）——Kotlin 的 `cellLines` 正则是在**归一化后的 HTML** 上跑的；
   - **自动补 `<tbody>`**（`directRows` 依赖它）；
   - `&nbsp;` 解码成 `\u00a0`（**不是**普通空格！现有 ArkTS 版解码成普通空格 `' '`，会改变 §13-B18 的行为）。
2. **`\s` 语义差异（重要）**：Java/Kotlin 的 `\s` = `[ \t\n\x0B\f\r]`（不含 `\u00a0`）；**JS/ArkTS 的 `\s` 含 `\u00a0` 及其它 Unicode 空白**。所有 `\s+` 折叠、`[\s,，;；/|]+` 分词、`第\s*(\d+)\s*周` 的行为都会因此不同。
   建议在 ArkTS 里**显式**写成 `[ \t\u00a0]+` 或先统一把 `\u00a0` 替换成空格，使行为可预测（`parseHeuristic` 已经这么做了，`parseCourseBlock` 没有）。
3. **`$` 语义差异**：Java 的 `$`（非 MULTILINE）还允许匹配"末尾换行符之前"；JS 的 `$` 只匹配串尾。`^(\d{1,2})$`、`[)）]\s*([\u4e00-\u9fa5]{2,4})$` 在带尾随 `\n` 的输入上结果可能不同。ArkTS 里用**全串匹配**函数（如 `new RegExp('^...$')` + `test` 后确认 `match[0].length === s.length`，或用 `^...$` 配 `[\s\S]`）更稳。
4. **Kotlin 专有 API 的等价物**：
   - `String.trim(vararg chars: Char)`（`trim('*','＊','·',' ','\u00a0')`、`trim('；',';',',','，','|')`、`trim(',',' ')`）→ JS 没有"按字符集修剪"，需要手写 while 循环；
   - `sortedSetOf<Int>()` → `Set<number>` + `Array.from(...).sort((a,b)=>a-b)`；
   - `coerceIn(1,200)`、`take(n)`、`toIntOrNull()`、`minOrNull()`/`maxOrNull()`（Kotlin `min()`/`max()` 在非空集合上返回非空值）；
   - `Regex.findAll(...).count()` → `(s.match(re) ?? []).length` 或 `while ((m = re.exec(s)) !== null)`（**注意 `g` 标志与 `lastIndex`**）；
   - `LinkedHashMap` 保序去重 → `Map<string, Course>`（JS 的 `Map` 保序）。
5. **必须复刻的哨兵技巧**：ArkTS 里也可以用 `\u0001`（或 `'\n'`，因为自写解析器不需要 Jsoup 的空白折叠）。但**必须保证**"`<br>` / `<div>` 边界 → 行"这一语义，否则 `extractCoursesFromInfoCell` 的切块、`extractEntriesFromGridCell` 的分块全部失效。
6. **`rowspan` 展开是硬需求**：真实 GLTU 列表页的"星期/节次"用的是 `rowspan="2"`（每个时段两行，每行一个信息格），**必须把被覆盖的格子填成"同一个单元格内容"**（而不是空串），否则第二张卡片所在的行会因为"星期/节次为空"被丢弃。
   ⚠ 现有 `HtmlTable.extractRows` **只处理了 colspan，没有处理 rowspan**（注释里写了 rowspan，代码里没有）——这是当前 ArkTS 版最大的功能缺口；同时 `TimetableParser.tryListView` 用"取该行前 3 个非空单元格"来定位，遇到 rowspan 行的第二个 `<tr>`（只有 1 个非空格）会直接 `continue`，**第二张卡片必然丢失**。
7. **策略字符串要一字不差**（用户可见）：`"无"`、`"列表视图（星期 / 节次 / 课表信息）"`（注意 `/` 两侧各有一个空格）、`"表格视图（按表头星期）"`、`"表格视图（默认列序）"`、`"div 网格（实验性）"`、`"失败"`；失败诊断文案也建议保留（含表格数量与 ①②③ 三条提示）。
8. **类型对齐**：`DayOfWeek` 在 Kotlin 是 `java.time.DayOfWeek`（MONDAY=1 … SUNDAY=7）；`Course.startIndex/endIndex` 直接来自"节次行"的 `min..max`，ArkTS 的 `Course` 需同为 1..7 的 number 语义；`weeks: number[]` 必须**升序去重**。
9. **`guessCurrentWeek` / `guessSemester` 的返回约定**：Kotlin 是 `Int?` / `String?`（null = 没识别出）；现有 ArkTS 是 `-1` / `''`。调用方 `WebImportScreen` 的语义是 `guessCurrentWeek(html) ?: SemesterStore.currentWeek(app)`——移植时保持"识别不出 → 用本地存档值"。

---

## 15. 与仓库里现有 ArkTS 移植版（`GltuSchedule-HarmonyOS/entry/src/main/ets/importer/`）的差异

现有文件：`HtmlTable.ets`（129 行）、`TimetableParser.ets`（430 行）、`WeekParser.ets`（152 行）。它们是**另一套更早的实现**，与 Kotlin 版有多处不一致，移植时要么按本报告 1:1 重写，要么逐条对齐：

| 维度 | Kotlin 版（本报告） | 现有 ArkTS 版 |
|---|---|---|
| 标签识别 | `LABEL_REGEX` 在**行内任意位置**匹配，21 个标签，**必须带冒号** | `LABEL_REGEX = /^\s*(周数\|周次\|上课地点\|地点\|教室\|教师\|老师\|学分\|校区\|上课时间\|教学班\|分组)\s*[：:]/` —— **要求行首**、标签集合更小 |
| 卡片名 | 取"第一个标签之前"的整段 | 扫描各行，取**第一个非标签行** |
| 名/师拆分 | 无例外词表（§12） | 有 `isNameWord()` 例外词表（`概论\|原理\|基础\|教程\|…`）——**应保留** |
| 教师清洗 | 去括号 + `take(20)`，不拆多人 | 去括号 + **只取第一个**（按 `,，、;；空白` 切） |
| 周次 | 只按 `, ， 、 ; ；` 切；单/双**只作用于区间** | 还按**空白**切；先剥 `第/周/括号/单双`；单双**两个分支都生效**；`inferRange` 有"恰好等于区间内全部单/双周"的判定 |
| 空周次兜底 | `startWeek=endWeek=1` | `startWeek=1, endWeek=16` |
| 策略 | ①②③④（列表 / 有表头表格 / 无表头表格 / div 兜底） | 只有 ①列表 ②表格；**没有表格就直接返回失败** |
| HTML 解析 | Jsoup + **rowspan/colspan 矩形展开** | 手写正则；**只补 colspan，没有 rowspan**；`/<table[\s\S]*?<\/table>/` 遇嵌套表会截断；`<(td|th)…>([\s\S]*?)<\/\1>` 遇嵌套同标签会提前结束 |
| 列表视图定位 | 表头行找 `星期`+`节次` 列号 | 取"该行前 3 个非空单元格"（rowspan 行会失败） |
| 学期/当前周 | 3 个正则（含 `2026-2027-1`），返回 `String?`/`Int?` | 2 个正则（`学年…学期`、`-1`），返回 `''`/`-1` |
| 失败诊断 | 有（含表格数量与排查提示） | 有（文案不同） |

**给 Lead 的建议**：`HtmlTable.ets` 必须先补 rowspan 展开（或改为一比一移植 `expandTable`），否则真实 GLTU 页面上"一个时段两张卡片"的场景必然丢一半；`WeekParser.parse` 需要把"单双只作用于区间"与"空周次兜底"按 §6/§13 对齐。

---

## 16. 官方测试反映的行为契约（`app/src/test/.../WebTimetableParserTest.kt`）

移植后应能通过这些断言（等价于验收标准）：

1. GLTU 列表视图（3 列表 + `rowspan=2` + 富文本卡片）：`parse` 出 **3 门课**；周一 1-2 节有 **2 张卡片**（同一时段不同教室）。
   - 第 1 张：`name="中华民族共同体概论"`（去掉尾部 `*`）、`teacher="文娟"`（去掉 `(讲师)`）、`location="雁山校区 1226（阶4教室）"`、`credit=2.0`、`day=MONDAY`、节次 1-2。
   - `weeks == [4,5,8,11,13,14,15,16]`、`startWeek=4`、`endWeek=16`、`weeksText == "4-5周,8周,11-13周(单),14-16周"`（**原样保留**）。
   - 第 2 张：`weeks == [6,7,9,10,12]`，`location` 含 `虚拟教室009`。
2. 强智表格视图（节次行 + 星期列 + `<div>` 单元格）：3 门课；`高等数学` → 周一 1-2 节、1..16 周、地点含 `明德楼`（**注意：`name` 实际是 `高等数学(分组A)`、`teacher` 由括号兜底得到 `张三`**）。
3. 通用表格视图（表头 `时间 + 周一…周日`，单元格用 `<br>` 分行）：2 门课；`护理学基础` → 周一 1-2 节、`endWeek=16`、`teacher="赵六"`；`生理学(单周)` → 周三。
4. `guessSemester`：`2026-2027学年第1学期` / `2026-2027学年第一学期` / `2026-2027 第2学期` → 分别是 `2026-2027 第1学期` / `2026-2027 第1学期` / `2026-2027 第2学期`；无关页面 → `null`。
5. `guessCurrentWeek`：`当前第6周` → 6；`周数：4-5周,8周` → `null`。
6. 非课表页（`<p>请先登录</p>`）→ `courses` 为空且 `note` 含"课表"。
