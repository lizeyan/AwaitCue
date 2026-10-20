import type { NormalizedRegion } from "./protocol";

export type CaptureStart = Readonly<{
  hookID: string;
  streamID: string;
  region: NormalizedRegion;
}>;

export interface CaptureBackend {
  start(request: CaptureStart): Promise<void>;
  stop(hookID: string): Promise<void>;
}

/** 维护 Hook 与标签页捕获流的唯一绑定，重复启动时先释放旧流。 */
export class CaptureSessionManager {
  readonly #backend: CaptureBackend;
  readonly #active = new Map<string, CaptureStart>();

  constructor(backend: CaptureBackend) {
    this.#backend = backend;
  }

  async start(request: CaptureStart): Promise<void> {
    if (this.#active.has(request.hookID)) await this.stop(request.hookID);
    await this.#backend.start(request);
    this.#active.set(request.hookID, request);
  }

  async stop(hookID: string): Promise<void> {
    if (!this.#active.has(hookID)) return;
    await this.#backend.stop(hookID);
    this.#active.delete(hookID);
  }

  isActive(hookID: string): boolean {
    return this.#active.has(hookID);
  }

  async stopAll(): Promise<void> {
    for (const hookID of [...this.#active.keys()]) await this.stop(hookID);
  }
}
