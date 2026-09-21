-- P6 gate (Step 15 §10, Step 16 G6): purchases and payables reconcile end to end.
-- Covers vendors, draft/submit/approve bills with server-side arithmetic and the three line treatments (expense,
-- asset, prepaid), maker-checker, duplicate detection, vendor payments (partial, exact, multi-bill, FX with gain and
-- loss), reversal, cancel/void/correct, derived status, AP aging, the AP control against the General Ledger, direct
-- expenses, evidence documents, period-close checks and authorization. All data is synthetic; dates are relative to
-- the Entity's today. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

-- Scratch space that survives role switches inside this transaction.
create table test_helpers.p6 (k text primary key, v uuid not null);
grant all on test_helpers.p6 to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p6 values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p6 where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

-- Test-only windows that work whichever role the test acts as.
create function test_helpers.mc(p_entity uuid, p_as_of date default null)
returns table (financial_account_id uuid, name text, kind text, currency text, is_active boolean,
               movement_balance numeric, movement_base_balance numeric, ledger_balance numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.money_control_rows(p_entity, p_as_of) $f$;
create function test_helpers.apc(p_entity uuid, p_as_of date default null)
returns table (sub_ledger numeric, ledger_purchases numeric, ledger_total numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.ap_control(p_entity, p_as_of) $f$;
create function test_helpers.bpos(p_entity uuid, p_as_of date default null)
returns table (bill_id uuid, bill_number text, vendor_id uuid, vendor_reference text, currency public.currency_code,
               status text, bill_date date, due_date date, total numeric, settled numeric, outstanding numeric,
               base_total numeric, base_settled numeric, base_outstanding numeric, settlement_status text,
               is_overdue boolean, days_overdue integer)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.bill_positions(p_entity, p_as_of) $f$;
grant execute on function test_helpers.mc(uuid, date), test_helpers.apc(uuid, date), test_helpers.bpos(uuid, date) to public;

-- Debit / credit of one account (by system key) inside one journal.
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
-- Ledger balance (debit - credit) of an account by system key, as of today.
create function test_helpers.bal(p_entity uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.debit - l.credit), 0)
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id and j.status = 'posted'
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = p_key $f$;
grant execute on function test_helpers.jd(uuid, text), test_helpers.jc(uuid, text), test_helpers.bal(uuid, text) to public;

-- The reconciliation invariants of the purchase layer, checked after every major step: money movements equal the
-- ledger, the AP sub-ledger equals the ledger, no bill is over-paid, every payment equals its allocations, and every
-- recognised bill's journal balances to the payable.
create function test_helpers.controls6(p_entity uuid, p_label text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $f$
declare
  c record;
begin
  if exists (select 1 from app_private.money_control_rows(p_entity) r where r.ledger_balance <> r.movement_base_balance) then
    raise exception 'TEST FAIL [%]: money movements differ from the ledger', p_label;
  end if;
  select * into c from app_private.ap_control(p_entity);
  if c.sub_ledger <> c.ledger_purchases then
    raise exception 'TEST FAIL [%]: AP sub-ledger % differs from ledger %', p_label, c.sub_ledger, c.ledger_purchases;
  end if;
  if exists (select 1 from app_private.bill_positions(p_entity) x
             where x.outstanding < 0 or x.base_outstanding < 0 or x.settled > x.total) then
    raise exception 'TEST FAIL [%]: a bill is over-paid', p_label;
  end if;
  if exists (select 1 from public.vendor_payments p where p.entity_id = p_entity and p.status = 'confirmed'
             and (select coalesce(sum(a.amount), 0) from public.vendor_payment_allocations a
                  where a.payment_id = p.id and a.status = 'active') <> p.amount) then
    raise exception 'TEST FAIL [%]: payment allocations differ from the payment', p_label;
  end if;
  if exists (select 1 from public.bills b where b.entity_id = p_entity and b.status = 'approved'
             and (select coalesce(sum(l.credit), 0) from public.journal_lines l
                  join public.ledger_accounts a on a.id = l.ledger_account_id
                  where l.journal_id = b.journal_id and a.system_key = 'ACCOUNTS_PAYABLE') <> b.base_total) then
    raise exception 'TEST FAIL [%]: a bill journal does not credit the payable by the base total', p_label;
  end if;
  if exists (select 1 from public.bills b where b.entity_id = p_entity and b.status = 'approved'
             and (select coalesce(sum(l.base_amount), 0) from public.bill_lines l where l.bill_id = b.id) <> b.base_total) then
    raise exception 'TEST FAIL [%]: the base amounts of the lines do not add up to the base total', p_label;
  end if;
end
$f$;
grant execute on function test_helpers.controls6(uuid, text) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p6_pt', 'P6 PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name)
  values ('personal', 'p6_pe', 'P6 PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);

  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000002', 'admin');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000003', 'approver');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000007', 'nobody');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000008', 'staff');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000009', 'pe_admin');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'c0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000002', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000003', 'approver');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000008', 'finance_staff');
  perform test_helpers.mk_member(v_pe, 'c0000000-0000-0000-0000-000000000009', 'finance_admin');
end
$$;

-- ================================================================ 1. vendors, categories and accounts
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  pe uuid := test_helpers.entity('p6_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_cat uuid;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.put('va', public.create_contact(pt, 'key-p6-ct-01', 'vendor', 'Vendor A', 'a@vendor.example.invalid', '+62 811-0000-0001',
    '01.234.567.8-901.000', 'PT Vendor A', 'Jl. Vendor 1', 'Bandung', 'ID'));
  perform test_helpers.put('vb', public.create_contact(pt, 'key-p6-ct-02', 'both', 'Vendor B'));
  perform test_helpers.put('vc', public.create_contact(pt, 'key-p6-ct-03', 'customer', 'Only A Customer'));
  perform test_helpers.put('vx', public.create_contact(pt, 'key-p6-ct-04', 'vendor', 'Retired Vendor'));
  perform test_helpers.put('pe_v', public.create_contact(pe, 'key-p6-ct-05', 'vendor', 'Personal Shop'));
  perform test_helpers.logout();
  update public.contacts set status = 'inactive' where id = test_helpers.g('vx');

  -- categories: an expense category mapped for the purchases context, an asset category, a revenue category (wrong kind)
  insert into public.categories (entity_id, name, kind) values (pt, 'Office Supplies', 'expense') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, debit_ledger_account_id, effective_from)
  values (pt, v_cat, 'purchases', test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE'), date '2000-01-01');
  perform test_helpers.put('cat_exp', v_cat);
  insert into public.categories (entity_id, name, kind) values (pt, 'Equipment', 'asset') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, debit_ledger_account_id, effective_from)
  values (pt, v_cat, 'purchases', test_helpers.acct(pt, 'FIXED_ASSET_EQUIPMENT'), date '2000-01-01');
  perform test_helpers.put('cat_asset', v_cat);
  insert into public.categories (entity_id, name, kind) values (pt, 'Course Sales', 'revenue') returning id into v_cat;
  perform test_helpers.put('cat_rev', v_cat);
  insert into public.categories (entity_id, name, kind, is_active) values (pt, 'Retired Expense', 'expense', false) returning id into v_cat;
  perform test_helpers.put('cat_off', v_cat);
  -- an expense category with NO mapping: the Entity default account applies
  insert into public.categories (entity_id, name, kind) values (pt, 'Unmapped Expense', 'expense') returning id into v_cat;
  perform test_helpers.put('cat_plain', v_cat);

  -- financial accounts (the owner creates the child ledger accounts)
  perform test_helpers.login(v_owner);
  perform test_helpers.put('bca', public.create_financial_account(pt, 'key-p6-fa-01', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-SECRET-777', 'PT P6'));
  perform test_helpers.put('cash', public.create_financial_account(pt, 'key-p6-fa-02', 'cash', 'Petty Cash', 'IDR', test_helpers.acct(pt, 'CASH')));
  perform test_helpers.put('usd', public.create_financial_account(pt, 'key-p6-fa-03', 'bank', 'USD Account', 'USD'));
  perform test_helpers.put('pe_bank', public.create_financial_account(pe, 'key-p6-fa-04', 'bank', 'Personal BCA', 'IDR', test_helpers.acct(pe, 'PERSONAL_BANK')));
  perform test_helpers.logout();
  insert into public.payment_channels (entity_id, method_kind, name, settlement_financial_account_id)
  values (pt, 'bank_transfer', 'Transfer BCA', test_helpers.g('bca'));
  perform test_helpers.put('chan_bca', (select id from public.payment_channels where entity_id = pt and name = 'Transfer BCA'));

  -- a vendor can be created by staff (P5's create_contact); the numbering families exist only once used
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(public.create_contact(pt, 'key-p6-ct-06', 'vendor', 'Staff Made Vendor') is not null, 'staff can create a vendor');
  perform test_helpers.logout();
  perform test_helpers.assert(not exists (select 1 from public.numbering_sequences where entity_id = pt and scope in ('bill_payment', 'expense')),
    'the payment and expense numbering families are not created before the first use');
end
$$;

-- ================================================================ 2. draft bills: server-side arithmetic and validation
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  pe uuid := test_helpers.entity('p6_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_va uuid := test_helpers.g('va');
  v_vb uuid := test_helpers.g('vb');
  v_vc uuid := test_helpers.g('vc');
  v_vx uuid := test_helpers.g('vx');
  v_today date := test_helpers.today(pt);
  v_a uuid;
  v_a2 uuid;
  b public.bills%rowtype;
  v_ver integer;
  v_lines jsonb;
begin
  perform test_helpers.login(v_staff);
  v_lines := jsonb_build_array(
    jsonb_build_object('description', 'Printer paper', 'quantity', '3', 'unit_price', '25000', 'category_id', test_helpers.g('cat_exp')),
    jsonb_build_object('description', 'Laptop', 'unit_price', '12000000', 'treatment', 'asset'),
    jsonb_build_object('description', 'Hosting prepaid, 12 months', 'unit_price', '2400000', 'treatment', 'prepaid'));
  -- the browser never supplies a total: everything is computed on the server
  v_a := public.create_bill_draft(pt, 'key-p6-b-01', v_va, v_today - 10, v_today + 20, v_lines, 'INV-A-001', null, null, 'Thanks', 'internal: hardware order');
  perform test_helpers.put('bill_a', v_a);
  perform test_helpers.assert(public.create_bill_draft(pt, 'key-p6-b-01', v_va, v_today - 10, v_today + 20, v_lines, 'INV-A-001', null, null, 'Thanks', 'internal: hardware order') = v_a,
    'creating a draft replays on the same key');
  select * into b from public.bills where id = v_a;
  perform test_helpers.assert(b.status = 'draft' and b.bill_number is null and b.journal_id is null and b.currency = 'IDR' and b.exchange_rate is null
    and b.subtotal = 14475000 and b.tax_total = 0 and b.total = 14475000 and b.base_total = 0 and b.tax_status = 'pending_engine'
    and b.vendor_reference = 'INV-A-001' and b.vendor_snapshot is null,
    'draft totals are computed: 75,000 + 12,000,000 + 2,400,000');
  perform test_helpers.assert((select array_agg(line_total::numeric order by line_no) from public.bill_lines where bill_id = v_a) = array[75000, 12000000, 2400000]::numeric[]
    and (select array_agg(treatment order by line_no) from public.bill_lines where bill_id = v_a) = array['expense', 'asset', 'prepaid']
    and (select bool_and(posted_account_id is null and base_amount is null and asset_link_status = 'none') from public.bill_lines where bill_id = v_a),
    'line totals and treatments; nothing is resolved before approval');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where source_type = 'bill' and source_id = v_a), 'a draft has no journal');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-01'', %L, %L, %L)', pt, v_va, v_today - 9, v_today + 20),
    'INVALID', 'a key cannot be reused for a different bill');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  -- header validation
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-02'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, v_vc, v_today, v_today),
    'INVALID', 'a customer-only contact cannot be billed as a vendor');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-03'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, test_helpers.g('pe_v'), v_today, v_today),
    'INVALID', 'a vendor of another Entity is refused');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-04'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, v_vx, v_today, v_today),
    'INVALID', 'an inactive vendor cannot be used for a new bill');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-05'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, v_va, v_today, v_today - 1),
    'INVALID', 'the due date cannot precede the bill date');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-06'', %L, %L, null, ''[{"description":"x","unit_price":1}]'')', pt, v_va, v_today),
    'INVALID', 'a due date is required');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-07'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', null, null, 15000)', pt, v_va, v_today, v_today),
    'INVALID', 'a base-currency bill has no rate');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-08'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', null, ''USD'')', pt, v_va, v_today, v_today),
    'INVALID', 'a foreign-currency bill needs a rate');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-09'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', null, ''ZZZ'', 1)', pt, v_va, v_today, v_today),
    'INVALID', 'unknown currency');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-10'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', null, ''USD'', 15000.12345678901)', pt, v_va, v_today, v_today),
    'INVALID', 'a rate has at most 10 decimals');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-11'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', %L)', pt, v_va, v_today, v_today, repeat('x', 101)),
    'INVALID', 'the vendor reference is limited to 100 characters');
  -- line validation
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-12'', %L, %L, %L, ''[{"description":"x","quantity":"0","unit_price":1}]'')', pt, v_va, v_today, v_today),
    'INVALID', 'a quantity must be positive');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-13'', %L, %L, %L, ''[{"description":"x","quantity":"1.00001","unit_price":1}]'')', pt, v_va, v_today, v_today),
    'INVALID', 'a quantity has at most 4 decimals');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-14'', %L, %L, %L, ''[{"description":"x","unit_price":"abc"}]'')', pt, v_va, v_today, v_today),
    'INVALID', 'a price must be a number');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-15'', %L, %L, %L, ''[{"description":"x","unit_price":"NaN"}]'')', pt, v_va, v_today, v_today),
    'INVALID', 'NaN is never a price');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-16'', %L, %L, %L, ''[{"description":"x","unit_price":-1}]'')', pt, v_va, v_today, v_today),
    'INVALID', 'a price cannot be negative');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-17'', %L, %L, %L, ''[{"description":"x","unit_price":0}]'')', pt, v_va, v_today, v_today),
    'INVALID', 'a line amount must be greater than zero');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-18'', %L, %L, %L, ''[{"unit_price":1}]'')', pt, v_va, v_today, v_today),
    'INVALID', 'a line needs a description');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-19'', %L, %L, %L, ''[{"description":"x","unit_price":1,"treatment":"gift"}]'')', pt, v_va, v_today, v_today),
    'INVALID', 'an unknown treatment is refused');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-20'', %L, %L, %L, ''[{"description":"x","unit_price":1,"category_id":"%s"}]'')', pt, v_va, v_today, v_today, test_helpers.g('cat_rev')),
    'INVALID', 'a revenue category cannot classify a purchase');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-21'', %L, %L, %L, ''[{"description":"x","unit_price":1,"category_id":"%s"}]'')', pt, v_va, v_today, v_today, test_helpers.g('cat_off')),
    'INVALID', 'an inactive category is refused');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-22'', %L, %L, %L, ''[{"description":"x","unit_price":1,"category_id":"%s","treatment":"asset"}]'')', pt, v_va, v_today, v_today, test_helpers.g('cat_exp')),
    'INVALID', 'an asset line needs an asset category');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-23'', %L, %L, %L, ''[{"description":"x","unit_price":1,"account_id":"%s"}]'')', pt, v_va, v_today, v_today, test_helpers.acct(pt, 'FIXED_ASSET_OTHER')),
    'INVALID', 'an expense line cannot name an asset account');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-24'', %L, %L, %L, ''[{"description":"x","unit_price":1,"treatment":"asset","account_id":"%s"}]'')', pt, v_va, v_today, v_today, test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE')),
    'INVALID', 'an asset line cannot name an expense account');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-25'', %L, %L, %L, ''[{"description":"x","unit_price":1,"treatment":"prepaid","account_id":"%s"}]'')', pt, v_va, v_today, v_today, test_helpers.acct(pt, 'CASH')),
    'INVALID', 'a prepaid line can only use a prepaid or deposit account');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-26'', %L, %L, %L, ''[{"description":"x","unit_price":1,"account_id":"%s"}]'')', pt, v_va, v_today, v_today, gen_random_uuid()),
    'INVALID', 'an unknown account is refused');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-27'', %L, %L, %L, ''{"a":1}'')', pt, v_va, v_today, v_today),
    'INVALID', 'lines must be a list');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-28'', %L, %L, %L, ''[{"description":"x","unit_price":1,"account_id":"not-a-uuid"}]'')', pt, v_va, v_today, v_today),
    'INVALID', 'an account identifier must be well formed');
  -- an asset line may use any active fixed-asset account, including one the OWNER added under the same parent group
  perform test_helpers.assert(public.create_bill_draft(pt, 'key-p6-b-29', v_va, v_today, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Chair', 'unit_price', 1000, 'treatment', 'asset', 'account_id', test_helpers.acct(pt, 'FIXED_ASSET_FURNITURE')))) is not null,
    'an asset line can name a fixed-asset account');
  -- rounding is half-up in the currency's minor unit, once per line
  v_a2 := public.create_bill_draft(pt, 'key-p6-b-30', v_va, v_today, v_today, '[{"description":"Rounding","quantity":"3","unit_price":"3.335"},{"description":"Half","unit_price":"10.005"}]');
  select * into b from public.bills where id = v_a2;
  perform test_helpers.assert(b.total = 10.01 + 10.01 and (select array_agg(line_total::numeric order by line_no) from public.bill_lines where bill_id = v_a2) = array[10.01, 10.01]::numeric[],
    'half-up rounding per line: 3 x 3.335 = 10.005 -> 10.01, 10.005 -> 10.01');
  perform public.cancel_bill(v_a2, 'key-p6-b-31', 'Rounding probe');
  -- the browser can never write bills directly
  perform test_helpers.expect_error(format('insert into public.bills (entity_id, vendor_id, currency, bill_date, due_date) values (%L, %L, ''IDR'', %L, %L)', pt, v_va, v_today, v_today),
    '42501', 'no direct insert into bills');
  perform test_helpers.expect_error(format('update public.bills set total = 1 where id = %L', v_a), '42501', 'no direct update of bills');
  perform test_helpers.expect_error(format('delete from public.bills where id = %L', v_a), '42501', 'no direct delete of bills');
  perform test_helpers.expect_error(format('insert into public.bill_lines (entity_id, bill_id, line_no, description, quantity, unit_price, line_subtotal, line_total) values (%L, %L, 9, ''x'', 1, 1, 1, 1)', pt, v_a),
    '42501', 'no direct insert into bill lines');
  perform test_helpers.logout();

  -- editing: only a draft, with a version check and a whitelist
  perform test_helpers.login(v_staff);
  select version into v_ver from public.bills where id = v_a;
  perform test_helpers.assert(public.update_bill_draft(v_a, jsonb_build_object('notes', 'Updated note', 'due_date', (v_today + 25)::text), v_ver) = v_ver + 1, 'update bumps the version');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"notes":"stale"}'', %s)', v_a, v_ver), 'CONFLICT', 'a stale version is refused');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"total":5}'')', v_a), 'INVALID', 'a total cannot be patched');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"status":"approved"}'')', v_a), 'INVALID', 'the status cannot be patched');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"due_date":"%s"}'')', v_a, v_today - 30), 'INVALID', 'a due date before the bill date');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"currency":"USD"}'')', v_a), 'INVALID', 'changing to a foreign currency needs a rate');
  perform test_helpers.assert((select total from public.bills where id = v_a) = 14475000 and (select due_date from public.bills where id = v_a) = v_today + 25, 'a rejected edit changes nothing');
  -- lines are replaced as a whole and re-computed
  v_a2 := public.create_bill_draft(pt, 'key-p6-b-32', v_va, v_today - 10, v_today + 20, '[{"description":"Temp","unit_price":10}]');
  perform public.update_bill_draft(v_a2, jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('description', 'Replaced', 'quantity', 3, 'unit_price', 7))));
  perform test_helpers.assert((select total from public.bills where id = v_a2) = 21 and (select count(*) from public.bill_lines where bill_id = v_a2) = 1, 'replacing the lines recomputes the total');
  perform public.update_bill_draft(v_a2, jsonb_build_object('vendor_id', v_vb, 'vendor_reference', '  REF-7  '));
  perform test_helpers.assert((select vendor_id from public.bills where id = v_a2) = v_vb and (select vendor_reference from public.bills where id = v_a2) = 'REF-7'
    and (select total from public.bills where id = v_a2) = 21, 'header edits keep the lines and trim the reference');
  perform public.cancel_bill(v_a2, 'key-p6-b-33', 'Created by mistake');
  perform test_helpers.assert((select status from public.bills where id = v_a2) = 'cancelled' and (select bill_number from public.bills where id = v_a2) is null
    and not exists (select 1 from public.journal_entries where source_id = v_a2), 'cancelling a draft has no accounting effect and uses no number');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"notes":"x"}'')', v_a2), 'CONFLICT', 'a cancelled draft cannot be edited');
  perform test_helpers.logout();

  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-b-40'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, v_va, v_today, v_today), 'FORBIDDEN', 'a viewer cannot create bills');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"notes":"x"}'')', v_a), 'FORBIDDEN', 'a viewer cannot edit');
  perform test_helpers.assert((select count(*) from public.bills where entity_id = pt) >= 2 and (select count(*) from public.bill_lines where entity_id = pt) >= 4, 'a viewer can read bills and lines');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"notes":"x"}'')', v_a), 'FORBIDDEN', 'a stranger cannot edit (same answer as not found)');
  perform test_helpers.assert((select count(*) from public.bills) = 0, 'a stranger sees no bill');
  perform test_helpers.logout();
  perform test_helpers.login('c0000000-0000-0000-0000-000000000009');
  perform test_helpers.assert((select count(*) from public.bills) = 0 and (select count(*) from public.bill_lines) = 0, 'a member of the other Entity sees no bill of this one');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"notes":"x"}'')', v_a), 'FORBIDDEN', 'a member of the other Entity cannot edit it');
  perform test_helpers.logout();
  perform test_helpers.as_anon();
  perform test_helpers.expect_error('select count(*) from public.bills', '42501', 'the anonymous role cannot read bills');
  perform test_helpers.expect_error(format('select public.approve_bill(%L, ''key-anon'')', v_a), '42501', 'the anonymous role cannot call the purchase commands');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. submit, recall, reject, approve (recognition)
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_va uuid := test_helpers.g('va');
  v_a uuid := test_helpers.g('bill_a');
  v_today date := test_helpers.today(pt);
  b public.bills%rowtype;
  v_j uuid;
  v_fut uuid;
  v_ver integer;
