-- P8 gate, part 2 (Step 15 §12): other receivables and payables (cash, offset, write-off, reversal, void) reconcile
-- to the General Ledger; Personal Entity; related-Entity link; authorization; immutability. All data is synthetic;
-- dates are relative to the Entity's today. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p8b (k text primary key, v uuid not null);
grant all on test_helpers.p8b to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p8b values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p8b where k = p_k $f$;
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

-- The invariants of the obligation layer: money equals the ledger; each side's sub-ledger equals its control account.
create function test_helpers.controls8b(p_entity uuid, p_label text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $f$
declare
  v_today date := app_private.entity_today(p_entity);
begin
  if exists (select 1 from app_private.money_control_rows(p_entity) r where r.ledger_balance <> r.movement_base_balance) then
    raise exception 'TEST FAIL [%]: money movements differ from the ledger', p_label;
  end if;
  if app_private.obligations_total(p_entity, 'receivable', v_today) <> test_helpers.bal(p_entity, 'OTHER_RECEIVABLE') then
    raise exception 'TEST FAIL [%]: other receivables % differ from the ledger %', p_label,
      app_private.obligations_total(p_entity, 'receivable', v_today), test_helpers.bal(p_entity, 'OTHER_RECEIVABLE');
  end if;
  if app_private.obligations_total(p_entity, 'payable', v_today) <> -test_helpers.bal(p_entity, 'OTHER_PAYABLE') then
    raise exception 'TEST FAIL [%]: other payables % differ from the ledger %', p_label,
      app_private.obligations_total(p_entity, 'payable', v_today), -test_helpers.bal(p_entity, 'OTHER_PAYABLE');
  end if;
  if exists (select 1 from public.other_obligations o where o.entity_id = p_entity and o.status = 'settled'
             and app_private.obligation_outstanding(o.id) <> 0) then
    raise exception 'TEST FAIL [%]: a settled obligation still has an outstanding amount', p_label;
  end if;
  if exists (select 1 from public.other_obligations o where o.entity_id = p_entity and o.status = 'open'
             and app_private.obligation_outstanding(o.id) = 0) then
    raise exception 'TEST FAIL [%]: an open obligation has nothing outstanding', p_label;
  end if;
end
$f$;
grant execute on function test_helpers.controls8b(uuid, text) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p8b_pt', 'P8B PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p8b_pe', 'P8B PERSONAL (synthetic)') returning id into v_pe;
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

-- ================================================================ 1. setup
do $$
declare
  pt uuid := test_helpers.entity('p8b_pt');
  pe uuid := test_helpers.entity('p8b_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.put('bca', public.create_financial_account(pt, 'key-p8b-fa-01', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-SECRET-1', 'PT P8B'));
  perform test_helpers.put('cash', public.create_financial_account(pt, 'key-p8b-fa-02', 'cash', 'Petty Cash', 'IDR', test_helpers.acct(pt, 'CASH')));
  perform test_helpers.put('usd', public.create_financial_account(pt, 'key-p8b-fa-03', 'bank', 'USD Account', 'USD'));
  perform test_helpers.put('pe_bank', public.create_financial_account(pe, 'key-p8b-fa-04', 'bank', 'Personal BCA', 'IDR', test_helpers.acct(pe, 'PERSONAL_BANK')));
  perform test_helpers.put('cx', public.create_contact(pt, 'key-p8b-ct-01', 'customer', 'Friendly Co'));
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. a cash receivable: recognition, validation, replay
do $$
declare
  pt uuid := test_helpers.entity('p8b_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_today date := test_helpers.today(pt);
  v_d0 date := test_helpers.today(pt) - 30;
  v_bca uuid := test_helpers.g('bca');
  v_id uuid;
  o public.other_obligations%rowtype;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0a'', ''loan'', ''Friendly Co'', null, %L, null, ''5000000'', ''cash'', %L, null, ''Short advance'')', pt, v_d0, v_bca), 'INVALID', 'kind is receivable or payable');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0b'', ''receivable'', ''Friendly Co'', null, %L, null, ''5000000'', ''cash'', %L, null, ''Short advance'')', pt, v_today + 1, v_bca), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0c'', ''receivable'', ''Friendly Co'', null, %L, %L, ''5000000'', ''cash'', %L, null, ''Short advance'')', pt, v_d0, v_d0 - 1, v_bca), 'INVALID', 'due before the date');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0d'', ''receivable'', ''Friendly Co'', null, %L, null, ''0'', ''cash'', %L, null, ''Short advance'')', pt, v_d0, v_bca), 'INVALID', 'amount above zero');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0e'', ''receivable'', ''Friendly Co'', null, %L, null, ''5000000.999'', ''cash'', %L, null, ''Short advance'')', pt, v_d0, v_bca), 'INVALID', 'too many decimals');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0f'', ''receivable'', ''Friendly Co'', null, %L, null, ''5000000'', ''cash'', %L, null, ''x'')', pt, v_d0, v_bca), 'INVALID', 'purpose needed');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0g'', ''receivable'', ''Friendly Co'', null, %L, null, ''5000000'', ''cash'', %L, null, ''Short advance'')', pt, v_d0, test_helpers.g('usd')), 'INVALID', 'base-currency account only');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0h'', ''receivable'', ''Friendly Co'', null, %L, null, ''5000000'', ''cash'', null, null, ''Short advance'')', pt, v_d0), 'INVALID', 'a cash obligation needs an account');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0i'', ''receivable'', ''Friendly Co'', %L, %L, null, ''5000000'', ''cash'', %L, null, ''Short advance'')', pt, gen_random_uuid(), v_d0, v_bca), 'INVALID', 'unknown contact');
  perform test_helpers.assert(not exists (select 1 from public.other_obligations where entity_id = pt) and not exists (select 1 from public.journal_entries where entity_id = pt), 'refused recognitions change nothing');
  perform test_helpers.logout();

  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-0j'', ''receivable'', ''Friendly Co'', null, %L, null, ''5000000'', ''cash'', %L, null, ''Short advance'')', pt, v_d0, v_bca), 'FORBIDDEN', 'a viewer cannot record an obligation');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  v_id := public.obligation_create(pt, 'key-p8b-r-1', 'receivable', 'Friendly Co', test_helpers.g('cx'), v_d0, v_today + 30, '5000000', 'cash', v_bca, null, 'Short advance to a friendly customer');
  perform test_helpers.put('r1', v_id);
  perform test_helpers.assert(public.obligation_create(pt, 'key-p8b-r-1', 'receivable', 'Friendly Co', test_helpers.g('cx'), v_d0, v_today + 30, '5000000', 'cash', v_bca, null, 'Short advance to a friendly customer') = v_id, 'recognition replays on the same key');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-r-1'', ''receivable'', ''Friendly Co'', null, %L, null, ''6000000'', ''cash'', %L, null, ''Short advance to a friendly customer'')', pt, v_d0, v_bca), 'INVALID', 'the same key with other facts is refused');
  perform test_helpers.logout();

  select * into o from public.other_obligations where id = v_id;
  perform test_helpers.assert(o.kind = 'receivable' and o.status = 'open' and o.principal = 5000000 and o.recognition = 'cash' and o.obligation_number like 'ORC-%'
    and o.source_type = 'manual' and o.financial_account_id = v_bca and o.journal_id is not null and o.created_by = v_owner, 'the obligation is recorded');
  perform test_helpers.assert(test_helpers.jd(o.journal_id, 'OTHER_RECEIVABLE') = 5000000 and test_helpers.jc(o.journal_id, 'BANK_OPERATING') = 5000000, 'Dr other receivable, Cr bank');
  perform test_helpers.assert((select direction from public.money_movements where source_type = 'other_obligation' and source_id = v_id) = 'out'
    and (select amount from public.money_movements where source_type = 'other_obligation' and source_id = v_id) = 5000000, 'the cash leaves the bank');
  perform test_helpers.assert(test_helpers.bal(pt, 'OTHER_RECEIVABLE') = 5000000 and app_private.obligations_total(pt, 'receivable', v_today) = 5000000, 'the register equals the control account');
  perform test_helpers.controls8b(pt, 'a cash receivable');

  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select count(*) from public.obligation_list(pt)) = 1 and (select outstanding::numeric from public.obligation_list(pt, 'receivable', 'open')) = 5000000
    and (select overdue from public.obligation_list(pt)) = false, 'the list shows the outstanding amount');
  perform test_helpers.assert((public.obligation_detail(v_id) ->> 'principal')::numeric = 5000000 and jsonb_array_length(public.obligation_detail(v_id) -> 'settlements') = 0, 'the detail carries the principal');
  perform test_helpers.logout();
