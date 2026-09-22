-- P10 gate (Step 15 §14, Step 01 #22/#23/#26): planning and recurring automation reconcile end to end.
-- Covers: the planning.* permission boundary; the recurring rule lifecycle (create/pause/resume/end,
-- editing never mutates already-generated history, enforced both by the command layer and by the
-- append-only guard trigger on recurring_occurrences); the generation engine (a batch that mixes
-- invoice/bill/expense rules, idempotent replay, monthly/weekly stepping, a failed-generation retry that
-- leaves next_occurrence_date untouched, and the scheduled service_role path with no signed-in user at
-- all, authorized structurally rather than by any table grant); budgets and revenue targets (create/edit/
-- activate/close, the computed Budget/Actual/Committed and Target/Actual/AR reports, forecast_amount
-- always null per docs/DECISIONS.md); and that browser roles have no direct write access to any P10
-- table. All data is synthetic; dates are relative to the Entity's today. The whole file runs in one
-- transaction that is rolled back.

begin;
set local client_min_messages = warning;

-- Scratch space (uuid and date) that survives role switches inside this transaction.
create table test_helpers.p10 (k text primary key, v uuid not null);
grant all on test_helpers.p10 to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p10 values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p10 where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

-- One recurring occurrence row, readable regardless of role and RLS (assertions only).
create function test_helpers.occ(p_rule uuid, p_date date)
returns public.recurring_occurrences
language sql stable security definer set search_path = pg_catalog, public as $f$
  select * from public.recurring_occurrences where recurring_rule_id = p_rule and occurrence_date = p_date
$f$;
grant execute on function test_helpers.occ(uuid, date) to public;

-- ================================================================ 1. fixtures: entities, users, members
do $$
declare
  v_pt uuid;
  v_other uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p10_pt', 'P10 PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p10_other', 'P10 OTHER (synthetic)') returning id into v_other;
  perform app_private.provision_default_coa(v_other);

  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000002', 'admin');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000003', 'staff');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000004', 'accountant');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000005', 'viewer');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000006', 'nobody');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000007', 'other_admin');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000002', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000003', 'finance_staff');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000004', 'accountant');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000005', 'viewer_auditor');
  perform test_helpers.mk_member(v_other, 'd0000000-0000-0000-0000-000000000007', 'finance_admin');
end
$$;

-- ================================================================ 2. categories, contacts, financial account
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  other uuid := test_helpers.entity('p10_other');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_cat uuid;
begin
  insert into public.categories (entity_id, name, kind) values (pt, 'Retainer Revenue', 'revenue') returning id into v_cat;
  perform test_helpers.put('cat_rev', v_cat);
  insert into public.categories (entity_id, name, kind) values (pt, 'Office Expense', 'expense') returning id into v_cat;
  perform test_helpers.put('cat_exp', v_cat);
  -- a SEPARATE revenue category for the budget/revenue-target sections (9-10): cat_rev is used by the
  -- recurring invoice rule's template (section 4 onward) and those occurrences generate real draft
  -- invoices against it, which must not leak into a budget report's Committed figure for cat_rev.
  insert into public.categories (entity_id, name, kind) values (pt, 'Consulting Revenue', 'revenue') returning id into v_cat;
  perform test_helpers.put('cat_bg_rev', v_cat);
  insert into public.categories (entity_id, name, kind, is_active) values (pt, 'Retired Expense', 'expense', false) returning id into v_cat;
  perform test_helpers.put('cat_off', v_cat);
  insert into public.categories (entity_id, name, kind) values (other, 'Other Entity Expense', 'expense') returning id into v_cat;
  perform test_helpers.put('cat_other', v_cat);

  perform test_helpers.login(v_owner);
  perform test_helpers.put('cust', public.create_contact(pt, 'key-p10-ct-01', 'customer', 'Klien Retainer'));
  perform test_helpers.put('vend', public.create_contact(pt, 'key-p10-ct-02', 'vendor', 'Vendor Sewa'));
  perform test_helpers.put('bca', public.create_financial_account(pt, 'key-p10-fa-01', 'bank', 'BCA Operasional', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING')));
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. planning.* permission boundary
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  v_staff uuid := 'd0000000-0000-0000-0000-000000000003';
  v_accountant uuid := 'd0000000-0000-0000-0000-000000000004';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000005';
  v_nobody uuid := 'd0000000-0000-0000-0000-000000000006';
  v_today date := test_helpers.today(pt);
begin
  -- planning.view: finance_staff, accountant and viewer_auditor can all list (all empty so far); a stranger cannot.
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(test_helpers.rows(format('select * from public.list_recurring_rules(%L)', pt)) = 0, 'finance_staff can view the recurring rule list');
  perform test_helpers.assert(test_helpers.rows(format('select * from public.list_budgets(%L)', pt)) = 0, 'finance_staff can view the budget list');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert(test_helpers.rows(format('select * from public.list_recurring_rules(%L)', pt)) = 0, 'viewer_auditor can view the recurring rule list');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.list_recurring_rules(%L)', pt), 'FORBIDDEN', 'a stranger with no membership cannot view recurring rules');
  perform test_helpers.expect_msg(format('select public.list_budgets(%L)', pt), 'FORBIDDEN', 'a stranger with no membership cannot view budgets');
  perform test_helpers.logout();

  -- planning.recurring_edit: only finance_admin holds it (Step 06 gap, DECISIONS); finance_staff/accountant/viewer_auditor do not.
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.create_recurring_rule(%L, ''key-p10-perm-01'', ''expense'', ''X'', ''monthly'', %L, ''{}''::jsonb)', pt, v_today),
    'FORBIDDEN', 'finance_staff cannot create a recurring rule');
  perform test_helpers.logout();
  perform test_helpers.login(v_accountant);
  perform test_helpers.expect_msg(format('select public.create_recurring_rule(%L, ''key-p10-perm-02'', ''expense'', ''X'', ''monthly'', %L, ''{}''::jsonb)', pt, v_today),
    'FORBIDDEN', 'accountant holds planning.budget_edit but not planning.recurring_edit');
  perform test_helpers.logout();

  -- planning.budget_edit: finance_admin and accountant hold it; finance_staff and viewer_auditor do not.
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.create_budget(%L, ''key-p10-perm-03'', ''Test Budget'', ''monthly'', %L, %L)', pt, v_today, v_today),
    'FORBIDDEN', 'finance_staff cannot create a budget');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.create_budget(%L, ''key-p10-perm-04'', ''Test Budget'', ''monthly'', %L, %L)', pt, v_today, v_today),
    'FORBIDDEN', 'viewer_auditor cannot create a budget');
  perform test_helpers.logout();

  -- anon has no EXECUTE grant on any P10 function at all: refused before any application check runs.
  perform test_helpers.as_anon();
  perform test_helpers.expect_error(format('select public.list_recurring_rules(%L)', pt), '42501', 'anon has no execute grant on list_recurring_rules');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 4. recurring rule lifecycle
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_cust uuid := test_helpers.g('cust');
  v_vend uuid := test_helpers.g('vend');
  v_bca uuid := test_helpers.g('bca');
  v_cat_rev uuid := test_helpers.g('cat_rev');
  v_cat_exp uuid := test_helpers.g('cat_exp');
  v_today date := test_helpers.today(pt);
  v_inv_tmpl jsonb;
  v_bill_tmpl jsonb;
  v_exp_tmpl jsonb;
  v_rule_inv uuid;
  v_rule_bill uuid;
  r public.recurring_rules%rowtype;
  v_ver integer;
