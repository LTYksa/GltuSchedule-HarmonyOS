/**
 * GltuSchedule · 鸿蒙版 —— 轻量 HTML 解析器（替代 Android 版依赖的 Jsoup）
 *
 * 为什么不用正则：真实教务页面里 <table> 会嵌套、rowspan/colspan 混用、
 * 单元格里还有富文本卡片，正则遇到嵌套就会截断，所以这里手写一棵 DOM 树。
 *
 * 对齐 Jsoup 的关键语义（Android 版 WebTimetableParser.kt 依赖它们）：
 *  1. 只取顶层 table（排除课程卡片里嵌套的小表）；
 *  2. directRows 认「直接子 tr」与「直接子 tbody/thead/tfoot 里的直接 tr」；
 *  3. expandTable 把 rowspan/colspan 展开成矩形网格，**被覆盖的格子放同一个元素引用**
 *     （不是空串）——真实 GLTU 列表页把「星期一 / 1-2」写成 rowspan=2，
 *     每个物理行各带一个信息格，只有复用引用，两行才都能读到星期与节次；
 *  4. text()：折叠空白（含 &nbsp; 解出来的 \u00a0）、块级元素与 <br> 的边界补一个空格、
 *     跳过 script/style 内容（Jsoup 的 DataNode）；
 *  5. cellLines()：等价于 Kotlin 的 cell.html() → 把 <br> 与块级标签边界换成哨兵
 *     → Jsoup.parse(...).text() → 按哨兵切分；这里直接在树上行走，语义一致且更稳；
 *  6. 实体解码是**单趟**扫描：`&amp;nbsp;` → `&nbsp;`（不会二次解码成空格），
 *     `&nbsp;` → \u00a0（随后被 text() 按空白折叠成普通空格，与 Jsoup 一致）。
 *
 * 同时保留旧版 HtmlTable 的公开 API（cellText / decodeEntities / extractTables /
 * extractRows / looksLikeTimetable），已有调用方不需要改。
 */

/** HTML 节点（基类） */
export class HtmlNode {
  /** 父元素；根节点的 parent 为 undefined */
  parent: HtmlElement | undefined = undefined;
}

/** 文本节点 */
export class HtmlText extends HtmlNode {
  text: string = '';
  /** script / style 的内容（Jsoup 里是 DataNode，text() 不会带进来） */
  isData: boolean = false;

  constructor(text: string) {
    super();
    this.text = text;
  }
}

/** 元素节点 */
export class HtmlElement extends HtmlNode {
  tag: string = '';
  attrs: Map<string, string> = new Map<string, string>();
  children: HtmlNode[] = [];

  constructor(tag: string) {
    super();
    this.tag = tag;
  }

  /** 属性值；没有该属性返回 ''（等价 Jsoup 的 attr() 缺省空串） */
  attr(name: string): string {
    const v: string | undefined = this.attrs.get(name);
    if (v === undefined) {
      return '';
    }
    return v;
  }

  /** 所有后代里 tag 相同的元素（文档顺序，不含自己） */
  descendants(tag: string): HtmlElement[] {
    const out: HtmlElement[] = [];
    const kids: HtmlNode[] = this.children;
    for (let i = 0; i < kids.length; i++) {
      const c: HtmlNode = kids[i];
      if (c instanceof HtmlElement) {
        const e: HtmlElement = c as HtmlElement;
        if (e.tag === tag) {
          out.push(e);
        }
        const deeper: HtmlElement[] = e.descendants(tag);
        for (let j = 0; j < deeper.length; j++) {
          out.push(deeper[j]);
        }
      }
    }
    return out;
  }

  /** 所有后代里 tag 属于 tags 的元素（文档顺序，不含自己） */
  descendantsAny(tags: string[]): HtmlElement[] {
    const out: HtmlElement[] = [];
    const kids: HtmlNode[] = this.children;
    for (let i = 0; i < kids.length; i++) {
      const c: HtmlNode = kids[i];
      if (c instanceof HtmlElement) {
        const e: HtmlElement = c as HtmlElement;
        if (tags.indexOf(e.tag) >= 0) {
          out.push(e);
        }
        const deeper: HtmlElement[] = e.descendantsAny(tags);
        for (let j = 0; j < deeper.length; j++) {
          out.push(deeper[j]);
        }
      }
    }
    return out;
  }

