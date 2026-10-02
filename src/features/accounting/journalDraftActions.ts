"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { createJournalDraft } from "@/services/accounting/ledger";

/**
 * Server action behind Jurnal Manual: the unmodified `create_journal_draft` (`accounting.journal_create`;
 * an override reason also needs `accounting.protected_manage`). The journal is saved as a DRAFT; posting
 * stays on Journal Detail.
 */

export interface JournalDraftState {
  status: "idle" | "ok" | "error";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function createJournalDraftAction(
  _previous: JournalDraftState,
  formData: FormData,
): Promise<JournalDraftState> {
  const entity = text(formData, "entity");
  let lines: unknown;
  try {
    lines = JSON.parse(text(formData, "lines") || "[]");
  } catch {
    return { status: "error", message: "Baris jurnal tidak valid." };
  }
  if (!Array.isArray(lines) || lines.length < 2) {
    return {
      status: "error",
      message: "Isi minimal dua baris: akun dan jumlah debit atau kredit.",
    };
  }
  let journalId: string;
  try {
    const { membership } = await requirePermission("accounting.journal_create", {
      entityCode: entity,
    });
    journalId = await createJournalDraft({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      entry_type: text(formData, "entry_type") as never,
      entry_date: text(formData, "entry_date"),
      description: text(formData, "description"),
      lines: lines as never,
      override_reason: text(formData, "override_reason") || undefined,
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      const match = /^(?:INVALID|CONFLICT):\s*([\s\S]+)$/.exec(error.message);
      const base = authzErrorMessage(error.code);
      return { status: "error", message: match?.[1] ? `${base} (${match[1].trim()})` : base };
    }
    return {
      status: "error",
      message:
        "Jurnal tidak dapat disimpan. Periksa tanggal, penjelasan, akun tiap baris, dan pastikan total debit sama dengan total kredit.",
    };
  }
  revalidatePath("/accounting/journal");
  redirect(
    entity
      ? `/accounting/journal/${journalId}?entity=${encodeURIComponent(entity)}`
      : `/accounting/journal/${journalId}`,
  );
}