begin
  perform test_helpers.login(v_admin);

  v_inv_tmpl := jsonb_build_object('customer_id', v_cust, 'notes', 'Terima kasih',
    'lines', jsonb_build_array(jsonb_build_object('description', 'Retainer bulanan', 'unit_price', '5000000', 'category_id', v_cat_rev)));
  v_bill_tmpl := jsonb_build_object('vendor_id', v_vend,
    'lines', jsonb_build_array(jsonb_build_object('description', 'Sewa kantor', 'unit_price', '3000000', 'category_id', v_cat_exp)));
  v_exp_tmpl := jsonb_build_object('account_id', v_bca, 'payee_name', 'Toko ATK',
    'lines', jsonb_build_array(jsonb_build_object('description', 'ATK bulanan', 'unit_price', '500000', 'category_id', v_cat_exp)));

  -- template validation: each kind needs the master its generator requires (checked at create/update time).
  perform test_helpers.expect_msg(format('select public.create_recurring_rule(%L, ''key-p10-rr-bad-1'', ''invoice'', ''No customer'', ''monthly'', %L, ''{"lines":[]}''::jsonb)', pt, v_today),
    'INVALID', 'a recurring invoice template needs a known customer');
  perform test_helpers.expect_msg(format('select public.create_recurring_rule(%L, ''key-p10-rr-bad-2'', ''bill'', ''No vendor'', ''monthly'', %L, ''{"lines":[]}''::jsonb)', pt, v_today),
    'INVALID', 'a recurring bill template needs a known vendor');
  perform test_helpers.expect_msg(format('select public.create_recurring_rule(%L, ''key-p10-rr-bad-3'', ''expense'', ''No payee'', ''monthly'', %L, %L::jsonb)', pt, v_today,
    jsonb_build_object('account_id', v_bca)::text), 'INVALID', 'a recurring expense template needs a payee');
  perform test_helpers.expect_msg(format('select public.create_recurring_rule(%L, ''key-p10-rr-bad-4'', ''expense'', ''No account'', ''monthly'', %L, %L::jsonb)', pt, v_today,
    jsonb_build_object('payee_name', 'X')::text), 'INVALID', 'a recurring expense template needs a payment account');

  -- create: the invoice rule, due today, monthly.
  v_rule_inv := public.create_recurring_rule(pt, 'key-p10-rr-01', 'invoice', 'Retainer Klien A', 'monthly', v_today, v_inv_tmpl);
  perform test_helpers.put('rr_inv', v_rule_inv);
  perform test_helpers.assert(public.create_recurring_rule(pt, 'key-p10-rr-01', 'invoice', 'Retainer Klien A', 'monthly', v_today, v_inv_tmpl) = v_rule_inv,
    'creating a recurring rule replays on the same key');
  select * into r from public.recurring_rules where id = v_rule_inv;
  perform test_helpers.assert(r.status = 'active' and r.next_occurrence_date = v_today and r.start_date = v_today
    and r.frequency = 'monthly' and r.interval_count = 1 and r.last_generated_date is null and r.version = 1,
    'a new recurring rule starts active with next_occurrence_date = start_date and nothing generated yet');

  -- the bill and expense rules (also due today), used for the generation and structural-authorization sections below.
  v_rule_bill := public.create_recurring_rule(pt, 'key-p10-rr-02', 'bill', 'Sewa Kantor', 'monthly', v_today, v_bill_tmpl);
  perform test_helpers.put('rr_bill', v_rule_bill);
  perform test_helpers.put('rr_exp', public.create_recurring_rule(pt, 'key-p10-rr-03', 'expense', 'ATK Bulanan', 'weekly', v_today, v_exp_tmpl, 1, 0, null, 'dipakai untuk uji generasi'));

  -- pause / resume / end mechanics (exercised on the invoice and bill rules; the bill rule is reset to
  -- active afterward so the generation sections below can use it too).
  perform test_helpers.expect_msg(format('select public.pause_recurring_rule(%L, ''x'')', v_rule_inv), 'INVALID', 'a pause reason must be at least 5 characters');
  perform public.pause_recurring_rule(v_rule_inv, 'klien sedang cuti panjang');
  select * into r from public.recurring_rules where id = v_rule_inv;
  perform test_helpers.assert(r.status = 'paused' and r.paused_reason = 'klien sedang cuti panjang' and r.paused_at is not null and r.paused_by = v_admin,
    'the rule is now paused, with who/when/why recorded');
  perform test_helpers.expect_msg(format('select public.pause_recurring_rule(%L, ''lagi dipause'')', v_rule_inv), 'INVALID', 'a paused rule cannot be paused again');
  perform public.resume_recurring_rule(v_rule_inv);
  select * into r from public.recurring_rules where id = v_rule_inv;
  perform test_helpers.assert(r.status = 'active' and r.paused_at is null and r.paused_reason is null and r.next_occurrence_date = v_today,
    'resuming clears the pause and does not move next_occurrence_date backward');
  perform test_helpers.expect_msg(format('select public.resume_recurring_rule(%L)', v_rule_inv), 'INVALID', 'an active rule cannot be resumed');

  perform test_helpers.expect_msg(format('select public.end_recurring_rule(%L, ''x'')', v_rule_bill), 'INVALID', 'an end reason must be at least 5 characters');
  perform public.end_recurring_rule(v_rule_bill, 'sedang diuji, akan dipakai lagi setelah ini');
  select * into r from public.recurring_rules where id = v_rule_bill;
  perform test_helpers.assert(r.status = 'ended' and r.ended_reason = 'sedang diuji, akan dipakai lagi setelah ini' and r.ended_at is not null and r.ended_by = v_admin,
    'the bill rule ended, with who/when/why recorded');
  perform test_helpers.expect_msg(format('select public.end_recurring_rule(%L, ''lagi diakhiri'')', v_rule_bill), 'INVALID', 'an already-ended rule cannot be ended again');
  perform test_helpers.expect_msg(format('select public.update_recurring_rule(%L, ''{"label":"x"}''::jsonb)', v_rule_bill), 'INVALID', 'an ended rule can no longer be edited');
  perform test_helpers.logout();
  -- only a superuser fixture reset can revive an ended rule; no application command does this by design.
  update public.recurring_rules set status = 'active', ended_at = null, ended_by = null, ended_reason = null where id = v_rule_bill;
  perform test_helpers.login(v_admin);

  -- optimistic concurrency on update_recurring_rule.
  select version into v_ver from public.recurring_rules where id = v_rule_inv;
  perform test_helpers.expect_msg(format('select public.update_recurring_rule(%L, ''{"label":"Retainer Klien A2"}''::jsonb, %s)', v_rule_inv, v_ver + 1),
    'CONFLICT', 'an expected_version that does not match is refused');
  perform test_helpers.assert(public.update_recurring_rule(v_rule_inv, '{"label":"Retainer Klien A"}'::jsonb, v_ver) = v_ver + 1,
    'a matching expected_version succeeds and bumps the version');
  select * into r from public.recurring_rules where id = v_rule_inv;
  perform test_helpers.assert(r.label = 'Retainer Klien A' and r.template = v_inv_tmpl, 'only the patched field changed; the template is untouched');

  perform test_helpers.logout();
