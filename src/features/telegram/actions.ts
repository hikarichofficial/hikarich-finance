"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { parseAmounts } from "@/domain/telegram/rupiah";
import { getServerEnv } from "@/lib/env";
import { requirePermission } from "@/services/identity/access";
import { getMe, setWebhook, telegramConfigured } from "@/services/telegram/api";
import {
  createTelegramLinkCode,
  getMyTelegramLink,
  revokeTelegramLink,
  updateTelegramSettings,
} from "@/services/telegram/link";

/**
 * Server Actions of the Telegram settings screen (decision 422). Creating a code and raising the limit demand a
 * fresh authenticator code; the database says so with `STEP_UP_REQUIRED`, which opens the verification popup and sends
 * the form again. Registering the webhook changes the bot for the whole system, so it is gated like the other
 * system-wide actions (`backup.create`, held by the OWNER only).
 */

export interface TelegramActionState {
  status: "idle" | "ok" | "error";
  message?: string;
  /** A freshly made pairing code. Shown once; never stored in the page. */
  code?: string;
  expiresAt?: string;
}

function fail(error: unknown, fallback: string): TelegramActionState {
  if (error instanceof AuthzError) return { status: "error", message: describeAuthzError(error) };
  return { status: "error", message: fallback };
}

export async function createCodeAction(): Promise<TelegramActionState> {
  try {
    await requirePermission("bills.create");
    const made = await createTelegramLinkCode();
    return {
      status: "ok",
      message: "Kode dibuat. Kirim ke bot dalam 10 menit.",
      code: made.code,
      expiresAt: made.expiresAt,
    };
  } catch (error) {
    return fail(error, "Kode tidak dapat dibuat.");
  }
}

export async function revokeLinkAction(): Promise<TelegramActionState> {
  try {
    await requirePermission("bills.create");
    await revokeTelegramLink();
  } catch (error) {
    return fail(error, "Tautan tidak dapat diputus.");
  }
  revalidatePath("/admin/telegram");
  return { status: "ok", message: "Telegram diputus. Bot tidak bisa lagi mencatat." };
}

function flag(formData: FormData, name: string): boolean {
  return formData.get(name) === "on";
}

export async function saveSettingsAction(
  _previous: TelegramActionState,
  formData: FormData,
): Promise<TelegramActionState> {
  const raw = formData.get("max_entry_amount");
  const parsed =
    typeof raw === "string" ? parseAmounts(/rp/i.test(raw) ? raw : `Rp ${raw}`)[0] : undefined;
  if (!parsed)
    return { status: "error", message: "Isi batas nominal per catatan, mis. 5.000.000." };
  try {
    await requirePermission("bills.create");
    const current = await getMyTelegramLink();
    await updateTelegramSettings({
      maxEntryAmount: parsed.value,
      reportDaily: flag(formData, "report_daily"),
      reportWeekly: flag(formData, "report_weekly"),
      reportMonthly: flag(formData, "report_monthly"),
      defaultEntity: current.linked ? current.default_entity_id : null,
    });
  } catch (error) {
    return fail(error, "Pengaturan tidak dapat disimpan.");
  }
  revalidatePath("/admin/telegram");
  return { status: "ok", message: "Pengaturan Telegram disimpan." };
}

export async function registerWebhookAction(): Promise<TelegramActionState> {
  try {
    await requirePermission("backup.create");
  } catch (error) {
    return fail(error, "Tidak diizinkan.");
  }
  const env = getServerEnv();
  if (!telegramConfigured() || !env.TELEGRAM_WEBHOOK_SECRET || !env.SUPABASE_SERVICE_ROLE_KEY) {
    return {
      status: "error",
      message:
        "Bot belum dikonfigurasi di server: isi TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET dan SUPABASE_SERVICE_ROLE_KEY di Vercel.",
    };
  }
  const url = `${env.APP_URL.replace(/\/$/, "")}/api/telegram/webhook`;
  if (!url.startsWith("https://")) {
    return {
      status: "error",
      message: "Telegram hanya menerima alamat https. Daftarkan dari alamat produksi.",
    };
  }
  const result = await setWebhook(url, env.TELEGRAM_WEBHOOK_SECRET);
  if (!result.ok)
    return { status: "error", message: `Telegram menolak: ${result.error ?? "tidak diketahui"}` };
  const me = await getMe();
  revalidatePath("/admin/telegram");
  return {
    status: "ok",
    message: `Webhook terdaftar${me.result?.username ? ` untuk @${me.result.username}` : ""}.`,
  };
}
