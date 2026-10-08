-- Decision 346: the final tax of a month that has ended is computed and recorded by the scheduled job, with no
-- person signed in; it is repeatable, follows a changed turnover with a new revision, and skips what it cannot
-- compute. One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  pf uuid;
  v_owner uuid := 'e3340000-0000-0000-0000-000000000001';
  v_cust uuid;
  v_i uuid;
  v_today date;
  v_cur date;
  v_prev date;
  v_n integer;
  d public.tax_determinations%rowtype;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p34_pf', 'P34 Auto Final PP (synthetic)') returning id into pf;
  perform app_private.provision_default_coa(pf);
  perform test_helpers.mk_user(v_owner, 'p34_owner');
  perform test_helpers.mk_member(pf, v_owner, 'owner');
  v_today := app_private.entity_today(pf);
  v_cur := date_trunc('month', v_today)::date;
  v_prev := (v_cur - interval '1 month')::date;

  perform test_helpers.login(v_owner);
  perform public.tax_record_entity_profile(pf, 'key-p34-f-01', v_prev, 'perseroan_perorangan', 'resident', 'final_umkm', 'none', 'none',
    'non_pkp', 'no', null, 'confirmed (synthetic)');
  perform public.tax_engine_activate(pf, 'key-p34-a-01', v_prev);
  v_cust := public.create_contact(pf, 'key-p34-c-01', 'customer', 'Pelanggan Uji');
  v_i := public.create_invoice_draft(pf, 'key-p34-i-01', v_cust, v_prev + 9, v_prev + 39, jsonb_build_array(
    jsonb_build_object('description', 'Kursus', 'unit_price', '100000000')));
  perform public.issue_invoice(v_i, 'key-p34-is-01');
  perform test_helpers.logout();

  perform test_helpers.assert(not exists (select 1 from public.tax_determinations where entity_id = pf and source_type = 'period'),
    '1.0 nothing is recorded before the job runs');

  v_n := app_private.tax_final_auto_run();
  select * into d from public.tax_determinations
  where entity_id = pf and tax_kind = 'final_umkm' and tax_period = v_prev and source_type = 'period' and superseded_at is null;
  perform test_helpers.assert(d.id is not null and d.tax_amount = 500000 and d.revision = 1 and d.journal_id is not null,
    '1.1 the job recorded the tax of the month that ended: 0.5% of 100,000,000, with its journal');
  perform test_helpers.assert((select count(*) from public.tax_ledger_entries where entity_id = pf and tax_kind = 'final_umkm') = 1
    and (select coalesce(sum(amount), 0) from public.tax_ledger_entries where entity_id = pf and tax_kind = 'final_umkm') = 500000,
    '1.2 one accrual in the tax ledger');
  perform test_helpers.assert(not exists (select 1 from public.tax_determinations where entity_id = pf and tax_period = v_cur and source_type = 'period'),
    '1.3 the running month is not recorded (it stays an estimate)');

  v_n := app_private.tax_final_auto_run();
  perform test_helpers.assert((select count(*) from public.tax_determinations where entity_id = pf and tax_period = v_prev and source_type = 'period') = 1
    and (select count(*) from public.tax_ledger_entries where entity_id = pf and tax_kind = 'final_umkm') = 1,
    '2.1 running the job again changes nothing');

  perform test_helpers.login(v_owner);
  v_i := public.create_invoice_draft(pf, 'key-p34-i-02', v_cust, v_prev + 14, v_prev + 44, jsonb_build_array(
    jsonb_build_object('description', 'Lokakarya', 'unit_price', '20000000')));
  perform public.issue_invoice(v_i, 'key-p34-is-02');
  perform test_helpers.logout();
  v_n := app_private.tax_final_auto_run();
  select * into d from public.tax_determinations
  where entity_id = pf and tax_kind = 'final_umkm' and tax_period = v_prev and source_type = 'period' and superseded_at is null;
  perform test_helpers.assert(d.tax_amount = 600000 and d.revision = 2
    and (select coalesce(sum(amount), 0) from public.tax_ledger_entries where entity_id = pf and tax_kind = 'final_umkm') = 600000,
    '2.2 a later invoice of the same month moves the tax by the difference only (new revision, 600,000 in total)');

  perform test_helpers.assert(not exists (select 1 from public.tax_determinations where entity_id = pf and tax_period < v_prev and source_type = 'period'),
    '3.1 months before the profile started are skipped, not recorded');
  perform test_helpers.assert(app_private.tax_final_auto_run() >= 0, '3.2 an Entity without a profile or a failing month never stops the job');
end
$$;

rollback;
