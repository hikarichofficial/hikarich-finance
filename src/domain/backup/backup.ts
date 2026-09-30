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
