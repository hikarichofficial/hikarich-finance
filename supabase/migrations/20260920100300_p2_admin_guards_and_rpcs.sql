-- P2 (Step 15 §6): membership/role administration, anti-escalation guards, session revocation,
-- sensitive-field reveal and owner bootstrap.
-- Authority: Step 06 §1 (no self-granting), §7-§9 (step-up, immediate disable, session revocation),
-- §12 (server privilege boundary), §13 (audit), Step 14 (database functions with explicit search_path).
--
-- Every RPC below is SECURITY DEFINER with a pinned search_path and derives the actor from the verified
-- JWT. None trusts a role, Entity or permission supplied by the caller. Failures use stable message
-- prefixes (UNAUTHENTICATED, FORBIDDEN, STEP_UP_REQUIRED, INVALID) that the application maps to errors.

-- ------------------------------------------------------------ guards
-- A user can never create, change or disable their own membership through a user session, and an Entity
-- can never be left without an active OWNER (lock-out protection).
create function app_private.tg_membership_guard() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
begin
  select id into v_owner from public.roles where role_key = 'owner';

  if tg_op = 'INSERT' then
    if v_uid is not null and new.user_id = v_uid then
      raise exception 'FORBIDDEN: users cannot grant themselves Entity access' using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;

  if v_uid is not null and old.user_id = v_uid
     and (tg_op = 'DELETE' or (new.role_id, new.status, new.user_id) is distinct from (old.role_id, old.status, old.user_id)) then
    raise exception 'FORBIDDEN: users cannot change their own Entity access' using errcode = 'insufficient_privilege';
  end if;

  if old.role_id = v_owner and old.status = 'active'
     and (tg_op = 'DELETE'
          or new.role_id <> old.role_id or new.status <> 'active' or new.user_id <> old.user_id) then
    if not exists (
      select 1
      from public.entity_memberships m
      join public.profiles p on p.id = m.user_id and p.is_active
      where m.entity_id = old.entity_id and m.role_id = v_owner and m.status = 'active' and m.id <> old.id
    ) then
      raise exception 'LAST_OWNER: an Entity must keep at least one active OWNER' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;
create trigger tg_guard before insert or update or delete on public.entity_memberships
  for each row execute function app_private.tg_membership_guard();

create function app_private.tg_overrides_guard() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_membership public.entity_memberships%rowtype;
  v_role text;
begin
  select * into v_membership from public.entity_memberships
  where id = case when tg_op = 'DELETE' then old.membership_id else new.membership_id end;
  if v_uid is not null and v_membership.user_id = v_uid then
    raise exception 'FORBIDDEN: users cannot change their own permissions' using errcode = 'insufficient_privilege';
  end if;
  select role_key into v_role from public.roles where id = v_membership.role_id;
  if v_role = 'owner' and tg_op <> 'DELETE' then
    raise exception 'INVALID: OWNER permissions are not overridden' using errcode = 'integrity_constraint_violation';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;
create trigger tg_guard before insert or update or delete on public.membership_permission_overrides
  for each row execute function app_private.tg_overrides_guard();

create function app_private.tg_roles_guard() returns trigger
language plpgsql as $$
begin
  if old.is_system then
    if tg_op = 'DELETE' then
      raise exception 'System role % cannot be deleted', old.role_key using errcode = 'integrity_constraint_violation';
    end if;
    if new.role_key <> old.role_key or new.is_system is distinct from old.is_system then
      raise exception 'System role % keeps its key and system flag', old.role_key using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;
create trigger tg_guard before update or delete on public.roles
  for each row execute function app_private.tg_roles_guard();

-- Disabling a user: keep the disabled_at bookkeeping consistent, protect the last OWNER, revoke sessions.
create function app_private.tg_profiles_guard() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_owner uuid;
begin
  if new.is_active = false and new.disabled_at is null then
    new.disabled_at := now();
  elsif new.is_active = true then
    new.disabled_at := null;
  end if;

  if old.is_active and not new.is_active then
    select id into v_owner from public.roles where role_key = 'owner';
    if exists (
      select 1 from public.entity_memberships m
      where m.user_id = old.id and m.role_id = v_owner and m.status = 'active'
        and not exists (
          select 1
          from public.entity_memberships m2
          join public.profiles p2 on p2.id = m2.user_id and p2.is_active
          where m2.entity_id = m.entity_id and m2.role_id = v_owner and m2.status = 'active' and m2.user_id <> old.id)
    ) then
      raise exception 'LAST_OWNER: the last active OWNER of an Entity cannot be disabled' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.profiles
  for each row execute function app_private.tg_profiles_guard();

