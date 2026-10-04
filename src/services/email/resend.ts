import "server-only";
import { getServerEnv } from "@/lib/env";

/**
 * Outbound transactional email via Resend (decision 279's open item, "Kirim Invoice via Email" --
 * the OWNER confirmed Resend, after checking its free tier covers Hikarich's volume: 3,000 emails/month,
 * 100/day, more than enough for invoicing). A plain `fetch` against Resend's HTTP API, not the `resend`
 * npm package -- this repo's own pattern for a small, optional, server-only integration (e.g.
 * `createSupabaseAdminClient`) is "no new dependency for one HTTP call", and Resend's send endpoint is a
 * single POST.
 *
 * Returns `{ sent: false, reason: "not_configured" }` when `RESEND_API_KEY`/`RESEND_FROM_EMAIL` are not
 * set, the same "absent means off" shape `documentStorageEnabled()` already uses for Supabase Storage --
 * so Preview/local builds, and any Entity before the OWNER sets up a Resend account, keep working: the
 * existing public-link share ("Salin Tautan Publik") is never gated by this.
 */

export interface SendEmailResult {
  sent: boolean;
  reason?: "not_configured" | "failed";
  /** The Resend API's own error message (never a secret), for the server log -- not shown to the person. */
  detail?: string;
}

function resendConfig(): { apiKey: string; from: string } | null {
  const env = getServerEnv();
  if (!env.RESEND_API_KEY || !env.RESEND_FROM_EMAIL) return null;
  return { apiKey: env.RESEND_API_KEY, from: env.RESEND_FROM_EMAIL };
}

export function emailDeliveryEnabled(): boolean {
  return resendConfig() !== null;
}

export async function sendEmail(input: {
  to: string;
  subject: string;
  html: string;
  replyTo?: string;
}): Promise<SendEmailResult> {
  const config = resendConfig();
  if (!config) return { sent: false, reason: "not_configured" };
  try {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: config.from,
        to: [input.to],
        subject: input.subject,
        html: input.html,
        reply_to: input.replyTo,
      }),
    });
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      return { sent: false, reason: "failed", detail: body.slice(0, 500) };
    }
    return { sent: true };
  } catch (error) {
    return {
      sent: false,
      reason: "failed",
      detail: error instanceof Error ? error.message : "unknown error",
    };
  }
}
