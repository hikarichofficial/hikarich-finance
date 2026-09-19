# Implementation Decisions

Decisions and deviations that do **not** rewrite a locked specification. Anything that would
change a locked item requires explicit OWNER approval and is recorded under "OWNER decisions".

## OWNER decisions

| Date       | Decision                                                                                                                                                                                                                                                                                                                                             |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-09-19 | No paid Supabase upgrade for managed backups. Recovery relies on the in-app Backup & Restore Center (Step 01 #36) with export to external storage, plus a restore drill before real data (Step 16 §34).                                                                                                                                              |
| 2026-09-19 | Hosting stays on **Vercel Hobby**. Vercel's fair-use terms describe Hobby as non-commercial and list processing payments from visitors as commercial use; OWNER accepts the risk knowingly. Netlify was evaluated and not chosen. Nothing about the app's purpose is hidden or misrepresented. The app stays portable (standard Next.js + Supabase). |
| 2026-09-19 | Working rule: do not improvise beyond the specs; ask the OWNER first.                                                                                                                                                                                                                                                                                |

## Resolved by authority (no OWNER decision needed)

1. **Navigation** follows Step 09 over Step 01 §7.
2. **Dashboard composition** follows Step 10; full personalization is delivered in P13.
3. **Column-level schema** is authored in P1 from Step 02 (which fixes entities and rules, not every column).
4. **COA seed** adds accounts the postings need but Step 03 does not list by number (rounding, dividend/distribution payable, bad debt, PPN/PPh child accounts, disposal gain/loss). Numbers follow Step 03's ranges.
5. **Capabilities Step 15 does not name** are mapped to the nearest valid phase. Proposed mapping, to be confirmed when each phase starts: Custom Report Builder (P12), Backup & Restore Center and Storage Monitor (P14), Notification Center UI (P13), Security/Users/Audit UI (P2 foundations, P14 hardening).
6. **Sales discount** default: contra-revenue account 4200 with AR recorded at net; kept configurable.
7. **Tax baseline** in Step 05 is the documented baseline. It is web-verified again at P7 and before P15; unverifiable facts become NEEDS_REVIEW, not guesses.

## Engineering decisions made in P0

| #   | Decision                                                                                                                                                                                                                                                             | Reason / authority                                                                                                           |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1   | Next.js (App Router) + TypeScript `strict`, pnpm, Node 22, Vitest, ESLint (Next config), Prettier.                                                                                                                                                                   | Step 13 §24, Step 14 §12.                                                                                                    |
| 2   | Env contract enforced with zod at dev start/build (`next.config.ts`) and server start (`instrumentation.ts`). Errors list variable names only.                                                                                                                       | Step 14 §15 "fail safely".                                                                                                   |
| 3   | The production Supabase project ref (`yvuakaxwgwfjyvjmvpbn`, an identifier, not a secret) is a constant in `src/lib/env/constants.ts`. A non-production `APP_ENV` pointing at it, or production pointing elsewhere, aborts the build.                                | Step 14 §3 LOCKED DECISION, §18.                                                                                             |
| 4   | `SUPABASE_SERVICE_ROLE_KEY` is optional in P0 (no privileged operation exists yet) and can never use a `NEXT_PUBLIC_` name.                                                                                                                                          | Step 13 (credentials/privileged operations), Step 14 §14.                                                                    |
| 5   | Local `supabase/config.toml`: `auto_expose_new_tables = false` and open sign-up disabled (default-deny). Auth policy is finalized in P2.                                                                                                                             | Step 06 default-deny; matches the cloud projects' settings.                                                                  |
| 6   | The two hosted Supabase projects: `hikarich-finance-prod` (production only) and `hikarich-finance-dev` (Development and Preview backend).                                                                                                                            | Step 14 §3–4: separate non-production project when Branching is unavailable.                                                 |
| 7   | Migration tests run on plain PostgreSQL plus small Supabase stubs (`supabase/tests/stubs`). Local tool availability: PostgreSQL 16 in the development sandbox; CI uses `postgres:17` (matches Supabase major 17). Two clean rebuilds must yield an identical schema. | The sandbox has no Docker, so `supabase start` is not available there. Re-run on the real Supabase CLI stack when available. |
| 8   | Baseline invariants tested after every migration: RLS enabled on all `public` tables; no direct INSERT/UPDATE/DELETE/TRUNCATE grants to `anon`/`authenticated` on `public` tables (an allowlist may be added only by a reviewed migration).                          | Step 14 (Supabase security), Step 13 (command boundary).                                                                     |
| 9   | P0 shell uses a system font stack and only the confirmed tokens (ink `#191714`, secondary text `#777069`, canvas `#F7F2EC`, bronze `#B77A43`). Typography and the full token set are finalized against Step 10 in P13.                                               | Avoids guessing typography before it is needed.                                                                              |
| 10  | Logo mark cropped from `HIKARICH_logo_4K.png` to a 512 px square for the shell and app icon. A transparent/vector logo for invoices and receipts is a P11 input from the OWNER.                                                                                      | The supplied file is a photographic render with a beige background.                                                          |
| 11  | `pnpm audit --prod` at high severity and a repository secret scan run in CI.                                                                                                                                                                                         | Step 14 §12, §22.                                                                                                            |

## Open items for later phases

- Non-production backend for Preview deployments: the `hikarich-finance-dev` project is the default; confirm before the first Preview deploy.
- SMTP provider for Auth emails (Step 14 §21).
- Domain `hikarich.com` / `finance.hikarich.com` purchase and DNS (Step 14 (domain)).
- Taxpayer facts (Perseroan Perorangan status, NPWP, PKP) and Personal-entity invoice numbering prefix, needed at P15.
- MFA on the infrastructure accounts (GitHub, Vercel, Supabase) before P15.
