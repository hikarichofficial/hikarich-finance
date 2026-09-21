-- P8 gate, part 1 (Step 15 §12, Step 16 G8): the Asset Register reconciles to the General Ledger.
-- Covers registration from bills and expenses, the operational events that post nothing, splitting, activation and
-- the depreciation plan (straight-line, declining balance, none), posting and reversing depreciation, prospective
-- re-planning, voiding and cancelling, sale and disposal with their receivable, reversal of a disposal, opening
-- assets, the fiscal memo schedule, the asset control, Personal assets and authorization. All data is synthetic; dates
-- are relative to the Entity's today. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p8a (k text primary key, v uuid not null);
grant all on test_helpers.p8a to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p8a values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p8a where k = p_k $f$;
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

-- Asset by name (a name is unique inside each scenario).
create function test_helpers.asset(p_entity uuid, p_name text) returns uuid
language sql security definer set search_path = pg_catalog, public as $f$
  select id from public.fixed_assets where entity_id = p_entity and name = p_name and status <> 'cancelled' $f$;
grant execute on function test_helpers.asset(uuid, text) to public;

-- The invariants of the asset layer, checked after every major step.
create function test_helpers.controls8a(p_entity uuid, p_label text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $f$
declare
  c record;
begin
  if exists (select 1 from app_private.money_control_rows(p_entity) r where r.ledger_balance <> r.movement_base_balance) then
    raise exception 'TEST FAIL [%]: money movements differ from the ledger', p_label;
  end if;
  for c in select * from app_private.asset_control(p_entity) loop
    if c.sub_ledger <> c.ledger_total then
      raise exception 'TEST FAIL [%]: asset control % sub-ledger % differs from ledger %', p_label, c.account_key, c.sub_ledger, c.ledger_total;
    end if;
  end loop;
  -- Depreciation never exceeds the depreciable basis, and a plan writes off exactly what is left.
  if exists (select 1 from public.fixed_assets f
             where f.entity_id = p_entity and f.status = 'active'
               and app_private.asset_accumulated(f.id) > f.acquisition_cost - f.residual_value) then
    raise exception 'TEST FAIL [%]: an asset is depreciated below its residual value', p_label;
  end if;
  if exists (select 1 from public.fixed_assets f
             where f.entity_id = p_entity and f.status = 'active' and f.depreciation_method <> 'none'
               and app_private.asset_accumulated(f.id)
                   + coalesce((select sum(l.amount) from public.asset_depreciation_lines l where l.asset_id = f.id and l.status = 'scheduled'), 0)
                   <> f.acquisition_cost - f.residual_value) then
    raise exception 'TEST FAIL [%]: posted plus scheduled depreciation is not the depreciable basis', p_label;
  end if;
  -- A purchase line's registered assets add up to the cost the ledger holds.
  if exists (select 1 from public.bill_lines l
             where l.entity_id = p_entity and l.asset_link_status = 'linked'
               and l.base_amount <> (select coalesce(sum(f.acquisition_cost), 0) from public.fixed_assets f
                                     where f.bill_line_id = l.id and f.status <> 'cancelled')) then
    raise exception 'TEST FAIL [%]: the assets of a bill line do not add up to its cost', p_label;
  end if;
  if exists (select 1 from public.expense_lines l
             where l.entity_id = p_entity and l.asset_link_status = 'linked'
               and l.base_amount <> (select coalesce(sum(f.acquisition_cost), 0) from public.fixed_assets f
                                     where f.expense_line_id = l.id and f.status <> 'cancelled')) then
    raise exception 'TEST FAIL [%]: the assets of an expense line do not add up to its cost', p_label;
  end if;
  -- Every posted depreciation line has its journal; no month is posted twice.
  if exists (select 1 from public.asset_depreciation_lines l where l.entity_id = p_entity and l.status = 'posted' and l.journal_id is null) then
    raise exception 'TEST FAIL [%]: a posted depreciation line has no journal', p_label;
  end if;
end
$f$;
grant execute on function test_helpers.controls8a(uuid, text) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
  v_op uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p8a_pt', 'P8A PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p8a_pe', 'P8A PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p8a_op', 'P8A OPENING PT (synthetic)') returning id into v_op;
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

-- ================================================================ 1. setup: accounts, vendor, category
do $$
declare
  pt uuid := test_helpers.entity('p8a_pt');
  pe uuid := test_helpers.entity('p8a_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_cat uuid;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.put('bca', public.create_financial_account(pt, 'key-p8a-fa-01', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-SECRET-1', 'PT P8A'));
  perform test_helpers.put('cash', public.create_financial_account(pt, 'key-p8a-fa-02', 'cash', 'Petty Cash', 'IDR', test_helpers.acct(pt, 'CASH')));
  perform test_helpers.put('usd', public.create_financial_account(pt, 'key-p8a-fa-03', 'bank', 'USD Account', 'USD'));
  perform test_helpers.put('pe_bank', public.create_financial_account(pe, 'key-p8a-fa-04', 'bank', 'Personal BCA', 'IDR', test_helpers.acct(pe, 'PERSONAL_BANK')));
  perform test_helpers.put('va', public.create_contact(pt, 'key-p8a-ct-01', 'vendor', 'Vendor A'));
  perform test_helpers.put('pe_v', public.create_contact(pe, 'key-p8a-ct-02', 'vendor', 'Personal Shop'));
  perform test_helpers.logout();
  insert into public.categories (entity_id, name, kind) values (pt, 'Equipment', 'asset') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, debit_ledger_account_id, effective_from)
  values (pt, v_cat, 'purchases', test_helpers.acct(pt, 'FIXED_ASSET_EQUIPMENT'), date '2000-01-01');
  perform test_helpers.put('cat_asset', v_cat);
end
$$;

