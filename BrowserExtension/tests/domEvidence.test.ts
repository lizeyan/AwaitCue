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
    const evidence = collectEvidence(
      document,
      "hook-1",
      { x: 0.05, y: 0.1, width: 0.4, height: 0.4 },
      true
    );

    expect(evidence.hookID).toBe("hook-1");
    expect(evidence.title).toBe("Build");
    expect(evidence.text).toContain("Succeeded");
    expect(evidence.text).not.toContain("Secret outside region");
    expect(evidence.aria).toContain("aria-label:Build status");
    expect(evidence.html).toContain("<section");
    expect(evidence.html).toContain("Succeeded");
    expect(evidence.html).not.toContain("Secret outside region");
    expect(evidence.html).toContain('data-awaitcue-rect="50,50,300,100"');
    expect(evidence.availability).toBe("sufficient");
    expect(evidence.selectionRegionExpanded).toBe(true);
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
      aria: [],
      html: ""
    });
    expect(evidence).not.toHaveProperty("imageDataURL");
  });

  it("uses text glyph bounds and keeps complete page classes in sanitized HTML", () => {
    document.body.insertAdjacentHTML(
      "beforeend",
      `
        <div id="overlay"><span id="far-text">Unrelated overlay text</span></div>
        <style id="inline-style">.private-rule { color: red; }</style>
        <svg id="state-icon" class="widget-icon phase-x7 marker-q9"></svg>
      `
    );
    vi.spyOn(document.querySelector<HTMLElement>("#overlay")!, "getBoundingClientRect")
      .mockReturnValue(rect(0, 0, 1_000, 500));
    vi.spyOn(document.querySelector<HTMLElement>("#far-text")!, "getBoundingClientRect")
      .mockReturnValue(rect(800, 400, 100, 20));
    vi.spyOn(document.querySelector<HTMLElement>("#inline-style")!, "getBoundingClientRect")
      .mockReturnValue(rect(120, 120, 100, 20));
    vi.spyOn(document.querySelector<HTMLElement>("#state-icon")!, "getBoundingClientRect")
      .mockReturnValue(rect(120, 140, 20, 20));

    const evidence = collectEvidence(document, "hook", { x: 0.05, y: 0.1, width: 0.4, height: 0.4 });

    expect(evidence.text).not.toContain("Unrelated overlay text");
    expect(evidence.text).not.toContain("private-rule");
    expect(evidence.html).not.toContain("Unrelated overlay text");
    expect(evidence.html).not.toContain("private-rule");
    expect(evidence.html).toContain('class="widget-icon phase-x7 marker-q9"');
  });

  it("preserves generic semantic attributes and strips executable or identifying attributes", () => {
    document.body.innerHTML = `
      <div id="card" class="widget-card phase-x7" role="status" aria-live="polite"
           data-phase="x7" title="Current phase" style="color:red" onclick="steal()">
        <a id="link" href="https://secret.example/path">
          <img id="icon" src="https://secret.example/icon.png" alt="Phase icon">
          <span id="label">Target step</span>
        </a>
        <input id="control" type="checkbox" name="approval" value="yes" max="1" checked disabled>
        <script>privateScript()</script>
        <template>Private template</template>
      </div>
    `;
    for (const selector of ["#card", "#link", "#icon", "#label", "#control"]) {
      vi.spyOn(document.querySelector<HTMLElement>(selector)!, "getBoundingClientRect")
        .mockReturnValue(rect(100, 100, 180, 30));
    }

    const evidence = collectEvidence(document, "generic", { x: 0, y: 0, width: 0.5, height: 0.5 });

    expect(evidence.html).toContain('class="widget-card phase-x7"');
    expect(evidence.html).toContain('role="status"');
    expect(evidence.html).toContain('aria-live="polite"');
    expect(evidence.html).toContain('data-phase="x7"');
    expect(evidence.html).toContain('alt="Phase icon"');
    expect(evidence.html).toContain('type="checkbox"');
    expect(evidence.html).toContain('name="approval"');
    expect(evidence.html).toContain('value="yes"');
    expect(evidence.html).toContain('max="1"');
    expect(evidence.html).toContain(" checked disabled");
    expect(evidence.html).toContain("Target step");
    expect(evidence.html).not.toMatch(/\s(?:id|href|src|style|onclick)=/);
    expect(evidence.html).not.toContain("privateScript");
    expect(evidence.html).not.toContain("Private template");
    expect(evidence).not.toHaveProperty("imageDataURL");
  });

  it("does not expose text hidden by CSS visibility", () => {
    const span = document.querySelector<HTMLElement>("#inside span")!;
    span.style.visibility = "hidden";

    const evidence = collectEvidence(document, "hook", { x: 0.05, y: 0.1, width: 0.4, height: 0.4 });

    expect(evidence.text).not.toContain("Succeeded");
    expect(evidence.html).not.toContain("Succeeded");
  });

  it("does not expose descendants of a CSS-hidden container", () => {
    const inside = document.querySelector<HTMLElement>("#inside")!;
    inside.style.display = "none";

    const evidence = collectEvidence(document, "hook", { x: 0.05, y: 0.1, width: 0.4, height: 0.4 });

    expect(evidence.text).not.toContain("Succeeded");
    expect(evidence.html).not.toContain("Succeeded");
    expect(evidence.html).not.toContain("Build status");
  });

  it("keeps overflow hierarchy without attributes from an ancestor outside the region", () => {
    document.body.innerHTML = `
      <div id="outside-parent" data-private-context="must-not-leak">
        <span id="overflow-child" class="visible-child">Visible target</span>
      </div>
    `;
    vi.spyOn(document.querySelector<HTMLElement>("#outside-parent")!, "getBoundingClientRect")
      .mockReturnValue(rect(700, 400, 200, 50));
    vi.spyOn(document.querySelector<HTMLElement>("#overflow-child")!, "getBoundingClientRect")
      .mockReturnValue(rect(100, 100, 160, 30));

    const evidence = collectEvidence(document, "overflow", { x: 0, y: 0, width: 0.5, height: 0.5 });

    expect(evidence.html).toContain("Visible target");
    expect(evidence.html).toContain('class="visible-child"');
    expect(evidence.html).not.toContain("must-not-leak");
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
    expect(new TextEncoder().encode(JSON.stringify(evidence)).byteLength).toBeLessThan(24 * 1_024);
    const template = document.createElement("template");
    template.innerHTML = evidence.html ?? "";
    expect(template.content.querySelector("span")).not.toBeNull();
    expect(elapsed).toBeLessThan(1_500);
  });

  it("emits only when the evidence fingerprint changes", async () => {
    vi.useFakeTimers();
    const onChange = vi.fn();
    const observer = new EvidenceObserver(
      document,
      "hook",
      { x: 0, y: 0, width: 1, height: 1 },
      onChange,
      true
    );

    const initialEvidence = observer.start();
    expect(initialEvidence.selectionRegionExpanded).toBe(true);
    expect(initialEvidence).not.toHaveProperty("imageDataURL");
    observer.check();
    expect(onChange).not.toHaveBeenCalled();

    document.querySelector("#inside span")!.textContent = "Failed";
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(300);
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange.mock.calls[0]?.[0].selectionRegionExpanded).toBe(true);
    expect(onChange.mock.calls[0]?.[0]).not.toHaveProperty("imageDataURL");
    observer.check();
    expect(onChange).toHaveBeenCalledTimes(1);

    observer.stop();
    vi.useRealTimers();
  });

  it("emits when a retained generic data attribute changes", async () => {
    vi.useFakeTimers();
    const status = document.querySelector<HTMLElement>("#inside")!;
    status.dataset.phase = "x7";
    const onChange = vi.fn();
    const observer = new EvidenceObserver(
      document,
      "hook",
      { x: 0, y: 0, width: 1, height: 1 },
      onChange
    );
    observer.start();
    onChange.mockClear();

    status.dataset.phase = "y2";
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(300);

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange.mock.calls[0]?.[0].aria).toContain("data-phase:y2");
    expect(onChange.mock.calls[0]?.[0].html).toContain('data-phase="y2"');
    observer.stop();
    vi.useRealTimers();
  });

  it("includes HTML-only class changes in the evidence fingerprint", async () => {
    vi.useFakeTimers();
    const status = document.querySelector<HTMLElement>("#inside")!;
    status.className = "phase-x7";
    const onChange = vi.fn();
    const observer = new EvidenceObserver(document, "hook", { x: 0, y: 0, width: 1, height: 1 }, onChange);
    observer.start();
    onChange.mockClear();

    status.className = "phase-y2";
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(300);

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange.mock.calls[0]?.[0].html).toContain('class="phase-y2"');
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
