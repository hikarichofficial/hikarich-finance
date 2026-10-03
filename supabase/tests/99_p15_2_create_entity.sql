-- P15 decision 276: an OWNER adds an Entity. Covers who may, step-up, validation, what is created, and
-- that the self-grant exception cannot be used for anything else.
-- Synthetic data; the whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e1 uuid;
  v_new uuid;
  v_owner uuid := 'e2760000-0000-0000-0000-000000000001';
  v_admin uuid := 'e2760000-0000-0000-0000-000000000002';
  q text := $q$select public.create_entity('p15_new1', 'company', 'Usaha Baru (synthetic)', 'Merek Baru')$q$;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p15_ce1', 'P15 Create (synthetic)')
  returning id into e1;
  perform test_helpers.mk_user(v_owner, 'p276-owner');
  perform test_helpers.mk_user(v_admin, 'p276-admin');
  perform test_helpers.mk_member(e1, v_owner, 'owner');
  perform test_helpers.mk_member(e1, v_admin, 'finance_admin');

  -- 1. who may, step-up, validation
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(q, 'FORBIDDEN', '1.1 a finance admin cannot add an Entity');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner, 'aal2', interval '1 hour');
  perform test_helpers.expect_msg(q, 'STEP_UP_REQUIRED', '1.2 a step-up is required');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg($q$select public.create_entity('X', 'company', 'Nama', null)$q$, 'INVALID', '1.3 a bad code is refused');
  perform test_helpers.expect_msg($q$select public.create_entity('p15_new1', 'other', 'Nama', null)$q$, 'INVALID', '1.4 an unknown type is refused');
  perform test_helpers.expect_msg($q$select public.create_entity('p15_new1', 'company', '  ', null)$q$, 'INVALID', '1.5 an empty name is refused');
  perform test_helpers.expect_msg($q$select public.create_entity('p15_ce1', 'company', 'Nama', null)$q$, 'CONFLICT', '1.6 a used code is refused');

  -- 2. what is created
  execute q into v_new;
  perform test_helpers.assert((select code = 'p15_new1' and entity_type = 'company' and legal_name = 'Usaha Baru (synthetic)'
    and brand_name = 'Merek Baru' and status = 'active' from public.entities where id = v_new), '2.1 the Entity is stored');
  perform test_helpers.assert((select count(*) from public.entity_memberships m join public.roles r on r.id = m.role_id
    where m.entity_id = v_new and m.user_id = v_owner and r.role_key = 'owner' and m.status = 'active') = 1
    and (select count(*) from public.entity_memberships where entity_id = v_new) = 1,
    '2.2 the creator is its only member, as OWNER');
  perform test_helpers.assert((select count(*) from public.ledger_accounts where entity_id = v_new)
    = (select count(*) from public.ledger_accounts where entity_id = e1) or
    (select count(*) from public.ledger_accounts where entity_id = v_new) > 0, '2.3 the chart of accounts is provisioned');
  perform test_helpers.assert(exists (select 1 from public.entity_profiles where entity_id = v_new), '2.4 the profile row exists');
  perform test_helpers.assert(exists (select 1 from public.audit_events where entity_id = v_new and action = 'entities.created'
    and after_state ->> 'code' = 'p15_new1'), '2.5 audited');
  perform test_helpers.assert(app_authz.is_owner(v_new), '2.6 the creator has OWNER authority on it');
  perform test_helpers.assert(coalesce(current_setting('app.creating_entity', true), '') = '', '2.7 the creation marker is cleared');

  -- 3. the exception is not a way to join an Entity. Run with table privileges (as the trigger sees a
  --    definer function) but with a user identity, so the guard itself is what refuses.
  perform test_helpers.logout();
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform test_helpers.expect_msg(format($q$insert into public.entity_memberships (entity_id, user_id, role_id)
    select %L, %L, id from public.roles where role_key = 'owner'$q$, v_new, v_admin), 'FORBIDDEN', '3.1 no marker: self-grant refused');
  perform set_config('app.creating_entity', e1::text, true);
  perform test_helpers.expect_msg(format($q$insert into public.entity_memberships (entity_id, user_id, role_id)
    select %L, %L, id from public.roles where role_key = 'owner'$q$, v_new, v_admin), 'FORBIDDEN', '3.2 a marker for another Entity does not help');
  perform set_config('app.creating_entity', v_new::text, true);
  perform test_helpers.expect_msg(format($q$insert into public.entity_memberships (entity_id, user_id, role_id)
    select %L, %L, id from public.roles where role_key = 'owner'$q$, v_new, v_admin), 'FORBIDDEN', '3.3 an Entity that already has a member cannot be joined');
  perform set_config('app.creating_entity', '', true);
  perform set_config('request.jwt.claims', '', true);
end
$$;

rollback;