end
$$;


-- ================================================================ 3. settling: partial, interest, full, reversal
do $$
declare
  pt uuid := test_helpers.entity('p8b_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'd0000000-0000-0000-0000-000000000008';
  v_today date := test_helpers.today(pt);
  v_d1 date := test_helpers.today(pt) - 20;
  v_d2 date := test_helpers.today(pt) - 10;
  v_bca uuid := test_helpers.g('bca');
  v_cash uuid := test_helpers.g('cash');
  v_r uuid := test_helpers.g('r1');
  v_s1 uuid;
  v_s2 uuid;
  v_rev uuid;
  s public.other_obligation_settlements%rowtype;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-0a'', %L, %L, ''6000000'')', v_r, v_d1, v_bca), 'INVALID', 'more than the outstanding amount');
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-0b'', %L, %L, ''2000000'', ''100000'')', v_r, v_d1, v_bca), 'INVALID', 'interest needs a note');
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-0c'', %L, %L, ''2000000'')', v_r, test_helpers.today(pt) - 31, v_bca), 'INVALID', 'not before the obligation');
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-0d'', %L, %L, ''2000000'')', v_r, v_today + 1, v_bca), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-0e'', %L, %L, ''0'')', v_r, v_d1, v_bca), 'INVALID', 'a settlement has a principal');
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-0f'', %L, %L, ''2000000'')', v_r, v_d1, test_helpers.g('usd')), 'INVALID', 'base-currency account only');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-0g'', %L, %L, ''2000000'')', v_r, v_d1, v_bca), 'FORBIDDEN', 'a viewer cannot settle');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-0h'', %L, %L, ''2000000'')', v_r, v_d1, v_bca), 'FORBIDDEN', 'staff cannot settle');
  perform test_helpers.logout();
  perform test_helpers.assert(not exists (select 1 from public.other_obligation_settlements), 'refused settlements change nothing');

  perform test_helpers.login(v_owner);
  v_s1 := public.obligation_settle(v_r, 'key-p8b-s-1', v_d1, v_bca, '2000000', '100000', '0', 'Agreed interest for the delay');
  perform test_helpers.assert(public.obligation_settle(v_r, 'key-p8b-s-1', v_d1, v_bca, '2000000', '100000', '0', 'Agreed interest for the delay') = v_s1, 'the settlement replays on the same key');
  perform test_helpers.logout();
  select * into s from public.other_obligation_settlements where id = v_s1;
  perform test_helpers.assert(s.kind = 'cash' and s.status = 'active' and s.principal = 2000000 and s.interest = 100000 and s.fee = 0 and s.tax_status = 'needs_review'
    and s.settlement_number like 'OSET-%', 'the settlement records principal and interest, and the interest awaits tax review');
  perform test_helpers.assert(test_helpers.jd(s.journal_id, 'BANK_OPERATING') = 2100000 and test_helpers.jc(s.journal_id, 'OTHER_RECEIVABLE') = 2000000
    and test_helpers.jc(s.journal_id, 'INTEREST_INCOME') = 100000, 'Dr bank 2,100,000; Cr other receivable 2,000,000; Cr interest income 100,000');
  perform test_helpers.assert((select direction from public.money_movements where source_type = 'obligation_settlement' and source_id = v_s1) = 'in'
    and (select amount from public.money_movements where source_type = 'obligation_settlement' and source_id = v_s1) = 2100000, 'the cash comes back into the bank');
  perform test_helpers.assert((select status from public.other_obligations where id = v_r) = 'open' and app_private.obligation_outstanding(v_r) = 3000000, 'three million is still outstanding');
  perform test_helpers.controls8b(pt, 'a partial settlement');

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-1x'', %L, %L, ''1000000'')', v_r, v_d1 - 1, v_bca), 'INVALID', 'not before the last settlement');
  v_s2 := public.obligation_settle(v_r, 'key-p8b-s-2', v_d2, v_cash, '3000000', '0', '50000', 'Handling fee');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.other_obligations where id = v_r) = 'settled' and app_private.obligation_outstanding(v_r) = 0, 'settling the rest closes the obligation');
  perform test_helpers.assert(test_helpers.jc((select journal_id from public.other_obligation_settlements where id = v_s2), 'OTHER_NONOPERATING_INCOME') = 50000
    and test_helpers.jd((select journal_id from public.other_obligation_settlements where id = v_s2), 'CASH') = 3050000, 'a fee is other income, and the cash box takes the total');
  perform test_helpers.assert((select tax_status from public.other_obligation_settlements where id = v_s2) = 'not_applicable', 'a fee alone needs no tax review');
  perform test_helpers.controls8b(pt, 'a full settlement');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-s-3'', %L, %L, ''1000'')', v_r, v_today, v_bca), 'CONFLICT', 'a settled obligation is not settled again');
  perform test_helpers.expect_msg(format('select public.obligation_void(%L, ''key-p8b-v-0'', %L, ''Wrong entry'')', v_r, v_today), 'CONFLICT', 'an obligation with settlements cannot be voided');
  perform test_helpers.logout();

  -- reversing the last settlement re-opens the obligation and restores everything
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.obligation_reverse_settlement(%L, ''key-p8b-rv-0'', %L, ''no'')', v_s2, v_today), 'INVALID', 'a reversal needs a reason');
  perform test_helpers.expect_msg(format('select public.obligation_reverse_settlement(%L, ''key-p8b-rv-0b'', %L, ''Wrong account'')', v_s2, v_d2 - 1), 'INVALID', 'not before the settlement');
  v_rev := public.obligation_reverse_settlement(v_s2, 'key-p8b-rv-1', v_today, 'Wrong cash account was used');
  perform test_helpers.assert(public.obligation_reverse_settlement(v_s2, 'key-p8b-rv-1', v_today, 'Wrong cash account was used') = v_rev, 'the reversal replays on the same key');
  perform test_helpers.expect_msg(format('select public.obligation_reverse_settlement(%L, ''key-p8b-rv-2'', %L, ''Twice by mistake'')', v_s2, v_today), 'CONFLICT', 'a reversed settlement is not reversed again');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.other_obligations where id = v_r) = 'open' and app_private.obligation_outstanding(v_r) = 3000000
    and (select status from public.other_obligation_settlements where id = v_s2) = 'reversed', 'the obligation is open again with three million outstanding');
  perform test_helpers.assert(test_helpers.bal(pt, 'CASH') = 0 and (select count(*) from public.money_movements where source_type = 'obligation_settlement' and source_id = v_s2) = 2, 'the cash box is back to zero, the movement is mirrored');
  perform test_helpers.controls8b(pt, 'a reversed settlement');
  perform test_helpers.assert(app_private.obligation_outstanding(v_r, v_d2) = 0 and app_private.obligation_outstanding(v_r, v_d2 - 1) = 3000000
    and app_private.obligation_outstanding(v_r, v_today) = 3000000, 'as of a date before the reversal the settlement still counts');
