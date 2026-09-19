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

-- 3. Browser-facing roles hold no direct write privilege on any `public` table
--    unless a migration explicitly documents it (Step 13 (command boundary): financial commands
--    are never direct browser writes). Vacuously true in P0.
do $$
declare
  offenders text;
begin
  select string_agg(format('%s on %s', privilege_type, table_name), ', ')
    into offenders
  from information_schema.role_table_grants
  where table_schema = 'public'
    and grantee in ('anon', 'authenticated')
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
  if offenders is not null then
    raise exception 'INVARIANT FAILED: browser roles have write grants: %', offenders;
  end if;
end
$$;
