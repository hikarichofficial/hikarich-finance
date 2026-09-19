# Spec Index — Hikarich Finance

The Step 01–17 specification set is **FINAL & LOCKED**. This file maps each step to the
subject it is authoritative for. It does not copy the specs; the DOCX files are the source of
truth and are kept by the OWNER outside this repository.

Reading rule: Step 17 first (execution protocol), then only the steps the current phase needs.
If two documents disagree, the more specific authority below wins (see `DECISIONS.md` for
resolved cases). If the disagreement changes economic meaning, tax treatment, authorization or
a user workflow, it is raised to the OWNER instead of guessed.

| Step | Document                                 | Authoritative for                                                           |
| ---- | ---------------------------------------- | --------------------------------------------------------------------------- |
| 01   | Master Specification (Requirements 1–51) | Scope, product intent, required capabilities, OWNER decisions               |
| 02   | Database Architecture / Schema / ERD     | Tables, keys, relationships, constraints, audit metadata                    |
| 03   | Chart of Accounts Architecture           | COA structure and account semantics                                         |
| 04   | Accounting Engine & Posting Rules        | Journals, posting, reversal, immutability, balance rules                    |
| 05   | Tax Rules Architecture                   | Tax determination, NEEDS_REVIEW behavior, tax ledgers                       |
| 06   | Permission / RLS Matrix                  | Roles, capabilities, RLS, step-up, public-token principal                   |
| 07   | Status Machines & Business Workflows     | Lifecycle states and transitions, workflow rules                            |
| 08   | Validation & Integrity Rules             | Field/domain validation and integrity invariants                            |
| 09   | UI Sitemap & Screen Architecture         | Navigation, screens, information architecture                               |
| 10   | Dashboard & Design System                | Visual language, dashboard composition, components                          |
| 11   | Invoice & Receipt Visual Specification   | Invoice/receipt documents and public page                                   |
| 12   | Reports Architecture                     | Financial statements, management reports, drill-down                        |
| 13   | API / Service Architecture & Conventions | Code organization, commands/queries, idempotency, atomicity, money handling |
| 14   | Supabase / Vercel / GitHub Architecture  | Environments, deployment, secrets, domain, migrations, CI                   |
| 15   | Implementation Phases & Dependency Map   | Build order P0–P15 and phase gates                                          |
| 16   | QA & Acceptance Criteria                 | Gates G0–G9, acceptance tests                                               |
| 17   | Claude Coding Handover Package           | Authority map, execution protocol, report format, stop conditions           |

## Code layout ↔ Step 13 §23

| Path           | Purpose                                                            |
| -------------- | ------------------------------------------------------------------ |
| `src/app`      | Routing, layouts, thin request boundaries                          |
| `src/features` | Feature UI and application-facing use cases, grouped by domain     |
| `src/domain`   | Pure business types/rules/domain services                          |
| `src/services` | Trusted orchestration for commands and queries                     |
| `src/data`     | Supabase/PostgreSQL access adapters (no UI concerns)               |
| `src/schemas`  | Runtime request/response validation schemas                        |
| `src/lib`      | Cross-cutting utilities (money, date, idempotency, auth, env…)     |
| `src/jobs`     | Scheduled/background consumers with explicit contracts             |
| `tests/`       | `unit`, `integration`, `rls`, `e2e` suites                         |
| `supabase/`    | `config.toml`, `migrations/`, `seed.sql` (non-prod only), `tests/` |
