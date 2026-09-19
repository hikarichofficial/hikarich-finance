# Testing

Step 16 defines the acceptance gates (G0–G9). CI verifies a release candidate; it does not
replace Step 16 evidence. "Implemented" is not "Verified".

## Commands

| Command              | What it does                                                                  |
| -------------------- | ----------------------------------------------------------------------------- |
| `pnpm typecheck`     | TypeScript strict type check                                                  |
| `pnpm lint`          | ESLint (Next.js core-web-vitals + TypeScript)                                 |
| `pnpm format:check`  | Prettier check                                                                |
| `pnpm test`          | Vitest unit tests (`tests/unit`)                                              |
| `pnpm secrets:check` | Scans the working tree for committed secrets (prints locations, never values) |
| `pnpm build`         | Production build (needs the environment contract; see `.env.example`)         |
| `pnpm db:test`       | Rebuilds a throwaway database from migrations twice and runs SQL invariants   |
| `pnpm check`         | typecheck + lint + test + secrets                                             |

`pnpm db:test` starts its own throwaway PostgreSQL cluster when server binaries are installed
locally, or uses `ADMIN_DATABASE_URL` (a non-production server). It refuses any Supabase-hosted URL.

## Suites

| Suite          | Location            | Status (P0)                                                         |
| -------------- | ------------------- | ------------------------------------------------------------------- |
| Unit / domain  | `tests/unit`        | Environment contract and production-isolation guard                 |
| Migration / DB | `supabase/tests`    | Clean rebuild x2, RLS-enabled and no-browser-write-grant invariants |
| Integration    | `tests/integration` | Empty until P3+                                                     |
| RLS / security | `tests/rls`         | Empty until P2                                                      |
| End-to-end     | `tests/e2e`         | Empty until UI phases                                               |

Every fixed financial-integrity bug gets a permanent regression test (Step 13 (testing strategy)).
