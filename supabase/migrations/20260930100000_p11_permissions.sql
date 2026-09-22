-- P11 (Step 15 §15): permission grants for Documents / Imports / Global Search.
-- Authority: Step 06 (permission model), Step 01 #34/#35/#43/#44.
--
-- Engineering decision (docs/DECISIONS.md #146): `system.import`, `system.rollback_import` and
-- `documents.export` were already catalogued in P2 (Step 06 lists them as System-specific
-- capabilities) but never granted to any role template. This migration grants them; it adds no new
-- permission keys, so no schema change is needed. No `search` permission key exists: a search hit is
-- authorized by the same view-permission key as opening the record directly (decision 145).

alter table public.role_permissions disable trigger tg_audit;

insert into public.role_permissions (role_id, permission_key)
select r.id, k
from public.roles r
join (values
  ('finance_admin', array['system.import', 'system.rollback_import', 'documents.export'])
) as t(role_key, keys) on t.role_key = r.role_key
cross join lateral unnest(t.keys) as k;

alter table public.role_permissions enable trigger tg_audit;