begin
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-ap-00'')', v_a), 'FORBIDDEN', 'staff cannot approve');
  perform test_helpers.assert(public.submit_bill(v_a, 'key-p6-ap-01') = v_a, 'staff submit the draft');
  perform test_helpers.assert((select status from public.bills where id = v_a) = 'submitted'
    and (select submitted_by from public.bills where id = v_a) = v_staff, 'the draft is now submitted by the staff member');
  perform test_helpers.assert(public.submit_bill(v_a, 'key-p6-ap-01') = v_a, 'submitting replays on the same key');
  perform test_helpers.expect_msg(format('select public.submit_bill(%L, ''key-p6-ap-02'')', v_a), 'CONFLICT', 'a submitted bill cannot be submitted again');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, ''{"notes":"late"}'')', v_a), 'CONFLICT', 'a submitted bill cannot be edited');
  perform test_helpers.expect_error(format('update public.bill_lines set unit_price = 1 where bill_id = %L', v_a), '42501', 'no direct edit of lines');
  perform test_helpers.assert(public.recall_bill(v_a) = 'draft', 'the preparer recalls a submitted bill');
  perform test_helpers.assert((select submitted_at from public.bills where id = v_a) is null, 'a recalled bill has no submission stamp');
  perform test_helpers.expect_msg(format('select public.recall_bill(%L)', v_a), 'CONFLICT', 'only a submitted bill can be recalled');
  perform public.submit_bill(v_a, 'key-p6-ap-03');
  perform test_helpers.expect_msg(format('select public.reject_bill(%L, ''no'')', v_a), 'FORBIDDEN', 'staff cannot reject');
  perform test_helpers.logout();

  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-ap-04'')', v_a), 'FORBIDDEN', 'a viewer cannot approve');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-ap-05'')', v_a), 'FORBIDDEN', 'a stranger cannot approve');
  perform test_helpers.logout();

  -- rejection sends it back with the reason
  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select public.reject_bill(%L, ''  '')', v_a), 'INVALID', 'a rejection needs a reason');
  perform test_helpers.assert(public.reject_bill(v_a, 'Attach the vendor invoice first') = 'draft', 'the approver rejects with a reason');
  perform test_helpers.assert((select reject_reason from public.bills where id = v_a) = 'Attach the vendor invoice first'
    and (select rejected_by from public.bills where id = v_a) = v_approver, 'the rejection keeps its reason and rejecter');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform public.submit_bill(v_a, 'key-p6-ap-06');
  perform test_helpers.logout();

  -- a bill dated in the future stays a draft until its date
  perform test_helpers.login(v_owner);
  v_fut := public.create_bill_draft(pt, 'key-p6-ap-07', v_va, v_today + 5, v_today + 30, '[{"description":"Future","unit_price":100}]');
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-ap-08'')', v_fut), 'INVALID', 'a future-dated bill cannot be approved');
  perform public.cancel_bill(v_fut, 'key-p6-ap-09', 'Future probe done');
  perform test_helpers.logout();

  -- approval recognises the bill once: number, snapshot, journal, resolved accounts and the asset hand-off
  perform test_helpers.login(v_approver);
  v_j := public.approve_bill(v_a, 'key-p6-ap-10');
  perform test_helpers.assert(v_j = v_a, 'approve returns the bill');
  select * into b from public.bills where id = v_a;
  perform test_helpers.assert(b.status = 'approved' and b.bill_number like 'BILL%' and b.journal_id is not null and b.base_total = 14475000
    and b.approved_by = v_approver and b.approved_at is not null and b.duplicate_ack_reason is null
    and b.vendor_snapshot ->> 'display_name' = 'Vendor A' and b.vendor_snapshot ->> 'legal_name' = 'PT Vendor A'
    and not (b.vendor_snapshot ? 'tax_identifier') and not (b.vendor_snapshot::text like '%01.234.567.8%'),
    'approved: numbered, frozen snapshot without the vendor tax identifier');
  perform test_helpers.put('j_a', b.journal_id);
  perform test_helpers.logout();  -- the ledger tables are read as a superuser: an approver cannot see them
  perform test_helpers.assert(test_helpers.jd(b.journal_id, 'OFFICE_GENERAL_EXPENSE') = 75000 and test_helpers.jd(b.journal_id, 'FIXED_ASSET_OTHER') = 12000000
    and test_helpers.jd(b.journal_id, 'PREPAID_EXPENSE') = 2400000 and test_helpers.jc(b.journal_id, 'ACCOUNTS_PAYABLE') = 14475000
    and (select count(*) from public.journal_lines where journal_id = b.journal_id) = 4,
    'Dr expense (category mapping), Dr other fixed assets (default), Dr prepaid (default), Cr Accounts Payable');
  perform test_helpers.assert((select array_agg(base_amount::numeric order by line_no) from public.bill_lines where bill_id = v_a) = array[75000, 12000000, 2400000]::numeric[]
    and (select array_agg(asset_link_status order by line_no) from public.bill_lines where bill_id = v_a) = array['none', 'linked', 'none']
    and (select bool_and(posted_account_id is not null) from public.bill_lines where bill_id = v_a), 'lines carry their posted account, base amount and the asset hand-off');
  perform test_helpers.assert((select entry_date from public.journal_entries where id = b.journal_id) = b.bill_date
    and (select source_type from public.journal_entries where id = b.journal_id) = 'bill', 'the journal is dated on the bill date and sourced from the bill');
  perform test_helpers.login(v_approver);
  perform test_helpers.assert(public.approve_bill(v_a, 'key-p6-ap-10') = v_a, 'approving replays on the same key');
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-ap-11'')', v_a), 'CONFLICT', 'an approved bill cannot be approved again');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.journal_entries where source_type = 'bill' and source_id = v_a) = 1,
    'the replay did not post a second journal');
  perform test_helpers.assert((select count(*) from public.outbox_events where aggregate_id = v_a and event_type = 'BillApproved') = 1, 'one BillApproved event');
  perform test_helpers.controls6(pt, 'after the first approval');

  -- once approved nothing but the workflow may change, even for a superuser session
  perform test_helpers.expect_error(format('update public.bills set total = 1, subtotal = 1 where id = %L', v_a), '23000', 'an approved bill is frozen');
  perform test_helpers.expect_error(format('update public.bills set vendor_id = %L where id = %L', test_helpers.g('vb'), v_a), '23000', 'the vendor of an approved bill cannot change');
  perform test_helpers.expect_error(format('update public.bill_lines set unit_price = 1 where bill_id = %L', v_a), '23000', 'the lines of an approved bill are frozen');
  perform test_helpers.expect_error(format('delete from public.bill_lines where bill_id = %L', v_a), '23000', 'lines of an approved bill cannot be deleted');
  perform test_helpers.expect_error(format('delete from public.bills where id = %L', v_a), '23000', 'a bill cannot be deleted');
  perform test_helpers.expect_error(format('update public.bills set status = ''draft'' where id = %L', v_a), '23000', 'an approved bill cannot go back to draft');
  perform test_helpers.expect_error(format('update public.bills set status = ''cancelled'', closed_at = now(), closed_date = current_date, closed_reason = ''x'' where id = %L', v_a), '23000', 'an approved bill cannot be cancelled, only voided');
  perform test_helpers.expect_error('truncate public.bills cascade', null, 'truncate is forbidden');
  perform test_helpers.expect_error(format('update public.bills set status = ''approved'', bill_number = null where id = %L', test_helpers.g('bill_a')), '23000', 'an approved bill must keep its number');
end
$$;

-- ================================================================ 4. vendor payments (base currency)
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  pe uuid := test_helpers.entity('p6_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_va uuid := test_helpers.g('va');
  v_vb uuid := test_helpers.g('vb');
  v_a uuid := test_helpers.g('bill_a');
  v_bca uuid := test_helpers.g('bca');
  v_cash uuid := test_helpers.g('cash');
  v_usd uuid := test_helpers.g('usd');
  v_today date := test_helpers.today(pt);
  v_b uuid;
  v_c uuid;
  v_d uuid;
  v_p1 uuid;
  v_p2 uuid;
  v_n integer;
begin
  -- two more bills: B (vendor B, already overdue) and C (vendor A); D stays a draft
  perform test_helpers.login(v_staff);
  v_b := public.create_bill_draft(pt, 'key-p6-b-40', v_vb, v_today - 8, v_today - 2, '[{"description":"Consulting","unit_price":3000000}]', 'VB-001');
  v_c := public.create_bill_draft(pt, 'key-p6-b-41', v_va, v_today - 3, v_today + 10, '[{"description":"Stationery","unit_price":1000000}]', 'INV-A-002');
  v_d := public.create_bill_draft(pt, 'key-p6-b-42', v_va, v_today, v_today + 10, '[{"description":"Not yet submitted","unit_price":500000}]', 'INV-A-003');
  perform public.submit_bill(v_b, 'key-p6-b-43');
  perform public.submit_bill(v_c, 'key-p6-b-44');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform public.approve_bill(v_b, 'key-p6-b-45');
  perform public.approve_bill(v_c, 'key-p6-b-46');
  perform test_helpers.logout();
  perform test_helpers.put('bill_b', v_b);
  perform test_helpers.put('bill_c', v_c);
  perform test_helpers.put('bill_d', v_d);

  -- who may pay
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-00'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'FORBIDDEN', 'staff cannot pay a bill');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-00'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'FORBIDDEN', 'an approver cannot pay a bill');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-00'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'FORBIDDEN', 'a viewer cannot pay a bill');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-00'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'FORBIDDEN', 'a stranger cannot pay a bill');
  perform test_helpers.logout();
  perform test_helpers.as_anon();
  perform test_helpers.expect_error(format('select public.record_vendor_payment(%L, ''key-p6-pay-00'', %L, %L, %L, 1000, ''[]'')', pt, v_va, v_bca, v_today), '42501', 'anonymous cannot pay');
  perform test_helpers.logout();

  perform test_helpers.login(v_admin);
  -- validation of the command itself
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-01'', %L, %L, %L, 5000000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 4000000))::text), 'INVALID', 'the payment must equal its allocations: no vendor advances');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-02'', %L, %L, %L, 14475001, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 14475001))::text), 'INVALID', 'a payment cannot exceed what is outstanding');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-03'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_bca, v_today + 1,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'INVALID', 'a payment cannot be dated in the future');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-04'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_bca, v_today - 11,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'INVALID', 'a payment cannot precede its bill');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-05'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_b, 'amount', 1000))::text), 'INVALID', 'a payment cannot settle another vendor''s bill');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-06'', %L, %L, %L, 1000, %L::jsonb, 15000)', pt, v_va, v_usd, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'INVALID', 'a USD account cannot pay an IDR bill');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-07'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_usd, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'INVALID', 'a foreign account needs a rate');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-08'', %L, %L, %L, 1000, %L::jsonb, 1)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'INVALID', 'a base-currency account takes no rate');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-09'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, gen_random_uuid(), v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'INVALID', 'an unknown paying account is refused');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-10'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, test_helpers.g('pe_bank'), v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'INVALID', 'an account of another Entity is refused');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-11'', %L, %L, %L, 2000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000), jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'INVALID', 'a bill appears once in the allocations');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-12'', %L, %L, %L, 1000, ''[]'')', pt, v_va, v_bca, v_today), 'INVALID', 'a payment needs at least one bill');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-13'', %L, %L, %L, 1000, null)', pt, v_va, v_bca, v_today), 'INVALID', 'a null list is refused');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-14'', %L, %L, %L, 500000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_d, 'amount', 500000))::text), 'CONFLICT', 'a draft bill cannot be paid');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-15'', %L, %L, %L, 0, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 0))::text), 'INVALID', 'an allocation must be positive');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-16'', %L, %L, %L, -5, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', -5))::text), 'INVALID', 'a negative payment is refused');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-17'', %L, %L, %L, 1000.005, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000.005))::text), 'INVALID', 'a payment allows only 2 decimals in rupiah');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-18'', %L, %L, %L, 1000, %L::jsonb, null, %L)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text, repeat('r', 201)), 'INVALID', 'the reference is limited to 200 characters');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-19'', %L, %L, %L, 1000, %L::jsonb, null, null, %L)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text, gen_random_uuid()), 'INVALID', 'an unknown payment channel is refused');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-20'', %L, %L, %L, 1000, %L::jsonb)', pt, test_helpers.g('vc'), v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000))::text), 'INVALID', 'a payee that is not a vendor is refused');
  perform test_helpers.logout();
