-- P8 gate, part 5 (Step 15 §12, Step 16 §16-17): the financing control, the tax review of the financing events, and the
-- period close checks for fixed assets, loans, other receivables and payables, dividends and depreciation. All data is
-- synthetic; dates are relative to the Entity's today. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p8e (k text primary key, v uuid not null);
grant all on test_helpers.p8e to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p8e values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p8e where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

-- the item count of a check code in a period (0 when the check does not fire); the code's severity
create function test_helpers.chk(p_period uuid, p_code text) returns bigint
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(max(item_count), 0) from app_private.period_blockers(p_period) where code = p_code $f$;
create function test_helpers.sev(p_period uuid, p_code text) returns text
language sql security definer set search_path = pg_catalog, public as $f$
  select max(severity) from app_private.period_blockers(p_period) where code = p_code $f$;
grant execute on function test_helpers.chk(uuid, text), test_helpers.sev(uuid, text) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p8e_pt', 'P8E PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p8e_pe', 'P8E PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000002', 'admin');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000007', 'nobody');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000008', 'staff');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000009', 'taxman');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000002', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000008', 'finance_staff');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000009', 'tax');
end
$$;

-- ================================================================ 1. the fixed asset checks
do $$
declare
  pt uuid := test_helpers.entity('p8e_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_acq date := (date_trunc('month', test_helpers.today(pt)) - interval '1 month')::date + 9;
  v_through date := (date_trunc('month', test_helpers.today(pt)) - interval '1 day')::date;
  v_prev uuid;
  v_cur uuid;
  v_b uuid;
  v_a uuid;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.put('bca', public.create_financial_account(pt, 'key-p8e-fa-01', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-SECRET-1', 'PT P8E'));
  perform test_helpers.put('va', public.create_contact(pt, 'key-p8e-ct-01', 'vendor', 'Vendor A'));
  v_b := public.create_bill_draft(pt, 'key-p8e-b-01', test_helpers.g('va'), v_acq, v_acq + 30,
    '[{"description":"Laptop","unit_price":"12000000","treatment":"asset"}]', 'INV-P8E-1');
  perform public.approve_bill(v_b, 'key-p8e-b-01a');
  select id into v_a from public.fixed_assets where entity_id = pt;
  perform test_helpers.put('laptop', v_a);
  perform test_helpers.logout();
  v_prev := app_private.ensure_accounting_period(pt, v_acq);
  v_cur := app_private.ensure_accounting_period(pt, v_today);

  -- a draft asset: the register already carries its cost (the line is linked), and nothing is due
  perform test_helpers.assert(test_helpers.chk(v_prev, 'asset_ledger_mismatch') = 0 and test_helpers.chk(v_prev, 'depreciation_not_posted') = 0
    and test_helpers.chk(v_prev, 'asset_lines_pending') = 0, 'a registered draft asset raises no asset check');

  perform test_helpers.login(v_owner);
  perform public.asset_activate(v_a, 'key-p8e-ac-1', v_acq, 'straight_line', 48);
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.chk(v_prev, 'depreciation_not_posted') = 1 and test_helpers.sev(v_prev, 'depreciation_not_posted') = 'blocker',
    'the month of the asset is over and its depreciation is not posted: a blocker');
  perform test_helpers.assert(test_helpers.chk(v_cur, 'depreciation_not_posted') = 0, 'the running month is not due yet: no blocker on the current period');
  perform test_helpers.login('d0000000-0000-0000-0000-000000000006');
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_prev) where code = 'depreciation_not_posted' and severity = 'blocker'),
    'the accountant sees the blocker in the period close checks');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform public.asset_post_depreciation(pt, v_through);
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.chk(v_prev, 'depreciation_not_posted') = 0 and test_helpers.chk(v_prev, 'asset_ledger_mismatch') = 0,
    'posting the depreciation clears the blocker and the register still equals the ledger');

  -- the register against the ledger: a posting to a fixed asset account with no asset behind it
  begin
    perform app_private.post_system_journal(pt, 'bill', gen_random_uuid(), 'bill.approve', 'bill.v1', v_today, 'Probe: cost with no asset',
      app_private.add_line(app_private.add_line('[]'::jsonb, test_helpers.acct(pt, 'FIXED_ASSET_EQUIPMENT'), 1000, 0, 'probe'),
                           test_helpers.acct(pt, 'ACCOUNTS_PAYABLE'), 0, 1000, 'probe'));
    perform test_helpers.assert(test_helpers.chk(v_cur, 'asset_ledger_mismatch') >= 1 and test_helpers.sev(v_cur, 'asset_ledger_mismatch') = 'blocker',
      'a fixed asset account that differs from the register is a close blocker');
    raise exception 'PROBE_DONE';
  exception when others then
    if sqlerrm <> 'PROBE_DONE' then
      raise;
    end if;
  end;
  perform test_helpers.assert(test_helpers.chk(v_cur, 'asset_ledger_mismatch') = 0, 'the probe was rolled back');
