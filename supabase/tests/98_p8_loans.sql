-- P8 gate, part 3 (Step 07 §12, Step 08 §12, Step 16 §17): the Loan Register reconciles to the General Ledger.
-- Covers the schedule arithmetic (annuity, flat, interest-only, manual), draft and activation, proceeds for both
-- directions, repayment allocation across schedule items (arrears first, prepayment, interest and fee), the principal
-- never going below zero, closing, write-off, reversal, restructuring with preserved history, cancellation, the asset
-- link, opening loans, Personal loans, the control and authorization. All data is synthetic; dates are relative to the
-- Entity's today. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p8c (k text primary key, v uuid not null);
grant all on test_helpers.p8c to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p8c values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p8c where k = p_k $f$;
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


-- The invariants of the loan layer: money equals the ledger; every loan account's sub-ledger equals its ledger balance.
create function test_helpers.controls8c(p_entity uuid, p_label text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $f$
declare
  v_today date := app_private.entity_today(p_entity);
  a record;
begin
  if exists (select 1 from app_private.money_control_rows(p_entity) r where r.ledger_balance <> r.movement_base_balance) then
    raise exception 'TEST FAIL [%]: money movements differ from the ledger', p_label;
  end if;
  for a in select distinct l.principal_account_id as id, l.direction from public.loans l where l.entity_id = p_entity loop
    if a.direction = 'borrowed' and app_private.loans_total(p_entity, 'borrowed', v_today, a.id)
       <> (select coalesce(sum(jl.credit - jl.debit), 0) from public.journal_lines jl
           join public.journal_entries j on j.id = jl.journal_id and j.entity_id = jl.entity_id and j.status = 'posted'
           where jl.entity_id = p_entity and jl.ledger_account_id = a.id) then
      raise exception 'TEST FAIL [%]: the loans on a liability account differ from the ledger', p_label;
    end if;
  end loop;
  if app_private.loans_total(p_entity, 'lent', v_today) + app_private.obligations_total(p_entity, 'receivable', v_today)
     <> test_helpers.bal(p_entity, 'OTHER_RECEIVABLE') then
    raise exception 'TEST FAIL [%]: loans given and other receivables differ from the ledger %', p_label, test_helpers.bal(p_entity, 'OTHER_RECEIVABLE');
  end if;
  if exists (select 1 from public.loans l where l.entity_id = p_entity and l.status = 'closed' and app_private.loan_outstanding(l.id) <> 0) then
    raise exception 'TEST FAIL [%]: a closed loan still has principal outstanding', p_label;
  end if;
  if exists (select 1 from public.loans l where l.entity_id = p_entity and l.status = 'active' and app_private.loan_outstanding(l.id) = 0) then
    raise exception 'TEST FAIL [%]: an active loan has nothing outstanding', p_label;
  end if;
  -- the schedule in force adds up to what it schedules; every allocation belongs to its payment's amounts
  if exists (select 1 from public.loan_schedule_versions v
             where v.entity_id = p_entity and v.status = 'active'
               and (select coalesce(sum(i.principal_due), 0) from public.loan_schedule_items i where i.version_id = v.id) <> v.principal_basis) then
    raise exception 'TEST FAIL [%]: a schedule does not add up to its principal', p_label;
  end if;
  if exists (select 1 from public.loan_payments p
             where p.entity_id = p_entity
               and ((select coalesce(sum(x.principal), 0) from public.loan_payment_allocations x where x.payment_id = p.id) <> p.principal
                or (select coalesce(sum(x.interest), 0) from public.loan_payment_allocations x where x.payment_id = p.id) <> p.interest
                or (select coalesce(sum(x.fee), 0) from public.loan_payment_allocations x where x.payment_id = p.id) <> p.fee)) then
    raise exception 'TEST FAIL [%]: the allocations of a payment differ from the payment', p_label;
  end if;
  -- no item is paid beyond what it schedules
  if exists (select 1 from public.loans l cross join lateral app_private.loan_items(l.id) i
             where l.entity_id = p_entity and (i.paid_principal > i.principal_due or i.paid_interest > i.interest_due or i.paid_fee > i.fee_due)) then
    raise exception 'TEST FAIL [%]: a schedule item is paid beyond its amounts', p_label;
  end if;
end
$f$;
grant execute on function test_helpers.controls8c(uuid, text) to public;

-- ================================================================ 1. the arithmetic of a schedule
do $$
declare
  n integer;
  v_sum numeric;
  r record;
begin
  -- annuity: 12,000,000 at 12% a year over 12 months
  select count(*), sum(principal) into n, v_sum from app_private.loan_plan('annuity', 12000000, 12, 12, 1, date '2027-01-31', 2);
  perform test_helpers.assert(n = 12 and v_sum = 12000000, 'an annuity schedules the whole principal over its installments');
  select * into r from app_private.loan_plan('annuity', 12000000, 12, 12, 1, date '2027-01-31', 2) where seq = 1;
  perform test_helpers.assert(r.interest = 120000 and r.principal + r.interest between 1066185 and 1066186, 'the first annuity installment: 1% interest, payment about 1,066,185.95');
  perform test_helpers.assert((select max(principal + interest) - min(principal + interest) from app_private.loan_plan('annuity', 12000000, 12, 12, 1, date '2027-01-31', 2) where seq < 12) < 0.02,
    'annuity payments are equal apart from the rounding');
  perform test_helpers.assert((select bool_and(p2.principal > p1.principal) from app_private.loan_plan('annuity', 12000000, 12, 12, 1, date '2027-01-31', 2) p1
    join app_private.loan_plan('annuity', 12000000, 12, 12, 1, date '2027-01-31', 2) p2 on p2.seq = p1.seq + 1), 'the principal part of an annuity grows');
  -- month-end due dates are stepped from the first date, not from the previous one
  perform test_helpers.assert((select array_agg(due_date order by seq) from app_private.loan_plan('annuity', 1200000, 12, 4, 1, date '2027-01-31', 2))
    = array[date '2027-01-31', date '2027-02-28', date '2027-03-31', date '2027-04-30'], 'due dates keep to month-ends');
  -- a zero rate: equal principal, no interest
  perform test_helpers.assert((select sum(interest) from app_private.loan_plan('annuity', 1200000, 0, 12, 1, date '2027-01-31', 2)) = 0
    and (select sum(principal) from app_private.loan_plan('annuity', 1200000, 0, 12, 1, date '2027-01-31', 2)) = 1200000, 'an interest-free loan schedules principal only');
  -- flat: interest on the original principal, principal in equal parts, the last absorbs the remainder
  perform test_helpers.assert((select min(interest) = 120000 and max(interest) = 120000 and sum(principal) = 12000000 and min(principal) = 1000000
    from app_private.loan_plan('flat', 12000000, 12, 12, 1, date '2027-01-31', 2)), 'flat: 120,000 interest and 1,000,000 principal every month');
  select sum(principal), max(principal) into v_sum, n from app_private.loan_plan('flat', 1000000, 10, 3, 1, date '2027-01-31', 2);
  perform test_helpers.assert(v_sum = 1000000, 'the last flat installment absorbs the rounding remainder');
  -- interest only: interest every period, the principal at the end
  perform test_helpers.assert((select sum(principal) = 12000000 and max(principal) = 12000000 and count(*) filter (where principal = 0) = 5 and sum(interest) = 6 * 120000
    from app_private.loan_plan('interest_only', 12000000, 12, 6, 1, date '2027-01-31', 2)), 'interest-only: interest each month, all principal at the end');
  -- quarterly steps
  perform test_helpers.assert((select array_agg(due_date order by seq) from app_private.loan_plan('flat', 4000000, 8, 4, 3, date '2027-03-15', 2))
    = array[date '2027-03-15', date '2027-06-15', date '2027-09-15', date '2027-12-15'], 'a quarterly step');
  perform test_helpers.assert((select count(*) from app_private.loan_plan('annuity', 500000, 9, 1, 1, date '2027-03-15', 2)) = 1
    and (select principal from app_private.loan_plan('annuity', 500000, 9, 1, 1, date '2027-03-15', 2)) = 500000, 'a single installment repays the principal');
  perform test_helpers.expect_msg('select * from app_private.loan_plan(''annuity'', 0, 12, 12, 1, date ''2027-01-31'', 2)', 'INVALID', 'a principal is needed');
  perform test_helpers.expect_msg('select * from app_private.loan_plan(''annuity'', 100, 12, 0, 1, date ''2027-01-31'', 2)', 'INVALID', 'installments are needed');
  perform test_helpers.expect_msg('select * from app_private.loan_plan(''annuity'', 100, 12, 12, 2, date ''2027-01-31'', 2)', 'INVALID', 'a step of 1, 3, 6 or 12 months');
  perform test_helpers.expect_msg('select * from app_private.loan_plan(''balloon'', 100, 12, 12, 1, date ''2027-01-31'', 2)', 'INVALID', 'a known method');
  perform test_helpers.expect_msg('select app_private.rate_arg(''100.5'', ''the rate'')', 'INVALID', 'a rate above 100');
  perform test_helpers.expect_msg('select app_private.rate_arg(''1.1234567'', ''the rate'')', 'INVALID', 'a rate with 7 decimals');
  perform test_helpers.expect_msg('select app_private.rate_arg(''-1'', ''the rate'')', 'INVALID', 'a negative rate');
  perform test_helpers.assert(app_private.rate_arg('12.5', 'the rate') = 12.5, 'a plain rate');
end
$$;


-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
  v_op uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p8c_pt', 'P8C PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p8c_pe', 'P8C PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p8c_op', 'P8C OPENING PT (synthetic)') returning id into v_op;
  perform app_private.provision_default_coa(v_op);
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000002', 'admin');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000007', 'nobody');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000008', 'staff');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_op, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000002', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000008', 'finance_staff');
end
$$;