end
$$;

-- ---- a first partial payment, then a payment that settles two bills at once
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_va uuid := test_helpers.g('va');
  v_a uuid := test_helpers.g('bill_a');
  v_b uuid := test_helpers.g('bill_b');
  v_c uuid := test_helpers.g('bill_c');
  v_bca uuid := test_helpers.g('bca');
  v_cash uuid := test_helpers.g('cash');
  v_today date := test_helpers.today(pt);
  v_p1 uuid;
  v_p2 uuid;
  v_alloc jsonb;
  p public.vendor_payments%rowtype;
  v_bca_la uuid;
  v_cash_la uuid;
  pos record;
  n integer;
begin
  select ledger_account_id into v_bca_la from public.financial_accounts where id = v_bca;
  select ledger_account_id into v_cash_la from public.financial_accounts where id = v_cash;
  perform test_helpers.login(v_admin);
  v_alloc := jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 5000000));
  v_p1 := public.record_vendor_payment(pt, 'key-p6-pay-30', v_va, v_bca, v_today - 5, 5000000, v_alloc, null, 'TRF-0001', test_helpers.g('chan_bca'), 'First instalment');
  perform test_helpers.put('pay_1', v_p1);
  perform test_helpers.assert(public.record_vendor_payment(pt, 'key-p6-pay-30', v_va, v_bca, v_today - 5, 5000000, v_alloc, null, 'TRF-0001', test_helpers.g('chan_bca'), 'First instalment') = v_p1,
    'recording a payment replays on the same key');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pay-30'', %L, %L, %L, 4000000, %L::jsonb)', pt, v_va, v_bca, v_today - 5,
    jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 4000000))::text), 'INVALID', 'a key cannot be reused for a different payment');
  select * into p from public.vendor_payments where id = v_p1;
  perform test_helpers.assert(p.status = 'confirmed' and p.payment_number like 'PAY%' and p.amount = 5000000 and p.base_amount = 5000000 and p.fx_difference = 0
    and p.currency = 'IDR' and p.exchange_rate is null and p.reference = 'TRF-0001' and p.vendor_id = v_va and p.payment_date = v_today - 5
    and p.payment_channel_id = test_helpers.g('chan_bca') and p.journal_id is not null and p.reversal_journal_id is null,
    'the payment is confirmed, numbered and carries its facts');
  perform test_helpers.assert((select count(*) from public.vendor_payment_allocations where payment_id = v_p1 and status = 'active' and bill_id = v_a and amount = 5000000 and base_ap_amount = 5000000) = 1,
    'one allocation, relieving the payable by the same amount');
  select * into pos from public.list_bill_positions(pt, null, null) x where x.bill_id = v_a;
  perform test_helpers.assert(pos.settled = '5000000.0000' and pos.outstanding = '9475000.0000' and pos.settlement_status = 'partial' and not pos.is_overdue,
    'the bill is partial: 5,000,000 settled, 9,475,000 outstanding, not overdue');
  perform test_helpers.logout();
  -- accounting: Dr Accounts Payable / Cr the paying account; one outbound movement; one event
  perform test_helpers.assert(test_helpers.jd(p.journal_id, 'ACCOUNTS_PAYABLE') = 5000000
    and (select coalesce(sum(credit), 0) from public.journal_lines where journal_id = p.journal_id and ledger_account_id = v_bca_la) = 5000000
    and (select count(*) from public.journal_lines where journal_id = p.journal_id) = 2, 'Dr Accounts Payable 5,000,000 / Cr BCA 5,000,000');
  perform test_helpers.assert((select source_type from public.journal_entries where id = p.journal_id) = 'vendor_payment'
    and (select entry_date from public.journal_entries where id = p.journal_id) = v_today - 5, 'the journal is sourced from the payment and dated on it');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'vendor_payment' and source_id = v_p1
    and direction = 'out' and amount = 5000000 and base_amount = 5000000 and financial_account_id = v_bca and journal_id = p.journal_id) = 1,
    'one outbound movement on the paying account');
  perform test_helpers.assert((select count(*) from public.journal_entries where source_type = 'vendor_payment' and source_id = v_p1) = 1, 'the replay posted nothing more');
  perform test_helpers.assert((select count(*) from public.outbox_events where aggregate_id = v_p1 and event_type = 'VendorPaymentConfirmed') = 1, 'one VendorPaymentConfirmed event');
  perform test_helpers.controls6(pt, 'after the first payment');

  -- one payment across two bills of the same vendor, paid from petty cash
  perform test_helpers.login(v_admin);
  v_alloc := jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 1000000), jsonb_build_object('bill_id', v_c, 'amount', 1000000));
  v_p2 := public.record_vendor_payment(pt, 'key-p6-pay-31', v_va, v_cash, v_today - 2, 2000000, v_alloc, null, 'CASH-01');
  perform test_helpers.put('pay_2', v_p2);
  perform test_helpers.assert((select count(*) from public.vendor_payment_allocations where payment_id = v_p2 and status = 'active') = 2, 'two allocations');
  perform test_helpers.assert((select payment_number from public.vendor_payments where id = v_p2) like 'PAY%'
    and (select payment_number from public.vendor_payments where id = v_p2) <> (select payment_number from public.vendor_payments where id = v_p1),
    'each payment has its own number');
  perform test_helpers.assert((select array_agg(settlement_status order by bill_number) from public.list_bill_positions(pt, null, null) where bill_id in (v_a, v_b, v_c))
    = array['partial', 'unpaid', 'paid'], 'derived status: A partial, B unpaid, C paid');
  perform test_helpers.assert((select is_overdue and days_overdue = 2 from public.list_bill_positions(pt, null, null) where bill_id = v_b), 'bill B is 2 days overdue');
  perform test_helpers.assert((select array_agg(bill_id order by bill_number) from public.list_bill_positions(pt, 'open')) = array[v_a, v_b], 'open: A and B');
  perform test_helpers.assert((select array_agg(bill_id) from public.list_bill_positions(pt, 'overdue')) = array[v_b], 'overdue: B');
  perform test_helpers.assert((select array_agg(bill_id) from public.list_bill_positions(pt, 'paid')) = array[v_c], 'paid: C');
  perform test_helpers.assert((select array_agg(bill_id) from public.list_bill_positions(pt, 'unpaid')) = array[v_b], 'unpaid: B');
  perform test_helpers.assert((select array_agg(bill_id) from public.list_bill_positions(pt, 'partial')) = array[v_a], 'partial: A');
  perform test_helpers.assert((select count(*) from public.list_bill_positions(pt, null, v_va)) = 2, 'filtered by vendor');
  perform test_helpers.expect_msg(format('select * from public.list_bill_positions(%L, ''nonsense'')', pt), 'INVALID', 'an unknown filter is refused');
  -- as of an earlier date the bill was not yet partly paid
  perform test_helpers.assert((select settled from public.list_bill_positions(pt, null, null, v_today - 6) where bill_id = v_a)::numeric = 0, 'as of six days ago nothing was paid');
  perform test_helpers.assert((select settled from public.list_bill_positions(pt, null, null, v_today - 5) where bill_id = v_a)::numeric = 5000000, 'as of the payment day it was');
  perform test_helpers.assert((select count(*) from public.list_vendor_payments(pt, v_va, null)) = 2 and (select count(*) from public.list_vendor_payments(pt, null, v_c)) = 1, 'payments list by vendor and by bill');
  perform test_helpers.logout();
  -- the AP control: 8,475,000 (A) + 3,000,000 (B) + 0 (C)
  perform test_helpers.assert((select sub_ledger from test_helpers.apc(pt)) = 11475000 and (select ledger_purchases from test_helpers.apc(pt)) = 11475000, 'the AP sub-ledger equals the ledger: 11,475,000');
  perform test_helpers.assert((select sub_ledger from test_helpers.apc(pt, v_today - 6)) = 17475000 and (select ledger_purchases from test_helpers.apc(pt, v_today - 6)) = 17475000,
    'as of six days ago A and B were recognised and nothing paid: 17,475,000 on both sides');
  perform test_helpers.controls6(pt, 'after the multi-bill payment');
  perform test_helpers.assert((select ledger_balance from test_helpers.mc(pt) where financial_account_id = v_bca) = -5000000
    and (select ledger_balance from test_helpers.mc(pt) where financial_account_id = v_cash) = -2000000, 'the paying accounts went down by what was paid');

  -- reading is for people who may see bills only
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.vendor_payments where entity_id = pt) = 2 and (select count(*) from public.list_bill_positions(pt)) = 3, 'a viewer sees payments and positions');
  perform test_helpers.expect_error(format('update public.vendor_payments set amount = 1 where id = %L', v_p1), '42501', 'no direct update of a payment');
  perform test_helpers.expect_error(format('insert into public.vendor_payment_allocations (entity_id, payment_id, bill_id, amount, base_ap_amount, allocation_date) values (%L, %L, %L, 1, 1, current_date)', pt, v_p1, v_a), '42501', 'no direct allocation');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.assert((select count(*) from public.vendor_payments) = 0, 'a stranger sees no payments');
  perform test_helpers.expect_msg(format('select * from public.list_bill_positions(%L)', pt), 'FORBIDDEN', 'a stranger cannot list positions');
  perform test_helpers.expect_msg(format('select * from public.list_vendor_payments(%L)', pt), 'FORBIDDEN', 'a stranger cannot list payments');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 5. foreign-currency bills and payments
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_vb uuid := test_helpers.g('vb');
  v_usd uuid := test_helpers.g('usd');
  v_today date := test_helpers.today(pt);
  v_usd_la uuid;
  v_d uuid;
  v_e uuid;
  v_p uuid;
  p public.vendor_payments%rowtype;
  b public.bills%rowtype;
  v_fx_before numeric;
  v_sum numeric;
begin
  select ledger_account_id into v_usd_la from public.financial_accounts where id = v_usd;
  v_fx_before := test_helpers.bal(pt, 'FX_GAIN_LOSS');
  perform test_helpers.login(v_staff);
  v_d := public.create_bill_draft(pt, 'key-p6-fx-01', v_vb, v_today - 4, v_today + 26, '[{"description":"Cloud services","unit_price":1000}]', 'USD-INV-1', 'USD', 15000);
  perform public.submit_bill(v_d, 'key-p6-fx-02');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform public.approve_bill(v_d, 'key-p6-fx-03');
  perform test_helpers.logout();
  perform test_helpers.put('bill_usd', v_d);
  select * into b from public.bills where id = v_d;
  perform test_helpers.assert(b.currency = 'USD' and b.total = 1000 and b.exchange_rate = 15000 and b.base_total = 15000000 and b.status = 'approved',
    'a USD bill of 1,000 at 15,000 is worth 15,000,000 in rupiah');
  perform test_helpers.assert(test_helpers.jc(b.journal_id, 'ACCOUNTS_PAYABLE') = 15000000
    and (select bool_and(original_currency = 'USD' and original_amount = 1000 and exchange_rate = 15000) from public.journal_lines l
         join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = b.journal_id and a.system_key = 'ACCOUNTS_PAYABLE'),
    'the payable line keeps its original amount and rate');

  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-fx-04'', %L, %L, %L, 600, %L::jsonb, 30000)', pt, v_vb, v_usd, v_today - 3,
    jsonb_build_array(jsonb_build_object('bill_id', v_d, 'amount', 600))::text), 'INVALID', 'an absurd rate (payable relieved 9,000,000, cash 18,000,000) is refused');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-fx-05'', %L, %L, %L, 600, %L::jsonb, 0)', pt, v_vb, v_usd, v_today - 3,
    jsonb_build_array(jsonb_build_object('bill_id', v_d, 'amount', 600))::text), 'INVALID', 'a rate of zero is refused');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-fx-06'', %L, %L, %L, 600, %L::jsonb, 15000.12345678901)', pt, v_vb, v_usd, v_today - 3,
    jsonb_build_array(jsonb_build_object('bill_id', v_d, 'amount', 600))::text), 'INVALID', 'a rate has at most 10 decimals');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-fx-07'', %L, %L, %L, 600, %L::jsonb, 15000)', pt, v_vb, test_helpers.g('bca'), v_today - 3,
    jsonb_build_array(jsonb_build_object('bill_id', v_d, 'amount', 600))::text), 'INVALID', 'a rupiah account cannot pay a USD bill');

  -- 400 USD at 15,200: cash 6,080,000 against 6,000,000 of payable -> a loss of 80,000
  v_p := public.record_vendor_payment(pt, 'key-p6-fx-08', v_vb, v_usd, v_today - 3, 400, jsonb_build_array(jsonb_build_object('bill_id', v_d, 'amount', 400)), 15200, 'SWIFT-1');
  perform test_helpers.put('pay_usd1', v_p);
  select * into p from public.vendor_payments where id = v_p;
  perform test_helpers.assert(p.currency = 'USD' and p.amount = 400 and p.exchange_rate = 15200 and p.base_amount = 6080000 and p.fx_difference = -80000,
    'payment 1: 400 USD, cash 6,080,000, difference -80,000 (loss)');
  perform test_helpers.assert((select base_ap_amount from public.vendor_payment_allocations where payment_id = v_p) = 6000000, 'the payable is relieved at the bill''s rate: 6,000,000');
  perform test_helpers.assert((select settled::numeric = 400 and outstanding::numeric = 600 and base_outstanding::numeric = 9000000 and settlement_status = 'partial'
    from public.list_bill_positions(pt, null, v_vb) where bill_id = v_d), 'after payment 1: 400 settled, 600 (9,000,000) outstanding');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jd(p.journal_id, 'ACCOUNTS_PAYABLE') = 6000000 and test_helpers.jd(p.journal_id, 'FX_GAIN_LOSS') = 80000
    and (select coalesce(sum(credit), 0) from public.journal_lines where journal_id = p.journal_id and ledger_account_id = v_usd_la) = 6080000,
    'Dr Accounts Payable 6,000,000 + Dr FX loss 80,000 / Cr USD account 6,080,000');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'vendor_payment' and source_id = v_p
    and direction = 'out' and amount = 400 and base_amount = 6080000 and exchange_rate = 15200) = 1, 'one outbound USD movement at the payment rate');
  perform test_helpers.controls6(pt, 'after the first USD payment');

  -- 600 USD at 14,900: cash 8,940,000 against 9,000,000 of payable -> a gain of 60,000
  perform test_helpers.login(v_admin);
  v_p := public.record_vendor_payment(pt, 'key-p6-fx-09', v_vb, v_usd, v_today - 1, 600, jsonb_build_array(jsonb_build_object('bill_id', v_d, 'amount', 600)), 14900);
  perform test_helpers.put('pay_usd2', v_p);
  select * into p from public.vendor_payments where id = v_p;
  perform test_helpers.assert(p.base_amount = 8940000 and p.fx_difference = 60000, 'payment 2: cash 8,940,000, difference +60,000 (gain)');
  perform test_helpers.assert((select base_ap_amount from public.vendor_payment_allocations where payment_id = v_p) = 9000000, 'the last payment relieves exactly what remains: 9,000,000');
  perform test_helpers.assert((select settlement_status = 'paid' and base_outstanding::numeric = 0 from public.list_bill_positions(pt, null, v_vb) where bill_id = v_d), 'the USD bill is paid');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-fx-10'', %L, %L, %L, 1, %L::jsonb, 15000)', pt, v_vb, v_usd, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_d, 'amount', 1))::text), 'INVALID', 'a paid bill cannot be over-paid');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jc(p.journal_id, 'FX_GAIN_LOSS') = 60000 and test_helpers.jd(p.journal_id, 'ACCOUNTS_PAYABLE') = 9000000, 'Cr FX gain 60,000, Dr Accounts Payable 9,000,000');
  perform test_helpers.assert(test_helpers.bal(pt, 'FX_GAIN_LOSS') - v_fx_before = 20000, 'net FX: a loss of 80,000 and a gain of 60,000 leave a net loss of 20,000');
  perform test_helpers.assert((select ledger_balance from test_helpers.mc(pt) where financial_account_id = v_usd) = -15020000
    and (select movement_balance from test_helpers.mc(pt) where financial_account_id = v_usd) = -1000, 'the USD account: -1,000 USD, -15,020,000 in rupiah');
  perform test_helpers.controls6(pt, 'after the USD bill is paid');

  -- three partial payments over an awkward base amount: the pieces add up to the bill exactly
  perform test_helpers.login(v_staff);
  v_e := public.create_bill_draft(pt, 'key-p6-fx-11', v_vb, v_today - 4, v_today + 26, '[{"description":"Odd rate","unit_price":100}]', 'USD-INV-2', 'USD', 15333.3333);
  perform public.submit_bill(v_e, 'key-p6-fx-12');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform public.approve_bill(v_e, 'key-p6-fx-13');
  perform test_helpers.logout();
  select * into b from public.bills where id = v_e;
  perform test_helpers.assert(b.base_total = 1533333.33, 'the base total rounds once: 100 x 15,333.3333 = 1,533,333.33');
  perform test_helpers.login(v_admin);
  perform public.record_vendor_payment(pt, 'key-p6-fx-14', v_vb, v_usd, v_today - 3, 33.33, jsonb_build_array(jsonb_build_object('bill_id', v_e, 'amount', 33.33)), 15333.3333);
  perform public.record_vendor_payment(pt, 'key-p6-fx-15', v_vb, v_usd, v_today - 2, 33.33, jsonb_build_array(jsonb_build_object('bill_id', v_e, 'amount', 33.33)), 15333.3333);
  perform test_helpers.assert((select base_outstanding::numeric > 0 and settled::numeric = 66.66 from public.list_bill_positions(pt, null, v_vb) where bill_id = v_e), 'two thirds paid, something still outstanding');
  perform public.record_vendor_payment(pt, 'key-p6-fx-16', v_vb, v_usd, v_today - 1, 33.34, jsonb_build_array(jsonb_build_object('bill_id', v_e, 'amount', 33.34)), 15333.3333);
  perform test_helpers.logout();
  select coalesce(sum(a.base_ap_amount), 0) into v_sum from public.vendor_payment_allocations a where a.bill_id = v_e and a.status = 'active';
  perform test_helpers.assert(v_sum = 1533333.33, 'the three allocations relieve the payable by exactly the base total');
  perform test_helpers.assert((select x.settlement_status = 'paid' and x.base_outstanding = 0 and x.outstanding = 0 from test_helpers.bpos(pt) x where x.bill_id = v_e), 'the odd-rate bill is fully paid with no residue');
  perform test_helpers.controls6(pt, 'after the odd-rate bill is paid');
