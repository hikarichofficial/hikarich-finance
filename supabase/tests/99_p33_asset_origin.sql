-- Decision 343: an asset records whether it was bought new or used and its year of manufacture, and an asset put in
-- service before 2020 can carry a fiscal group (the groups are the same since 1 January 2009). One transaction,
-- rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  pe uuid;
  v_owner uuid := 'e3330000-0000-0000-0000-000000000001';
  v_viewer uuid := 'e3330000-0000-0000-0000-000000000002';
  v_cut date;
  v_old date := date '2018-03-10';
  v_ids uuid[];
  v_acct uuid;
  d jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p33_pe', 'P33 Asset Origin PT (synthetic)') returning id into pe;
  perform app_private.provision_default_coa(pe);
  perform test_helpers.mk_user(v_owner, 'p33_owner');
  perform test_helpers.mk_user(v_viewer, 'p33_viewer');
  perform test_helpers.mk_member(pe, v_owner, 'owner');
  perform test_helpers.mk_member(pe, v_viewer, 'viewer_auditor');
  v_cut := (date_trunc('month', app_private.entity_today(pe)) - interval '1 day')::date;
  v_acct := test_helpers.acct(pe, 'FIXED_ASSET_EQUIPMENT');

  perform test_helpers.assert(app_private.fiscal_class('group_1', date '2018-03-10') is not null
    and app_private.fiscal_class('group_1', date '2001-06-01') is not null
    and app_private.fiscal_class('group_1', date '2019-12-31') ->> 'life_years' = '4'
    and app_private.fiscal_class('group_1', date '2020-01-01') ->> 'life_years' = '4',
    '1.1 the fiscal groups apply to every date, with the same values');

  perform test_helpers.login(v_owner);
  v_ids := public.asset_load_opening(pe, 'key-p33-1', jsonb_build_array(
    jsonb_build_object('name', 'Laptop lama', 'cost_account', v_acct, 'acquisition_date', v_old, 'in_service_date', v_old, 'cutover_date', v_cut,
      'cost', '10000000', 'accumulated', '3000000', 'method', 'straight_line', 'life_months', 144, 'fiscal_class', 'group_1',
      'condition', 'used', 'manufacture_year', '2015'),
    jsonb_build_object('name', 'Meja baru', 'cost_account', v_acct, 'acquisition_date', v_old, 'in_service_date', v_old, 'cutover_date', v_cut,
      'cost', '4000000', 'accumulated', '500000', 'method', 'straight_line', 'life_months', 144)));
  perform test_helpers.assert(array_length(v_ids, 1) = 2, '2.1 an asset older than 2020 can be loaded with a fiscal group');
  d := public.asset_detail(v_ids[1]) -> 'asset';
  perform test_helpers.assert(d ->> 'acquired_condition' = 'used' and d ->> 'manufacture_year' = '2015' and d ->> 'fiscal_class_key' = 'group_1',
    '2.2 the detail shows a used asset, its year and its fiscal group');
  d := public.asset_detail(v_ids[2]) -> 'asset';
  perform test_helpers.assert(d ->> 'acquired_condition' = 'new' and d -> 'manufacture_year' = 'null'::jsonb, '2.3 an asset without the facts is new with no year');

  perform test_helpers.expect_msg(format('select public.asset_load_opening(%L, ''key-p33-2'', %L::jsonb)', pe, jsonb_build_array(
    jsonb_build_object('name', 'Mobil bekas', 'cost_account', v_acct, 'acquisition_date', v_old, 'in_service_date', v_old, 'cutover_date', v_cut,
      'cost', '10000000', 'method', 'straight_line', 'life_months', 96, 'condition', 'used'))), 'INVALID', '3.1 a used asset needs its year of manufacture');
  perform test_helpers.expect_msg(format('select public.asset_load_opening(%L, ''key-p33-3'', %L::jsonb)', pe, jsonb_build_array(
    jsonb_build_object('name', 'Mobil', 'cost_account', v_acct, 'acquisition_date', v_old, 'in_service_date', v_old, 'cutover_date', v_cut,
      'cost', '10000000', 'method', 'straight_line', 'life_months', 96, 'manufacture_year', '2019'))), 'INVALID', '3.2 the year of manufacture cannot be after the year it was bought');
  perform test_helpers.expect_msg(format('select public.asset_load_opening(%L, ''key-p33-4'', %L::jsonb)', pe, jsonb_build_array(
    jsonb_build_object('name', 'Mobil', 'cost_account', v_acct, 'acquisition_date', v_old, 'in_service_date', v_old, 'cutover_date', v_cut,
      'cost', '10000000', 'method', 'straight_line', 'life_months', 96, 'condition', 'rusak'))), 'INVALID', '3.3 the condition is new or used');
  perform test_helpers.expect_msg(format('select public.asset_load_opening(%L, ''key-p33-5'', %L::jsonb)', pe, jsonb_build_array(
    jsonb_build_object('name', 'Mobil', 'cost_account', v_acct, 'acquisition_date', v_old, 'in_service_date', v_old, 'cutover_date', v_cut,
      'cost', '10000000', 'method', 'straight_line', 'life_months', 96, 'manufacture_year', 'abc'))), 'INVALID', '3.4 the year must be a number');
  v_ids := v_ids || public.asset_load_opening(pe, 'key-p33-6', jsonb_build_array(
    jsonb_build_object('name', 'Gedung tua', 'cost_account', test_helpers.acct(pe, 'FIXED_ASSET_OTHER'), 'acquisition_date', date '2001-06-01', 'in_service_date', date '2001-06-01', 'cutover_date', v_cut,
      'cost', '10000000', 'accumulated', '1000000', 'method', 'straight_line', 'life_months', 600, 'fiscal_class', 'building_permanent')));
  perform test_helpers.assert(array_length(v_ids, 1) = 3, '3.5 an asset of 2001 can carry its fiscal group too');
  perform test_helpers.assert((select count(*) from public.ledger_accounts where entity_id = pe and code in (
      '1501', '1502', '1503', '1504', '1505', '1511', '1512', '1513', '1514', '1515', '1516', '1531', '1532', '1533', '1534',
      '1540', '1550', '1560', '1570') and parent_id is not null and is_control and not allows_manual_posting) = 19,
    '3.6 land, buildings, equipment, vehicles and the other fixed-asset kinds exist under Fixed Assets, as control accounts');
  perform test_helpers.assert((select count(*) from public.ledger_accounts a where a.entity_id = pe
      and a.parent_id in (select id from public.ledger_accounts where entity_id = pe and code in ('1600', '1700'))
      and not a.is_control and a.allows_manual_posting) = 12
    and (select normal_balance from public.ledger_accounts where entity_id = pe and code = '1690') = 'credit',
    '3.6b intangible assets and long-term investments (such as term deposits) exist outside the asset register, open to journals');
  perform test_helpers.assert((select count(*) from public.ledger_accounts where entity_id = pe and code in ('1220', '1230') and not is_control and allows_manual_posting) = 2,
    '3.6c broker/trading funds and crypto have accounts of their own, outside the asset register');
  perform test_helpers.assert((select count(*) from public.ledger_accounts where entity_id = pe
      and code in ('7110', '7120', '7130', '7140', '7150', '7160', '7210', '7220', '7230', '7240', '7320', '7330', '7340', '7350', '7360', '7370', '7380', '6710', '8300')
      and not is_control and allows_manual_posting) = 19
    and (select account_class from public.ledger_accounts where entity_id = pe and code = '7110') = 'other_income'
    and (select account_class from public.ledger_accounts where entity_id = pe and code = '7320') = 'other',
    '3.6d dividend, forex, crypto, investment and broker-cost accounts exist and take journals');
  v_ids := v_ids || public.asset_load_opening(pe, 'key-p33-7', jsonb_build_array(
    jsonb_build_object('name', 'Mobil operasional', 'cost_account', (select id from public.ledger_accounts where entity_id = pe and code = '1531'),
      'acquisition_date', v_old, 'in_service_date', v_old, 'cutover_date', v_cut,
      'cost', '100000000', 'accumulated', '10000000', 'method', 'straight_line', 'life_months', 192, 'fiscal_class', 'group_2')));
  perform test_helpers.assert(array_length(v_ids, 1) = 4, '3.7 an asset can be loaded on a new account such as vehicles');

  perform public.asset_set_origin(v_ids[2], 'used', 2016);
  d := public.asset_detail(v_ids[2]) -> 'asset';
  perform test_helpers.assert(d ->> 'acquired_condition' = 'used' and d ->> 'manufacture_year' = '2016', '4.1 the origin of an asset can be recorded afterwards');
  perform test_helpers.expect_msg(format('select public.asset_set_origin(%L, ''used'', null)', v_ids[2]), 'INVALID', '4.2 used still needs the year');
  perform test_helpers.expect_msg(format('select public.asset_set_origin(%L, ''new'', 2030)', v_ids[2]), 'INVALID', '4.3 the year cannot be after the year it was bought');
  perform test_helpers.logout();

  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.asset_set_origin(%L, ''new'', null)', v_ids[2]), 'FORBIDDEN', '4.4 a viewer cannot change it');
  perform test_helpers.logout();
end
$$;

rollback;
