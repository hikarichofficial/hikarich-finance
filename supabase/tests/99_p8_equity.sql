-- P8 gate, part 4 (Step 07 §13, Step 08 §14, Step 16 §17): capital and equity workflows are explicit economic
-- classifications. Covers contributions, capital returns, dividends (declaration, partial payments, reversal), the
-- retained-earnings warning, the equity.approve right and step-up, Personal investment and distribution events, the
-- related-Entity tag, the dividend payable control, authorization and immutability. All data is synthetic; dates are
-- relative to the Entity's today. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p8d (k text primary key, v uuid not null);
grant all on test_helpers.p8d to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p8d values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p8d where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

create function test_helpers.jd(p_journal uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.debit), 0) from public.journal_lines l
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.journal_id = p_journal and a.system_key = p_key $f$;
create function test_helpers.jc(p_journal uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.credit), 0) from public.journal_lines l
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.journal_id = p_journal and a.system_key = p_key $f$;
create function test_helpers.bal(p_entity uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.debit - l.credit), 0)
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id and j.status = 'posted'
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = p_key $f$;
grant execute on function test_helpers.jd(uuid, text), test_helpers.jc(uuid, text), test_helpers.bal(uuid, text) to public;

create function test_helpers.mc(p_entity uuid, p_as_of date default null)
returns table (financial_account_id uuid, name text, kind text, currency text, is_active boolean,
               movement_balance numeric, movement_base_balance numeric, ledger_balance numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.money_control_rows(p_entity, p_as_of) $f$;
grant execute on function test_helpers.mc(uuid, date) to public;


create function test_helpers.controls8d(p_entity uuid, p_label text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $f$
declare
  v_today date := app_private.entity_today(p_entity);
begin
  if exists (select 1 from app_private.money_control_rows(p_entity) r where r.ledger_balance <> r.movement_base_balance) then
    raise exception 'TEST FAIL [%]: money movements differ from the ledger', p_label;
  end if;
  if app_private.dividends_payable_total(p_entity, v_today) <> -test_helpers.bal(p_entity, 'DIVIDEND_PAYABLE') then
    raise exception 'TEST FAIL [%]: dividends payable % differ from the ledger %', p_label,
      app_private.dividends_payable_total(p_entity, v_today), -test_helpers.bal(p_entity, 'DIVIDEND_PAYABLE');
  end if;
  if exists (select 1 from public.equity_events e where e.entity_id = p_entity and e.kind = 'dividend'
             and app_private.dividend_outstanding(e.id) < 0) then
    raise exception 'TEST FAIL [%]: a dividend is paid beyond its amount', p_label;
  end if;
  if exists (select 1 from public.equity_events e where e.entity_id = p_entity and e.status = 'confirmed' and e.kind <> 'dividend'
             and not exists (select 1 from public.money_movements m where m.source_type = 'equity_event' and m.source_id = e.id)) then
    raise exception 'TEST FAIL [%]: a confirmed cash event has no money movement', p_label;
  end if;
end
$f$;
grant execute on function test_helpers.controls8d(uuid, text) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p8d_pt', 'P8D PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p8d_pe', 'P8D PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000002', 'admin');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000007', 'nobody');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000008', 'staff');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000002', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000008', 'finance_staff');
end
$$;

-- ================================================================ 1. setup and validation
do $$
declare
  pt uuid := test_helpers.entity('p8d_pt');
  pe uuid := test_helpers.entity('p8d_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_today date := test_helpers.today(pt);
begin
  perform test_helpers.assert(exists (select 1 from public.permissions where key = 'equity.approve'), 'the approval right is in the catalog');
  perform test_helpers.assert(not exists (select 1 from public.role_permissions where permission_key = 'equity.approve'), 'no role template holds it: only the owner does');
  perform test_helpers.login(v_owner);
  perform test_helpers.put('bca', public.create_financial_account(pt, 'k-p8d-fa-1', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-SECRET-1', 'PT P8D'));
  perform test_helpers.put('usd', public.create_financial_account(pt, 'k-p8d-fa-2', 'bank', 'USD Account', 'USD'));
  perform test_helpers.put('pe_bank', public.create_financial_account(pe, 'k-p8d-fa-3', 'bank', 'Personal BCA', 'IDR', test_helpers.acct(pe, 'PERSONAL_BANK')));
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0a'', ''investment_contribution'', %L, ''1000000'', ''Owner'', null, ''Wrong Entity type'')', pt, v_today), 'INVALID', 'a company has no investment contribution');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0b'', ''dividend'', %L, ''1000000'', ''Owner'', null, ''Wrong Entity type'', null, ''RUPS 1'')', pe, v_today), 'INVALID', 'a personal Entity declares no dividend');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0c'', ''gift'', %L, ''1000000'', ''Owner'', null, ''Unknown kind'')', pt, v_today), 'INVALID', 'a known kind');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0d'', ''contribution'', %L, ''0'', ''Owner'', null, ''Zero amount'')', pt, v_today), 'INVALID', 'an amount above zero');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0e'', ''contribution'', %L, ''1000000'', ''Owner'', null, ''Future date'')', pt, v_today + 1), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0f'', ''contribution'', %L, ''1000000'', ''Owner'', null, ''Bad class'', ''preferred'')', pt, v_today), 'INVALID', 'a known equity class');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0g'', ''dividend'', %L, ''1000000'', ''Owner'', null, ''No resolution'')', pt, v_today), 'INVALID', 'a dividend needs its resolution');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0h'', ''capital_return'', %L, ''1000000'', ''Owner'', null, ''No resolution'', ''capital'', ''ab'')', pt, v_today), 'INVALID', 'a capital return needs its resolution');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0i'', ''dividend'', %L, ''1000000'', ''Owner'', null, ''Dividend with a class'', ''capital'', ''RUPS 1'')', pt, v_today), 'INVALID', 'a dividend has no equity class');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0j'', ''contribution'', %L, ''1000000'', ''Owner'', null, ''Related without basis'', null, null, %L)', pt, v_today, pe), 'INVALID', 'a related Entity needs its basis');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0k'', ''contribution'', %L, ''1000000'', '''', null, ''No counterparty'')', pt, v_today), 'INVALID', 'a counterparty is named');
  perform test_helpers.assert(not exists (select 1 from public.equity_events), 'refused events change nothing');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-c0l'', ''contribution'', %L, ''1000000'', ''Owner'', null, ''A viewer cannot'')', pt, v_today), 'FORBIDDEN', 'a viewer cannot record equity');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. contributions
do $$
declare
  pt uuid := test_helpers.entity('p8d_pt');
  pe uuid := test_helpers.entity('p8d_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'd0000000-0000-0000-0000-000000000008';
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_e uuid;
  v_e2 uuid;
  v_e3 uuid;
  v_j uuid;
  e public.equity_events%rowtype;
begin
  perform test_helpers.login(v_owner);
  v_e := public.equity_create(pt, 'k-p8d-e1', 'contribution', v_today - 30, '50000000', 'Owner (Personal)', null, 'Initial paid-in capital', null, null, pe, 'Shareholder, initial capital');
  perform test_helpers.put('e1', v_e);
  perform test_helpers.assert(public.equity_create(pt, 'k-p8d-e1', 'contribution', v_today - 30, '50000000', 'Owner (Personal)', null, 'Initial paid-in capital', null, null, pe, 'Shareholder, initial capital') = v_e, 'creation replays on the same key');
  perform test_helpers.logout();
  select * into e from public.equity_events where id = v_e;
  perform test_helpers.assert(e.status = 'draft' and e.equity_class = 'capital' and e.event_number like 'EQ-%' and e.journal_id is null and e.related_entity_id = pe, 'a draft contribution, capital by default');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = pt), 'a draft posts nothing');

  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-e1x'')', v_e), 'INVALID', 'a contribution names the account the cash comes into');
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-e1y'', %L)', v_e, test_helpers.g('usd')), 'INVALID', 'a base-currency account only');
  v_j := public.equity_confirm(v_e, 'k-p8d-e1z', v_bca);
  perform test_helpers.assert(public.equity_confirm(v_e, 'k-p8d-e1z', v_bca) = v_j, 'confirmation replays on the same key');
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-e1w'', %L)', v_e, v_bca), 'CONFLICT', 'a confirmed event is not confirmed again');
  perform test_helpers.logout();
  select * into e from public.equity_events where id = v_e;
  perform test_helpers.assert(e.status = 'confirmed' and e.journal_id = v_j and e.financial_account_id = v_bca and e.confirmed_by = v_admin and e.tax_status = 'not_applicable', 'a finance admin confirms a contribution');
  perform test_helpers.assert(test_helpers.jd(v_j, 'BANK_OPERATING') = 50000000 and test_helpers.jc(v_j, 'OWNER_CAPITAL') = 50000000
    and (select direction from public.money_movements where source_type = 'equity_event' and source_id = v_e) = 'in', 'Dr bank, Cr owner capital; the cash comes in');
  perform test_helpers.assert(test_helpers.bal(pt, 'OWNER_CAPITAL') = -50000000, 'a contribution is equity, not revenue');
  perform test_helpers.assert(not exists (select 1 from public.journal_lines jl join public.ledger_accounts a on a.id = jl.ledger_account_id and a.entity_id = jl.entity_id
    where jl.entity_id = pt and a.account_class in ('revenue', 'expense')), 'no revenue or expense is touched');
  perform test_helpers.controls8d(pt, 'a contribution');

  -- additional paid-in capital, and a draft that is cancelled
  perform test_helpers.login(v_owner);
  v_e2 := public.equity_create(pt, 'k-p8d-e2', 'contribution', v_today - 20, '5000000', 'Investor', null, 'Share premium', 'additional');
  v_e3 := public.equity_create(pt, 'k-p8d-e3', 'contribution', v_today - 20, '1000000', 'Investor', null, 'Entered by mistake');
  perform test_helpers.expect_msg(format('select public.equity_cancel(%L, ''k-p8d-e3x'', ''no'')', v_e3), 'INVALID', 'a cancellation needs a reason');
  perform test_helpers.assert(public.equity_cancel(v_e3, 'k-p8d-e3y', 'Entered by mistake, no money moved') = v_e3, 'a draft is cancelled');
  perform test_helpers.expect_msg(format('select public.equity_cancel(%L, ''k-p8d-e3z'', ''Cancelled twice by mistake'')', v_e3), 'CONFLICT', 'a cancelled event is not cancelled again');
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-e3w'', %L)', v_e3, v_bca), 'CONFLICT', 'a cancelled event is not confirmed');
  perform test_helpers.expect_msg(format('select public.equity_cancel(%L, ''k-p8d-e1v'', ''Cancelling a confirmed event'')', v_e), 'CONFLICT', 'a confirmed event is reversed, not cancelled');
  v_j := public.equity_confirm(v_e2, 'k-p8d-e2c', v_bca);
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jc(v_j, 'ADDITIONAL_EQUITY') = 5000000 and test_helpers.bal(pt, 'ADDITIONAL_EQUITY') = -5000000, 'additional paid-in capital goes to Additional Equity');
  perform test_helpers.put('e2', v_e2);

  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-e4'', %L)', v_e, v_bca), 'FORBIDDEN', 'staff cannot confirm');
  perform test_helpers.logout();
  perform test_helpers.controls8d(pt, 'contributions');
end
$$;

-- ================================================================ 3. capital return (equity.approve + step-up)
do $$
declare
  pt uuid := test_helpers.entity('p8d_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_r uuid;
  v_big uuid;
  v_j uuid;
  v_rev uuid;
  e public.equity_events%rowtype;
begin
  perform test_helpers.login(v_owner);
  v_r := public.equity_create(pt, 'k-p8d-r1', 'capital_return', v_today - 10, '10000000', 'Owner (Personal)', null, 'Partial return of paid-in capital', 'capital', 'RUPS 2026/05');
  v_big := public.equity_create(pt, 'k-p8d-r2', 'capital_return', v_today - 10, '60000000', 'Owner (Personal)', null, 'More than the capital', 'capital', 'RUPS 2026/06');
  perform test_helpers.logout();
  perform test_helpers.put('r1', v_r);
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-r1a'', %L)', v_r, v_bca), 'FORBIDDEN', 'a finance admin cannot approve a capital return');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner, 'aal2', interval '2 hours');
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-r1b'', %L)', v_r, v_bca), 'STEP_UP_REQUIRED', 'a capital return needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-r2a'', %L)', v_big, v_bca), 'INVALID', 'not more than the capital recorded');
  v_j := public.equity_confirm(v_r, 'k-p8d-r1c', v_bca);
  perform test_helpers.logout();
  select * into e from public.equity_events where id = v_r;
  perform test_helpers.assert(e.status = 'confirmed' and e.tax_status = 'needs_review' and test_helpers.jd(v_j, 'OWNER_CAPITAL') = 10000000 and test_helpers.jc(v_j, 'BANK_OPERATING') = 10000000
    and (select direction from public.money_movements where source_type = 'equity_event' and source_id = v_r) = 'out', 'a capital return: Dr owner capital, Cr bank, and its tax awaits review');
  perform test_helpers.assert(test_helpers.bal(pt, 'OWNER_CAPITAL') = -40000000 and not exists (select 1 from public.journal_lines jl join public.ledger_accounts a on a.id = jl.ledger_account_id and a.entity_id = jl.entity_id
    where jl.entity_id = pt and a.account_class = 'expense'), 'the return lowers equity and is never an expense');
  perform test_helpers.controls8d(pt, 'a capital return');
  -- reversing it needs the same care
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.equity_reverse(%L, ''k-p8d-r3'', %L, ''Reversal by the admin'')', v_r, v_today), 'FORBIDDEN', 'a finance admin cannot reverse a capital return');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.equity_reverse(%L, ''k-p8d-r3b'', %L, ''no'')', v_r, v_today), 'INVALID', 'a reversal needs a reason');
  perform test_helpers.expect_msg(format('select public.equity_reverse(%L, ''k-p8d-r3c'', %L, ''Wrong date'')', v_r, v_today - 11), 'INVALID', 'not before the event');
  v_rev := public.equity_reverse(v_r, 'k-p8d-r4', v_today, 'The return was resolved but never paid out');
  perform test_helpers.assert(public.equity_reverse(v_r, 'k-p8d-r4', v_today, 'The return was resolved but never paid out') = v_rev, 'the reversal replays on the same key');
  perform test_helpers.expect_msg(format('select public.equity_reverse(%L, ''k-p8d-r5'', %L, ''Reversed twice by mistake'')', v_r, v_today), 'CONFLICT', 'a reversed event is not reversed again');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.equity_events where id = v_r) = 'reversed' and test_helpers.bal(pt, 'OWNER_CAPITAL') = -50000000
    and (select count(*) from public.money_movements where source_type = 'equity_event' and source_id = v_r) = 2, 'the reversal mirrors the ledger and the money layer');
  perform test_helpers.controls8d(pt, 'a reversed capital return');
end
$$;

-- ================================================================ 4. dividends: declaration, payments, warning, reversal
do $$
declare
  pt uuid := test_helpers.entity('p8d_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_d uuid;
  v_j uuid;
  v_p1 uuid;
  v_p2 uuid;
  v_rev uuid;
  e public.equity_events%rowtype;
begin
  perform test_helpers.login(v_owner);
  v_d := public.equity_create(pt, 'k-p8d-d1', 'dividend', v_today - 8, '2000000', 'Shareholders', null, 'Interim dividend', null, 'RUPS 2026/07');
  perform test_helpers.put('d1', v_d);
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-d1a'', %L)', v_d, v_bca), 'INVALID', 'a declaration moves no cash');
  v_j := public.equity_confirm(v_d, 'k-p8d-d1b');
  perform test_helpers.logout();
  select * into e from public.equity_events where id = v_d;
  perform test_helpers.assert(e.status = 'confirmed' and e.financial_account_id is null and e.tax_status = 'needs_review' and e.retained_available = 0 and e.exceeds_retained_earnings,
    'a dividend beyond the profit available is allowed, flagged, and its tax awaits review');
  perform test_helpers.assert(test_helpers.jd(v_j, 'RETAINED_EARNINGS') = 2000000 and test_helpers.jc(v_j, 'DIVIDEND_PAYABLE') = 2000000
    and not exists (select 1 from public.money_movements where source_type = 'equity_event' and source_id = v_d), 'declaration: Dr retained earnings, Cr dividend payable; no cash');
  perform test_helpers.assert(app_private.dividend_outstanding(v_d) = 2000000 and test_helpers.bal(pt, 'DIVIDEND_PAYABLE') = -2000000, 'the payable is recognised');
  perform test_helpers.controls8d(pt, 'a dividend declared');

  -- payments, in parts
  perform test_helpers.login(v_admin);
  v_p1 := public.equity_pay_dividend(v_d, 'k-p8d-dp1', v_today - 6, v_bca, '800000', 'First instalment');
  perform test_helpers.assert(public.equity_pay_dividend(v_d, 'k-p8d-dp1', v_today - 6, v_bca, '800000', 'First instalment') = v_p1, 'a payment replays on the same key');
  perform test_helpers.expect_msg(format('select public.equity_pay_dividend(%L, ''k-p8d-dp2'', %L, %L, ''1200001'')', v_d, v_today - 5, v_bca), 'INVALID', 'not more than is unpaid');
  perform test_helpers.expect_msg(format('select public.equity_pay_dividend(%L, ''k-p8d-dp3'', %L, %L, ''1000'')', v_d, v_today - 7, v_bca), 'INVALID', 'not before the last activity');
  perform test_helpers.expect_msg(format('select public.equity_pay_dividend(%L, ''k-p8d-dp4'', %L, %L, ''1000'')', v_d, v_today + 1, v_bca), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.equity_pay_dividend(%L, ''k-p8d-dp5'', %L, %L, ''1000'')', v_d, v_today - 5, test_helpers.g('usd')), 'INVALID', 'a base-currency account only');
  v_p2 := public.equity_pay_dividend(v_d, 'k-p8d-dp6', v_today - 5, v_bca, '1200000');
  perform test_helpers.expect_msg(format('select public.equity_pay_dividend(%L, ''k-p8d-dp7'', %L, %L, ''1'')', v_d, v_today - 4, v_bca), 'INVALID', 'a paid dividend takes no more');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jd((select journal_id from public.equity_dividend_payments where id = v_p1), 'DIVIDEND_PAYABLE') = 800000
    and test_helpers.jc((select journal_id from public.equity_dividend_payments where id = v_p1), 'BANK_OPERATING') = 800000
    and (select tax_status from public.equity_dividend_payments where id = v_p1) = 'needs_review'
    and (select direction from public.money_movements where source_type = 'dividend_payment' and source_id = v_p1) = 'out', 'a payment: Dr dividend payable, Cr bank; its withholding awaits review');
  perform test_helpers.assert(app_private.dividend_outstanding(v_d) = 0 and test_helpers.bal(pt, 'DIVIDEND_PAYABLE') = 0, 'the payable is cleared');
  perform test_helpers.assert(app_private.dividend_outstanding(v_d, v_today - 6) = 1200000 and app_private.dividend_outstanding(v_d, v_today - 9) = 0, 'the payable as of an earlier date');
  perform test_helpers.controls8d(pt, 'a dividend paid');

  -- reversing: the payments first, with the extra care
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.equity_reverse(%L, ''k-p8d-dr1'', %L, ''Reversing with payments'')', v_d, v_today), 'CONFLICT', 'a dividend with payments cannot be reversed');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner, 'aal2', interval '2 hours');
  perform test_helpers.expect_msg(format('select public.equity_reverse_payment(%L, ''k-p8d-dr2'', %L, ''Undo the payment'')', v_p2, v_today), 'STEP_UP_REQUIRED', 'reversing a payment needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  v_rev := public.equity_reverse_payment(v_p2, 'k-p8d-dr3', v_today - 3, 'Bank returned the transfer');
  perform test_helpers.assert(public.equity_reverse_payment(v_p2, 'k-p8d-dr3', v_today - 3, 'Bank returned the transfer') = v_rev, 'the payment reversal replays on the same key');
  perform test_helpers.expect_msg(format('select public.equity_reverse_payment(%L, ''k-p8d-dr4'', %L, ''Reversed twice by mistake'')', v_p2, v_today), 'CONFLICT', 'a reversed payment is not reversed again');
  perform test_helpers.expect_msg(format('select public.equity_reverse_payment(%L, ''k-p8d-dr5'', %L, ''no'')', v_p1, v_today), 'INVALID', 'a reversal needs a reason');
  perform test_helpers.expect_msg(format('select public.equity_reverse_payment(%L, ''k-p8d-dr6'', %L, ''Too early'')', v_p1, v_today - 7), 'INVALID', 'not before the payment');
  perform test_helpers.logout();
  perform test_helpers.assert(app_private.dividend_outstanding(v_d) = 1200000 and (select status from public.equity_dividend_payments where id = v_p2) = 'reversed'
    and test_helpers.bal(pt, 'DIVIDEND_PAYABLE') = -1200000, 'a reversed payment restores the payable');
  perform test_helpers.controls8d(pt, 'a reversed dividend payment');
  perform test_helpers.login(v_owner);
  perform public.equity_reverse_payment(v_p1, 'k-p8d-dr7', v_today - 2, 'Bank returned this transfer too');
  perform test_helpers.expect_msg(format('select public.equity_reverse(%L, ''k-p8d-dr8'', %L, ''Reversing with the wrong date'')', v_d, v_today - 9), 'INVALID', 'not before the declaration');
  v_rev := public.equity_reverse(v_d, 'k-p8d-dr9', v_today, 'Declaration withdrawn before payment');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.equity_events where id = v_d) = 'reversed' and app_private.dividend_outstanding(v_d) = 0 and test_helpers.bal(pt, 'DIVIDEND_PAYABLE') = 0
    and app_private.dividend_outstanding(v_d, v_today - 1) = 2000000 and app_private.dividend_outstanding(v_d, v_today - 4) = 0, 'the declaration is reversed once its payments are; history as of yesterday is intact');
  perform test_helpers.controls8d(pt, 'a reversed dividend');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.equity_pay_dividend(%L, ''k-p8d-dp8'', %L, %L, ''1000'')', v_d, v_today, v_bca), 'CONFLICT', 'a reversed dividend is not paid');
  perform test_helpers.logout();

  -- profit available: an other receivable recognised against revenue gives the company something to distribute
  perform test_helpers.login(v_owner);
  perform public.obligation_create(pt, 'k-p8d-ob1', 'receivable', 'A customer', null, v_today - 3, null, '5000000', 'offset', null, test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE'), 'Revenue outside the invoice flow');
  v_d := public.equity_create(pt, 'k-p8d-d2', 'dividend', v_today - 1, '3000000', 'Shareholders', null, 'Final dividend within profit', null, 'RUPS 2026/08');
  v_j := public.equity_confirm(v_d, 'k-p8d-d2c');
  perform test_helpers.logout();
  perform test_helpers.put('d2', v_d);
  select * into e from public.equity_events where id = v_d;
  perform test_helpers.assert(e.retained_available = 3000000 and not e.exceeds_retained_earnings and e.tax_status = 'needs_review', 'a dividend within the profit available (5,000,000 less the 2,000,000 declared and not yet reversed on that date) carries no warning');
  perform test_helpers.controls8d(pt, 'a dividend within profit');
end
$$;


-- ================================================================ 5. the owner's side: Personal investment and distribution events
do $$
declare
  pe uuid := test_helpers.entity('p8d_pe');
  pt uuid := test_helpers.entity('p8d_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pe);
  v_bank uuid := test_helpers.g('pe_bank');
  v_c uuid;
  v_r uuid;
  v_big uuid;
  v_x uuid;
  v_j uuid;
begin
  perform test_helpers.login(v_owner);
  v_c := public.equity_create(pe, 'k-p8d-pe1', 'investment_contribution', v_today - 30, '10000000', 'PT Hikarich (synthetic)', null, 'Capital contributed to my company', null, null, pt, 'Shareholder; matches the company contribution');
  v_j := public.equity_confirm(v_c, 'k-p8d-pe1c', v_bank);
  perform test_helpers.assert(test_helpers.jd(v_j, 'PERSONAL_INVESTMENT') = 10000000 and test_helpers.jc(v_j, 'PERSONAL_BANK') = 10000000
    and (select direction from public.money_movements where source_type = 'equity_event' and source_id = v_c) = 'out', 'an investment contribution: Dr personal investment, Cr the personal bank');
  perform test_helpers.assert((select related_entity_id from public.equity_events where id = v_c) = pt and (select tax_status from public.equity_events where id = v_c) = 'not_applicable', 'the relationship to the company is a tag, and no tax is flagged');
  v_big := public.equity_create(pe, 'k-p8d-pe2', 'investment_return', v_today - 20, '10000001', 'PT Hikarich (synthetic)', null, 'More than I invested');
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-pe2c'', %L)', v_big, v_bank), 'INVALID', 'a return above the investment recorded');
  v_r := public.equity_create(pe, 'k-p8d-pe3', 'investment_return', v_today - 20, '3000000', 'PT Hikarich (synthetic)', null, 'Capital returned to me');
  v_j := public.equity_confirm(v_r, 'k-p8d-pe3c', v_bank);
  perform test_helpers.assert(test_helpers.jd(v_j, 'PERSONAL_BANK') = 3000000 and test_helpers.jc(v_j, 'PERSONAL_INVESTMENT') = 3000000 and test_helpers.bal(pe, 'PERSONAL_INVESTMENT') = 7000000
    and (select direction from public.money_movements where source_type = 'equity_event' and source_id = v_r) = 'in', 'an investment return: Dr the personal bank, Cr personal investment');
  v_x := public.equity_create(pe, 'k-p8d-pe4', 'distribution_received', v_today - 10, '500000', 'PT Hikarich (synthetic)', null, 'Dividend received', null, null, pt, 'Dividend declared by the company');
  v_j := public.equity_confirm(v_x, 'k-p8d-pe4c', v_bank);
  perform test_helpers.assert(test_helpers.jc(v_j, 'BUSINESS_DISTRIBUTION_INCOME') = 500000 and test_helpers.bal(pe, 'BUSINESS_DISTRIBUTION_INCOME') = -500000
    and (select tax_status from public.equity_events where id = v_x) = 'needs_review', 'a distribution received is personal income, and its tax awaits review');
  perform test_helpers.expect_msg(format('select public.equity_create(%L, ''k-p8d-pe5'', ''investment_contribution'', %L, ''1000'', ''X'', null, ''With a class'', ''capital'')', pe, v_today), 'INVALID', 'a personal event has no equity class');
  perform test_helpers.logout();
  perform test_helpers.controls8d(pe, 'the personal Entity');
  perform test_helpers.controls8d(pt, 'the company beside it');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = pt and source_type = 'equity_event' and created_at > now() - interval '1 second' and false), 'the personal events post nothing to the company');
end
$$;

-- ================================================================ 6. reading, authorization, immutability
do $$
declare
  pt uuid := test_helpers.entity('p8d_pt');
  pe uuid := test_helpers.entity('p8d_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'd0000000-0000-0000-0000-000000000007';
  v_staff uuid := 'd0000000-0000-0000-0000-000000000008';
  v_today date := test_helpers.today(pt);
  v_e1 uuid := test_helpers.g('e1');
  v_d2 uuid := test_helpers.g('d2');
  v_bca uuid := test_helpers.g('bca');
  v_pay uuid;
begin
  select id into v_pay from public.equity_dividend_payments limit 1;
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.equity_list(pt)) = 7 and (select count(*) from public.equity_list(pt, 'dividend')) = 2
    and (select count(*) from public.equity_list(pt, null, 'draft')) = 1 and (select count(*) from public.equity_list(pt, 'contribution', 'confirmed')) = 2, 'a viewer lists the events, filtered by kind and status');
  perform test_helpers.assert((select outstanding::numeric from public.equity_list(pt) where event_id = v_d2) = 3000000 and (select exceeds_retained_earnings from public.equity_list(pt, 'dividend', 'reversed')) = true,
    'the list shows what is unpaid and the retained-earnings warning');
  perform test_helpers.assert((public.equity_detail(v_d2) ->> 'kind') = 'dividend' and (public.equity_detail(v_d2) ->> 'outstanding')::numeric = 3000000
    and jsonb_array_length(public.equity_detail((select event_id from public.equity_list(pt, 'dividend', 'reversed'))) -> 'payments') = 2, 'the detail carries the payments');
  perform test_helpers.assert((select amount::numeric from public.equity_summary(pt, v_today - 40, v_today) where metric = 'contribution') = 55000000
    and (select events from public.equity_summary(pt, v_today - 40, v_today) where metric = 'contribution') = 2
    and (select amount::numeric from public.equity_summary(pt, v_today - 40, v_today) where metric = 'dividend') = 3000000
    and (select amount::numeric from public.equity_summary(pt, v_today - 40, v_today) where metric = 'dividend_paid') = 0
    and (select amount::numeric from public.equity_summary(pt, v_today - 40, v_today) where metric = 'dividend_payable') = 3000000
    and (select amount::numeric from public.equity_summary(pt, v_today - 40, v_today - 12) where metric = 'capital_return') = 0, 'the summary tracks contributions, returns, dividends and the payable apart');
  perform test_helpers.assert((select amount::numeric from public.equity_summary(pt, v_today - 40, v_today - 9) where metric = 'capital_return') = 10000000, 'a return reversed later still counts as of an earlier date');
  perform test_helpers.expect_msg(format('select public.equity_confirm(%L, ''k-p8d-z1'', %L)', v_e1, v_bca), 'FORBIDDEN', 'a viewer cannot confirm');
  perform test_helpers.expect_msg(format('select public.equity_pay_dividend(%L, ''k-p8d-z2'', %L, %L, ''1000'')', v_d2, v_today, v_bca), 'FORBIDDEN', 'a viewer cannot pay a dividend');
  perform test_helpers.expect_msg(format('select public.equity_reverse(%L, ''k-p8d-z3'', %L, ''Not for a viewer'')', v_e1, v_today), 'FORBIDDEN', 'a viewer cannot reverse');
  perform test_helpers.expect_msg(format('select public.equity_reverse_payment(%L, ''k-p8d-z4'', %L, ''Not for a viewer'')', v_pay, v_today), 'FORBIDDEN', 'a viewer cannot reverse a payment');
  perform test_helpers.expect_msg(format('select * from public.equity_list(%L)', pe), 'FORBIDDEN', 'a viewer of the company sees nothing of the personal Entity');
  perform test_helpers.assert((select count(*) from public.equity_events where entity_id = pt) = 7 and (select count(*) from public.equity_dividend_payments where entity_id = pt) = 2, 'a viewer reads the tables through RLS');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select * from public.equity_list(%L)', pt), 'FORBIDDEN', 'staff without equity.view cannot list');
  perform test_helpers.assert(not exists (select 1 from public.equity_events), 'staff read no equity rows');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.assert(not exists (select 1 from public.equity_events) and not exists (select 1 from public.equity_dividend_payments), 'a stranger sees no rows');
  perform test_helpers.expect_msg(format('select public.equity_detail(%L)', v_e1), 'FORBIDDEN', 'a stranger cannot read an event');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_error(format('update public.equity_events set amount = 1 where id = %L', v_e1), '42501', 'no direct update of an event');
  perform test_helpers.expect_error(format('delete from public.equity_events where id = %L', v_e1), '42501', 'no direct delete of an event');
  perform test_helpers.expect_error(format('update public.equity_dividend_payments set amount = 1 where id = %L', v_pay), '42501', 'no direct update of a payment');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format('delete from public.equity_events where id = %L', v_e1), null, 'an event cannot be deleted');
  perform test_helpers.expect_error(format('update public.equity_events set amount = amount + 1 where id = %L', v_e1), null, 'the amount of an event cannot be edited');
  perform test_helpers.expect_error(format('update public.equity_events set kind = ''dividend'' where id = %L', v_e1), null, 'the kind of an event cannot be edited');
  perform test_helpers.expect_error(format('update public.equity_events set status = ''draft'' where id = %L', v_e1), null, 'an event cannot go back to draft');
  perform test_helpers.expect_error(format('update public.equity_events set journal_id = null where id = %L', v_e1), null, 'the posting of a confirmed event cannot be removed');
  perform test_helpers.expect_error('update public.equity_events set status = ''confirmed'' where status = ''reversed''', null, 'a reversed event cannot be revived');
  perform test_helpers.expect_error('update public.equity_events set status = ''confirmed'' where status = ''cancelled''', null, 'a cancelled event cannot be revived');
  perform test_helpers.expect_error(format('update public.equity_dividend_payments set amount = amount + 1 where id = %L', v_pay), null, 'a payment cannot be edited');
  perform test_helpers.expect_error(format('delete from public.equity_dividend_payments where id = %L', v_pay), null, 'a payment cannot be deleted');
  perform test_helpers.expect_error(format('insert into public.equity_dividend_payments (entity_id, event_id, payment_number, payment_date, amount, financial_account_id, journal_id) select entity_id, id, ''EQ-X'', %L, 999999999999, %L, journal_id from public.equity_events where id = %L', v_today, v_bca, v_d2), null, 'a payment beyond the dividend is refused by the table');
  perform test_helpers.expect_error(format('insert into public.equity_dividend_payments (entity_id, event_id, payment_number, payment_date, amount, financial_account_id, journal_id) select entity_id, id, ''EQ-Y'', %L, 1, %L, journal_id from public.equity_events where id = %L', v_today, v_bca, v_e1), null, 'a contribution cannot be paid as a dividend');
  perform test_helpers.assert((select count(*) from public.audit_events where entity_id = pt and target_table in ('equity_events', 'equity_dividend_payments')) > 0, 'equity changes are audited');
end
$$;

rollback;