end
$$;


-- ================================================================ 4. write-off of a receivable (step-up, reason, reversal)
do $$
declare
  pt uuid := test_helpers.entity('p8b_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_today date := test_helpers.today(pt);
  v_d3 date := test_helpers.today(pt);
  v_r uuid := test_helpers.g('r1');
  v_w uuid;
  v_j uuid;
  s public.other_obligation_settlements%rowtype;
begin
  perform test_helpers.login(v_owner, 'aal2', interval '2 hours');
  perform test_helpers.expect_msg(format('select public.obligation_write_off(%L, ''key-p8b-w-0'', %L, ''1000000'', ''Customer closed down'')', v_r, v_d3), 'STEP_UP_REQUIRED', 'a write-off needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.obligation_write_off(%L, ''key-p8b-w-0b'', %L, ''1000000'', ''no'')', v_r, v_d3), 'INVALID', 'a write-off needs a reason');
  perform test_helpers.expect_msg(format('select public.obligation_write_off(%L, ''key-p8b-w-0c'', %L, ''3000001'', ''Customer closed down'')', v_r, v_d3), 'INVALID', 'not more than the outstanding amount');
  perform test_helpers.expect_msg(format('select public.obligation_write_off(%L, ''key-p8b-w-0d'', %L, ''1000000'', ''Customer closed down'')', v_r, test_helpers.today(pt) - 21), 'INVALID', 'not before the last settlement activity');
  v_w := public.obligation_write_off(v_r, 'key-p8b-w-1', v_d3, '1000000', 'Customer closed down, part not recoverable');
  perform test_helpers.assert(public.obligation_write_off(v_r, 'key-p8b-w-1', v_d3, '1000000', 'Customer closed down, part not recoverable') = v_w, 'the write-off replays on the same key');
  perform test_helpers.logout();
  select * into s from public.other_obligation_settlements where id = v_w;
  perform test_helpers.assert(s.kind = 'write_off' and s.principal = 1000000 and s.financial_account_id is null and s.tax_status = 'needs_review', 'a write-off is a settlement without cash that awaits tax review');
  perform test_helpers.assert(test_helpers.jd(s.journal_id, 'BAD_DEBT_EXPENSE') = 1000000 and test_helpers.jc(s.journal_id, 'OTHER_RECEIVABLE') = 1000000, 'Dr bad debt, Cr other receivable');
  perform test_helpers.assert(not exists (select 1 from public.money_movements where source_type = 'obligation_settlement' and source_id = v_w), 'a write-off moves no cash');
  perform test_helpers.assert(app_private.obligation_outstanding(v_r) = 2000000 and (select status from public.other_obligations where id = v_r) = 'open', 'two million is still outstanding');
  perform test_helpers.controls8b(pt, 'a write-off');

  -- the admin can settle but neither write off nor reverse without the owner-level step-up in this build's rule set
  perform test_helpers.login(v_admin);
  perform test_helpers.assert(public.obligation_settle(v_r, 'key-p8b-s-9', v_d3, test_helpers.g('bca'), '2000000') is not null, 'a finance admin settles the rest in cash');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.other_obligations where id = v_r) = 'settled', 'the receivable is settled');
  perform test_helpers.controls8b(pt, 'settled after a write-off');
  perform test_helpers.login(v_owner, 'aal2', interval '2 hours');
  perform test_helpers.expect_msg(format('select public.obligation_reverse_settlement(%L, ''key-p8b-w-2'', %L, ''Undo the write-off'')', v_w, v_today), 'STEP_UP_REQUIRED', 'reversing needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  v_j := public.obligation_reverse_settlement(v_w, 'key-p8b-w-3', v_today, 'Customer paid this part after all');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.other_obligation_settlements where id = v_w) = 'reversed' and app_private.obligation_outstanding(v_r) = 1000000
    and (select status from public.other_obligations where id = v_r) = 'open', 'reversing the write-off re-opens the receivable');
  perform test_helpers.controls8b(pt, 'a reversed write-off');
