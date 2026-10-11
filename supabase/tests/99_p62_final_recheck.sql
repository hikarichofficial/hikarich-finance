-- Decision 408: the automatic final-tax run re-checks EVERY earlier month, so an invoice issued late with a date
-- three months back (after that month was already recorded as 0) still reaches the tax ledger. One transaction,
-- rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  pf uuid;
  v_owner uuid := 'e3620000-0000-0000-0000-000000000001';
  v_cust uuid;
  v_i uuid;
  v_cur date;
  v_old date;
  v_n integer;
  d public.tax_determinations%rowtype;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p62_pf', 'P62 Recheck PP (synthetic)') returning id into pf;
  perform app_private.provision_default_coa(pf);
  perform test_helpers.mk_user(v_owner, 'p62_owner');
  perform test_helpers.mk_member(pf, v_owner, 'owner');
  v_cur := date_trunc('month', app_private.entity_today(pf))::date;
  v_old := (v_cur - interval '3 months')::date;

  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(pf, 'key-p62-f-01', v_old, 'perseroan_perorangan', 'resident', 'final_umkm', 'none', 'none',
    'non_pkp', 'no', null, 'confirmed (synthetic)');
  perform public.tax_engine_activate(pf, 'key-p62-a-01', v_old);
  v_cust := public.create_contact(pf, 'key-p62-c-01', 'customer', 'Pelanggan Uji');
  perform test_helpers.logout();

  v_n := app_private.tax_final_auto_run();
  select * into d from public.tax_determinations
  where entity_id = pf and tax_kind = 'final_umkm' and tax_period = v_old and source_type = 'period' and superseded_at is null;
  perform test_helpers.assert(d.id is not null and d.tax_amount = 0,
    '1.1 the month with no sales is first recorded as 0');

  perform test_helpers.login(v_owner);
  v_i := public.create_invoice_draft(pf, 'key-p62-i-01', v_cust, v_old + 27, v_old + 57, jsonb_build_array(
    jsonb_build_object('description', 'Kursus', 'unit_price', '23362891')));
  perform public.issue_invoice(v_i, 'key-p62-is-01');
  perform test_helpers.logout();

  perform test_helpers.assert(exists (select 1 from app_private.tax_final_recheck_queue where entity_id = pf and period = v_old),
    '1.2 issuing the invoice queued that month');
  -- the deferred step runs at commit; here the commit is brought forward
  set constraints all immediate;
  perform test_helpers.assert(not exists (select 1 from app_private.tax_final_recheck_queue where entity_id = pf and period = v_old),
    '1.3 the queue is empty again once the month has been computed');
  select * into d from public.tax_determinations
  where entity_id = pf and tax_kind = 'final_umkm' and tax_period = v_old and source_type = 'period' and superseded_at is null;
  perform test_helpers.assert(d.tax_amount = 116814 and d.revision = 2 and d.journal_id is not null,
    '2.1 an invoice issued afterwards for that older month moves the tax to 116,814 (new revision, with its journal)');
  perform test_helpers.assert((select coalesce(sum(amount), 0) from public.tax_ledger_entries
    where entity_id = pf and tax_kind = 'final_umkm' and tax_period = v_old) = 116814,
    '2.2 the tax ledger holds 116,814 for that month');

  v_n := app_private.tax_final_auto_run();
  perform test_helpers.assert((select count(*) from public.tax_determinations
    where entity_id = pf and tax_kind = 'final_umkm' and tax_period = v_old and source_type = 'period') = 2,
    '3.1 running the job again changes nothing');

  -- the safety net: a queued month that was not computed yet is picked up by the retry job
  set constraints all deferred;
  insert into app_private.tax_final_recheck_queue (entity_id, period) values (pf, (v_old + interval '1 month')::date)
  on conflict do nothing;
  v_n := app_private.tax_final_process_queue();
  perform test_helpers.assert(v_n >= 1 and not exists (select 1 from app_private.tax_final_recheck_queue where entity_id = pf),
    '4.1 the retry job works through what is still queued');

  -- an invoice issued in the running month is not queued (it stays a live estimate)
  perform test_helpers.login(v_owner);
  v_i := public.create_invoice_draft(pf, 'key-p62-i-02', v_cust, v_cur + 1, v_cur + 31, jsonb_build_array(
    jsonb_build_object('description', 'Lokakarya', 'unit_price', '1000000')));
  perform public.issue_invoice(v_i, 'key-p62-is-02');
  perform test_helpers.logout();
  perform test_helpers.assert(not exists (select 1 from app_private.tax_final_recheck_queue where entity_id = pf and period = v_cur),
    '5.1 the running month is not queued');
end
$$;

rollback;
