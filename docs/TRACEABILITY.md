# Requirement Traceability Matrix (Step 17 §26)

Maps a locked requirement / spec section to its implementation module and tests.
Status: Not Started / In Progress / Implemented / **Verified** (Verified requires Step 16 evidence).
Requirement-level rows for Step 01 (#1–#51) and Steps 02–12 are added when the phase that
implements them starts.

| Spec reference                                                | Implementation                                                           | Tests                                                      | Status      |
| ------------------------------------------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------- | ----------- |
| Step 13 §23 code organization                                 | `src/{app,features,domain,services,data,schemas,lib,jobs}`, `tests/*`    | Structure reviewed                                         | Implemented |
| Step 13 §24 TypeScript strict                                 | `tsconfig.json` (`strict`)                                               | `pnpm typecheck` (CI)                                      | Implemented |
| Step 14 §3, §18 Preview never touches Production              | `src/lib/env/guard.ts`, `next.config.ts`                                 | `tests/unit/env.test.ts`; failed-build checks run manually | Implemented |
| Step 14 §5 Supabase repository layout                         | `supabase/` (config, migrations, seed, tests)                            | `pnpm db:test`                                             | Implemented |
| Step 14 §6 migration discipline / clean rebuild               | `supabase/migrations`, `scripts/db-test.sh`                              | Two clean rebuilds with identical schema; negative probes  | Implemented |
| Step 14 (Supabase security) RLS on exposed tables             | `supabase/tests/00_baseline_invariants.sql`                              | Invariant fails when a table lacks RLS (probed)            | Implemented |
| Step 13 (command boundary) no direct browser financial writes | Same invariants (no write grants to browser roles)                       | Invariant fails on an INSERT grant (probed)                | Implemented |
| Step 14 §12 CI quality gate                                   | `.github/workflows/ci.yml`                                               | Runs on GitHub once code is pushed                         | In Progress |
| Step 14 §14–15 env variables, no secrets in Git               | `src/lib/env`, `.env.example`, `.gitignore`, `scripts/check-secrets.mjs` | `env.test.ts`, secret-scan probe                           | Implemented |
| Step 14 §22 secret governance                                 | `scripts/check-secrets.mjs`                                              | Scanner detects a planted token/DB URL (probed)            | Implemented |
