import { beforeEach, describe, expect, it, vi } from "vitest";
import { collectEvidence, EvidenceObserver, fingerprint } from "../src/domEvidence";

describe("DOM evidence", () => {
  beforeEach(() => {
    document.documentElement.innerHTML = `
      <head><title>Build</title></head>
      <body>
        <section id="inside" aria-label="Build status"><span>Succeeded</span></section>
        <section id="outside">Secret outside region</section>
      </body>
    `;
    Object.defineProperties(document.documentElement, {
      clientWidth: { configurable: true, value: 1_000 },
      clientHeight: { configurable: true, value: 500 }
    });
    vi.spyOn(document.querySelector<HTMLElement>("#inside")!, "getBoundingClientRect").mockReturnValue(rect(100, 100, 300, 100));
    vi.spyOn(document.querySelector<HTMLElement>("#inside span")!, "getBoundingClientRect").mockReturnValue(rect(110, 110, 100, 20));
    vi.spyOn(document.querySelector<HTMLElement>("#outside")!, "getBoundingClientRect").mockReturnValue(rect(700, 400, 200, 50));
    vi.spyOn(document, "createRange").mockImplementation(() => {
      let selectedNode: Node | null = null;
      return {
        selectNodeContents(node: Node) {
          selectedNode = node;
        },
        getClientRects() {
          const parent = selectedNode?.parentElement;
          return (parent ? [parent.getBoundingClientRect()] : []) as unknown as DOMRectList;
        },
        detach() {}
      } as unknown as Range;
    });
  });

  it("collects only visible elements intersecting the selected region", () => {
    const evidence = collectEvidence(document, "hook-1", { x: 0.05, y: 0.1, width: 0.4, height: 0.4 });

    expect(evidence.hookID).toBe("hook-1");
    expect(evidence.title).toBe("Build");
    expect(evidence.text).toContain("Succeeded");
    expect(evidence.text).not.toContain("Secret outside region");
    expect(evidence.aria).toContain("aria-label:Build status");
    expect(evidence.availability).toBe("sufficient");
    expect(evidence).not.toHaveProperty("imageDataURL");
    expect(evidence.fingerprint).toMatch(/^[0-9a-f]{8}$/);
  });

  it("marks a visual-only selected region as insufficient instead of inventing screenshot evidence", () => {
    document.body.innerHTML = `<canvas id="pipeline"></canvas>`;
    vi.spyOn(document.querySelector<HTMLElement>("#pipeline")!, "getBoundingClientRect")
      .mockReturnValue(rect(100, 100, 300, 100));

    const evidence = collectEvidence(document, "visual-only", {
      x: 0.05,
      y: 0.1,
      width: 0.4,
      height: 0.4
    });

    expect(evidence).toMatchObject({
      availability: "insufficient",
      insufficiencyReason: "no_semantic_content",
      text: "",
      aria: []
    });
    expect(evidence).not.toHaveProperty("imageDataURL");
  });

  it("uses text glyph bounds and keeps semantic status classes", () => {
    document.body.insertAdjacentHTML(
      "beforeend",
      `
        <div id="overlay"><span id="far-text">Unrelated overlay text</span></div>
        <style id="inline-style">.private-rule { color: red; }</style>
        <svg id="success-icon" class="atom-pipeline-icon atom-pipeline-icon-check-circle-fill"></svg>
      `
    );
    vi.spyOn(document.querySelector<HTMLElement>("#overlay")!, "getBoundingClientRect")
      .mockReturnValue(rect(0, 0, 1_000, 500));
    vi.spyOn(document.querySelector<HTMLElement>("#far-text")!, "getBoundingClientRect")
      .mockReturnValue(rect(800, 400, 100, 20));
    vi.spyOn(document.querySelector<HTMLElement>("#inline-style")!, "getBoundingClientRect")
      .mockReturnValue(rect(120, 120, 100, 20));
    vi.spyOn(document.querySelector<HTMLElement>("#success-icon")!, "getBoundingClientRect")
      .mockReturnValue(rect(120, 140, 20, 20));

    const evidence = collectEvidence(document, "hook", { x: 0.05, y: 0.1, width: 0.4, height: 0.4 });

    expect(evidence.text).not.toContain("Unrelated overlay text");
    expect(evidence.text).not.toContain("private-rule");
    expect(evidence.aria).toContain("class:atom-pipeline-icon-check-circle-fill");
  });

  it("does not expose text hidden by CSS visibility", () => {
    const span = document.querySelector<HTMLElement>("#inside span")!;
    span.style.visibility = "hidden";

    const evidence = collectEvidence(document, "hook", { x: 0.05, y: 0.1, width: 0.4, height: 0.4 });

    expect(evidence.text).not.toContain("Succeeded");
  });

  it("normalizes repeated whitespace and caps collected text", () => {
    const span = document.querySelector("#inside span")!;
    span.textContent = `  ${"word ".repeat(2_000)}  `;
    const evidence = collectEvidence(document, "hook", { x: 0, y: 0, width: 1, height: 1 });
    expect(evidence.text.length).toBe(4_000);
    expect(evidence.text).toContain("word word");
    expect(new TextEncoder().encode(JSON.stringify(evidence)).byteLength).toBeLessThan(24_000);
  });

  it("extracts a large selected DOM within the interaction budget", () => {
    document.body.innerHTML = Array.from(
      { length: 5_000 },
      (_, index) => `<span class="status-${index % 2 === 0 ? "success" : "pending"}">Node ${index}</span>`
    ).join("");
    for (const element of document.querySelectorAll<HTMLElement>("span")) {
      vi.spyOn(element, "getBoundingClientRect").mockReturnValue(rect(0, 0, 100, 20));
    }

    const startedAt = performance.now();
    const evidence = collectEvidence(document, "large", { x: 0, y: 0, width: 1, height: 1 });
    const elapsed = performance.now() - startedAt;

    expect(evidence.text.length).toBe(4_000);
    expect(elapsed).toBeLessThan(1_500);
  });

  it("emits only when the evidence fingerprint changes", async () => {
    vi.useFakeTimers();
    const onChange = vi.fn();
    const observer = new EvidenceObserver(document, "hook", { x: 0, y: 0, width: 1, height: 1 }, onChange);

    observer.start();
    observer.check();
    expect(onChange).not.toHaveBeenCalled();

    document.querySelector("#inside span")!.textContent = "Failed";
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(300);
    expect(onChange).toHaveBeenCalledTimes(1);
    observer.check();
    expect(onChange).toHaveBeenCalledTimes(1);

    observer.stop();
    vi.useRealTimers();
  });

  it("emits when a background page changes only its semantic status class", async () => {
    vi.useFakeTimers();
    const status = document.querySelector<HTMLElement>("#inside")!;
    status.className = "pipeline-status-pending";
    const onChange = vi.fn();
    const observer = new EvidenceObserver(
      document,
      "hook",
      { x: 0, y: 0, width: 1, height: 1 },
      onChange
    );
    observer.start();
    onChange.mockClear();

    status.className = "pipeline-status-success";
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(300);

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange.mock.calls[0]?.[0].aria).toContain("class:pipeline-status-success");
    observer.stop();
    vi.useRealTimers();
  });

  it("ignores mutations whose rendered evidence stays outside the region", async () => {
    vi.useFakeTimers();
    const onChange = vi.fn();
    const observer = new EvidenceObserver(document, "hook", { x: 0.05, y: 0.1, width: 0.4, height: 0.4 }, onChange);
    observer.start();

    document.querySelector<HTMLElement>("#outside")!.textContent = "Changed secret outside region";
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(300);

    expect(onChange).not.toHaveBeenCalled();
    observer.stop();
    vi.useRealTimers();
  });

  it("coalesces a mutation burst and cancels pending collection when stopped", async () => {
    vi.useFakeTimers();
    const onChange = vi.fn();
    const observer = new EvidenceObserver(
      document,
      "hook",
      { x: 0, y: 0, width: 1, height: 1 },
      onChange
    );
    observer.start();
    onChange.mockClear();

    for (let index = 0; index < 100; index += 1) {
      document.querySelector("#inside span")!.textContent = `State ${index}`;
      await Promise.resolve();
    }
    expect(onChange).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(299);
    expect(onChange).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange.mock.calls[0]?.[0].text).toContain("State 99");

    document.querySelector("#inside span")!.textContent = "Cancelled change";
    await Promise.resolve();
    observer.stop();
    await vi.advanceTimersByTimeAsync(300);
    expect(onChange).toHaveBeenCalledTimes(1);
    vi.useRealTimers();
  });

  it("produces deterministic fingerprints", () => {
    expect(fingerprint("same")).toBe(fingerprint("same"));
    expect(fingerprint("same")).not.toBe(fingerprint("different"));
  });
});

function rect(x: number, y: number, width: number, height: number): DOMRect {
  return {
    x,
    y,
    width,
    height,
    top: y,
    right: x + width,
    bottom: y + height,
    left: x,
    toJSON: () => ({})
  };
}
