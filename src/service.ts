import type { Blame, Content, Diff, Draft, HistoryLog, HistorySettings, HistoryStatus, HistoryTransport } from './types';

export class HistoryService {
  constructor(private readonly transport: HistoryTransport, readonly folder: string, private readonly settings: () => HistorySettings) {}

  call<T>(op: string, args: Record<string, unknown> = {}): Promise<T> {
    const settings = this.settings();
    return this.transport.request<T>({ folder: this.folder, writer: settings.writer,
      extensions: settings.extensions.split(',').map((e) => e.trim()).filter(Boolean), op, ...args });
  }
  log(path?: string, filters: Record<string, unknown> = {}): Promise<HistoryLog> { return this.call('log', { ...(path ? { path } : {}), ...filters }); }
  show(path: string, ref: string): Promise<Content> { return this.call('show', { path, ref }); }
  diff(path: string, left: string, right: string): Promise<Diff> { return this.call('diff', { path, left, right }); }
  blame(path: string, ref: string): Promise<Blame> { return this.call('blame', { path, ref }); }
  status(): Promise<HistoryStatus> { return this.call('status'); }
  record(path?: string): Promise<{ message: string }> { return this.call('commit', path ? { path } : {}); }
  rename(path: string, newPath: string): Promise<unknown> { return this.call('rename', { path, newPath }); }
  restore(path: string, ref: string, expectedLive: string | null): Promise<{ message: string }> { return this.call('restore', { path, ref, expectedLive }); }
  merge(path: string, branch: string, expectedLive: string | null, take?: 'live' | 'branch'): Promise<Draft | { message: string }> {
    return this.call(take ? 'merge-take' : 'merge-start', { path, branch, expectedLive, ...(take ? { take } : {}) });
  }
  draft(path: string): Promise<Draft> { return this.call('draft', { path }); }
  saveDraft(path: string, text: string): Promise<unknown> { return this.call('draft-save', { path, text }); }
  finish(path: string, text: string, expectedLive: string | null): Promise<{ message: string }> { return this.call('merge-continue', { path, text, expectedLive }); }
  abort(path: string): Promise<unknown> { return this.call('merge-abort', { path }); }
  dispose(): void { this.transport.dispose(); }
}

/** Owns only the timing; the engine owns what counts as a recorded version. */
export class SaveRecorder {
  private readonly timers = new Map<string, ReturnType<typeof setTimeout>>();
  private stopped = false;
  constructor(private readonly service: Pick<HistoryService, 'record' | 'rename'>,
    private readonly delay: () => number, private readonly onError: (error: unknown) => void) {}

  changed(path: string): void {
    if (this.stopped) return;
    this.cancel(path);
    this.timers.set(path, setTimeout(() => {
      this.timers.delete(path);
      void this.service.record(path).catch(this.onError);
    }, this.delay()));
  }
  renamed(oldPath: string, newPath: string): void {
    if (this.stopped) return;
    this.cancel(oldPath); this.cancel(newPath);
    void this.service.rename(oldPath, newPath).catch(this.onError);
  }
  deleted(path: string): void {
    if (this.stopped) return;
    this.cancel(path);
    void this.service.record(path).catch(this.onError);
  }
  private cancel(path: string): void {
    const timer = this.timers.get(path);
    if (timer != null) clearTimeout(timer);
    this.timers.delete(path);
  }
  dispose(): void {
    this.stopped = true;
    for (const path of this.timers.keys()) this.cancel(path);
  }
}
