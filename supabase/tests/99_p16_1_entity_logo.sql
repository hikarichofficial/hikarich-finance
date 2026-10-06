-- Decision 307: the company logo shown on invoices and receipts. Covers authorization, step-up, validation,
-- the stored result, that identity changes keep the logo, and that the audit trail never holds the image.
-- Synthetic data; the whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e1 uuid;
  v_owner uuid := 'e3070000-0000-0000-0000-000000000001';
  v_admin uuid := 'e3070000-0000-0000-0000-000000000002';
  v_png text := 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  v_ver integer;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p16_logo', 'P16 Logo (synthetic)')
  returning id into e1;
  perform test_helpers.mk_user(v_owner, 'p307-owner');
  perform test_helpers.mk_user(v_admin, 'p307-admin');
  perform test_helpers.mk_member(e1, v_owner, 'owner');
  perform test_helpers.mk_member(e1, v_admin, 'finance_admin');

  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.set_entity_logo(%L, %L)', e1, v_png), 'FORBIDDEN', '1.1 finance_admin lacks system.entity_config');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner, 'aal2', interval '1 hour');
  perform test_helpers.expect_msg(format('select public.set_entity_logo(%L, %L)', e1, v_png), 'STEP_UP_REQUIRED', '1.2 a step-up is required');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.set_entity_logo(%L, %L)', e1, 'data:image/svg+xml;base64,PHN2Zz48L3N2Zz4='), 'INVALID', '1.3 an svg is refused (scripts can hide in it)');
  perform test_helpers.expect_msg(format('select public.set_entity_logo(%L, %L)', e1, 'https://example.test/logo.png'), 'INVALID', '1.4 only an embedded image is accepted');
  perform test_helpers.expect_msg(format('select public.set_entity_logo(%L, %L)', e1, 'data:image/png;base64,' || repeat('A', 400000)), 'INVALID', '1.5 an over-large image is refused');

  perform public.set_entity_logo(e1, v_png);
  perform test_helpers.logout();
  perform test_helpers.assert((select logo_data_url = v_png from public.entity_profiles where entity_id = e1), '2.1 the logo is stored');
  perform test_helpers.assert(exists (select 1 from public.audit_events where entity_id = e1 and action = 'entities.logo_changed'
    and (after_state ->> 'has_logo')::boolean and not (before_state ->> 'has_logo')::boolean), '2.2 the change is audited');
  perform test_helpers.assert(not exists (select 1 from public.audit_events where entity_id = e1 and (before_state::text like '%base64%' or after_state::text like '%base64%')),
    '2.3 the image never enters the audit trail');

  -- changing the names keeps the logo
  select version into v_ver from public.entities where id = e1;
  perform test_helpers.login(v_owner);
  perform public.update_entity_identity(e1, 'P16 Logo Baru', null, 'Jl. Contoh 1', null, null, null, null, null, null, v_ver);
  perform test_helpers.logout();
  perform test_helpers.assert((select logo_data_url = v_png and address_line = 'Jl. Contoh 1' from public.entity_profiles where entity_id = e1),
    '3.1 an identity change keeps the logo');

  -- removing it
  perform test_helpers.login(v_owner);
  perform public.set_entity_logo(e1, null);
  perform test_helpers.logout();
  perform test_helpers.assert((select logo_data_url is null from public.entity_profiles where entity_id = e1), '4.1 the logo can be removed');
end
$$;

rollback;
