-- Decision 324: the automatic SKU generator. Covers provisioning for every Entity, the never-reused numbering, the
-- composed format (order, separator, prefix/suffix, empty parts, digits, scope), variants, the master data rules
-- (unique live codes, archive/restore, delete only when unused), the permission split (Owner configures and
-- overrides, staff only picks) and the SKU history. Synthetic data; one transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e1 uuid;
  e2 uuid;
  v_owner uuid := 'e3240000-0000-0000-0000-000000000001';
  v_staff uuid := 'e3240000-0000-0000-0000-000000000002';
  v_kea uuid;
  v_kkm uuid;
  v_ea uuid;
  v_ind uuid;
  v_1b uuid;
  v_3b uuid;
  p1 uuid; p2 uuid; p3 uuid; p4 uuid; v1 uuid; v2 uuid;
  v_new uuid;
  v_comp jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p24_sku', 'P24 SKU (synthetic)') returning id into e1;
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p24_sku2', 'P24 SKU 2 (synthetic)') returning id into e2;
  perform test_helpers.mk_user(v_owner, 'p324-owner');
  perform test_helpers.mk_user(v_staff, 'p324-staff');
  perform test_helpers.mk_member(e1, v_owner, 'owner');
  perform test_helpers.mk_member(e1, v_staff, 'finance_staff');
  perform test_helpers.mk_member(e2, v_owner, 'owner');

  -- every Entity, old or new, gets the defaults
  perform test_helpers.assert((select count(*) from public.sku_settings where entity_id in (e1, e2)) = 2, '1.1 settings exist for every Entity');
  perform test_helpers.assert((select count(*) from public.product_brands where entity_id = e2) = 3
    and (select count(*) from public.product_types where entity_id = e2) = 8
    and (select count(*) from public.product_variants where entity_id = e2) = 5, '1.2 default brands, types and variants for every Entity');
  perform test_helpers.assert((select count(*) from public.sku_settings s where not exists (select 1 from public.entities e where e.id = s.entity_id)) = 0
    and not exists (select 1 from public.entities e where not exists (select 1 from public.sku_settings s where s.entity_id = e.id)),
    '1.3 no Entity is without SKU settings');

  select id into v_kea from public.product_brands where entity_id = e1 and code = 'KEA';
  select id into v_kkm from public.product_brands where entity_id = e1 and code = 'KKM';
  select id into v_ea from public.product_types where entity_id = e1 and code = 'EA';
  select id into v_ind from public.product_types where entity_id = e1 and code = 'IND';
  select id into v_1b from public.product_variants where entity_id = e1 and code = '1B';
  select id into v_3b from public.product_variants where entity_id = e1 and code = '3B';

  perform test_helpers.login(v_owner);
  -- preview does not take a number
  perform test_helpers.assert((public.preview_product_sku(e1, v_kea, v_ea) ->> 'base_sku') = 'KEA-EA-001', '2.1 preview shows the next SKU');
  perform test_helpers.assert((public.preview_product_sku(e1, v_kea, v_ea) ->> 'base_sku') = 'KEA-EA-001', '2.2 preview does not use the number up');

  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'MT5 EA', v_kea, v_ea) returning id into p1;
  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'MT5 EA 2', v_kea, v_ea) returning id into p2;
  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'Indicator', v_kea, v_ind) returning id into p3;
  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'KKM EA', v_kkm, v_ea) returning id into p4;
  perform test_helpers.assert((select sku from public.products where id = p1) = 'KEA-EA-001', '3.1 first product: KEA-EA-001');
  perform test_helpers.assert((select sku from public.products where id = p2) = 'KEA-EA-002', '3.2 second product: KEA-EA-002');
  perform test_helpers.assert((select sku from public.products where id = p3) = 'KEA-IND-001', '3.3 numbering is per brand and type');
  perform test_helpers.assert((select sku from public.products where id = p4) = 'KKM-EA-001', '3.4 another brand starts at 001');

  -- a deleted number is never handed out again
  delete from public.products where id = p2;
  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'MT5 EA 3', v_kea, v_ea) returning id into p2;
  perform test_helpers.assert((select sku from public.products where id = p2) = 'KEA-EA-003', '3.5 number 002 is not reused after a delete');

  -- variants
  insert into public.products (entity_id, kind, name, parent_product_id, variant_id) values (e1, 'product', 'MT5 EA 1 Bulan', p1, v_1b) returning id into v1;
  insert into public.products (entity_id, kind, name, parent_product_id, variant_id) values (e1, 'product', 'MT5 EA 3 Bulan', p1, v_3b) returning id into v2;
  perform test_helpers.assert((select sku from public.products where id = v1) = 'KEA-EA-001-1B', '4.1 variant SKU: base plus variant code');
  perform test_helpers.assert((select sku from public.products where id = v2) = 'KEA-EA-001-3B', '4.2 second variant SKU');
  perform test_helpers.assert((select sku from public.products where id = p1) = 'KEA-EA-001', '4.3 the base product keeps its own SKU');
  perform test_helpers.expect_error(format('insert into public.products (entity_id, kind, name, parent_product_id, variant_id) values (%L,%L,%L,%L,%L)', e1, 'product', 'dup', p1, v_1b), '23505', '4.4 the same variant twice is refused');
  perform test_helpers.expect_error(format('update public.products set sku_number = 9 where id = %L', p1), '42501', '4.5 the sequence number cannot be edited');

  -- history and snapshot of the first SKUs
  perform test_helpers.assert((select count(*) from public.product_sku_history where product_id = p1) = 1, '5.1 the first SKU is in the history');

  -- master data rules
  perform test_helpers.expect_error(format('select public.save_sku_master(%L,%L,null,%L,%L)', 'brand', e1, 'Dup', 'KEA'), '23505', '6.1 two live brands cannot share a code');
  perform test_helpers.expect_error(format('select public.set_sku_master_state(%L,%L,%L,%L)', 'brand', e1, v_kea, 'delete'), '23503', '6.2 a used brand cannot be deleted');
  perform public.set_sku_master_state('brand', e1, v_kkm, 'archive');
  perform test_helpers.assert((select archived_at is not null and not is_active from public.product_brands where id = v_kkm), '6.3 a used brand can be archived');
  v_new := public.save_sku_master('brand', e1, null, 'Another KKM', 'KKM');
  perform test_helpers.assert(v_new is not null, '6.4 an archived code is free again');
  perform test_helpers.expect_error(format('select public.set_sku_master_state(%L,%L,%L,%L)', 'brand', e1, v_kkm, 'restore'), '23505', '6.5 restore refuses a code that is taken');
  perform public.set_sku_master_state('brand', e1, v_new, 'delete');
  perform test_helpers.assert(not exists (select 1 from public.product_brands where id = v_new), '6.6 an unused brand can be deleted');
  perform public.save_sku_master('type', e1, v_ea, 'Expert Advisor', 'BOT');
  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'After code change', v_kea, v_ea) returning id into v_new;
  perform test_helpers.assert((select sku from public.products where id = v_new) = 'KEA-BOT-004', '6.7 a changed type code applies to new SKUs only');
  perform test_helpers.assert((select sku from public.products where id = p1) = 'KEA-EA-001', '6.8 existing SKUs keep their code');

  -- the format builder
  perform public.save_sku_settings(e1, true,
    '[{"key":"brand","enabled":true,"required":true},{"key":"seq","enabled":true,"required":true},{"key":"type","enabled":true,"required":true},{"key":"variant","enabled":true,"required":false}]'::jsonb,
    '/', 'HIK', '', 'skip', 'XX', 4, 1, 1, 'brand_type');
  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'Reordered', v_kea, v_ind) returning id into v_new;
  perform test_helpers.assert((select sku from public.products where id = v_new) = 'HIK/KEA/0002/IND', '7.1 order, separator, prefix and digits follow the settings');
  perform public.save_sku_settings(e1, true,
    '[{"key":"brand","enabled":true,"required":true},{"key":"type","enabled":false,"required":false},{"key":"seq","enabled":true,"required":true},{"key":"variant","enabled":true,"required":false}]'::jsonb,
    '-', '', '', 'skip', 'XX', 3, 1, 1, 'global');
  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'No type part', v_kea, v_ind) returning id into v_new;
  perform test_helpers.assert((select sku from public.products where id = v_new) = 'KEA-001', '7.2 a switched-off part leaves no double separator');
  perform test_helpers.logout();
  perform test_helpers.assert(app_private.compose_sku(e1, 'KEA', 'EA', 5, null, true) = 'KEA-005', '7.3 an empty variant is left out');
  perform test_helpers.login(v_owner);
  perform public.save_sku_settings(e1, true,
    '[{"key":"brand","enabled":true,"required":true},{"key":"type","enabled":true,"required":true},{"key":"seq","enabled":true,"required":true},{"key":"variant","enabled":true,"required":false}]'::jsonb,
    '-', '', '', 'placeholder', 'NA', 3, 1, 1, 'brand_type');
  perform test_helpers.logout();
  perform test_helpers.assert(app_private.compose_sku(e1, 'KEA', 'EA', 5, null, true) = 'KEA-EA-005-NA', '7.4 an empty part can be a fixed filler');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_error(format('select public.save_sku_settings(%L,true,%L::jsonb,%L,%L,%L,%L,%L,3,1,1,%L)', e1, '[{"key":"brand"}]', '-', '', '', 'skip', 'XX', 'global'), '23514', '7.5 a broken format is refused');
  perform test_helpers.expect_error(format('select public.save_sku_settings(%L,true,%L::jsonb,%L,%L,%L,%L,%L,3,1,1,%L)', e1, '[{"key":"brand","enabled":true,"required":true},{"key":"brand","enabled":true,"required":true},{"key":"seq","enabled":true,"required":true},{"key":"variant","enabled":true,"required":false}]', '-', '', '', 'skip', 'XX', 'global'), '23514', '7.6 a part cannot repeat');

  -- a number already taken by another SKU is skipped, never duplicated
  perform public.save_sku_settings(e1, true,
    '[{"key":"brand","enabled":true,"required":true},{"key":"type","enabled":true,"required":true},{"key":"seq","enabled":true,"required":true},{"key":"variant","enabled":true,"required":false}]'::jsonb,
    '-', '', '', 'skip', 'XX', 3, 1, 1, 'global');
  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'Global 1', v_kea, v_ea) returning id into v_new;
  perform test_helpers.assert((select sku from public.products where id = v_new) = 'KEA-BOT-' || lpad((select sku_number::text from public.products where id = v_new), 3, '0'), '7.7 global numbering composes');

  -- owner override, with a reason
  perform public.set_product_sku(p1, 'KEA-EA-001-MANUAL', 'rename for launch');
  perform test_helpers.assert((select sku from public.products where id = p1) = 'KEA-EA-001-MANUAL' and (select sku_manual from public.products where id = p1), '8.1 the Owner can change a SKU by hand');
  perform test_helpers.assert((select count(*) from public.product_sku_history where product_id = p1 and reason = 'rename for launch') = 1, '8.2 the change is in the history with its reason');
  perform test_helpers.expect_error(format('select public.set_product_sku(%L, %L)', p2, 'KEA-EA-001-MANUAL'), '23505', '8.3 a manual SKU must still be unique');


  -- Global Search: SKU, name, brand and type all find the product
  perform public.set_product_sku(p1, 'KEA-EA-001-SRCH', 'restore for search test');
  perform public.rebuild_search_index(e1);
  perform test_helpers.assert((select count(*) from public.search(e1, 'KEA-EA-001-SRCH') where target_type = 'product' and target_id = p1) = 1, '10.1 the full SKU finds the product');
  perform test_helpers.assert((select count(*) from public.search(e1, 'KEA-EA-001') where target_type = 'product' and target_id = p1) = 1, '10.2 a SKU without the variant finds it too');
  perform test_helpers.assert((select count(*) from public.search(e1, (select name from public.products where id = p1)) where target_type = 'product' and target_id = p1) >= 1, '10.3 the product name finds it');
  perform test_helpers.assert((select count(*) from public.search(e1, 'kea') where target_type = 'product' and target_id = p1) = 1, '10.4 the brand code finds it');
  perform test_helpers.assert((select count(*) from public.search(e1, 'Expert Advisor') where target_type = 'product' and target_id = p1) >= 1, '10.5 the type name finds it');
  perform public.save_sku_master('brand', e1, v_kea, 'Keagenan Renamed', 'KEA');
  perform public.refresh_search_index_batch(500);
  perform test_helpers.assert((select count(*) from public.search(e1, 'Renamed') where target_type = 'product' and target_id = p1) = 1, '10.6 renaming a brand refreshes its products in the index');

  -- staff: pick, never type
  perform test_helpers.login(v_staff);
  insert into public.products (entity_id, kind, name, brand_id, product_type_id) values (e1, 'product', 'Staff product', v_kea, v_ea) returning id into v_new;
  perform test_helpers.assert((select sku from public.products where id = v_new) is not null, '9.1 staff get an automatic SKU');
  perform test_helpers.expect_error(format('insert into public.products (entity_id, kind, name, sku) values (%L,%L,%L,%L)', e1, 'product', 'typed', 'MY-SKU'), '42501', '9.2 staff cannot type a SKU');
  perform test_helpers.expect_error(format('update public.products set sku = %L where id = %L', 'MY-SKU', v_new), '42501', '9.3 staff cannot change a SKU');
  perform test_helpers.expect_error(format('select public.set_product_sku(%L, %L)', v_new, 'MY-SKU'), '42501', '9.4 staff cannot use the override function');
  perform test_helpers.expect_error(format('select public.save_sku_master(%L,%L,null,%L,%L)', 'brand', e1, 'X', 'XYZ'), '42501', '9.5 staff cannot add a brand');
  perform test_helpers.expect_error(format('select public.save_sku_settings(%L,true,%L::jsonb,%L,%L,%L,%L,%L,3,1,1,%L)', e1, '[]', '-', '', '', 'skip', 'XX', 'global'), '42501', '9.6 staff cannot change the format');
  perform test_helpers.assert(test_helpers.rows(format('select id from public.product_brands where entity_id = %L', e1)) >= 3, '9.7 staff can read the brands to pick one');
  perform test_helpers.expect_error(format('insert into public.product_brands (entity_id, name, code) values (%L,%L,%L)', e1, 'Direct', 'DIR'), '42501', '9.8 no direct write to the masters');
  perform test_helpers.logout();
end
$$;

rollback;
