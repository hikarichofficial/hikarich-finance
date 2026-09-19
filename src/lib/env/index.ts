import { envSchema, publicEnvSchema, type PublicEnv, type ServerEnv } from "./schema";
import { evaluateEnvironmentGuard } from "./guard";
import type { AppEnvironment } from "./constants";

export class EnvironmentConfigError extends Error {
  readonly issues: string[];
  constructor(issues: string[]) {
    super(`Invalid environment configuration:\n - ${issues.join("\n - ")}`);
    this.name = "EnvironmentConfigError";
    this.issues = issues;
  }
}

type EnvSource = Record<string, string | undefined>;

/**
 * Validates and returns the full (server) environment. Throws
 * EnvironmentConfigError when required values are missing/invalid or when a
 * cross-variable safety rule is violated. Error messages list variable names
 * only, never values, so secrets cannot leak through logs.
 */
export function parseServerEnv(source: EnvSource): ServerEnv {
  const result = envSchema.safeParse(source);
  if (!result.success) {
    throw new EnvironmentConfigError(
      result.error.issues.map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`),
    );
  }
  const env = result.data;
  const violations = evaluateEnvironmentGuard({
    appEnv: env.APP_ENV as AppEnvironment,
    supabaseUrl: env.NEXT_PUBLIC_SUPABASE_URL,
    platformEnv: source.VERCEL_ENV,
    publicVariableNames: Object.keys(source).filter((name) => name.startsWith("NEXT_PUBLIC_")),
  });
  if (violations.length > 0) {
    throw new EnvironmentConfigError(violations);
  }
  return env;
}

/** Browser-safe subset only. Safe to call from client code. */
export function parsePublicEnv(source: EnvSource): PublicEnv {
  const result = publicEnvSchema.safeParse(source);
  if (!result.success) {
    throw new EnvironmentConfigError(
      result.error.issues.map((issue) => `${issue.path.join(".") || "(root)"}: ${issue.message}`),
    );
  }
  return result.data;
}

let cachedServerEnv: ServerEnv | undefined;

/** Server-only accessor. Do not import from client components. */
export function getServerEnv(): ServerEnv {
  cachedServerEnv ??= parseServerEnv(process.env);
  return cachedServerEnv;
}

export { PRODUCTION_SUPABASE_PROJECT_REF } from "./constants";
export type { AppEnvironment } from "./constants";
export type { PublicEnv, ServerEnv } from "./schema";