-- ================================================================ 2. setup and drafts
do $$
declare
  pt uuid := test_helpers.entity('p8c_pt');
  pe uuid := test_helpers.entity('p8c_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_today date := test_helpers.today(pt);
  v_ag date := test_helpers.today(pt) - 95;
  v_first date := test_helpers.today(pt) - 60;
  v_id uuid;
  l public.loans%rowtype;
  v public.loan_schedule_versions%rowtype;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.put('bca', public.create_financial_account(pt, 'key-p8c-fa-01', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-SECRET-1', 'PT P8C'));
  perform test_helpers.put('cash', public.create_financial_account(pt, 'key-p8c-fa-02', 'cash', 'Petty Cash', 'IDR', test_helpers.acct(pt, 'CASH')));
  perform test_helpers.put('usd', public.create_financial_account(pt, 'key-p8c-fa-03', 'bank', 'USD Account', 'USD'));
  perform test_helpers.put('pe_bank', public.create_financial_account(pe, 'key-p8c-fa-04', 'bank', 'Personal BCA', 'IDR', test_helpers.acct(pe, 'PERSONAL_BANK')));
  perform test_helpers.put('lender', public.create_contact(pt, 'key-p8c-ct-01', 'vendor', 'Bank Lender'));

  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0a'', ''swap'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L)', pt, v_ag, v_first), 'INVALID', 'a loan is borrowed or lent');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0b'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''0'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L)', pt, v_ag, v_first), 'INVALID', 'a principal above zero');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0c'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, null, ''12'', ''annuity'', 12, 1, %L)', pt, v_ag, v_first), 'INVALID', 'a company loan is short or long term');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0d'', ''lent'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L)', pt, v_ag, v_first), 'INVALID', 'a loan given has no term class');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0e'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''balloon'', 12, 1, %L)', pt, v_ag, v_first), 'INVALID', 'a known method');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0f'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''annuity'', null, 1, %L)', pt, v_ag, v_first), 'INVALID', 'a generated schedule needs its installments');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0g'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L)', pt, v_ag, v_ag - 1), 'INVALID', 'the first installment is not before the agreement');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0h'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L)', pt, v_today + 1, v_today + 30), 'INVALID', 'an agreement in the future');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0i'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''120'', ''annuity'', 12, 1, %L)', pt, v_ag, v_first), 'INVALID', 'a rate above 100');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0j'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''0'', ''manual'', null, null, null, %L::jsonb)', pt, v_ag,
    '[{"due_date":"2099-01-01","principal":"5000000"},{"due_date":"2099-02-01","principal":"5000000"}]'), 'INVALID', 'a manual schedule adds up to the principal');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0k'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''10000000'', %L, ''short'', ''0'', ''manual'', null, null, null, %L::jsonb)', pt, v_ag,
    '[{"due_date":"2099-02-01","principal":"5000000"},{"due_date":"2099-01-01","principal":"5000000"}]'), 'INVALID', 'manual installments are dated in order');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0l'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''10000000'', %L, ''short'', ''0'', ''manual'', null, null, null, null)', pt, v_ag), 'INVALID', 'a manual schedule lists its installments');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0m'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L, null, %L)', pt, v_ag, v_first, gen_random_uuid()), 'INVALID', 'an unknown asset');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0n'', ''borrowed'', ''Bank X'', %L, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L, null, null, %L)', pt, gen_random_uuid(), v_ag, v_first, pe), 'INVALID', 'an unknown contact');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0o'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L, null, null, %L)', pt, v_ag, v_first, pe), 'INVALID', 'a related Entity needs its basis');
  perform test_helpers.assert(not exists (select 1 from public.loans where entity_id = pt), 'refused loans change nothing');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c0p'', ''borrowed'', ''Bank X'', null, ''Working capital'', ''12000000'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L)', pt, v_ag, v_first), 'FORBIDDEN', 'a viewer cannot record a loan');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  v_id := public.loan_create(pt, 'k-p8c-c1', 'borrowed', 'Bank Lender', test_helpers.g('lender'), 'Working capital loan', '12000000', v_ag, 'short', '12', 'annuity', 12, 1, v_first);
  perform test_helpers.put('l1', v_id);
  perform test_helpers.assert(public.loan_create(pt, 'k-p8c-c1', 'borrowed', 'Bank Lender', test_helpers.g('lender'), 'Working capital loan', '12000000', v_ag, 'short', '12', 'annuity', 12, 1, v_first) = v_id, 'creation replays on the same key');
  perform test_helpers.expect_msg(format('select public.loan_create(%L, ''k-p8c-c1'', ''borrowed'', ''Bank Lender'', null, ''Working capital loan'', ''13000000'', %L, ''short'', ''12'', ''annuity'', 12, 1, %L)', pt, v_ag, v_first), 'INVALID', 'the same key with other facts is refused');
  perform test_helpers.logout();
  select * into l from public.loans where id = v_id;
  perform test_helpers.assert(l.status = 'draft' and l.direction = 'borrowed' and l.principal = 12000000 and l.funded_principal = 0 and l.loan_number like 'LN-%' and l.effective_date is null
    and l.principal_account_id = test_helpers.acct(pt, 'LOAN_SHORT_TERM') and l.term_class = 'short' and l.created_by = v_owner and l.proceeds_journal_id is null, 'a draft loan');
  select * into v from public.loan_schedule_versions where loan_id = v_id;
  perform test_helpers.assert(v.version_no = 1 and v.status = 'draft' and v.method = 'annuity' and v.rate = 12 and v.installments = 12 and v.principal_basis = 12000000 and v.effective_from is null
    and (select count(*) from public.loan_schedule_items where version_id = v.id) = 12
    and (select sum(principal_due) from public.loan_schedule_items where version_id = v.id) = 12000000
    and v.maturity_date = (select max(due_date) from public.loan_schedule_items where version_id = v.id), 'version 1 is a draft schedule that adds up');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = pt) and app_private.loan_outstanding(v_id) = 0, 'a draft posts nothing and owes nothing');
  perform test_helpers.controls8c(pt, 'a draft loan');
end
$$;