end
$$;

-- ================================================================ 5. generation: a mixed batch, replay, stepping
-- The day-of-month clamp itself (31 Jan + 1 month -> 28/29 Feb, never rolling into March) is proven
-- deterministically, independent of wall-clock "today", by the pure TypeScript mirror in
-- src/domain/planning/planning.test.ts. Here the expected next date is computed with the same
-- "add a month, clamp to the target month's last day" idiom against whatever "today" actually is when
-- this suite runs, so the assertion is robust however close to a month-end the test happens to execute.
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_rule_inv uuid := test_helpers.g('rr_inv');
  v_rule_bill uuid := test_helpers.g('rr_bill');
  v_rule_exp uuid := test_helpers.g('rr_exp');
  v_today date := test_helpers.today(pt);
  v_expected_monthly_next date;
  v_count integer;
  o public.recurring_occurrences%rowtype;
  r public.recurring_rules%rowtype;
  v_inv public.invoices%rowtype;
  v_bill public.bills%rowtype;
  v_exp public.expenses%rowtype;
  v_base public.currency_code;
begin
  -- app_private is off-limits to browser roles (00_baseline_invariants.sql): read this while still superuser.
  v_base := app_private.entity_base_currency(pt);
  perform test_helpers.login(v_admin);
  v_expected_monthly_next := least(
    (date_trunc('month', v_today) + interval '1 month' + make_interval(days => extract(day from v_today)::int - 1))::date,
    (date_trunc('month', v_today) + interval '2 months - 1 day')::date);

  v_count := public.run_due_recurring_occurrences(pt, v_today);
  perform test_helpers.assert(v_count = 3, 'all three due rules (invoice, bill, expense) are processed in one batch call');

  select * into o from test_helpers.occ(v_rule_inv, v_today);
  perform test_helpers.assert(o.status = 'generated' and o.generated_table = 'invoices' and o.generated_id is not null and o.attempts = 1, 'the invoice occurrence generated');
  select * into v_inv from public.invoices where id = o.generated_id;
  perform test_helpers.assert(v_inv.status = 'draft' and v_inv.customer_id = test_helpers.g('cust') and v_inv.currency = v_base
    and v_inv.issue_date = v_today and v_inv.due_date = v_today and v_inv.subtotal = 5000000 and v_inv.total = 5000000,
    'the generated invoice is a plain draft with the template''s amount (Step 15 §14: drafts by default)');

  select * into o from test_helpers.occ(v_rule_bill, v_today);
  perform test_helpers.assert(o.status = 'generated' and o.generated_table = 'bills' and o.generated_id is not null and o.attempts = 1, 'the bill occurrence generated');
  select * into v_bill from public.bills where id = o.generated_id;
  perform test_helpers.assert(v_bill.status = 'draft' and v_bill.vendor_id = test_helpers.g('vend') and v_bill.currency = v_base
    and v_bill.bill_date = v_today and v_bill.due_date = v_today and v_bill.subtotal = 3000000 and v_bill.total = 3000000,
    'the generated bill is a plain draft with the template''s amount');

  select * into o from test_helpers.occ(v_rule_exp, v_today);
  perform test_helpers.assert(o.status = 'generated' and o.generated_table = 'expenses' and o.generated_id is not null and o.attempts = 1, 'the expense occurrence generated');
  select * into v_exp from public.expenses where id = o.generated_id;
  perform test_helpers.assert(v_exp.status = 'draft' and v_exp.payee_name = 'Toko ATK' and v_exp.financial_account_id = test_helpers.g('bca')
    and v_exp.currency = v_base and v_exp.expense_date = v_today and v_exp.subtotal = 500000 and v_exp.total = 500000,
    'the generated expense is a plain draft with the template''s amount');

  select * into r from public.recurring_rules where id = v_rule_inv;
  perform test_helpers.assert(r.last_generated_date = v_today and r.next_occurrence_date = v_expected_monthly_next and r.status = 'active',
    'the invoice rule advanced by one calendar month, preserving/clamping the day of month');
  select * into r from public.recurring_rules where id = v_rule_bill;
  perform test_helpers.assert(r.last_generated_date = v_today and r.next_occurrence_date = v_expected_monthly_next and r.status = 'active',
    'the bill rule advanced identically (same start date, frequency and interval)');
  select * into r from public.recurring_rules where id = v_rule_exp;
  perform test_helpers.assert(r.last_generated_date = v_today and r.next_occurrence_date = v_today + 7 and r.status = 'active',
    'the weekly expense rule advanced by exactly 7 days');

  -- replay: re-running the same as_of finds nothing due anymore (every rule already advanced past it).
  v_count := public.run_due_recurring_occurrences(pt, v_today);
  perform test_helpers.assert(v_count = 0, 'a retried run at the same as_of generates nothing further');
  perform test_helpers.assert(test_helpers.rows(format('select * from public.recurring_occurrences where recurring_rule_id in (%L, %L, %L)', v_rule_inv, v_rule_bill, v_rule_exp)) = 3,
    'still exactly one occurrence row per rule: the unique (recurring_rule_id, occurrence_date) constraint holds');

  -- isolate the bill rule for the failure/retry section: pause the other two so only it is due there.
  perform public.pause_recurring_rule(v_rule_inv, 'menjaga isolasi pengujian retry');
  perform public.pause_recurring_rule(v_rule_exp, 'menjaga isolasi pengujian retry');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. generation: failed-generation retry
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_rule_bill uuid := test_helpers.g('rr_bill');
  v_vend uuid := test_helpers.g('vend');
  v_next_bill date;
  v_count integer;
  o public.recurring_occurrences%rowtype;
  r public.recurring_rules%rowtype;
