"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { setFlash } from "@/lib/flash";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { mapImportTable, parseDelimited } from "@/domain/imports/csv";
import { importDomainSchema } from "@/schemas/imports";
import { requirePermission } from "@/services/identity/access";
import {
  commitImportBatch,
  rollbackImportBatch,
  stageImportBatch,
  validateImportBatch,
} from "@/services/imports/imports";
import type { ImportActionState } from "./importActionsState";

/**
 * Server actions of the Import Wizard (Step 15 §15, decisions 140/143, 275). The table is parsed and its
 * columns mapped here (application layer); `stage_import_batch`, `validate_import_batch`,
 * `commit_import_batch` and `rollback_import_batch` are the unmodified P11 RPCs and own every rule.
 */

const MAX_ROWS = 5000;

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): ImportActionState {
  if (error instanceof AuthzError) return { status: "error", message: describeAuthzError(error) };
  return { status: "error", message: fallback };
}

function detailPath(batchId: string, entity: string): string {
  return entity
    ? `/admin/imports/${batchId}?entity=${encodeURIComponent(entity)}`
    : `/admin/imports/${batchId}`;
}

export async function stageImportAction(
  _previous: ImportActionState,
  formData: FormData,
): Promise<ImportActionState> {
  const entity = text(formData, "entity");
  const domain = importDomainSchema.safeParse(text(formData, "domain"));
  if (!domain.success) return { status: "error", message: "Pilih jenis data yang diimpor." };
  const raw = formData.get("table");
  const table = parseDelimited(typeof raw === "string" ? raw : "");
  if (table.length < 2) {
    return {
      status: "error",
      message: "Isi tabel dengan satu baris judul kolom dan minimal satu baris data.",
    };
  }
  const mapped = mapImportTable(domain.data, table);
  if (mapped.missingFields.length > 0) {
    return {
      status: "error",
      message: `Kolom wajib belum ada: ${mapped.missingFields.map((f) => f.label).join(", ")}.`,
    };
  }
  if (mapped.rows.length > MAX_ROWS) {
    return { status: "error", message: `Satu kali impor maksimal ${MAX_ROWS} baris.` };
  }
  let batchId: string;
  try {
    const { membership } = await requirePermission("system.import", { entityCode: entity });
    batchId = await stageImportBatch({
      entity_id: membership.entity_id,
      domain: domain.data,
      mapping: mapped.mapping,
      rows: mapped.rows,
      source_file_name: text(formData, "file_name") || undefined,
    });
    await validateImportBatch({ batch_id: batchId });
  } catch (error) {
    return errorState(error, "Data tidak dapat disiapkan untuk impor. Periksa isi tabel.");
  }
  revalidatePath("/admin/imports");
  await setFlash("Berkas impor diterima. Periksa barisnya sebelum diproses.");
  redirect(detailPath(batchId, entity));
}

export async function validateImportAction(
  _previous: ImportActionState,
  formData: FormData,
): Promise<ImportActionState> {
  const batchId = text(formData, "batch_id");
  let result;
  try {
    result = await validateImportBatch({ batch_id: batchId });
  } catch (error) {
    return errorState(error, "Batch tidak dapat diperiksa.");
  }
  revalidatePath(`/admin/imports/${batchId}`);
  return {
    status: "ok",
    message: `Diperiksa: ${result.valid_rows} valid, ${result.invalid_rows} tidak valid, ${result.duplicate_rows} duplikat.`,
  };
}

export async function commitImportAction(
  _previous: ImportActionState,
  formData: FormData,
): Promise<ImportActionState> {
  const batchId = text(formData, "batch_id");
  let result;
  try {
    result = await commitImportBatch({ batch_id: batchId });
  } catch (error) {
    return errorState(error, "Batch tidak dapat diterapkan.");
  }
  revalidatePath("/admin/imports");
  revalidatePath(`/admin/imports/${batchId}`);
  return {
    status: "ok",
    message: `${result.committed_rows} baris masuk ke pembukuan, ${result.skipped_rows} baris dilewati.`,
  };
}

export async function rollbackImportAction(
  _previous: ImportActionState,
  formData: FormData,
): Promise<ImportActionState> {
  const batchId = text(formData, "batch_id");
  const reason = text(formData, "reason");
  if (reason.length < 3) return { status: "error", message: "Tulis alasan pembatalan." };
  let result;
  try {
    result = await rollbackImportBatch({ batch_id: batchId, reason });
  } catch (error) {
    return errorState(error, "Batch tidak dapat dibatalkan.");
  }
  revalidatePath("/admin/imports");
  revalidatePath(`/admin/imports/${batchId}`);
  return {
    status: "ok",
    message: `${result.rolled_back_rows} baris dibatalkan, ${result.retained_rows} baris tetap karena sudah dipakai transaksi lain.`,
  };
}