-- ================================================================ 3. activation: the proceeds
do $$
declare
  pt uuid := test_helpers.entity('p8c_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'd0000000-0000-0000-0000-000000000008';
  v_today date := test_helpers.today(pt);
  v_act date := test_helpers.today(pt) - 90;
  v_l uuid := test_helpers.g('l1');
  v_bca uuid := test_helpers.g('bca');
  v_j uuid;
  l public.loans%rowtype;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.loan_activate(%L, ''k-p8c-a0a'', %L, %L)', v_l, v_act - 6, v_bca), 'INVALID', 'not before the agreement');
  perform test_helpers.expect_msg(format('select public.loan_activate(%L, ''k-p8c-a0b'', %L, %L)', v_l, v_today + 1, v_bca), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.loan_activate(%L, ''k-p8c-a0c'', %L, %L)', v_l, v_today - 50, v_bca), 'INVALID', 'the first installment falls before the proceeds');
  perform test_helpers.expect_msg(format('select public.loan_activate(%L, ''k-p8c-a0d'', %L, %L)', v_l, v_act, test_helpers.g('usd')), 'INVALID', 'a base-currency account only');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.loan_activate(%L, ''k-p8c-a0e'', %L, %L)', v_l, v_act, v_bca), 'FORBIDDEN', 'a viewer cannot activate');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.loan_activate(%L, ''k-p8c-a0f'', %L, %L)', v_l, v_act, v_bca), 'FORBIDDEN', 'staff cannot activate');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.loans where id = v_l) = 'draft' and not exists (select 1 from public.journal_entries where entity_id = pt), 'refused activations change nothing');

  perform test_helpers.login(v_owner);
  v_j := public.loan_activate(v_l, 'k-p8c-a1', v_act, v_bca);
  perform test_helpers.assert(public.loan_activate(v_l, 'k-p8c-a1', v_act, v_bca) = v_j, 'activation replays on the same key');
  perform test_helpers.expect_msg(format('select public.loan_activate(%L, ''k-p8c-a2'', %L, %L)', v_l, v_act, v_bca), 'CONFLICT', 'an active loan is not activated again');
  perform test_helpers.expect_msg(format('select public.loan_cancel(%L, ''k-p8c-a3'', ''Cancelling an active loan'')', v_l), 'CONFLICT', 'an active loan cannot be cancelled');
  perform test_helpers.logout();
  select * into l from public.loans where id = v_l;
  perform test_helpers.assert(l.status = 'active' and l.effective_date = v_act and l.funded_principal = 12000000 and l.financial_account_id = v_bca and l.proceeds_journal_id = v_j
    and app_private.loan_outstanding(v_l) = 12000000, 'the loan is active with its proceeds');
  perform test_helpers.assert(test_helpers.jd(v_j, 'BANK_OPERATING') = 12000000 and test_helpers.jc(v_j, 'LOAN_SHORT_TERM') = 12000000, 'Dr bank, Cr short-term loan');
  perform test_helpers.assert((select direction from public.money_movements where source_type = 'loan' and source_id = v_l) = 'in', 'the proceeds come into the bank');
  perform test_helpers.assert(test_helpers.bal(pt, 'LOAN_SHORT_TERM') = -12000000, 'proceeds are a liability, not revenue');
  perform test_helpers.assert((select status from public.loan_schedule_versions where loan_id = v_l) = 'active' and (select effective_from from public.loan_schedule_versions where loan_id = v_l) = v_act, 'the schedule takes effect with the proceeds');
  perform test_helpers.controls8c(pt, 'activation');
  -- nothing was booked to revenue or expense
  perform test_helpers.assert(not exists (select 1 from public.journal_lines jl join public.ledger_accounts a on a.id = jl.ledger_account_id and a.entity_id = jl.entity_id
    where jl.entity_id = pt and a.account_class in ('revenue', 'expense')), 'loan proceeds touch no revenue or expense account');
end
$$;


-- ================================================================ 4. repayments: allocation to the schedule
do $$
declare
  pt uuid := test_helpers.entity('p8c_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'd0000000-0000-0000-0000-000000000008';
  v_today date := test_helpers.today(pt);
  v_l uuid := test_helpers.g('l1');
  v_bca uuid := test_helpers.g('bca');
  v_draft uuid;
  i1 record;
  i2 record;
  i3 record;
  v_p1 uuid;
  v_p2 uuid;
  p public.loan_payments%rowtype;
begin
  select * into i1 from app_private.loan_items(v_l) where seq = 1;
  select * into i2 from app_private.loan_items(v_l) where seq = 2;
  select * into i3 from app_private.loan_items(v_l) where seq = 3;
  perform test_helpers.assert(i1.overdue and i1.state = 'due' and i2.overdue and i2.state = 'due', 'the first two installments are due and overdue');
  perform test_helpers.assert(i1.principal_due + i1.interest_due between 1066185 and 1066186 and i1.interest_due = 120000, 'the first installment of the annuity');

  -- a loan that is not active cannot be repaid
  perform test_helpers.login(v_owner);
  v_draft := public.loan_create(pt, 'k-p8c-d1', 'borrowed', 'Draft Lender', null, 'A draft only', '3000000', v_today - 5, 'long', '10', 'flat', 3, 1, v_today + 30);
  perform test_helpers.put('draft', v_draft);
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0z'', %L, %L, ''1000'')', v_draft, v_today, v_bca), 'CONFLICT', 'a draft loan cannot be repaid');
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0a'', %L, %L, ''12000001'')', v_l, i1.due_date, v_bca), 'INVALID', 'more than the outstanding principal');
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0b'', %L, %L, ''900000'', ''120000'')', v_l, i1.due_date, v_bca), 'INVALID', 'interest needs a note');
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0c'', %L, %L, ''0'', ''0'', ''0'')', v_l, i1.due_date, v_bca), 'INVALID', 'a payment needs an amount');
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0d'', %L, %L, ''900000'')', v_l, v_today + 1, v_bca), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0e'', %L, %L, ''900000'')', v_l, v_today - 91, v_bca), 'INVALID', 'not before the proceeds');
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0f'', %L, %L, ''900000'')', v_l, i1.due_date, test_helpers.g('usd')), 'INVALID', 'a base-currency account only');
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0g'', %L, %L, ''900.005'')', v_l, i1.due_date, v_bca), 'INVALID', 'too many decimals');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0h'', %L, %L, ''900000'')', v_l, i1.due_date, v_bca), 'FORBIDDEN', 'a viewer cannot repay');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r0i'', %L, %L, ''900000'')', v_l, i1.due_date, v_bca), 'FORBIDDEN', 'staff cannot repay');
  perform test_helpers.logout();
  perform test_helpers.assert(not exists (select 1 from public.loan_payments where entity_id = pt), 'refused payments change nothing');

  -- installment 1, paid exactly
  perform test_helpers.login(v_owner);
  v_p1 := public.loan_repay(v_l, 'k-p8c-r1', i1.due_date, v_bca, i1.principal_due::text, i1.interest_due::text, '0', 'Installment 1');
  perform test_helpers.assert(public.loan_repay(v_l, 'k-p8c-r1', i1.due_date, v_bca, i1.principal_due::text, i1.interest_due::text, '0', 'Installment 1') = v_p1, 'a repayment replays on the same key');
  perform test_helpers.logout();
  select * into p from public.loan_payments where id = v_p1;
  perform test_helpers.assert(p.kind = 'repayment' and p.status = 'active' and p.principal = i1.principal_due and p.interest = 120000 and p.fee = 0 and p.payment_number like 'LPY-%'
    and p.tax_status = 'needs_review' and p.schedule_version_id = (select id from public.loan_schedule_versions where loan_id = v_l and status = 'active'), 'the payment splits principal and interest and awaits tax review');
  perform test_helpers.assert(test_helpers.jd(p.journal_id, 'LOAN_SHORT_TERM') = i1.principal_due and test_helpers.jd(p.journal_id, 'INTEREST_EXPENSE') = 120000
    and test_helpers.jc(p.journal_id, 'BANK_OPERATING') = i1.principal_due + 120000, 'Dr loan (principal), Dr interest expense; Cr bank');
  perform test_helpers.assert((select direction from public.money_movements where source_type = 'loan_payment' and source_id = v_p1) = 'out'
    and (select amount from public.money_movements where source_type = 'loan_payment' and source_id = v_p1) = i1.principal_due + 120000, 'the whole payment leaves the bank');
  perform test_helpers.assert((select count(*) from public.loan_payment_allocations where payment_id = v_p1) = 1
    and (select item_id from public.loan_payment_allocations where payment_id = v_p1) = i1.item_id, 'it settles installment 1');
  perform test_helpers.assert((select state from app_private.loan_items(v_l) where seq = 1) = 'paid' and (select overdue from app_private.loan_items(v_l) where seq = 1) = false, 'installment 1 is paid');
  perform test_helpers.assert(app_private.loan_outstanding(v_l) = 12000000 - i1.principal_due and (select status from public.loans where id = v_l) = 'active', 'the principal falls by the principal part only');
  perform test_helpers.assert(test_helpers.bal(pt, 'INTEREST_EXPENSE') = 120000 and test_helpers.bal(pt, 'LOAN_SHORT_TERM') = -(12000000 - i1.principal_due), 'interest is expense, principal is not');
  perform test_helpers.controls8c(pt, 'installment 1');

  -- installment 2: interest a little short, plus a prepayment of principal and an unscheduled fee
  perform test_helpers.login(v_owner);
  v_p2 := public.loan_repay(v_l, 'k-p8c-r2', i2.due_date, v_bca, (i2.principal_due + 500000)::text, (i2.interest_due - 1000)::text, '25000', 'Installment 2, part of the interest next time, prepayment, bank fee');
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-r2x'', %L, %L, ''1000'', ''0'', ''0'', ''back-dated'')', v_l, i1.due_date, v_bca), 'INVALID', 'not before the last activity on the loan');
  perform test_helpers.logout();
  select * into p from public.loan_payments where id = v_p2;
  perform test_helpers.assert(test_helpers.jd(p.journal_id, 'LOAN_SHORT_TERM') = i2.principal_due + 500000 and test_helpers.jd(p.journal_id, 'INTEREST_EXPENSE') = i2.interest_due - 1000
    and test_helpers.jd(p.journal_id, 'OTHER_NONOPERATING_EXPENSE') = 25000
    and test_helpers.jc(p.journal_id, 'BANK_OPERATING') = i2.principal_due + 500000 + i2.interest_due - 1000 + 25000, 'Dr loan, Dr interest, Dr other expense (fee); Cr bank');
  select * into i2 from app_private.loan_items(v_l) where seq = 2;
  select * into i3 from app_private.loan_items(v_l) where seq = 3;
  perform test_helpers.assert(i2.paid_principal = i2.principal_due and i2.paid_interest = i2.interest_due - 1000 and i2.state = 'partially_paid' and i2.overdue, 'installment 2 is partly paid and still overdue');
  perform test_helpers.assert(i3.paid_principal = 500000 and i3.state = 'partially_paid', 'the prepayment goes to the next installment in line');
  perform test_helpers.assert((select item_id from public.loan_payment_allocations where payment_id = v_p2 and fee = 25000) is null and (select count(*) from public.loan_payment_allocations where payment_id = v_p2) = 3,
    'the unscheduled fee is kept against no installment');
  perform test_helpers.assert(app_private.loan_outstanding(v_l) = 12000000 - i1.principal_due - i2.principal_due - 500000, 'the outstanding principal after the prepayment');
  perform test_helpers.controls8c(pt, 'installment 2 and a prepayment');
  perform test_helpers.put('p1', v_p1);
  perform test_helpers.put('p2', v_p2);