begin
  select next_occurrence_date into v_next_bill from public.recurring_rules where id = v_rule_bill;

  -- break the template's own referenced master (the vendor), which only the manual/scheduled generation
  -- re-validates at run time; creation- and update-time validation cannot catch this kind of later drift.
  update public.contacts set status = 'inactive' where id = v_vend;

  perform test_helpers.login(v_admin);
  v_count := public.run_due_recurring_occurrences(pt, v_next_bill);
  perform test_helpers.assert(v_count = 1, 'the one due (bill) rule is processed; the invoice and expense rules stay paused');
  perform test_helpers.logout();

  select * into o from test_helpers.occ(v_rule_bill, v_next_bill);
  perform test_helpers.assert(o.status = 'failed' and o.attempts = 1 and o.generated_table is null and o.generated_id is null and o.last_error is not null,
    'the failed attempt is recorded with an error and nothing generated');
  select * into r from public.recurring_rules where id = v_rule_bill;
  perform test_helpers.assert(r.next_occurrence_date = v_next_bill and r.status = 'active',
    'a failure leaves next_occurrence_date untouched so the next run retries the same date (Step 15 §14), and never ends the rule');

  -- fix the underlying problem and retry at the same as_of.
  update public.contacts set status = 'active' where id = v_vend;
  perform test_helpers.login(v_admin);
  v_count := public.run_due_recurring_occurrences(pt, v_next_bill);
  perform test_helpers.assert(v_count = 1, 'the retry processes the same one due rule');
  perform test_helpers.logout();

  select * into o from test_helpers.occ(v_rule_bill, v_next_bill);
  perform test_helpers.assert(o.status = 'generated' and o.attempts = 2 and o.generated_table = 'bills' and o.generated_id is not null and o.last_error is null,
    'the retry succeeds: same occurrence row, attempts incremented, now linked to a real bill');
  select * into r from public.recurring_rules where id = v_rule_bill;
  perform test_helpers.assert(r.next_occurrence_date > v_next_bill and r.last_generated_date = v_next_bill,
    'next_occurrence_date only advances once generation actually succeeds');
