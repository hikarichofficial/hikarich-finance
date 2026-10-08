-- P36 (decision 349, owner approval of 8 October 2026: "continue, as long as it does not disturb the website"):
-- row-level-security policies ask "may this person see/write rows of this Entity?" once per STATEMENT instead of
-- once per ROW.
-- Before: using (app_authz.has_permission(entity_id, 'contacts.view')) -- the function (a lookup of the
-- membership, role, overrides and MFA) ran for every candidate row (measured about 0,6 ms per row: 10.000
-- journal lines cost about 6 s).
-- Now: using (coalesce(entity_id = any (((select app_authz.permitted_entities('contacts.view')))::uuid[]), false))
-- app_authz.permitted_entities(key) returns the Entities in which the caller holds the permission. It is defined
-- BY has_permission itself (it asks has_permission once for each of the caller's active memberships), so it can
-- only ever say what has_permission says; has_permission is not rewritten. The uncorrelated sub-select is
-- evaluated once per statement by the planner and then matches rows by an array comparison that can also use
-- an index. coalesce(..., false) keeps the old "no Entity (null) means no permission" answer even inside NOT/OR.
-- Only policies of the exact shape has_permission(<column>, '<literal>') are rewritten (by exact text replacement
-- of the live policy text, in the public schema); anything else (a column-valued permission key, the lookups
-- inside EXISTS, has_any_permission, shares_entity_with) is left as it is. Policy names, commands and roles do
-- not change. supabase/tests/99_p36_rls_permitted_entities.sql proves permitted_entities equals has_permission
-- for every role, user, Entity and permission, and checks real rows through the rewritten policies.

create function app_authz.permitted_entities(p_key text) returns uuid[]
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(array_agg(m.entity_id), '{}'::uuid[])
  from public.entity_memberships m
  where m.user_id = auth.uid() and m.status = 'active' and app_authz.has_permission(m.entity_id, p_key)
$$;

revoke all on function app_authz.permitted_entities(text) from public, anon;
grant execute on function app_authz.permitted_entities(text) to authenticated;

do $mig$
declare
  p record;
  v_re constant text := $re$app_authz\.has_permission\(([a-z_]+), '([a-z_.]+)'::text\)$re$;
  v_to constant text := $to$coalesce(\1 = any (((select app_authz.permitted_entities('\2'::text)))::uuid[]), false)$to$;
  v_using text;
  v_check text;
  v_sql text;
  v_n integer := 0;
begin
  for p in
    select schemaname, tablename, policyname, qual, with_check
    from pg_policies
    where schemaname = 'public'
      and (coalesce(qual, '') ~ v_re or coalesce(with_check, '') ~ v_re)
    order by tablename, policyname
  loop
    v_using := case when p.qual is not null then regexp_replace(p.qual, v_re, v_to, 'g') end;
    v_check := case when p.with_check is not null then regexp_replace(p.with_check, v_re, v_to, 'g') end;
    v_sql := format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
    if v_using is not null then v_sql := v_sql || format(' using (%s)', v_using); end if;
    if v_check is not null then v_sql := v_sql || format(' with check (%s)', v_check); end if;
    execute v_sql;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then
    raise exception 'p36 patch: no policy with the expected shape was found';
  end if;
  raise notice 'p36: % policies now ask once per statement', v_n;
end
$mig$;