end
$$;

-- ================================================================ 2. pending asset lines
do $$
declare
  pt uuid := test_helpers.entity('p8e_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_cur uuid;
  v_line uuid;
begin
  v_cur := app_private.ensure_accounting_period(pt, v_today);
  -- a line that is booked as an asset but not registered (made pending on purpose, as the P6 flow leaves it)
  begin
    update public.bill_lines l set asset_link_status = 'pending'
    where l.entity_id = pt and l.bill_id = (select id from public.bills where entity_id = pt limit 1) and l.asset_link_status = 'linked'
    returning l.id into v_line;
    perform test_helpers.assert(v_line is not null, 'a linked line was made pending for the probe');
    perform test_helpers.assert(test_helpers.chk(app_private.ensure_accounting_period(pt, (date_trunc('month', v_today) - interval '1 month')::date + 9), 'asset_lines_pending') = 1
      and test_helpers.sev(app_private.ensure_accounting_period(pt, (date_trunc('month', v_today) - interval '1 month')::date + 9), 'asset_lines_pending') = 'warning',
      'an approved asset line that is not registered is a warning');
    raise exception 'PROBE_DONE';
  exception when others then
    if sqlerrm <> 'PROBE_DONE' then
      raise;
    end if;
  end;
end
$$;

-- ================================================================ 3. loans, other obligations, equity: the checks and the tax review
do $$
declare
  pt uuid := test_helpers.entity('p8e_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_cur uuid;
  v_loan uuid;
  v_pay uuid;
  v_obl uuid;
  v_wo uuid;
  v_ev uuid;
  v_div uuid;
  v_dp uuid;
  v_n bigint;
begin
  v_cur := app_private.ensure_accounting_period(pt, v_today);
  perform test_helpers.login(v_owner);
  -- funding
  v_ev := public.equity_create(pt, 'k-p8e-e1', 'contribution', v_today, '80000000', 'Owner', null, 'Initial capital');
  perform public.equity_confirm(v_ev, 'k-p8e-e1c', v_bca);

  -- a loan received, then an installment with interest (the interest is flagged for a tax review)
  v_loan := public.loan_create(pt, 'k-p8e-l1', 'borrowed', 'Bank X', null, 'Working capital', '12000000', v_today, 'short', '12', 'annuity', 12, 1, v_today);
  perform public.loan_activate(v_loan, 'k-p8e-l1a', v_today, v_bca);
  perform test_helpers.assert(test_helpers.chk(v_cur, 'financing_ledger_mismatch') = 0 and test_helpers.chk(v_cur, 'financing_tax_review_pending') = 0,
    'a loan received: the loan account equals the register, nothing waits for a tax review');
  perform test_helpers.assert(test_helpers.chk(v_cur, 'loan_installments_overdue') = 1 and test_helpers.sev(v_cur, 'loan_installments_overdue') = 'warning',
    'the first installment falls due today and is unpaid: a warning');
  v_pay := public.loan_repay(v_loan, 'k-p8e-l1r', v_today, v_bca, '500000', '120000', '0', 'Installment with interest');
  perform test_helpers.assert(test_helpers.chk(v_cur, 'financing_tax_review_pending') = 1 and test_helpers.sev(v_cur, 'financing_tax_review_pending') = 'warning',
    'a payment with interest waits for a tax review');

  -- an other receivable, part of it written off (needs step-up: the login is fresh)
  v_obl := public.obligation_create(pt, 'k-p8e-o1', 'receivable', 'Friendly Co', null, v_today, v_today + 30, '5000000', 'cash', v_bca, null, 'Short advance to a friendly customer');
  v_wo := public.obligation_write_off(v_obl, 'k-p8e-o1w', v_today, '1000000', 'Customer closed down, part not recoverable');

  -- a dividend, and part of it paid
  v_div := public.equity_create(pt, 'k-p8e-d1', 'dividend', v_today, '2000000', 'Shareholders', null, 'Interim dividend', null, 'RUPS 2026/07');
  perform public.equity_confirm(v_div, 'k-p8e-d1c');
  v_dp := public.equity_pay_dividend(v_div, 'k-p8e-d1p', v_today, v_bca, '800000', 'First instalment');
  perform test_helpers.logout();

  perform test_helpers.assert(test_helpers.chk(v_cur, 'financing_ledger_mismatch') = 0, 'loans, other receivables and dividends payable all equal their accounts');
  select count(*) into v_n from (
    select 1 from public.other_obligation_settlements where entity_id = pt and status = 'active' and tax_status = 'needs_review'
    union all select 1 from public.loan_payments where entity_id = pt and status = 'active' and tax_status = 'needs_review'
    union all select 1 from public.equity_events where entity_id = pt and status = 'confirmed' and tax_status = 'needs_review'
    union all select 1 from public.equity_dividend_payments where entity_id = pt and status = 'active' and tax_status = 'needs_review') q;
  perform test_helpers.assert(v_n >= 3 and test_helpers.chk(v_cur, 'financing_tax_review_pending') = v_n,
    'the warning counts every financing event waiting for a review: ' || v_n);
  perform test_helpers.put('loan_pay', v_pay);
  perform test_helpers.put('wo', v_wo);
  perform test_helpers.put('div', v_div);
  perform test_helpers.put('dp', v_dp);
end
$$;

-- ================================================================ 4. the financing control report
do $$
declare
  pt uuid := test_helpers.entity('p8e_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_cur uuid;
  r record;
begin
  v_cur := app_private.ensure_accounting_period(pt, v_today);
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select count(*) from public.financing_control_report(pt)) = 5
    and (select bool_and(difference::numeric = 0) from public.financing_control_report(pt)), 'five control accounts, every difference nil');
  select * into r from public.financing_control_report(pt) where account_key = 'LOAN_SHORT_TERM';
  perform test_helpers.assert(r.sub_ledger::numeric = 11500000 and r.ledger_total::numeric = 11500000, 'the short-term loan account: 12,000,000 less 500,000 repaid');
  select * into r from public.financing_control_report(pt) where account_key = 'OTHER_RECEIVABLE';
  perform test_helpers.assert(r.sub_ledger::numeric = 4000000 and r.ledger_total::numeric = 4000000, 'the other receivable: 5,000,000 less 1,000,000 written off');
  select * into r from public.financing_control_report(pt) where account_key = 'DIVIDEND_PAYABLE';
  perform test_helpers.assert(r.sub_ledger::numeric = 1200000 and r.ledger_total::numeric = 1200000, 'the dividend payable: 2,000,000 less 800,000 paid');
  select * into r from public.financing_control_report(pt, v_today - 400) where account_key = 'DIVIDEND_PAYABLE';
  perform test_helpers.assert(r.sub_ledger::numeric = 0 and r.ledger_total::numeric = 0, 'as of a date before any of it, everything is nil');
  perform test_helpers.logout();

  -- a posting to a control account outside its workflow is a blocker
  begin
    perform app_private.post_system_journal(pt, 'loan', gen_random_uuid(), 'loan.probe', 'loan.v1', v_today, 'Probe: a loan journal with no loan',
      app_private.add_line(app_private.add_line('[]'::jsonb, test_helpers.acct(pt, 'BANK_OPERATING'), 1000, 0, 'probe'),
                           test_helpers.acct(pt, 'LOAN_SHORT_TERM'), 0, 1000, 'probe'));
    perform test_helpers.assert(test_helpers.chk(v_cur, 'financing_ledger_mismatch') = 1 and test_helpers.sev(v_cur, 'financing_ledger_mismatch') = 'blocker',
      'a loan account that differs from the loan register is a close blocker');
    perform test_helpers.login(v_owner);
    perform test_helpers.assert((select difference::numeric from public.financing_control_report(pt) where account_key = 'LOAN_SHORT_TERM') = -1000, 'the report shows the difference');
    perform test_helpers.logout();
    raise exception 'PROBE_DONE';
  exception when others then
    if sqlerrm <> 'PROBE_DONE' then
      raise;
    end if;
  end;
  begin
    perform app_private.post_system_journal(pt, 'equity_event', gen_random_uuid(), 'equity.probe', 'equity.v1', v_today, 'Probe: a dividend payable with no dividend',
      app_private.add_line(app_private.add_line('[]'::jsonb, test_helpers.acct(pt, 'RETAINED_EARNINGS'), 1000, 0, 'probe'),
                           test_helpers.acct(pt, 'DIVIDEND_PAYABLE'), 0, 1000, 'probe'));
    perform test_helpers.assert(test_helpers.chk(v_cur, 'financing_ledger_mismatch') = 1, 'a dividend payable that differs from the dividends is a close blocker');
    raise exception 'PROBE_DONE';
  exception when others then
    if sqlerrm <> 'PROBE_DONE' then
      raise;
    end if;
  end;
  perform test_helpers.assert(test_helpers.chk(v_cur, 'financing_ledger_mismatch') = 0, 'the probes were rolled back');

  -- the Personal Entity has its own control accounts (no dividends there)
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select array_agg(account_key order by account_key) from public.financing_control_report(test_helpers.entity('p8e_pe')))
    = array['OTHER_PAYABLE', 'OTHER_RECEIVABLE', 'PERSONAL_LOAN'], 'the Personal Entity is controlled on its own three accounts');
  perform test_helpers.logout();

  -- who may read the control
  perform test_helpers.login('d0000000-0000-0000-0000-000000000004');
  perform test_helpers.assert((select count(*) from public.financing_control_report(pt)) = 5, 'an auditor reads the control');
  perform test_helpers.logout();
  perform test_helpers.login('d0000000-0000-0000-0000-000000000008');
  perform test_helpers.expect_msg(format('select * from public.financing_control_report(%L)', pt), 'FORBIDDEN', 'staff cannot read the control');
  perform test_helpers.logout();
  perform test_helpers.login('d0000000-0000-0000-0000-000000000007');
  perform test_helpers.expect_msg(format('select * from public.financing_control_report(%L)', pt), 'FORBIDDEN', 'a stranger cannot read the control');
  perform test_helpers.logout();
  perform test_helpers.expect_msg(format('select * from public.financing_control_report(%L)', pt), 'UNAUTHENTICATED', 'nobody, no control');