end
$$;

-- ================================================================ 6. reversing a payment
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_va uuid := test_helpers.g('va');
  v_a uuid := test_helpers.g('bill_a');
  v_c uuid := test_helpers.g('bill_c');
  v_cash uuid := test_helpers.g('cash');
  v_bca uuid := test_helpers.g('bca');
  v_p1 uuid := test_helpers.g('pay_1');
  v_p2 uuid := test_helpers.g('pay_2');
  v_today date := test_helpers.today(pt);
  v_rev uuid;
  v_p3 uuid;
  p public.vendor_payments%rowtype;
  d date;
  k integer;
begin
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-rv-00'', %L, ''Wrong account used'')', v_p2, v_today - 1), 'FORBIDDEN', 'staff cannot reverse a payment');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-rv-00'', %L, ''Wrong account used'')', v_p2, v_today - 1), 'FORBIDDEN', 'a viewer cannot reverse a payment');
  perform test_helpers.logout();

  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-rv-01'', %L, ''no'')', v_p2, v_today - 1), 'INVALID', 'a reversal needs a reason of 5 characters');
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-rv-02'', %L, ''Wrong account used'')', v_p2, v_today + 1), 'INVALID', 'a reversal cannot be dated in the future');
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-rv-03'', %L, ''Wrong account used'')', v_p2, v_today - 3), 'INVALID', 'a reversal cannot precede the payment');
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-rv-04'', null, ''Wrong account used'')', v_p2), 'INVALID', 'a reversal needs a date');
  v_rev := public.reverse_vendor_payment(v_p2, 'key-p6-rv-05', v_today - 1, 'Wrong account used');
  perform test_helpers.assert(public.reverse_vendor_payment(v_p2, 'key-p6-rv-05', v_today - 1, 'Wrong account used') = v_rev, 'reversing replays on the same key');
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-rv-06'', %L, ''Wrong account used'')', v_p2, v_today - 1), 'CONFLICT', 'a payment is reversed only once');
  select * into p from public.vendor_payments where id = v_p2;
  perform test_helpers.assert(p.status = 'reversed' and p.reversal_journal_id = v_rev and p.reversed_date = v_today - 1 and p.reverse_reason = 'Wrong account used' and p.reversed_by = v_admin,
    'the payment is reversed with its date, reason and actor');
  perform test_helpers.assert((select count(*) from public.vendor_payment_allocations where payment_id = v_p2 and status = 'reversed' and reversal_journal_id = v_rev) = 2, 'both allocations are reversed');
  -- the bills are exactly as before the payment, on the day of the reversal and after
  perform test_helpers.assert((select settlement_status = 'unpaid' and outstanding::numeric = 1000000 from public.list_bill_positions(pt) where bill_id = v_c), 'bill C is unpaid again');
  perform test_helpers.assert((select settled::numeric = 5000000 and settlement_status = 'partial' from public.list_bill_positions(pt) where bill_id = v_a), 'bill A is back to 5,000,000 settled');
  -- history is kept: on the payment day (before the reversal) bill C was still paid
  perform test_helpers.assert((select settled::numeric = 1000000 and settlement_status = 'paid' from public.list_bill_positions(pt, null, null, v_today - 2) where bill_id = v_c), 'as of the payment day C was paid');
  perform test_helpers.assert((select settled::numeric = 0 from public.list_bill_positions(pt, null, null, v_today - 1) where bill_id = v_c), 'as of the reversal day C is unpaid');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jc(v_rev, 'ACCOUNTS_PAYABLE') = 2000000
    and (select reverses_journal_id from public.journal_entries where id = v_rev) = p.journal_id
    and (select entry_date from public.journal_entries where id = v_rev) = v_today - 1, 'a linked reversal journal: Cr Accounts Payable 2,000,000, dated on the reversal');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'vendor_payment' and source_id = v_p2 and direction = 'in' and amount = 2000000
    and financial_account_id = v_cash and reverses_movement_id is not null) = 1, 'the movement is mirrored back into the petty cash');
  perform test_helpers.assert((select ledger_balance = 0 and movement_balance = 0 from test_helpers.mc(pt) where financial_account_id = v_cash), 'the petty cash is back to zero');
  perform test_helpers.controls6(pt, 'after reversing the multi-bill payment');
  -- the sub-ledger and the ledger agree on every day, not only today
  for k in 0 .. 12 loop
    d := v_today - k;
    perform test_helpers.assert((select sub_ledger = ledger_purchases from test_helpers.apc(pt, d)), 'AP control agrees as of ' || d::text);
  end loop;

  -- pay bill C again, this time from the bank
  perform test_helpers.login(v_admin);
  v_p3 := public.record_vendor_payment(pt, 'key-p6-rv-07', v_va, v_bca, v_today, 1000000, jsonb_build_array(jsonb_build_object('bill_id', v_c, 'amount', 1000000)), null, 'TRF-0002');
  perform test_helpers.put('pay_3', v_p3);
  perform test_helpers.assert((select settlement_status = 'paid' from public.list_bill_positions(pt) where bill_id = v_c), 'C is paid by the second attempt');
  perform test_helpers.assert((select count(*) from public.vendor_payments where entity_id = pt and status = 'reversed') = 1, 'the reversed payment stays on record');

  -- reverse the first payment (5,000,000) on a later day than it was made
  v_rev := public.reverse_vendor_payment(v_p1, 'key-p6-rv-08', v_today - 4, 'Vendor returned the transfer');
  perform test_helpers.assert((select settlement_status = 'unpaid' and outstanding::numeric = 14475000 from public.list_bill_positions(pt) where bill_id = v_a), 'A is unpaid: 14,475,000 outstanding');
  perform test_helpers.logout();
  perform test_helpers.assert((select ledger_balance = -1000000 and movement_balance = -1000000 from test_helpers.mc(pt) where financial_account_id = v_bca), 'the bank account holds only the one live payment: -1,000,000');
  perform test_helpers.controls6(pt, 'after reversing the first payment');
  for k in 0 .. 12 loop
    d := v_today - k;
    perform test_helpers.assert((select sub_ledger = ledger_purchases from test_helpers.apc(pt, d)), 'AP control still agrees as of ' || d::text);
  end loop;
  -- a reversed payment can never change, and neither can its allocations
  perform test_helpers.expect_error(format('update public.vendor_payments set note = ''x'' where id = %L', v_p1), '23000', 'a reversed payment is frozen');
  perform test_helpers.expect_error(format('update public.vendor_payment_allocations set amount = 1 where payment_id = %L', v_p1), '23000', 'a reversed allocation is frozen');
  perform test_helpers.expect_error(format('update public.vendor_payments set amount = 1 where id = %L', v_p3), '23000', 'the facts of a confirmed payment are frozen');
  perform test_helpers.expect_error(format('delete from public.vendor_payments where id = %L', v_p3), '23000', 'a payment cannot be deleted');
  perform test_helpers.expect_error(format('delete from public.vendor_payment_allocations where payment_id = %L', v_p3), '23000', 'an allocation cannot be deleted');
  perform test_helpers.expect_error('truncate public.vendor_payments cascade', null, 'a payment table cannot be truncated');
  perform test_helpers.expect_error('truncate public.vendor_payment_allocations', null, 'the allocation table cannot be truncated');
end
$$;

-- ================================================================ 7. due date, cancel, void and correct
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_va uuid := test_helpers.g('va');
  v_vb uuid := test_helpers.g('vb');
  v_a uuid := test_helpers.g('bill_a');
  v_b uuid := test_helpers.g('bill_b');
  v_d uuid := test_helpers.g('bill_d');
  v_today date := test_helpers.today(pt);
  b public.bills%rowtype;
  v_bn text;
  v_x uuid;
  v_y uuid;
  v_p4 uuid;
  v_new uuid;
  v_ver integer;
  v_j uuid;
begin
  -- ---- the due date is the one commercial term that may change after approval
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.update_bill_due_date(%L, %L, ''Vendor agreed'')', v_a, v_today - 1), 'FORBIDDEN', 'a viewer cannot change a due date');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.update_bill_due_date(%L, %L, ''x'')', v_a, v_today - 1), 'INVALID', 'a due-date change needs a reason');
  perform test_helpers.expect_msg(format('select public.update_bill_due_date(%L, null, ''Vendor agreed'')', v_a), 'INVALID', 'a due-date change needs a date');
  perform test_helpers.expect_msg(format('select public.update_bill_due_date(%L, %L, ''Vendor agreed'')', v_a, v_today - 11), 'INVALID', 'the due date cannot precede the bill date');
  perform test_helpers.expect_msg(format('select public.update_bill_due_date(%L, %L, ''Vendor agreed'')', v_d, v_today), 'CONFLICT', 'only an approved bill has its due date changed here');
  perform test_helpers.assert(public.update_bill_due_date(v_a, v_today - 1, 'Vendor agreed to an earlier due date') = v_today - 1, 'the due date changes');
  perform test_helpers.assert((select is_overdue and days_overdue = 1 from public.list_bill_positions(pt) where bill_id = v_a), 'A is now one day overdue');
  perform public.update_bill_due_date(v_a, v_today, 'Due today is not late yet');
  perform test_helpers.assert((select not is_overdue and days_overdue = 0 from public.list_bill_positions(pt) where bill_id = v_a), 'a bill due today is not overdue');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.audit_events where target_id = v_a and reason = 'Vendor agreed to an earlier due date') = 1, 'the reason is in the audit trail');
  perform test_helpers.assert((select total = 14475000 and base_total = 14475000 from public.bills where id = v_a), 'the frozen figures are unaffected');
  perform test_helpers.login(v_admin);
  perform public.update_bill_due_date(v_a, v_today + 20, 'Back to the agreed term');
  perform test_helpers.logout();

  -- ---- cancelling: a draft by its preparer, a submitted bill only by someone who may void; approved bills are voided
  perform test_helpers.login(v_staff);
  v_x := public.create_bill_draft(pt, 'key-p6-cv-01', v_va, v_today, v_today + 5, '[{"description":"Mistake","unit_price":1000}]', 'INV-X-1');
  v_y := public.create_bill_draft(pt, 'key-p6-cv-02', v_va, v_today, v_today + 5, '[{"description":"Mistake 2","unit_price":2000}]', 'INV-X-2');
  perform public.submit_bill(v_y, 'key-p6-cv-03');
  perform test_helpers.expect_msg(format('select public.cancel_bill(%L, ''key-p6-cv-04'', ''no'')', v_x), 'INVALID', 'a cancellation needs a reason');
  perform test_helpers.expect_msg(format('select public.cancel_bill(%L, ''key-p6-cv-05'', ''Submitted by mistake'')', v_y), 'FORBIDDEN', 'staff cannot cancel a submitted bill (recall it instead)');
  perform test_helpers.expect_msg(format('select public.cancel_bill(%L, ''key-p6-cv-06'', ''Cancelling an approved one'')', v_a), 'FORBIDDEN', 'staff cannot cancel an approved bill');
  perform test_helpers.assert(public.cancel_bill(v_x, 'key-p6-cv-07', 'Entered by mistake') = v_x, 'staff cancel their own draft');
  perform test_helpers.assert(public.cancel_bill(v_x, 'key-p6-cv-07', 'Entered by mistake') = v_x, 'cancelling replays on the same key');
  perform test_helpers.logout();
  select * into b from public.bills where id = v_x;
  perform test_helpers.assert(b.status = 'cancelled' and b.bill_number is null and b.journal_id is null and b.closed_reason = 'Entered by mistake' and b.closed_by = v_staff, 'a cancelled draft never had a number or a journal');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.cancel_bill(%L, ''key-p6-cv-08'', ''Cancelling an approved one'')', v_a), 'CONFLICT', 'an approved bill is voided, not cancelled');
  perform test_helpers.expect_msg(format('select public.cancel_bill(%L, ''key-p6-cv-09'', ''Already cancelled'')', v_x), 'CONFLICT', 'a cancelled bill cannot be cancelled again');
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-cv-10'', ''Voiding a draft here'')', v_d), 'CONFLICT', 'only an approved bill can be voided');
  perform test_helpers.assert(public.cancel_bill(v_y, 'key-p6-cv-11', 'Submitted by mistake') = v_y, 'the owner cancels a submitted bill');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.journal_entries where source_id in (v_x, v_y)) = 0, 'cancelling leaves no accounting trace');
end
$$;

-- ---- voiding and correcting approved bills
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_va uuid := test_helpers.g('va');
  v_vb uuid := test_helpers.g('vb');
  v_a uuid := test_helpers.g('bill_a');
  v_b uuid := test_helpers.g('bill_b');
  v_c uuid := test_helpers.g('bill_c');
  v_bca uuid := test_helpers.g('bca');
  v_today date := test_helpers.today(pt);
  b public.bills%rowtype;
  r public.bills%rowtype;
  v_p4 uuid;
  v_rev uuid;
  v_new uuid;
  k integer;
  d date;