  /** Jsoup 风格的纯文本（折叠空白、块级边界与 <br> 补空格、跳过 script/style） */
  text(): string {
    return HtmlTable.textOf(this);
  }
}

export class HtmlTable {

  // =====================================================================
  // 实体与空白
  // =====================================================================

  private static entityMap: Map<string, string> | undefined = undefined;

  private static entities(): Map<string, string> {
    const cached: Map<string, string> | undefined = HtmlTable.entityMap;
    if (cached !== undefined) {
      return cached;
    }
    const m: Map<string, string> = new Map<string, string>();
    m.set('nbsp', '\u00a0');
    m.set('lt', '<');
    m.set('gt', '>');
    m.set('quot', '"');
    m.set('apos', '\'');
    m.set('amp', '&');
    m.set('ldquo', '\u201c');
    m.set('rdquo', '\u201d');
    m.set('lsquo', '\u2018');
    m.set('rsquo', '\u2019');
    m.set('mdash', '\u2014');
    m.set('ndash', '\u2013');
    m.set('hellip', '\u2026');
    m.set('middot', '\u00b7');
    m.set('times', '\u00d7');
    m.set('divide', '\u00f7');
    m.set('laquo', '\u00ab');
    m.set('raquo', '\u00bb');
    m.set('bull', '\u2022');
    m.set('copy', '\u00a9');
    m.set('reg', '\u00ae');
    m.set('trade', '\u2122');
    m.set('deg', '\u00b0');
    m.set('plusmn', '\u00b1');
    m.set('sect', '\u00a7');
    m.set('para', '\u00b6');
    m.set('dagger', '\u2020');
    m.set('permil', '\u2030');
    m.set('prime', '\u2032');
    m.set('ensp', '\u2002');
    m.set('emsp', '\u2003');
    m.set('thinsp', '\u2009');
    m.set('shy', '\u00ad');
    m.set('iexcl', '\u00a1');
    m.set('cent', '\u00a2');
    m.set('pound', '\u00a3');
    m.set('curren', '\u00a4');
    m.set('yen', '\u00a5');
    m.set('brvbar', '\u00a6');
    m.set('uml', '\u00a8');
    m.set('not', '\u00ac');
    m.set('macr', '\u00af');
    m.set('acute', '\u00b4');
    m.set('micro', '\u00b5');
    m.set('cedil', '\u00b8');
    m.set('ordf', '\u00aa');
    m.set('ordm', '\u00ba');
    m.set('frac12', '\u00bd');
    m.set('frac14', '\u00bc');
    m.set('frac34', '\u00be');
    m.set('sup2', '\u00b2');
    m.set('sup3', '\u00b3');
    m.set('iquest', '\u00bf');
    m.set('euro', '\u20ac');
    HtmlTable.entityMap = m;
    return m;
  }

  /**
   * 解码 HTML 实体。
   * 单趟扫描（和 Jsoup 一致）：`&amp;nbsp;` 解成字面量 `&nbsp;` 而不是空格。
   */
  static decodeEntities(s: string): string {
    if (s === undefined || s === null || s.length === 0) {
      return s;
    }
    return s.replace(/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g,
      (m: string, name: string): string => {
        if (name.length > 1 && name.charAt(0) === '#') {
          let code: number = -1;
          if (name.charAt(1) === 'x' || name.charAt(1) === 'X') {
            code = parseInt(name.substring(2), 16);
          } else {
            code = parseInt(name.substring(1), 10);
          }
          if (isNaN(code) || code <= 0) {
            return m;
          }
          return String.fromCharCode(code);
        }
        const v: string | undefined = HtmlTable.entities().get(name.toLowerCase());
        if (v === undefined) {
          return m;
        }
        return v;
      });
  }

  /** Kotlin 的 String.isBlank()：全空白（含 \u00a0）算空 */
  static isBlank(s: string): boolean {
    if (s === undefined || s === null || s.length === 0) {
      return true;
    }
    return /^[\s\u0085\u001c-\u001f]*$/.test(s);
  }

  /**
   * 是否是"折叠后算空白"的字符。
   * Jsoup 归一空白时把 \u00a0 也当空白（`&nbsp;` 折叠成普通空格），这里保持一致。
   */
  private static isWsChar(c: string): boolean {
    return c === ' ' || c === '\t' || c === '\n' || c === '\r'
      || c === '\f' || c === '\u000b' || c === '\u00a0';
  }

