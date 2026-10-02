-- P15 decision 272: changing the Entity's names, address and contact details from Settings. Covers
-- authorization, step-up, validation, optimistic concurrency, the stored result and the audit record.
-- Synthetic data; the whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e1 uuid;
  v_owner uuid := 'e2720000-0000-0000-0000-000000000001';
  v_admin uuid := 'e2720000-0000-0000-0000-000000000002';
  v_ver integer;
  v_new integer;
  q text;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p15_id1', 'P15 Identity (synthetic)')
  returning id into e1;
  perform test_helpers.mk_user(v_owner, 'p272-owner');
  perform test_helpers.mk_user(v_admin, 'p272-admin');
  perform test_helpers.mk_member(e1, v_owner, 'owner');
  perform test_helpers.mk_member(e1, v_admin, 'finance_admin');
  select version into v_ver from public.entities where id = e1;

  q := format('select public.update_entity_identity(%L, %L, %L, %L, %L, null, null, %L, null, null, %s)',
    e1, 'PT Contoh Baru', 'Merek Baru', 'Jl. Contoh 1', 'Makassar', 'halo@example.test', v_ver);

  -- 1. authorization, step-up, validation, concurrency
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(q, 'FORBIDDEN', '1.1 finance_admin lacks system.entity_config');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner, 'aal2', interval '1 hour');
  perform test_helpers.expect_msg(q, 'STEP_UP_REQUIRED', '1.2 a step-up is required');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.update_entity_identity(%L, %L, null, null, null, null, null, null, null, null, %s)',
    e1, '   ', v_ver), 'INVALID', '1.3 an empty legal name is refused');
  perform test_helpers.expect_msg(format('select public.update_entity_identity(%L, %L, null, null, null, null, null, %L, null, null, %s)',
    e1, 'PT Contoh', 'bukan-email', v_ver), 'INVALID', '1.4 a malformed email is refused');
  perform test_helpers.expect_msg(format('select public.update_entity_identity(%L, %L, null, null, null, null, null, null, null, null, %s)',
    e1, 'PT Contoh', v_ver + 7), 'CONFLICT', '1.5 a stale version is refused');

  -- 2. a valid change
  execute q into v_new;
  perform test_helpers.logout();
  perform test_helpers.assert(v_new = v_ver + 1, '2.1 the version advances when a name changes');
  perform test_helpers.assert((select legal_name = 'PT Contoh Baru' and brand_name = 'Merek Baru' from public.entities where id = e1),
    '2.2 both names stored');
  perform test_helpers.assert((select address_line = 'Jl. Contoh 1' and city = 'Makassar' and contact_email = 'halo@example.test'
    and province is null from public.entity_profiles where entity_id = e1), '2.3 the profile row is created with the details');
  perform test_helpers.assert(exists (select 1 from public.audit_events where entity_id = e1
    and action = 'entities.identity_changed' and before_state ->> 'legal_name' = 'P15 Identity (synthetic)'
    and after_state ->> 'brand_name' = 'Merek Baru'), '2.4 audited with before and after');

  -- 3. clearing the brand and changing only the profile keeps the version
  perform test_helpers.login(v_owner);
  execute format('select public.update_entity_identity(%L, %L, %L, null, %L, null, null, null, null, null, %s)',
    e1, 'PT Contoh Baru', 'Merek Baru', 'Jakarta', v_new) into v_ver;
  perform test_helpers.logout();
  perform test_helpers.assert(v_ver = v_new, '3.1 a profile-only change does not advance the Entity version');
  perform test_helpers.assert((select city = 'Jakarta' and address_line is null and contact_email is null
    from public.entity_profiles where entity_id = e1), '3.2 the profile is replaced, empty fields are cleared');

  perform test_helpers.login(v_owner);
  execute format('select public.update_entity_identity(%L, %L, %L, null, null, null, null, null, null, null, %s)',
    e1, 'PT Contoh Baru', '', v_ver) into v_new;
  perform test_helpers.logout();
  perform test_helpers.assert((select brand_name is null from public.entities where id = e1), '3.3 an empty brand clears it');
end
$$;

rollback;
