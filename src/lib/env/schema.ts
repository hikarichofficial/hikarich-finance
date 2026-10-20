import { z } from "zod";
import { APP_ENVIRONMENTS } from "./constants";

/**
 * Required environment contract (Step 14 §15).
 *
 * - Public (browser-safe) variables use the NEXT_PUBLIC_ prefix and may only
 *   contain values that are safe to expose (URL + publishable key).
 * - Server variables are never bundled into browser code.
 * - No integration keys are declared before the integration exists.
 */

const httpUrl = z
  .string()
  .trim()
  .url()
  .refine((value) => /^https?:\/\//i.test(value), "must be an http(s) URL");

export const publicEnvSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: httpUrl,
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().trim().min(20, "looks too short"),
});

export const serverEnvSchema = z.object({
  APP_ENV: z.enum(APP_ENVIRONMENTS),
  APP_URL: httpUrl,
  /**
   * Server-only privileged credential. Optional in P0 because no privileged
   * operation exists yet (Step 13 (credentials/privileged operations)). Must never be NEXT_PUBLIC_.
   */
  SUPABASE_SERVICE_ROLE_KEY: z.string().trim().min(20).optional(),
  /**
   * Secret salt for the hash of a public requester (customer invoice page, "Saya Sudah Bayar"). The database
   * only ever stores the hash and uses it for abuse limits. Optional so builds and Preview work without it
   * (a fixed fallback salt is used then); set a long random value in Production (DECISIONS 70).
   */
  PUBLIC_CLAIM_SALT: z.string().trim().min(16).optional(),
  /**
   * Resend (decision 279's open item, "Kirim Invoice via Email"). Optional: `src/services/email/resend.ts`
   * returns `{ sent: false, reason: "not_configured" }` without either set, the same "absent means off"
   * shape `SUPABASE_SERVICE_ROLE_KEY` already uses -- builds and Preview work without it, and the existing
   * public-link share stays available either way.
   */
  RESEND_API_KEY: z.string().trim().min(10).optional(),
  RESEND_FROM_EMAIL: z.string().trim().email().optional(),
  /**
   * Telegram bot (decision 422). All optional: without them the bot routes answer "not configured" and the rest of the
   * site is unaffected. `TELEGRAM_WEBHOOK_SECRET` is the value Telegram sends back in the
   * `X-Telegram-Bot-Api-Secret-Token` header; `CRON_SECRET` is what Vercel Cron sends as a Bearer token.
   * `GEMINI_API_KEY` belongs to the free Google AI Studio tier; the AI helper never receives books data.
   */
  TELEGRAM_BOT_TOKEN: z.string().trim().min(20).optional(),
  TELEGRAM_WEBHOOK_SECRET: z
    .string()
    .trim()
    .regex(/^[A-Za-z0-9_-]{16,256}$/, "use 16-256 letters, digits, _ or -")
    .optional(),
  GEMINI_API_KEY: z.string().trim().min(10).optional(),
  GEMINI_MODEL: z.string().trim().min(3).max(80).optional(),
  CRON_SECRET: z.string().trim().min(16).optional(),
});

export const envSchema = publicEnvSchema.extend(serverEnvSchema.shape);

export type PublicEnv = z.infer<typeof publicEnvSchema>;
export type ServerEnv = z.infer<typeof envSchema>;