-- ================================================================ 2. approving a bill registers its asset lines as draft assets
do $$
declare
  pt uuid := test_helpers.entity('p8a_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_acq date := (date_trunc('month', test_helpers.today(pt)) - interval '5 months')::date + 9;
  v_b uuid;
  v_j uuid;
  v_laptop uuid;
  v_monitor uuid;
  a public.fixed_assets%rowtype;
begin
  perform test_helpers.login(v_owner);
  v_b := public.create_bill_draft(pt, 'key-p8a-b-01', test_helpers.g('va'), v_acq, v_acq + 30,
    jsonb_build_array(
      jsonb_build_object('description', 'Laptop', 'unit_price', '12000000', 'treatment', 'asset', 'category_id', test_helpers.g('cat_asset')),
      jsonb_build_object('description', 'Monitor', 'unit_price', '3000000', 'treatment', 'asset'),
      jsonb_build_object('description', 'Printer paper', 'unit_price', '100000', 'treatment', 'expense')),
    'INV-P8A-1');
  perform test_helpers.put('bill1', v_b);
  perform test_helpers.assert(not exists (select 1 from public.fixed_assets where entity_id = pt), 'a draft bill registers nothing');
  v_j := public.approve_bill(v_b, 'key-p8a-b-01a');
  perform test_helpers.logout();

  perform test_helpers.assert((select count(*) from public.fixed_assets where entity_id = pt) = 2, 'approving registers one draft asset per asset line');
  select * into a from public.fixed_assets where entity_id = pt and name = 'Laptop';
  perform test_helpers.assert(a.status = 'draft' and a.condition = 'in_use' and a.source_type = 'bill_line' and a.acquisition_cost = 12000000
    and a.acquisition_date = v_acq and a.cost_account_id = test_helpers.acct(pt, 'FIXED_ASSET_EQUIPMENT') and a.asset_code like 'AST-%'
    and a.in_service_date is null and a.depreciation_method is null and a.plan_version = 0 and a.bill_line_id is not null,
    'the draft asset carries the cost, account and date of its purchase line, and no depreciation setup');
  select * into a from public.fixed_assets where entity_id = pt and name = 'Monitor';
  perform test_helpers.assert(a.acquisition_cost = 3000000 and a.cost_account_id = test_helpers.acct(pt, 'FIXED_ASSET_OTHER'), 'the default asset account applies to a line without category');
  perform test_helpers.assert((select array_agg(asset_link_status order by line_no) from public.bill_lines where bill_id = v_b) = array['linked', 'linked', 'none'],
    'the asset lines are linked and the expense line is not');
  perform test_helpers.assert((select count(*) from public.asset_events where entity_id = pt and event_type = 'registered') = 2, 'each registration is logged');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = pt and source_type like 'asset%'), 'registration posts nothing: the purchase journal holds the cost');
  perform test_helpers.assert(test_helpers.bal(pt, 'FIXED_ASSET_EQUIPMENT') = 12000000 and test_helpers.bal(pt, 'FIXED_ASSET_OTHER') = 3000000, 'the ledger holds the cost');
  perform test_helpers.controls8a(pt, 'after registration');
  perform test_helpers.put('laptop', test_helpers.asset(pt, 'Laptop'));
  perform test_helpers.put('monitor', test_helpers.asset(pt, 'Monitor'));

  -- the lines of an approved bill stay frozen, except the asset link that the register maintains
  perform test_helpers.expect_error(format('update public.bill_lines set unit_price = 1 where bill_id = %L', v_b), '23000', 'the lines of an approved bill are frozen');
  perform test_helpers.expect_error(format('update public.bill_lines set asset_link_status = ''none'', description = ''x'' where bill_id = %L and line_no = 1', v_b), '23000',
    'nothing but the asset link may change on an approved asset line');
  perform test_helpers.expect_error(format('update public.bill_lines set asset_link_status = ''pending'' where bill_id = %L and line_no = 3', v_b), '23000',
    'a non-asset line never changes');
end
$$;

-- ================================================================ 3. draft assets: details, transfer, condition, split
do $$
declare
  pt uuid := test_helpers.entity('p8a_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_laptop uuid := test_helpers.g('laptop');
  v_ids uuid[];
  v_ids2 uuid[];
  a public.fixed_assets%rowtype;
begin
  perform test_helpers.login(v_owner);
  perform public.asset_update_details(v_laptop, 'Laptop', 'MacBook for design work', 'SN-123');
  perform public.asset_transfer(v_laptop, 'Head office', 'Design team', test_helpers.today(pt), 'Assigned on delivery');
  perform public.asset_set_condition(v_laptop, 'in_storage', test_helpers.today(pt));
  perform public.asset_set_condition(v_laptop, 'in_use', test_helpers.today(pt));
  perform test_helpers.expect_msg(format('select public.asset_set_condition(%L, ''damaged'', %L)', v_laptop, test_helpers.today(pt)), 'INVALID', 'damage needs a note');
  perform test_helpers.expect_msg(format('select public.asset_set_condition(%L, ''broken'', %L)', v_laptop, test_helpers.today(pt)), 'INVALID', 'unknown condition');
  perform test_helpers.expect_msg(format('select public.asset_transfer(%L, null, null, %L)', v_laptop, test_helpers.today(pt)), 'INVALID', 'a transfer names a location or a custodian');
  perform test_helpers.logout();
  select * into a from public.fixed_assets where id = v_laptop;
  perform test_helpers.assert(a.description = 'MacBook for design work' and a.serial_number = 'SN-123' and a.location = 'Head office' and a.custodian = 'Design team' and a.condition = 'in_use',
    'details, location and custody are recorded');
  perform test_helpers.assert((select count(*) from public.asset_events where asset_id = v_laptop and event_type in ('transferred', 'condition_changed', 'details_changed')) = 4,
    'operational changes are logged');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = pt and source_type like 'asset%'), 'operational changes post nothing');

  -- splitting: the parts add up to the cost of the purchase line
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.asset_split(%L, ''key-p8a-sp-0'', %L::jsonb)', v_laptop,
    '[{"name":"Laptop A","cost":"7000000"},{"name":"Laptop B","cost":"4000000"}]'), 'INVALID', 'the parts must add up to the cost');
  perform test_helpers.expect_msg(format('select public.asset_split(%L, ''key-p8a-sp-0b'', %L::jsonb)', v_laptop,
    '[{"name":"Laptop A","cost":"12000000"}]'), 'INVALID', 'a split needs at least two parts');
  v_ids := public.asset_split(v_laptop, 'key-p8a-sp-1', '[{"name":"Laptop A","cost":"7000000"},{"name":"Laptop B","cost":"5000000"}]'::jsonb);
  v_ids2 := public.asset_split(v_laptop, 'key-p8a-sp-1', '[{"name":"Laptop A","cost":"7000000"},{"name":"Laptop B","cost":"5000000"}]'::jsonb);
  perform test_helpers.logout();
  perform test_helpers.assert(array_length(v_ids, 1) = 2 and v_ids[1] = v_laptop and v_ids = v_ids2, 'the split replays on the same key; the first part is the original');
  perform test_helpers.assert((select array_agg(acquisition_cost::numeric order by name) from public.fixed_assets where entity_id = pt and name like 'Laptop %') = array[7000000, 5000000]::numeric[]
    and (select count(*) from public.fixed_assets where entity_id = pt and split_from_asset_id = v_laptop) = 1, 'two parts, 7,000,000 and 5,000,000');
  perform test_helpers.put('laptop_a', test_helpers.asset(pt, 'Laptop A'));
  perform test_helpers.put('laptop_b', test_helpers.asset(pt, 'Laptop B'));
  perform test_helpers.assert((select bool_and(bill_line_id = (select bill_line_id from public.fixed_assets where id = v_laptop)) from public.fixed_assets where entity_id = pt and name like 'Laptop %'), 'the parts share the purchase line');
  perform test_helpers.controls8a(pt, 'after the split');
