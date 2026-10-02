# Go-live (P15)

The order in which production is brought up. Every step that needs a password, a token or an
authenticator code is done by the OWNER in the service's own screen; none of them is ever typed into
code, chat, an issue or a file in Git.

## 1. Schema: migrations reach production through GitHub

`.github/workflows/production-migrations.yml` applies `supabase/migrations` to the production project
with the Supabase CLI: byte for byte, in order, recorded in the database's migration history. It runs
when a merge to `main` changes a migration and on demand (Actions → Production migrations → Run
workflow). The seed file is never applied to production.

It needs two repository secrets (GitHub → Settings → Secrets and variables → Actions):

| Secret                  | Where the OWNER gets it                                                         |
| ----------------------- | ------------------------------------------------------------------------------- |
| `SUPABASE_ACCESS_TOKEN` | Supabase → Account → Access Tokens → Generate new token                         |
| `SUPABASE_DB_PASSWORD`  | Supabase → project `hikarich-finance-prod` → Database → Reset database password |

After both are saved, run the workflow once. The first run applies every migration to the empty
production database.

## 2. First OWNER

Production has its own users; the account used on Preview lives in the non-production project.

1. The OWNER creates the user in Supabase → `hikarich-finance-prod` → Authentication → Users → Add user
   (email and a password they type; "Auto Confirm User" on).
2. The Entities are created (step 3), then a database administrator runs
   `select app_private.bootstrap_owner('<auth user id>', '<display name>')` once. It makes that user OWNER
   of every active Entity and refuses to run a second time.
3. The OWNER signs in at the production URL and enrols an authenticator (mandatory for OWNER).

## 3. Entities

Created once by a database administrator, with the chart of accounts provisioned for each:

| Code       | Type    | Legal name                 | Brand               | Taxpayer kind (set in the app)  |
| ---------- | ------- | -------------------------- | ------------------- | ------------------------------- |
| `pt`       | company | PT Hikarich Kitana Digital | Kamar Kajian Market | PT Perorangan                   |
| `hikarich` | company | Hikarich                   | —                   | Orang pribadi (dagang dan jasa) |

Both are business-type ledgers (decision 270): every feature is the same and only the tax rules differ.
Names, brand, address and contact details can be changed later in Settings (decision 272); the code and
the type cannot.

## 4. In the application, by the OWNER

1. Pajak → Pengaturan Pajak: taxpayer profile per Entity (kind, final UMKM regime, not PKP, NPWP typed
   here only), then activate the tax engine from the first day tax should be computed.
2. Kas & Bank: every cash, bank and e-wallet account.
3. Akuntansi → Saldo Awal: opening balances at the cut-over date (`docs/DATA_CUTOVER.md`).
4. Aset → Aset yang Sudah Dimiliki: equipment owned before the cut-over.
5. Administrasi → Backup: download a first Full backup and keep it outside Supabase and Vercel.

## 5. Address

Production is served at `hikarich-finance.vercel.app` until a custom domain is bought. When it is:
add the domain in Vercel, set `APP_URL` (Production) to it, set the Site URL in Supabase Auth to it, and
redeploy.

## Not part of go-live

Import Wizard screens and document attachments (file storage) are not built yet. Tax items that could
not be confirmed from a primary text are listed in `docs/DECISIONS.md` (decisions 256-261, 269).
