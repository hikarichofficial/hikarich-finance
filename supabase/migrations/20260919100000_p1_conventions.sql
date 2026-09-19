-- P1 (Step 15 §5): database conventions shared by every later migration.
-- Authority: Step 02 §1/§6/§8, Step 08 §3/§5, Step 13 §22/§25/§26.
--
-- Conventions established here
--   * Money is exact `numeric` (never float). Dates are `date`; instants are `timestamptz`.
--   * Every mutable table carries audit metadata (created/updated at+by) and an integer
--     `version` for optimistic concurrency (Step 08 §18).
--   * Entity ownership: every Entity-scoped table has `entity_id`, exposes UNIQUE (entity_id, id)
--     and links to other Entity-scoped tables through COMPOSITE foreign keys
--     (entity_id, x_id). A row can therefore never point at another Entity's record.
--   * `entity_id` can never be changed after insert (Step 08 §4).
--   * Internal functions live in the non-exposed schema `app_private`; browser roles get no
--     access to it. Every table gets RLS enabled and no privileges for browser roles; access
--     policies and privileges arrive with Auth/RLS in P2 (default deny).

create extension if not exists btree_gist with schema extensions;

create schema if not exists app_private;
revoke all on schema app_private from public;

-- ---------------------------------------------------------------- domains
create domain public.currency_code as text
  constraint currency_code_format check (value ~ '^[A-Z]{3}$');

-- Rupiah, other currencies and tax amounts: exact decimal, 4 fractional digits of headroom.
-- Sign is allowed here; columns that must be non-negative add their own CHECK.
create domain public.money_amount as numeric(20, 4)
  constraint money_amount_finite check (
    value is null
    or (value <> 'NaN'::numeric and value <> 'Infinity'::numeric and value <> '-Infinity'::numeric)
  );

create domain public.fx_rate as numeric(20, 10)
  constraint fx_rate_positive check (
    value is null
    or (value > 0 and value <> 'NaN'::numeric and value <> 'Infinity'::numeric)
  );

-- ------------------------------------------------- generic trigger functions
-- Maintains updated_at/updated_by and the optimistic-concurrency version.
create function app_private.tg_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  new.version := old.version + 1;
  return new;
end
$$;

-- Entity ownership never changes (Step 08 §4: no moving records between PT and Personal).
create function app_private.tg_lock_entity() returns trigger
language plpgsql as $$
begin
  if new.entity_id is distinct from old.entity_id then
    raise exception 'entity_id cannot be changed on %.% (Step 08 §4)', tg_table_schema, tg_table_name
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;

create function app_private.tg_forbid_delete() returns trigger
language plpgsql as $$
begin
  raise exception 'DELETE is not allowed on %.%', tg_table_schema, tg_table_name
    using errcode = 'integrity_constraint_violation';
end
$$;

create function app_private.tg_forbid_update() returns trigger
language plpgsql as $$
begin
  raise exception 'UPDATE is not allowed on %.% (append-only)', tg_table_schema, tg_table_name
    using errcode = 'integrity_constraint_violation';
end
$$;

create function app_private.tg_forbid_truncate() returns trigger
language plpgsql as $$
begin
  raise exception 'TRUNCATE is not allowed on %.%', tg_table_schema, tg_table_name
    using errcode = 'integrity_constraint_violation';
end
$$;

-- Parent/child hierarchies (categories, ledger accounts) must stay acyclic (Step 08 §15).
-- Table must have columns (id, parent_id).
create function app_private.tg_no_parent_cycle() returns trigger
language plpgsql as $$
declare
  v_cycle boolean;
begin
  if new.parent_id is null then
    return new;
  end if;
  if new.parent_id = new.id then
    raise exception 'A row cannot be its own parent (%.%)', tg_table_schema, tg_table_name
      using errcode = 'integrity_constraint_violation';
  end if;
  execute format(
    'with recursive anc(id, parent_id) as (
       select t.id, t.parent_id from %1$I.%2$I t where t.id = $1
       union all
       select t.id, t.parent_id from %1$I.%2$I t join anc on t.id = anc.parent_id
     )
     select exists (select 1 from anc where id = $2)',
    tg_table_schema, tg_table_name)
    into v_cycle
    using new.parent_id, new.id;
  if v_cycle then
    raise exception 'Hierarchy cycle detected on %.%', tg_table_schema, tg_table_name
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;

-- Generic audit trail writer (Step 08 §3, Step 13 §19, Step 06 §13).
-- Trigger arguments: [0] column holding the Entity id ('entity_id', or 'id' for entities,
-- or '' for global tables); [1..] column names to redact from before/after snapshots.
-- Context is read from optional settings: app.audit_reason, app.correlation_id,
-- app.actor_type ('user' default | 'system' | 'public_token'), app.actor_id.
create function app_private.tg_audit() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_action text;
  v_entity uuid;
  v_target uuid;
  v_key text;
  v_entity_col text := coalesce(nullif(tg_argv[0], ''), null);
  v_actor_type text := coalesce(nullif(current_setting('app.actor_type', true), ''), 'user');
  v_actor uuid := coalesce(nullif(current_setting('app.actor_id', true), '')::uuid, auth.uid());
  i int;
begin
  if tg_op = 'INSERT' then
    v_action := 'insert';
    v_after := to_jsonb(new);
  elsif tg_op = 'UPDATE' then
    v_action := 'update';
    v_before := to_jsonb(old);
    v_after := to_jsonb(new);
    -- Ignore pure bookkeeping churn.
    if (v_before - 'updated_at' - 'updated_by' - 'version')
       = (v_after - 'updated_at' - 'updated_by' - 'version') then
      return null;
    end if;
  else
    v_action := 'delete';
    v_before := to_jsonb(old);
  end if;

  v_target := nullif(coalesce(v_after ->> 'id', v_before ->> 'id'), '')::uuid;
  if v_entity_col is not null then
    v_entity := nullif(coalesce(v_after ->> v_entity_col, v_before ->> v_entity_col), '')::uuid;
  end if;

  for i in 1 .. coalesce(array_length(tg_argv, 1), 0) - 1 loop
    v_key := tg_argv[i];
    v_before := v_before - v_key;
    v_after := v_after - v_key;
  end loop;

  insert into public.audit_events
    (entity_id, actor_type, actor_id, action, target_table, target_id, before_state, after_state,
     reason, correlation_id)
  values
    (v_entity, v_actor_type, v_actor, tg_table_name || '.' || v_action, tg_table_name, v_target,
     v_before, v_after, nullif(current_setting('app.audit_reason', true), ''),
     nullif(current_setting('app.correlation_id', true), ''));
  return null;
end
$$;

-- Locks a table down for browser roles: RLS on, no privileges (default deny until P2 policies).
create procedure app_private.secure_table(rel regclass)
language plpgsql as $$
begin
  execute format('alter table %s enable row level security', rel);
  execute format('revoke all on table %s from public, anon, authenticated', rel);
end
$$;

-- Standard trigger set for a mutable, Entity-scoped table.
create procedure app_private.apply_standard_triggers(rel regclass, scoped_by_entity boolean default true)
language plpgsql as $$
begin
  execute format(
    'create trigger tg_touch before update on %s for each row execute function app_private.tg_touch()', rel);
  if scoped_by_entity then
    execute format(
      'create trigger tg_lock_entity before update on %s for each row execute function app_private.tg_lock_entity()',
      rel);
  end if;
end
$$;

revoke all on all functions in schema app_private from public;
revoke all on all procedures in schema app_private from public;
