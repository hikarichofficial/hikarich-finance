-- P14 decision 252: Documents Archive, the Sales/Purchase report and Saved Reports. Synthetic data; one
-- transaction, rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p152 (k text primary key, v uuid);
grant all on test_helpers.p152 to public;

do $$
declare
  e uuid;
  v_owner uuid := 'e1520000-0000-0000-0000-000000000001';
  v_staff uuid := 'e1520000-0000-0000-0000-000000000002';
  v_admin uuid := 'e1520000-0000-0000-0000-000000000003';
  v_id uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p14_ar', 'P14 Archive/Reports (synthetic)')
  returning id into e;
  perform app_private.provision_default_coa(e);
  perform test_helpers.mk_user(v_owner, 'p152-owner');
  perform test_helpers.mk_user(v_staff, 'p152-staff');
  perform test_helpers.mk_user(v_admin, 'p152-admin');
  perform test_helpers.mk_member(e, v_owner, 'owner');
  perform test_helpers.mk_member(e, v_staff, 'finance_staff');
  perform test_helpers.mk_member(e, v_admin, 'finance_admin');
  insert into test_helpers.p152 values ('e', e), ('owner', v_owner), ('staff', v_staff), ('admin', v_admin);
  insert into public.categories (entity_id, name, kind) values (e, 'AR Revenue', 'revenue') returning id into v_id;
  insert into test_helpers.p152 values ('cat_rev', v_id);
  insert into public.categories (entity_id, name, kind) values (e, 'AR Expense', 'expense') returning id into v_id;
  insert into test_helpers.p152 values ('cat_exp', v_id);
  insert into public.products (entity_id, kind, sku, name, default_unit_price, default_currency)
  values (e, 'service', 'AR-1', 'Jasa AR', 1000000, 'IDR') returning id into v_id;
  insert into test_helpers.p152 values ('prod', v_id);
end
$$;

-- ================================================================ 1. documents archive
do $$
declare
  e uuid := (select v from test_helpers.p152 where k = 'e');
  v_owner uuid := (select v from test_helpers.p152 where k = 'owner');
  v_contact uuid;
  d1 uuid; d2 uuid; d3 uuid; d4 uuid;
  l1 uuid; l3 uuid;
  r record;
  n integer;
begin
  perform test_helpers.login(v_owner);
  v_contact := public.create_contact(e, 'key-p152-ct', 'customer', 'Klien Arsip');
  insert into test_helpers.p152 values ('cust', v_contact);
  d1 := public.register_document(e, 'key-p152-d1', 'kontrak-v1.pdf', 'application/pdf', 1000, repeat('1', 64));
  l1 := public.link_document(d1, 'contact', v_contact, 'contract');
  d2 := public.register_document(e, 'key-p152-d2', 'kontrak-v2.pdf', 'application/pdf', 1200, repeat('2', 64), d1);
  perform public.replace_document_link(l1, d2, 'versi bertanda tangan');
  d3 := public.register_document(e, 'key-p152-d3', 'salah.pdf', 'application/pdf', 900, repeat('3', 64));
  l3 := public.link_document(d3, 'contact', v_contact, 'other');
  perform public.unlink_document(l3, 'berkas yang salah');
  d4 := public.register_document(e, 'key-p152-d4', 'baru.pdf', 'application/pdf', 800, repeat('4', 64));

  select count(*) into n from public.list_document_archive(e);
  perform test_helpers.assert(n = 2, '1.1 the superseded and the unlinked document are archived; active and never-linked ones are not');
  for r in select * from public.list_document_archive(e) loop
    if r.document_id = d1 then
      perform test_helpers.assert(r.archive_reason = 'superseded' and r.superseded_by = d2
        and r.superseded_by_name = 'kontrak-v2.pdf' and r.former_target_types = array['contact'],
        '1.2 the old version points to its replacement');
    else
      perform test_helpers.assert(r.document_id = d3 and r.archive_reason = 'unlinked'
        and r.removed_reason = 'berkas yang salah' and r.archived_at is not null, '1.3 the unlinked document keeps its reason');
    end if;
  end loop;
  perform test_helpers.assert((select count(*) from public.list_document_archive(e, 'kontrak')) = 1, '1.4 search by file name');
  perform test_helpers.expect_msg(format('select * from public.list_document_archive(%L, null, 0)', e), 'INVALID', '1.5 limit 1..200');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. sales / purchase report
do $$
declare
  e uuid := (select v from test_helpers.p152 where k = 'e');
  v_owner uuid := (select v from test_helpers.p152 where k = 'owner');
  v_staff uuid := (select v from test_helpers.p152 where k = 'staff');
  v_cust uuid := (select v from test_helpers.p152 where k = 'cust');
  v_rev uuid := (select v from test_helpers.p152 where k = 'cat_rev');
  v_exp uuid := (select v from test_helpers.p152 where k = 'cat_exp');
  v_prod uuid := (select v from test_helpers.p152 where k = 'prod');
  v_today date := test_helpers.today(e);
  v_start date := date_trunc('month', test_helpers.today(e))::date;
  v_vend uuid;
  v_inv uuid;
  v_bill uuid;
  r record;
  n integer;