end
$$;

-- ================================================================ 7. editing a recurring rule never mutates already-generated history
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_cust uuid := test_helpers.g('cust');
  v_cat_rev uuid := test_helpers.g('cat_rev');
  v_rule_inv uuid := test_helpers.g('rr_inv');
  v_today date := test_helpers.today(pt);
  v_first_date date;
  v_before public.recurring_occurrences%rowtype;
  v_after public.recurring_occurrences%rowtype;
  v_inv1 public.invoices%rowtype;
  v_inv2 public.invoices%rowtype;
  v_next date;
  v_new_tmpl jsonb;
  v_count integer;
  o public.recurring_occurrences%rowtype;
begin
  perform test_helpers.login(v_admin);
  perform public.resume_recurring_rule(v_rule_inv);

  select last_generated_date into v_first_date from public.recurring_rules where id = v_rule_inv;
  select * into v_before from public.recurring_occurrences where recurring_rule_id = v_rule_inv and occurrence_date = v_first_date;
  select * into v_inv1 from public.invoices where id = v_before.generated_id;
  perform test_helpers.assert(v_inv1.total = 5000000, 'the first generated invoice has the original template''s total');

  v_new_tmpl := jsonb_build_object('customer_id', v_cust,
    'lines', jsonb_build_array(jsonb_build_object('description', 'Retainer bulanan (naik)', 'unit_price', '6000000', 'category_id', v_cat_rev)));
  perform public.update_recurring_rule(v_rule_inv, jsonb_build_object('label', 'Retainer Klien A (revisi)', 'template', v_new_tmpl));

  select * into v_after from public.recurring_occurrences where recurring_rule_id = v_rule_inv and occurrence_date = v_first_date;
  perform test_helpers.assert(v_before.id = v_after.id and v_before.generated_table = v_after.generated_table
    and v_before.generated_id = v_after.generated_id and v_before.status = v_after.status
    and v_before.attempts = v_after.attempts and v_before.last_attempted_at = v_after.last_attempted_at
    and v_before.last_error is not distinct from v_after.last_error,
    'the already-generated occurrence row is unchanged after editing the rule');
  select * into v_inv1 from public.invoices where id = v_after.generated_id;
  perform test_helpers.assert(v_inv1.total = 5000000, 'the already-generated invoice keeps its original total; editing never retroactively changes it');

  select next_occurrence_date into v_next from public.recurring_rules where id = v_rule_inv;
  v_count := public.run_due_recurring_occurrences(pt, v_next);
  perform test_helpers.assert(v_count = 1, 'exactly the one due rule (rr_inv) is processed: rr_exp is still paused and rr_bill is not due yet');
  select * into o from test_helpers.occ(v_rule_inv, v_next);
  select * into v_inv2 from public.invoices where id = o.generated_id;
  perform test_helpers.assert(v_inv2.total = 6000000 and v_inv2.id <> v_inv1.id,
    'the NEXT occurrence, generated after the edit, reflects the updated template: editing applies prospectively only');
  perform test_helpers.logout();

  -- the guard holds at the trigger level too, not only by application convention.
  perform test_helpers.expect_error(format('update public.recurring_occurrences set last_error = ''tampered'' where id = %L', v_before.id), null,
    'a generated occurrence is append-only: not even a superuser can update it once generated');
end
$$;

-- ================================================================ 8. structural authorization: service_role vs authenticated
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'd0000000-0000-0000-0000-000000000003';
  v_cust uuid := test_helpers.g('cust');
  v_today date := test_helpers.today(pt);
  v_rule uuid;
  v_count integer;
  o public.recurring_occurrences%rowtype;
