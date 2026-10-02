import { hostname } from 'node:os';
import { join } from 'node:path';
import { FileSystemAdapter, MarkdownView, Notice, Plugin, PluginSettingTab, Setting, TFile } from 'obsidian';
import { BridgeClient, HistoryError } from './client';
import { EngineInstaller, historyRelease } from './engineInstaller';
import { HistoryService, SaveRecorder } from './service';
import type { HistorySettings } from './types';
import { HistoryView, VIEW_TYPE, type MergeModal } from './view';

export default class EntropyHistoryPlugin extends Plugin {
  settings: HistorySettings = { autoRecord: false, debounceMs: 1500, writer: `Obsidian@${hostname()}`, extensions: '.md' };
  service!: HistoryService;
  private recorder!: SaveRecorder;
  readonly merges = new Set<MergeModal>();
  private closed = false;
  private installer?: EngineInstaller;

  async onload(): Promise<void> {
    this.settings = Object.assign({}, this.settings, await this.loadData());
    const adapter = this.app.vault.adapter;
    if (!(adapter instanceof FileSystemAdapter)) {
      new Notice('Entropy History поддерживает файловые vault на компьютере.'); return;
    }
    const folder = adapter.getBasePath();
    const pluginDir = join(folder, this.manifest.dir ?? `${this.app.vault.configDir}/plugins/${this.manifest.id}`);
    this.installer = new EngineInstaller(pluginDir, historyRelease);
    const client = new BridgeClient(() => this.installer!.executable());
    this.service = new HistoryService(client, folder, () => this.settings);
    this.recorder = new SaveRecorder(this.service, () => this.settings.debounceMs, (e) => {
      if (!(e instanceof HistoryError && e.code === 'not_tracked') && !this.closed) this.error(e);
    });
    this.registerView(VIEW_TYPE, (leaf) => new HistoryView(leaf, this));
    this.addRibbonIcon('history', 'История текущего файла', () => { void this.openHistory(); });
    this.addCommand({ id: 'open-history', name: 'История текущего файла', callback: () => { void this.openHistory(); } });
    this.addCommand({ id: 'vault-history', name: 'История всего vault', callback: () => { void this.openHistory(undefined, true); } });
    this.addCommand({ id: 'record-note', name: 'Записать версию текущего файла', checkCallback: (checking) => {
      const file = this.app.workspace.getActiveFile();
      if (!file) return false;
      if (!checking) void this.record(file.path);
      return true;
    } });
    this.addCommand({ id: 'record-vault', name: 'Записать изменения vault', callback: () => { void this.record(); } });
    this.addCommand({ id: 'show-divergence', name: 'Расхождения и незавершённые merge', callback: () => {
      void this.openHistory(undefined, true).then((view) => view?.showStatus());
    } });
    this.addSettingTab(new HistorySettingTab(this));
    this.registerEvent(this.app.workspace.on('file-open', (file) => {
      if (!file) return;
      for (const leaf of this.app.workspace.getLeavesOfType(VIEW_TYPE)) {
        const view = leaf.view as HistoryView;
        if (view.followActive) view.showPath(file.path, true);
      }
    }));
    this.registerEvent(this.app.workspace.on('file-menu', (menu, file) => {
      if (!(file instanceof TFile)) return;
      menu.addItem((item) => item.setTitle('Entropy: история файла').setIcon('history').onClick(() => { void this.openHistory(file.path); }));
      menu.addItem((item) => item.setTitle('Entropy: записать версию').setIcon('save').onClick(() => { void this.record(file.path); }));
    }));
    // Register only after discovery, so opening a vault cannot mint versions.
    this.app.workspace.onLayoutReady(() => {
      if (this.closed) return;
      this.registerEvent(this.app.vault.on('modify', (file) => this.fileChanged(file)));
      this.registerEvent(this.app.vault.on('create', (file) => this.fileChanged(file)));
      this.registerEvent(this.app.vault.on('delete', (file) => {
        if (this.settings.autoRecord && file instanceof TFile) this.recorder.deleted(file.path);
        this.refreshViews();
      }));
      this.registerEvent(this.app.vault.on('rename', (file, oldPath) => {
        if (this.settings.autoRecord && file instanceof TFile) this.recorder.renamed(oldPath, file.path);
        for (const leaf of this.app.workspace.getLeavesOfType(VIEW_TYPE)) {
          const view = leaf.view as HistoryView;
          if (view.path === oldPath) view.showPath(file.path, view.followActive);
        }
        this.refreshViews();
      }));
    });
  }

  onunload(): void {
    this.closed = true;
    this.installer?.cancelDownload();
    this.recorder?.dispose();
    // Finish local draft saves before killing the owned bridge processes.
    const saves = [...this.merges].map((modal) => modal.closeForUnload());
    void Promise.allSettled(saves).finally(() => { this.installer?.dispose(); this.service?.dispose(); });
  }

  private fileChanged(file: unknown): void {
    if (file instanceof TFile && this.settings.autoRecord) this.recorder.changed(file.path);
    this.refreshViews();
  }

  refreshViews(): void {
    if (this.closed) return;
    for (const leaf of this.app.workspace.getLeavesOfType(VIEW_TYPE)) (leaf.view as HistoryView).scheduleRefresh();
  }

