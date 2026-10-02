import { ItemView, Modal, Notice, TFile, type WorkspaceLeaf } from 'obsidian';
import type EntropyHistoryPlugin from './main';
import type { Draft, Entry, HistoryLog, HistoryStatus } from './types';

export const VIEW_TYPE = 'entropy-history';
const short = (hash: string) => hash.slice(0, 10);
const time = (stamp: number) => new Date(stamp).toLocaleString();
const kind = { divergent: 'расхождение', merged: 'объединено', archived: 'архив' };

function button(parent: HTMLElement, text: string, action: () => void | Promise<unknown>, cls = ''): HTMLButtonElement {
  const el = parent.createEl('button', { text, cls }); el.type = 'button';
  el.addEventListener('click', () => { void Promise.resolve(action()).catch((e) => new Notice(String(e), 8000)); });
  return el;
}
function code(parent: HTMLElement, text: string, cls = ''): HTMLElement {
  return parent.createEl('pre', { cls: `eh-code ${cls}` }).createEl('code', { text });
}

export class HistoryView extends ItemView {
  path: string | undefined;
  followActive = true;
  private list!: HTMLElement;
  private preview!: HTMLElement;
  private title!: HTMLElement;
  private errorEl!: HTMLElement;
  private statusButton!: HTMLButtonElement;
  private scopeButton!: HTMLButtonElement;
  private log: HistoryLog | undefined;
  private status: HistoryStatus | undefined;
  private selected: Entry | undefined;
  private tab: 'content' | 'diff' | 'blame' = 'content';
  private filters: Record<string, unknown> = { limit: 200 };
  private left = '';
  private right = 'WORKING';
  private generation = 0;
  private closed = false;
  private loading = false;
  private refreshTimer: number | undefined;

  constructor(leaf: WorkspaceLeaf, readonly plugin: EntropyHistoryPlugin) { super(leaf); }
  getViewType(): string { return VIEW_TYPE; }
  getDisplayText(): string { return 'История'; }
  getIcon(): string { return 'history'; }
  getState(): Record<string, unknown> { return { path: this.path, followActive: this.followActive }; }
  async setState(state: { path?: string; followActive?: boolean }): Promise<void> {
    this.path = state.path; this.followActive = state.followActive ?? true;
    if (this.list) await this.refresh();
  }

  async onOpen(): Promise<void> {
    const root = this.contentEl; root.empty(); root.addClass('entropy-history');
    const toolbar = root.createDiv({ cls: 'eh-toolbar' });
    this.title = toolbar.createEl('strong', { text: 'История' });
    this.scopeButton = button(toolbar, 'Весь vault', () => this.showVault());
    button(toolbar, 'Текущий файл', () => this.showPath(this.app.workspace.getActiveFile()?.path, true));
    button(toolbar, 'Обновить', () => this.refresh());
    button(toolbar, 'Записать', () => this.plugin.record(this.path));
    this.statusButton = button(toolbar, 'Расхождения', () => this.showStatus());
    const filters = root.createDiv({ cls: 'eh-filters' });
    const filter = filters.createEl('input', { type: 'search', placeholder: 'Путь содержит…', attr: { 'aria-label': 'Фильтр пути' } });
    filter.addEventListener('input', () => { this.filters.filter = filter.value; this.scheduleRefresh(); });
    const author = filters.createEl('input', { type: 'search', placeholder: 'Автор', attr: { 'aria-label': 'Фильтр автора' } });
    author.addEventListener('input', () => { this.filters.author = author.value; this.scheduleRefresh(); });
    const since = filters.createEl('input', { type: 'date', attr: { 'aria-label': 'Версии начиная с даты' } });
    since.addEventListener('change', () => {
      if (since.value) this.filters.since = new Date(`${since.value}T00:00:00`).getTime();
      else delete this.filters.since;
      this.scheduleRefresh();
    });
    this.errorEl = root.createDiv({ cls: 'eh-error', attr: { role: 'status' } });
    const body = root.createDiv({ cls: 'eh-body' });
    this.list = body.createDiv({ cls: 'eh-versions' });
    this.preview = body.createDiv({ cls: 'eh-preview' });
    this.registerInterval(window.setInterval(() => { if (!this.loading) void this.refresh(); }, 10_000));
    await this.refresh();
  }

