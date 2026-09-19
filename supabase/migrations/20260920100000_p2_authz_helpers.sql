-- P2 (Step 15 §6): authorization helper layer for RLS and server-side checks.
-- Authority: Step 06 §1, §5, §8, §9, §12 (default deny; Entity + capability; MFA; step-up; immediate
-- effect of disabling), Step 13 §12 (authorization enforcement pattern).
--
-- Design notes
--   * Helpers live in schema `app_authz`, which is NOT exposed through the Data API (only `public` is).
--     The `authenticated` role needs USAGE because RLS policies run with the caller's privileges.
--     `anon` never receives access.
--   * Functions that read membership/role tables are SECURITY DEFINER with a pinned search_path so that
--     policies on those tables cannot recurse; every one of them derives the actor from the verified JWT
--     (`auth.uid()`), never from a caller-supplied argument.
--   * Nothing is cached: every check evaluates the current membership rows, so disabling a user, a
--     membership or a permission takes effect on the very next statement (Step 06 §9).

create schema if not exists app_authz;
revoke all on schema app_authz from public;
grant usage on schema app_authz to authenticated;

-- ------------------------------------------------------------ JWT / assurance-level helpers
create function app_authz.aal2() returns boolean
language sql stable as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
$$;

-- Most recent authentication event recorded in the session's `amr` claim (password, totp, ...).
create function app_authz.last_authenticated_at() returns timestamptz
language sql stable as $$
  select to_timestamp(max((e ->> 'timestamp')::double precision))
  from jsonb_array_elements(
    case when jsonb_typeof(auth.jwt() -> 'amr') = 'array' then auth.jwt() -> 'amr' else '[]'::jsonb end
  ) as e
$$;

-- Step-up: the locked 10-minute recent re-authentication window (Step 06 §8).
create function app_authz.recent_step_up(p_max_age interval default interval '10 minutes') returns boolean
language sql stable as $$
  select coalesce(app_authz.last_authenticated_at() >= now() - p_max_age, false)
$$;

-- ------------------------------------------------------------ user / membership state
create function app_authz.is_active_user() returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_active)
$$;

-- OWNER always needs MFA (Step 01 #38); other roles when the Entity setting `security.require_mfa` is true.
create function app_authz.mfa_required(p_entity uuid, p_role_key text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select p_role_key = 'owner'
    or coalesce((select s.setting_value = 'true'::jsonb
                 from public.entity_settings s
                 where s.entity_id = p_entity and s.setting_key = 'security.require_mfa'), false)
$$;

create function app_authz.mfa_satisfied(p_entity uuid, p_role_key text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select app_authz.aal2() or not app_authz.mfa_required(p_entity, p_role_key)
$$;

-- The caller's usable membership in an Entity: active user + active membership + active Entity +
-- MFA requirement met. Empty when any of those fails (default deny).
create function app_authz.active_membership(p_entity uuid)
returns table (membership_id uuid, role_id uuid, role_key text)
language sql stable security definer set search_path = pg_catalog, public as $$
  select m.id, m.role_id, r.role_key
  from public.entity_memberships m
  join public.profiles p on p.id = m.user_id and p.is_active
  join public.entities e on e.id = m.entity_id and e.status = 'active'
  join public.roles r on r.id = m.role_id
  where m.user_id = auth.uid()
    and m.entity_id = p_entity
    and m.status = 'active'
    and app_authz.mfa_satisfied(m.entity_id, r.role_key)
$$;

create function app_authz.is_member(p_entity uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (select 1 from app_authz.active_membership(p_entity))
$$;

create function app_authz.is_owner(p_entity uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (select 1 from app_authz.active_membership(p_entity) a where a.role_key = 'owner')
$$;

-- Atomic capability check (Step 06 §2, §4): (role permission OR explicit grant) AND NOT explicit deny.
-- OWNER holds every catalogued permission and cannot be denied (hard invariants still apply in the
-- database and are not permissions).
create function app_authz.has_permission(p_entity uuid, p_key text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce((
    select case
      when a.role_key = 'owner' then exists (select 1 from public.permissions x where x.key = p_key)
      else (
        exists (select 1 from public.role_permissions rp
                where rp.role_id = a.role_id and rp.permission_key = p_key)
        or exists (select 1 from public.membership_permission_overrides o
                   where o.membership_id = a.membership_id and o.permission_key = p_key and o.effect = 'grant')
      )
      and not exists (select 1 from public.membership_permission_overrides o
                      where o.membership_id = a.membership_id and o.permission_key = p_key and o.effect = 'deny')
    end
    from app_authz.active_membership(p_entity) a
  ), false)
$$;

-- True when the caller holds the capability in at least one Entity (used for Entity-less reference data).
create function app_authz.has_any_permission(p_key text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (
    select 1 from public.entity_memberships m
    where m.user_id = auth.uid() and m.status = 'active' and app_authz.has_permission(m.entity_id, p_key)
  )
$$;

-- True when the caller holds the capability in some Entity where `p_user` has a membership
-- (active or disabled): lets an administrator see the users they administer, and nobody else's.
create function app_authz.shares_entity_with(p_user uuid, p_key text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select exists (
    select 1 from public.entity_memberships m
    where m.user_id = p_user and app_authz.has_permission(m.entity_id, p_key)
  )
$$;

revoke all on all functions in schema app_authz from public, anon;
grant execute on all functions in schema app_authz to authenticated;

-- Functions created later in `public` must never become callable by browser roles by accident:
-- each RPC is granted explicitly (Step 06 §12, Step 14 (database functions)).
alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

-- ------------------------------------------------------------ created_by is stamped from the JWT
-- A browser client cannot forge who created a row. Non-JWT contexts (migrations, system jobs) keep
-- whatever value they supply.
create function app_private.tg_stamp_created() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null then
    new.created_by := auth.uid();
  end if;
  return new;
end
$$;

do $$
declare
  r record;
begin
  for r in
    select c.oid::regclass as rel
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and exists (select 1 from pg_attribute a
                  where a.attrelid = c.oid and a.attname = 'created_by' and not a.attisdropped)
  loop
    execute format(
      'create trigger tg_stamp_created before insert on %s for each row execute function app_private.tg_stamp_created()',
      r.rel);
  end loop;
end
$$;

-- Future tables created through the standard procedure get the stamp automatically.
create or replace procedure app_private.apply_standard_triggers(rel regclass, scoped_by_entity boolean default true)
language plpgsql as $$
begin
  execute format(
    'create trigger tg_touch before update on %s for each row execute function app_private.tg_touch()', rel);
  if scoped_by_entity then
    execute format(
      'create trigger tg_lock_entity before update on %s for each row execute function app_private.tg_lock_entity()',
      rel);
  end if;
  if exists (select 1 from pg_attribute a
             where a.attrelid = rel and a.attname = 'created_by' and not a.attisdropped) then
    execute format(
      'create trigger tg_stamp_created before insert on %s for each row execute function app_private.tg_stamp_created()',
      rel);
  end if;
end
$$;

revoke all on all functions in schema app_private from public;
revoke all on all procedures in schema app_private from public;