  /** Jsoup 视为"不可见"的字符（零宽空格、软连字符） */
  private static isInvisibleChar(c: string): boolean {
    return c === '\u200b' || c === '\u200c' || c === '\u200d' || c === '\u00ad';
  }

  // =====================================================================
  // HTML → DOM 树
  // =====================================================================

  /** 解析 HTML，返回根元素（tag 为 '#root'） */
  static parse(html: string): HtmlElement {
    const root: HtmlElement = new HtmlElement('#root');
    if (html === undefined || html === null || html.length === 0) {
      return root;
    }
    HtmlTable.parseInto(html, root);
    return root;
  }

  /** 把纯文本（\n 分行）包成一个元素，等价于"一格多行"的单元格（旧 API 兼容用） */
  static fromText(text: string): HtmlElement {
    const el: HtmlElement = new HtmlElement('#text');
    if (text === undefined || text === null || text.length === 0) {
      return el;
    }
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      if (i > 0) {
        const br: HtmlElement = new HtmlElement('br');
        br.parent = el;
        el.children.push(br);
      }
      const t: HtmlText = new HtmlText(lines[i]);
      t.parent = el;
      el.children.push(t);
    }
    return el;
  }

  private static parseInto(html: string, root: HtmlElement): void {
    const n: number = html.length;
    let current: HtmlElement = root;
    let pos: number = 0;
    let textStart: number = 0;

    while (pos < n) {
      const lt: number = html.indexOf('<', pos);
      if (lt < 0) {
        break;
      }
      // <!-- 注释 -->
      if (html.substring(lt, lt + 4) === '<!--') {
        HtmlTable.addTextNode(current, html.substring(textStart, lt));
        const end: number = html.indexOf('-->', lt + 4);
        if (end < 0) {
          return;
        }
        pos = end + 3;
        textStart = pos;
        continue;
      }
      // <!DOCTYPE ...> / <?xml ...>
      const next: string = html.charAt(lt + 1);
      if (next === '!' || next === '?') {
        HtmlTable.addTextNode(current, html.substring(textStart, lt));
        const end: number = html.indexOf('>', lt + 2);
        if (end < 0) {
          return;
        }
        pos = end + 1;
        textStart = pos;
        continue;
      }
      const isEnd: boolean = next === '/';
      const nameStart: number = isEnd ? lt + 2 : lt + 1;
      let j: number = nameStart;
      while (j < n && HtmlTable.isTagNameChar(html.charAt(j))) {
        j++;
      }
      const name: string = html.substring(nameStart, j).toLowerCase();
      if (name.length === 0) {
        // 孤立的 '<'，当普通文本，继续往后找
        pos = lt + 1;
        continue;
      }
      const tagEnd: number = HtmlTable.findTagEnd(html, j);
      if (tagEnd < 0) {
        break;
      }
      const attrText: string = html.substring(j, tagEnd);
      const selfClosing: boolean = attrText.length > 0
        && attrText.charAt(attrText.length - 1) === '/';
      HtmlTable.addTextNode(current, html.substring(textStart, lt));
      if (isEnd) {
        current = HtmlTable.closeTag(current, root, name);
        pos = tagEnd + 1;
        textStart = pos;
        continue;
      }
      const attrs: Map<string, string> = HtmlTable.parseAttrs(attrText);
      current = HtmlTable.openTag(current, root, name, attrs, selfClosing);
      pos = tagEnd + 1;
      textStart = pos;
      // script / style：内容当原始数据（Jsoup 的 DataNode），text() 不带进来
      if (name === 'script' || name === 'style') {
        const closeIdx: number = HtmlTable.indexOfCloseTag(html, pos, name);
        if (closeIdx < 0) {
          HtmlTable.addTextNode(current, html.substring(pos), true);
          return;
        }
        HtmlTable.addTextNode(current, html.substring(pos, closeIdx), true);
        pos = closeIdx + name.length + 3; // "</" + name + ">"
        textStart = pos;
        current = HtmlTable.closeTag(current, root, name);
      }
    }
    if (textStart < n) {
      HtmlTable.addTextNode(current, html.substring(textStart, n));
    }
  }

  private static addTextNode(el: HtmlElement, text: string, isData: boolean = false): void {
    if (text.length === 0) {
      return;
    }
    const t: HtmlText = new HtmlText(isData ? text : HtmlTable.decodeEntities(text));
    t.isData = isData;
    t.parent = el;
    el.children.push(t);
  }

  private static isTagNameChar(c: string): boolean {
    return /[a-zA-Z0-9:_\-]/.test(c);
  }

  /** 找标签结束的 '>'（跳过引号里的内容） */
  private static findTagEnd(html: string, from: number): number {
    let i: number = from;
    let quote: string = '';
    while (i < html.length) {
      const c: string = html.charAt(i);
      if (quote.length > 0) {
        if (c === quote) {
          quote = '';
        }
      } else if (c === '"' || c === '\'') {
        quote = c;
      } else if (c === '>') {
        return i;
      }
      i++;
    }
    return -1;
  }

  /** 解析属性串（已去掉标签名与收尾的 '>'） */
  private static parseAttrs(s: string): Map<string, string> {
    const attrs: Map<string, string> = new Map<string, string>();
    const n: number = s.length;
    let i: number = 0;
    while (i < n) {
      while (i < n && (HtmlTable.isAsciiWs(s.charAt(i)) || s.charAt(i) === '/')) {
        i++;
      }
      if (i >= n) {
        break;
      }
      const nameStart: number = i;
      while (i < n && !HtmlTable.isAsciiWs(s.charAt(i))
        && s.charAt(i) !== '=' && s.charAt(i) !== '/') {
        i++;
      }
      const name: string = s.substring(nameStart, i).toLowerCase();
      while (i < n && HtmlTable.isAsciiWs(s.charAt(i))) {
        i++;
      }
      let value: string = '';
      if (i < n && s.charAt(i) === '=') {
        i++;
        while (i < n && HtmlTable.isAsciiWs(s.charAt(i))) {
          i++;
        }
        if (i < n && (s.charAt(i) === '"' || s.charAt(i) === '\'')) {
          const quote: string = s.charAt(i);
          i++;
          const valStart: number = i;
          while (i < n && s.charAt(i) !== quote) {
            i++;
          }
          value = s.substring(valStart, i);
          if (i < n) {
            i++;
          }
        } else {
          const valStart: number = i;
          while (i < n && !HtmlTable.isAsciiWs(s.charAt(i))) {
            i++;
          }
          value = s.substring(valStart, i);
        }
      }
      if (name.length > 0 && !attrs.has(name)) {
        attrs.set(name, HtmlTable.decodeEntities(value));
      }
    }
    return attrs;
  }

  private static isAsciiWs(c: string): boolean {
    return c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f' || c === '\u000b';
  }

  private static isVoidTag(tag: string): boolean {
    return tag === 'area' || tag === 'base' || tag === 'br' || tag === 'col'
      || tag === 'embed' || tag === 'hr' || tag === 'img' || tag === 'input'
      || tag === 'link' || tag === 'meta' || tag === 'param' || tag === 'source'
      || tag === 'track' || tag === 'wbr';
  }

  /** Jsoup 里 isBlock() 的标签（影响 text() 的空格与 <p> 的隐式闭合） */
  private static isBlockTag(tag: string): boolean {
    switch (tag) {
      case 'html': case 'head': case 'body': case 'frameset':
      case 'script': case 'noscript': case 'style': case 'meta': case 'link':
      case 'title': case 'frame': case 'noframes':
      case 'section': case 'nav': case 'aside': case 'hgroup':
      case 'header': case 'footer': case 'p':
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
      case 'ul': case 'ol': case 'pre': case 'div': case 'blockquote':
      case 'hr': case 'address': case 'figure': case 'figcaption':
      case 'form': case 'fieldset': case 'ins': case 'del': case 's':
      case 'dl': case 'dt': case 'dd': case 'li':
      case 'table': case 'caption': case 'thead': case 'tfoot': case 'tbody':
      case 'colgroup': case 'col': case 'tr': case 'th': case 'td':
      case 'video': case 'audio': case 'canvas': case 'details': case 'menu':
      case 'plaintext': case 'template': case 'article': case 'main':
      case 'svg': case 'math': case 'center': case 'dir':
      case 'optgroup': case 'option': case 'select':
      case 'iframe': case 'object': case 'applet': case 'marquee':
      case 'xmp': case 'listing': case 'summary':
        return true;
      default:
        return false;
    }
  }

  /**
   * Kotlin 版 cellLines 里会被替换成"换行哨兵"的标签：
   * `</(div|p|li|tr|h[1-6]|table)>` 与 `<(div|p|li|tr|h[1-6]|table)[^>]*>`。
   */
  private static isLineBreakTag(tag: string): boolean {
    if (tag === 'div' || tag === 'p' || tag === 'li' || tag === 'tr' || tag === 'table') {
      return true;
    }
    return tag === 'h1' || tag === 'h2' || tag === 'h3'
      || tag === 'h4' || tag === 'h5' || tag === 'h6';
  }

  private static parentOf(el: HtmlElement, root: HtmlElement): HtmlElement {
    const p: HtmlElement | undefined = el.parent;
    if (p === undefined) {
      return root;
    }
    return p;
  }

  /** 起始标签的隐式闭合规则（够用即可：p / li / dt+dd / option / 表格结构） */
  private static autoClose(current: HtmlElement, root: HtmlElement, name: string): HtmlElement {
    let el: HtmlElement = current;
    if (HtmlTable.isBlockTag(name) && el.tag === 'p') {
      el = HtmlTable.parentOf(el, root);
    }
    if (name === 'li' && el.tag === 'li') {
      el = HtmlTable.parentOf(el, root);
    }
    if ((name === 'dt' || name === 'dd') && (el.tag === 'dt' || el.tag === 'dd')) {
      el = HtmlTable.parentOf(el, root);
    }
    if (name === 'option' && el.tag === 'option') {
      el = HtmlTable.parentOf(el, root);
    }
    if (name === 'td' || name === 'th' || name === 'tr'
      || name === 'tbody' || name === 'thead' || name === 'tfoot') {
      while (el.tag === 'td' || el.tag === 'th') {
        el = HtmlTable.parentOf(el, root);
      }
      if ((name === 'tr' || name === 'tbody' || name === 'thead' || name === 'tfoot')
        && el.tag === 'tr') {
        el = HtmlTable.parentOf(el, root);
      }
      if ((name === 'tbody' || name === 'thead' || name === 'tfoot')
        && (el.tag === 'tbody' || el.tag === 'thead' || el.tag === 'tfoot')) {
        el = HtmlTable.parentOf(el, root);
      }
    }
    return el;
  }

  private static openTag(current: HtmlElement, root: HtmlElement, name: string,
    attrs: Map<string, string>, selfClosing: boolean): HtmlElement {
    const parent: HtmlElement = HtmlTable.autoClose(current, root, name);
    const child: HtmlElement = new HtmlElement(name);
    child.attrs = attrs;
    child.parent = parent;
    parent.children.push(child);
    if (selfClosing || HtmlTable.isVoidTag(name)) {
      return parent;
    }
    return child;
  }

  /** 结束标签：往上找到同名元素并闭合；找不到就忽略 */
  private static closeTag(current: HtmlElement, root: HtmlElement, name: string): HtmlElement {
    let el: HtmlElement = current;
    while (el !== root && el.tag !== name) {
      el = HtmlTable.parentOf(el, root);
    }
    if (el.tag !== name) {
      return current;
    }
    return HtmlTable.parentOf(el, root);
  }

  /**
   * 找 `</name` 的位置（大小写不敏感，且要求标签名后面是分隔符）。
   * 直接扫原串而不是 `html.toLowerCase()`，避免 toLowerCase 改变长度时下标错位。
   */
  private static indexOfCloseTag(html: string, from: number, name: string): number {
    const needle: string = '</' + name;
    const n: number = html.length;
    let i: number = from;
    while (i <= n - needle.length) {
      if (html.charAt(i) === '<' && html.charAt(i + 1) === '/') {
        let k: number = 2;
        let matched: boolean = true;
        while (k < needle.length) {
          if (html.charAt(i + k).toLowerCase() !== needle.charAt(k)) {
            matched = false;
            break;
          }
          k++;
        }
        if (matched) {
          const after: string = i + needle.length < n ? html.charAt(i + needle.length) : '>';
          if (after === '>' || after === '/' || after === ' ' || after === '\t'
            || after === '\n' || after === '\r' || after === '\f') {
            return i;
          }
        }
      }
      i++;
    }
    return -1;
  }

  // =====================================================================
  // text() / cellLines()
  // =====================================================================

  /** 保证 out 的最后一个元素是"当前行"（行模型：out 里每项是一行的内容） */
  private static ensureLine(out: string[]): void {
    if (out.length === 0) {
      out.push('');
      return;
    }
    if (out[out.length - 1].length > 0) {
      out.push('');
    }
  }

  private static appendRaw(out: string[], s: string): void {
    if (out.length === 0) {
      out.push(s);
      return;
    }
    out[out.length - 1] = out[out.length - 1] + s;
  }

  private static lineHasContent(out: string[]): boolean {
    return out.length > 0 && out[out.length - 1].length > 0;
  }

  private static lineEndsWithWs(out: string[]): boolean {
    if (out.length === 0) {
      return true;
    }
    const s: string = out[out.length - 1];
    if (s.length === 0) {
      return true;
    }
    return HtmlTable.isWsChar(s.charAt(s.length - 1));
  }

  private static nextSiblingIsText(kids: HtmlNode[], i: number): boolean {
    return i + 1 < kids.length && kids[i + 1] instanceof HtmlText;
  }

  /** Jsoup 的 appendNormalisedWhitespace：空白折叠成单个空格，跳过不可见字符 */
  private static appendNormalizedCore(s: string, text: string): string {
    let out: string = s;
    let lastWasWhite: boolean = out.length === 0
      ? true : HtmlTable.isWsChar(out.charAt(out.length - 1));
    for (let i = 0; i < text.length; i++) {
      const c: string = text.charAt(i);
      if (HtmlTable.isWsChar(c)) {
        if (lastWasWhite) {
          continue;
        }
        out = out + ' ';
        lastWasWhite = true;
      } else if (HtmlTable.isInvisibleChar(c)) {
        continue;
      } else {
        out = out + c;
        lastWasWhite = false;
      }
    }
    return out;
  }

  /** 追加到"当前行"（cellLines 的行模型：out 的最后一项就是当前行） */
  private static appendNormalizedToLine(out: string[], text: string): void {
    HtmlTable.ensureLine(out);
    const idx: number = out.length - 1;
    out[idx] = HtmlTable.appendNormalizedCore(out[idx], text);
  }

  /** 追加到"单行累加器"（text() 用：整棵子树合成一段文本，不能换行） */
  private static appendNormalizedToText(out: string[], text: string): void {
    if (out.length === 0) {
      out.push('');
    }
    out[0] = HtmlTable.appendNormalizedCore(out[0], text);
  }

  /** 往单行累加器里直接塞一段字符（补空格用） */
  private static appendRawToText(out: string[], s: string): void {
    if (out.length === 0) {
      out.push(s);
      return;
    }
    out[0] = out[0] + s;
  }

  /** Element.text() 的遍历：块级元素（含 br）边界补一个空格 */
  private static collectText(el: HtmlElement, out: string[]): void {
    const kids: HtmlNode[] = el.children;
    for (let i = 0; i < kids.length; i++) {
      const child: HtmlNode = kids[i];
      if (child instanceof HtmlText) {
        const t: HtmlText = child as HtmlText;
        if (!t.isData) {
          HtmlTable.appendNormalizedToText(out, t.text);
        }
        continue;
      }
      const e: HtmlElement = child as HtmlElement;
      const block: boolean = HtmlTable.isBlockTag(e.tag) || e.tag === 'br';
      if (block && HtmlTable.lineHasContent(out) && !HtmlTable.lineEndsWithWs(out)) {
        HtmlTable.appendRawToText(out, ' ');
      }
      HtmlTable.collectText(e, out);
      if (HtmlTable.isBlockTag(e.tag) && HtmlTable.nextSiblingIsText(kids, i)
        && HtmlTable.lineHasContent(out) && !HtmlTable.lineEndsWithWs(out)) {
        HtmlTable.appendRawToText(out, ' ');
      }
    }
  }

  static textOf(el: HtmlElement): string {
    const acc: string[] = [];
    HtmlTable.collectText(el, acc);
    if (acc.length === 0) {
      return '';
    }
    return acc[0].trim();
  }

  /** cellLines 的遍历：<br> 与块级标签（div/p/li/tr/h1-6/table）的边界断行 */
  private static collectLines(el: HtmlElement, out: string[]): void {
    const kids: HtmlNode[] = el.children;
    for (let i = 0; i < kids.length; i++) {
      const child: HtmlNode = kids[i];
      if (child instanceof HtmlText) {
        const t: HtmlText = child as HtmlText;
        if (!t.isData) {
          HtmlTable.appendNormalizedToLine(out, t.text);
        }
        continue;
      }
      const e: HtmlElement = child as HtmlElement;
      const brk: boolean = e.tag === 'br' || HtmlTable.isLineBreakTag(e.tag);
      if (brk) {
        HtmlTable.ensureLine(out);
      }
      if (e.tag !== 'br') {
        // 不在断行名单里的块级标签（ul / td / section…）按 Jsoup 规则补空格
        const spacedBlock: boolean = !HtmlTable.isLineBreakTag(e.tag)
          && HtmlTable.isBlockTag(e.tag);
        if (spacedBlock && HtmlTable.lineHasContent(out) && !HtmlTable.lineEndsWithWs(out)) {
          HtmlTable.appendRaw(out, ' ');
        }
        HtmlTable.collectLines(e, out);
        if (spacedBlock && HtmlTable.nextSiblingIsText(kids, i)
          && HtmlTable.lineHasContent(out) && !HtmlTable.lineEndsWithWs(out)) {
          HtmlTable.appendRaw(out, ' ');
        }
      }
      if (brk) {
        HtmlTable.ensureLine(out);
      }
    }
  }

  /**
   * 保留行结构的单元格文本行。
   * 等价 Kotlin：`cell.html()` 把 <br> / 块级标签边界换成哨兵 → `Jsoup.parse().text()` → 按哨兵切分
   * → 每行 trim → 去空行。
   */
  static cellLines(cell: HtmlElement): string[] {
    const raw: string[] = [];
    HtmlTable.collectLines(cell, raw);
    const out: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      const t: string = raw[i].trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  // =====================================================================
  // 表格 → 网格
  // =====================================================================

  /** 只取顶层 table（排除嵌套在别的 table 里的表） */
  static directTables(root: HtmlElement): HtmlElement[] {
    const all: HtmlElement[] = root.descendants('table');
    const out: HtmlElement[] = [];
    for (let i = 0; i < all.length; i++) {
      if (!HtmlTable.hasTableAncestor(all[i])) {
        out.push(all[i]);
      }
    }
    return out;
  }

  private static hasTableAncestor(el: HtmlElement): boolean {
    let p: HtmlElement | undefined = el.parent;
    while (p !== undefined) {
      if (p.tag === 'table') {
        return true;
      }
      p = p.parent;
    }
    return false;
  }

  /** 直接子 tr，或直接子 tbody/thead/tfoot 的直接子 tr（等价 Jsoup 自动补 tbody 后的行为） */
  static directRows(table: HtmlElement): HtmlElement[] {
    const rows: HtmlElement[] = [];
    const kids: HtmlNode[] = table.children;
    for (let i = 0; i < kids.length; i++) {
      const c: HtmlNode = kids[i];
      if (!(c instanceof HtmlElement)) {
        continue;
      }
      const e: HtmlElement = c as HtmlElement;
      if (e.tag === 'tr') {
        rows.push(e);
        continue;
      }
      if (e.tag === 'tbody' || e.tag === 'thead' || e.tag === 'tfoot') {
        const gk: HtmlNode[] = e.children;
        for (let j = 0; j < gk.length; j++) {
          const g: HtmlNode = gk[j];
          if (g instanceof HtmlElement) {
            const ge: HtmlElement = g as HtmlElement;
            if (ge.tag === 'tr') {
              rows.push(ge);
            }
          }
        }
      }
    }
    return rows;
  }

  /** 行里的直接 td / th */
  static directCells(row: HtmlElement): HtmlElement[] {
    const cells: HtmlElement[] = [];
    const kids: HtmlNode[] = row.children;
    for (let i = 0; i < kids.length; i++) {
      const c: HtmlNode = kids[i];
      if (c instanceof HtmlElement) {
        const e: HtmlElement = c as HtmlElement;
        if (e.tag === 'td' || e.tag === 'th') {
          cells.push(e);
        }
      }
    }
    return cells;
  }

  /** rowspan / colspan：缺省或非数字 → 1，越界钳制（rowspan 1..200，colspan 1..20） */
  private static spanAttr(cell: HtmlElement, name: string, max: number): number {
    const raw: string = cell.attr(name);
    if (raw.length === 0) {
      return 1;
    }
    const v: number = parseInt(raw, 10);
    if (isNaN(v)) {
      return 1;
    }
    if (v < 1) {
      return 1;
    }
    if (v > max) {
      return max;
    }
    return v;
  }

  /**
   * 把表格展开成矩形网格（等价 Kotlin 版 expandTable）。
   * 被 rowspan/colspan 覆盖的格子放的是**同一个元素引用**，不是 undefined，
   * 所以带 rowspan 的「星期一 / 1-2」在它覆盖的每一行都能读到。
   * 行长度可能参差不齐（某行格子少 → 该行数组短），取值前要自己判边界。
   */
  static expandTable(table: HtmlElement): (HtmlElement | undefined)[][] {
    const grid: (HtmlElement | undefined)[][] = [];
    const rows: HtmlElement[] = HtmlTable.directRows(table);
    if (rows.length === 0) {
      return grid;
    }
    for (let rIdx = 0; rIdx < rows.length; rIdx++) {
      while (grid.length <= rIdx) {
        const empty: (HtmlElement | undefined)[] = [];
        grid.push(empty);
      }
      let cIdx: number = 0;
      const cells: HtmlElement[] = HtmlTable.directCells(rows[rIdx]);
      for (let ci = 0; ci < cells.length; ci++) {
        const cell: HtmlElement = cells[ci];
        // 跳过已被上方 rowspan 占用的位置
        while (cIdx < grid[rIdx].length && grid[rIdx][cIdx] !== undefined) {
          cIdx++;
        }
        const rowspan: number = HtmlTable.spanAttr(cell, 'rowspan', 200);
        const colspan: number = HtmlTable.spanAttr(cell, 'colspan', 20);
        for (let dr = 0; dr < rowspan; dr++) {
          const rr: number = rIdx + dr;
          while (grid.length <= rr) {
            const empty: (HtmlElement | undefined)[] = [];
            grid.push(empty);
          }
          for (let dc = 0; dc < colspan; dc++) {
            const cc: number = cIdx + dc;
            while (grid[rr].length <= cc) {
              grid[rr].push(undefined);
            }
            grid[rr][cc] = cell;
          }
        }
        cIdx += colspan;
      }
    }
    return grid;
  }

  // =====================================================================
  // 旧版公开 API（保持兼容）
  // =====================================================================

  /** 去掉标签后的纯文本；<br> 与块级标签边界转成换行，行内空白折叠 */
  static cellText(html: string): string {
    if (html === undefined || html === null || html.length === 0) {
      return '';
    }
    const root: HtmlElement = HtmlTable.parse(html);
    const lines: string[] = [];
    HtmlTable.collectLines(root, lines);
    const out: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out.join('\n');
  }

  /** 抽出所有顶层表格：[表][行][列]；被 rowspan/colspan 覆盖的位置复用同一内容 */
  static extractTables(html: string): string[][][] {
    const result: string[][][] = [];
    if (html === undefined || html === null || html.length === 0) {
      return result;
    }
    const root: HtmlElement = HtmlTable.parse(html);
    const tables: HtmlElement[] = HtmlTable.directTables(root);
    for (let i = 0; i < tables.length; i++) {
      const rows: string[][] = HtmlTable.gridToText(HtmlTable.expandTable(tables[i]));
      if (rows.length > 0) {
        result.push(rows);
      }
    }
    return result;
  }

  /** 单个表格的行列结构（取片段里第一个顶层表格） */
  static extractRows(tableHtml: string): string[][] {
    if (tableHtml === undefined || tableHtml === null || tableHtml.length === 0) {
      return [];
    }
    const root: HtmlElement = HtmlTable.parse(tableHtml);
    const tables: HtmlElement[] = HtmlTable.directTables(root);
    if (tables.length === 0) {
      return [];
    }
    return HtmlTable.gridToText(HtmlTable.expandTable(tables[0]));
  }

  private static gridToText(grid: (HtmlElement | undefined)[][]): string[][] {
    const rows: string[][] = [];
    for (let r = 0; r < grid.length; r++) {
      const cells: string[] = [];
      for (let c = 0; c < grid[r].length; c++) {
        const el: HtmlElement | undefined = grid[r][c];
        if (el === undefined) {
          cells.push('');
        } else {
          cells.push(HtmlTable.cellLines(el).join('\n'));
        }
      }
      if (cells.length > 0) {
        rows.push(cells);
      }
    }
    return rows;
  }

  /** 当前是否处于课表页面（导入前的粗判与诊断用） */
  static looksLikeTimetable(html: string): boolean {
    if (html === undefined || html === null) {
      return false;
    }
    const hasWeek: boolean = /周数|周次|第\s*\d+\s*周/.test(html);
    const hasSection: boolean = /节次|第\s*\d+\s*节/.test(html);
    const hasWeekday: boolean = /星期[一二三四五六日天]|周一|周二|周三|周四|周五|周六|周日/.test(html);
    return hasWeek && (hasSection || hasWeekday);
  }
}
