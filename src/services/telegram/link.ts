import "server-only";
import { z } from "zod";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { createSupabaseServerClient } from "@/lib/supabase/server";

/**
 * The signed-in owner's side of the Telegram bot (decision 422): pairing code, current link, settings, revoke. All
 * four are database functions running under the person's own session; creating a code needs MFA and a fresh step-up,
 * raising the limit needs a fresh step-up. The bot's own side (webhook, reports) is in the other files of this folder.
 */

const linkSchema = z.union([
  z.object({ linked: z.literal(false) }),
  z.object({
    linked: z.literal(true),
    telegram_username: z.string().nullable(),
    linked_at: z.string(),
    max_entry_amount: z.string(),
    report_daily: z.boolean(),
    report_weekly: z.boolean(),
    report_monthly: z.boolean(),
    default_entity_id: z.string().nullable(),
    groups: z.array(
      z.object({
        chat_id: z.string(),
        title: z.string().nullable(),
        kind: z.string(),
        registered_at: z.string(),
      }),
    ),
  }),
]);

export type TelegramLink = z.infer<typeof linkSchema>;

const codeSchema = z.object({ code: z.string(), expires_at: z.string() });

async function call(name: string, args?: Record<string, unknown>): Promise<unknown> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Pengaturan Telegram tidak dapat diproses.");
  }
  return data;
}

export async function getMyTelegramLink(): Promise<TelegramLink> {
  const parsed = linkSchema.safeParse(await call("my_telegram_link"));
  if (!parsed.success) throw new Error("Respons Telegram tidak dikenali.");
  return parsed.data;
}

export async function createTelegramLinkCode(): Promise<{ code: string; expiresAt: string }> {
  const parsed = codeSchema.safeParse(await call("create_telegram_link_code"));
  if (!parsed.success) throw new Error("Respons kode tidak dikenali.");
  return { code: parsed.data.code, expiresAt: parsed.data.expires_at };
}

export async function revokeTelegramLink(): Promise<void> {
  await call("revoke_telegram_link");
}

export async function updateTelegramSettings(input: {
  maxEntryAmount: number;
  reportDaily: boolean;
  reportWeekly: boolean;
  reportMonthly: boolean;
  defaultEntity: string | null;
}): Promise<void> {
  await call("update_telegram_settings", {
    p_max_entry_amount: z.number().positive().max(9_999_999_999_999).parse(input.maxEntryAmount),
    p_report_daily: input.reportDaily,
    p_report_weekly: input.reportWeekly,
    p_report_monthly: input.reportMonthly,
    p_default_entity: input.defaultEntity ? z.uuid().parse(input.defaultEntity) : null,
  });
}
