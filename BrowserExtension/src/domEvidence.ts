import type { Evidence, NormalizedRegion } from "./protocol";
import { denormalizeRegion, intersects } from "./region";

const maximumTextLength = 4_000;
const observedAttributes = ["aria-label", "aria-valuenow", "aria-valuetext", "role", "title", "alt"];

/** 从框选区域内的 DOM 提取有限且稳定的文本证据。 */
export function collectEvidence(
  document: Document,
  hookID: string,
  region: NormalizedRegion
): Evidence {
  const pixelRegion = denormalizeRegion(region, document.documentElement.clientWidth, document.documentElement.clientHeight);
  const textParts: string[] = [];
  const aria = new Set<string>();

  for (const element of document.querySelectorAll<HTMLElement>("body *")) {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0 || !intersects(rect, pixelRegion)) continue;
    const ownText = normalizeText(element.childNodes.length === 1 ? element.textContent ?? "" : "");
    if (ownText) textParts.push(ownText);
    for (const attribute of observedAttributes) {
      const value = normalizeText(element.getAttribute(attribute) ?? "");
      if (value) aria.add(`${attribute}:${value}`);
    }
  }

  const text = normalizeText(textParts.join(" ")).slice(0, maximumTextLength);
  const ariaValues = [...aria].sort().slice(0, 100);
  return {
    hookID,
    url: document.location.href,
    title: document.title,
    text,
    aria: ariaValues,
    fingerprint: fingerprint(`${document.location.href}\n${document.title}\n${text}\n${ariaValues.join("\n")}`)
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
  #observer: MutationObserver | null = null;
  #lastFingerprint: string | null = null;

  constructor(document: Document, hookID: string, region: NormalizedRegion, onChange: (evidence: Evidence) => void) {
    this.#document = document;
    this.#hookID = hookID;
    this.#region = region;
    this.#onChange = onChange;
  }

  start(): Evidence {
    const initial = this.check();
    this.#observer = new MutationObserver(() => this.check());
    this.#observer.observe(this.#document.documentElement, {
      attributes: true,
      childList: true,
      characterData: true,
      subtree: true,
      attributeFilter: observedAttributes
    });
    return initial;
  }

  stop(): void {
    this.#observer?.disconnect();
    this.#observer = null;
  }

  check(): Evidence {
    const evidence = collectEvidence(this.#document, this.#hookID, this.#region);
    if (evidence.fingerprint !== this.#lastFingerprint) {
      this.#lastFingerprint = evidence.fingerprint;
      this.#onChange(evidence);
    }
    return evidence;
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
