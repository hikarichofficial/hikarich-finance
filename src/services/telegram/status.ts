import "server-only";
import { getServerEnv } from "@/lib/env";
import { getMe, getWebhookInfo, telegramConfigured } from "./api";

export interface BotStatus {
  configured: boolean;
  aiConfigured: boolean;
  cronConfigured: boolean;
  botUsername: string | null;
  webhookUrl: string | null;
  pending: number | null;
  lastError: string | null;
}

/** Read-only status for the settings screen (never a secret). Not a Server Action: only the page calls it. */
export async function loadBotStatus(): Promise<BotStatus> {
  const env = getServerEnv();
  const configured =
    telegramConfigured() &&
    Boolean(env.TELEGRAM_WEBHOOK_SECRET) &&
    Boolean(env.SUPABASE_SERVICE_ROLE_KEY);
  const status: BotStatus = {
    configured,
    aiConfigured: Boolean(env.GEMINI_API_KEY),
    cronConfigured: Boolean(env.CRON_SECRET),
    botUsername: null,
    webhookUrl: null,
    pending: null,
    lastError: null,
  };
  if (!telegramConfigured()) return status;
  const [me, info] = await Promise.all([getMe(), getWebhookInfo()]);
  status.botUsername = me.result?.username ?? null;
  status.webhookUrl = info.result?.url || null;
  status.pending = info.result?.pending_update_count ?? null;
  status.lastError = info.result?.last_error_message ?? null;
  return status;
}
