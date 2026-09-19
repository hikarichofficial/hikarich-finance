import { getServerEnv } from "@/lib/env";

/**
 * Runs once when the server starts. Re-validates the environment so a
 * misconfigured deployment fails at startup instead of on first request.
 */
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs" && process.env.SKIP_ENV_VALIDATION !== "1") {
    getServerEnv();
  }
}
