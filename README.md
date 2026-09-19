# Hikarich Finance

Finance system for PT Hikarich Kitana Digital and a separate Personal Entity.
Next.js (TypeScript, modular monolith) · Supabase (PostgreSQL, Auth, Storage, RLS) · Vercel · GitHub.

The product is defined by the locked specification set (Steps 01–17). Start with
[`docs/SPEC_INDEX.md`](docs/SPEC_INDEX.md). Current build status is in
[`docs/TASK_BOARD.md`](docs/TASK_BOARD.md).

## Requirements

- Node.js 22+ and pnpm 10
- For database tests: PostgreSQL server binaries (or an `ADMIN_DATABASE_URL` for a non-production server)

## Local setup

```bash
pnpm install
cp .env.example .env.local   # then fill in NON-PRODUCTION values only
pnpm dev
```

The app validates its environment at start and build. A non-production `APP_ENV` that points
at the production Supabase project is rejected on purpose (Step 14 §3).

## Checks

```bash
pnpm check        # typecheck + lint + unit tests + secret scan
pnpm build
pnpm db:test      # clean database rebuild from migrations (x2) + invariants
```

See [`docs/TESTING.md`](docs/TESTING.md) for details.

## Repository map

| Path        | Purpose                                                                    |
| ----------- | -------------------------------------------------------------------------- |
| `src/`      | Application code (see `docs/SPEC_INDEX.md` for layout)                     |
| `supabase/` | Config, ordered migrations, non-production seed, DB tests                  |
| `tests/`    | Unit, integration, RLS and end-to-end suites                               |
| `scripts/`  | Repository tooling (secret scan, DB rebuild test)                          |
| `docs/`     | Spec index, decisions, release, testing, cutover, task board, traceability |

## Rules that never bend

Separate ledgers per Entity; posted GL is the accounting truth; journals are balanced and
immutable (corrections by reversal); financial commands are atomic and idempotent; the UI is not a
security boundary (RLS + server authorization); Preview/Development never write to Production;
no secrets in Git.