  async onClose(): Promise<void> {
    this.closed = true; this.generation++;
    if (this.refreshTimer != null) window.clearTimeout(this.refreshTimer);
  }

  showPath(path?: string, follow = false): void {
    this.generation++;
    this.path = path; this.followActive = follow; this.selected = undefined;
    this.left = ''; this.right = 'WORKING'; this.scheduleRefresh();
  }
  showVault(): void {
    this.generation++;
    this.path = undefined; this.followActive = false; this.selected = undefined;
    this.scheduleRefresh();
  }
  scheduleRefresh(): void {
    if (this.closed) return;
    if (this.refreshTimer != null) window.clearTimeout(this.refreshTimer);
    this.refreshTimer = window.setTimeout(() => { this.refreshTimer = undefined; void this.refresh(); }, 300);
  }

  async refresh(): Promise<void> {
    if (this.closed || !this.list) return;
    if (this.loading) { this.scheduleRefresh(); return; }
    this.loading = true;
    const generation = ++this.generation;
    try {
      const log = await this.plugin.service.log(this.path, this.filters);
      const status = await this.plugin.service.status();
      if (generation !== this.generation || this.closed) return;
      this.errorEl.empty(); this.log = log; this.status = status;
      this.title.setText(this.path ?? 'История vault');
      this.scopeButton.disabled = this.path == null;
      this.statusButton.setText(`Расхождения: ${status.divergent.length} · Черновики: ${status.drafts.length}`);
      this.renderList();
      if (this.selected) {
        const current = log.entries.find((e) => e.path === this.selected?.path && e.hash === this.selected.hash);
        if (current) this.selected = current;
        else this.selected = undefined;
      }
      if (this.selected) {
        await this.renderPreview();
      } else if (log.entries.length) {
        this.selected = log.entries[0]; this.left = this.selected.hash;
        await this.renderPreview();
      } else {
        this.preview.empty(); this.preview.createEl('p', { text: 'Версий пока нет. Запишите текущий файл или включите запись сохранений в настройках.' });
      }
      this.renderList();
    } catch (e) { if (generation === this.generation && !this.closed) this.showError(e); }
    finally { this.loading = false; }
  }

  private renderList(): void {
    const log = this.log!; this.list.empty();
    if (log.approximate) this.list.createEl('p', { text: 'Порядок между файлами приблизительный: он зависит от часов устройств. История хранится отдельно для каждого файла.', cls: 'eh-hint' });
    if (log.unrecorded) this.list.createEl('p', { text: 'В текущем файле есть незаписанные изменения.', cls: 'eh-hint' });
    if (log.path && !log.exists && log.entries.length) this.list.createEl('p', { text: 'Файл удалён; его версии можно восстановить.', cls: 'eh-hint' });
    for (const link of [...log.renamedFrom, ...log.renamedTo]) button(this.list, `Связанное имя: ${link.path}`, () => this.showPath(link.path));
    for (const entry of log.entries) {
      const row = button(this.list, '', async () => {
        this.selected = entry; this.left = entry.hash; this.right = 'WORKING';
        this.renderList(); await this.renderPreview();
      }, `eh-version${this.selected?.hash === entry.hash && this.selected.path === entry.path ? ' is-selected' : ''}`);
      row.createEl('strong', { text: log.approximate ? entry.path : short(entry.hash) });
      row.createEl('span', { text: `${time(entry.timestamp)} · ${entry.writers.join(', ')}` });
      row.createEl('small', { text: [entry.live ? 'текущая' : '', entry.branch ? kind[entry.branch.kind] : '', entry.broken ? 'повреждена' : ''].filter(Boolean).join(' · ') || short(entry.hash) });
      row.title = entry.hash;
    }
    if (log.total > log.entries.length && Number(this.filters.limit) >= 10000) this.list.createEl('p', { text: 'Показаны первые 10 000 версий. Уточните фильтр.' });
    else if (log.total > log.entries.length) button(this.list, `Показать ещё (${log.total - log.entries.length})`, () => {
      this.filters.limit = Math.min(10000, Number(this.filters.limit) + 200); return this.refresh();
    });
  }

