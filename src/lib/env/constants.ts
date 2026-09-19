/**
 * Non-secret infrastructure identifiers used by the environment guard.
 *
 * The production Supabase project ref is an identifier, not a credential
 * (it is visible in every production API URL). It is kept in code so that a
 * Preview / Development build can never be pointed at the production database
 * by a configuration mistake (Step 14 §3 LOCKED DECISION, §18).
 */
export const PRODUCTION_SUPABASE_PROJECT_REF = "yvuakaxwgwfjyvjmvpbn";

export const APP_ENVIRONMENTS = ["development", "preview", "production"] as const;
export type AppEnvironment = (typeof APP_ENVIRONMENTS)[number];