begin
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-vd-01'', ''Duplicate of another bill'')', v_b), 'FORBIDDEN', 'a finance admin cannot void a bill');
  perform test_helpers.expect_msg(format('select public.correct_bill(%L, ''key-p6-vd-02'', ''Wrong amount typed'')', v_b), 'FORBIDDEN', 'nor correct one');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-vd-03'', ''Duplicate of another bill'')', v_b), 'FORBIDDEN', 'staff cannot void a bill');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-vd-04'', ''no'')', v_b), 'INVALID', 'voiding needs a reason');
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-vd-05'', ''Duplicate of another bill'', %L)', v_b, v_today + 1), 'INVALID', 'a void cannot be dated in the future');
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-vd-06'', ''Duplicate of another bill'', %L)', v_b, v_today - 9), 'INVALID', 'a void cannot precede the bill');
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-vd-07'', ''Paid bill, cannot void'')', v_c), 'CONFLICT', 'a bill with a live payment cannot be voided');
  perform test_helpers.assert(public.void_bill(v_b, 'key-p6-vd-08', 'Duplicate of another bill') = v_b, 'the owner voids an unpaid bill');
  perform test_helpers.assert(public.void_bill(v_b, 'key-p6-vd-08', 'Duplicate of another bill') = v_b, 'voiding replays on the same key');
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-vd-09'', ''Duplicate of another bill'')', v_b), 'CONFLICT', 'a void bill cannot be voided again');
  perform test_helpers.logout();
  select * into b from public.bills where id = v_b;
  perform test_helpers.assert(b.status = 'void' and b.reversal_journal_id is not null and b.closed_date = v_today and b.closed_by = v_owner and b.closed_reason = 'Duplicate of another bill'
    and b.bill_number is not null, 'a void bill keeps its number and links its reversal');
  perform test_helpers.assert((select reverses_journal_id from public.journal_entries where id = b.reversal_journal_id) = b.journal_id
    and test_helpers.jd(b.reversal_journal_id, 'ACCOUNTS_PAYABLE') = 3000000, 'the reversal debits the payable by 3,000,000');
  perform test_helpers.login(v_admin);
  perform test_helpers.assert((select status = 'void' and outstanding::numeric = 0 and settlement_status is null and not is_overdue from public.list_bill_positions(pt) where bill_id = v_b),
    'today the voided bill is closed: nothing outstanding and no longer overdue');
  perform test_helpers.assert((select status = 'approved' and outstanding::numeric = 3000000 and is_overdue from public.list_bill_positions(pt, null, null, v_today - 1) where bill_id = v_b),
    'yesterday it was still an approved, overdue bill');
  perform test_helpers.assert((select array_agg(bill_id) from public.list_bill_positions(pt, 'closed')) = array[v_b], 'closed: the voided bill');
  perform test_helpers.assert(not exists (select 1 from public.list_bill_positions(pt, 'open') where bill_id = v_b), 'a voided bill is not open');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-vd-10'', %L, %L, %L, 1000, %L::jsonb)', pt, v_vb, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_b, 'amount', 1000))::text), 'CONFLICT', 'a voided bill cannot be paid');
  -- pay bill A again, then try to void or correct it while the payment stands
  v_p4 := public.record_vendor_payment(pt, 'key-p6-vd-11', v_va, v_bca, v_today - 1, 2000000, jsonb_build_array(jsonb_build_object('bill_id', v_a, 'amount', 2000000)), null, 'TRF-0003');
  perform test_helpers.logout();
  perform test_helpers.controls6(pt, 'after voiding bill B');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-vd-12'', ''Wrong vendor invoice'')', v_a), 'CONFLICT', 'a partly paid bill cannot be voided');
  perform test_helpers.expect_msg(format('select public.correct_bill(%L, ''key-p6-vd-13'', ''Wrong vendor invoice'')', v_a), 'CONFLICT', 'nor corrected');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  v_rev := public.reverse_vendor_payment(v_p4, 'key-p6-vd-14', v_today, 'Paid the wrong bill');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-vd-15'', ''Wrong vendor invoice'', %L)', v_a, v_today - 1), 'INVALID',
    'a void cannot be dated before the last payment activity (the payable would go negative in between)');

  -- correcting: the original is voided, a draft copy points back to it
  v_new := public.correct_bill(v_a, 'key-p6-vd-16', 'Wrong vendor invoice');
  perform test_helpers.assert(public.correct_bill(v_a, 'key-p6-vd-16', 'Wrong vendor invoice') = v_new, 'correcting replays on the same key');
  perform test_helpers.expect_msg(format('select public.correct_bill(%L, ''key-p6-vd-17'', ''Wrong vendor invoice'')', v_a), 'CONFLICT', 'a bill is corrected once');
  perform test_helpers.put('bill_r', v_new);
  perform test_helpers.logout();
  select * into b from public.bills where id = v_a;
  select * into r from public.bills where id = v_new;
  perform test_helpers.assert(b.status = 'void' and b.replaced_by_bill_id = v_new and b.reversal_journal_id is not null and b.closed_reason = 'Wrong vendor invoice',
    'the original is void and points at its replacement');
  perform test_helpers.assert(r.status = 'draft' and r.replaces_bill_id = v_a and r.bill_number is null and r.vendor_id = v_va and r.vendor_reference = 'INV-A-001'
    and r.total = 14475000 and r.bill_date = b.bill_date and r.internal_note like 'Replaces %', 'the replacement is a draft copy that points back');
  perform test_helpers.assert((select array_agg(description || ':' || treatment order by line_no) from public.bill_lines where bill_id = v_new)
    = (select array_agg(description || ':' || treatment order by line_no) from public.bill_lines where bill_id = v_a), 'with the same lines and treatments');
  perform test_helpers.assert((select coalesce(sum(l.credit - l.debit), 0) from public.journal_lines l join public.ledger_accounts x on x.id = l.ledger_account_id
    where l.journal_id in (b.journal_id, b.reversal_journal_id) and x.system_key = 'ACCOUNTS_PAYABLE') = 0, 'the original and its reversal net to zero on the payable');
  perform test_helpers.controls6(pt, 'after correcting bill A');
  for k in 0 .. 12 loop
    d := v_today - k;
    perform test_helpers.assert((select sub_ledger = ledger_purchases from test_helpers.apc(pt, d)), 'AP control agrees after the void, as of ' || d::text);
  end loop;

  -- the preparer fixes the amount; approval does not see the voided original as a duplicate
  perform test_helpers.login(v_staff);
  select version into r.version from public.bills where id = v_new;
  perform public.update_bill_draft(v_new, '{"lines":[{"description":"Laptop (corrected)","unit_price":11500000,"treatment":"asset"}]}'::jsonb, r.version);
  perform public.submit_bill(v_new, 'key-p6-vd-18');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform public.approve_bill(v_new, 'key-p6-vd-19');
  perform test_helpers.logout();
  select * into r from public.bills where id = v_new;
  perform test_helpers.assert(r.status = 'approved' and r.bill_number is not null and r.bill_number <> b.bill_number and r.total = 11500000 and r.duplicate_ack_reason is null,
    'the replacement approves under a new number without a duplicate acknowledgement');
  perform test_helpers.controls6(pt, 'after approving the replacement');
end
$$;

-- ================================================================ 8. duplicate detection on bills
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_va uuid := test_helpers.g('va');
  v_vb uuid := test_helpers.g('vb');
  v_c uuid := test_helpers.g('bill_c');
  v_today date := test_helpers.today(pt);
  v_f uuid;
  v_g uuid;
  v_h uuid;
  b public.bills%rowtype;
  n integer;
begin
  perform test_helpers.login(v_staff);
  -- same vendor, same number apart from case and spaces
  v_f := public.create_bill_draft(pt, 'key-p6-du-01', v_va, v_today, v_today + 10, '[{"description":"Stationery again","unit_price":1000000}]', '  inv-a-002 ');
  v_g := public.create_bill_draft(pt, 'key-p6-du-02', v_vb, v_today, v_today + 10, '[{"description":"Other vendor, same number","unit_price":700000}]', 'INV-A-002');
  v_h := public.create_bill_draft(pt, 'key-p6-du-03', v_va, v_today, v_today + 10, '[{"description":"Same date and total, other number","unit_price":1000000}]', 'INV-H-1');
  perform public.submit_bill(v_f, 'key-p6-du-04');
  perform public.submit_bill(v_g, 'key-p6-du-05');
  perform public.submit_bill(v_h, 'key-p6-du-06');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-du-07'')', v_f), 'CONFLICT', 'the same vendor number twice is refused without a reason');
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-du-08'', ''ok'')', v_f), 'CONFLICT', 'a reason of two characters is not a reason');
  perform test_helpers.assert(public.approve_bill(v_g, 'key-p6-du-09') = v_g, 'the same number from a different vendor is not a duplicate');
  perform test_helpers.assert(public.approve_bill(v_f, 'key-p6-du-10', 'Second order on the same invoice number') = v_f, 'a stated reason lets the second document through');
  select * into b from public.bills where id = v_f;
  perform test_helpers.assert(b.status = 'approved' and b.duplicate_ack_reason = 'Second order on the same invoice number', 'the reason stays with the bill');
  -- a likely duplicate (same vendor, date, currency, total) is shown but does not block
  perform test_helpers.assert(public.approve_bill(v_h, 'key-p6-du-11') = v_h, 'same vendor, date and total under another number is only a hint');
  perform test_helpers.assert((select duplicate_ack_reason is null from public.bills where id = v_h), 'no reason is recorded when none was needed');
  perform test_helpers.logout();

  -- the finder works before anything is saved
  perform test_helpers.login(v_viewer);
  select count(*) into n from public.find_purchase_duplicates(pt, v_va, null, 'INV-A-002');
  perform test_helpers.assert(n = 2, 'exact: the same number, matching the paid bill C and the acknowledged bill F');
  perform test_helpers.assert((select severity from public.find_purchase_duplicates(pt, v_va, null, 'INV-A-002') order by severity limit 1) = 'exact', 'an exact match is labelled exact');
  perform test_helpers.assert((select count(*) from public.find_purchase_duplicates(pt, v_va, null, 'INV-A-002', null, null, null, 'bill', v_f)) = 1, 'a document is never its own duplicate');
  perform test_helpers.assert((select array_agg(doc_id) from public.find_purchase_duplicates(pt, v_va, null, 'INV-NEW', v_today, 'IDR', 1000000)) @> array[v_f, v_h], 'likely: same vendor, date, currency and total');
  perform test_helpers.assert((select bool_and(severity = 'likely') from public.find_purchase_duplicates(pt, v_va, null, 'INV-NEW', v_today, 'IDR', 1000000)), 'without the same number they are only likely');
  perform test_helpers.assert((select count(*) from public.find_purchase_duplicates(pt, v_vb, null, 'VB-001')) = 0, 'a voided bill is not a duplicate candidate');
  perform test_helpers.assert((select count(*) from public.find_purchase_duplicates(pt, v_va, null, 'INV-A-003')) = 0, 'a draft is not a duplicate candidate');
  perform test_helpers.expect_msg(format('select * from public.find_purchase_duplicates(%L)', pt), 'INVALID', 'a vendor or a payee must be named');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select * from public.find_purchase_duplicates(%L, %L, null, ''INV-A-002'')', pt, v_va), 'FORBIDDEN', 'a stranger cannot probe for duplicates');
  perform test_helpers.logout();
  perform test_helpers.controls6(pt, 'after the duplicate tests');
end
$$;

-- ================================================================ 9. direct expenses (paid at once from a cash or bank account)
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_va uuid := test_helpers.g('va');
  v_cash uuid := test_helpers.g('cash');
  v_usd uuid := test_helpers.g('usd');
  v_cat uuid := test_helpers.g('cat_exp');
  v_today date := test_helpers.today(pt);
  v_cash_la uuid;
  v_usd_la uuid;
  v_e1 uuid;
  v_e2 uuid;
  v_empty uuid;
  v_ver integer;
  x public.expenses%rowtype;
  v_cash_before numeric;
begin
  select ledger_account_id into v_cash_la from public.financial_accounts where id = v_cash;
  select ledger_account_id into v_usd_la from public.financial_accounts where id = v_usd;
  select ledger_balance into v_cash_before from test_helpers.mc(pt) where financial_account_id = v_cash;

  -- ---- a draft, prepared by staff
  perform test_helpers.login(v_staff);
  v_e1 := public.create_expense_draft(pt, 'key-p6-ex-01', v_cash, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Coffee for the client meeting', 'unit_price', 85000, 'category_id', v_cat)),
    null, 'Kopi Kenangan', 'RCPT-1', null, 'Meeting with Vendor A', 'internal: petty cash');
  perform test_helpers.put('exp_1', v_e1);
  perform test_helpers.assert(public.create_expense_draft(pt, 'key-p6-ex-01', v_cash, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Coffee for the client meeting', 'unit_price', 85000, 'category_id', v_cat)),
    null, 'Kopi Kenangan', 'RCPT-1', null, 'Meeting with Vendor A', 'internal: petty cash') = v_e1, 'creating an expense replays on the same key');
  select * into x from public.expenses where id = v_e1;
  perform test_helpers.assert(x.status = 'draft' and x.expense_number is null and x.journal_id is null and x.currency = 'IDR' and x.total = 85000 and x.base_total = 0
    and x.payee_name = 'Kopi Kenangan' and x.receipt_reference = 'RCPT-1' and x.tax_status = 'pending_engine', 'a draft expense: computed total, no number, no journal');
  perform test_helpers.assert(not exists (select 1 from public.money_movements where source_type = 'expense' and source_id = v_e1), 'a draft moves no money');

  -- validation
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-02'', %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, v_cash, v_today), 'INVALID', 'an expense needs a payee');
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-03'', %L, %L, ''[{"description":"x","unit_price":1}]'', %L)', pt, v_cash, v_today, test_helpers.g('vc')), 'INVALID', 'a customer-only contact is not a payee');
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-04'', %L, %L, ''[{"description":"x","unit_price":1}]'', %L)', pt, v_cash, v_today, test_helpers.g('vx')), 'INVALID', 'an inactive contact is not a payee');
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-05'', %L, %L, ''[{"description":"x","unit_price":1}]'', null, ''Shop'')', pt, test_helpers.g('pe_bank'), v_today), 'INVALID', 'the account must belong to the Entity');
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-06'', %L, %L, ''[{"description":"x","unit_price":1}]'', null, ''Shop'', null, 15000)', pt, v_cash, v_today), 'INVALID', 'a rupiah expense takes no rate');
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-07'', %L, %L, ''[{"description":"x","unit_price":1}]'', null, ''Shop'')', pt, v_usd, v_today), 'INVALID', 'a USD expense needs a rate');
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-08'', %L, null, ''[{"description":"x","unit_price":1}]'', null, ''Shop'')', pt, v_cash), 'INVALID', 'an expense needs a date');
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-09'', %L, %L, ''[{"description":"x","unit_price":1}]'', null, %L)', pt, v_cash, v_today, repeat('n', 201)), 'INVALID', 'the payee name is limited to 200 characters');
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-10'', %L, %L, ''[{"description":"x","unit_price":1}]'', null, ''Shop'', %L)', pt, v_cash, v_today, repeat('r', 101)), 'INVALID', 'the receipt reference is limited to 100 characters');
  v_empty := public.create_expense_draft(pt, 'key-p6-ex-11', v_cash, v_today, '[]', null, 'Shop');
  perform test_helpers.expect_msg(format('select public.submit_expense(%L, ''key-p6-ex-11b'')', v_empty), 'INVALID', 'an expense without a line can be saved as a draft but not submitted');
  perform public.cancel_expense(v_empty, 'key-p6-ex-11c', 'Empty draft dropped');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-12'', %L, %L, ''[{"description":"x","unit_price":1}]'', null, ''Shop'')', pt, v_cash, v_today), 'FORBIDDEN', 'a viewer cannot create an expense');
  perform test_helpers.expect_error(format('insert into public.expenses (entity_id, payee_name, financial_account_id, currency, expense_date) values (%L, ''x'', %L, ''IDR'', current_date)', pt, v_cash), '42501', 'no direct insert into expenses');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-ex-13'', %L, %L, ''[{"description":"x","unit_price":1}]'', null, ''Shop'')', pt, v_cash, v_today), 'FORBIDDEN', 'a stranger cannot create an expense');
  perform test_helpers.assert((select count(*) from public.expenses) = 0, 'a stranger sees no expenses');
  perform test_helpers.logout();

  -- editing a draft: whitelist, version check
  perform test_helpers.login(v_staff);
  select version into v_ver from public.expenses where id = v_e1;
  perform test_helpers.assert(public.update_expense_draft(v_e1, '{"notes":"Meeting with Vendor A and B"}'::jsonb, v_ver) = v_ver + 1, 'the draft is edited and its version moves');
  perform test_helpers.expect_msg(format('select public.update_expense_draft(%L, ''{"notes":"stale"}'', %s)', v_e1, v_ver), 'CONFLICT', 'a stale version is refused');
  perform test_helpers.expect_msg(format('select public.update_expense_draft(%L, ''{"total":1}'')', v_e1), 'INVALID', 'a total cannot be patched');
  perform test_helpers.expect_msg(format('select public.update_expense_draft(%L, ''{"status":"confirmed"}'')', v_e1), 'INVALID', 'a status cannot be patched');
  perform test_helpers.assert(public.submit_expense(v_e1, 'key-p6-ex-14') = v_e1, 'staff submit the expense');
  perform test_helpers.assert(public.recall_expense(v_e1) = 'draft', 'the preparer takes it back');
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-ex-15'')', v_e1), 'FORBIDDEN', 'the preparer cannot confirm the expense');
  perform public.submit_expense(v_e1, 'key-p6-ex-16');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-ex-17'')', v_e1), 'FORBIDDEN', 'an approver cannot confirm an expense (nothing to approve: it is paid)');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-ex-18'')', v_e1), 'FORBIDDEN', 'a viewer cannot confirm an expense');
  perform test_helpers.logout();

  -- rejection sends it back with a reason
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.reject_expense(%L, '' '')', v_e1), 'INVALID', 'a rejection needs a reason');
  perform test_helpers.assert(public.reject_expense(v_e1, 'Attach the receipt photo') = 'draft', 'the finance admin rejects with a reason');
  perform test_helpers.assert((select status = 'draft' and reject_reason = 'Attach the receipt photo' and rejected_by = v_admin from public.expenses where id = v_e1), 'the rejection is recorded');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform public.submit_expense(v_e1, 'key-p6-ex-19');
  perform test_helpers.logout();

  -- ---- confirmation posts once: Dr expense account / Cr the paying account
  perform test_helpers.login(v_admin);
  perform test_helpers.assert(public.confirm_expense(v_e1, 'key-p6-ex-20') = v_e1, 'the finance admin confirms the expense');
  perform test_helpers.assert(public.confirm_expense(v_e1, 'key-p6-ex-20') = v_e1, 'confirming replays on the same key');
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-ex-21'')', v_e1), 'CONFLICT', 'an expense is confirmed once');
  select * into x from public.expenses where id = v_e1;
  perform test_helpers.assert(x.status = 'confirmed' and x.expense_number like 'EXP%' and x.base_total = 85000 and x.journal_id is not null and x.confirmed_by = v_admin and x.duplicate_ack_reason is null,
    'confirmed: numbered EXP, journal linked, base total booked');
  perform test_helpers.assert((select array_agg(posted_account_id is not null and base_amount = 85000 and asset_link_status = 'none') from public.expense_lines where expense_id = v_e1) = array[true], 'the line carries its posted account and base amount');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jd(x.journal_id, 'OFFICE_GENERAL_EXPENSE') = 85000
    and (select coalesce(sum(credit), 0) from public.journal_lines where journal_id = x.journal_id and ledger_account_id = v_cash_la) = 85000
    and (select count(*) from public.journal_lines where journal_id = x.journal_id) = 2, 'Dr Office expense 85,000 / Cr Petty Cash 85,000');
  perform test_helpers.assert((select source_type = 'expense' and entry_date = v_today from public.journal_entries where id = x.journal_id), 'the journal is sourced from the expense');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'expense' and source_id = v_e1 and direction = 'out' and amount = 85000
    and base_amount = 85000 and financial_account_id = v_cash and journal_id = x.journal_id) = 1, 'one outbound movement');
  perform test_helpers.assert((select count(*) from public.journal_entries where source_type = 'expense' and source_id = v_e1) = 1, 'the replay posted nothing more');
  perform test_helpers.assert((select ledger_balance from test_helpers.mc(pt) where financial_account_id = v_cash) = v_cash_before - 85000, 'the petty cash went down by 85,000');
  perform test_helpers.controls6(pt, 'after the first expense');
  -- frozen once confirmed
  perform test_helpers.expect_error(format('update public.expenses set total = 1, subtotal = 1 where id = %L', v_e1), '23000', 'a confirmed expense is frozen');
  perform test_helpers.expect_error(format('update public.expenses set payee_name = ''Someone else'' where id = %L', v_e1), '23000', 'its payee cannot change');
  perform test_helpers.expect_error(format('update public.expense_lines set unit_price = 1 where expense_id = %L', v_e1), '23000', 'its lines are frozen');
  perform test_helpers.expect_error(format('delete from public.expense_lines where expense_id = %L', v_e1), '23000', 'its lines cannot be deleted');
  perform test_helpers.expect_error(format('delete from public.expenses where id = %L', v_e1), '23000', 'an expense cannot be deleted');
  perform test_helpers.expect_error(format('update public.expenses set status = ''draft'' where id = %L', v_e1), '23000', 'a confirmed expense cannot go back to draft');
  perform test_helpers.expect_error('truncate public.expenses cascade', null, 'truncate is forbidden');
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.update_expense_draft(%L, ''{"notes":"late"}'')', v_e1), 'CONFLICT', 'a confirmed expense cannot be edited');
  perform test_helpers.expect_error(format('update public.expenses set total = 1 where id = %L', v_e1), '42501', 'no direct update by the browser');
  perform test_helpers.logout();

  -- ---- a foreign-currency prepaid expense from the USD account, payee is a known vendor
  perform test_helpers.login(v_staff);
  v_e2 := public.create_expense_draft(pt, 'key-p6-ex-22', v_usd, v_today, '[{"description":"SaaS tool, annual","unit_price":20,"treatment":"prepaid"}]', v_va, null, 'SAAS-77', 15000);
  perform public.submit_expense(v_e2, 'key-p6-ex-23');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform public.confirm_expense(v_e2, 'key-p6-ex-24');
  select * into x from public.expenses where id = v_e2;
  perform test_helpers.logout();
  perform test_helpers.assert(x.currency = 'USD' and x.total = 20 and x.base_total = 300000 and x.payee_id = v_va and x.payee_name is null, 'a USD expense of 20 at 15,000 books 300,000');
  perform test_helpers.assert(test_helpers.jd(x.journal_id, 'PREPAID_EXPENSE') = 300000
    and (select coalesce(sum(credit), 0) from public.journal_lines where journal_id = x.journal_id and ledger_account_id = v_usd_la and original_currency = 'USD' and original_amount = 20 and exchange_rate = 15000) = 300000,
    'Dr Prepaid 300,000 / Cr the USD account, keeping the original amount and rate');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'expense' and source_id = v_e2 and direction = 'out' and amount = 20 and base_amount = 300000 and exchange_rate = 15000) = 1, 'the movement is in USD at the rate');
  perform test_helpers.controls6(pt, 'after the USD expense');