end
$$;

-- ================================================================ 5. payables: cash, interest and fee, write-off, offset recognition
do $$
declare
  pt uuid := test_helpers.entity('p8b_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_acct uuid := 'd0000000-0000-0000-0000-000000000006';
  v_today date := test_helpers.today(pt);
  v_d0 date := test_helpers.today(pt) - 30;
  v_bca uuid := test_helpers.g('bca');
  v_p uuid;
  v_po uuid;
  v_ro uuid;
  v_s uuid;
  v_w uuid;
  o public.other_obligations%rowtype;
  s public.other_obligation_settlements%rowtype;
begin
  perform test_helpers.login(v_owner);
  v_p := public.obligation_create(pt, 'key-p8b-p-1', 'payable', 'Kind Uncle', null, v_d0, v_today + 60, '4000000', 'cash', v_bca, null, 'Short-term help from family');
  perform test_helpers.put('p1', v_p);
  perform test_helpers.logout();
  select * into o from public.other_obligations where id = v_p;
  perform test_helpers.assert(o.kind = 'payable' and o.obligation_number like 'OPY-%' and test_helpers.jd(o.journal_id, 'BANK_OPERATING') = 4000000 and test_helpers.jc(o.journal_id, 'OTHER_PAYABLE') = 4000000
    and (select direction from public.money_movements where source_type = 'other_obligation' and source_id = v_p) = 'in', 'Dr bank, Cr other payable; the cash comes in');
  perform test_helpers.controls8b(pt, 'a cash payable');

  perform test_helpers.login(v_admin);
  v_s := public.obligation_settle(v_p, 'key-p8b-ps-1', test_helpers.today(pt) - 15, v_bca, '1000000', '50000', '10000', 'Interest and bank charge');
  perform test_helpers.logout();
  select * into s from public.other_obligation_settlements where id = v_s;
  perform test_helpers.assert(test_helpers.jd(s.journal_id, 'OTHER_PAYABLE') = 1000000 and test_helpers.jd(s.journal_id, 'INTEREST_EXPENSE') = 50000
    and test_helpers.jd(s.journal_id, 'OTHER_NONOPERATING_EXPENSE') = 10000 and test_helpers.jc(s.journal_id, 'BANK_OPERATING') = 1060000 and s.tax_status = 'needs_review',
    'Dr payable, Dr interest expense, Dr other expense; Cr bank 1,060,000');
  perform test_helpers.assert((select direction from public.money_movements where source_type = 'obligation_settlement' and source_id = v_s) = 'out', 'the cash leaves the bank');
  perform test_helpers.controls8b(pt, 'a payable settlement');
  perform test_helpers.login(v_owner);
  v_w := public.obligation_write_off(v_p, 'key-p8b-pw-1', test_helpers.today(pt) - 10, '500000', 'Uncle forgave this part in writing');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jd((select journal_id from public.other_obligation_settlements where id = v_w), 'OTHER_PAYABLE') = 500000
    and test_helpers.jc((select journal_id from public.other_obligation_settlements where id = v_w), 'OTHER_NONOPERATING_INCOME') = 500000, 'a forgiven payable is other income');
  perform test_helpers.assert(app_private.obligation_outstanding(v_p) = 2500000, '2,500,000 is still owed');
  perform test_helpers.controls8b(pt, 'a payable write-off');

  -- an offset obligation is recognised against an account, not against cash
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-o-0'', ''payable'', ''Landlord'', null, %L, null, ''800000'', ''offset'', null, %L, ''Rent unpaid at year end'')', pt, v_d0, test_helpers.acct(pt, 'RENT_EXPENSE')), 'FORBIDDEN', 'a free counter account needs the journal right');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-o-0a'', ''payable'', ''Landlord'', null, %L, null, ''800000'', ''offset'', null, %L, ''Rent unpaid at year end'')', pt, v_d0, test_helpers.acct(pt, 'RENT_EXPENSE')), 'FORBIDDEN', 'an accountant without loans.manage cannot record it either');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-o-0b'', ''payable'', ''Landlord'', null, %L, null, ''800000'', ''offset'', null, %L, ''Rent unpaid at year end'')', pt, v_d0, test_helpers.acct(pt, 'ACCOUNTS_PAYABLE')), 'INVALID', 'a control account is not a counter account');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-o-0c'', ''payable'', ''Landlord'', null, %L, null, ''800000'', ''offset'', null, %L, ''Rent unpaid at year end'')', pt, v_d0, test_helpers.acct(pt, 'BANK_OPERATING')), 'INVALID', 'a cash account is not a counter account');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-o-0d'', ''payable'', ''Landlord'', null, %L, null, ''800000'', ''offset'', %L, %L, ''Rent unpaid at year end'')', pt, v_d0, v_bca, test_helpers.acct(pt, 'RENT_EXPENSE')), 'INVALID', 'an offset obligation names no financial account');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-o-0e'', ''payable'', ''Landlord'', null, %L, null, ''800000'', ''offset'', null, null, ''Rent unpaid at year end'')', pt, v_d0), 'INVALID', 'an offset obligation names its counter account');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-o-0f'', ''payable'', ''Landlord'', null, %L, null, ''800000'', ''cash'', %L, %L, ''Rent unpaid at year end'')', pt, v_d0, v_bca, test_helpers.acct(pt, 'RENT_EXPENSE')), 'INVALID', 'a cash obligation takes no counter account');
  v_po := public.obligation_create(pt, 'key-p8b-o-1', 'payable', 'Landlord', null, v_d0, v_today + 5, '800000', 'offset', null, test_helpers.acct(pt, 'RENT_EXPENSE'), 'Rent unpaid at year end');
  v_ro := public.obligation_create(pt, 'key-p8b-o-2', 'receivable', 'Ex-partner', null, v_d0, null, '600000', 'offset', null, test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE'), 'Fee billed outside the invoice flow');
  perform test_helpers.logout();
  perform test_helpers.put('po', v_po);
  perform test_helpers.put('ro', v_ro);
  select * into o from public.other_obligations where id = v_po;
  perform test_helpers.assert(o.recognition = 'offset' and o.financial_account_id is null and o.counter_account_id = test_helpers.acct(pt, 'RENT_EXPENSE')
    and test_helpers.jd(o.journal_id, 'RENT_EXPENSE') = 800000 and test_helpers.jc(o.journal_id, 'OTHER_PAYABLE') = 800000, 'Dr rent expense, Cr other payable');
  perform test_helpers.assert(not exists (select 1 from public.money_movements where source_id in (v_po, v_ro)), 'an offset obligation moves no cash');
  perform test_helpers.assert(test_helpers.jd((select journal_id from public.other_obligations where id = v_ro), 'OTHER_RECEIVABLE') = 600000
    and test_helpers.jc((select journal_id from public.other_obligations where id = v_ro), 'OTHER_OPERATING_REVENUE') = 600000, 'Dr other receivable, Cr revenue');
  perform test_helpers.controls8b(pt, 'offset obligations');
end
$$;


-- ================================================================ 6. voiding, overdue, the related Entity
do $$
declare
  pt uuid := test_helpers.entity('p8b_pt');
  pe uuid := test_helpers.entity('p8b_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_today date := test_helpers.today(pt);
  v_d0 date := test_helpers.today(pt) - 30;
  v_cash uuid := test_helpers.g('cash');
  v_bca uuid := test_helpers.g('bca');
  v_id uuid;
  v_v uuid;
  v_po uuid := test_helpers.g('po');
  o public.other_obligations%rowtype;
begin
  -- a mistaken entry is voided while it has no settlements
  perform test_helpers.login(v_owner);
  v_id := public.obligation_create(pt, 'key-p8b-v-1', 'receivable', 'Mistaken Co', null, v_d0, v_d0 + 5, '3000000', 'cash', v_cash, null, 'Entered by mistake');
  perform test_helpers.assert((select overdue from public.obligation_list(pt, 'receivable', 'open') where obligation_id = v_id), 'an open obligation past its due date is overdue');
  perform test_helpers.expect_msg(format('select public.obligation_void(%L, ''key-p8b-v-1a'', %L, ''no'')', v_id, v_today), 'INVALID', 'a void needs a reason');
  perform test_helpers.expect_msg(format('select public.obligation_void(%L, ''key-p8b-v-1b'', %L, ''Entered by mistake'')', v_id, v_d0 - 1), 'INVALID', 'not before the obligation');
  v_v := public.obligation_void(v_id, 'key-p8b-v-2', v_today, 'Entered by mistake, nothing was lent');
  perform test_helpers.assert(public.obligation_void(v_id, 'key-p8b-v-2', v_today, 'Entered by mistake, nothing was lent') = v_v, 'the void replays on the same key');
  perform test_helpers.expect_msg(format('select public.obligation_void(%L, ''key-p8b-v-3'', %L, ''Voided twice by mistake'')', v_id, v_today), 'CONFLICT', 'a void obligation is not voided again');
  perform test_helpers.expect_msg(format('select public.obligation_settle(%L, ''key-p8b-v-4'', %L, %L, ''1000'')', v_id, v_today, v_cash), 'CONFLICT', 'a void obligation cannot be settled');
  perform test_helpers.logout();
  select * into o from public.other_obligations where id = v_id;
  perform test_helpers.assert(o.status = 'void' and o.reversal_journal_id = v_v and o.void_reason like 'Entered by mistake%' and o.voided_by = v_owner, 'the void is recorded with its reason');
  perform test_helpers.assert(app_private.obligations_total(pt, 'receivable', v_today) = test_helpers.bal(pt, 'OTHER_RECEIVABLE')
    and app_private.obligation_outstanding(v_id, v_today - 3) = 3000000 and app_private.obligation_outstanding(v_id, v_today) = 3000000,
    'the void leaves the control in step, and history as of an earlier date still shows the entry');
  perform test_helpers.assert(test_helpers.bal(pt, 'CASH') = 0, 'the cash box is back to zero');
  perform test_helpers.controls8b(pt, 'a void');
  perform test_helpers.login(v_admin);
  perform test_helpers.assert((select count(*) from public.obligation_list(pt, null, 'void')) = 1 and (select count(*) from public.obligation_list(pt, null, 'open')) >= 4, 'the list filters by status');
  perform test_helpers.logout();

  -- a related Entity: a loan from the owner's Personal Entity to the company (an Entity the user can access)
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-rel-0'', ''payable'', ''Owner (personal)'', null, %L, null, ''2000000'', ''cash'', %L, null, ''Owner lends to the company'', %L)', pt, v_d0, v_bca, pe), 'INVALID', 'a related Entity needs its basis');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-rel-0b'', ''payable'', ''Owner (personal)'', null, %L, null, ''2000000'', ''cash'', %L, null, ''Owner lends to the company'', %L, ''x'')', pt, v_d0, v_bca, pe), 'INVALID', 'a basis of a few characters');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-rel-0c'', ''payable'', ''Owner (personal)'', null, %L, null, ''2000000'', ''cash'', %L, null, ''Owner lends to the company'', %L, ''Shareholder loan agreement'')', pt, v_d0, v_bca, pt), 'INVALID', 'an Entity is not related to itself');
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-rel-0d'', ''payable'', ''Owner (personal)'', null, %L, null, ''2000000'', ''cash'', %L, null, ''Owner lends to the company'', null, ''Shareholder loan agreement'')', pt, v_d0, v_bca), 'INVALID', 'a basis needs the related Entity');
  v_id := public.obligation_create(pt, 'key-p8b-rel-1', 'payable', 'Owner (personal)', null, v_d0, null, '2000000', 'cash', v_bca, null, 'Owner lends to the company', pe, 'Shareholder loan agreement dated last month');
  perform test_helpers.logout();
  perform test_helpers.assert((select related_entity_id from public.other_obligations where id = v_id) = pe and (select relationship_basis from public.other_obligations where id = v_id) like 'Shareholder loan%', 'the related Entity and its basis are kept');
  -- the link is a label: it changes no balance in the other Entity
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = pe) and not exists (select 1 from public.other_obligations where entity_id = pe), 'the related Entity is unaffected');
  -- an Entity the user cannot access is refused
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.obligation_create(%L, ''key-p8b-rel-2'', ''payable'', ''Owner (personal)'', null, %L, null, ''2000000'', ''cash'', %L, null, ''Owner lends to the company'', %L, ''Shareholder loan agreement'')', pt, v_d0, v_bca, pe), 'INVALID', 'a related Entity the user cannot access is refused');
  perform test_helpers.logout();
  perform test_helpers.controls8b(pt, 'a related-Entity obligation');
