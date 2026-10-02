import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

export const notices: string[] = [];
export class Notice { constructor(text: string) { notices.push(text); } }
export class TFile { constructor(public path: string) {} }
export class FileSystemAdapter {
  constructor(private root: string) {}
  getBasePath(): string { return this.root; }
  async read(path: string): Promise<string> { return readFileSync(join(this.root, path), 'utf8'); }
}
class Events {
  callbacks = new Map<string, Set<(...args: any[]) => void>>();
  on(name: string, callback: (...args: any[]) => void): { cleanup(): void } {
    const set = this.callbacks.get(name) ?? new Set(); this.callbacks.set(name, set); set.add(callback);
    return { cleanup: () => { set.delete(callback); } };
  }
  emit(name: string, ...args: any[]): void { for (const callback of this.callbacks.get(name) ?? []) callback(...args); }
}
export class MarkdownView {
  file: TFile;
  text: string;
  editor = { getValue: () => this.text, setValue: (s: string) => { this.text = s; }, getCursor: () => ({ line: 0, ch: 0 }), setCursor: () => {} };
  constructor(path: string, text: string) { this.file = new TFile(path); this.text = text; }
  getMode(): string { return 'source'; }
}
export function createApp(root: string): any {
  const workspace: any = new Events();
  workspace.leaves = []; workspace.views = new Map(); workspace.layout = [];
  workspace.getLeavesOfType = (type: string) => workspace.leaves.filter((leaf: any) => type === 'markdown' ? leaf.view instanceof MarkdownView : leaf.view?.getViewType?.() === type);
  workspace.getActiveFile = () => workspace.getLeavesOfType('markdown')[0]?.view.file;
  workspace.onLayoutReady = (callback: () => void) => workspace.layout.push(callback);
  workspace.ready = () => { for (const callback of workspace.layout.splice(0)) callback(); };
  const leaf = () => ({ app, view: undefined as any,
    async setViewState(state: any) { this.view = workspace.views.get(state.type)(this); workspace.leaves.push(this); await this.view.onOpen(); },
    async openFile(file: TFile) { workspace.opened = file.path; } });
  workspace.getRightLeaf = leaf; workspace.getLeaf = leaf; workspace.revealLeaf = async () => {};
  const vault: any = new Events(); vault.adapter = new FileSystemAdapter(root); vault.configDir = '.obsidian';
  vault.getFileByPath = (path: string) => existsSync(join(root, path)) ? new TFile(path) : null;
  vault.getMarkdownFiles = () => workspace.getLeavesOfType('markdown').map((leaf: any) => leaf.view.file);
  vault.read = async (file: TFile) => vault.adapter.read(file.path);
  vault.modify = async (file: TFile, text: string) => {
    mkdirSync(dirname(join(root, file.path)), { recursive: true }); writeFileSync(join(root, file.path), text);
    vault.emit('modify', file);
  };
  vault.process = async (file: TFile, callback: (s: string) => string) => vault.modify(file, callback(await vault.read(file)));
  const app = { workspace, vault };
  return app;
}
export class Plugin {
  commands = new Map<string, any>(); cleanups: (() => void)[] = [];
  constructor(public app: any, public manifest: any) {}
  async loadData(): Promise<unknown> { return null; }
  async saveData(): Promise<void> {}
  registerView(type: string, factory: any): void { this.app.workspace.views.set(type, factory); }
  registerEvent(event: { cleanup(): void }): void { this.cleanups.push(() => event.cleanup()); }
  addCommand(command: any): void { this.commands.set(command.id, command); }
  addRibbonIcon(): void {}
  addSettingTab(): void {}
  cleanup(): void { for (const callback of this.cleanups.splice(0)) callback(); }
}
export class ItemView {
  contentEl = document.createElement('div'); intervals: number[] = []; app: any;
  constructor(public leaf: any) { this.app = leaf.app; document.body.append(this.contentEl); }
  registerInterval(id: number): void { this.intervals.push(id); }
  cleanup(): void { for (const id of this.intervals) window.clearInterval(id); this.contentEl.remove(); }
}
export class Modal {
  static opened: Modal[] = [];
  modalEl = document.createElement('div'); titleEl = document.createElement('h2'); contentEl = document.createElement('div');
  constructor(public app: any) { this.modalEl.append(this.titleEl, this.contentEl); }
  open(): void { Modal.opened.push(this); document.body.append(this.modalEl); (this as any).onOpen?.(); }
  close(): void { Modal.opened = Modal.opened.filter((modal) => modal !== this); (this as any).onClose?.(); this.modalEl.remove(); }
}
export class PluginSettingTab { containerEl = document.createElement('div'); constructor(public app: any, public plugin: any) {} }
export class Setting {
  constructor(_parent: HTMLElement) {}
  setName(): this { return this; } setDesc(): this { return this; }
  addToggle(): this { return this; } addText(): this { return this; } addButton(): this { return this; }
}

export function installDomHelpers(): void {
  const proto = window.HTMLElement.prototype as any;
  proto.empty = function () { this.replaceChildren(); };
  proto.addClass = function (name: string) { this.classList.add(name); };
  proto.setText = function (text: string) { this.textContent = text; };
  proto.createEl = function (tag: string, options: any = {}) {
    const el = document.createElement(tag);
    if (options.text != null) el.textContent = options.text;
    if (options.cls) el.className = options.cls;
    for (const key of ['type', 'placeholder', 'value']) if (options[key]) el.setAttribute(key, options[key]);
    for (const [key, value] of Object.entries(options.attr ?? {})) el.setAttribute(key, String(value));
    this.append(el); return el;
  };
  proto.createDiv = function (options: any = {}) { return this.createEl('div', options); };
}