begin
  perform test_helpers.login(v_owner);
  v_vend := public.create_contact(e, 'key-p152-vd', 'vendor', 'Vendor Laporan');
  v_inv := public.create_invoice_draft(e, 'key-p152-i1', v_cust, v_today, v_today, jsonb_build_array(
    jsonb_build_object('description', 'Jasa', 'unit_price', '1000000', 'category_id', v_rev, 'product_id', v_prod)));
  perform public.issue_invoice(v_inv, 'key-p152-i1-issue');
  v_inv := public.create_invoice_draft(e, 'key-p152-i2', v_cust, v_today, v_today, jsonb_build_array(
    jsonb_build_object('description', 'Jasa lain', 'unit_price', '500000', 'category_id', v_rev)));
  perform public.issue_invoice(v_inv, 'key-p152-i2-issue');
  perform public.create_invoice_draft(e, 'key-p152-i3', v_cust, v_today, v_today, jsonb_build_array(
    jsonb_build_object('description', 'Draf', 'unit_price', '777000', 'category_id', v_rev)));
  v_bill := public.create_bill_draft(e, 'key-p152-b1', v_vend, v_today, v_today, jsonb_build_array(
    jsonb_build_object('description', 'Sewa', 'unit_price', '300000', 'category_id', v_exp)));
  perform public.submit_bill(v_bill, 'key-p152-b1-submit');
  perform public.approve_bill(v_bill, 'key-p152-b1-approve');

  select * into r from public.sales_purchase_report(e, 'sales', 'party', v_start, v_today);
  perform test_helpers.assert(r.dimension_id = v_cust and r.dimension_label = 'Klien Arsip' and r.document_count = 2
    and r.net_amount::numeric = 1500000 and r.gross_amount::numeric = 1500000,
    '2.1 sales by customer: two issued invoices, the draft excluded');
  select count(*) into n from public.sales_purchase_report(e, 'sales', 'product', v_start, v_today);
  perform test_helpers.assert(n = 2, '2.2 sales by product: the product and "no product"');
  perform test_helpers.assert((select net_amount::numeric from public.sales_purchase_report(e, 'sales', 'product', v_start, v_today)
    where dimension_id = v_prod) = 1000000, '2.3 the product line');
  perform test_helpers.assert((select dimension_label from public.sales_purchase_report(e, 'sales', 'product', v_start, v_today)
    where dimension_id is null) = 'Tanpa produk', '2.4 lines without a product are grouped');
  perform test_helpers.assert((select period_month from public.sales_purchase_report(e, 'sales', 'month', v_start, v_today)) = v_start,
    '2.5 by month');
  select * into r from public.sales_purchase_report(e, 'purchases', 'category', v_start, v_today);
  perform test_helpers.assert(r.dimension_id = v_exp and r.net_amount::numeric = 300000 and r.document_count = 1,
    '2.6 purchases by category: the approved bill');
  perform test_helpers.expect_msg(format('select * from public.sales_purchase_report(%L, %L, %L, %L, %L)', e, 'purchases', 'product', v_start, v_today),
    'INVALID', '2.7 purchases have no product dimension');
  perform test_helpers.expect_msg(format('select * from public.sales_purchase_report(%L, %L, %L, %L, %L)', e, 'sales', 'party', v_today, v_start - 1),
    'INVALID', '2.8 an inverted range is refused');
  perform test_helpers.logout();

  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select * from public.sales_purchase_report(%L, %L, %L, %L, %L)', e, 'sales', 'party', v_start, v_today),
    'FORBIDDEN', '2.9 reports.view is required');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. saved reports
do $$
declare
  e uuid := (select v from test_helpers.p152 where k = 'e');
  v_owner uuid := (select v from test_helpers.p152 where k = 'owner');
  v_staff uuid := (select v from test_helpers.p152 where k = 'staff');
  v_admin uuid := (select v from test_helpers.p152 where k = 'admin');
  v_id uuid;
begin
  perform test_helpers.login(v_owner);
  v_id := public.save_report(e, 'Laba rugi bulan ini', '/reports', 'statement=profit_and_loss&start=2026-10-01');
  perform test_helpers.assert(test_helpers.rows('select * from public.saved_reports') = 1, '3.1 the owner sees their saved report');
  perform test_helpers.expect_msg(format('select public.save_report(%L, %L, %L, %L)', e, 'Laba rugi bulan ini', '/reports', ''),
    'CONFLICT', '3.2 names are unique per person');
  perform test_helpers.expect_msg(format('select public.save_report(%L, %L, %L, %L)', e, 'Luar', 'https://evil.example', ''),
    'INVALID', '3.3 only report pages can be saved');
  perform test_helpers.expect_error(format('delete from public.saved_reports where id = %L', v_id), '42501',
    '3.4 no direct writes (only the RPCs write)');
  perform test_helpers.logout();

  perform test_helpers.login(v_admin);
  perform test_helpers.assert(test_helpers.rows('select * from public.saved_reports') = 0, '3.5 another person does not see it');
  perform test_helpers.expect_msg(format('select public.delete_saved_report(%L)', v_id), 'FORBIDDEN', '3.6 nor delete it');
  perform test_helpers.logout();

  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.save_report(%L, %L, %L, %L)', e, 'Tanpa izin', '/reports', ''),
    'FORBIDDEN', '3.7 reports.view is required');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform public.delete_saved_report(v_id);
  perform test_helpers.assert(test_helpers.rows('select * from public.saved_reports') = 0, '3.8 the owner deletes it');
  perform test_helpers.logout();
end
$$;

rollback;
