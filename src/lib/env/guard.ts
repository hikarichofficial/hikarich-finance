import { PRODUCTION_SUPABASE_PROJECT_REF, type AppEnvironment } from "./constants";

/** Returns the Supabase project ref from a hosted URL, or null (e.g. local stack). */
export function supabaseProjectRef(supabaseUrl: string): string | null {
  let host: string;
  try {
    host = new URL(supabaseUrl).hostname.toLowerCase();
  } catch {
    return null;
  }
  const match = /^([a-z0-9]+)\.supabase\.(co|in|net)$/.exec(host);
  return match ? match[1] : null;
}

export type GuardInput = {
  appEnv: AppEnvironment;
  supabaseUrl: string;
  /** Value of the platform deployment marker (Vercel: VERCEL_ENV), if any. */
  platformEnv?: string;
  /** Names of NEXT_PUBLIC_ variables present, to detect secret leakage by naming. */
  publicVariableNames?: string[];
};

/**
 * Cross-variable safety rules. Returns human-readable violations; an empty
 * array means the configuration is safe.
 *
 * Rules (Step 14 §3, §14, §18):
 *  1. Non-production environments must never use the production Supabase project.
 *  2. The production environment must use the production Supabase project.
 *  3. The platform marker (Vercel) must agree with APP_ENV, so a Preview build
 *     cannot silently run with production settings.
 *  4. Service-role style secrets must never be exposed via NEXT_PUBLIC_ names.
 */
export function evaluateEnvironmentGuard(input: GuardInput): string[] {
  const violations: string[] = [];
  const ref = supabaseProjectRef(input.supabaseUrl);
  const usesProductionProject = ref === PRODUCTION_SUPABASE_PROJECT_REF;

  if (input.appEnv !== "production" && usesProductionProject) {
    violations.push(
      `APP_ENV=${input.appEnv} must not use the production Supabase project (Step 14 §3/§18).`,
    );
  }

  if (input.appEnv === "production" && !usesProductionProject) {
    violations.push("APP_ENV=production must use the production Supabase project (Step 14 §3).");
  }

  if (input.platformEnv) {
    const expected =
      input.platformEnv === "production"
        ? "production"
        : input.platformEnv === "preview"
          ? "preview"
          : input.platformEnv === "development"
            ? "development"
            : undefined;
    if (expected && expected !== input.appEnv) {
      violations.push(
        `Platform environment "${input.platformEnv}" does not match APP_ENV=${input.appEnv}.`,
      );
    }
  }

  const leaked = (input.publicVariableNames ?? []).filter((name) =>
    /service[_-]?role|secret|private/i.test(name),
  );
  for (const name of leaked) {
    violations.push(`${name} looks like a secret but is exposed through a NEXT_PUBLIC_ name.`);
  }

  return violations;
}
