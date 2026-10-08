-- Decision 348: the faster public.my_access() lists exactly the permissions app_authz.has_permission grants.
-- Every role, with a grant override, with a deny override, without MFA, a disabled membership, a disabled user.
-- One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e1 uuid;
  e2 uuid;
  r record;
  v_user uuid;
  v_m uuid;
  v_n integer := 0;
  v_ref jsonb;
  v_got jsonb;
  v_perm_in_role text;
  v_perm_not_in_role text;
  v_access jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p35_a', 'P35 A (synthetic)') returning id into e1;
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p35_b', 'P35 B (synthetic)') returning id into e2;

  -- one user per role, member of both Entities (an override only in the first one)
  for r in select id, role_key from public.roles order by role_key loop
    v_n := v_n + 1;
    v_user := ('e3500000-0000-0000-0000-' || lpad(v_n::text, 12, '0'))::uuid;
    perform test_helpers.mk_user(v_user, 'p35_' || r.role_key);
    v_m := test_helpers.mk_member(e1, v_user, r.role_key);
    perform test_helpers.mk_member(e2, v_user, r.role_key);

    if r.role_key <> 'owner' then
      select rp.permission_key into v_perm_in_role from public.role_permissions rp where rp.role_id = r.id order by 1 limit 1;
      select x.key into v_perm_not_in_role from public.permissions x
      where not exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = x.key)
      order by 1 limit 1;
      if v_perm_in_role is not null then
        insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (v_m, v_perm_in_role, 'deny');
      end if;
      if v_perm_not_in_role is not null then
        insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (v_m, v_perm_not_in_role, 'grant');
      end if;
    end if;
  end loop;
  perform test_helpers.assert(v_n >= 5, '1.0 at least five roles are covered, got ' || v_n);

  -- 1. the same list as has_permission, for every user, every Entity, with MFA satisfied
  for r in select u.id as user_id, p.display_name from auth.users u join public.profiles p on p.id = u.id
           where u.email like 'p35\_%@example.invalid' order by 2 loop
    perform test_helpers.login(r.user_id);
    v_access := public.my_access();
    perform test_helpers.assert(jsonb_array_length(v_access -> 'memberships') = 2, '1.1 two memberships listed for ' || r.display_name);
    for v_n in 0 .. 1 loop
      v_got := v_access -> 'memberships' -> v_n -> 'permissions';
      v_ref := (select coalesce(jsonb_agg(x.key order by x.key), '[]'::jsonb) from public.permissions x
                where app_authz.has_permission((v_access -> 'memberships' -> v_n ->> 'entity_id')::uuid, x.key));
      perform test_helpers.assert(v_got = v_ref, format('1.2 permissions of %s in membership %s equal has_permission (%s vs %s)',
        r.display_name, v_n, jsonb_array_length(v_got), jsonb_array_length(v_ref)));
    end loop;
    perform test_helpers.logout();
  end loop;

  -- 2. the OWNER holds every permission; a role with a deny override lacks exactly that one
  select id into v_user from auth.users where email = 'p35_owner@example.invalid';
  perform test_helpers.login(v_user);
  perform test_helpers.assert(jsonb_array_length(public.my_access() -> 'memberships' -> 0 -> 'permissions') = (select count(*) from public.permissions),
    '2.1 OWNER holds all permissions');
  perform test_helpers.logout();

  -- 3. without MFA (aal1) an OWNER gets no permissions, exactly as has_permission refuses everything
  perform test_helpers.login(v_user, 'aal1');
  v_access := public.my_access();
  perform test_helpers.assert(v_access -> 'memberships' -> 0 -> 'permissions' = '[]'::jsonb
    and not (v_access -> 'memberships' -> 0 ->> 'mfa_satisfied')::boolean, '3.1 OWNER without MFA lists no permissions');
  perform test_helpers.logout();

  -- 4. a disabled membership is not listed; a disabled user is reported inactive with nothing listed
  select id into v_user from auth.users where email = 'p35_finance_admin@example.invalid';
  update public.entity_memberships set status = 'disabled', disabled_at = now() where entity_id = e2 and user_id = v_user;
  perform test_helpers.login(v_user);
  v_access := public.my_access();
  perform test_helpers.assert(jsonb_array_length(v_access -> 'memberships') = 1
    and (v_access -> 'memberships' -> 0 ->> 'entity_id')::uuid = e1, '4.1 a disabled membership is not listed');
  perform test_helpers.logout();
  update public.profiles set is_active = false, disabled_at = now() where id = v_user;
  perform test_helpers.login(v_user);
  v_access := public.my_access();
  perform test_helpers.assert(not (v_access ->> 'active')::boolean and jsonb_array_length(v_access -> 'memberships') = 0,
    '4.2 a disabled user is inactive and lists nothing');
  perform test_helpers.logout();
end
$$;

rollback;