end
$$;

-- ================================================================ 5. paying off, closing, reopening by reversal
do $$
declare
  pt uuid := test_helpers.entity('p8c_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_today date := test_helpers.today(pt);
  v_l uuid := test_helpers.g('l1');
  v_bca uuid := test_helpers.g('bca');
  v_out numeric := app_private.loan_outstanding(test_helpers.g('l1'));
  v_pay uuid;
  v_rev uuid;
begin
  perform test_helpers.login(v_admin);
  v_pay := public.loan_repay(v_l, 'k-p8c-po1', v_today, v_bca, v_out::text);
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.loans where id = v_l) = 'closed' and (select closed_date from public.loans where id = v_l) = v_today and app_private.loan_outstanding(v_l) = 0,
    'repaying the last principal closes the loan');
  perform test_helpers.assert(test_helpers.bal(pt, 'LOAN_SHORT_TERM') = 0, 'the liability is gone');
  perform test_helpers.controls8c(pt, 'a closed loan');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-po2'', %L, %L, ''1000'')', v_l, v_today, v_bca), 'CONFLICT', 'a closed loan is not repaid');
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-po3'', %L, ''9'', ''flat'', 6, 1, %L, null, ''Restructuring a closed loan'')', v_l, v_today, v_today + 30), 'CONFLICT', 'a closed loan is not restructured');
  perform test_helpers.expect_msg(format('select public.loan_reverse_payment(%L, ''k-p8c-po4'', %L, ''no'')', v_pay, v_today), 'INVALID', 'a reversal needs a reason');
  perform test_helpers.expect_msg(format('select public.loan_reverse_payment(%L, ''k-p8c-po5'', %L, ''Wrong account'')', v_pay, v_today - 200), 'INVALID', 'not before the payment');
  v_rev := public.loan_reverse_payment(v_pay, 'k-p8c-po6', v_today, 'Paid from the wrong account');
  perform test_helpers.assert(public.loan_reverse_payment(v_pay, 'k-p8c-po6', v_today, 'Paid from the wrong account') = v_rev, 'the reversal replays on the same key');
  perform test_helpers.expect_msg(format('select public.loan_reverse_payment(%L, ''k-p8c-po7'', %L, ''Reversed again by mistake'')', v_pay, v_today), 'CONFLICT', 'a reversed payment is not reversed again');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.loans where id = v_l) = 'active' and (select closed_date from public.loans where id = v_l) is null and app_private.loan_outstanding(v_l) = v_out
    and (select status from public.loan_payments where id = v_pay) = 'reversed', 'reversing the last payment re-opens the loan');
  perform test_helpers.assert(test_helpers.bal(pt, 'LOAN_SHORT_TERM') = -v_out and (select count(*) from public.money_movements where source_type = 'loan_payment' and source_id = v_pay) = 2, 'the ledger and the money layer are mirrored');
  perform test_helpers.assert(app_private.loan_outstanding(v_l, v_today - 1) = v_out and app_private.loan_outstanding(v_l, v_today) = v_out, 'as of yesterday and today the principal is as before');
  perform test_helpers.controls8c(pt, 'a re-opened loan');
end
$$;

