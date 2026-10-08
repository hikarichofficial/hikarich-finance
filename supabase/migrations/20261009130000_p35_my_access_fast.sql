-- P35 (decision 348, owner approval of 8 October 2026): public.my_access() answers faster.
-- It runs once for every page request. To list a membership's permissions it asked
-- app_authz.has_permission(entity, key) once for each of the ~107 permissions, and every one of those calls
-- looked the membership up again (measured: about 138 ms per call of my_access).
-- Now the list is computed in one pass with the SAME rule, written inline:
--   owner            -> every permission;
--   any other role   -> (granted by the role OR granted by a membership override) AND NOT denied by an override.
-- The membership, its active status, the active Entity, the active profile and the MFA condition are the ones
-- my_access already selected / tested for that row, so nothing else changes: same fields, same order, same
-- refusals. app_authz.has_permission itself is NOT touched (it still guards every row-level-security policy).
-- Built from the live definition by exact text replacement; the migration fails if the old text is not found.
-- supabase/tests/99_p35_my_access_fast.sql compares the new answer with has_permission for every role, with
-- grant and deny overrides, without MFA, and for a disabled membership.

do $mig$
declare
  v_def text;
  v_old constant text := $o$where app_authz.has_permission(e.id, x.key)), '[]'::jsonb)$o$;
  v_new constant text := $n$where r.role_key = 'owner'
                         or ((exists (select 1 from public.role_permissions rp
                                      where rp.role_id = m.role_id and rp.permission_key = x.key)
                              or exists (select 1 from public.membership_permission_overrides o
                                         where o.membership_id = m.id and o.permission_key = x.key and o.effect = 'grant'))
                             and not exists (select 1 from public.membership_permission_overrides o
                                             where o.membership_id = m.id and o.permission_key = x.key and o.effect = 'deny'))),
                      '[]'::jsonb)$n$;
begin
  v_def := pg_catalog.pg_get_functiondef('public.my_access()'::regprocedure);
  if position(v_old in v_def) = 0 then
    raise exception 'p35 patch: the permission list of my_access was not found';
  end if;
  v_def := replace(v_def, v_old, v_new);
  if position('app_authz.has_permission' in v_def) > 0 then
    raise exception 'p35 patch: has_permission is still called by my_access';
  end if;
  execute v_def;
end
$mig$;
