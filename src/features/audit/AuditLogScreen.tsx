import Link from "next/link";
import {
  AUDIT_OPERATION_FILTER_OPTIONS,
  AUDIT_OPERATION_LABELS,
  AUDIT_OPERATION_TONE,
  AUDIT_PAGE_SIZE,
  auditOperationOf,
  changedFieldNames,
  shortId,
  type AuditOperation,
} from "@/domain/audit/audit";
import type { AuditEventRow } from "@/schemas/audit";
import { formatAuditTimestamp } from "./format";

/**
 * Audit Log (P13 unbuilt-screens backlog, decision 242): the active Entity's audit trail, newest first,
 * filterable by operation and paged server-side. Shows which fields changed on an update, never their
 * values -- before/after states can hold financial detail a reviewer of the trail does not need to see in
 * bulk, and per-record history belongs on each record's own Activity tab. Read-only by nature: the table is
 * append-only.
 */

function buildHref(
  entity: string | undefined,
  operation: AuditOperation | undefined,
  offset: number,
): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (operation) params.set("op", operation);
  if (offset > 0) params.set("offset", String(offset));
  const qs = params.toString();
  return qs ? `/admin/audit?${qs}` : "/admin/audit";
}

function actorLabel(row: AuditEventRow, names: ReadonlyMap<string, string>): string {
  if (row.actor_type === "system") return "Sistem";
  if (row.actor_type === "public_token") return "Tautan publik";
  if (!row.actor_id) return "—";
  return names.get(row.actor_id) ?? `Pengguna ${shortId(row.actor_id)}`;
}

export function AuditLogScreen({
  rows,
  actorNames,
  activeOperation,
  offset,
  hasMore,
  entity,
}: {
  rows: readonly AuditEventRow[];
  actorNames: ReadonlyMap<string, string>;
  activeOperation: AuditOperation | undefined;
  offset: number;
  hasMore: boolean;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Log Audit</h1>
          <p className="list-screen-summary">
            {rows.length === 0
              ? "Tidak ada kejadian pada halaman ini."
              : `Kejadian ${offset + 1}–${offset + rows.length}, terbaru lebih dulu.`}
          </p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Saring jenis perubahan">
          {AUDIT_OPERATION_FILTER_OPTIONS.map((option) => (
            <Link
              key={option.label}
              href={buildHref(entity, option.value, 0)}
              className={
                option.value === activeOperation
                  ? "list-filter-tab list-filter-tab-active"
                  : "list-filter-tab"
              }
            >
              {option.label}
            </Link>
          ))}
        </nav>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>
            {activeOperation || offset > 0
              ? "Tidak ada kejadian audit untuk saringan atau halaman ini."
              : "Belum ada kejadian audit untuk entitas ini."}
          </p>
          {activeOperation || offset > 0 ? (
            <Link
              href={buildHref(entity, undefined, 0)}
              className="btn-secondary list-empty-action"
            >
              Hapus Saringan
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Waktu</th>
              <th scope="col">Tabel</th>
              <th scope="col">Aksi</th>
              <th scope="col">Pelaku</th>
              <th scope="col">Field Berubah</th>
              <th scope="col">Alasan</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const operation = auditOperationOf(row.action);
              const fields = changedFieldNames(row.before_state, row.after_state);
              return (
                <tr key={row.id}>
                  <td data-label="Waktu">{formatAuditTimestamp(row.occurred_at)}</td>
                  <td data-label="Tabel">
                    <code>{row.target_table}</code>
                  </td>
                  <td data-label="Aksi">
                    {operation ? (
                      <span
                        className={`status-badge status-badge-${AUDIT_OPERATION_TONE[operation]}`}
                      >
                        {AUDIT_OPERATION_LABELS[operation]}
                      </span>
                    ) : (
                      <code>{row.action}</code>
                    )}
                  </td>
                  <td data-label="Pelaku">{actorLabel(row, actorNames)}</td>
                  <td data-label="Field Berubah">{fields.length > 0 ? fields.join(", ") : "—"}</td>
                  <td data-label="Alasan">{row.reason ?? "—"}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}

      {offset > 0 || hasMore ? (
        <div className="list-screen-toolbar" aria-label="Navigasi halaman">
          {offset > 0 ? (
            <Link
              href={buildHref(entity, activeOperation, Math.max(0, offset - AUDIT_PAGE_SIZE))}
              className="btn-secondary"
            >
              Sebelumnya
            </Link>
          ) : null}
          {hasMore ? (
            <Link
              href={buildHref(entity, activeOperation, offset + AUDIT_PAGE_SIZE)}
              className="btn-secondary"
            >
              Berikutnya
            </Link>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
