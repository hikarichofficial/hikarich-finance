import type { BackupKind } from "@/schemas/backup";

/**
 * Backup & Restore Center (P14, Step 01 #36, Step 16 §34, decision 224). The database owns every rule
 * (which tables each kind carries, Entity isolation, validation); this module holds labels, a plain
 * byte-size formatter and the "history/reminders" half of Step 01 #36 -- a pure function over the last
 * backup's timestamp, nothing stored or scheduled here.
 */

export const BACKUP_KIND_LABELS: Readonly<Record<BackupKind, string>> = {
  full: "Backup Penuh",
  data_only: "Backup Data Saja",
  documents_archive: "Arsip Dokumen",
};

export const BACKUP_KIND_DESCRIPTIONS: Readonly<Record<BackupKind, string>> = {
  full: "Seluruh data Entity, termasuk metadata dokumen dan jejak audit.",
  data_only:
    "Data operasional dan keuangan saat ini saja, tanpa jejak audit maupun metadata dokumen.",
  documents_archive:
    "Manifes dokumen milik Entity ini. Berkas fisik belum tersedia karena Supabase Storage belum " +
    "dikonfigurasi -- lihat catatan pada layar Backup & Restore.",
};

/** Human-readable byte size, base-1024, matching how file sizes are conventionally shown (KB/MB/GB, not
 * KiB/MiB) -- there is no existing formatter for this anywhere else in the codebase to reuse. */
export function formatByteSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "-";
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unitIndex]}`;
}

const REMINDER_THRESHOLD_DAYS = 30;

/** Whole days between `lastBackupAt` (a backup_jobs.created_at ISO timestamp, or null when none exists
 * yet) and `now`. Returns null when there is no backup to measure from at all -- the caller then shows
 * "never backed up" rather than a number of days, which `daysSinceLastBackup` itself does not decide. */
export function daysSinceLastBackup(lastBackupAt: string | null, now: Date): number | null {
  if (!lastBackupAt) return null;
  const last = new Date(lastBackupAt);
  if (Number.isNaN(last.getTime())) return null;
  const diffMs = now.getTime() - last.getTime();
  return Math.max(0, Math.floor(diffMs / (24 * 60 * 60 * 1000)));
}

/** Step 01 #36's "reminders": a plain, pure message decided from `daysSinceLastBackup`'s own output --
 * never a scheduled notification (no scheduling infrastructure exists for this yet), just what the
 * Backup & Restore Center screen shows the person on every visit. `null` days (never backed up) is
 * always a reminder; 30+ days is a reminder; anything sooner needs none. */
export function backupReminderMessage(daysSince: number | null): string | null {
  if (daysSince === null) {
    return "Belum pernah ada backup untuk Entity ini. Disarankan membuat Backup Penuh sekarang.";
  }
  if (daysSince >= REMINDER_THRESHOLD_DAYS) {
    return `Backup terakhir ${daysSince} hari yang lalu. Disarankan membuat backup baru.`;
  }
  return null;
}

// ------------------------------------------------------------ Part 2: restore (decision 247)

export const RESTORE_STATUS_LABELS: Readonly<Record<"completed" | "failed", string>> = {
  completed: "Berhasil",
  failed: "Gagal (tidak ada data yang ditulis)",
};

export const RESTORE_STATUS_TONES: Readonly<
  Record<"completed" | "failed", "success" | "critical">
> = {
  completed: "success",
  failed: "critical",
};

/** The typed confirmation must equal the Entity code exactly (the database applies the same rule; this is
 * only so the Restore button stays disabled until it matches). Surrounding whitespace is ignored. */
export function restoreConfirmMatches(typed: string, entityCode: string): boolean {
  return typed.trim() === entityCode;
}

/** Sum of a `{table: rows}` count record. */
export function totalRows(counts: Readonly<Record<string, number>>): number {
  return Object.values(counts).reduce((sum, n) => sum + n, 0);
}

/** Tables with at least one row, largest first, for a compact impact list. */
export function nonEmptyTables(
  counts: Readonly<Record<string, number>>,
): Array<{ table: string; rows: number }> {
  return Object.entries(counts)
    .filter(([, rows]) => rows > 0)
    .map(([table, rows]) => ({ table, rows }))
    .sort((a, b) => b.rows - a.rows || a.table.localeCompare(b.table));
}

/** Whether a restore may be started from a preview: the file is valid and the target is empty (both
 * reported by the database) and the step-up window is satisfied. */
export function restoreReady(preview: {
  ok: boolean;
  step_up_ok: boolean;
}): "ready" | "invalid" | "step_up" {
  if (!preview.ok) return "invalid";
  if (!preview.step_up_ok) return "step_up";
  return "ready";
}