end
$$;

-- ================================================================ 7. Personal Entity
do $$
declare
  pe uuid := test_helpers.entity('p8b_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pe);
  v_d0 date := test_helpers.today(pe) - 20;
  v_bank uuid := test_helpers.g('pe_bank');
  v_id uuid;
  v_s uuid;
  v_ip uuid;
begin
  perform test_helpers.login(v_owner);
  v_id := public.obligation_create(pe, 'key-p8b-pe-1', 'receivable', 'Sibling', null, v_d0, null, '3000000', 'cash', v_bank, null, 'Personal loan to my sibling');
  v_s := public.obligation_settle(v_id, 'key-p8b-pe-2', v_d0 + 5, v_bank, '1000000', '20000', '0', 'Small interest');
  v_ip := public.obligation_create(pe, 'key-p8b-pe-3', 'payable', 'Friend', null, v_d0, null, '1500000', 'cash', v_bank, null, 'Borrowed from a friend');
  perform public.obligation_settle(v_ip, 'key-p8b-pe-4', v_d0 + 5, v_bank, '500000', '30000', '5000', 'Interest and transfer fee');
  perform public.obligation_write_off(v_ip, 'key-p8b-pe-5', v_today, '100000', 'Friend forgave part of it');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jd((select journal_id from public.other_obligations where id = v_id), 'OTHER_RECEIVABLE') = 3000000
    and test_helpers.jc((select journal_id from public.other_obligations where id = v_id), 'PERSONAL_BANK') = 3000000, 'a personal loan given is Dr 1210, Cr the personal bank');
  perform test_helpers.assert(test_helpers.jc((select journal_id from public.other_obligation_settlements where id = v_s), 'INVESTMENT_INCOME') = 20000, 'interest received in Personal is investment income');
  perform test_helpers.assert(test_helpers.bal(pe, 'OTHER_PERSONAL_EXPENSE') = 5000 and test_helpers.bal(pe, 'PERSONAL_INTEREST_EXPENSE') = 30000, 'interest and fee paid in Personal use the personal expense accounts');
  perform test_helpers.assert(test_helpers.bal(pe, 'OTHER_PERSONAL_INCOME') = -100000, 'a forgiven personal payable is other personal income');
  perform test_helpers.assert(test_helpers.bal(pe, 'OTHER_PAYABLE') = -900000 and test_helpers.bal(pe, 'OTHER_RECEIVABLE') = 2000000, 'the personal control accounts carry the balances');
  perform test_helpers.controls8b(pe, 'the personal Entity');
