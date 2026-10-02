"use client";

import { useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import {
  BACKUP_KIND_DESCRIPTIONS,
  BACKUP_KIND_LABELS,
  RESTORE_STATUS_LABELS,
  RESTORE_STATUS_TONES,
  formatByteSize,
  nonEmptyTables,
  restoreConfirmMatches,
  restoreReady,
  totalRows,
} from "@/domain/backup/backup";
import {
  RESTORE_FILE_MAX_BYTES,
  type BackupJobRow,
  type BackupKind,
  type RestoreJobRow,
  type RestorePreview,
  type RestoreResult,
} from "@/schemas/backup";
import { exportBackupAction, previewRestoreAction, restoreBackupAction } from "./actions";

const BACKUP_KINDS: readonly BackupKind[] = ["full", "data_only", "documents_archive"];

/** Saves the database's own serialisation byte-for-byte (no JSON round-trip, so exact money values and
 * the checksum survive). */
function triggerFileDownload(file: string, kind: BackupKind): void {
  const blob = new Blob([file], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const filename = `hikarich-backup-${kind}-${new Date().toISOString().slice(0, 10)}.json`;
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}

function ExportButtons({ entityId }: { entityId: string }) {
  const router = useRouter();
  const [pendingKind, setPendingKind] = useState<BackupKind | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function handleExport(kind: BackupKind): Promise<void> {
    setPendingKind(kind);
    setError(null);
    const result = await exportBackupAction(entityId, kind);
    setPendingKind(null);
    if (result.status === "error") {
      setError(result.message);
      return;
    }
    triggerFileDownload(result.file, result.kind);
    router.refresh();
  }

  return (
    <div className="dashboard-section">
      <h2>Buat Backup</h2>
      {error ? (
        <p role="alert" className="error">
          {error}
        </p>
      ) : null}
      <div className="backup-export-grid">
        {BACKUP_KINDS.map((kind) => (
          <div key={kind} className="backup-export-card">
            <h3>{BACKUP_KIND_LABELS[kind]}</h3>
            <p className="hint">{BACKUP_KIND_DESCRIPTIONS[kind]}</p>
            <button
              type="button"
              className="btn-primary"
              disabled={pendingKind !== null}
              onClick={() => void handleExport(kind)}
            >
              {pendingKind === kind ? "Membuat…" : `Unduh ${BACKUP_KIND_LABELS[kind]}`}
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

function BackupHistoryTable({ rows }: { rows: readonly BackupJobRow[] }) {
  return (
    <div className="dashboard-section">
      <h2>Riwayat Backup</h2>
      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Belum ada backup yang dibuat untuk Entity ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Waktu</th>
              <th scope="col">Jenis</th>
              <th scope="col">Jumlah Tabel</th>
              <th scope="col">Ukuran</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id}>
                <td>{new Date(row.created_at).toLocaleString("id-ID")}</td>
                <td>{BACKUP_KIND_LABELS[row.kind]}</td>
                <td>{row.table_count}</td>
                <td>{formatByteSize(row.byte_size)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

function CountList({ counts }: { counts: Readonly<Record<string, number>> }) {
  const rows = nonEmptyTables(counts);
  if (rows.length === 0) return <p className="hint">Tidak ada baris.</p>;
  return (
    <details>
      <summary>
        {totalRows(counts).toLocaleString("id-ID")} baris di {rows.length} tabel
      </summary>
      <ul className="hint">
        {rows.map((r) => (
          <li key={r.table}>
            {r.table}: {r.rows.toLocaleString("id-ID")}
          </li>
        ))}
      </ul>
    </details>
  );
}

function RestoreOutcome({ result }: { result: RestoreResult }) {
  const ok = result.status === "completed";
  return (
    <div className={ok ? "backup-validation-ok" : "backup-validation-fail"} role="status">
      <p>
        <strong>
          {ok
            ? "Pemulihan selesai dan lolos pemeriksaan integritas."
            : "Pemulihan gagal. Tidak ada data yang ditulis; percobaan ini tercatat di riwayat."}
        </strong>
      </p>
      {ok ? (
        <>
          <CountList counts={result.table_counts} />
          {result.skipped.entity_memberships ? (
            <p className="hint">
              {result.skipped.entity_memberships} keanggotaan pengguna di berkas tidak dipulihkan --
              atur ulang akses lewat Pengguna &amp; Peran.
            </p>
          ) : null}
        </>
      ) : (
        <p className="hint">{result.error ?? "Pemeriksaan integritas tidak lolos."}</p>
      )}
    </div>
  );
}

function RestoreFromFile({
  entityId,
  entityCode,
  stepUpHref,
}: {
  entityId: string;
  entityCode: string;
  stepUpHref: string;
}) {
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);
  const [fileText, setFileText] = useState<string | null>(null);
  const [fileName, setFileName] = useState<string | null>(null);
  const [preview, setPreview] = useState<RestorePreview | null>(null);
  const [confirm, setConfirm] = useState("");
  const [pending, setPending] = useState<"preview" | "restore" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [needsStepUp, setNeedsStepUp] = useState(false);
  const [result, setResult] = useState<RestoreResult | null>(null);

  function reset(): void {
    setFileText(null);
    setFileName(null);
    setPreview(null);
    setConfirm("");
    setError(null);
    setNeedsStepUp(false);
    if (inputRef.current) inputRef.current.value = "";
  }

  function handleFileChange(event: React.ChangeEvent<HTMLInputElement>): void {
    const file = event.target.files?.[0];
    setResult(null);
    setPreview(null);
    setConfirm("");
    setError(null);
    setNeedsStepUp(false);
    if (!file) return;
    if (file.size > RESTORE_FILE_MAX_BYTES) {
      setError(
        `Berkas terlalu besar (${formatByteSize(file.size)}). Batas unggah saat ini ` +
          `${formatByteSize(RESTORE_FILE_MAX_BYTES)}.`,
      );
      return;
    }
    setPending("preview");
    const reader = new FileReader();
    reader.onload = () => {
      void (async () => {
        const text = String(reader.result);
        const outcome = await previewRestoreAction(entityId, text);
        setPending(null);
        if (outcome.status === "error") {
          setError(outcome.message);
          return;
        }
        setFileText(text);
        setFileName(file.name);
        setPreview(outcome.preview);
      })();
    };
    reader.onerror = () => {
      setPending(null);
      setError("Gagal membaca berkas.");
    };
    reader.readAsText(file);
  }

  async function handleRestore(): Promise<void> {
    if (!fileText) return;
    setPending("restore");
    setError(null);
    const outcome = await restoreBackupAction(entityId, fileText, confirm.trim());
    setPending(null);
    if (outcome.status === "error") {
      setError(outcome.message);
      setNeedsStepUp(outcome.code === "STEP_UP_REQUIRED");
      return;
    }
    setResult(outcome.result);
    reset();
    router.refresh();
  }

  const readiness = preview ? restoreReady(preview) : null;
  const canSubmit =
    readiness === "ready" && restoreConfirmMatches(confirm, entityCode) && pending === null;

  return (
    <div className="dashboard-section">
      <h2>Pulihkan dari Berkas</h2>
      <p className="hint">
        Pemulihan hanya dapat dilakukan ke Entity yang masih kosong (belum berisi transaksi maupun
        data master). Berkas diperiksa lebih dulu -- checksum, kecocokan Entity, dan dampaknya --
        sebelum apa pun ditulis. Pemulihan berjalan sebagai satu transaksi: bila pemeriksaan
        integritas gagal, tidak ada data yang tertulis.
      </p>
      <input
        ref={inputRef}
        type="file"
        accept="application/json,.json"
        aria-label="Berkas backup"
        disabled={pending !== null}
        onChange={handleFileChange}
      />
      {pending === "preview" ? <p className="hint">Memeriksa berkas…</p> : null}
      {error ? (
        <p role="alert" className="error">
          {error}
          {needsStepUp ? (
            <>
              {" "}
              <Link href={stepUpHref}>Verifikasi sekarang</Link>.
            </>
          ) : null}
        </p>
      ) : null}
      {result ? <RestoreOutcome result={result} /> : null}
      {preview ? (
        <div className={preview.ok ? "backup-validation-ok" : "backup-validation-fail"}>
          <p>
            <strong>
              {preview.ok
                ? `Berkas ${fileName ?? ""} valid dan siap dipulihkan.`
                : `Berkas ${fileName ?? ""} tidak dapat dipulihkan.`}
            </strong>
          </p>
          {preview.errors.length > 0 ? (
            <ul>
              {preview.errors.map((message, index) => (
                <li key={index}>{message}</li>
              ))}
            </ul>
          ) : null}
          {preview.warnings.length > 0 ? (
            <ul className="hint">
              {preview.warnings.map((message, index) => (
                <li key={index}>{message}</li>
              ))}
            </ul>
          ) : null}
          <h3>Isi berkas yang akan dipulihkan</h3>
          <CountList counts={preview.table_counts} />
          {totalRows(preview.target_rows) > 0 ? (
            <>
              <h3>Data yang sudah ada di Entity ini</h3>
              <CountList counts={preview.target_rows} />
            </>
          ) : null}
          {readiness === "step_up" ? (
            <p role="alert" className="error">
              Pemulihan memerlukan verifikasi ulang (30 menit terakhir).{" "}
              <Link href={stepUpHref}>Verifikasi sekarang</Link>, lalu pilih berkas lagi.
            </p>
          ) : null}
          {readiness === "ready" ? (
            <div className="record-form">
              <label>
                Ketik kode Entity <strong>{entityCode}</strong> untuk mengonfirmasi
                <input
                  value={confirm}
                  onChange={(event) => setConfirm(event.target.value)}
                  autoComplete="off"
                  spellCheck={false}
                />
              </label>
              <div>
                <button
                  type="button"
                  className="btn-danger"
                  disabled={!canSubmit}
                  onClick={() => void handleRestore()}
                >
                  {pending === "restore" ? "Memulihkan…" : "Pulihkan sekarang"}
                </button>{" "}
                <button type="button" disabled={pending !== null} onClick={reset}>
                  Batal
                </button>
              </div>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function RestoreHistoryTable({ rows }: { rows: readonly RestoreJobRow[] }) {
  return (
    <div className="dashboard-section">
      <h2>Riwayat Pemulihan</h2>
      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Belum ada pemulihan untuk Entity ini.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Waktu</th>
              <th scope="col">Jenis Berkas</th>
              <th scope="col">Baris</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id}>
                <td>{new Date(row.created_at).toLocaleString("id-ID")}</td>
                <td data-label="Jenis Berkas">
                  {row.source_kind in BACKUP_KIND_LABELS
                    ? BACKUP_KIND_LABELS[row.source_kind as BackupKind]
                    : row.source_kind}
                </td>
                <td data-label="Baris">{totalRows(row.table_counts).toLocaleString("id-ID")}</td>
                <td data-label="Status">
                  <span className={`status-badge status-badge-${RESTORE_STATUS_TONES[row.status]}`}>
                    {RESTORE_STATUS_LABELS[row.status]}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

/**
 * Backup & Restore Center (P14, Step 01 #36, Step 16 §34, decisions 224 and 247): export (Full/Data-only/
 * Documents Archive, saved exactly as the database serialised it), backup history, and -- for
 * `backup.restore` holders -- restore into an empty Entity (OWNER decision 247): pick a file, see the
 * database's own validation and impact preview, step up, type the Entity code, restore; plus restore
 * history. The database enforces every one of those rules again.
 */
export function BackupRestoreScreen({
  entityId,
  entityCode,
  history,
  restoreHistory,
  reminder,
  canRestore,
  stepUpHref,
}: {
  entityId: string;
  entityCode: string;
  history: readonly BackupJobRow[];
  restoreHistory: readonly RestoreJobRow[];
  reminder: string | null;
  canRestore: boolean;
  stepUpHref: string;
}) {
  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Administrasi</p>
          <h1>Backup &amp; Restore Center</h1>
        </div>
      </header>
      {reminder ? (
        <div className="dashboard-section">
          <p role="status" className="hint">
            {reminder}
          </p>
        </div>
      ) : null}
      <ExportButtons entityId={entityId} />
      <BackupHistoryTable rows={history} />
      {canRestore ? (
        <>
          <RestoreFromFile entityId={entityId} entityCode={entityCode} stepUpHref={stepUpHref} />
          <RestoreHistoryTable rows={restoreHistory} />
        </>
      ) : null}
    </div>
  );
}
