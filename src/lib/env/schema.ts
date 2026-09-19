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
});

export const envSchema = publicEnvSchema.extend(serverEnvSchema.shape);

export type PublicEnv = z.infer<typeof publicEnvSchema>;
export type ServerEnv = z.infer<typeof envSchema>;
