export interface Branch {
  leaf: string; kind: 'divergent' | 'merged' | 'archived';
  writers: string[]; hashes: string[]; fork: string | null;
}
export interface Entry {
  path: string; hash: string; timestamp: number; writers: string[];
  live: boolean; snapshot: boolean; broken: boolean; parents: string[];
  branch: Branch | null;
}
export interface HistoryLog {
  path: string | null; entries: Entry[]; total: number; approximate: boolean;
  liveHash: string | null; exists: boolean; unrecorded: boolean;
  unsavedAfter: string | null; branches: Branch[];
  renamedFrom: { path: string; hash: string }[];
  renamedTo: { path: string; hash: string }[];
}
export interface Content { hash: string; content: string }
export interface Diff {
  left: Content; right: Content; unified: string;
  edits: { op: 'equal' | 'insert' | 'delete'; lines: string[] }[];
}
export interface Blame {
  hash: string;
  lines: { line: number; text: string; hash: string; writers: string[]; timestamp: number }[];
}
export interface Draft {
  exists: boolean; path: string; live: string; branch: string; base: string | null;
  created: number; conflicts: number; text: string; liveHash: string | null;
  baseContent: string; liveContent: string; branchContent: string;
}
export interface HistoryStatus {
  divergent: { path: string; branches: Branch[] }[];
  unrecorded: string[]; paths: string[];
  drafts: { path: string; live: string; branch: string; conflicts: number }[];
}
export interface HistorySettings {
  autoRecord: boolean; debounceMs: number; writer: string; extensions: string;
}
export interface HistoryTransport {
  request<T>(payload: Record<string, unknown>): Promise<T>;
  dispose(): void;
}
