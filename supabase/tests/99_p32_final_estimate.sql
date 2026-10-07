-- Decision 342: the running month's PPh Final UMKM is shown as an estimate, never recorded. It follows each new
-- invoice, is not available for a future month, needs tax.view, and leaves the final computation unchanged.
-- One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  pf uuid;
  v_owner uuid := 'e3320000-0000-0000-0000-000000000001';
  v_viewer uuid := 'e3320000-0000-0000-0000-000000000002';
  v_stranger uuid := 'e3320000-0000-0000-0000-000000000003';
  v_cust uuid;
  v_i uuid;
  v_today date;
  v_start date;
  e jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p32_pf', 'P32 Estimate PP (synthetic)') returning id into pf;
  perform app_private.provision_default_coa(pf);
  perform test_helpers.mk_user(v_owner, 'p32_owner');
  perform test_helpers.mk_user(v_viewer, 'p32_viewer');
  perform test_helpers.mk_user(v_stranger, 'p32_stranger');
  perform test_helpers.mk_member(pf, v_owner, 'owner');
  perform test_helpers.mk_member(pf, v_viewer, 'viewer_auditor');
  v_today := app_private.entity_today(pf);
  v_start := date_trunc('month', v_today)::date;

  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(pf, 'key-p32-f-01', v_start, 'perseroan_perorangan', 'resident', 'final_umkm', 'none', 'none',
    'non_pkp', 'no', null, 'confirmed (synthetic)');
  perform public.tax_engine_activate(pf, 'key-p32-a-01', v_start);
  v_cust := public.create_contact(pf, 'key-p32-c-01', 'customer', 'Pelanggan Uji');

  e := public.tax_final_estimate(pf, v_start);
  perform test_helpers.assert(e ->> 'status' = 'auto_determined' and (e ->> 'estimate')::boolean and (e ->> 'tax')::numeric = 0,
    '1.1 the running month has an estimate of zero before any sale');

  v_i := public.create_invoice_draft(pf, 'key-p32-i-01', v_cust, v_today, v_today + 30, jsonb_build_array(
    jsonb_build_object('description', 'Kursus', 'unit_price', '100000000')));
  perform public.issue_invoice(v_i, 'key-p32-is-01');
  e := public.tax_final_estimate(pf, v_start);
  perform test_helpers.assert((e ->> 'tax')::numeric = 500000 and (e ->> 'base')::numeric = 100000000 and (e ->> 'turnover_month')::numeric = 100000000,
    '1.2 the estimate is 0.5% of the turnover issued so far (100,000,000 -> 500,000)');

  v_i := public.create_invoice_draft(pf, 'key-p32-i-02', v_cust, v_today, v_today + 30, jsonb_build_array(
    jsonb_build_object('description', 'Lokakarya', 'unit_price', '20000000')));
  perform public.issue_invoice(v_i, 'key-p32-is-02');
  e := public.tax_final_estimate(pf, v_start);
  perform test_helpers.assert((e ->> 'tax')::numeric = 600000, '1.3 the estimate follows each new invoice (120,000,000 -> 600,000)');

  perform test_helpers.assert(public.tax_final_preview(pf, v_start) ->> 'status' = 'not_configured',
    '2.1 the ordinary preview of the running month is unchanged: not computed until the month has ended');
  perform test_helpers.expect_msg(format($q$select public.tax_final_compute(%L, 'key-p32-fc-01', %L::date)$q$, pf, v_start), 'CONFLICT',
    '2.2 the final tax of the running month cannot be computed or posted');
  perform test_helpers.assert(public.tax_final_estimate(pf, (v_start + interval '1 month')::date) ->> 'status' = 'not_configured',
    '2.3 a future month has no estimate');
  perform test_helpers.assert(public.tax_final_estimate(pf, (v_start - interval '1 month')::date) ->> 'estimate' = 'false',
    '2.4 a month already over is not an estimate');
  perform test_helpers.assert(not exists (select 1 from public.tax_determinations where entity_id = pf and source_type = 'period')
    and not exists (select 1 from public.tax_ledger_entries where entity_id = pf and tax_kind = 'final_umkm'),
    '2.5 the estimate records nothing: no period determination and no tax ledger entry');
  perform test_helpers.logout();

  perform test_helpers.login(v_viewer);
  perform test_helpers.assert(public.tax_final_estimate(pf, v_start) ->> 'status' = 'auto_determined', '3.1 a viewer can see the estimate');
  perform test_helpers.logout();

  perform test_helpers.login(v_stranger);
  perform test_helpers.expect_msg(format($q$select public.tax_final_estimate(%L, %L::date)$q$, pf, v_start), 'FORBIDDEN', '3.2 someone outside the Entity cannot');
  perform test_helpers.logout();
end
$$;

rollback;
