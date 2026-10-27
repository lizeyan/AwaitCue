import type { Evidence, NormalizedRegion } from "./protocol";
import { denormalizeRegion, intersects } from "./region";

const maximumEvidenceMessageBytes = 24 * 1_024;
const maximumTextBytes = 4_000;
const maximumHTMLBytes = 9_000;
const maximumARIABytes = 2_000;
const maximumURLBytes = 2_000;
const maximumTitleBytes = 512;
const maximumAttributeValueBytes = 512;
const ignoredTags = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE"]);
const booleanStateAttributes = new Set([
  "checked",
  "disabled",
  "inert",
  "multiple",
  "open",
  "readonly",
  "required",
  "selected"
]);
const explicitlyPreservedAttributes = new Set([
  "class",
  "role",
  "title",
  "alt",
  "type",
  "name",
  "value",
  "max"
]);
const voidTags = new Set([
  "area",
  "base",
  "br",
  "col",
  "embed",
  "hr",
  "img",
  "input",
  "link",
  "meta",
  "param",
  "source",
  "track",
  "wbr"
]);
const mutationCoalescingMilliseconds = 300;
const textEncoder = new TextEncoder();

type EvidenceRow = Readonly<{ x: number; y: number; text: string }>;
type SanitizedAttribute = Readonly<{ name: string; value?: string }>;
type SanitizedHTMLNode = string | Readonly<{
  tagName: string;
  attributes: SanitizedAttribute[];
  children: SanitizedHTMLNode[];
}>;

/**
 * 从框选区域内提取可见文本和精简 DOM。HTML 只保留帮助模型理解页面语义的属性，
 * 不包含链接、资源地址、事件处理器、样式或浏览器像素。
 */
export function collectEvidence(
  document: Document,
  hookID: string,
  region: NormalizedRegion,
  selectionRegionExpanded = false
): Evidence {
  const pixelRegion = denormalizeRegion(region, document.documentElement.clientWidth, document.documentElement.clientHeight);
  const rows: EvidenceRow[] = [];
  const semanticAttributes = new Set<string>();
  const selectedText = new Map<Node, string>();
  const selectedElements = new Map<Element, DOMRect>();

  // 元素盒可能横跨整页，即使文字实际位于选区外；Range 才能给出文字本身的可见位置。
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode;
    const parent = node.parentElement;
    if (!parent || hasIgnoredAncestor(parent) || !isElementVisible(parent)) continue;
    const text = normalizeText(node.nodeValue ?? "");
    if (!text) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    const rects = [...range.getClientRects()].filter((rect) => intersects(rect, pixelRegion));
    range.detach();
    if (rects.length === 0) continue;
    const rect = rects[0]!;
    selectedText.set(node, text);
    rows.push({
      x: Math.round(rect.left - pixelRegion.x),
      y: Math.round(rect.top - pixelRegion.y),
      text
    });
  }

  for (const element of document.querySelectorAll<HTMLElement>("body *")) {
    if (hasIgnoredAncestor(element) || !isElementVisible(element)) continue;
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0 || !intersects(rect, pixelRegion)) continue;
    selectedElements.set(element, rect);
    for (const attribute of collectPreservedAttributes(element)) {
      if (attribute.name === "class" || attribute.name === "data-awaitcue-rect") continue;
      const semantic = `${attribute.name}:${attribute.value ?? "true"}`;
      semanticAttributes.add(semantic);
      rows.push({
        x: Math.round(rect.left - pixelRegion.x),
        y: Math.round(rect.top - pixelRegion.y),
        text: semantic
      });
    }
  }

  rows.sort((left, right) => Math.abs(left.y - right.y) <= 3 ? left.x - right.x : left.y - right.y);
  const seenRows = new Set<string>();
  const text = truncateUTF8(rows.flatMap((row) => {
    const key = `${row.x}|${row.y}|${row.text}`;
    if (seenRows.has(key)) return [];
    seenRows.add(key);
    return [`[${row.x},${row.y}] ${row.text}`];
  }).join("\n"), maximumTextBytes);
  const ariaValues = fitStringsWithinBytes([...semanticAttributes].sort(), maximumARIABytes);
  const htmlNodes = [...document.body.childNodes].flatMap((node) => {
    const sanitized = buildSanitizedNode(node, selectedText, selectedElements, pixelRegion);
    return sanitized === null ? [] : [sanitized];
  });

  const url = truncateUTF8(document.location.href, maximumURLBytes);
  const title = truncateUTF8(document.title, maximumTitleBytes);
  let htmlBudget = maximumHTMLBytes;
  let html = serializeHTML(htmlNodes, htmlBudget);
  let evidence = makeEvidence({
    hookID,
    url,
    title,
    text,
    aria: ariaValues,
    html,
    selectionRegionExpanded
  });

  // Native Messaging 虽允许更大载荷，但证据会继续进入模型请求；这里硬性限制单条消息，
  // 并通过重新序列化完整标签而不是截断字符串，保证 HTML 始终保持可解析。
  while (encodedBytes(JSON.stringify(evidence)) >= maximumEvidenceMessageBytes && htmlBudget > 0) {
    const overflow = encodedBytes(JSON.stringify(evidence)) - maximumEvidenceMessageBytes;
    htmlBudget = Math.max(0, htmlBudget - Math.max(512, overflow + 256));
    html = serializeHTML(htmlNodes, htmlBudget);
    evidence = makeEvidence({
      hookID,
      url,
      title,
      text,
      aria: ariaValues,
      html,
      selectionRegionExpanded
    });
  }
  return evidence;
}

