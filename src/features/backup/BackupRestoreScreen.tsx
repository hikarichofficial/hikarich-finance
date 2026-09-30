"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import {
  BACKUP_KIND_DESCRIPTIONS,
  BACKUP_KIND_LABELS,
  formatByteSize,
} from "@/domain/backup/backup";
import type {
  BackupJobRow,
  BackupKind,
  BackupSnapshot,
  BackupValidationResult,
} from "@/schemas/backup";
import { exportBackupAction, validateBackupAction } from "./actions";

const BACKUP_KINDS: readonly BackupKind[] = ["full", "data_only", "documents_archive"];

function triggerJsonDownload(snapshot: BackupSnapshot): void {
  const blob = new Blob([JSON.stringify(snapshot, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const filename = `hikarich-backup-${snapshot.kind}-${snapshot.created_at.slice(0, 10)}.json`;
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
    triggerJsonDownload(result.snapshot);
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

function ValidateBeforeRestore({ entityId }: { entityId: string }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<BackupValidationResult | null>(null);

  function handleFileChange(event: React.ChangeEvent<HTMLInputElement>): void {
    const file = event.target.files?.[0];
    if (!file) return;
    setPending(true);
    setError(null);
    setResult(null);
    const reader = new FileReader();
    reader.onload = () => {
      void (async () => {
        let payload: unknown;
        try {
          payload = JSON.parse(String(reader.result));
        } catch {
          setPending(false);
          setError("Berkas yang dipilih bukan JSON yang valid.");
          return;
        }
        const outcome = await validateBackupAction(entityId, payload);
        setPending(false);
        if (outcome.status === "error") {
          setError(outcome.message);
          return;
        }
        setResult(outcome.result);
      })();
    };
    reader.onerror = () => {
      setPending(false);
      setError("Gagal membaca berkas.");
    };
    reader.readAsText(file);
    if (inputRef.current) inputRef.current.value = "";
  }

  return (
    <div className="dashboard-section">
      <h2>Validasi Sebelum Pemulihan</h2>
      <p className="hint">
        Unggah berkas backup (.json) untuk memeriksa apakah berkas tersebut valid dan cocok dengan
        Entity ini, sebelum dipulihkan. Pemulihan sesungguhnya belum tersedia pada peningkatan ini
        -- akan tersedia pada peningkatan berikutnya.
      </p>
      <input
        ref={inputRef}
        type="file"
        accept="application/json"
        disabled={pending}
        onChange={handleFileChange}
      />
      {pending ? <p className="hint">Memeriksa berkas…</p> : null}
      {error ? (
        <p role="alert" className="error">
          {error}
        </p>
      ) : null}
      {result ? (
        <div className={result.ok ? "backup-validation-ok" : "backup-validation-fail"}>
          <p>
            <strong>{result.ok ? "Berkas valid." : "Berkas tidak valid."}</strong>
          </p>
          {result.errors.length > 0 ? (
            <ul>
              {result.errors.map((message, index) => (
                <li key={index}>{message}</li>
              ))}
            </ul>
          ) : null}
          {result.warnings.length > 0 ? (
            <ul className="hint">
              {result.warnings.map((message, index) => (
                <li key={index}>{message}</li>
              ))}
            </ul>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

/**
 * Backup & Restore Center (P14, Step 01 #36, Step 16 §34, decision 224), Part 1: export (Full/Data-only/
 * Documents Archive, each a browser download built client-side from the RPC's own JSON payload -- no
 * server route handler exists in this codebase to stream a file, and none is needed for a JSON blob),
 * history and validate-before-restore. The actual restore-write path is Part 2, deliberately deferred --
 * `ValidateBeforeRestore` says so plainly rather than implying a restore button is coming right after.
 */
export function BackupRestoreScreen({
  entityId,
  history,
  reminder,
  canRestore,
}: {
  entityId: string;
  history: readonly BackupJobRow[];
  reminder: string | null;
  canRestore: boolean;
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
      {canRestore ? <ValidateBeforeRestore entityId={entityId} /> : null}
    </div>
  );
}
