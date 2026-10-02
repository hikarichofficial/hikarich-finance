"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { closeFiscalYear, reverseFiscalYearClosing } from "@/services/reports/reports";

/**
 * Server actions behind the year-end forms on Accounting Periods: the unmodified `close_fiscal_year`
 * (`periods.close`) and `reverse_fiscal_year_closing` (`periods.reopen`, recent step-up, a reason of at
 * least 10 characters).
 */

export interface FiscalYearState {
  status: "idle" | "ok" | "error";
  message?: string;
  stepUp?: boolean;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): FiscalYearState {
  if (error instanceof AuthzError) {
    return {
      status: "error",
      message: describeAuthzError(error),
      stepUp: error.code === "STEP_UP_REQUIRED",
    };
  }
  return { status: "error", message: fallback };
}

function revalidateYearEnd(): void {
  revalidatePath("/accounting/periods");
  revalidatePath("/accounting/journal");
  revalidatePath("/reports");
}

export async function closeFiscalYearAction(
  _previous: FiscalYearState,
  formData: FormData,
): Promise<FiscalYearState> {
  const entity = text(formData, "entity");
  const year = Number(text(formData, "fiscal_year"));
  try {
    const { membership } = await requirePermission("periods.close", { entityCode: entity });
    await closeFiscalYear({
      entity_id: membership.entity_id,
      fiscal_year: year,
      idempotency_key: randomUUID(),
    });
  } catch (error) {
    return errorState(
      error,
      "Tahun buku tidak dapat ditutup. Pastikan semua periode di tahun itu sudah ditutup dan tahun itu belum pernah ditutup.",
    );
  }
  revalidateYearEnd();
  return { status: "ok", message: `Tahun buku ${year} ditutup. Jurnal penutup sudah dibuat.` };
}

export async function reverseFiscalYearClosingAction(
  _previous: FiscalYearState,
  formData: FormData,
): Promise<FiscalYearState> {
  const entity = text(formData, "entity");
  const year = Number(text(formData, "fiscal_year"));
  try {
    const { membership } = await requirePermission("periods.reopen", { entityCode: entity });
    await reverseFiscalYearClosing({
      entity_id: membership.entity_id,
      fiscal_year: year,
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(
      error,
      "Penutupan tahun buku tidak dapat dibatalkan. Isi alasan minimal 10 karakter dan pastikan tahun itu memang sudah ditutup.",
    );
  }
  revalidateYearEnd();
  return { status: "ok", message: `Penutupan tahun buku ${year} dibatalkan.` };
}