end
$$;

-- ---- duplicates, dates, defaults, cancel, reverse and correct for expenses
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_va uuid := test_helpers.g('va');
  v_cash uuid := test_helpers.g('cash');
  v_usd uuid := test_helpers.g('usd');
  v_cat uuid := test_helpers.g('cat_exp');
  v_e1 uuid := test_helpers.g('exp_1');
  v_e2 uuid;
  v_today date := test_helpers.today(pt);
  v_cash_la uuid;
  v_e3 uuid;
  v_e4 uuid;
  v_e5 uuid;
  v_e6 uuid;
  v_e7 uuid;
  v_e8 uuid;
  v_rev uuid;
  v_new uuid;
  v_before numeric;
  x public.expenses%rowtype;
  r public.expenses%rowtype;
begin
  select ledger_account_id into v_cash_la from public.financial_accounts where id = v_cash;
  select id into v_e2 from public.expenses where entity_id = pt and receipt_reference = 'SAAS-77';

  -- ---- the same receipt from the same payee, apart from case and spaces
  perform test_helpers.login(v_staff);
  v_e3 := public.create_expense_draft(pt, 'key-p6-ex-30', v_cash, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Coffee again', 'unit_price', 90000, 'category_id', v_cat)), null, ' kopi kenangan ', 'rcpt-1');
  perform public.submit_expense(v_e3, 'key-p6-ex-31');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-ex-32'')', v_e3), 'CONFLICT', 'the same payee and receipt number twice is refused without a reason');
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-ex-33'', ''ok'')', v_e3), 'CONFLICT', 'a two-character reason is not a reason');
  perform public.confirm_expense(v_e3, 'key-p6-ex-34', 'A second coffee bought on the same receipt book');
  perform test_helpers.assert((select status = 'confirmed' and duplicate_ack_reason = 'A second coffee bought on the same receipt book' from public.expenses where id = v_e3), 'a stated reason lets it through and stays on the expense');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.find_purchase_duplicates(pt, null, 'kopi KENANGAN', 'RCPT-1')) = 2, 'the finder matches a payee by name');
  perform test_helpers.logout();

  -- ---- an expense paid in cash for a document that is already a bill is a double count
  perform test_helpers.login(v_staff);
  v_e4 := public.create_expense_draft(pt, 'key-p6-ex-35', v_cash, v_today, '[{"description":"Stationery paid in cash","unit_price":1000000}]', v_va, null, 'inv-a-002');
  perform public.submit_expense(v_e4, 'key-p6-ex-36');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-ex-37'')', v_e4), 'CONFLICT', 'a receipt that matches a bill of the same vendor is refused');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.cancel_expense(v_e4, 'key-p6-ex-38', 'Already recorded as a bill') = v_e4, 'the owner cancels a submitted expense');
  perform test_helpers.logout();

  -- ---- a future-dated expense stays a draft
  perform test_helpers.login(v_staff);
  v_e5 := public.create_expense_draft(pt, 'key-p6-ex-39', v_cash, v_today + 3, '[{"description":"Next week","unit_price":5000}]', null, 'Toko Depan');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-ex-40'')', v_e5), 'INVALID', 'a future-dated expense cannot be confirmed');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(public.cancel_expense(v_e5, 'key-p6-ex-41', 'Not needed after all') = v_e5, 'staff cancel their own draft');
  perform test_helpers.assert(public.cancel_expense(v_e5, 'key-p6-ex-41', 'Not needed after all') = v_e5, 'cancelling replays on the same key');
  perform test_helpers.expect_msg(format('select public.cancel_expense(%L, ''key-p6-ex-42'', ''Cancelled twice'')', v_e5), 'FORBIDDEN', 'a cancelled expense is out of the preparer''s reach');
  perform test_helpers.logout();
  perform test_helpers.assert((select status = 'cancelled' and expense_number is null and journal_id is null from public.expenses where id = v_e5), 'a cancelled draft has no number and no journal');

  -- ---- default and mapped accounts, asset line; several lines share one credit
  perform test_helpers.login(v_staff);
  v_e6 := public.create_expense_draft(pt, 'key-p6-ex-43', v_cash, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Parking', 'unit_price', 15000, 'category_id', test_helpers.g('cat_plain')),
                      jsonb_build_object('description', 'Side table', 'unit_price', 900000, 'treatment', 'asset', 'category_id', test_helpers.g('cat_asset'))),
    null, 'Toko Meja', 'TM-1');
  perform public.submit_expense(v_e6, 'key-p6-ex-44');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform public.confirm_expense(v_e6, 'key-p6-ex-45');
  perform test_helpers.logout();
  select * into x from public.expenses where id = v_e6;
  perform test_helpers.assert(test_helpers.jd(x.journal_id, 'OTHER_OPERATING_EXPENSE') = 15000 and test_helpers.jd(x.journal_id, 'FIXED_ASSET_EQUIPMENT') = 900000
    and (select coalesce(sum(credit), 0) from public.journal_lines where journal_id = x.journal_id and ledger_account_id = v_cash_la) = 915000
    and (select count(*) from public.journal_lines where journal_id = x.journal_id) = 3, 'an unmapped category uses the Entity default; the asset goes to equipment; one credit of 915,000');
  perform test_helpers.assert((select array_agg(asset_link_status order by line_no) from public.expense_lines where expense_id = v_e6) = array['none', 'linked'], 'the asset line is linked to a draft in the asset register (P8)');
  perform test_helpers.controls6(pt, 'after the multi-line expense');

  -- ---- cancelling
  perform test_helpers.login(v_staff);
  v_e7 := public.create_expense_draft(pt, 'key-p6-ex-46', v_cash, v_today, '[{"description":"Mistake","unit_price":1000}]', null, 'Toko Salah');
  v_e8 := public.create_expense_draft(pt, 'key-p6-ex-47', v_cash, v_today, '[{"description":"Mistake two","unit_price":2000}]', null, 'Toko Salah Dua');
  perform public.submit_expense(v_e8, 'key-p6-ex-48');
  perform test_helpers.expect_msg(format('select public.cancel_expense(%L, ''key-p6-ex-49'', ''no'')', v_e7), 'INVALID', 'a cancellation needs a reason');
  perform test_helpers.expect_msg(format('select public.cancel_expense(%L, ''key-p6-ex-50'', ''Submitted by mistake'')', v_e8), 'FORBIDDEN', 'staff cannot cancel a submitted expense');
  perform test_helpers.expect_msg(format('select public.cancel_expense(%L, ''key-p6-ex-51'', ''Cancel a confirmed one'')', v_e6), 'FORBIDDEN', 'staff cannot cancel a confirmed expense');
  perform public.cancel_expense(v_e7, 'key-p6-ex-52', 'Entered by mistake');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.cancel_expense(%L, ''key-p6-ex-53'', ''Cancel a confirmed one'')', v_e6), 'CONFLICT', 'a confirmed expense is reversed, not cancelled');
  perform public.cancel_expense(v_e8, 'key-p6-ex-54', 'Submitted by mistake');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.journal_entries where source_id in (v_e4, v_e5, v_e7, v_e8)) = 0, 'cancelling leaves no accounting trace');

  -- ---- reversing a confirmed expense: owner only
  select ledger_balance into v_before from test_helpers.mc(pt) where financial_account_id = v_cash;
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.reverse_expense(%L, ''key-p6-ex-55'', ''Bought by mistake'')', v_e6), 'FORBIDDEN', 'a finance admin cannot reverse an expense');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.reverse_expense(%L, ''key-p6-ex-56'', ''Bought by mistake'')', v_e6), 'FORBIDDEN', 'staff cannot reverse an expense');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.reverse_expense(%L, ''key-p6-ex-57'', ''no'')', v_e6), 'INVALID', 'a reversal needs a reason');
  perform test_helpers.expect_msg(format('select public.reverse_expense(%L, ''key-p6-ex-58'', ''Bought by mistake'', %L)', v_e6, v_today + 1), 'INVALID', 'a reversal cannot be in the future');
  perform test_helpers.expect_msg(format('select public.reverse_expense(%L, ''key-p6-ex-59'', ''Bought by mistake'', %L)', v_e6, v_today - 1), 'INVALID', 'a reversal cannot precede the expense');
  v_rev := public.reverse_expense(v_e6, 'key-p6-ex-60', 'Bought by mistake');
  perform test_helpers.assert(public.reverse_expense(v_e6, 'key-p6-ex-60', 'Bought by mistake') = v_rev, 'reversal replays on the same key');
  perform test_helpers.expect_msg(format('select public.reverse_expense(%L, ''key-p6-ex-61'', ''Bought by mistake'')', v_e6), 'CONFLICT', 'an expense is reversed once');
  perform test_helpers.logout();
  select * into x from public.expenses where id = v_e6;
  perform test_helpers.assert(x.status = 'reversed' and x.reversal_journal_id is not null and x.closed_reason = 'Bought by mistake' and x.closed_by = v_owner and x.closed_date = v_today, 'the expense is reversed with its reason, actor and date');
  perform test_helpers.assert((select reverses_journal_id from public.journal_entries where id = x.reversal_journal_id) = x.journal_id, 'a linked reversal journal');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'expense' and source_id = v_e6 and direction = 'in' and amount = 915000 and reverses_movement_id is not null) = 1, 'the movement is mirrored back');
  perform test_helpers.assert((select ledger_balance from test_helpers.mc(pt) where financial_account_id = v_cash) = v_before + 915000, 'the petty cash is restored');
  perform test_helpers.controls6(pt, 'after reversing an expense');

  -- ---- correcting: the USD expense gets a replacement draft
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.correct_expense(%L, ''key-p6-ex-62'', ''Wrong amount typed'')', v_e2), 'FORBIDDEN', 'a finance admin cannot correct an expense');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  v_new := public.correct_expense(v_e2, 'key-p6-ex-63', 'Wrong amount typed');
  perform test_helpers.assert(public.correct_expense(v_e2, 'key-p6-ex-63', 'Wrong amount typed') = v_new, 'correcting replays on the same key');
  perform test_helpers.logout();
  select * into x from public.expenses where id = v_e2;
  select * into r from public.expenses where id = v_new;
  perform test_helpers.assert(x.status = 'reversed' and x.replaced_by_expense_id = v_new and r.status = 'draft' and r.replaces_expense_id = v_e2 and r.receipt_reference = 'SAAS-77'
    and r.payee_id = v_va and r.currency = 'USD' and r.exchange_rate = 15000 and r.total = 20 and r.financial_account_id = v_usd, 'the replacement is a draft copy that points back');
  perform test_helpers.login(v_staff);
  perform public.update_expense_draft(v_new, '{"lines":[{"description":"SaaS tool, annual","unit_price":25,"treatment":"prepaid"}]}'::jsonb, r.version);
  perform public.submit_expense(v_new, 'key-p6-ex-64');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform public.confirm_expense(v_new, 'key-p6-ex-65');
  perform test_helpers.logout();
  perform test_helpers.assert((select status = 'confirmed' and base_total = 375000 and duplicate_ack_reason is null from public.expenses where id = v_new), 'the replacement confirms without a duplicate reason: the reversed original is not a duplicate');
  perform test_helpers.controls6(pt, 'after correcting an expense');
end
$$;

-- ================================================================ 10. evidence documents
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_r uuid := test_helpers.g('bill_r');
  v_a uuid := test_helpers.g('bill_a');
  v_d uuid := test_helpers.g('bill_d');
  v_e1 uuid := test_helpers.g('exp_1');
  v_today date := test_helpers.today(pt);
  v_h1 text := encode(sha256('p6-document-one'::bytea), 'hex');
  v_h2 text := encode(sha256('p6-document-two'::bytea), 'hex');
  v_doc1 uuid;
  v_doc2 uuid;
  v_l1 uuid;
  v_l2 uuid;
  v_l3 uuid;
  v_cancelled_exp uuid;
  v_missing_before bigint;
  v_n bigint;
