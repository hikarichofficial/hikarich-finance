-- Decision 349: app_authz.permitted_entities(key) says exactly what app_authz.has_permission says, and the
-- row-level-security policies that now use it (once per statement) show and refuse exactly the same rows.
-- One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e1 uuid;
  e2 uuid;
  r record;
  k record;
  v_n integer := 0;
  v_user uuid;
  v_m uuid;
  v_perm_in_role text;
  v_perm_not_in_role text;
  v_bad integer;
  v_c1 uuid;
  v_c2 uuid;
  v_role_ok text;
  v_role_no text;
  v_cnt integer;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p36_a', 'P36 A (synthetic)') returning id into e1;
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p36_b', 'P36 B (synthetic)') returning id into e2;

  -- one user per role: member of A with a deny and a grant override, member of B plain
  for r in select id, role_key from public.roles order by role_key loop
    v_n := v_n + 1;
    v_user := ('e3600000-0000-0000-0000-' || lpad(v_n::text, 12, '0'))::uuid;
    perform test_helpers.mk_user(v_user, 'p36_' || r.role_key);
    v_m := test_helpers.mk_member(e1, v_user, r.role_key);
    perform test_helpers.mk_member(e2, v_user, r.role_key);
    if r.role_key <> 'owner' then
      select rp.permission_key into v_perm_in_role from public.role_permissions rp where rp.role_id = r.id order by 1 limit 1;
      select x.key into v_perm_not_in_role from public.permissions x
      where not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = x.key) order by 1 limit 1;
      if v_perm_in_role is not null then
        insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (v_m, v_perm_in_role, 'deny');
      end if;
      if v_perm_not_in_role is not null then
        insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (v_m, v_perm_not_in_role, 'grant');
      end if;
    end if;
  end loop;
  perform test_helpers.assert(v_n >= 5, '1.0 at least five roles are covered, got ' || v_n);

  -- 1. the list of Entities equals has_permission, for every user, permission and Entity (MFA satisfied)
  v_bad := 0;
  for r in select u.id as user_id from auth.users u where u.email like 'p36\_%@example.invalid' loop
    perform test_helpers.login(r.user_id);
    for k in select x.key from public.permissions x loop
      if (e1 = any (app_authz.permitted_entities(k.key))) is distinct from app_authz.has_permission(e1, k.key)
         or (e2 = any (app_authz.permitted_entities(k.key))) is distinct from app_authz.has_permission(e2, k.key) then
        v_bad := v_bad + 1;
      end if;
    end loop;
    perform test_helpers.logout();
  end loop;
  perform test_helpers.assert(v_bad = 0, '1.1 permitted_entities equals has_permission everywhere, differences: ' || v_bad);

  -- 2. an OWNER without MFA, a disabled membership, a disabled user
  select id into v_user from auth.users where email = 'p36_owner@example.invalid';
  perform test_helpers.login(v_user, 'aal1');
  perform test_helpers.assert(cardinality(app_authz.permitted_entities('contacts.view')) = 0, '2.1 OWNER without MFA is permitted nowhere');
  perform test_helpers.logout();
  select id into v_user from auth.users where email = 'p36_finance_admin@example.invalid';
  update public.entity_memberships set status = 'disabled', disabled_at = now() where entity_id = e2 and user_id = v_user;
  perform test_helpers.login(v_user);
  perform test_helpers.assert(not (e2 = any (app_authz.permitted_entities('contacts.view'))), '2.2 a disabled membership permits nothing');
  perform test_helpers.logout();
  update public.profiles set is_active = false, disabled_at = now() where id = v_user;
  perform test_helpers.login(v_user);
  perform test_helpers.assert(cardinality(app_authz.permitted_entities('contacts.view')) = 0, '2.3 a disabled user is permitted nowhere');
  perform test_helpers.logout();
  update public.profiles set is_active = true, disabled_at = null where id = v_user;
  update public.entity_memberships set status = 'active', disabled_at = null where entity_id = e2 and user_id = v_user;

  -- 3. no policy keeps the per-row shape, and the rewritten ones exist
  perform test_helpers.assert(not exists (
    select 1 from pg_policies where schemaname = 'public'
      and coalesce(qual, '') || coalesce(with_check, '') ~ 'app_authz\.has_permission\([a-z_]+, ''[a-z_.]+''::text\)'),
    '3.1 no policy asks has_permission once per row for a column and a literal');
  perform test_helpers.assert((select count(*) from pg_policies where schemaname = 'public'
    and coalesce(qual, '') || coalesce(with_check, '') like '%permitted_entities%') >= 50, '3.2 the rewritten policies are in place');

  -- 4. real rows through the rewritten contacts policies
  select r1.role_key, r2.role_key into v_role_ok, v_role_no
  from (select ro.role_key from public.roles ro
        where exists (select 1 from public.role_permissions rp where rp.role_id = ro.id and rp.permission_key = 'contacts.view')
          and exists (select 1 from public.role_permissions rp where rp.role_id = ro.id and rp.permission_key = 'contacts.create')
          and ro.role_key <> 'owner' order by 1 limit 1) r1,
       (select ro.role_key from public.roles ro
        where not exists (select 1 from public.role_permissions rp where rp.role_id = ro.id and rp.permission_key = 'contacts.view')
          and ro.role_key <> 'owner' order by 1 limit 1) r2;
  perform test_helpers.assert(v_role_ok is not null and v_role_no is not null, '4.0 roles for the contacts check exist');

  insert into public.contacts (entity_id, kind, display_name) values (e1, 'customer', 'P36 kontak A') returning id into v_c1;
  insert into public.contacts (entity_id, kind, display_name) values (e2, 'customer', 'P36 kontak B') returning id into v_c2;

  -- a user who is a member of A only
  v_user := 'e3600000-0000-0000-0000-0000000000f1';
  perform test_helpers.mk_user(v_user, 'p36_only_a');
  v_m := test_helpers.mk_member(e1, v_user, v_role_ok);
  perform test_helpers.login(v_user);
  perform test_helpers.assert((select count(*) from public.contacts where id in (v_c1, v_c2)) = 1
    and exists (select 1 from public.contacts where id = v_c1), '4.1 a member of A sees the contact of A and not the contact of B');
  insert into public.contacts (entity_id, kind, display_name) values (e1, 'customer', 'P36 baru A');
  perform test_helpers.expect_error(format('insert into public.contacts (entity_id, kind, display_name) values (%L, %L, %L)', e2, 'customer', 'P36 salah'),
    '42501', '4.2 a member of A cannot create a contact in B');
  perform test_helpers.logout();

  -- a deny override hides the contacts of that Entity at once; a grant shows them
  insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (v_m, 'contacts.view', 'deny');
  perform test_helpers.login(v_user);
  perform test_helpers.assert((select count(*) from public.contacts where id in (v_c1, v_c2)) = 0, '4.3 a deny override hides the contacts');
  perform test_helpers.logout();
  delete from public.membership_permission_overrides where membership_id = v_m;

  v_user := 'e3600000-0000-0000-0000-0000000000f2';
  perform test_helpers.mk_user(v_user, 'p36_no_view');
  v_m := test_helpers.mk_member(e1, v_user, v_role_no);
  perform test_helpers.login(v_user);
  perform test_helpers.assert((select count(*) from public.contacts where id in (v_c1, v_c2)) = 0, '4.4 a role without contacts.view sees nothing');
  perform test_helpers.logout();
  insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (v_m, 'contacts.view', 'grant');
  perform test_helpers.login(v_user);
  perform test_helpers.assert((select count(*) from public.contacts where id in (v_c1, v_c2)) = 1, '4.5 a grant override shows the contact of A only');
  perform test_helpers.logout();

  -- OWNER without MFA sees nothing; with MFA sees its own Entity only
  v_user := 'e3600000-0000-0000-0000-0000000000f3';
  perform test_helpers.mk_user(v_user, 'p36_owner_a');
  perform test_helpers.mk_member(e1, v_user, 'owner');
  perform test_helpers.login(v_user, 'aal1');
  perform test_helpers.assert((select count(*) from public.contacts where id in (v_c1, v_c2)) = 0, '4.6 OWNER without MFA sees nothing');
  perform test_helpers.logout();
  perform test_helpers.login(v_user);
  perform test_helpers.assert((select count(*) from public.contacts where id in (v_c1, v_c2)) = 1, '4.7 OWNER with MFA sees its own Entity only');
  perform test_helpers.logout();
end
$$;

rollback;