-- Step 06 §9: access already stops at the next statement because every check reads the live profile row.
-- This additionally removes the user's Supabase sessions and records a security event.
create function app_private.tg_profiles_revoke() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_revoked boolean := false;
begin
  if old.is_active and not new.is_active then
    begin
      delete from auth.sessions where user_id = new.id;
      v_revoked := true;
    exception when insufficient_privilege or undefined_table then
      raise warning 'Could not remove auth sessions for %; access is still denied by profile state', new.id;
    end;
    insert into public.security_events (user_id, event_type, severity, metadata)
    values (new.id, 'user_disabled', 'warning', jsonb_build_object('sessions_revoked', v_revoked, 'by', auth.uid()));
  elsif not old.is_active and new.is_active then
    insert into public.security_events (user_id, event_type, severity, metadata)
    values (new.id, 'user_enabled', 'info', jsonb_build_object('by', auth.uid()));
  end if;
  return null;
end
$$;
create trigger tg_revoke after update on public.profiles
  for each row execute function app_private.tg_profiles_revoke();

-- ------------------------------------------------------------ RPC: my_access
-- One round trip for the application: who am I, in which Entities, with which capabilities.
-- Capabilities are returned only for memberships whose MFA requirement is met.
create function public.my_access() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  return jsonb_build_object(
    'user_id', v_uid,
    'active', coalesce((select p.is_active from public.profiles p where p.id = v_uid), false),
    'display_name', (select p.display_name from public.profiles p where p.id = v_uid),
    'aal', coalesce(auth.jwt() ->> 'aal', 'aal1'),
    'recent_step_up', app_authz.recent_step_up(),
    'memberships', coalesce((
      select jsonb_agg(jsonb_build_object(
        'membership_id', m.id,
        'entity_id', e.id,
        'entity_code', e.code,
        'entity_type', e.entity_type,
        'entity_name', e.legal_name,
        'role_key', r.role_key,
        'mfa_required', app_authz.mfa_required(e.id, r.role_key),
        'mfa_satisfied', app_authz.mfa_satisfied(e.id, r.role_key),
        'permissions', case when app_authz.mfa_satisfied(e.id, r.role_key) then
            coalesce((select jsonb_agg(x.key order by x.key) from public.permissions x
                      where app_authz.has_permission(e.id, x.key)), '[]'::jsonb)
          else '[]'::jsonb end
      ) order by e.code)
      from public.entity_memberships m
      join public.entities e on e.id = m.entity_id and e.status = 'active'
      join public.roles r on r.id = m.role_id
      where m.user_id = v_uid and m.status = 'active'
        and exists (select 1 from public.profiles p where p.id = v_uid and p.is_active)
    ), '[]'::jsonb));
end
$$;
revoke all on function public.my_access() from public, anon;
grant execute on function public.my_access() to authenticated;

