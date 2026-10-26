import type { Evidence, NormalizedRegion } from "./protocol";
import { denormalizeRegion, intersects } from "./region";

const maximumTextLength = 4_000;
const evidenceAttributes = [
  "aria-label",
  "aria-valuenow",
  "aria-valuetext",
  "aria-checked",
  "aria-selected",
  "aria-busy",
  "aria-current",
  "aria-disabled",
  "aria-expanded",
  "aria-pressed",
  "role",
  "title",
  "alt",
  "data-state",
  "data-status",
  "value",
  "max"
];
const mutationAttributes = [...evidenceAttributes, "class"];
const ignoredTextParentTags = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE"]);
const semanticClassPattern = /(success|succeed|done|complete|check|fail|error|running|loading|pending|wait|ignored|disabled|status|progress)/i;
const mutationCoalescingMilliseconds = 300;

type EvidenceRow = Readonly<{ x: number; y: number; text: string }>;

/** 从框选区域内的 DOM 提取有限且稳定的文本证据，并标明范围是否因侧栏歧义被扩大。 */
export function collectEvidence(
  document: Document,
  hookID: string,
  region: NormalizedRegion,
  selectionRegionExpanded = false
): Evidence {
  const pixelRegion = denormalizeRegion(region, document.documentElement.clientWidth, document.documentElement.clientHeight);
  const rows: EvidenceRow[] = [];
  const aria = new Set<string>();

  // 元素盒可能横跨整页，即使文字实际位于选区外；Range 才能给出文字本身的可见位置。
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode;
    const parent = node.parentElement;
    if (!parent || ignoredTextParentTags.has(parent.tagName)) continue;
    // checkVisibility 由浏览器原生判断继承的 CSS 可见性，避免逐节点 getComputedStyle 触发布局计算。
    if (!isElementVisible(parent)) continue;
    const text = normalizeText(node.nodeValue ?? "");
    if (!text) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    const rects = [...range.getClientRects()].filter((rect) => intersects(rect, pixelRegion));
    range.detach();
    if (rects.length === 0) continue;
    const rect = rects[0]!;
    rows.push({
      x: Math.round(rect.left - pixelRegion.x),
      y: Math.round(rect.top - pixelRegion.y),
      text
    });
  }

  for (const element of document.querySelectorAll<HTMLElement>("body *")) {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0 || !intersects(rect, pixelRegion)) continue;
    for (const attribute of evidenceAttributes) {
      const value = normalizeText(element.getAttribute(attribute) ?? "");
      if (!value) continue;
      const semantic = `${attribute}:${value}`;
      aria.add(semantic);
      rows.push({
        x: Math.round(rect.left - pixelRegion.x),
        y: Math.round(rect.top - pixelRegion.y),
        text: semantic
      });
    }
    for (const token of element.classList) {
      if (!semanticClassPattern.test(token)) continue;
      const semantic = `class:${token}`;
      aria.add(semantic);
      rows.push({
        x: Math.round(rect.left - pixelRegion.x),
        y: Math.round(rect.top - pixelRegion.y),
        text: semantic
      });
    }
  }

  rows.sort((left, right) => Math.abs(left.y - right.y) <= 3 ? left.x - right.x : left.y - right.y);
  const seenRows = new Set<string>();
  const text = rows.flatMap((row) => {
    const key = `${row.x}|${row.y}|${row.text}`;
    if (seenRows.has(key)) return [];
    seenRows.add(key);
    return [`[${row.x},${row.y}] ${row.text}`];
  }).join("\n").slice(0, maximumTextLength);
  const ariaValues = [...aria].sort().slice(0, 100);
  const availability = text || ariaValues.length > 0 ? "sufficient" : "insufficient";
  const insufficiencyReason = availability === "insufficient" ? "no_semantic_content" : undefined;
  return {
    hookID,
    url: document.location.href,
    title: document.title,
    text,
    aria: ariaValues,
    availability,
    ...(insufficiencyReason ? { insufficiencyReason } : {}),
    selectionRegionExpanded,
    fingerprint: fingerprint(
      `${document.location.href}\n${document.title}\n${availability}\n${selectionRegionExpanded}\n${text}\n${ariaValues.join("\n")}`
    )
  };
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
      subtree: true,
      attributeFilter: mutationAttributes
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

function normalizeText(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function isElementVisible(element: HTMLElement): boolean {
  if (element.hidden || element.closest("[hidden]")) return false;
  if (typeof element.checkVisibility === "function") {
    return element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  }
  // jsdom 等测试环境没有 checkVisibility；覆盖最常见的内联隐藏方式，不把测试替身变成性能瓶颈。
  return element.style.display !== "none"
    && element.style.visibility !== "hidden"
    && element.style.opacity !== "0";
}