-- ================================================================ 6. write-off (forgiven debt)
do $$
declare
  pt uuid := test_helpers.entity('p8c_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_l uuid := test_helpers.g('l1');
  v_out numeric := app_private.loan_outstanding(test_helpers.g('l1'));
  v_w uuid;
  v_rev uuid;
  p public.loan_payments%rowtype;
begin
  perform test_helpers.login(v_owner, 'aal2', interval '2 hours');
  perform test_helpers.expect_msg(format('select public.loan_write_off(%L, ''k-p8c-w0'', %L, ''1000000'', ''The lender forgave part of the debt'')', v_l, v_today), 'STEP_UP_REQUIRED', 'a write-off needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.loan_write_off(%L, ''k-p8c-w0b'', %L, ''1000000'', ''no'')', v_l, v_today), 'INVALID', 'a write-off needs a reason');
  perform test_helpers.expect_msg(format('select public.loan_write_off(%L, ''k-p8c-w0c'', %L, %L, ''The lender forgave part of the debt'')', v_l, v_today, (v_out + 1)::text), 'INVALID', 'not more than the outstanding principal');
  v_w := public.loan_write_off(v_l, 'k-p8c-w1', v_today, '1000000', 'The lender forgave part of the debt');
  perform test_helpers.assert(public.loan_write_off(v_l, 'k-p8c-w1', v_today, '1000000', 'The lender forgave part of the debt') = v_w, 'the write-off replays on the same key');
  perform test_helpers.logout();
  select * into p from public.loan_payments where id = v_w;
  perform test_helpers.assert(p.kind = 'write_off' and p.principal = 1000000 and p.financial_account_id is null and p.tax_status = 'needs_review'
    and test_helpers.jd(p.journal_id, 'LOAN_SHORT_TERM') = 1000000 and test_helpers.jc(p.journal_id, 'OTHER_NONOPERATING_INCOME') = 1000000, 'Dr loan, Cr other income; no cash');
  perform test_helpers.assert(not exists (select 1 from public.money_movements where source_type = 'loan_payment' and source_id = v_w) and app_private.loan_outstanding(v_l) = v_out - 1000000, 'a write-off moves no cash');
  perform test_helpers.controls8c(pt, 'a write-off');
  perform test_helpers.login(v_owner, 'aal2', interval '2 hours');
  perform test_helpers.expect_msg(format('select public.loan_reverse_payment(%L, ''k-p8c-w2'', %L, ''Undo the write-off'')', v_w, v_today), 'STEP_UP_REQUIRED', 'reversing a write-off needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  v_rev := public.loan_reverse_payment(v_w, 'k-p8c-w3', v_today, 'The lender did not forgive it after all');
  perform test_helpers.logout();
  perform test_helpers.assert(app_private.loan_outstanding(v_l) = v_out and (select status from public.loan_payments where id = v_w) = 'reversed', 'the reversed write-off restores the principal');
  perform test_helpers.controls8c(pt, 'a reversed write-off');
end
$$;

-- ================================================================ 7. restructuring: a new version, the history kept
do $$
declare
  pt uuid := test_helpers.entity('p8c_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_l uuid := test_helpers.g('l1');
  v_bca uuid := test_helpers.g('bca');
  v_out numeric := app_private.loan_outstanding(test_helpers.g('l1'));
  v_v1 uuid;
  v_v2 uuid;
  v_p3 uuid;
  i record;
begin
  select id into v_v1 from public.loan_schedule_versions where loan_id = v_l and status = 'active';
  perform test_helpers.login(v_owner, 'aal2', interval '2 hours');
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-s0'', %L, ''9'', ''flat'', 6, 1, %L, null, ''Lender agreed a longer term'')', v_l, v_today, v_today + 30), 'STEP_UP_REQUIRED', 'a restructuring needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-s0b'', %L, ''9'', ''flat'', 6, 1, %L, null, ''no'')', v_l, v_today, v_today + 30), 'INVALID', 'a restructuring needs a reason');
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-s0c'', %L, ''9'', ''flat'', 6, 1, %L, null, ''Lender agreed a longer term'')', v_l, v_today - 100, v_today + 30), 'INVALID', 'not before the last activity');
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-s0d'', %L, ''9'', ''flat'', 6, 1, %L, null, ''Lender agreed a longer term'')', v_l, v_today + 1, v_today + 30), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-s0e'', %L, ''9'', ''balloon'', 6, 1, %L, null, ''Lender agreed a longer term'')', v_l, v_today, v_today + 30), 'INVALID', 'a known method');
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-s0f'', %L, ''9'', ''flat'', null, 1, %L, null, ''Lender agreed a longer term'')', v_l, v_today, v_today + 30), 'INVALID', 'a generated schedule needs its installments');
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-s0g'', %L, ''9'', ''flat'', 6, 1, %L, null, ''Lender agreed a longer term'')', v_l, v_today, v_today - 1), 'INVALID', 'the first installment is not before the effective date');
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-s0h'', %L, ''9'', ''manual'', null, null, null, %L::jsonb, ''Lender agreed a longer term'')', v_l, v_today,
    '[{"due_date":"2099-01-01","principal":"1000"}]'), 'INVALID', 'a manual schedule adds up to the outstanding principal');
  perform test_helpers.assert((select count(*) from public.loan_schedule_versions where loan_id = v_l) = 1, 'refused restructurings change nothing');

  v_v2 := public.loan_restructure(v_l, 'k-p8c-s1', v_today, '9', 'flat', 6, 1, v_today + 30, null, 'Lender agreed a longer term after the hardship');
  perform test_helpers.assert(public.loan_restructure(v_l, 'k-p8c-s1', v_today, '9', 'flat', 6, 1, v_today + 30, null, 'Lender agreed a longer term after the hardship') = v_v2, 'the restructuring replays on the same key');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.loan_schedule_versions where id = v_v1) = 'superseded' and (select status from public.loan_schedule_versions where id = v_v2) = 'active'
    and (select version_no from public.loan_schedule_versions where id = v_v2) = 2 and (select principal_basis from public.loan_schedule_versions where id = v_v2) = v_out
    and (select rate from public.loan_schedule_versions where id = v_v2) = 9 and (select effective_from from public.loan_schedule_versions where id = v_v2) = v_today, 'version 2 is in force with the outstanding principal as its basis');
  perform test_helpers.assert((select count(*) from public.loan_schedule_items where version_id = v_v1) = 12 and (select sum(principal_due) from public.loan_schedule_items where version_id = v_v1) = 12000000
    and (select count(*) from public.loan_schedule_items where version_id = v_v2) = 6 and (select sum(principal_due) from public.loan_schedule_items where version_id = v_v2) = v_out, 'the old schedule is kept whole; the new one schedules what is outstanding');
  perform test_helpers.assert((select count(*) from public.loan_payment_allocations a join public.loan_schedule_items it on it.id = a.item_id join public.loan_payments pm on pm.id = a.payment_id
    where it.version_id = v_v1 and pm.status = 'active') = 3, 'the payments made under the old schedule stay against its installments');
  perform test_helpers.assert((select paid_principal from app_private.loan_items(v_l, v_v1) where seq = 1) = (select principal_due from public.loan_schedule_items where version_id = v_v1 and seq = 1)
    and (select state from app_private.loan_items(v_l, v_v1) where seq = 1) = 'paid', 'the old schedule still shows what was paid');
  perform test_helpers.assert((select bool_and(state = 'scheduled' or state = 'due') from app_private.loan_items(v_l)), 'nothing is paid yet on the new schedule');
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select count(*) from public.loan_schedule(v_l)) = 6 and (select min(version_no) from public.loan_schedule(v_l)) = 2 and (select count(*) from public.loan_schedule(v_l, 1)) = 12,
    'the default schedule is the version in force; the old one is still readable');
  perform test_helpers.logout();
  perform test_helpers.controls8c(pt, 'a restructured loan');

  -- an earlier payment is history now; a new one belongs to version 2 and can still be reversed
  select * into i from app_private.loan_items(v_l) where seq = 1;
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.loan_reverse_payment(%L, ''k-p8c-s2'', %L, ''Reversing old history'')', test_helpers.g('p1'), v_today), 'CONFLICT', 'a payment of a superseded schedule cannot be reversed');
  v_p3 := public.loan_repay(v_l, 'k-p8c-s3', v_today, v_bca, i.principal_due::text, i.interest_due::text, '0', 'First installment of the new schedule');
  perform test_helpers.logout();
  perform test_helpers.assert((select item_id from public.loan_payment_allocations where payment_id = v_p3 limit 1) = i.item_id and (select state from app_private.loan_items(v_l) where seq = 1) = 'paid', 'a payment goes to the schedule in force');
  perform test_helpers.login(v_owner);
  perform public.loan_reverse_payment(v_p3, 'k-p8c-s4', v_today, 'Posted twice by mistake, redone below');
  perform test_helpers.logout();
  perform test_helpers.assert((select state from app_private.loan_items(v_l) where seq = 1) in ('scheduled', 'due') and app_private.loan_outstanding(v_l) = v_out, 'reversing it frees the installment again');
  perform test_helpers.login(v_owner);
  perform public.loan_repay(v_l, 'k-p8c-s5', v_today, v_bca, i.principal_due::text, i.interest_due::text, '0', 'First installment of the new schedule');
  perform test_helpers.logout();
  perform test_helpers.assert(app_private.loan_outstanding(v_l) = v_out - i.principal_due, 'the outstanding principal after the first new installment');
  perform test_helpers.controls8c(pt, 'a payment after the restructuring');
end
$$;