end
$$;

-- ================================================================ 4. activation and the depreciation plan
do $$
declare
  pt uuid := test_helpers.entity('p8a_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_today date := test_helpers.today(pt);
  v_acq date := (date_trunc('month', test_helpers.today(pt)) - interval '5 months')::date + 9;
  v_a uuid := test_helpers.g('laptop_a');
  v_b uuid := test_helpers.g('laptop_b');
  v_m uuid := test_helpers.g('monitor');
  v_n integer;
  a public.fixed_assets%rowtype;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-0'', %L, ''straight_line'', 48)', v_a, v_today + 1), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-0b'', %L, ''straight_line'', 48)', v_a, v_acq - 1), 'INVALID', 'not before the acquisition');
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-0c'', %L, ''straight_line'', null)', v_a, v_acq), 'INVALID', 'a depreciated asset needs a life');
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-0d'', %L, ''straight_line'', 48, ''8000000'')', v_a, v_acq), 'INVALID', 'the residual cannot exceed the cost');
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-0e'', %L, ''none'', 48)', v_a, v_acq), 'INVALID', 'an undepreciated asset has no life');
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-0f'', %L, ''sum_of_digits'', 48)', v_a, v_acq), 'INVALID', 'unknown method');
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-0g'', %L, ''straight_line'', 48, ''0'', ''group_9'')', v_a, v_acq), 'INVALID', 'unknown fiscal class');
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-0h'', %L, ''declining_balance'', 48, ''0'', ''building_permanent'', ''declining_balance'')', v_a, v_acq), 'INVALID', 'buildings are straight-line only');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-0i'', %L, ''straight_line'', 48)', v_a, v_acq), 'FORBIDDEN', 'a viewer cannot activate');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.fixed_assets where id = v_a) = 'draft', 'refused activations change nothing');

  perform test_helpers.login(v_owner);
  v_n := public.asset_activate(v_a, 'key-p8a-ac-1', v_acq, 'straight_line', 48, '1000000', 'group_1', 'straight_line');
  perform test_helpers.assert(public.asset_activate(v_a, 'key-p8a-ac-1', v_acq, 'straight_line', 48, '1000000', 'group_1', 'straight_line') = v_n, 'activation replays on the same key');
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-ac-1x'', %L, ''straight_line'', 48)', v_a, v_acq), 'CONFLICT', 'an active asset is not activated again');
  perform test_helpers.assert(v_n = 48, 'straight-line over 48 months has 48 lines');
  v_n := public.asset_activate(v_b, 'key-p8a-ac-2', v_acq, 'declining_balance', 48, '500000', 'group_1', 'declining_balance');
  perform public.asset_activate(v_m, 'key-p8a-ac-3', v_acq, 'none', null);
  perform test_helpers.logout();

  select * into a from public.fixed_assets where id = v_a;
  perform test_helpers.assert(a.status = 'active' and a.in_service_date = v_acq and a.depreciation_method = 'straight_line' and a.useful_life_months = 48
    and a.residual_value = 1000000 and a.plan_version = 1 and a.fiscal_class_key = 'group_1' and a.activated_by = v_owner, 'activation records the setup');
  -- (7,000,000 - 1,000,000) / 48 = 125,000 a month, exactly
  perform test_helpers.assert((select sum(amount) from public.asset_depreciation_lines where asset_id = v_a) = 6000000
    and (select min(amount) from public.asset_depreciation_lines where asset_id = v_a) = 125000
    and (select max(amount) from public.asset_depreciation_lines where asset_id = v_a) = 125000
    and (select min(period_month) from public.asset_depreciation_lines where asset_id = v_a) = date_trunc('month', v_acq)::date
    and (select count(*) from public.asset_depreciation_lines where asset_id = v_a and status = 'scheduled') = 48, 'the SL plan: 125,000 a month from the in-service month');
  perform test_helpers.assert((select sum(amount) from public.asset_depreciation_lines where asset_id = v_b) = 4500000
    and (select count(*) from public.asset_depreciation_lines where asset_id = v_b) = 48
    and (select amount from public.asset_depreciation_lines where asset_id = v_b order by period_month limit 1) = 208333.33
    and (select amount from public.asset_depreciation_lines where asset_id = v_b order by period_month limit 1)
      > (select amount from public.asset_depreciation_lines where asset_id = v_b order by period_month desc limit 1),
    'the declining-balance plan writes off the basis, starting at 5,000,000 x 2 / 48 = 208,333.33, and declines');
  perform test_helpers.assert(not exists (select 1 from public.asset_depreciation_lines where asset_id = v_m), 'an asset that is not depreciated has no schedule');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = pt and source_type like 'asset%'), 'activation posts nothing');
  perform test_helpers.controls8a(pt, 'after activation');

  -- a fiscal group is a memo: it never touches the ledger
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select sum(depreciation::numeric) from public.asset_fiscal_schedule(v_a)) = 7000000, 'the fiscal schedule writes off the whole cost');
  perform test_helpers.assert((select count(*) from public.asset_fiscal_schedule(v_a)) = 5 and (select rule_version from public.asset_fiscal_schedule(v_a) limit 1) = 1, 'a 4-year group spans five fiscal years when it starts mid-year (or four from January)');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 5. posting depreciation