begin
  select id into v_cancelled_exp from public.expenses where entity_id = pt and status = 'cancelled' limit 1;

  perform test_helpers.login(v_viewer);
  select count(*) into v_missing_before from public.list_missing_evidence(pt);
  perform test_helpers.assert(v_missing_before >= 8 and exists (select 1 from public.list_missing_evidence(pt) where doc_kind = 'bill' and doc_id = v_r)
    and exists (select 1 from public.list_missing_evidence(pt) where doc_kind = 'expense' and doc_id = v_e1), 'before any evidence, approved bills and confirmed expenses are listed as missing it');
  perform test_helpers.assert(not exists (select 1 from public.list_missing_evidence(pt) where doc_id in (v_a, v_d, v_cancelled_exp)), 'voided bills, drafts and cancelled expenses are not');
  perform test_helpers.assert((select count(*) from public.list_missing_evidence(pt, v_today + 1)) = 0, 'the date filter applies');
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-dc-00'', ''a.pdf'', ''application/pdf'', 10, %L)', pt, v_h1), 'FORBIDDEN', 'a viewer cannot register a document');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-dc-00'', ''a.pdf'', ''application/pdf'', 10, %L)', pt, v_h1), 'FORBIDDEN', 'a stranger cannot register a document');
  perform test_helpers.expect_msg(format('select * from public.list_missing_evidence(%L)', pt), 'FORBIDDEN', 'nor read the missing-evidence list');
  perform test_helpers.logout();

  perform test_helpers.login(v_staff);
  v_doc1 := public.register_document(pt, 'key-p6-dc-01', 'vendor-invoice-r.pdf', 'application/pdf', 120000, v_h1);
  perform test_helpers.assert(public.register_document(pt, 'key-p6-dc-01', 'vendor-invoice-r.pdf', 'application/pdf', 120000, v_h1) = v_doc1, 'registering replays on the same key');
  perform test_helpers.assert(public.register_document(pt, 'key-p6-dc-02', 'renamed.pdf', 'application/pdf', 120000, upper(v_h1)) = v_doc1, 'the same content is registered once per Entity, whatever its name');
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-dc-03'', ''a.zip'', ''application/zip'', 10, %L)', pt, v_h2), 'INVALID', 'only PDF and image types are accepted');
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-dc-04'', ''a.pdf'', ''application/pdf'', 26214401, %L)', pt, v_h2), 'INVALID', 'a document is at most 25 MB');
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-dc-05'', ''a.pdf'', ''application/pdf'', 0, %L)', pt, v_h2), 'INVALID', 'an empty document is refused');
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-dc-06'', ''a.pdf'', ''application/pdf'', 10, ''not-a-hash'')', pt), 'INVALID', 'a SHA-256 hash is required');
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-dc-07'', ''../a.pdf'', ''application/pdf'', 10, %L)', pt, v_h2), 'INVALID', 'a file name has no path in it');
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-dc-08'', '' '', ''application/pdf'', 10, %L)', pt, v_h2), 'INVALID', 'a file name is required');
  v_doc2 := public.register_document(pt, 'key-p6-dc-09', 'receipt-photo.png', 'image/png', 350000, v_h2);
  perform test_helpers.assert(v_doc2 <> v_doc1, 'a different content is a different document');

  -- linking
  v_l1 := public.link_document(v_doc1, 'bill', v_r, 'vendor_invoice');
  perform test_helpers.assert(public.link_document(v_doc1, 'bill', v_r, 'vendor_invoice') = v_l1, 'linking twice keeps one active link');
  v_l2 := public.link_document(v_doc2, 'expense', v_e1, 'receipt');
  v_l3 := public.link_document(v_doc1, 'bill', v_d, 'other');
  perform test_helpers.expect_msg(format('select public.link_document(%L, ''invoice'', %L)', v_doc1, v_r), 'INVALID', 'documents attach to bills and expenses only');
  perform test_helpers.expect_msg(format('select public.link_document(%L, ''bill'', %L)', v_doc1, gen_random_uuid()), 'INVALID', 'the target must exist');
  perform test_helpers.expect_msg(format('select public.link_document(%L, ''bill'', %L, ''selfie'')', v_doc1, v_r), 'INVALID', 'the purpose is from a fixed list');
  perform test_helpers.expect_msg(format('select public.link_document(%L, ''bill'', %L)', v_doc1, v_a), 'CONFLICT', 'a voided bill takes no more documents');
  perform test_helpers.expect_msg(format('select public.link_document(%L, ''expense'', %L)', v_doc1, v_cancelled_exp), 'CONFLICT', 'a cancelled expense takes no more documents');
  perform test_helpers.expect_msg(format('select public.unlink_document(%L, ''x'')', v_l3), 'INVALID', 'removing evidence needs a reason');
  perform test_helpers.assert(public.unlink_document(v_l3, 'Wrong file attached') = 'removed', 'evidence of a draft can be removed');
  perform test_helpers.expect_msg(format('select public.unlink_document(%L, ''Wrong file attached'')', v_l3), 'CONFLICT', 'a removed link is removed once');
  perform test_helpers.expect_msg(format('select public.unlink_document(%L, ''Changed my mind'')', v_l1), 'CONFLICT', 'evidence of an approved bill is part of the record');
  perform test_helpers.expect_msg(format('select public.unlink_document(%L, ''Changed my mind'')', v_l2), 'CONFLICT', 'evidence of a confirmed expense is part of the record');
  perform test_helpers.assert((select count(*) from public.list_document_links(pt, 'bill', v_d)) = 0, 'a removed link is not listed');
  perform test_helpers.logout();

  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) = 1 and bool_and(file_name = 'vendor-invoice-r.pdf' and sha256 = v_h1 and purpose = 'vendor_invoice') from public.list_document_links(pt, 'bill', v_r)), 'a viewer lists the evidence of the bill');
  perform test_helpers.assert(not exists (select 1 from public.list_missing_evidence(pt) where doc_id in (v_r, v_e1)), 'the two purchases with evidence leave the missing list');
  select count(*) into v_n from public.list_missing_evidence(pt);
  perform test_helpers.assert(v_n = v_missing_before - 2, 'and only those two');
  perform test_helpers.expect_msg(format('select public.link_document(%L, ''bill'', %L)', v_doc2, v_r), 'FORBIDDEN', 'a viewer cannot attach a document');
  perform test_helpers.expect_error('insert into public.document_links (entity_id, document_id, target_type, target_id) values (gen_random_uuid(), gen_random_uuid(), ''bill'', gen_random_uuid())', '42501', 'no direct insert into links');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select * from public.list_document_links(%L, ''bill'', %L)', pt, v_r), 'FORBIDDEN', 'an approver without documents.view cannot list evidence');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.assert(public.link_document(v_doc2, 'bill', v_r, 'receipt') is not null, 'a finance admin attaches a second document to the approved bill');
  perform test_helpers.logout();

  -- a document never changes; only its storage location is set later
  perform test_helpers.expect_error(format('update public.documents set file_name = ''x.pdf'' where id = %L', v_doc1), '23000', 'a registered document is immutable');
  perform test_helpers.expect_error(format('update public.documents set sha256 = %L where id = %L', repeat('a', 64), v_doc1), '23000', 'its hash cannot change');
  perform test_helpers.expect_error(format('delete from public.documents where id = %L', v_doc1), '23000', 'a document cannot be deleted');
  perform test_helpers.expect_error(format('delete from public.document_links where id = %L', v_l1), '23000', 'a link cannot be deleted');
  perform test_helpers.expect_error(format('update public.document_links set target_id = %L where id = %L', v_d, v_l1), '23000', 'a link cannot be moved to another target');
  update public.documents set storage_path = 'p6/synthetic/one.pdf' where id = v_doc1;
  perform test_helpers.assert((select storage_path from public.documents where id = v_doc1) = 'p6/synthetic/one.pdf', 'the storage path can be set by the upload flow');
  perform test_helpers.expect_error(format('insert into public.document_links (entity_id, document_id, target_type, target_id) values (%L, %L, ''bill'', %L)', pt, v_doc1, v_r), '23505', 'one active link per document and target');
  perform test_helpers.expect_error('truncate public.documents cascade', null, 'documents cannot be truncated');
end
$$;

-- ================================================================ 11. periods: close checks, closed periods
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_acct uuid := 'c0000000-0000-0000-0000-000000000006';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_va uuid := test_helpers.g('va');
  v_bca uuid := test_helpers.g('bca');
  v_cash uuid := test_helpers.g('cash');
  v_today date := test_helpers.today(pt);
  v_old date := (date_trunc('month', test_helpers.today(pt)) - interval '2 months')::date + 4;
  v_cur uuid;
  v_period uuid;
  v_o1 uuid;
  v_o2 uuid;
  v_o3 uuid;
  v_ox uuid;
  v_pay uuid;
  v_ap uuid;
  v_exp uuid;
begin
  select id into v_cur from public.accounting_periods where entity_id = pt and v_today between period_start and period_end;

  -- warnings, never blockers, for unfinished purchases and missing evidence
  perform test_helpers.login(v_staff);
  v_exp := public.create_expense_draft(pt, 'key-p6-pc-00', v_cash, v_today, '[{"description":"Unfinished","unit_price":1000}]', null, 'Toko Belum Selesai');
  perform public.submit_expense(v_exp, 'key-p6-pc-00b');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_cur) where code = 'unapproved_bills' and severity = 'warning' and item_count >= 1), 'draft bills of the period are a warning');
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_cur) where code = 'unconfirmed_expenses' and severity = 'warning' and item_count = 1), 'a submitted expense of the period is a warning');
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_cur) where code = 'purchases_without_evidence' and severity = 'warning' and item_count >= 3), 'purchases without a document are a warning');
  perform test_helpers.assert(not exists (select 1 from public.period_close_checks(v_cur) where severity = 'blocker'), 'no blocker: the purchase layer reconciles with the ledger');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform public.recall_expense(v_exp);
  perform public.cancel_expense(v_exp, 'key-p6-pc-01', 'Not needed after all');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(not exists (select 1 from public.period_close_checks(v_cur) where code = 'unconfirmed_expenses'), 'a cancelled expense no longer warns');
  perform test_helpers.logout();

  -- the sub-ledger against the ledger is a blocker when they differ (a purchase journal without a bill behind it)
  begin
    perform app_private.post_system_journal(pt, 'bill', gen_random_uuid(), 'bill.approve', 'bill.v1', v_today, 'Probe: a bill journal with no bill',
      app_private.add_line(app_private.add_line('[]'::jsonb, test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE'), 1000, 0, 'probe'),
                           test_helpers.acct(pt, 'ACCOUNTS_PAYABLE'), 0, 1000, 'probe'));
    perform test_helpers.login(v_acct);
    perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_cur) where code = 'ap_ledger_mismatch' and severity = 'blocker'), 'a mismatch between bills and the payable is a close blocker');
    raise exception 'PROBE_DONE';
  exception when others then
    if sqlerrm <> 'PROBE_DONE' then
      raise;
    end if;
  end;
  perform test_helpers.assert((select sub_ledger = ledger_purchases from test_helpers.apc(pt)), 'the probe was rolled back');

  -- bills and payments in an old period, then close it
  perform test_helpers.login(v_staff);
  v_o1 := public.create_bill_draft(pt, 'key-p6-pc-02', v_va, v_old, v_old + 30, '[{"description":"Old month cost","unit_price":500000}]', 'OLD-1');
  v_o2 := public.create_bill_draft(pt, 'key-p6-pc-03', v_va, v_old, v_old + 30, '[{"description":"Old month cost, unpaid","unit_price":300000}]', 'OLD-2');
  v_o3 := public.create_bill_draft(pt, 'key-p6-pc-04', v_va, v_old, v_old + 30, '[{"description":"Old month draft","unit_price":10}]', 'OLD-3');
  v_ox := public.create_expense_draft(pt, 'key-p6-pc-05', v_cash, v_old, '[{"description":"Old month cash","unit_price":2000}]', null, 'Toko Lama');
  perform public.submit_bill(v_o1, 'key-p6-pc-06');
  perform public.submit_bill(v_o2, 'key-p6-pc-07');
  perform public.submit_bill(v_o3, 'key-p6-pc-08');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform public.approve_bill(v_o1, 'key-p6-pc-09');
  perform public.approve_bill(v_o2, 'key-p6-pc-10');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  v_pay := public.record_vendor_payment(pt, 'key-p6-pc-11', v_va, v_bca, v_old + 1, 200000, jsonb_build_array(jsonb_build_object('bill_id', v_o1, 'amount', 200000)));
  perform test_helpers.logout();
  select id into v_period from public.accounting_periods where entity_id = pt and v_old between period_start and period_end;
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_period) where code = 'unapproved_bills' and item_count = 1)
    and exists (select 1 from public.period_close_checks(v_period) where code = 'unconfirmed_expenses' and item_count = 1), 'the old period warns about the unapproved bill and the unconfirmed expense');
  perform public.begin_period_close(v_period);
  perform test_helpers.assert(public.close_period(v_period) = 'closed', 'the period closes: warnings do not block');
  perform test_helpers.logout();

  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-pc-12'')', v_o3), 'CONFLICT', 'a bill dated in a closed period cannot be approved');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-pc-13'')', v_ox), 'CONFLICT', 'an expense dated in a closed period cannot be confirmed');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-pc-14'', %L, %L, %L, 100000, %L::jsonb)', pt, v_va, v_bca, v_old + 2,
    jsonb_build_array(jsonb_build_object('bill_id', v_o1, 'amount', 100000))::text), 'CONFLICT', 'a payment cannot be dated in a closed period');
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-pc-15'', %L, ''Wrong bill, closed month'')', v_pay, v_old + 3), 'CONFLICT', 'a payment cannot be reversed with a date in a closed period');
  perform public.record_vendor_payment(pt, 'key-p6-pc-16', v_va, v_bca, v_today, 300000, jsonb_build_array(jsonb_build_object('bill_id', v_o1, 'amount', 300000)));
  perform test_helpers.assert((select settlement_status = 'paid' from public.list_bill_positions(pt) where bill_id = v_o1), 'the rest of the old bill is paid with a current date');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-pc-17'', ''Voiding inside a closed month'', %L)', v_o2, v_old + 5), 'CONFLICT', 'a void cannot be dated in a closed period');
  perform public.void_bill(v_o2, 'key-p6-pc-18', 'Voided with a current date', v_today);
  perform test_helpers.assert((select status = 'void' and closed_date = v_today from public.bills where id = v_o2), 'a later void reverses on the current date; the closed month is untouched');
  perform test_helpers.logout();
  perform test_helpers.controls6(pt, 'after closing a period');
  -- as of the end of the closed period the books still show what they showed when it closed
  perform test_helpers.assert((select sub_ledger = ledger_purchases from test_helpers.apc(pt, (select period_end from public.accounting_periods where id = v_period))), 'the closed period still reconciles as of its end date');
end
$$;

-- ================================================================ 11b. maker-checker thresholds (Step 06 §9): a threshold is in the BASE currency
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_va uuid := test_helpers.g('va');
  v_bca uuid := test_helpers.g('bca');
  v_usd uuid := test_helpers.g('usd');
  v_today date := test_helpers.today(pt);
  v_big uuid;
  v_small uuid;
  v_fx uuid;
  v_xa uuid;
  v_xs uuid;
begin
  insert into public.approval_rules (entity_id, module, action, min_amount, requires_approval, allow_self_approval, effective_from)
  values (pt, 'bills', 'approve', 10000000, true, false, v_today - 30),
         (pt, 'bills', 'pay', 10000000, true, false, v_today - 30);

  -- approving a bill: the person who prepared it cannot approve it above the threshold
  perform test_helpers.login(v_admin);
  v_big := public.create_bill_draft(pt, 'key-p6-mc-01', v_va, v_today - 1, v_today + 20, '[{"description":"Big purchase","unit_price":15000000}]', 'MC-BIG');
  v_small := public.create_bill_draft(pt, 'key-p6-mc-02', v_va, v_today - 1, v_today + 20, '[{"description":"Small purchase","unit_price":5000000}]', 'MC-SMALL');
  v_fx := public.create_bill_draft(pt, 'key-p6-mc-03', v_va, v_today - 1, v_today + 20, '[{"description":"USD purchase, 15,000,000 in rupiah","unit_price":1000}]', 'MC-USD', 'USD', 15000);
  perform public.submit_bill(v_big, 'key-p6-mc-04');
  perform public.submit_bill(v_small, 'key-p6-mc-05');
  perform public.submit_bill(v_fx, 'key-p6-mc-06');
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-mc-07'')', v_big), 'FORBIDDEN', 'the preparer cannot approve a bill over the threshold');
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-mc-08'')', v_fx), 'FORBIDDEN', 'a 1,000 USD bill is 15,000,000 in rupiah: over the threshold, whatever the nominal amount');
  perform test_helpers.assert(public.approve_bill(v_small, 'key-p6-mc-09') = v_small, 'under the threshold the preparer may approve');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.assert(public.approve_bill(v_big, 'key-p6-mc-10') = v_big, 'a different person approves the big bill');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.approve_bill(v_fx, 'key-p6-mc-11') = v_fx, 'the OWNER is exempt');
  perform test_helpers.logout();

  -- paying: the same threshold, and a payment has no second approver, so above it only the OWNER pays
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-mc-12'', %L, %L, %L, 15000000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_big, 'amount', 15000000))::text), 'FORBIDDEN', 'a finance admin cannot pay 15,000,000 when a rule requires approval');
  perform test_helpers.assert(public.record_vendor_payment(pt, 'key-p6-mc-13', v_va, v_bca, v_today, 5000000, jsonb_build_array(jsonb_build_object('bill_id', v_big, 'amount', 5000000))) is not null,
    'under the threshold a finance admin pays');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-mc-14'', %L, %L, %L, 1000, %L::jsonb, 15000)', pt, v_va, v_usd, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_fx, 'amount', 1000))::text), 'FORBIDDEN', 'the threshold applies to a USD payment in rupiah');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.record_vendor_payment(pt, 'key-p6-mc-15', v_va, v_bca, v_today, 10000000, jsonb_build_array(jsonb_build_object('bill_id', v_big, 'amount', 10000000))) is not null,
    'the OWNER pays the rest');
  perform test_helpers.logout();

  -- confirming an expense: the preparer cannot confirm it above the threshold; someone else with bills.pay can
  perform test_helpers.login(v_admin);
  v_xa := public.create_expense_draft(pt, 'key-p6-mc-16', v_bca, v_today, '[{"description":"Big expense by the admin","unit_price":12000000}]', null, 'Toko Besar A', 'MC-X-A');
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-mc-17'')', v_xa), 'FORBIDDEN', 'the preparer cannot confirm a big expense');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  v_xs := public.create_expense_draft(pt, 'key-p6-mc-18', v_bca, v_today, '[{"description":"Big expense by staff","unit_price":12000000}]', null, 'Toko Besar B', 'MC-X-B');
  perform public.submit_expense(v_xs, 'key-p6-mc-19');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.assert(public.confirm_expense(v_xs, 'key-p6-mc-20') = v_xs, 'a finance admin confirms an expense someone else prepared');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.confirm_expense(v_xa, 'key-p6-mc-21') = v_xa, 'the OWNER confirms an expense he prepared or that the admin prepared');
  perform test_helpers.logout();
  delete from public.approval_rules where entity_id = pt;
  perform test_helpers.controls6(pt, 'after the maker-checker checks');
end
$$;

-- ================================================================ 11c. review hardening: backdating after a reversal, who prepared what, input limits
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_va uuid := test_helpers.g('va');
  v_bca uuid := test_helpers.g('bca');
  v_fxbill uuid;
  v_today date := test_helpers.today(pt);
  v_b uuid;
  v_b2 uuid;
  v_d uuid;
  v_e uuid;
  v_x uuid;
  v_xs uuid;
  v_pay uuid;
  v_pay2 uuid;
  v_journal uuid;
  v_name text;
  k integer;