end
$$;

-- ================================================================ 5. the tax review command
do $$
declare
  pt uuid := test_helpers.entity('p8e_pt');
  pe uuid := test_helpers.entity('p8e_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_tax uuid := 'd0000000-0000-0000-0000-000000000009';
  v_today date := test_helpers.today(pt);
  v_cur uuid;
  v_before bigint;
  v_evt uuid;
  r record;
begin
  v_cur := app_private.ensure_accounting_period(pt, v_today);
  v_before := test_helpers.chk(v_cur, 'financing_tax_review_pending');

  perform test_helpers.login(v_tax);
  perform test_helpers.assert((select count(*) from public.financing_tax_reviews(pt)) = v_before, 'the queue lists what waits: ' || v_before);
  perform test_helpers.assert((select array_agg(distinct source_type order by source_type) from public.financing_tax_reviews(pt))
    = array['dividend_payment', 'equity_event', 'loan_payment', 'obligation_settlement'], 'all four kinds of financing events are queued');
  perform test_helpers.expect_msg(format('select public.financing_tax_review(%L, ''loan_payment'', %L, ''ok'')', pt, test_helpers.g('loan_pay')), 'INVALID', 'a conclusion is written down');
  perform test_helpers.expect_msg(format('select public.financing_tax_review(%L, ''bill'', %L, ''Interest checked with the adviser'')', pt, test_helpers.g('loan_pay')), 'INVALID', 'a known kind of record');
  perform test_helpers.expect_msg(format('select public.financing_tax_review(%L, ''loan_payment'', %L, ''Interest checked with the adviser'')', pt, gen_random_uuid()), 'INVALID', 'a known record');
  perform test_helpers.expect_msg(format('select public.financing_tax_review(%L, ''loan_payment'', %L, ''Interest checked with the adviser'')', pe, test_helpers.g('loan_pay')), 'FORBIDDEN', 'not through another Entity');
  perform public.financing_tax_review(pt, 'loan_payment', test_helpers.g('loan_pay'), 'Interest is deductible and the lender is a bank; nothing withheld');
  perform public.financing_tax_review(pt, 'obligation_settlement', test_helpers.g('wo'), 'Write-off documented; treatment agreed with the adviser');
  perform public.financing_tax_review(pt, 'dividend_payment', test_helpers.g('dp'), 'Withholding on the dividend reviewed with the adviser');
  perform test_helpers.expect_msg(format('select public.financing_tax_review(%L, ''loan_payment'', %L, ''Interest checked again with the adviser'')', pt, test_helpers.g('loan_pay')), 'CONFLICT', 'a review is made once');
  perform test_helpers.logout();

  select * into r from public.loan_payments where id = test_helpers.g('loan_pay');
  perform test_helpers.assert(r.tax_status = 'reviewed' and r.tax_reviewed_by = v_tax and r.tax_reviewed_at is not null and r.tax_note like 'Interest is deductible%'
    and r.interest = 120000 and r.principal = 500000 and r.status = 'active', 'the review records who, when and what; the facts of the payment are untouched');
  perform test_helpers.assert(exists (select 1 from public.audit_events where entity_id = pt and target_table = 'loan_payments' and target_id = r.id
    and reason = 'tax review of a financing event'), 'the review is in the audit log');
  perform test_helpers.assert(test_helpers.chk(v_cur, 'financing_tax_review_pending') = v_before - 3, 'three fewer wait for a review');

  -- the dividend itself (the equity event) is reviewed by the owner, if it was flagged
  select id into v_evt from public.equity_events where id = test_helpers.g('div');
  perform test_helpers.login(v_owner);
  if exists (select 1 from public.equity_events where id = v_evt and tax_status = 'needs_review') then
    perform public.financing_tax_review(pt, 'equity_event', v_evt, 'Dividend declared by resolution; withholding on payment');
  end if;
  perform test_helpers.assert(not exists (select 1 from public.financing_tax_reviews(pt)), 'nothing is left in the queue');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.chk(v_cur, 'financing_tax_review_pending') = 0, 'the period check no longer warns');

  -- authorization: the review needs tax.confirm_facts, reading the queue needs tax.view
  perform test_helpers.login(v_admin);
  perform test_helpers.assert((select count(*) from public.financing_tax_reviews(pt)) = 0, 'finance admin can read the queue (tax.view)');
  perform test_helpers.expect_msg(format('select public.financing_tax_review(%L, ''loan_payment'', %L, ''Interest checked with the adviser'')', pt, test_helpers.g('loan_pay')), 'FORBIDDEN', 'finance admin cannot record a tax conclusion');
  perform test_helpers.logout();
  perform test_helpers.login('d0000000-0000-0000-0000-000000000004');
  perform test_helpers.expect_msg(format('select public.financing_tax_review(%L, ''loan_payment'', %L, ''Interest checked with the adviser'')', pt, test_helpers.g('loan_pay')), 'FORBIDDEN', 'an auditor cannot record a tax conclusion');
  perform test_helpers.logout();
  perform test_helpers.login('d0000000-0000-0000-0000-000000000008');
  perform test_helpers.expect_msg(format('select * from public.financing_tax_reviews(%L)', pt), 'FORBIDDEN', 'staff cannot read the queue');
  perform test_helpers.logout();
  perform test_helpers.expect_msg(format('select public.financing_tax_review(%L, ''loan_payment'', %L, ''Interest checked with the adviser'')', pt, test_helpers.g('loan_pay')), 'UNAUTHENTICATED', 'nobody, no review');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = pt and description like '%tax review%'), 'a review posts nothing');