  private async renderPreview(): Promise<void> {
    const entry = this.selected; if (!entry || this.closed) return;
    const generation = ++this.generation;
    this.preview.empty();
    const header = this.preview.createDiv({ cls: 'eh-preview-header' });
    header.createEl('h3', { text: entry.path });
    header.createEl('code', { text: entry.hash });
    const actions = header.createDiv({ cls: 'eh-toolbar' });
    for (const [tab, title] of [['content', 'Текст'], ['diff', 'Различия'], ['blame', 'Авторство']] as const) button(actions, title, () => { this.tab = tab; return this.renderPreview(); }, this.tab === tab ? 'mod-cta' : '');
    const restoreButton = button(actions, 'Восстановить', () => this.restore(entry), 'mod-warning');
    restoreButton.disabled = entry.broken;
    button(actions, 'Открыть файл', async () => {
      const file = this.app.vault.getFileByPath(entry.path);
      if (file) await this.app.workspace.getLeaf('tab').openFile(file);
      else new Notice('Файл удалён. Выберите версию и восстановите его.');
    });
    const body = this.preview.createDiv({ cls: 'eh-preview-content' });
    try {
      const fileLog = this.log?.path === entry.path ? this.log : await this.plugin.service.log(entry.path);
      if (generation !== this.generation || this.closed) return;
      if (this.tab === 'content') {
        const data = await this.plugin.service.show(entry.path, entry.hash);
        if (generation !== this.generation || this.closed) return;
        code(body, data.content);
      } else if (this.tab === 'blame') {
        const data = await this.plugin.service.blame(entry.path, entry.hash);
        if (generation !== this.generation || this.closed) return;
        const table = body.createEl('table', { cls: 'eh-blame' });
        for (const line of data.lines) {
          const row = table.createEl('tr');
          row.createEl('td', { text: String(line.line) });
          row.createEl('td', { text: `${short(line.hash)}\n${line.writers.join(', ')}\n${time(line.timestamp)}` });
          row.createEl('td').createEl('code', { text: line.text });
        }
      } else {
        const refs = body.createDiv({ cls: 'eh-filters' });
        if (!fileLog.exists && this.right === 'WORKING') this.right = entry.parents[0] ?? entry.hash;
        for (const side of ['left', 'right'] as const) {
          const select = refs.createEl('select', { attr: { 'aria-label': side === 'left' ? 'Левая версия' : 'Правая версия' } });
          if (fileLog.exists) select.createEl('option', { text: 'Текущий файл', value: 'WORKING' });
          for (const e of fileLog.entries) select.createEl('option', { text: `${short(e.hash)} · ${time(e.timestamp)}`, value: e.hash });
          select.value = this[side] || entry.hash;
          select.addEventListener('change', () => { this[side] = select.value; void this.renderPreview(); });
        }
        const data = await this.plugin.service.diff(entry.path, this.left || entry.hash, this.right);
        if (generation !== this.generation || this.closed) return;
        const split = body.createDiv({ cls: 'eh-split' });
        const a = split.createDiv(); a.createEl('strong', { text: 'До' }); code(a, data.left.content);
        const b = split.createDiv(); b.createEl('strong', { text: 'После' }); code(b, data.right.content);
        const unified = body.createEl('pre', { cls: 'eh-code eh-diff' });
        if (!data.unified) unified.setText('Без изменений.');
        for (const line of data.unified.split('\n')) unified.createEl('div', { text: line || ' ', cls: line.startsWith('+') ? 'eh-add' : line.startsWith('-') ? 'eh-delete' : '' });
      }
      if (generation !== this.generation || this.closed) return;
      for (const branch of fileLog.branches.filter((b) => b.kind === 'divergent')) {
        const section = this.preview.createDiv({ cls: 'eh-branch' });
        section.createEl('strong', { text: `Расхождение ${short(branch.leaf)} · ${branch.writers.join(', ')}` });
        const controls = section.createDiv({ cls: 'eh-toolbar' });
        button(controls, 'Оставить текущий', () => this.reconcile(entry.path, branch.leaf, fileLog.liveHash, 'live'));
        button(controls, 'Взять ветку', () => this.reconcile(entry.path, branch.leaf, fileLog.liveHash, 'branch'));
        const merge = button(controls, 'Объединить', () => this.reconcile(entry.path, branch.leaf, fileLog.liveHash));
        merge.disabled = branch.fork == null;
        if (!branch.fork) section.createEl('p', { text: 'Нет общего предка. Можно выбрать одну из сторон.' });
      }
      if (this.status?.drafts.some((d) => d.path === entry.path)) button(this.preview, 'Продолжить merge-черновик', () => this.resume(entry.path), 'mod-cta');
    } catch (e) { if (generation === this.generation && !this.closed) { body.empty(); body.createEl('p', { text: e instanceof Error ? e.message : String(e), cls: 'eh-error' }); } }
  }