  async openHistory(path?: string, vaultWide = false): Promise<HistoryView | undefined> {
    try {
      let leaf = this.app.workspace.getLeavesOfType(VIEW_TYPE)[0];
      if (!leaf) {
        leaf = this.app.workspace.getRightLeaf(false) ?? this.app.workspace.getLeaf('tab');
        await leaf.setViewState({ type: VIEW_TYPE, active: true });
      }
      const view = leaf.view as HistoryView;
      if (vaultWide) view.showVault();
      else view.showPath(path ?? this.app.workspace.getActiveFile()?.path, path == null);
      await this.app.workspace.revealLeaf(leaf);
      return view;
    } catch (e) { this.error(e); return undefined; }
  }

  async record(path?: string): Promise<void> {
    try {
      if (path) await this.flushEditors(path);
      else for (const file of this.app.vault.getMarkdownFiles()) await this.flushEditors(file.path);
      const result = await this.service.record(path);
      new Notice(result.message);
      this.refreshViews();
    } catch (e) { this.error(e); }
  }

  /** Save the buffer using Vault.process's current-content guard. */
  async flushEditors(path: string): Promise<Map<MarkdownView, string>> {
    const editors = new Map<MarkdownView, string>();
    for (const leaf of this.app.workspace.getLeavesOfType('markdown')) {
      const view = leaf.view;
      if (view instanceof MarkdownView && view.file?.path === path && view.getMode() === 'source') editors.set(view, view.editor.getValue());
    }
    if (new Set(editors.values()).size > 1) throw new Error('В открытых панелях разные правки этого файла. Сохраните их перед восстановлением.');
    const file = this.app.vault.getFileByPath(path);
    if (file && editors.size) {
      const text = [...editors.values()][0];
      const before = await this.app.vault.read(file);
      if (before !== text) await this.app.vault.process(file, (current) => {
        if (current !== before) throw new Error('Файл изменился во время сохранения редактора. Обновите историю.');
        return text;
      });
    }
    return editors;
  }

  /** Keep an edit typed during the request; otherwise refresh from the restored file. */
  async updateEditors(path: string, editors: Map<MarkdownView, string>): Promise<void> {
    const file = this.app.vault.getFileByPath(path);
    if (!file) { this.refreshViews(); return; }
    const content = await this.app.vault.adapter.read(path);
    for (const [view, before] of editors) {
      // Obsidian's file watcher may already have loaded the restored content.
      if (view.file?.path === path && view.editor.getValue() !== before && view.editor.getValue() !== content) {
        await this.app.vault.modify(file, view.editor.getValue());
        await this.service.record(path);
        throw new Error('Во время операции появилась новая правка в редакторе. Она сохранена; повторите действие после проверки.');
      }
    }
    await this.app.vault.modify(file, content);
    for (const [view] of editors) {
      if (view.file?.path === path) {
        const cursor = view.editor.getCursor();
        view.editor.setValue(content); view.editor.setCursor(cursor);
      }
    }
    this.refreshViews();
  }

  error(error: unknown): void { if (!this.closed) new Notice(`История: ${error instanceof Error ? error.message : String(error)}`, 8000); }
}

class HistorySettingTab extends PluginSettingTab {
  constructor(private readonly plugin: EntropyHistoryPlugin) { super(plugin.app, plugin); }
  display(): void {
    this.containerEl.empty();
    this.containerEl.createEl('h2', { text: 'Entropy History' });
    new Setting(this.containerEl).setName('Записывать сохранения').setDesc('Автоматически сохранять версии после правок. Можно оставить выключенным, если историю уже записывает entropyd.').addToggle((toggle) => toggle.setValue(this.plugin.settings.autoRecord).onChange(async (value) => {
      this.plugin.settings.autoRecord = value; await this.plugin.saveData(this.plugin.settings);
    }));
    new Setting(this.containerEl).setName('Задержка записи, мс').setDesc('Объединяет несколько быстрых сохранений в одну версию.').addText((text) => text.setValue(String(this.plugin.settings.debounceMs)).onChange(async (value) => {
      const ms = Number(value);
      if (Number.isFinite(ms) && ms >= 250 && ms <= 60_000) {
        this.plugin.settings.debounceMs = ms; await this.plugin.saveData(this.plugin.settings);
      }
    }));
    new Setting(this.containerEl).setName('Имя этого устройства').addText((text) => text.setValue(this.plugin.settings.writer).onChange(async (value) => {
      if (value.trim()) { this.plugin.settings.writer = value.trim(); await this.plugin.saveData(this.plugin.settings); }
    }));
    new Setting(this.containerEl).setName('Расширения').setDesc('Через запятую: .md,.txt. * — любые текстовые файлы. Ignore-файлы учитываются всегда.').addText((text) => text.setValue(this.plugin.settings.extensions).onChange(async (value) => {
      const items = value.split(',').map((s) => s.trim());
      if (items.length && items.every((s) => s === '*' || /^\.[a-zA-Z0-9]+$/.test(s))) {
        this.plugin.settings.extensions = items.join(','); await this.plugin.saveData(this.plugin.settings);
      }
    }));
    new Setting(this.containerEl).setName('История vault').addButton((button) => button.setButtonText('Открыть').onClick(() => { void this.plugin.openHistory(undefined, true); }));
  }
}