begin
  select id into v_fxbill from public.bills where entity_id = pt and currency = 'USD' and status = 'approved' limit 1;
  select display_name into v_name from public.contacts where id = v_va;

  -- ---- a payment cannot be dated before a reversal on the same bill
  perform test_helpers.login(v_admin);
  v_b := public.create_bill_draft(pt, 'key-p6-bd-01', v_va, v_today - 4, v_today + 20, '[{"description":"Backdating check","unit_price":3000000}]', 'BD-1');
  perform public.submit_bill(v_b, 'key-p6-bd-02');
  perform public.approve_bill(v_b, 'key-p6-bd-03');
  v_pay := public.record_vendor_payment(pt, 'key-p6-bd-04', v_va, v_bca, v_today - 3, 3000000, jsonb_build_array(jsonb_build_object('bill_id', v_b, 'amount', 3000000)));
  perform public.reverse_vendor_payment(v_pay, 'key-p6-bd-05', v_today - 1, 'Transfer bounced');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-bd-06'', %L, %L, %L, 3000000, %L::jsonb)', pt, v_va, v_bca, v_today - 2,
    jsonb_build_array(jsonb_build_object('bill_id', v_b, 'amount', 3000000))::text), 'INVALID', 'a payment cannot be dated before a reversal on the same bill');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-bd-07'', %L, %L, %L, 3000000, %L::jsonb)', pt, v_va, v_bca, v_today - 3,
    jsonb_build_array(jsonb_build_object('bill_id', v_b, 'amount', 3000000))::text), 'INVALID', 'not even on the original payment day');
  v_pay2 := public.record_vendor_payment(pt, 'key-p6-bd-08', v_va, v_bca, v_today - 1, 3000000, jsonb_build_array(jsonb_build_object('bill_id', v_b, 'amount', 3000000)));
  perform test_helpers.assert((select settlement_status = 'paid' from public.list_bill_positions(pt) where bill_id = v_b), 'dated on the day of the reversal, the new payment is accepted');
  perform test_helpers.logout();
  perform test_helpers.controls6(pt, 'after re-paying a reversed payment');
  for k in 0 .. 6 loop
    perform test_helpers.assert((select sub_ledger = ledger_purchases from test_helpers.apc(pt, v_today - k)), 'AP control agrees as of ' || (v_today - k)::text || ' after re-paying');
    perform test_helpers.assert((select coalesce(min(outstanding::numeric), 0) >= 0 from test_helpers.bpos(pt, v_today - k)), 'no bill is negative as of ' || (v_today - k)::text);
  end loop;

  -- ---- direct writes cannot break what the workflow guarantees
  select journal_id into v_journal from public.vendor_payments where id = v_pay2;
  perform test_helpers.login(v_admin);
  v_b2 := public.create_bill_draft(pt, 'key-p6-bd-09', v_va, v_today - 2, v_today + 20, '[{"description":"Direct write check","unit_price":2000000}]', 'BD-2');
  perform public.submit_bill(v_b2, 'key-p6-bd-10');
  perform public.approve_bill(v_b2, 'key-p6-bd-11');
  perform test_helpers.logout();
  perform test_helpers.expect_msg(format('insert into public.vendor_payment_allocations (entity_id, payment_id, bill_id, amount, base_ap_amount, allocation_date, journal_id) values (%L, %L, %L, 1, 1, %L, %L)',
    pt, v_pay2, v_b2, v_today - 5, v_journal), 'CONFLICT: the allocation does not match', 'an allocation must carry its payment date');
  perform test_helpers.expect_msg(format('insert into public.vendor_payment_allocations (entity_id, payment_id, bill_id, amount, base_ap_amount, allocation_date, journal_id) values (%L, %L, %L, 1, 1, %L, %L)',
    pt, v_pay2, v_fxbill, v_today - 1, v_journal), 'CONFLICT: the allocation does not match', 'an allocation must match the currency of its payment');
  perform test_helpers.expect_error(format('update public.bills set status = ''void'' where id = %L', v_b), '23000', 'a bill with active allocations cannot be voided by any writer');

  -- ---- who prepared a purchase: whoever created, edited or submitted it cannot also approve it above the threshold
  insert into public.approval_rules (entity_id, module, action, min_amount, requires_approval, allow_self_approval, effective_from)
  values (pt, 'bills', 'approve', 10000000, true, false, v_today - 30),
         (pt, 'bills', 'pay', 10000000, true, false, v_today - 30);
  perform test_helpers.login(v_staff);
  v_e := public.create_bill_draft(pt, 'key-p6-bd-12', v_va, v_today - 1, v_today + 20, '[{"description":"Big bill drafted by staff","unit_price":15000000}]', 'BD-ED');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform public.update_bill_draft(v_e, '{"notes":"checked by the finance admin"}'::jsonb);
  perform public.submit_bill(v_e, 'key-p6-bd-13');
  perform test_helpers.expect_msg(format('select public.approve_bill(%L, ''key-p6-bd-14'')', v_e), 'FORBIDDEN', 'the person who edited and submitted a big bill cannot approve it');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.assert(public.approve_bill(v_e, 'key-p6-bd-15') = v_e, 'a person who never touched it approves');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  v_x := public.create_expense_draft(pt, 'key-p6-bd-16', v_bca, v_today, '[{"description":"Big expense drafted by staff","unit_price":12000000}]', null, 'Toko Besar C', 'BD-X-C');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform public.update_expense_draft(v_x, '{"notes":"checked by the finance admin"}'::jsonb);
  perform test_helpers.expect_msg(format('select public.confirm_expense(%L, ''key-p6-bd-17'')', v_x), 'FORBIDDEN', 'the person who edited a big expense cannot confirm it');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.confirm_expense(v_x, 'key-p6-bd-18') = v_x, 'the OWNER confirms it');
  perform test_helpers.logout();
  delete from public.approval_rules where entity_id = pt;

  -- ---- input limits are explicit errors
  perform test_helpers.login(v_admin);
  v_d := public.create_bill_draft(pt, 'key-p6-bd-19', v_va, v_today - 1, v_today + 20, '[{"description":"Limits check","unit_price":100000}]', 'BD-LIM');
  perform test_helpers.expect_msg(format('select public.cancel_bill(%L, ''key-p6-bd-20'', %L)', v_d, repeat('x', 1001)), 'INVALID', 'a cancellation reason is limited to 1000 characters');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-bd-21'', %L)', v_b2, repeat('x', 1001)), 'INVALID', 'a void reason is limited to 1000 characters');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-bd-22'', %L, %L)', v_pay2, v_today, repeat('x', 1001)), 'INVALID', 'a payment reversal reason is limited to 1000 characters');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-bd-23'', %L, %L, %L, ''[{"description":"Notes","unit_price":1000}]''::jsonb, p_notes => %L)', pt, v_va, v_today - 1, v_today + 20, repeat('n', 2001)),
    'INVALID', 'notes are limited to 2000 characters');
  perform test_helpers.expect_msg(format('select public.update_bill_draft(%L, jsonb_build_object(''internal_note'', %L))', v_d, repeat('n', 2001)), 'INVALID', 'a patch cannot carry a note over 2000 characters');
  perform test_helpers.expect_msg(format('select public.create_expense_draft(%L, ''key-p6-bd-24'', %L, %L, ''[{"description":"Notes","unit_price":1000}]''::jsonb, null, ''Kios'', ''BD-N'', null, %L)', pt, v_bca, v_today, repeat('n', 2001)),
    'INVALID', 'expense notes are limited to 2000 characters');
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-bd-25'', ''a.pdf'', null, 100, %L)', pt, repeat('a', 64)), 'INVALID', 'a document needs a file type');
  perform test_helpers.expect_msg(format('select public.register_document(%L, ''key-p6-bd-26'', ''a.pdf'', ''application/pdf'', null, %L)', pt, repeat('a', 64)), 'INVALID', 'a document needs a size');
  perform test_helpers.logout();

  -- ---- an expense keeps the payee as it was when it was confirmed
  perform test_helpers.login(v_admin);
  v_xs := public.create_expense_draft(pt, 'key-p6-bd-27', v_bca, v_today, '[{"description":"Snapshot check","unit_price":50000}]', v_va, null, 'BD-SNAP');
  perform public.confirm_expense(v_xs, 'key-p6-bd-28');
  perform test_helpers.logout();
  update public.contacts set display_name = 'Renamed Vendor After' where id = v_va;
  perform test_helpers.assert((select payee_snapshot ->> 'display_name' = v_name from public.expenses where id = v_xs), 'the snapshot keeps the name at confirmation');
  update public.contacts set display_name = v_name where id = v_va;
  perform test_helpers.assert((select payee_snapshot is null from public.expenses where id = v_x), 'a free-text payee has no contact snapshot');
  perform test_helpers.controls6(pt, 'after the hardening checks');
end
$$;

-- ================================================================ 12. the Personal Entity, isolation between Entities, privileges
do $$
declare
  pt uuid := test_helpers.entity('p6_pt');
  pe uuid := test_helpers.entity('p6_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_pe_admin uuid := 'c0000000-0000-0000-0000-000000000009';
  v_pe_v uuid := test_helpers.g('pe_v');
  v_pe_bank uuid := test_helpers.g('pe_bank');
  v_c uuid := test_helpers.g('bill_c');
  v_r uuid := test_helpers.g('bill_r');
  v_p3 uuid := test_helpers.g('pay_3');
  v_va uuid := test_helpers.g('va');
  v_bca uuid := test_helpers.g('bca');
  v_doc uuid;
  v_today date := test_helpers.today(pe);
  v_pb uuid;
  v_pp uuid;
  v_px uuid;
  v_j uuid;
  v_pe_bank_la uuid;
  t text;
begin
  select ledger_account_id into v_pe_bank_la from public.financial_accounts where id = v_pe_bank;
  -- ---- a personal bill uses the Personal Entity's default accounts
  perform test_helpers.login(v_pe_admin);
  v_pb := public.create_bill_draft(pe, 'key-p6-pe-01', v_pe_v, v_today - 2, v_today + 10,
    '[{"description":"Groceries delivery","unit_price":250000},{"description":"Bicycle","unit_price":3000000,"treatment":"asset"},{"description":"Deposit on rental","unit_price":1000000,"treatment":"prepaid"}]', 'PS-1');
  perform public.submit_bill(v_pb, 'key-p6-pe-02');
  perform public.approve_bill(v_pb, 'key-p6-pe-03');
  select journal_id into v_j from public.bills where id = v_pb;
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jd(v_j, 'OTHER_PERSONAL_EXPENSE') = 250000 and test_helpers.jd(v_j, 'PERSONAL_FIXED_ASSET') = 3000000
    and test_helpers.jd(v_j, 'PREPAID_DEPOSIT') = 1000000 and test_helpers.jc(v_j, 'ACCOUNTS_PAYABLE') = 4250000, 'personal bill: default personal expense, fixed asset and deposit accounts; Cr Personal Payables');
  perform test_helpers.login(v_pe_admin);
  v_pp := public.record_vendor_payment(pe, 'key-p6-pe-04', v_pe_v, v_pe_bank, v_today - 1, 1000000, jsonb_build_array(jsonb_build_object('bill_id', v_pb, 'amount', 1000000)), null, 'PERS-TRF');
  perform test_helpers.assert((select settled::numeric = 1000000 and settlement_status = 'partial' from public.list_bill_positions(pe) where bill_id = v_pb), 'a personal payment settles part of the bill');
  v_px := public.create_expense_draft(pe, 'key-p6-pe-05', v_pe_bank, v_today, '[{"description":"Lunch","unit_price":60000}]', null, 'Warung Makan');
  perform public.confirm_expense(v_px, 'key-p6-pe-06');
  perform test_helpers.logout();
  perform test_helpers.assert(test_helpers.jd((select journal_id from public.expenses where id = v_px), 'OTHER_PERSONAL_EXPENSE') = 60000, 'a personal expense debits the personal expense account');
  perform test_helpers.assert((select ledger_balance = -1060000 and movement_balance = -1060000 from test_helpers.mc(pe) where financial_account_id = v_pe_bank), 'the personal bank account reflects both payments');
  perform test_helpers.controls6(pe, 'the personal Entity');

  -- ---- nothing crosses the boundary between the two Entities
  perform test_helpers.login(v_pe_admin);
  perform test_helpers.assert((select count(*) from public.bills) = 1 and (select count(*) from public.vendor_payments) = 1 and (select count(*) from public.expenses) = 1, 'the personal admin sees only personal purchases');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-xe-01'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_c, 'amount', 1000))::text), 'FORBIDDEN', 'a personal admin cannot pay a company bill');
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p6-xe-02'', ''Cross entity void'')', v_r), 'FORBIDDEN', 'nor void one');
  perform test_helpers.expect_msg(format('select public.reverse_vendor_payment(%L, ''key-p6-xe-03'', %L, ''Cross entity reversal'')', v_p3, v_today), 'FORBIDDEN', 'nor reverse a company payment');
  perform test_helpers.expect_msg(format('select * from public.list_bill_positions(%L)', pt), 'FORBIDDEN', 'nor read company positions');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-xe-04'', %L, %L, %L, 1000, %L::jsonb)', pe, v_pe_v, v_pe_bank, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_pb, 'amount', 1000))::text), 'FORBIDDEN', 'a company admin cannot pay a personal bill');
  perform test_helpers.logout();
  -- the OWNER belongs to both Entities, and even then a document of one cannot serve the other
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-xe-05'', %L, %L, %L, 1000, %L::jsonb)', pt, v_va, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_pb, 'amount', 1000))::text), 'INVALID', 'a personal bill cannot be paid inside the company Entity');
  perform test_helpers.expect_msg(format('select public.record_vendor_payment(%L, ''key-p6-xe-06'', %L, %L, %L, 1000, %L::jsonb)', pe, v_pe_v, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('bill_id', v_pb, 'amount', 1000))::text), 'INVALID', 'a company account cannot pay a personal bill');
  perform test_helpers.expect_msg(format('select public.create_bill_draft(%L, ''key-p6-xe-07'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pe, v_va, v_today, v_today), 'INVALID', 'a company vendor is not a personal vendor');
  v_doc := public.register_document(pt, 'key-p6-xe-08', 'company-only.pdf', 'application/pdf', 5000, encode(sha256('p6-company-only'::bytea), 'hex'));
  perform test_helpers.expect_msg(format('select public.link_document(%L, ''expense'', %L)', v_doc, v_px), 'INVALID', 'a company document cannot be attached to a personal expense');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.assert((select count(*) from public.bills) = 0 and (select count(*) from public.vendor_payments) = 0 and (select count(*) from public.expenses) = 0
    and (select count(*) from public.documents) = 0 and (select count(*) from public.document_links) = 0 and (select count(*) from public.vendor_payment_allocations) = 0
    and (select count(*) from public.bill_lines) = 0 and (select count(*) from public.expense_lines) = 0, 'a stranger sees no purchase data at all');
  perform test_helpers.logout();

  -- ---- capacity and integrity are enforced by the database itself, not only by the commands
  perform test_helpers.expect_error(format('insert into public.vendor_payment_allocations (entity_id, payment_id, bill_id, amount, base_ap_amount, allocation_date) values (%L, %L, %L, 1, 1, current_date)', pt, v_p3, v_c),
    '23000', 'a paid bill takes no further allocation, even from a superuser session');
  perform test_helpers.expect_error(format('insert into public.vendor_payment_allocations (entity_id, payment_id, bill_id, amount, base_ap_amount, allocation_date) values (%L, %L, %L, 1, 1, current_date)', pt, v_p3, test_helpers.g('bill_d')),
    '23000', 'a draft bill takes no allocation');
  perform test_helpers.expect_error(format('update public.bill_lines set posted_account_id = null where bill_id = %L', v_r), '23000', 'the posted account of an approved line is frozen');

  -- ---- browser roles have no direct write access to any P6 table
  perform test_helpers.login(v_owner);
  foreach t in array array['bills', 'bill_lines', 'vendor_payments', 'vendor_payment_allocations', 'expenses', 'expense_lines', 'documents', 'document_links'] loop
    perform test_helpers.expect_error(format('insert into public.%I select * from public.%I limit 1', t, t), '42501', format('the OWNER cannot insert into %s directly', t));
    perform test_helpers.expect_error(format('update public.%I set version = version', t), '42501', format('nor update %s', t));
    perform test_helpers.expect_error(format('delete from public.%I', t), '42501', format('nor delete from %s', t));
    perform test_helpers.expect_error(format('truncate public.%I', t), '42501', format('nor truncate %s', t));
  end loop;
  perform test_helpers.logout();
  foreach t in array array['bills', 'bill_lines', 'vendor_payments', 'vendor_payment_allocations', 'expenses', 'expense_lines', 'documents', 'document_links'] loop
    perform test_helpers.expect_error(format('truncate public.%I cascade', t), null, format('nobody truncates %s, not even a superuser', t));
  end loop;
  perform test_helpers.as_anon();
  foreach t in array array['bills', 'bill_lines', 'vendor_payments', 'vendor_payment_allocations', 'expenses', 'expense_lines', 'documents', 'document_links'] loop
    perform test_helpers.expect_error(format('select 1 from public.%I', t), '42501', format('anonymous cannot read %s', t));
  end loop;
  perform test_helpers.logout();
end
$$;

rollback;