do $$
declare
  pt uuid := test_helpers.entity('p8a_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_today date := test_helpers.today(pt);
  v_through date := (date_trunc('month', test_helpers.today(pt)) - interval '1 day')::date;
  v_a uuid := test_helpers.g('laptop_a');
  v_b uuid := test_helpers.g('laptop_b');
  v_m uuid := test_helpers.g('monitor');
  r jsonb;
  v_line uuid;
  v_j uuid;
  v_exp numeric;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select count(*) from public.asset_depreciation_due(pt)) = 10, 'ten months are due: five for each depreciated asset');
  perform test_helpers.expect_msg(format('select public.asset_post_depreciation(%L, %L)', pt, v_through - 3), 'INVALID', 'post through a month-end');
  perform test_helpers.expect_msg(format('select public.asset_post_depreciation(%L, %L)', pt, (date_trunc('month', v_today) + interval '1 month - 1 day')::date), 'INVALID', 'not through a month that is not over');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.asset_post_depreciation(%L, %L)', pt, v_through), 'FORBIDDEN', 'a viewer cannot post depreciation');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  r := public.asset_post_depreciation(pt, v_through);
  perform test_helpers.assert((r ->> 'posted')::integer = 10, 'ten months were posted');
  perform test_helpers.assert(public.asset_post_depreciation(pt, v_through) ->> 'posted' = '0', 'the run is repeatable and posts nothing twice');
  perform test_helpers.logout();
  select coalesce(sum(amount), 0) into v_exp from public.asset_depreciation_lines where entity_id = pt and status = 'posted';
  perform test_helpers.assert((r ->> 'total')::numeric = v_exp and v_exp > 625000, 'the reported total equals the posted lines');
  perform test_helpers.assert(test_helpers.bal(pt, 'DEPRECIATION_EXPENSE') = v_exp and test_helpers.bal(pt, 'ACCUMULATED_DEPRECIATION') = -v_exp, 'Dr Depreciation Expense / Cr Accumulated Depreciation');
  perform test_helpers.assert((select count(*) from public.journal_entries where entity_id = pt and source_type = 'asset_depreciation' and status = 'posted') = 10
    and (select bool_and(entry_date = app_private.month_end(l.period_month)) from public.asset_depreciation_lines l join public.journal_entries j on j.id = l.journal_id where l.entity_id = pt),
    'one journal per asset and month, dated the last day of the month');
  perform test_helpers.assert((select sum(amount) from public.asset_depreciation_lines where asset_id = v_a and status = 'posted') = 625000, 'five months of 125,000 for Laptop A');
  perform test_helpers.controls8a(pt, 'after the first depreciation run');

  -- a posted month is reversed with a reason and is due again
  select id, journal_id into v_line, v_j from public.asset_depreciation_lines where asset_id = v_a and status = 'posted' order by period_month limit 1;
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.asset_reverse_depreciation(%L, ''key-p8a-rd-0'', %L, ''no'')', v_line, v_today), 'INVALID', 'a reversal needs a reason');
  perform test_helpers.assert(public.asset_reverse_depreciation(v_line, 'key-p8a-rd-1', v_today, 'Posted with the wrong estimate') is not null, 'the owner reverses a month');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.asset_depreciation_lines where id = v_line) = 'reversed'
    and (select count(*) from public.asset_depreciation_lines where asset_id = v_a and period_month = (select period_month from public.asset_depreciation_lines where id = v_line) and status = 'scheduled') = 1
    and (select sum(amount) from public.asset_depreciation_lines where asset_id = v_a and status = 'posted') = 500000, 'the month is reversed and scheduled again');
  perform test_helpers.controls8a(pt, 'after reversing a month');

  -- re-plan (change of estimate) is prospective: the posted months stay; the rest is planned again
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.asset_replan(%L, ''key-p8a-rp-0'', ''straight_line'', 30, ''0'', ''no'')', v_a), 'INVALID', 'a change of estimate needs a reason');
  perform test_helpers.expect_msg(format('select public.asset_replan(%L, ''key-p8a-rp-0b'', ''straight_line'', 30, ''0'', ''Life shortened after review'')', v_a), 'CONFLICT',
    'a re-plan is refused while a month before the latest posted one is unposted');
  perform public.asset_post_depreciation(pt, v_through);
  perform test_helpers.assert(public.asset_replan(v_a, 'key-p8a-rp-1', 'straight_line', 30, '500000', 'Life shortened after review') = 30, 'thirty months are planned');
  perform test_helpers.logout();
  perform test_helpers.assert((select sum(amount) from public.asset_depreciation_lines where asset_id = v_a and status = 'scheduled') = 7000000 - 625000 - 500000
    and (select useful_life_months from public.fixed_assets where id = v_a) = 5 + 30 and (select plan_version from public.fixed_assets where id = v_a) = 2
    and (select min(period_month) from public.asset_depreciation_lines where asset_id = v_a and status = 'scheduled') = date_trunc('month', v_today)::date,
    'the rest of the book value is written off over the new life, from the current month');
  perform test_helpers.assert((select sum(amount) from public.asset_depreciation_lines where asset_id = v_a and status = 'posted') = 625000, 'posted months are untouched by a re-plan');
  perform test_helpers.controls8a(pt, 'after the re-plan');

  -- the register
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select accumulated::numeric from public.asset_register(pt) where asset_id = v_a) = 625000
    and (select net_book_value::numeric from public.asset_register(pt) where asset_id = v_a) = 6375000
    and (select status from public.asset_register(pt) where asset_id = v_m) = 'active', 'the register shows cost, accumulated depreciation and book value');
  perform test_helpers.assert(jsonb_array_length((public.asset_detail(v_a)) -> 'schedule') > 30 and jsonb_array_length((public.asset_detail(v_a)) -> 'events') >= 3, 'the detail carries schedule and events');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. sale (cash), disposal reversal, loss on a sale
