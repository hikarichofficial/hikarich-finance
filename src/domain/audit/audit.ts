/**
 * Pure helpers for the Audit Log screen (P13 unbuilt-screens backlog, decision 242). The audit trigger
 * (`app_private.tg_audit`, P1) writes `action` as `<table>.<insert|update|delete>`; everything here only
 * reads that shape back for display. Nothing here calls the database.
 */

export type AuditOperation = "insert" | "update" | "delete";

export const AUDIT_OPERATION_LABELS: Readonly<Record<AuditOperation, string>> = {
  insert: "Dibuat",
  update: "Diubah",
  delete: "Dihapus",
};

export const AUDIT_OPERATION_TONE: Readonly<
  Record<AuditOperation, "success" | "progress" | "critical">
> = {
  insert: "success",
  update: "progress",
  delete: "critical",
};

export const AUDIT_OPERATION_FILTER_OPTIONS: readonly {
  readonly value: AuditOperation | undefined;
  readonly label: string;
}[] = [
  { value: undefined, label: "Semua" },
  { value: "insert", label: AUDIT_OPERATION_LABELS.insert },
  { value: "update", label: AUDIT_OPERATION_LABELS.update },
  { value: "delete", label: AUDIT_OPERATION_LABELS.delete },
];

export const AUDIT_PAGE_SIZE = 50;

/** An unknown or absent `?op=` shows everything; `Object.hasOwn` keeps prototype keys out. */
export function parseAuditOperation(value: string | undefined): AuditOperation | undefined {
  return value !== undefined && Object.hasOwn(AUDIT_OPERATION_LABELS, value)
    ? (value as AuditOperation)
    : undefined;
}

/** `?offset=` as a non-negative multiple of the page size; anything else falls back to the first page. */
export function parseAuditOffset(value: string | undefined): number {
  if (value === undefined || !/^\d+$/.test(value)) return 0;
  const n = Number(value);
  return Number.isSafeInteger(n) && n % AUDIT_PAGE_SIZE === 0 ? n : 0;
}

/** The operation half of `<table>.<op>`, or `undefined` for an action written in any other shape. */
export function auditOperationOf(action: string): AuditOperation | undefined {
  const op = action.slice(action.lastIndexOf(".") + 1);
  return parseAuditOperation(op);
}

/** Bookkeeping columns every audited table carries; a change to only these is never interesting, and the
 * trigger itself already skips an update where nothing else changed. */
const BOOKKEEPING_FIELDS: ReadonlySet<string> = new Set([
  "updated_at",
  "updated_by",
  "version",
  "created_at",
  "created_by",
]);

/** Names (never values) of the fields that differ between the before and after state, sorted, without
 * bookkeeping columns. An insert or delete lists no fields: the whole row was created or removed. */
export function changedFieldNames(
  before: Readonly<Record<string, unknown>> | null,
  after: Readonly<Record<string, unknown>> | null,
): string[] {
  if (!before || !after) return [];
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
  return [...keys]
    .filter((key) => !BOOKKEEPING_FIELDS.has(key))
    .filter((key) => JSON.stringify(before[key]) !== JSON.stringify(after[key]))
    .sort();
}

/** First 8 characters of a uuid, for an actor whose profile the viewer may not read. */
export function shortId(id: string): string {
  return id.slice(0, 8);
}
