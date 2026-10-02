# Release, Deployment, Migration and Recovery

Source of authority: Step 14. This document records the procedure as it is implemented;
sections marked **(not yet implemented)** are planned for the phase shown.

## Environments (Step 14 §3)

| Environment | Backend                                        | Notes                                                     |
| ----------- | ---------------------------------------------- | --------------------------------------------------------- |
| Development | Local Supabase stack or `hikarich-finance-dev` | localhost only; never production secrets                  |
| Preview/PR  | `hikarich-finance-dev` (non-production)        | Must never write to production; test identities/data only |
| Production  | `hikarich-finance-prod`                        | `finance.hikarich.com`; authoritative real financial data |

The application refuses to build or start when `APP_ENV` and the Supabase project disagree
(`src/lib/env`). Preview deployments use Preview-scoped variables; the service-role key is
never scoped to Preview.

## Change flow

1. Branch from `main` (`feature/*`, `fix/*`, `chore/*`).
2. Push. CI runs (format, typecheck, lint, unit tests, secret scan, dependency audit, build; and the migration clean-rebuild job). A Preview deployment is created.
3. Open a pull request; the Preview URL and checks are the review surface. Squash merge into `main`.
4. `main` is the Production branch. A production deploy requires green CI.

## Branch protection (to configure on GitHub)

Ruleset on `main`: block deletion and force-push, require pull request, require the CI checks
`Typecheck, lint, tests, build` and `Migration clean-rebuild and invariants`. Solo-OWNER
workflow: no mandatory reviewer count; OWNER bypass is exceptional (Step 14 §11).

## Database migrations (Step 14 §6)

- Only migrations change production schema, policies and functions. Files are ordered
  (`YYYYMMDDHHMMSS_snake_case.sql`), forward-only, never edited after being applied to production.
- Every migration is rebuilt from scratch twice in CI (`scripts/db-test.sh`) and must pass the
  invariants in `supabase/tests`.
- Production migrations run through the controlled Git-connected/CI path, not casual local pushes:
  `.github/workflows/production-migrations.yml` (decision 272, `docs/GO_LIVE.md`).
- Rollback: code rollback where safe; forward-fix migration for irreversible schema changes;
  restore only for genuine recovery.

## Secrets (Step 14 §14, §22)

- No secrets in Git, screenshots, issues or prompts. `.env.example` holds placeholders only.
- `NEXT_PUBLIC_` variables are browser-visible: URL and publishable key only.
- If a secret is exposed: rotate/revoke it first; deleting the line is not enough.

## Recovery (Step 14, Step 16 §34)

No paid managed backups are used (OWNER decision, see `DECISIONS.md`). Recovery comes from the
in-app Backup & Restore Center (`/admin/backup`) with export to external storage, and a restore
drill before real financial data is entered (decision 247).

Backups:

- OWNER downloads a Full backup regularly (the screen reminds after 30 days) and keeps the file
  outside Supabase and Vercel (for example an encrypted personal drive). The file is the database's
  own serialisation with an MD5 checksum over its data; do not edit it.
- Current limit: a backup file travels through a Vercel function, so it must stay under 4 MB
  (Vercel's 4.5 MB request/response ceiling). Re-assess before the data grows near that size.

Restore (OWNER decision 247: only into an empty Entity):

1. The target Entity must exist with the same id as the backup and hold no data yet. To recover a
   lost project: create a fresh Supabase project, apply every migration in order
   (`supabase/migrations`), create the Entity row with the original id and code, and add the OWNER
   membership. User accounts and memberships are not restored from the file; re-invite people
   through Users & Roles afterwards.
2. On `/admin/backup`, pick the backup file. The database checks the checksum, the Entity id,
   unknown tables and that the target is empty, and shows the rows per table it will write.
3. Re-verify (step-up, 10 minutes), type the Entity code, and press **Pulihkan sekarang**.
4. The restore runs as one transaction: rows are written in foreign-key order, then row counts,
   balanced posted journals and a zero trial-balance difference are verified. Any failure writes
   nothing and is recorded as a Failed restore in the history and the Audit Log.

Restore drill: `supabase/tests/99_p14_2_restore.sql` (run by `pnpm db:test`) exports an Entity with
data, empties it, restores it and requires the re-export to equal the original table by table,
including exact money amounts. Run a manual drill on the non-production project before go-live.

## Vercel (not yet configured — after code is pushed)

Hobby plan (OWNER decision). Project linked to GitHub, `main` = Production, Deployment
Protection on for Preview, environment variables scoped per environment, custom domain per the
live Vercel instructions at setup time.