do $$
declare
  pt uuid := test_helpers.entity('p8a_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_m uuid := test_helpers.g('monitor');
  v_bca uuid := test_helpers.g('bca');
  v_d uuid;
  v_before numeric;
  d public.asset_disposals%rowtype;
begin
  select ledger_balance into v_before from test_helpers.mc(pt) where financial_account_id = v_bca;
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.asset_dispose(%L, ''key-p8a-ds-0'', ''sale'', %L, ''2000000'', ''none'', null, null, null, ''Sold'')', v_m, v_today), 'INVALID', 'proceeds need a method');
  perform test_helpers.expect_msg(format('select public.asset_dispose(%L, ''key-p8a-ds-0b'', ''scrapped'', %L, ''1000'', ''cash'', %L, null, null, ''Scrapped'')', v_m, v_today, v_bca), 'INVALID', 'only a sale has proceeds');
  perform test_helpers.expect_msg(format('select public.asset_dispose(%L, ''key-p8a-ds-0c'', ''sale'', %L, ''2000000'', ''cash'', %L, null, null, ''Sold'')', v_m, v_today + 1, v_bca), 'INVALID', 'not in the future');
  perform test_helpers.expect_msg(format('select public.asset_dispose(%L, ''key-p8a-ds-0d'', ''sale'', %L, ''2000000'', ''cash'', %L, null, null, ''Sold'')', v_m, v_today, test_helpers.g('usd')), 'INVALID', 'proceeds go to a base-currency account');
  v_d := public.asset_dispose(v_m, 'key-p8a-ds-1', 'sale', v_today, '2000000', 'cash', v_bca, null, null, 'Sold to an employee');
  perform test_helpers.assert(public.asset_dispose(v_m, 'key-p8a-ds-1', 'sale', v_today, '2000000', 'cash', v_bca, null, null, 'Sold to an employee') = v_d, 'a disposal replays on the same key');
  perform test_helpers.expect_msg(format('select public.asset_dispose(%L, ''key-p8a-ds-1b'', ''scrapped'', %L, ''0'', ''none'', null, null, null, ''again'')', v_m, v_today), 'CONFLICT', 'a sold asset is not disposed of again');
  perform test_helpers.logout();
  select * into d from public.asset_disposals where id = v_d;
  perform test_helpers.assert(d.status = 'posted' and d.cost_removed = 3000000 and d.accumulated_removed = 0 and d.net_book_value = 3000000 and d.proceeds = 2000000 and d.gain_loss = -1000000
    and d.proceeds_method = 'cash' and d.financial_account_id = v_bca, 'sold for 2,000,000 against a book value of 3,000,000: a loss of 1,000,000');
  perform test_helpers.assert(test_helpers.jd(d.journal_id, 'ASSET_DISPOSAL_GAIN_LOSS') = 1000000 and test_helpers.jc(d.journal_id, 'FIXED_ASSET_OTHER') = 3000000
    and test_helpers.jd(d.journal_id, 'BANK_OPERATING') = 2000000, 'Dr bank, Dr loss, Cr the cost of the asset');
  perform test_helpers.assert((select status from public.fixed_assets where id = v_m) = 'sold', 'the asset is sold');
  perform test_helpers.assert(test_helpers.bal(pt, 'FIXED_ASSET_OTHER') = 0, 'the cost left the ledger');
  perform test_helpers.assert((select ledger_balance from test_helpers.mc(pt) where financial_account_id = v_bca) = v_before + 2000000, 'the proceeds reached the bank account');
  perform test_helpers.controls8a(pt, 'after a cash sale');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.asset_transfer(%L, ''X'', null, %L)', v_m, v_today), 'CONFLICT', 'a sold asset is not transferred');

  -- the disposal is reversed with a reason: the asset returns to service and the money mirrors back
  perform test_helpers.expect_msg(format('select public.asset_reverse_disposal(%L, ''key-p8a-dr-0'', %L, ''no'')', v_d, v_today), 'INVALID', 'a reversal needs a reason');
  perform test_helpers.assert(public.asset_reverse_disposal(v_d, 'key-p8a-dr-1', v_today, 'Buyer backed out') is not null, 'the disposal is reversed');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.fixed_assets where id = v_m) = 'active' and (select status from public.asset_disposals where id = v_d) = 'reversed'
    and test_helpers.bal(pt, 'FIXED_ASSET_OTHER') = 3000000 and test_helpers.bal(pt, 'ASSET_DISPOSAL_GAIN_LOSS') = 0
    and (select ledger_balance from test_helpers.mc(pt) where financial_account_id = v_bca) = v_before, 'the asset, the ledger and the bank are back');
  perform test_helpers.controls8a(pt, 'after reversing the sale');
  -- a reversed disposal is history
  perform test_helpers.expect_error(format('update public.asset_disposals set proceeds = 1 where id = %L', v_d), '23000', 'a reversed disposal cannot change');
end
$$;

-- ================================================================ 7. an expense-funded asset: catch-up depreciation, sale on credit, settlement, reversal
do $$
declare
  pt uuid := test_helpers.entity('p8a_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_acq date := (date_trunc('month', test_helpers.today(pt)) - interval '5 months')::date + 9;
  v_cash uuid := test_helpers.g('cash');
  v_bca uuid := test_helpers.g('bca');
  v_x uuid;
  v_srv uuid;
  v_d uuid;
  v_o uuid;
  v_s uuid;
  d public.asset_disposals%rowtype;
  o public.other_obligations%rowtype;
begin
  perform test_helpers.login(v_owner);
  -- fund the cash box first (an owner contribution is P8 part 3; a plain transfer from the bank is enough here)
  v_x := public.create_expense_draft(pt, 'key-p8a-ex-1', v_cash, v_acq,
    jsonb_build_array(jsonb_build_object('description', 'Server', 'unit_price', '20000000', 'treatment', 'asset')), null, 'Server Shop', 'RCPT-SRV');
  perform test_helpers.put('exp_srv', v_x);
  perform public.confirm_expense(v_x, 'key-p8a-ex-1c');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.fixed_assets where entity_id = pt and source_type = 'expense_line') = 1
    and (select asset_link_status from public.expense_lines where expense_id = v_x) = 'linked', 'confirming an expense registers its asset line too');
  v_srv := test_helpers.asset(pt, 'Server');
  perform test_helpers.put('server', v_srv);
  perform test_helpers.controls8a(pt, 'after the expense');

  perform test_helpers.login(v_owner);
  perform public.asset_activate(v_srv, 'key-p8a-ac-4', v_acq, 'straight_line', 60, '0');
  -- the sale is dated today: the five complete months are brought up to date first
  perform test_helpers.expect_msg(format('select public.asset_dispose(%L, ''key-p8a-ds-2x'', ''sale'', %L, ''15000000'', ''receivable'', null, null, null, ''Sold on credit'')', v_srv, v_today), 'INVALID', 'a sale on credit names the buyer');
  v_d := public.asset_dispose(v_srv, 'key-p8a-ds-2', 'sale', v_today, '15000000', 'receivable', null, 'PT Buyer', v_today + 30, 'Sold on credit to PT Buyer');
  perform test_helpers.put('disp_srv', v_d);
  perform test_helpers.logout();
  select * into d from public.asset_disposals where id = v_d;
  perform test_helpers.assert(d.accumulated_removed = 5 * 333333.33 and d.net_book_value = 20000000 - 5 * 333333.33 and d.gain_loss = 15000000 - d.net_book_value
    and d.proceeds_method = 'receivable' and d.obligation_id is not null and d.financial_account_id is null,
    'five months of 333,333.33 were posted before the sale; the receivable carries the proceeds');
  perform test_helpers.assert(test_helpers.jd(d.journal_id, 'OTHER_RECEIVABLE') = 15000000 and test_helpers.jd(d.journal_id, 'ACCUMULATED_DEPRECIATION') = d.accumulated_removed
    and test_helpers.jc(d.journal_id, 'FIXED_ASSET_OTHER') = 20000000 and test_helpers.jd(d.journal_id, 'ASSET_DISPOSAL_GAIN_LOSS') = -d.gain_loss and d.gain_loss < 0,
    'Dr other receivable, Dr accumulated depreciation, Dr the loss, Cr the cost');
  perform test_helpers.assert(not exists (select 1 from public.asset_depreciation_lines where asset_id = v_srv and status = 'scheduled'), 'nothing is left scheduled after a disposal');
  perform test_helpers.assert(not exists (select 1 from public.asset_depreciation_lines where asset_id = v_srv and status = 'posted' and period_month >= date_trunc('month', v_today)),
    'the month of disposal is not depreciated');
  select * into o from public.other_obligations where id = d.obligation_id;
  perform test_helpers.assert(o.kind = 'receivable' and o.principal = 15000000 and o.status = 'open' and o.source_type = 'asset_disposal' and o.source_id = v_d and o.counterparty_name = 'PT Buyer'
    and o.journal_id = d.journal_id and o.obligation_number like 'ORC-%', 'the sale created an other receivable from the disposal journal');
  perform test_helpers.controls8a(pt, 'after the sale on credit');

  -- the buyer pays part: the receivable is settled through the obligation workflow; the disposal cannot be reversed meanwhile
  perform test_helpers.login(v_owner);
  v_s := public.obligation_settle(d.obligation_id, 'key-p8a-os-1', v_today, v_bca, '6000000');
  perform test_helpers.expect_msg(format('select public.asset_reverse_disposal(%L, ''key-p8a-dr-2'', %L, ''Sale cancelled by the buyer'')', v_d, v_today), 'CONFLICT', 'a sale that was paid in part cannot be reversed');
  perform test_helpers.expect_msg(format('select public.obligation_void(%L, ''key-p8a-ov-1'', %L, ''Wrong sale'')', d.obligation_id, v_today), 'CONFLICT', 'an obligation created by a sale is voided only through the disposal');
  perform public.obligation_reverse_settlement(v_s, 'key-p8a-or-1', v_today, 'The transfer bounced');
  perform public.asset_reverse_disposal(v_d, 'key-p8a-dr-3', v_today, 'Sale cancelled by the buyer');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.other_obligations where id = d.obligation_id) = 'void' and (select status from public.fixed_assets where id = v_srv) = 'active'
    and test_helpers.bal(pt, 'OTHER_RECEIVABLE') = 0 and test_helpers.bal(pt, 'FIXED_ASSET_OTHER') = 3000000 + 20000000, 'the receivable is void and the server is back in service');
  -- the schedule continues from the month after the last posted one: 55 months remain
  perform test_helpers.assert((select count(*) from public.asset_depreciation_lines where asset_id = v_srv and status = 'scheduled') = 55
    and (select min(period_month) from public.asset_depreciation_lines where asset_id = v_srv and status = 'scheduled') = date_trunc('month', v_today)::date
    and (select sum(amount) from public.asset_depreciation_lines where asset_id = v_srv and status in ('scheduled', 'posted')) = 20000000, 'the plan is regenerated from the month after the last posted one');
  perform test_helpers.controls8a(pt, 'after reversing the sale on credit');

  -- scrapping: no proceeds, the book value is the loss
  perform test_helpers.login(v_owner);
  v_d := public.asset_dispose(v_srv, 'key-p8a-ds-3', 'scrapped', v_today, '0', 'none', null, null, null, 'Water damage, not repairable');
  perform test_helpers.logout();
  select * into d from public.asset_disposals where id = v_d;
  perform test_helpers.assert(d.gain_loss = -d.net_book_value and d.proceeds = 0 and (select status from public.fixed_assets where id = v_srv) = 'disposed'
    and test_helpers.bal(pt, 'ASSET_DISPOSAL_GAIN_LOSS') = d.net_book_value, 'scrapped: the whole book value is the loss');
  perform test_helpers.controls8a(pt, 'after the scrap');
