-- P10 (Step 15 §14): permission catalog additions for Planning & Recurring Automation.
-- Authority: Step 06 (permission model), Step 01 #22/#23/#26.
--
-- Engineering decision (docs/DECISIONS.md): Step 06's Permission/RLS Matrix does not name Planning
-- capabilities verbatim (same gap as other phases, see DECISIONS #5). New keys follow the
-- established `<module>.<action>` convention. `planning.recurring_run` is the capability the
-- generation engine (P10 §2) checks; it is granted to finance_admin for a manual "generate now"
-- action, and separately enforced structurally for the scheduled path (service_role only, P10 §2).

alter table public.roles disable trigger tg_audit;
alter table public.role_permissions disable trigger tg_audit;

insert into public.permissions (key, module, action, description)
select v.module || '.' || v.action, v.module, v.action, v.description
from (values
  ('planning', 'view', 'View budgets, revenue targets, forecasts and recurring rules'),
  ('planning', 'budget_edit', 'Create and edit budgets and revenue targets'),
  ('planning', 'recurring_edit', 'Create, edit, pause, resume and end recurring rules'),
  ('planning', 'recurring_run', 'Manually generate due recurring occurrences')
) as v(module, action, description);

insert into public.role_permissions (role_id, permission_key)
select r.id, k
from public.roles r
join (values
  ('finance_admin', array['planning.view', 'planning.budget_edit', 'planning.recurring_edit', 'planning.recurring_run']),
  ('finance_staff', array['planning.view']),
  ('accountant', array['planning.view', 'planning.budget_edit']),
  ('viewer_auditor', array['planning.view'])
) as t(role_key, keys) on t.role_key = r.role_key
cross join lateral unnest(t.keys) as k;

alter table public.roles enable trigger tg_audit;
alter table public.role_permissions enable trigger tg_audit;