-- ================================================================ 8. a loan given (receivable), with an other receivable beside it
do $$
declare
  pt uuid := test_helpers.entity('p8c_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_l uuid;
  v_j uuid;
  v_o uuid;
  v_p uuid;
  v_w uuid;
  i1 record;
  p public.loan_payments%rowtype;
begin
  perform test_helpers.login(v_owner);
  v_l := public.loan_create(pt, 'k-p8c-g1', 'lent', 'Friendly Co', null, 'Bridging loan to a customer', '6000000', v_today - 35, null, '12', 'interest_only', 3, 1, v_today - 20);
  perform test_helpers.put('lent', v_l);
  v_j := public.loan_activate(v_l, 'k-p8c-g2', v_today - 30, v_bca);
  v_o := public.obligation_create(pt, 'k-p8c-g3', 'receivable', 'Ex-partner', null, v_today - 25, null, '1000000', 'cash', v_bca, null, 'Advance outside any loan');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jd(v_j, 'OTHER_RECEIVABLE') = 6000000 and test_helpers.jc(v_j, 'BANK_OPERATING') = 6000000
    and (select principal_account_id from public.loans where id = v_l) = test_helpers.acct(pt, 'OTHER_RECEIVABLE'), 'a loan given: Dr other receivable, Cr bank');
  perform test_helpers.assert((select direction from public.money_movements where source_type = 'loan' and source_id = v_l) = 'out', 'the cash leaves the bank');
  perform test_helpers.controls8c(pt, 'a loan given beside an other receivable');
  select * into i1 from app_private.loan_items(v_l) where seq = 1;
  perform test_helpers.assert(i1.principal_due = 0 and i1.interest_due = 60000 and i1.overdue, 'an interest-only installment carries interest only');

  perform test_helpers.login(v_owner);
  v_p := public.loan_repay(v_l, 'k-p8c-g4', v_today - 20, v_bca, '0', '60000', '0', 'Interest for the first month');
  perform test_helpers.logout();
  select * into p from public.loan_payments where id = v_p;
  perform test_helpers.assert(p.principal = 0 and test_helpers.jd(p.journal_id, 'BANK_OPERATING') = 60000 and test_helpers.jc(p.journal_id, 'INTEREST_INCOME') = 60000
    and (select direction from public.money_movements where source_type = 'loan_payment' and source_id = v_p) = 'in' and p.tax_status = 'needs_review', 'interest received is income; the principal is untouched');
  perform test_helpers.assert(app_private.loan_outstanding(v_l) = 6000000 and (select state from app_private.loan_items(v_l) where seq = 1) = 'paid', 'a payment of interest alone leaves the principal as it was');
  perform test_helpers.controls8c(pt, 'interest received');

  perform test_helpers.login(v_owner);
  perform public.loan_repay(v_l, 'k-p8c-g5', v_today - 15, v_bca, '2000000', '0', '10000', 'Partial repayment with an arrangement fee');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.bal(pt, 'OTHER_NONOPERATING_INCOME') = -10000 and app_private.loan_outstanding(v_l) = 4000000, 'a fee received is other income');
  perform test_helpers.controls8c(pt, 'a partial repayment of a loan given');

  perform test_helpers.login(v_owner);
  v_w := public.loan_write_off(v_l, 'k-p8c-g6', v_today - 10, '500000', 'Part of the loan is not recoverable');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jd((select journal_id from public.loan_payments where id = v_w), 'BAD_DEBT_EXPENSE') = 500000
    and test_helpers.jc((select journal_id from public.loan_payments where id = v_w), 'OTHER_RECEIVABLE') = 500000, 'a bad debt: Dr bad debt expense, Cr other receivable');
  perform test_helpers.controls8c(pt, 'a bad debt');
  perform test_helpers.login(v_owner);
  perform public.loan_repay(v_l, 'k-p8c-g7', v_today - 5, v_bca, '3500000');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.loans where id = v_l) = 'closed' and app_private.loan_outstanding(v_l) = 0 and test_helpers.bal(pt, 'OTHER_RECEIVABLE') = 1000000, 'the loan given is closed; only the other receivable remains');
  perform test_helpers.controls8c(pt, 'a closed loan given');
end
$$;

-- ================================================================ 9. cancelling a draft, the asset link
do $$
declare
  pt uuid := test_helpers.entity('p8c_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_draft uuid := test_helpers.g('draft');
  v_a uuid[];
  v_l uuid;
  v_lent uuid := test_helpers.g('lent');
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.loan_cancel(%L, ''k-p8c-x0'', ''no'')', v_draft), 'INVALID', 'a cancellation needs a reason');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.loan_cancel(%L, ''k-p8c-x0b'', ''Not allowed for a viewer'')', v_draft), 'FORBIDDEN', 'a viewer cannot cancel');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.loan_cancel(v_draft, 'k-p8c-x1', 'The lender withdrew the offer') = v_draft, 'a draft is cancelled');
  perform test_helpers.assert(public.loan_cancel(v_draft, 'k-p8c-x1', 'The lender withdrew the offer') = v_draft, 'the cancellation replays on the same key');
  perform test_helpers.expect_msg(format('select public.loan_cancel(%L, ''k-p8c-x2'', ''Cancelled twice by mistake'')', v_draft), 'CONFLICT', 'a cancelled loan is not cancelled again');
  perform test_helpers.expect_msg(format('select public.loan_activate(%L, ''k-p8c-x3'', %L, %L)', v_draft, v_today, v_bca), 'CONFLICT', 'a cancelled loan is not activated');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.loans where id = v_draft) = 'cancelled' and (select cancel_reason from public.loans where id = v_draft) like 'The lender%' and app_private.loan_outstanding(v_draft) = 0, 'the cancellation is recorded');

  -- asset financing: a link, no posting
  perform test_helpers.login(v_owner);
  v_a := public.asset_load_opening(pt, 'k-p8c-as1', jsonb_build_array(jsonb_build_object('name', 'Delivery van', 'cost_account', test_helpers.acct(pt, 'FIXED_ASSET_EQUIPMENT'),
    'acquisition_date', v_today - 60, 'in_service_date', v_today - 60, 'cutover_date', v_today - 30, 'cost', '80000000', 'method', 'none')));
  v_l := public.loan_create(pt, 'k-p8c-x4', 'borrowed', 'Leasing Co', null, 'Vehicle financing', '60000000', v_today - 40, 'long', '9', 'annuity', 24, 1, v_today + 20, null, v_a[1]);
  perform test_helpers.logout();
  perform test_helpers.assert((select asset_id from public.loans where id = v_l) = v_a[1] and (select principal_account_id from public.loans where id = v_l) = test_helpers.acct(pt, 'LOAN_LONG_TERM'), 'a long-term loan financing an asset');
  perform test_helpers.login(v_owner);
  perform public.loan_set_asset(v_l, null);
  perform test_helpers.assert((select asset_id from public.loans where id = v_l) is null, 'the link is removed');
  perform public.loan_set_asset(v_l, v_a[1]);
  perform test_helpers.expect_msg(format('select public.loan_set_asset(%L, %L)', v_l, gen_random_uuid()), 'INVALID', 'an unknown asset');
  perform test_helpers.expect_msg(format('select public.loan_set_asset(%L, %L)', v_lent, v_a[1]), 'INVALID', 'a loan given is not linked to an asset');
  perform test_helpers.logout();
  perform test_helpers.assert((select asset_id from public.loans where id = v_l) = v_a[1] and not exists (select 1 from public.journal_entries where source_type = 'loan' and source_id = v_l), 'linking posts nothing');
  perform test_helpers.put('l_asset', v_l);
  perform test_helpers.controls8c(pt, 'a loan linked to an asset');
end
$$;


