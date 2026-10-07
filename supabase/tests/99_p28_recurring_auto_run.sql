-- Decision 327: the scheduled recurring auto-run. The wrapper must create the due draft with no signed-in user,
-- leave a not-yet-due rule alone, and never create the same occurrence twice. One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
  v_owner uuid := 'e3270000-0000-0000-0000-000000000001';
  v_cust uuid;
  v_due uuid;
  v_future uuid;
  v_today date;
  n integer;
  o record;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p28_pt', 'P28 Auto-run PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  perform test_helpers.mk_user(v_owner, 'p28_owner');
  perform test_helpers.mk_member(v_pt, v_owner, 'owner');
  v_today := app_private.entity_today(v_pt);

  perform test_helpers.login(v_owner);
  v_cust := public.create_contact(v_pt, 'key-p28-ct', 'customer', 'Pelanggan Uji');
  v_due := public.create_recurring_rule(v_pt, 'key-p28-due', 'invoice', 'Jatuh tempo hari ini', 'monthly', v_today,
    jsonb_build_object('customer_id', v_cust, 'lines', jsonb_build_array(jsonb_build_object('description', 'Layanan', 'unit_price', '100000'))));
  v_future := public.create_recurring_rule(v_pt, 'key-p28-future', 'invoice', 'Belum jatuh tempo', 'monthly', v_today + 5,
    jsonb_build_object('customer_id', v_cust, 'lines', jsonb_build_array(jsonb_build_object('description', 'Layanan', 'unit_price', '100000'))));
  perform test_helpers.logout();

  -- the job runs with no claims at all
  perform set_config('request.jwt.claims', '', true);
  n := app_private.run_all_due_recurring();
  perform test_helpers.assert(n >= 1, '1.1 the auto-run generated at least the due occurrence');

  select * into o from public.recurring_occurrences where recurring_rule_id = v_due and occurrence_date = v_today;
  perform test_helpers.assert(o.status = 'generated' and o.generated_table = 'invoices', '1.2 the due rule produced a real invoice');
  perform test_helpers.assert((select status from public.invoices where id = o.generated_id) = 'draft', '1.3 the generated invoice is a draft, never posted');
  perform test_helpers.assert(not exists (select 1 from public.recurring_occurrences where recurring_rule_id = v_future), '1.4 a rule that is not due yet is left alone');
  perform test_helpers.assert(coalesce(nullif(current_setting('request.jwt.claims', true), ''), 'none') = 'none', '1.5 the caller''s claims are restored');

  n := app_private.run_all_due_recurring();
  perform test_helpers.assert((select count(*) from public.recurring_occurrences where recurring_rule_id = v_due) = 1, '2.1 running again the same day creates nothing twice');
end
$$;

rollback;
