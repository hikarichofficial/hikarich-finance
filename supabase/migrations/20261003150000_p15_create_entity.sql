-- P15 decision 276 (OWNER, 3 October 2026: "setuju"): an OWNER can add a further Entity from Settings.
--
-- Rule approved by the OWNER: only a person who is already an active OWNER of an Entity may add one; a
-- recent step-up is required; the new Entity belongs to the OWNER who created it (and to nobody else until
-- they grant access through the normal membership commands); it gets the standard chart of accounts.
--
-- Step 06 §1 forbids self-granting, and `tg_membership_guard` enforces it: a user session can never insert
-- its own membership. Creating a brand-new Entity is the one case the OWNER approved. The guard therefore
-- accepts an own OWNER membership only when all of these hold: this function marked the Entity as being
-- created in the current transaction, the membership is for the OWNER role, and the Entity has no
-- membership yet. The marker is a transaction-local setting; no table can be written by a user session
-- directly (RLS has no insert policy), so it cannot be used to join an existing Entity.

create or replace function app_private.tg_membership_guard() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
begin
  select id into v_owner from public.roles where role_key = 'owner';

  if tg_op = 'INSERT' then
    if v_uid is not null and new.user_id = v_uid then
      if new.role_id = v_owner
         and nullif(current_setting('app.creating_entity', true), '') = new.entity_id::text
         and not exists (select 1 from public.entity_memberships m where m.entity_id = new.entity_id) then
        return new;
      end if;
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

create function public.create_entity(p_code text, p_entity_type text, p_legal_name text, p_brand_name text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_id uuid;
  v_code text := lower(btrim(coalesce(p_code, '')));
  v_legal text := btrim(coalesce(p_legal_name, ''));
  v_brand text := nullif(btrim(coalesce(p_brand_name, '')), '');
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select id into v_owner from public.roles where role_key = 'owner';
  if not app_authz.is_active_user() or not exists (
      select 1 from public.entity_memberships m
      join public.entities e on e.id = m.entity_id and e.status = 'active'
      where m.user_id = v_uid and m.role_id = v_owner and m.status = 'active' and app_authz.is_owner(m.entity_id)) then
    raise exception 'FORBIDDEN: only an OWNER can add an Entity' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if v_code !~ '^[a-z][a-z0-9_-]{1,30}$' then
    raise exception 'INVALID: the Entity code is 2 to 31 lower-case letters, digits, "-" or "_", starting with a letter'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_entity_type is null or p_entity_type not in ('company', 'personal') then
    raise exception 'INVALID: the Entity type is a business ledger or a household ledger' using errcode = 'invalid_parameter_value';
  end if;
  if length(v_legal) not between 1 and 200 or length(coalesce(v_brand, '')) > 200 then
    raise exception 'INVALID: the legal name must be 1 to 200 characters' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.entities where code = v_code) then
    raise exception 'CONFLICT: an Entity with this code already exists' using errcode = 'unique_violation';
  end if;

  insert into public.entities (entity_type, code, legal_name, brand_name)
  values (p_entity_type, v_code, v_legal, v_brand)
  returning id into v_id;
  insert into public.entity_profiles (entity_id) values (v_id);
  perform app_private.provision_default_coa(v_id);

  perform set_config('app.creating_entity', v_id::text, true);
  insert into public.entity_memberships (entity_id, user_id, role_id, granted_by) values (v_id, v_uid, v_owner, v_uid);
  perform set_config('app.creating_entity', '', true);

  insert into public.audit_events (entity_id, actor_type, actor_id, action, target_table, target_id, after_state)
  values (v_id, 'user', v_uid, 'entities.created', 'entities', v_id,
          jsonb_build_object('code', v_code, 'entity_type', p_entity_type, 'legal_name', v_legal, 'brand_name', v_brand));
  return v_id;
end
$$;

revoke all on function public.create_entity(text, text, text, text) from public;
grant execute on function public.create_entity(text, text, text, text) to authenticated;