end
$$;

-- ================================================================ 6. the shape of the fiscal depreciation groups
do $$
declare
  v_ok constant text := '{"first_year":"prorate_months_from_acquisition_month","classes":[{"key":"group_1","name":"Group 1","building":false,"depreciable":true,"life_years":4,"sl_rate":"0.25","db_rate":"0.5"},{"key":"land","name":"Land","building":false,"depreciable":false,"life_years":null,"sl_rate":null,"db_rate":null}]}';
begin
  perform test_helpers.assert(app_private.tax_rule_params_problem('fiscal_depreciation', v_ok::jsonb) is null, 'well-formed groups pass');
  perform test_helpers.assert(app_private.tax_rule_params_problem('fiscal_depreciation', '{"classes":[]}'::jsonb) is not null, 'the first-year rule is needed');
  perform test_helpers.assert(app_private.tax_rule_params_problem('fiscal_depreciation', '{"first_year":"prorate_months_from_acquisition_month","classes":[]}'::jsonb) is not null, 'at least one group');
  perform test_helpers.assert(app_private.tax_rule_params_problem('fiscal_depreciation', replace(v_ok, '"sl_rate":"0.25"', '"sl_rate":"1.5"')::jsonb) is not null, 'a rate is a decimal below one');
  perform test_helpers.assert(app_private.tax_rule_params_problem('fiscal_depreciation', replace(v_ok, '"life_years":4', '"life_years":0')::jsonb) is not null, 'a life of at least one year');
  perform test_helpers.assert(app_private.tax_rule_params_problem('fiscal_depreciation', replace(v_ok, '"key":"land"', '"key":"group_1"')::jsonb) is not null, 'the keys are unique');
  perform test_helpers.assert(app_private.tax_rule_params_problem('fiscal_depreciation',
    '{"first_year":"prorate_months_from_acquisition_month","classes":[{"key":"b","name":"B","building":true,"depreciable":true,"life_years":20,"sl_rate":"0.05","db_rate":"0.1"}]}'::jsonb) is not null,
    'a building allows straight-line only');
  perform test_helpers.assert(app_private.tax_rule_params_problem('fiscal_depreciation', '[]'::jsonb) is not null, 'the parameters are an object');
end
$$;

rollback;