begin
  perform test_helpers.login(v_admin);
  v_rule := public.create_recurring_rule(pt, 'key-p10-svc-01', 'invoice', 'Uji Service Role', 'weekly', v_today,
    jsonb_build_object('customer_id', v_cust, 'lines', jsonb_build_array(jsonb_build_object('description', 'Layanan mingguan', 'unit_price', '100000'))));
  perform test_helpers.logout();

  -- finance_staff holds planning.view but not planning.recurring_run: the manual action is refused.
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.run_due_recurring_occurrences(%L, %L)', pt, v_today),
    'FORBIDDEN', 'finance_staff cannot manually run recurring generation (lacks planning.recurring_run)');
  perform test_helpers.logout();

  -- anon has no EXECUTE grant on the function at all: refused before any application-level check runs.
  perform test_helpers.as_anon();
  perform test_helpers.expect_error(format('select public.run_due_recurring_occurrences(%L, %L)', pt, v_today), '42501',
    'anon cannot call run_due_recurring_occurrences at all');
  perform test_helpers.logout();

  -- the scheduled/background path: no signed-in user, service_role only. Nobody was ever granted
  -- planning.recurring_run for this to work; it is authorized structurally (auth.role() = 'service_role').
  perform test_helpers.as_service_role();
  perform test_helpers.assert(auth.uid() is null, 'the service_role path truly has no signed-in user');
  v_count := public.run_due_recurring_occurrences(pt, v_today);
  perform test_helpers.assert(v_count = 1, 'the scheduled path generates the one due occurrence with no signed-in user at all');
  perform test_helpers.logout();

  select * into o from test_helpers.occ(v_rule, v_today);
  perform test_helpers.assert(o.status = 'generated' and o.generated_table = 'invoices' and o.generated_id is not null,
    'the service-role-generated occurrence recorded a real invoice');
end
$$;

-- ================================================================ 9. budgets: lifecycle and the computed report
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_cust uuid := test_helpers.g('cust');
  v_vend uuid := test_helpers.g('vend');
  -- a category not touched by the recurring rules in sections 4-8, so their leftover draft invoices
  -- (which stay draft forever, by design) never leak into this budget's Committed figure.
  v_cat_rev uuid := test_helpers.g('cat_bg_rev');
  v_cat_exp uuid := test_helpers.g('cat_exp');
  v_cat_off uuid := test_helpers.g('cat_off');
  v_cat_other uuid := test_helpers.g('cat_other');
  v_today date := test_helpers.today(pt);
  v_month date := date_trunc('month', v_today)::date;
  v_month_end date := (v_month + interval '1 month - 1 day')::date;
  v_budget uuid;
  v_ver integer;
  v_many jsonb;
  v_inv uuid;
  v_bill1 uuid;
  v_bill2 uuid;
  rep record;
  v_seen integer := 0;