  private async restore(entry: Entry): Promise<void> {
    try {
      await this.plugin.flushEditors(entry.path);
      const log = await this.plugin.service.log(entry.path);
      const preview = log.exists
        ? (await this.plugin.service.diff(entry.path, 'WORKING', entry.hash)).unified
        : (await this.plugin.service.show(entry.path, entry.hash)).content;
      const confirmed = await new ConfirmModal(this.plugin, 'Восстановить версию?', `${entry.path}\n${entry.hash}\nТекущая незаписанная версия будет сохранена в истории.\n\n${preview || 'Текст совпадает с текущей версией.'}`).ask();
      if (!confirmed) return;
      const editors = await this.plugin.flushEditors(entry.path);
      await this.plugin.service.restore(entry.path, entry.hash, log.liveHash);
      await this.plugin.updateEditors(entry.path, editors);
      new Notice('Версия восстановлена.'); await this.refresh();
    } catch (e) { this.showError(e); }
  }

  private async reconcile(path: string, branch: string, liveHash: string | null, take?: 'live' | 'branch'): Promise<void> {
    try {
      if (take && !await new ConfirmModal(this.plugin, take === 'live' ? 'Оставить текущую версию?' : 'Взять версию из ветки?', `${path}\nВетка ${branch}\nРасхождение будет отмечено как разобранное. Все версии останутся в истории.`).ask()) return;
      const editors = await this.plugin.flushEditors(path);
      const result = await this.plugin.service.merge(path, branch, liveHash, take);
      if (take) { await this.plugin.updateEditors(path, editors); await this.refresh(); }
      else new MergeModal(this.plugin, result as Draft, () => this.refresh()).open();
    } catch (e) { this.showError(e); }
  }

  async resume(path: string): Promise<void> {
    try {
      if ([...this.plugin.merges].some((modal) => modal.path === path)) {
        new Notice('Черновик этого файла уже открыт.'); return;
      }
      const draft = await this.plugin.service.draft(path);
      if (draft.exists) new MergeModal(this.plugin, draft, () => this.refresh()).open();
      else new Notice('Незавершённого черновика нет.');
    } catch (e) { this.showError(e); }
  }
  async showStatus(): Promise<void> {
    try {
      const status = await this.plugin.service.status(); this.status = status;
      const modal = new Modal(this.app); modal.titleEl.setText('Расхождения и merge-черновики');
      if (!status.divergent.length && !status.drafts.length) modal.contentEl.createEl('p', { text: 'Нет открытых расхождений или черновиков.' });
      for (const item of status.divergent) button(modal.contentEl, `${item.path} · ${item.branches.length} расхождений`, () => { this.showPath(item.path); modal.close(); });
      for (const item of status.drafts) button(modal.contentEl, `${item.path} · продолжить черновик`, () => { modal.close(); return this.resume(item.path); });
      modal.open();
    } catch (e) { this.showError(e); }
  }
  private showError(error: unknown): void { this.errorEl.setText(error instanceof Error ? error.message : String(error)); }
}

class ConfirmModal extends Modal {
  private resolve!: (result: boolean) => void;
  private settled = false;
  constructor(plugin: EntropyHistoryPlugin, private readonly title: string, private readonly details: string) { super(plugin.app); }
  ask(): Promise<boolean> { return new Promise((resolve) => { this.resolve = resolve; this.open(); }); }
  onOpen(): void {
    this.titleEl.setText(this.title); code(this.contentEl, this.details);
    const controls = this.contentEl.createDiv({ cls: 'eh-toolbar' });
    button(controls, 'Отмена', () => this.close());
    button(controls, 'Подтвердить', () => { this.settled = true; this.resolve(true); this.close(); }, 'mod-warning');
  }
  onClose(): void { if (!this.settled) this.resolve(false); this.contentEl.empty(); }
}