-- ------------------------------------------------------------ RPC: membership administration
create function public.assign_membership(p_entity uuid, p_user uuid, p_role_key text, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_role public.roles%rowtype;
  v_type text;
  v_missing text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_user = v_uid then
    raise exception 'FORBIDDEN: users cannot change their own access' using errcode = 'insufficient_privilege';
  end if;
  if not (app_authz.has_permission(p_entity, 'users.assign_role') and app_authz.has_permission(p_entity, 'users.assign_entity')) then
    raise exception 'FORBIDDEN: missing users.assign_role / users.assign_entity' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;

  select * into v_role from public.roles where role_key = p_role_key;
  if not found then
    raise exception 'INVALID: unknown role' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.profiles where id = p_user and is_active) then
    raise exception 'INVALID: target user is unknown or disabled' using errcode = 'invalid_parameter_value';
  end if;

  select entity_type into v_type from public.entities where id = p_entity;
  if (v_role.role_key = 'owner' or v_type = 'personal') and not app_authz.is_owner(p_entity) then
    raise exception 'FORBIDDEN: only an OWNER manages OWNER access and the Personal Entity' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from public.entity_memberships m join public.roles r on r.id = m.role_id
             where m.entity_id = p_entity and m.user_id = p_user and r.role_key = 'owner')
     and not app_authz.is_owner(p_entity) then
    raise exception 'FORBIDDEN: only an OWNER changes an OWNER membership' using errcode = 'insufficient_privilege';
  end if;

  -- No privilege escalation: a role can only be handed out if the caller holds all of its permissions.
  if v_role.role_key <> 'owner' then
    select rp.permission_key into v_missing
    from public.role_permissions rp
    where rp.role_id = v_role.id and not app_authz.has_permission(p_entity, rp.permission_key)
    limit 1;
    if v_missing is not null then
      raise exception 'FORBIDDEN: cannot grant a permission you do not hold (%)', v_missing using errcode = 'insufficient_privilege';
    end if;
  end if;

  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  insert into public.entity_memberships (entity_id, user_id, role_id, granted_by)
  values (p_entity, p_user, v_role.id, v_uid)
  on conflict (entity_id, user_id) do update
    set role_id = excluded.role_id, status = 'active', disabled_at = null, granted_by = excluded.granted_by
  returning id into v_id;

  insert into public.security_events (user_id, entity_id, event_type, severity, metadata)
  values (p_user, p_entity, 'membership_assigned', 'warning',
          jsonb_build_object('role', v_role.role_key, 'by', v_uid, 'membership_id', v_id));
  return v_id;
end
$$;
revoke all on function public.assign_membership(uuid, uuid, text, text) from public, anon;
grant execute on function public.assign_membership(uuid, uuid, text, text) to authenticated;