begin
  perform test_helpers.login(v_admin);
  v_budget := public.create_budget(pt, 'key-p10-bg-01', 'Anggaran Bulan Ini', 'monthly', v_month, v_month_end);
  perform test_helpers.put('budget', v_budget);
  perform test_helpers.assert(public.create_budget(pt, 'key-p10-bg-01', 'Anggaran Bulan Ini', 'monthly', v_month, v_month_end) = v_budget,
    'creating a budget replays on the same key');
  perform test_helpers.expect_msg(format('select public.create_budget(%L, ''key-p10-bg-02'', ''Bad'', ''monthly'', %L, %L)', pt, v_month_end, v_month),
    'INVALID', 'the end date cannot be before the start date');

  perform test_helpers.expect_msg(format('select public.set_budget_lines(%L, %L::jsonb)', v_budget,
    jsonb_build_array(jsonb_build_object('category_id', v_cat_off, 'period_month', v_month, 'budgeted_amount', '1'))::text),
    'INVALID', 'an inactive category is refused');
  perform test_helpers.expect_msg(format('select public.set_budget_lines(%L, %L::jsonb)', v_budget,
    jsonb_build_array(jsonb_build_object('category_id', v_cat_other, 'period_month', v_month, 'budgeted_amount', '1'))::text),
    'INVALID', 'a category belonging to another Entity is refused');
  perform test_helpers.expect_msg(format('select public.set_budget_lines(%L, %L::jsonb)', v_budget,
    jsonb_build_array(jsonb_build_object('category_id', v_cat_rev, 'period_month', v_month, 'budgeted_amount', '-1'))::text),
    'INVALID', 'a negative budgeted amount is refused');
  perform test_helpers.expect_msg(format('select public.set_budget_lines(%L, %L::jsonb)', v_budget,
    jsonb_build_array(jsonb_build_object('category_id', v_cat_rev, 'period_month', (v_month + interval '2 months')::date, 'budgeted_amount', '1'))::text),
    'INVALID', 'a period_month outside the budget''s date range is refused');
  select jsonb_agg(jsonb_build_object('category_id', v_cat_rev, 'period_month', v_month, 'budgeted_amount', '1')) into v_many from generate_series(1, 2001);
  perform test_helpers.expect_msg(format('select public.set_budget_lines(%L, %L::jsonb)', v_budget, v_many::text),
    'INVALID', 'a budget cannot have more than 2000 lines');

  perform test_helpers.assert(public.set_budget_lines(v_budget, jsonb_build_array(
      jsonb_build_object('category_id', v_cat_rev, 'period_month', v_month, 'budgeted_amount', '2500000'),
      jsonb_build_object('category_id', v_cat_exp, 'period_month', v_month, 'budgeted_amount', '1000000'))) = 2,
    'the lines are stored and the budget version bumps');
  perform test_helpers.assert(test_helpers.rows(format('select * from public.get_budget_lines(%L)', v_budget)) = 2, 'two stored lines');

  select version into v_ver from public.budgets where id = v_budget;
  perform test_helpers.expect_msg(format('select public.set_budget_lines(%L, ''[]''::jsonb, %s)', v_budget, v_ver + 1),
    'CONFLICT', 'a stale expected_version is refused');
  perform test_helpers.logout();

  -- Actual/Committed data: an issued invoice and an approved bill (Actual); a draft invoice and a submitted bill (Committed).
  perform test_helpers.login(v_owner);
  v_inv := public.create_invoice_draft(pt, 'key-p10-bg-inv-01', v_cust, v_today, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Jasa A', 'unit_price', '2000000', 'category_id', v_cat_rev)));
  perform public.issue_invoice(v_inv, 'key-p10-bg-inv-01-issue');
  perform test_helpers.put('bg_inv', v_inv);
  perform public.create_invoice_draft(pt, 'key-p10-bg-inv-02', v_cust, v_today, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Jasa B (belum diterbitkan)', 'unit_price', '300000', 'category_id', v_cat_rev)));

  v_bill1 := public.create_bill_draft(pt, 'key-p10-bg-bill-01', v_vend, v_today, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Sewa A', 'unit_price', '800000', 'category_id', v_cat_exp)));
  perform public.submit_bill(v_bill1, 'key-p10-bg-bill-01-submit');
  perform public.approve_bill(v_bill1, 'key-p10-bg-bill-01-approve');
  v_bill2 := public.create_bill_draft(pt, 'key-p10-bg-bill-02', v_vend, v_today, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Sewa B (belum disetujui)', 'unit_price', '150000', 'category_id', v_cat_exp)));
  perform public.submit_bill(v_bill2, 'key-p10-bg-bill-02-submit');
  perform test_helpers.logout();

  perform test_helpers.login(v_admin);
  for rep in select * from public.get_budget_report(v_budget) loop
    v_seen := v_seen + 1;
    if rep.category_id = v_cat_rev then
      perform test_helpers.assert(rep.budgeted_amount = 2500000 and rep.actual_amount = 2000000 and rep.committed_amount = 300000
        and rep.remaining_amount = 200000 and rep.pct_used = 80.00 and rep.variance_amount = -500000 and rep.forecast_amount is null,
        'revenue category: Budget 2.5jt, Actual 2jt (issued), Committed 300rb (draft), Remaining 200rb, 80% used, forecast is null');
    elsif rep.category_id = v_cat_exp then
      perform test_helpers.assert(rep.budgeted_amount = 1000000 and rep.actual_amount = 800000 and rep.committed_amount = 150000
        and rep.remaining_amount = 50000 and rep.pct_used = 80.00 and rep.variance_amount = -200000 and rep.forecast_amount is null,
        'expense category: Budget 1jt, Actual 800rb (approved), Committed 150rb (submitted), Remaining 50rb, 80% used, forecast is null');
    else
      perform test_helpers.assert(false, format('unexpected category %s in the budget report', rep.category_id));
    end if;
  end loop;
  perform test_helpers.assert(v_seen = 2, 'exactly the two budgeted lines are reported');

  perform public.activate_budget(v_budget);
  perform test_helpers.expect_msg(format('select public.activate_budget(%L)', v_budget), 'INVALID', 'only a draft budget can be activated');
  perform public.close_budget(v_budget);
  perform test_helpers.expect_msg(format('select public.close_budget(%L)', v_budget), 'INVALID', 'the budget is already closed');
  perform test_helpers.expect_msg(format('select public.set_budget_lines(%L, ''[]''::jsonb)', v_budget), 'INVALID', 'a closed budget cannot be edited');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 10. revenue targets: lifecycle and the computed report
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_cust uuid := test_helpers.g('cust');
  v_bca uuid := test_helpers.g('bca');
  v_today date := test_helpers.today(pt);
  v_month date := date_trunc('month', v_today)::date;
  v_month_end date := (v_month + interval '1 month - 1 day')::date;
  v_target uuid;
  v_many jsonb;
  rep record;
  v_rows integer;
begin
  perform test_helpers.login(v_admin);
  v_target := public.create_revenue_target(pt, 'key-p10-rt-01', 'Target Bulan Ini', 'monthly', v_month, v_month_end);
  perform test_helpers.put('target', v_target);
  perform test_helpers.expect_msg(format('select public.create_revenue_target(%L, ''key-p10-rt-02'', ''Bad'', ''monthly'', %L, %L)', pt, v_month_end, v_month),
    'INVALID', 'the end date cannot be before the start date');

  select jsonb_agg(jsonb_build_object('period_month', v_month, 'target_amount', '1')) into v_many from generate_series(1, 121);
  perform test_helpers.expect_msg(format('select public.set_revenue_target_lines(%L, %L::jsonb)', v_target, v_many::text),
    'INVALID', 'a revenue target cannot have more than 120 monthly lines');
  perform test_helpers.expect_msg(format('select public.set_revenue_target_lines(%L, %L::jsonb)', v_target,
    jsonb_build_array(jsonb_build_object('period_month', v_month, 'target_amount', '-1'))::text),
    'INVALID', 'a negative target amount is refused');

  perform test_helpers.assert(public.set_revenue_target_lines(v_target, jsonb_build_array(
    jsonb_build_object('period_month', v_month, 'target_amount', '1500000'))) = 2, 'the line is stored and the version bumps');
  perform public.activate_revenue_target(v_target);
  perform test_helpers.expect_msg(format('select public.activate_revenue_target(%L)', v_target), 'INVALID', 'only a draft revenue target can be activated');
  perform test_helpers.logout();

  -- Actual = the issued invoice from the budget section (2,000,000); pay 1,200,000 of it so AR outstanding differs from Actual.
  perform test_helpers.login(v_owner);
  perform public.record_payment(pt, 'key-p10-rt-pay-01', v_cust, v_bca, v_today, 1200000,
    jsonb_build_array(jsonb_build_object('invoice_id', test_helpers.g('bg_inv'), 'amount', 1200000)));
  perform test_helpers.logout();

  perform test_helpers.login(v_admin);
  select count(*) into v_rows from public.get_revenue_target_report(v_target);
  perform test_helpers.assert(v_rows = 1, 'one monthly line is reported');
  select * into rep from public.get_revenue_target_report(v_target) limit 1;
  perform test_helpers.assert(rep.target_amount = 1500000 and rep.actual_amount = 2000000 and rep.ar_outstanding_amount = 800000
    and rep.variance_amount = 500000 and rep.forecast_amount is null,
    'Target 1.5jt, Actual 2jt (issued), AR outstanding 800rb after a 1.2jt payment, Variance +500rb, forecast is null');

  perform public.close_revenue_target(v_target);
  perform test_helpers.expect_msg(format('select public.close_revenue_target(%L)', v_target), 'INVALID', 'the revenue target is already closed');
  perform test_helpers.expect_msg(format('select public.set_revenue_target_lines(%L, ''[]''::jsonb)', v_target), 'INVALID', 'a closed revenue target cannot be edited');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 11. RLS and privileges: direct table access
do $$
declare
  pt uuid := test_helpers.entity('p10_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_other_admin uuid := 'd0000000-0000-0000-0000-000000000007';
  v_nobody uuid := 'd0000000-0000-0000-0000-000000000006';
  t text;
begin
  -- an admin of a different Entity cannot see this Entity's planning data at all.
  perform test_helpers.login(v_other_admin);
  perform test_helpers.expect_msg(format('select public.list_recurring_rules(%L)', pt), 'FORBIDDEN', 'another Entity''s admin cannot view this Entity''s recurring rules');
  perform test_helpers.expect_msg(format('select public.list_budgets(%L)', pt), 'FORBIDDEN', 'another Entity''s admin cannot view this Entity''s budgets');
  perform test_helpers.logout();

  perform test_helpers.login(v_nobody);
  perform test_helpers.assert((select count(*) from public.recurring_rules) = 0 and (select count(*) from public.recurring_occurrences) = 0
    and (select count(*) from public.budgets) = 0 and (select count(*) from public.budget_lines) = 0
    and (select count(*) from public.revenue_targets) = 0 and (select count(*) from public.revenue_target_lines) = 0,
    'a stranger with no membership anywhere sees no P10 data at all, even by selecting the tables directly');
  perform test_helpers.logout();

  -- browser roles (even the OWNER) have no direct write access to any P10 table; everything goes through a command.
  perform test_helpers.login(v_owner);
  foreach t in array array['recurring_rules', 'recurring_occurrences', 'budgets', 'budget_lines', 'revenue_targets', 'revenue_target_lines'] loop
    perform test_helpers.expect_error(format('insert into public.%I select * from public.%I limit 1', t, t), '42501', format('the OWNER cannot insert into %s directly', t));
    perform test_helpers.expect_error(format('update public.%I set entity_id = entity_id', t), '42501', format('nor update %s', t));
    perform test_helpers.expect_error(format('delete from public.%I', t), '42501', format('nor delete from %s', t));
    perform test_helpers.expect_error(format('truncate public.%I', t), '42501', format('nor truncate %s', t));
  end loop;
  perform test_helpers.logout();

  -- anon cannot even read any P10 table.
  perform test_helpers.as_anon();
  foreach t in array array['recurring_rules', 'recurring_occurrences', 'budgets', 'budget_lines', 'revenue_targets', 'revenue_target_lines'] loop
    perform test_helpers.expect_error(format('select 1 from public.%I', t), '42501', format('anonymous cannot read %s', t));
  end loop;
  perform test_helpers.logout();

  -- the three append-only tables refuse delete/truncate even from a superuser session.
  foreach t in array array['recurring_occurrences', 'budget_lines', 'revenue_target_lines'] loop
    perform test_helpers.expect_error(format('delete from public.%I', t), null, format('%s is append-only: nobody deletes from it, not even a superuser', t));
    perform test_helpers.expect_error(format('truncate public.%I cascade', t), null, format('%s is append-only: nobody truncates it, not even a superuser', t));
  end loop;
end
$$;

rollback;
