-- Database invariants that must hold after EVERY migration (Step 14 §6-7, Step 15 P1 gate).
-- Each block raises an exception on failure; psql runs with ON_ERROR_STOP.

-- 1. The baseline extension exists.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pgcrypto') then
    raise exception 'INVARIANT FAILED: pgcrypto extension missing';
  end if;
end
$$;

-- 2. RLS is enabled on every application table in `public` (Step 14 (Supabase security) / Step 06).
--    Vacuously true in P0 (no tables yet); enforced automatically from P1 on.
do $$
declare
  offenders text;
begin
  select string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    into offenders
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and not c.relrowsecurity;
  if offenders is not null then
    raise exception 'INVARIANT FAILED: RLS disabled on: %', offenders;
  end if;
end
$$;

-- 3. Browser-facing roles hold no direct write privilege on any `public` table unless it is on the
--    reviewed allowlist below (Step 13 (command boundary): financial commands are never direct browser
--    writes). The allowlist is the master-data set of Step 06 §5, whose writes RLS constrains per Entity
--    and capability (P2). `anon` never holds any privilege at all.
do $$
declare
  offenders text;
  allowlist constant text[] := array['categories', 'contacts', 'products', 'product_aliases'];
begin
  select string_agg(format('%s on %s', p.priv, c.relname), ', ')
    into offenders
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  cross join lateral (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) as p(priv)
  where c.relkind in ('r', 'p')
    and c.relname <> all (allowlist)
    and (
      (p.priv in ('INSERT', 'UPDATE') and has_any_column_privilege('authenticated', c.oid, p.priv))
      or (p.priv not in ('INSERT', 'UPDATE') and has_table_privilege('authenticated', c.oid, p.priv))
    );
  if offenders is not null then
    raise exception 'INVARIANT FAILED: browser roles have write grants: %', offenders;
  end if;

  select string_agg(format('%s on %s', p.priv, c.relname), ', ')
    into offenders
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  cross join lateral (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) as p(priv)
  where c.relkind in ('r', 'p', 'v', 'm')
    and (
      (p.priv in ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES') and has_any_column_privilege('anon', c.oid, p.priv))
      or has_table_privilege('anon', c.oid, p.priv)
    );
  if offenders is not null then
    raise exception 'INVARIANT FAILED: anon has table privileges: %', offenders;
  end if;
end
$$;

-- 4. Function exposure (Step 06 §12, Step 14): browser roles execute only the reviewed RPCs; `anon`
--    executes nothing; nothing in the internal schemas is reachable.
do $$
declare
  offenders text;
  rpc_allowlist constant text[] := array['my_access', 'assign_membership', 'set_membership_status',
                                         'set_user_active', 'set_permission_override', 'reveal_sensitive',
                                         -- P3 accounting core
                                         'create_journal_draft', 'discard_journal_draft', 'post_journal',
                                         'reverse_journal', 'trial_balance', 'period_close_checks',
                                         'begin_period_close', 'cancel_period_close', 'close_period',
                                         'reopen_period', 'post_opening_balances', 'complete_opening_balances'];
begin
  select string_agg(format('anon can execute public.%s', p.proname), ', ')
    into offenders
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  where p.prokind = 'f' and has_function_privilege('anon', p.oid, 'EXECUTE')
    and p.oid not in (select d.objid from pg_depend d where d.deptype = 'e');
  if offenders is not null then
    raise exception 'INVARIANT FAILED: %', offenders;
  end if;

  select string_agg(format('authenticated can execute public.%s', p.proname), ', ')
    into offenders
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  where p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and p.proname <> all (rpc_allowlist)
    and p.oid not in (select d.objid from pg_depend d where d.deptype = 'e');
  if offenders is not null then
    raise exception 'INVARIANT FAILED: %', offenders;
  end if;

  select string_agg(format('%s can use schema %s', r.rolname, n.nspname), ', ')
    into offenders
  from pg_roles r
  join pg_namespace n on n.nspname = 'app_private'
  where r.rolname in ('anon', 'authenticated') and has_schema_privilege(r.rolname, n.oid, 'USAGE');
  if offenders is not null then
    raise exception 'INVARIANT FAILED: %', offenders;
  end if;

  if has_schema_privilege('anon', 'app_authz', 'USAGE') then
    raise exception 'INVARIANT FAILED: anon can use schema app_authz';
  end if;
end
$$;