end
$$;

-- ================================================================ 8. voiding a document and cancelling assets
do $$
declare
  pt uuid := test_helpers.entity('p8a_pt');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(pt);
  v_va uuid := test_helpers.g('va');
  v_b2 uuid;
  v_b3 uuid;
  v_b4 uuid;
  v_a2 uuid;
  v_a3 uuid;
  v_a4 uuid;
  v_new uuid;
  v_line uuid;
begin
  perform test_helpers.login(v_owner);
  -- a bill whose draft asset was never activated: voiding the bill releases the asset
  v_b2 := public.create_bill_draft(pt, 'key-p8a-b-02', v_va, v_today - 2, v_today + 20, '[{"description":"Desk","unit_price":"5000000","treatment":"asset"}]', 'INV-P8A-2');
  perform public.approve_bill(v_b2, 'key-p8a-b-02a');
  v_a2 := test_helpers.asset(pt, 'Desk');
  perform test_helpers.assert(v_a2 is not null, 'the desk is registered');
  perform public.void_bill(v_b2, 'key-p8a-b-02v', 'Ordered twice');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.fixed_assets where id = v_a2) = 'cancelled' and (select cancelled_date from public.fixed_assets where id = v_a2) is not null
    and (select asset_link_status from public.bill_lines where bill_id = v_b2) = 'none', 'voiding the bill cancelled its asset and released the line');
  perform test_helpers.controls8a(pt, 'after voiding a bill with a draft asset');

  -- a bill whose asset already carries posted depreciation cannot be voided
  perform test_helpers.login(v_owner);
  v_b3 := public.create_bill_draft(pt, 'key-p8a-b-03', v_va, (date_trunc('month', v_today) - interval '2 months')::date + 3, v_today + 20,
    '[{"description":"Chair","unit_price":"1200000","treatment":"asset"}]', 'INV-P8A-3');
  perform public.approve_bill(v_b3, 'key-p8a-b-03a');
  v_a3 := test_helpers.asset(pt, 'Chair');
  perform public.asset_activate(v_a3, 'key-p8a-ac-5', (date_trunc('month', v_today) - interval '2 months')::date + 3, 'straight_line', 24, '0');
  perform public.asset_post_depreciation(pt, (date_trunc('month', v_today) - interval '1 day')::date);
  perform test_helpers.expect_msg(format('select public.void_bill(%L, ''key-p8a-b-03v'', ''Wrong vendor'')', v_b3), 'CONFLICT', 'a bill with a depreciating asset cannot be voided');
  perform test_helpers.expect_msg(format('select public.asset_cancel(%L, ''key-p8a-ca-0'', ''Not an asset after all'')', v_a3), 'CONFLICT', 'an asset with posted depreciation cannot be cancelled');
  perform test_helpers.logout();

  -- cancelling a draft asset returns its line to pending; it is registered again by hand
  perform test_helpers.login(v_owner);
  v_b4 := public.create_bill_draft(pt, 'key-p8a-b-04', v_va, v_today - 1, v_today + 20, '[{"description":"Shelf","unit_price":"900000","treatment":"asset"}]', 'INV-P8A-4');
  perform public.approve_bill(v_b4, 'key-p8a-b-04a');
  v_a4 := test_helpers.asset(pt, 'Shelf');
  perform test_helpers.expect_msg(format('select public.asset_cancel(%L, ''key-p8a-ca-1'', ''x'')', v_a4), 'INVALID', 'a cancellation needs a reason');
  perform public.asset_cancel(v_a4, 'key-p8a-ca-2', 'Booked as an asset by mistake');
  select id into v_line from public.bill_lines where bill_id = v_b4;
  perform test_helpers.assert((select asset_link_status from public.bill_lines where id = v_line) = 'pending' and (select status from public.fixed_assets where id = v_a4) = 'cancelled'
    and exists (select 1 from public.asset_pending_lines(pt) where line_id = v_line and base_amount::numeric = 900000), 'the line is pending again and listed as waiting for registration');
  perform test_helpers.controls8a(pt, 'a pending line is counted by the control');
  v_new := public.asset_register_pending('bill_line', v_line);
  perform test_helpers.assert((select status from public.fixed_assets where id = v_new) = 'draft' and (select acquisition_cost from public.fixed_assets where id = v_new) = 900000
    and (select asset_link_status from public.bill_lines where id = v_line) = 'linked', 'registered again as a new draft asset');
  perform test_helpers.expect_msg(format('select public.asset_register_pending(''bill_line'', %L)', v_line), 'CONFLICT', 'only a pending line is registered');
  perform test_helpers.logout();
  perform test_helpers.controls8a(pt, 'after re-registering');