create function public.set_membership_status(p_membership uuid, p_active boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_m public.entity_memberships%rowtype;
  v_target_owner boolean;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_m from public.entity_memberships where id = p_membership;
  if not found or v_m.user_id = v_uid
     or not app_authz.has_permission(v_m.entity_id, 'users.disable') then
    raise exception 'FORBIDDEN' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  select exists (select 1 from public.roles r where r.id = v_m.role_id and r.role_key = 'owner') into v_target_owner;
  if v_target_owner and not app_authz.is_owner(v_m.entity_id) then
    raise exception 'FORBIDDEN: only an OWNER changes an OWNER membership' using errcode = 'insufficient_privilege';
  end if;

  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  update public.entity_memberships
  set status = case when p_active then 'active' else 'disabled' end,
      disabled_at = case when p_active then null else now() end
  where id = p_membership;

  insert into public.security_events (user_id, entity_id, event_type, severity, metadata)
  values (v_m.user_id, v_m.entity_id, case when p_active then 'membership_enabled' else 'membership_disabled' end,
          'warning', jsonb_build_object('by', v_uid, 'membership_id', p_membership));
end
$$;
revoke all on function public.set_membership_status(uuid, boolean, text) from public, anon;
grant execute on function public.set_membership_status(uuid, boolean, text) to authenticated;

create function public.set_user_active(p_user uuid, p_active boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  -- The caller must be allowed to disable users in EVERY Entity the target belongs to.
  if p_user = v_uid
     or not exists (select 1 from public.entity_memberships where user_id = p_user)
     or exists (select 1 from public.entity_memberships m
                where m.user_id = p_user and not app_authz.has_permission(m.entity_id, 'users.disable')) then
    raise exception 'FORBIDDEN' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  -- Only an OWNER may disable a user who is an OWNER anywhere.
  if exists (select 1 from public.entity_memberships m join public.roles r on r.id = m.role_id
             where m.user_id = p_user and r.role_key = 'owner' and not app_authz.is_owner(m.entity_id)) then
    raise exception 'FORBIDDEN: only an OWNER disables an OWNER' using errcode = 'insufficient_privilege';
  end if;

  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  update public.profiles set is_active = p_active where id = p_user;
end
$$;
revoke all on function public.set_user_active(uuid, boolean, text) from public, anon;
grant execute on function public.set_user_active(uuid, boolean, text) to authenticated;

create function public.set_permission_override(p_membership uuid, p_key text, p_effect text, p_reason text default null)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_m public.entity_memberships%rowtype;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_effect not in ('grant', 'deny', 'clear') then
    raise exception 'INVALID: effect must be grant, deny or clear' using errcode = 'invalid_parameter_value';
  end if;
  select * into v_m from public.entity_memberships where id = p_membership;
  if not found or v_m.user_id = v_uid
     or not app_authz.has_permission(v_m.entity_id, 'users.change_permissions') then
    raise exception 'FORBIDDEN' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.permissions where key = p_key) then
    raise exception 'INVALID: unknown permission' using errcode = 'invalid_parameter_value';
  end if;
  -- No privilege escalation: only permissions the caller holds can be granted.
  if p_effect = 'grant' and not app_authz.has_permission(v_m.entity_id, p_key) then
    raise exception 'FORBIDDEN: cannot grant a permission you do not hold' using errcode = 'insufficient_privilege';
  end if;

  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  if p_effect = 'clear' then
    delete from public.membership_permission_overrides where membership_id = p_membership and permission_key = p_key;
  else
    insert into public.membership_permission_overrides (membership_id, permission_key, effect, reason)
    values (p_membership, p_key, p_effect, p_reason)
    on conflict (membership_id, permission_key) do update set effect = excluded.effect, reason = excluded.reason;
  end if;

  insert into public.security_events (user_id, entity_id, event_type, severity, metadata)
  values (v_m.user_id, v_m.entity_id, 'permission_override', 'warning',
          jsonb_build_object('permission', p_key, 'effect', p_effect, 'by', v_uid));
end
$$;
revoke all on function public.set_permission_override(uuid, text, text, text) from public, anon;
grant execute on function public.set_permission_override(uuid, text, text, text) to authenticated;

-- ------------------------------------------------------------ RPC: reveal a sensitive value
-- Sensitive columns are not selectable by browser roles. This returns exactly one value, only to callers
-- holding the explicit capability in that record's Entity, and records that it was revealed (never the value).
create function public.reveal_sensitive(p_kind text, p_id uuid) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
  v_value text;
  v_perm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;

  if p_kind = 'contact_tax_identifier' then
    select entity_id, tax_identifier into v_entity, v_value from public.contacts where id = p_id;
    v_perm := 'contacts.view_sensitive';
  elsif p_kind = 'contact_bank_account_number' then
    select entity_id, account_number into v_entity, v_value from public.contact_bank_accounts where id = p_id;
    v_perm := 'money.view_sensitive';
  elsif p_kind = 'financial_account_number' then
    select entity_id, account_number into v_entity, v_value from public.financial_accounts where id = p_id;
    v_perm := 'money.view_sensitive';
  else
    raise exception 'INVALID: unknown sensitive kind' using errcode = 'invalid_parameter_value';
  end if;

  -- Same answer for "does not exist" and "not allowed": no existence leak.
  if v_entity is null or not app_authz.has_permission(v_entity, v_perm) then
    raise exception 'FORBIDDEN' using errcode = 'insufficient_privilege';
  end if;

  insert into public.security_events (user_id, entity_id, event_type, severity, metadata)
  values (auth.uid(), v_entity, 'sensitive_reveal', 'info', jsonb_build_object('kind', p_kind, 'id', p_id));
  return v_value;
end
$$;
revoke all on function public.reveal_sensitive(text, uuid) from public, anon;
grant execute on function public.reveal_sensitive(text, uuid) to authenticated;

-- ------------------------------------------------------------ owner bootstrap (deployment-time only)
-- Seeds the initial OWNER / Super Admin (Step 06 §15). Callable only by database administrators (no grant
-- to any API role) and only while no OWNER membership exists at all.
create function app_private.bootstrap_owner(p_user uuid, p_display_name text) returns integer
language plpgsql as $$
declare
  v_owner uuid;
  v_count integer;
begin
  select id into v_owner from public.roles where role_key = 'owner';
  if exists (select 1 from public.entity_memberships where role_id = v_owner) then
    raise exception 'An OWNER already exists; further OWNER access is granted through assign_membership'
      using errcode = 'integrity_constraint_violation';
  end if;
  if not exists (select 1 from auth.users where id = p_user) then
    raise exception 'Unknown auth user %', p_user using errcode = 'no_data_found';
  end if;
  insert into public.profiles (id, display_name) values (p_user, p_display_name) on conflict (id) do nothing;
  insert into public.entity_memberships (entity_id, user_id, role_id)
  select e.id, p_user, v_owner from public.entities e where e.status = 'active';
  get diagnostics v_count = row_count;
  return v_count;
end
$$;
revoke all on function app_private.bootstrap_owner(uuid, text) from public, anon, authenticated;

revoke all on all functions in schema app_private from public;
revoke all on all procedures in schema app_private from public;
