-- P18 (decision 314): every internal function pins its search_path.
--   The Supabase security advisor ("Function Search Path Mutable") listed 299 functions in the internal schemas
--   `app_private` and `app_authz` whose search_path is left to the caller. They are not callable from the browser
--   (the schemas are closed to `anon` and `authenticated`), so the risk was low; this closes the finding anyway by
--   giving each one the same pinned path the rest of the codebase already uses: pg_catalog, public.
--   Only the setting changes. No body, signature, grant, owner or security mode is touched, and a function that
--   already pins a path (or belongs to an extension) is left alone, so running it twice changes nothing.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app_private', 'app_authz')
      and p.prokind in ('f', 'p')
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) as c where c like 'search_path=%')
      and not exists (select 1 from pg_depend d
                      where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter routine %s set search_path = pg_catalog, public', r.signature);
  end loop;
end
$$;