export class MergeModal extends Modal {
  private editor!: HTMLTextAreaElement;
  private errorEl!: HTMLElement;
  private saving: Promise<unknown> = Promise.resolve();
  private disposed = false;
  private completed = false;
  private busy = false;
  private saveTimer: number | undefined;
  private closingForUnload = false;
  constructor(private readonly plugin: EntropyHistoryPlugin, private readonly draft: Draft, private readonly refresh: () => Promise<void>) { super(plugin.app); }
  get path(): string { return this.draft.path; }
  onOpen(): void {
    this.plugin.merges.add(this); this.modalEl.addClass('eh-merge-modal');
    this.titleEl.setText(`Объединить ${this.draft.path}`);
    const sources = this.contentEl.createDiv({ cls: 'eh-merge-sources' });
    for (const [title, content] of [['Общий предок', this.draft.baseContent], ['Текущая версия', this.draft.liveContent], ['Другая ветка', this.draft.branchContent]]) {
      const panel = sources.createDiv(); panel.createEl('strong', { text: title }); code(panel, content);
    }
    this.contentEl.createEl('p', { text: 'Проверьте результат и удалите все маркеры конфликтов. Черновик сохраняется локально и доступен после закрытия.' });
    this.editor = this.contentEl.createEl('textarea', { cls: 'eh-merge-editor', attr: { 'aria-label': 'Результат объединения', spellcheck: 'false' } });
    this.editor.value = this.draft.text;
    this.editor.addEventListener('input', () => {
      if (this.saveTimer != null) window.clearTimeout(this.saveTimer);
      this.saveTimer = window.setTimeout(() => { this.saveTimer = undefined; void this.persist().catch((e) => this.error(e)); }, 600);
    });
    this.errorEl = this.contentEl.createDiv({ cls: 'eh-error', attr: { role: 'status' } });
    const controls = this.contentEl.createDiv({ cls: 'eh-toolbar' });
    button(controls, 'Сохранить черновик', async () => { await this.persist(); if (!this.disposed) new Notice('Черновик сохранён.'); });
    button(controls, 'Применить результат', async () => {
      if (this.busy) return;
      this.lock(true);
      try {
        await this.persist();
        const editors = await this.plugin.flushEditors(this.draft.path);
        await this.plugin.service.finish(this.draft.path, this.editor.value, this.draft.live);
        this.completed = true;
        await this.plugin.updateEditors(this.draft.path, editors);
        this.close(); await this.refresh(); new Notice('Версии объединены.');
      } catch (e) {
        if (this.completed) { this.close(); await this.refresh(); this.plugin.error(e); }
        else this.error(e);
      } finally { this.lock(false); }
    }, 'mod-cta');
    button(controls, 'Отменить merge', async () => {
      if (this.busy) return;
      this.lock(true);
      if (this.saveTimer != null) window.clearTimeout(this.saveTimer);
      this.saveTimer = undefined;
      try { await this.saving; await this.plugin.service.abort(this.draft.path); this.completed = true; this.close(); await this.refresh(); }
      catch (e) { this.error(e); } finally { this.lock(false); }
    }, 'mod-warning');
  }
  persist(): Promise<unknown> {
    if (this.saveTimer != null) window.clearTimeout(this.saveTimer);
    this.saveTimer = undefined;
    if (this.completed || !this.editor) return Promise.resolve();
    const text = this.editor.value;
    // The transport serializes operations. Queue immediately so reopening the
    // dialog cannot read the old draft before this close-save reaches the queue.
    this.saving = this.plugin.service.saveDraft(this.draft.path, text);
    return this.saving;
  }
  onClose(): void {
    this.disposed = true;
    if (this.saveTimer != null) window.clearTimeout(this.saveTimer);
    this.plugin.merges.delete(this);
    if (!this.completed && !this.busy && !this.closingForUnload) void this.persist().catch((e) => this.plugin.error(e));
  }
  closeForUnload(): Promise<unknown> {
    this.closingForUnload = true;
    const save = this.persist();
    this.close();
    return save;
  }
  private lock(busy: boolean): void {
    this.busy = busy; this.editor.disabled = busy;
    this.contentEl.querySelectorAll('button').forEach((b) => { b.disabled = busy; });
  }
  private error(error: unknown): void {
    if (this.disposed) this.plugin.error(error);
    else this.errorEl.setText(error instanceof Error ? error.message : String(error));
  }
}