-- ================================================================ 10. opening loans and the control against the opening balances
do $$
declare
  op uuid := test_helpers.entity('p8c_op');
  pt uuid := test_helpers.entity('p8c_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_today date := test_helpers.today(op);
  v_cut date := test_helpers.today(op) - 40;
  v_ag date := test_helpers.today(op) - 400;
  v_ids uuid[];
  v_ids2 uuid[];
  v_bank uuid;
  i1 record;
  v_json jsonb;
begin
  v_json := jsonb_build_array(
    jsonb_build_object('direction', 'borrowed', 'counterparty', 'Old Bank', 'term_class', 'long', 'principal', '10000000', 'outstanding', '9000000',
      'agreement_date', v_ag, 'cutover_date', v_cut, 'method', 'annuity', 'rate', '10', 'installments', 6, 'step_months', 1, 'first_due', v_today - 10),
    jsonb_build_object('direction', 'lent', 'counterparty', 'Old Debtor', 'principal', '2000000', 'outstanding', '2000000',
      'agreement_date', v_ag, 'cutover_date', v_cut, 'method', 'manual',
      'items', jsonb_build_array(jsonb_build_object('due_date', v_today + 30, 'principal', '1000000'), jsonb_build_object('due_date', v_today + 60, 'principal', '1000000'))));
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.loan_load_opening(%L, ''k-p8c-o0a'', %L::jsonb)', op, '[]'), 'INVALID', 'give at least one loan');
  perform test_helpers.expect_msg(format('select public.loan_load_opening(%L, ''k-p8c-o0b'', %L::jsonb)', op, jsonb_build_array(jsonb_build_object('direction', 'swap', 'counterparty', 'X', 'outstanding', '100', 'agreement_date', v_ag, 'cutover_date', v_cut))), 'INVALID', 'a known direction');
  perform test_helpers.expect_msg(format('select public.loan_load_opening(%L, ''k-p8c-o0c'', %L::jsonb)', op, jsonb_build_array(jsonb_build_object('direction', 'borrowed', 'counterparty', 'X', 'outstanding', '100', 'agreement_date', v_ag, 'cutover_date', v_today + 1))), 'INVALID', 'the cut-over is not in the future');
  perform test_helpers.expect_msg(format('select public.loan_load_opening(%L, ''k-p8c-o0d'', %L::jsonb)', op, jsonb_build_array(jsonb_build_object('direction', 'borrowed', 'counterparty', 'X', 'outstanding', '200', 'principal', '100', 'agreement_date', v_ag, 'cutover_date', v_cut, 'term_class', 'long', 'method', 'flat', 'installments', 2, 'first_due', v_today))), 'INVALID', 'the outstanding principal is not above the original');
  perform test_helpers.expect_msg(format('select public.loan_load_opening(%L, ''k-p8c-o0e'', %L::jsonb)', op, jsonb_build_array(jsonb_build_object('direction', 'borrowed', 'counterparty', 'X', 'outstanding', '100', 'agreement_date', v_ag, 'cutover_date', v_cut, 'method', 'flat', 'installments', 2, 'first_due', v_today))), 'INVALID', 'a company loan is short or long term');
  perform test_helpers.expect_msg(format('select public.loan_load_opening(%L, ''k-p8c-o0f'', %L::jsonb)', op, jsonb_build_array(jsonb_build_object('direction', 'lent', 'counterparty', 'X', 'outstanding', '100', 'agreement_date', v_ag, 'cutover_date', v_cut, 'method', 'manual',
    'items', jsonb_build_array(jsonb_build_object('due_date', v_today + 30, 'principal', '99'))))), 'INVALID', 'the manual schedule adds up to the outstanding principal');
  perform test_helpers.assert(not exists (select 1 from public.loans where entity_id = op), 'refused loads change nothing');
  v_ids := public.loan_load_opening(op, 'k-p8c-o1', v_json);
  v_ids2 := public.loan_load_opening(op, 'k-p8c-o1', v_json);
  perform test_helpers.logout();
  perform test_helpers.assert(v_ids = v_ids2 and array_length(v_ids, 1) = 2 and (select count(*) from public.loans where entity_id = op) = 2, 'the opening load replays on the same key');
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.loan_load_opening(%L, ''k-p8c-o0g'', %L::jsonb)', pt, v_json), 'FORBIDDEN', 'a viewer cannot load loans');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.loans where entity_id = op and status = 'active' and source_type = 'opening' and effective_date = v_cut) = 2
    and (select funded_principal from public.loans where id = v_ids[1]) = 9000000 and (select principal from public.loans where id = v_ids[1]) = 10000000
    and (select principal_account_id from public.loans where id = v_ids[1]) = test_helpers.acct(op, 'LOAN_LONG_TERM'), 'two opening loans: the original and the outstanding principal');
  perform test_helpers.assert((select principal_basis from public.loan_schedule_versions where loan_id = v_ids[1]) = 9000000 and (select count(*) from public.loan_schedule_items where loan_id = v_ids[1]) = 6
    and (select sum(principal_due) from public.loan_schedule_items where loan_id = v_ids[1]) = 9000000, 'the schedule continues from the outstanding principal');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = op) and app_private.loan_outstanding(v_ids[1], v_cut - 1) = 0 and app_private.loan_outstanding(v_ids[1], v_cut) = 9000000,
    'loading posts no journal; nothing is owed before the cut-over');
  -- until the opening balances are posted the register is ahead of the ledger
  perform test_helpers.assert(app_private.loans_total(op, 'borrowed', v_today) = 9000000 and test_helpers.bal(op, 'LOAN_LONG_TERM') = 0, 'the control shows the register ahead of the ledger');
  perform test_helpers.login(v_owner);
  perform public.post_opening_balances(op, 'k-p8c-ob1', v_cut, jsonb_build_array(
    jsonb_build_object('account_key', 'OTHER_RECEIVABLE', 'debit', 2000000),
    jsonb_build_object('account_key', 'FIXED_ASSET_OTHER', 'debit', 7000000),
    jsonb_build_object('account_key', 'LOAN_LONG_TERM', 'credit', 9000000)), 'Opening balances');
  perform test_helpers.logout();
  perform test_helpers.controls8c(op, 'after the opening balances');
  -- an opening loan is repaid like any other
  select * into i1 from app_private.loan_items(v_ids[1]) where seq = 1;
  perform test_helpers.login(v_owner);
  perform test_helpers.put('op_bank', public.create_financial_account(op, 'k-p8c-ofa', 'bank', 'Old Bank Account', 'IDR', test_helpers.acct(op, 'BANK_OPERATING')));
  perform public.loan_repay(v_ids[1], 'k-p8c-o2', v_today - 5, test_helpers.g('op_bank'), i1.principal_due::text, i1.interest_due::text, '0', 'First installment after the cut-over');
  perform test_helpers.logout();
  perform test_helpers.assert(app_private.loan_outstanding(v_ids[1]) = 9000000 - i1.principal_due and test_helpers.bal(op, 'LOAN_LONG_TERM') = -(9000000 - i1.principal_due), 'an opening loan is repaid from the cut-over balance');
  perform test_helpers.controls8c(op, 'an opening loan repaid');
end
$$;