end
$$;

-- ================================================================ 8. authorization and immutability
do $$
declare
  pt uuid := test_helpers.entity('p8b_pt');
  pe uuid := test_helpers.entity('p8b_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'd0000000-0000-0000-0000-000000000007';
  v_staff uuid := 'd0000000-0000-0000-0000-000000000008';
  v_r uuid := test_helpers.g('r1');
  v_p uuid := test_helpers.g('p1');
  v_first uuid;
begin
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.obligation_list(pt)) > 0 and (select count(*) from public.other_obligations where entity_id = pt) > 0
    and (select count(*) from public.other_obligation_settlements where entity_id = pt) > 0, 'a viewer reads the obligations and settlements');
  perform test_helpers.assert(jsonb_array_length(public.obligation_detail(v_r) -> 'settlements') >= 2, 'a viewer reads the detail');
  perform test_helpers.expect_msg(format('select public.obligation_void(%L, ''key-p8b-au-1'', %L, ''Not allowed for a viewer'')', v_p, test_helpers.today(pt)), 'FORBIDDEN', 'a viewer cannot void');
  perform test_helpers.expect_msg(format('select public.obligation_write_off(%L, ''key-p8b-au-2'', %L, ''1000'', ''Not allowed for a viewer'')', v_p, test_helpers.today(pt)), 'FORBIDDEN', 'a viewer cannot write off');
  perform test_helpers.expect_msg(format('select * from public.obligation_list(%L)', pe), 'FORBIDDEN', 'a viewer of the company sees nothing of the personal Entity');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select * from public.obligation_list(%L)', pt), 'FORBIDDEN', 'staff without loans.view cannot list');
  perform test_helpers.assert(not exists (select 1 from public.other_obligations), 'staff read no obligation rows');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.assert(not exists (select 1 from public.other_obligations) and not exists (select 1 from public.other_obligation_settlements), 'a stranger sees no rows');
  perform test_helpers.expect_msg(format('select public.obligation_detail(%L)', v_r), 'FORBIDDEN', 'a stranger cannot read the detail');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_error(format('update public.other_obligations set principal = 1 where id = %L', v_r), '42501', 'no direct update');
  perform test_helpers.expect_error(format('delete from public.other_obligations where id = %L', v_r), '42501', 'no direct delete');
  perform test_helpers.expect_error(format('update public.other_obligation_settlements set principal = 1 where obligation_id = %L', v_r), '42501', 'no direct settlement update');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format('delete from public.other_obligations where id = %L', v_r), null, 'an obligation cannot be deleted');
  perform test_helpers.expect_error(format('delete from public.other_obligation_settlements where obligation_id = %L', v_r), null, 'a settlement cannot be deleted');
  perform test_helpers.expect_error(format('update public.other_obligations set principal = principal + 1 where id = %L', v_r), null, 'the principal cannot be edited');
  perform test_helpers.expect_error('update public.other_obligations set status = ''open'' where status = ''void''', null, 'a void obligation cannot be re-opened by hand');
  perform test_helpers.expect_error(format('update public.other_obligation_settlements set principal = principal + 1 where obligation_id = %L', v_r), null, 'a settlement cannot be edited');
  perform test_helpers.expect_error(format('insert into public.other_obligation_settlements (entity_id, obligation_id, settlement_number, kind, settlement_date, principal, journal_id) select entity_id, id, ''OSET-X'', ''cash'', %L, 99999999999, journal_id from public.other_obligations where id = %L', test_helpers.today(pt), v_p), null, 'a settlement beyond the principal is refused by the table');
  perform test_helpers.assert((select count(*) from public.audit_events where entity_id = pt and target_table in ('other_obligations', 'other_obligation_settlements')) > 0, 'obligation changes are audited');
end
$$;

rollback;