/**
 * 只在证据指纹变化时通知原生应用，避免 MutationObserver 的高频回调直接放大为模型调用。
 */
export class EvidenceObserver {
  readonly #document: Document;
  readonly #hookID: string;
  readonly #region: NormalizedRegion;
  readonly #onChange: (evidence: Evidence) => void;
  readonly #selectionRegionExpanded: boolean;
  #observer: MutationObserver | null = null;
  #pendingCheck: ReturnType<typeof setTimeout> | null = null;
  #lastFingerprint: string | null = null;

  constructor(
    document: Document,
    hookID: string,
    region: NormalizedRegion,
    onChange: (evidence: Evidence) => void,
    selectionRegionExpanded = false
  ) {
    this.#document = document;
    this.#hookID = hookID;
    this.#region = region;
    this.#onChange = onChange;
    this.#selectionRegionExpanded = selectionRegionExpanded;
  }

  start(): Evidence {
    const initial = collectEvidence(
      this.#document,
      this.#hookID,
      this.#region,
      this.#selectionRegionExpanded
    );
    this.#lastFingerprint = initial.fingerprint;
    this.#observer = new MutationObserver(() => this.scheduleCheck());
    this.#observer.observe(this.#document.documentElement, {
      attributes: true,
      childList: true,
      characterData: true,
      subtree: true
    });
    return initial;
  }

  stop(): void {
    this.#observer?.disconnect();
    this.#observer = null;
    if (this.#pendingCheck !== null) {
      clearTimeout(this.#pendingCheck);
      this.#pendingCheck = null;
    }
  }

  check(): Evidence {
    const evidence = collectEvidence(
      this.#document,
      this.#hookID,
      this.#region,
      this.#selectionRegionExpanded
    );
    if (evidence.fingerprint !== this.#lastFingerprint) {
      this.#lastFingerprint = evidence.fingerprint;
      this.#onChange(evidence);
    }
    return evidence;
  }

  /** 一个页面更新通常产生大量相邻 mutation；同一 300ms 窗口只重新采集一次。 */
  private scheduleCheck(): void {
    if (this.#pendingCheck !== null) return;
    this.#pendingCheck = globalThis.setTimeout(() => {
      this.#pendingCheck = null;
      this.check();
    }, mutationCoalescingMilliseconds);
  }
}