-- ================================================================ 11. Personal loans
do $$
declare
  pe uuid := test_helpers.entity('p8c_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pe);
  v_bank uuid := test_helpers.g('pe_bank');
  v_b uuid;
  v_g uuid;
begin
  perform test_helpers.login(v_owner);
  v_b := public.loan_create(pe, 'k-p8c-pe1', 'borrowed', 'Family Friend', null, 'Personal loan received', '5000000', v_today - 30, null, '0', 'flat', 5, 1, v_today + 5);
  v_g := public.loan_create(pe, 'k-p8c-pe2', 'lent', 'Sibling', null, 'Personal loan given', '3000000', v_today - 30, null, '6', 'flat', 3, 1, v_today + 5);
  perform public.loan_activate(v_b, 'k-p8c-pe3', v_today - 28, v_bank);
  perform public.loan_activate(v_g, 'k-p8c-pe4', v_today - 28, v_bank);
  perform public.loan_repay(v_b, 'k-p8c-pe5', v_today - 20, v_bank, '1000000', '30000', '5000', 'Interest and transfer fee');
  perform public.loan_repay(v_g, 'k-p8c-pe6', v_today - 10, v_bank, '1000000', '15000', '0', 'Interest from my sibling');
  perform test_helpers.expect_msg(format('select public.loan_repay(%L, ''k-p8c-pe7'', %L, %L, ''1000'', ''100'')', v_g, v_today - 9, v_bank), 'INVALID', 'interest needs a note here too');
  perform test_helpers.logout();
  perform test_helpers.assert((select principal_account_id from public.loans where id = v_b) = test_helpers.acct(pe, 'PERSONAL_LOAN') and (select term_class from public.loans where id = v_b) is null, 'a personal loan received sits on Personal Loans / Debt');
  perform test_helpers.assert(test_helpers.bal(pe, 'PERSONAL_LOAN') = -4000000 and test_helpers.bal(pe, 'PERSONAL_INTEREST_EXPENSE') = 30000 and test_helpers.bal(pe, 'OTHER_PERSONAL_EXPENSE') = 5000, 'personal interest and fees use the personal expense accounts');
  perform test_helpers.assert(test_helpers.bal(pe, 'OTHER_RECEIVABLE') = 2000000 and test_helpers.bal(pe, 'INVESTMENT_INCOME') = -15000, 'a personal loan given is a receivable, its interest investment income');
  perform test_helpers.assert(test_helpers.bal(pe, 'PERSONAL_BANK') = 5000000 - 1035000 - 3000000 + 1015000, 'the personal bank follows the payments');
  perform test_helpers.controls8c(pe, 'Personal loans');
end
$$;

-- ================================================================ 12. reading, authorization, immutability
do $$
declare
  pt uuid := test_helpers.entity('p8c_pt');
  pe uuid := test_helpers.entity('p8c_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'd0000000-0000-0000-0000-000000000007';
  v_staff uuid := 'd0000000-0000-0000-0000-000000000008';
  v_today date := test_helpers.today(pt);
  v_l uuid := test_helpers.g('l1');
  v_lent uuid := test_helpers.g('lent');
  v_pay uuid := test_helpers.g('p2');
  v_out numeric := app_private.loan_outstanding(test_helpers.g('l1'));
  v_first uuid;
begin
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.loan_list(pt)) = 4 and (select count(*) from public.loan_list(pt, 'lent')) = 1
    and (select count(*) from public.loan_list(pt, null, 'closed')) = 1 and (select count(*) from public.loan_list(pt, 'borrowed', 'cancelled')) = 1, 'a viewer lists the loans, filtered by direction and status');
  perform test_helpers.assert((select outstanding::numeric from public.loan_list(pt) where loan_id = v_l) = v_out, 'the list shows the outstanding principal');
  perform test_helpers.assert((public.loan_detail(v_l) ->> 'status') = 'active' and jsonb_array_length(public.loan_detail(v_l) -> 'versions') = 2 and jsonb_array_length(public.loan_detail(v_l) -> 'payments') >= 4
    and jsonb_array_length((public.loan_detail(v_l) -> 'payments') -> 0 -> 'allocations') >= 1, 'the detail carries versions, payments and their allocations');
  perform test_helpers.assert((select count(*) from public.loan_due(pt, v_today + 400)) > 0 and (select bool_and(overdue = (days_overdue > 0)) from public.loan_due(pt, v_today + 400)), 'installments due, with the days overdue');
  perform test_helpers.assert((select count(*) from public.loan_due(pt, v_today - 1000)) = 0, 'nothing is due before the first installment');
  perform test_helpers.assert((select (proceeds::numeric) from public.loan_summary(pt, v_today - 120, v_today) where loan_id = v_l) = 12000000
    and (select closing_principal::numeric from public.loan_summary(pt, v_today - 120, v_today) where loan_id = v_l) = (select outstanding::numeric from public.loan_list(pt) where loan_id = v_l)
    and (select opening_principal::numeric from public.loan_summary(pt, v_today - 60, v_today) where loan_id = v_l) = 12000000
    and (select interest_paid::numeric from public.loan_summary(pt, v_today - 120, v_today) where loan_id = v_l) > 120000, 'the summary: opening, proceeds, repaid, closing, interest');
  perform test_helpers.assert((select principal_written_off::numeric from public.loan_summary(pt, v_today - 120, v_today) where loan_id = v_lent) = 500000, 'the summary shows what was written off');
  perform test_helpers.expect_msg(format('select public.loan_restructure(%L, ''k-p8c-z1'', %L, ''9'', ''flat'', 6, 1, %L, null, ''Not for a viewer'')', v_l, v_today, v_today + 30), 'FORBIDDEN', 'a viewer cannot restructure');
  perform test_helpers.expect_msg(format('select public.loan_write_off(%L, ''k-p8c-z2'', %L, ''1000'', ''Not for a viewer'')', v_l, v_today), 'FORBIDDEN', 'a viewer cannot write off');
  perform test_helpers.expect_msg(format('select public.loan_reverse_payment(%L, ''k-p8c-z3'', %L, ''Not for a viewer'')', v_pay, v_today), 'FORBIDDEN', 'a viewer cannot reverse');
  perform test_helpers.expect_msg(format('select * from public.loan_list(%L)', pe), 'FORBIDDEN', 'a viewer of the company sees nothing of the personal Entity');
  perform test_helpers.assert((select count(*) from public.loans where entity_id = pt) = 4 and (select count(*) from public.loan_payments where entity_id = pt) > 4
    and (select count(*) from public.loan_schedule_items where entity_id = pt) > 20 and (select count(*) from public.loan_payment_allocations where entity_id = pt) > 4, 'a viewer reads the tables through RLS');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select * from public.loan_list(%L)', pt), 'FORBIDDEN', 'staff without loans.view cannot list');
  perform test_helpers.assert(not exists (select 1 from public.loans) and not exists (select 1 from public.loan_payments), 'staff read no loan rows');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.assert(not exists (select 1 from public.loans) and not exists (select 1 from public.loan_schedule_versions) and not exists (select 1 from public.loan_schedule_items)
    and not exists (select 1 from public.loan_payments) and not exists (select 1 from public.loan_payment_allocations), 'a stranger sees no loan rows');
  perform test_helpers.expect_msg(format('select public.loan_detail(%L)', v_l), 'FORBIDDEN', 'a stranger cannot read a loan');
  perform test_helpers.expect_msg(format('select * from public.loan_schedule(%L)', v_l), 'FORBIDDEN', 'a stranger cannot read a schedule');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_error(format('update public.loans set principal = 1 where id = %L', v_l), '42501', 'no direct update of a loan');
  perform test_helpers.expect_error(format('delete from public.loans where id = %L', v_l), '42501', 'no direct delete of a loan');
  perform test_helpers.expect_error(format('update public.loan_payments set principal = 1 where id = %L', v_pay), '42501', 'no direct update of a payment');
  perform test_helpers.expect_error(format('insert into public.loan_payment_allocations (entity_id, loan_id, payment_id, principal) values (%L, %L, %L, 1)', pt, v_l, v_pay), '42501', 'no direct allocation');
  perform test_helpers.logout();
  select id into v_first from public.loan_schedule_items where loan_id = v_l order by created_at limit 1;
  perform test_helpers.expect_error(format('delete from public.loans where id = %L', v_l), null, 'a loan cannot be deleted');
  perform test_helpers.expect_error(format('update public.loans set principal = principal + 1 where id = %L', v_l), null, 'the principal of a loan cannot be edited');
  perform test_helpers.expect_error(format('update public.loans set funded_principal = 1 where id = %L', v_l), null, 'the proceeds of an active loan cannot be edited');
  perform test_helpers.expect_error(format('update public.loans set status = ''draft'' where id = %L', v_l), null, 'a loan cannot go back to draft');
  perform test_helpers.expect_error('update public.loans set status = ''active'' where status = ''cancelled''', null, 'a cancelled loan cannot be revived');
  perform test_helpers.expect_error(format('update public.loan_schedule_items set principal_due = 1 where id = %L', v_first), null, 'a schedule item cannot be edited');
  perform test_helpers.expect_error(format('delete from public.loan_schedule_items where id = %L', v_first), null, 'a schedule item cannot be deleted');
  perform test_helpers.expect_error(format('update public.loan_schedule_versions set rate = 1 where loan_id = %L and status = ''superseded''', v_l), null, 'a superseded schedule cannot be edited');
  perform test_helpers.expect_error(format('update public.loan_schedule_versions set status = ''active'' where loan_id = %L and status = ''superseded''', v_l), null, 'a superseded schedule cannot be re-activated');
  perform test_helpers.expect_error(format('update public.loan_payments set principal = principal + 1 where id = %L', v_pay), null, 'a payment cannot be edited');
  perform test_helpers.expect_error(format('delete from public.loan_payments where id = %L', v_pay), null, 'a payment cannot be deleted');
  perform test_helpers.expect_error(format('update public.loan_payment_allocations set principal = 1 where payment_id = %L', v_pay), null, 'an allocation cannot be edited');
  perform test_helpers.expect_error(format('delete from public.loan_payment_allocations where payment_id = %L', v_pay), null, 'an allocation cannot be deleted');
  perform test_helpers.expect_error(format('insert into public.loan_payments (entity_id, loan_id, payment_number, kind, payment_date, principal, financial_account_id, schedule_version_id, journal_id) select entity_id, id, ''LPY-X'', ''repayment'', %L, 999999999999, financial_account_id, (select id from public.loan_schedule_versions where loan_id = loans.id and status = ''active''), proceeds_journal_id from public.loans where id = %L', v_today, v_l), null, 'a payment beyond the principal is refused by the table');
  perform test_helpers.assert((select count(*) from public.audit_events where entity_id = pt and target_table in ('loans', 'loan_payments', 'loan_schedule_versions')) > 0, 'loan changes are audited');
end
$$;

rollback;