end
$$;

-- ================================================================ 9. opening assets and the control against the opening balances
do $$
declare
  op uuid := test_helpers.entity('p8a_op');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_today date := test_helpers.today(op);
  v_cut date := (date_trunc('month', test_helpers.today(op)) - interval '1 day')::date;
  v_svc date := (date_trunc('month', test_helpers.today(op)) - interval '21 months')::date;
  v_ids uuid[];
  v_c record;
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.asset_load_opening(%L, ''key-p8a-op-0'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('name', 'Old Server', 'cost_account', test_helpers.acct(op, 'BANK_OPERATING'), 'acquisition_date', v_svc, 'in_service_date', v_svc,
      'cutover_date', v_cut, 'cost', '10000000', 'accumulated', '4000000', 'method', 'straight_line', 'life_months', 60))), 'INVALID', 'the cost account must be a fixed-asset account');
  perform test_helpers.expect_msg(format('select public.asset_load_opening(%L, ''key-p8a-op-0b'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('name', 'Old Server', 'cost_account', test_helpers.acct(op, 'FIXED_ASSET_EQUIPMENT'), 'acquisition_date', v_svc, 'in_service_date', v_svc,
      'cutover_date', v_cut, 'cost', '10000000', 'accumulated', '11000000', 'method', 'straight_line', 'life_months', 60))), 'INVALID', 'accumulated depreciation cannot exceed the basis');
  v_ids := public.asset_load_opening(op, 'key-p8a-op-1', jsonb_build_array(
    jsonb_build_object('name', 'Old Server', 'cost_account', test_helpers.acct(op, 'FIXED_ASSET_EQUIPMENT'), 'acquisition_date', v_svc, 'in_service_date', v_svc,
      'cutover_date', v_cut, 'cost', '10000000', 'accumulated', '3500000', 'method', 'straight_line', 'life_months', 60, 'residual', '0', 'location', 'Data room'),
    jsonb_build_object('name', 'Land', 'cost_account', test_helpers.acct(op, 'FIXED_ASSET_OTHER'), 'acquisition_date', v_svc, 'in_service_date', v_svc,
      'cutover_date', v_cut, 'cost', '50000000', 'method', 'none', 'fiscal_class', 'land')));
  perform test_helpers.assert(public.asset_load_opening(op, 'key-p8a-op-1', jsonb_build_array(
    jsonb_build_object('name', 'Old Server', 'cost_account', test_helpers.acct(op, 'FIXED_ASSET_EQUIPMENT'), 'acquisition_date', v_svc, 'in_service_date', v_svc,
      'cutover_date', v_cut, 'cost', '10000000', 'accumulated', '3500000', 'method', 'straight_line', 'life_months', 60, 'residual', '0', 'location', 'Data room'),
    jsonb_build_object('name', 'Land', 'cost_account', test_helpers.acct(op, 'FIXED_ASSET_OTHER'), 'acquisition_date', v_svc, 'in_service_date', v_svc,
      'cutover_date', v_cut, 'cost', '50000000', 'method', 'none', 'fiscal_class', 'land'))) = v_ids, 'the opening load replays on the same key');
  perform test_helpers.logout();
  perform test_helpers.assert(array_length(v_ids, 1) = 2 and (select count(*) from public.fixed_assets where entity_id = op) = 2, 'two opening assets');
  -- 21 months elapsed at the cut-over (the cut-over month included) leave 60 - 21 = 39 months, of 6,500,000
  perform test_helpers.assert((select count(*) from public.asset_depreciation_lines l join public.fixed_assets f on f.id = l.asset_id where f.entity_id = op and f.name = 'Old Server') = 39
    and (select sum(l.amount) from public.asset_depreciation_lines l join public.fixed_assets f on f.id = l.asset_id where f.entity_id = op and f.name = 'Old Server') = 6500000
    and (select min(l.period_month) from public.asset_depreciation_lines l join public.fixed_assets f on f.id = l.asset_id where f.entity_id = op and f.name = 'Old Server') = date_trunc('month', v_today)::date,
    'the schedule of an opening asset continues from the month after the cut-over');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where entity_id = op), 'loading opening assets posts no journal');

  -- until the opening balances are posted the register is ahead of the ledger: the control shows it
  select * into v_c from app_private.asset_control(op) where account_key = 'FIXED_ASSET_COST';
  perform test_helpers.assert(v_c.sub_ledger = 60000000 and v_c.ledger_total = 0, 'the control shows the register ahead of the ledger');
  perform test_helpers.login(v_owner);
  perform public.post_opening_balances(op, 'key-p8a-ob-1', v_cut, jsonb_build_array(
    jsonb_build_object('account_key', 'FIXED_ASSET_EQUIPMENT', 'debit', 10000000),
    jsonb_build_object('account_key', 'FIXED_ASSET_OTHER', 'debit', 50000000),
    jsonb_build_object('account_key', 'ACCUMULATED_DEPRECIATION', 'credit', 3500000),
    jsonb_build_object('account_key', 'OWNER_CAPITAL', 'credit', 56500000)), 'Opening balances');
  perform test_helpers.assert((select bool_and(difference::numeric = 0) from public.asset_control_report(op)), 'after the opening balances the register equals the ledger');
  perform test_helpers.assert((select ledger_other::numeric from public.asset_control_report(op) where account_key = 'FIXED_ASSET_COST') = 60000000, 'the opening is shown apart from the asset workflow');
  perform test_helpers.logout();
  perform test_helpers.controls8a(op, 'opening assets');

  -- the schedule starts after the cut-over: nothing is due until that month is over
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(not exists (select 1 from public.asset_depreciation_due(op)), 'no depreciation is due on opening assets before their first month ends');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 10. Personal assets, authorization and immutability
do $$
declare
  pt uuid := test_helpers.entity('p8a_pt');
  pe uuid := test_helpers.entity('p8a_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_viewer uuid := 'd0000000-0000-0000-0000-000000000004';
  v_staff uuid := 'd0000000-0000-0000-0000-000000000008';
  v_nobody uuid := 'd0000000-0000-0000-0000-000000000007';
  v_today date := test_helpers.today(pe);
  v_acq date := test_helpers.today(pe) - 20;
  v_x uuid;
  v_a uuid;
  v_d uuid;
  v_first uuid;
  a public.fixed_assets%rowtype;
  d public.asset_disposals%rowtype;
begin
  perform test_helpers.login(v_owner);
  v_x := public.create_expense_draft(pe, 'key-p8a-pe-1', test_helpers.g('pe_bank'), v_acq,
    jsonb_build_array(jsonb_build_object('description', 'Camera', 'unit_price', '9000000', 'treatment', 'asset')), null, 'Personal Shop', 'PRC-1');
  perform public.confirm_expense(v_x, 'key-p8a-pe-1c');
  perform test_helpers.logout();
  v_a := test_helpers.asset(pe, 'Camera');
  perform test_helpers.assert(v_a is not null, 'a personal expense line registers an asset');
  select * into a from public.fixed_assets where id = v_a;
  perform test_helpers.assert(a.status = 'draft' and a.acquisition_cost = 9000000 and a.cost_account_id = test_helpers.acct(pe, 'PERSONAL_FIXED_ASSET'), 'the personal asset sits on the personal fixed-asset account');
  perform test_helpers.controls8a(pe, 'personal asset registered');

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.asset_activate(%L, ''key-p8a-pe-2x'', %L, ''straight_line'', 36)', v_a, v_acq), 'INVALID', 'personal assets are not depreciated');
  perform public.asset_activate(v_a, 'key-p8a-pe-2', v_acq, 'none', null);
  perform test_helpers.assert(not exists (select 1 from public.asset_depreciation_lines where asset_id = v_a) and (select status from public.fixed_assets where id = v_a) = 'active', 'a personal asset is kept at cost, with no schedule');
  v_d := public.asset_dispose(v_a, 'key-p8a-pe-3', 'sale', v_today, '10000000', 'cash', test_helpers.g('pe_bank'), null, null, 'Sold second-hand');
  perform test_helpers.logout();
  select * into d from public.asset_disposals where id = v_d;
  perform test_helpers.assert(d.gain_loss = 1000000 and d.accumulated_removed = 0 and test_helpers.jc(d.journal_id, 'ASSET_DISPOSAL_GAIN_LOSS') = 1000000
    and test_helpers.jd(d.journal_id, 'PERSONAL_BANK') = 10000000 and test_helpers.jc(d.journal_id, 'PERSONAL_FIXED_ASSET') = 9000000, 'a personal sale books the gain on Personal 7400');
  perform test_helpers.controls8a(pe, 'personal asset sold');

  -- authorization: the asset layer follows the Entity, not the user
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.asset_register(pt)) > 0, 'a viewer reads the register');
  perform test_helpers.assert((select count(*) from public.fixed_assets where entity_id = pt) > 0, 'a viewer reads the asset table through RLS');
  perform test_helpers.expect_msg(format('select public.asset_update_details(%L, ''Renamed'')', test_helpers.g('monitor')), 'FORBIDDEN', 'a viewer cannot edit an asset');
  perform test_helpers.expect_msg(format('select public.asset_register(%L)', pe), 'FORBIDDEN', 'a viewer of the company sees nothing of the personal Entity');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.assert(not exists (select 1 from public.fixed_assets) and not exists (select 1 from public.asset_depreciation_lines) and not exists (select 1 from public.asset_disposals), 'a stranger sees no asset rows');
  perform test_helpers.expect_msg(format('select public.asset_register(%L)', pt), 'FORBIDDEN', 'a stranger cannot read the register');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.asset_post_depreciation(%L, %L)', pt, (date_trunc('month', test_helpers.today(pt))::date - 1)), 'FORBIDDEN', 'staff cannot post depreciation');
  perform test_helpers.expect_msg(format('select public.asset_dispose(%L, ''key-p8a-au-1'', ''write_off'', %L, ''0'', null, null, null, null, ''x'')', test_helpers.g('monitor'), test_helpers.today(pt)), 'FORBIDDEN', 'staff cannot dispose of an asset');
  perform test_helpers.logout();

  -- nothing writes the tables directly, and history is append-only
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_error(format('update public.fixed_assets set acquisition_cost = 1 where id = %L', test_helpers.g('monitor')), '42501', 'no direct update of an asset');
  perform test_helpers.expect_error(format('delete from public.fixed_assets where id = %L', test_helpers.g('monitor')), '42501', 'no direct delete of an asset');
  perform test_helpers.expect_error(format('insert into public.asset_events (entity_id, asset_id, event_type) values (%L, %L, ''x'')', pt, test_helpers.g('monitor')), '42501', 'no direct event');
  perform test_helpers.logout();
  select id into v_first from public.asset_events where entity_id = pt limit 1;
  perform test_helpers.expect_error(format('update public.asset_events set event_type = ''x'' where id = %L', v_first), null, 'the event log cannot be edited');
  perform test_helpers.expect_error(format('delete from public.asset_events where id = %L', v_first), null, 'the event log cannot be deleted');
  perform test_helpers.expect_error(format('delete from public.fixed_assets where id = %L', test_helpers.g('monitor')), null, 'an asset cannot be deleted, even by the owner of the database');
  perform test_helpers.expect_error(format('delete from public.asset_disposals where id = %L', v_d), null, 'a disposal cannot be deleted');
  perform test_helpers.expect_error(format('update public.fixed_assets set acquisition_cost = acquisition_cost + 1 where id = %L', test_helpers.g('monitor')), null, 'the cost of an asset cannot be edited directly');
  perform test_helpers.assert((select count(*) from public.audit_events where entity_id = pt and target_table = 'fixed_assets') > 0, 'asset changes are audited');
end
$$;

rollback;