export function fingerprint(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function makeEvidence(input: Readonly<{
  hookID: string;
  url: string;
  title: string;
  text: string;
  aria: string[];
  html: string;
  selectionRegionExpanded: boolean;
}>): Evidence {
  const availability = input.text || input.aria.length > 0 || input.html ? "sufficient" : "insufficient";
  const insufficiencyReason = availability === "insufficient" ? "no_semantic_content" : undefined;
  return {
    hookID: input.hookID,
    url: input.url,
    title: input.title,
    text: input.text,
    aria: input.aria,
    html: input.html,
    availability,
    ...(insufficiencyReason ? { insufficiencyReason } : {}),
    selectionRegionExpanded: input.selectionRegionExpanded,
    fingerprint: fingerprint(
      `${input.url}\n${input.title}\n${availability}\n${input.selectionRegionExpanded}\n${input.text}\n${input.aria.join("\n")}\n${input.html}`
    )
  };
}

function buildSanitizedNode(
  node: Node,
  selectedText: ReadonlyMap<Node, string>,
  selectedElements: ReadonlyMap<Element, DOMRect>,
  pixelRegion: Readonly<{ x: number; y: number; width: number; height: number }>
): SanitizedHTMLNode | null {
  if (node.nodeType === Node.TEXT_NODE) return selectedText.get(node) ?? null;
  if (!(node instanceof Element) || ignoredTags.has(node.tagName)) return null;
  if (!isElementVisible(node as HTMLElement)) return null;

  const children = [...node.childNodes].flatMap((child) => {
    const sanitized = buildSanitizedNode(child, selectedText, selectedElements, pixelRegion);
    return sanitized === null ? [] : [sanitized];
  });
  const rect = selectedElements.get(node);
  // 溢出子元素可能进入选区，而祖先盒本身完全在选区外；只保留祖先标签层级，
  // 不能顺带上传框外祖先的 data-*、ARIA 或 class 属性。
  const attributes = rect ? collectPreservedAttributes(node) : [];
  // 空的布局容器本身没有可供模型判断的内容；有入选子节点时仍保留它，以维持页面层级关系。
  if (!rect && children.length === 0) return null;
  if (rect && attributes.length === 0 && children.length === 0) return null;
  const box = rect ? clippedRelativeBox(rect, pixelRegion) : null;
  return {
    tagName: node.localName,
    attributes: [
      ...(box ? [{ name: "data-awaitcue-rect", value: box }] : []),
      ...attributes
    ],
    children
  };
}

function collectPreservedAttributes(element: Element): SanitizedAttribute[] {
  const attributes: SanitizedAttribute[] = [];
  for (const attribute of element.attributes) {
    const name = attribute.name.toLowerCase();
    if (name === "data-awaitcue-rect") continue;
    if (booleanStateAttributes.has(name)) {
      attributes.push({ name });
      continue;
    }
    if (
      explicitlyPreservedAttributes.has(name)
      || name.startsWith("aria-")
      || name.startsWith("data-")
    ) {
      const value = truncateUTF8(normalizeText(attribute.value), maximumAttributeValueBytes);
      if (value) attributes.push({ name, value });
    }
  }
  return attributes;
}

function clippedRelativeBox(
  rect: DOMRect,
  region: Readonly<{ x: number; y: number; width: number; height: number }>
): string | null {
  const left = Math.max(rect.left, region.x);
  const top = Math.max(rect.top, region.y);
  const right = Math.min(rect.right, region.x + region.width);
  const bottom = Math.min(rect.bottom, region.y + region.height);
  if (right <= left || bottom <= top) return null;
  return [
    Math.round(left - region.x),
    Math.round(top - region.y),
    Math.round(right - left),
    Math.round(bottom - top)
  ].join(",");
}

function serializeHTML(nodes: readonly SanitizedHTMLNode[], maximumBytes: number): string {
  let result = "";
  let remaining = maximumBytes;
  for (const node of nodes) {
    const serialized = serializeNode(node, remaining);
    if (!serialized) continue;
    result += serialized;
    remaining -= encodedBytes(serialized);
    if (remaining <= 0) break;
  }
  return result;
}

function serializeNode(node: SanitizedHTMLNode, maximumBytes: number): string {
  if (maximumBytes <= 0) return "";
  if (typeof node === "string") return escapeTextWithinBytes(node, maximumBytes);

  const closingTag = voidTags.has(node.tagName) ? "" : `</${node.tagName}>`;
  const closingBytes = encodedBytes(closingTag);
  let openingTag = `<${node.tagName}`;
  for (const attribute of node.attributes) {
    const token = attribute.value === undefined
      ? ` ${attribute.name}`
      : ` ${attribute.name}="${escapeAttribute(attribute.value)}"`;
    if (encodedBytes(`${openingTag}${token}>`) + closingBytes > maximumBytes) break;
    openingTag += token;
  }
  openingTag += ">";
  const fixedBytes = encodedBytes(openingTag) + closingBytes;
  if (fixedBytes > maximumBytes) return "";
  if (!closingTag) return openingTag;

  let children = "";
  let remaining = maximumBytes - fixedBytes;
  for (const child of node.children) {
    const serialized = serializeNode(child, remaining);
    if (!serialized) continue;
    children += serialized;
    remaining -= encodedBytes(serialized);
    if (remaining <= 0) break;
  }
  return `${openingTag}${children}${closingTag}`;
}

function fitStringsWithinBytes(values: readonly string[], maximumBytes: number): string[] {
  const result: string[] = [];
  let used = 0;
  for (const value of values) {
    const limited = truncateUTF8(value, maximumAttributeValueBytes);
    const bytes = encodedBytes(limited);
    if (used + bytes > maximumBytes) break;
    result.push(limited);
    used += bytes;
  }
  return result;
}

function truncateUTF8(value: string, maximumBytes: number): string {
  if (encodedBytes(value) <= maximumBytes) return value;
  let result = "";
  let used = 0;
  for (const character of value) {
    const bytes = encodedBytes(character);
    if (used + bytes > maximumBytes) break;
    result += character;
    used += bytes;
  }
  return result;
}

function escapeTextWithinBytes(value: string, maximumBytes: number): string {
  let result = "";
  let used = 0;
  for (const character of value) {
    const escaped = escapeText(character);
    const bytes = encodedBytes(escaped);
    if (used + bytes > maximumBytes) break;
    result += escaped;
    used += bytes;
  }
  return result;
}

function escapeText(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function escapeAttribute(value: string): string {
  return escapeText(value).replaceAll('"', "&quot;");
}

function normalizeText(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function hasIgnoredAncestor(element: Element): boolean {
  for (let current: Element | null = element; current; current = current.parentElement) {
    if (ignoredTags.has(current.tagName)) return true;
  }
  return false;
}

function isElementVisible(element: HTMLElement): boolean {
  if (element.hidden || element.closest("[hidden]")) return false;
  if (typeof element.checkVisibility === "function") {
    return element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  }
  // jsdom 等测试环境没有 checkVisibility；沿祖先链覆盖最常见的内联隐藏方式。
  for (let current: HTMLElement | null = element; current; current = current.parentElement) {
    if (
      current.style.display === "none"
      || current.style.visibility === "hidden"
      || current.style.opacity === "0"
    ) return false;
  }
  return true;
}

function encodedBytes(value: string): number {
  return textEncoder.encode(value).byteLength;
}
