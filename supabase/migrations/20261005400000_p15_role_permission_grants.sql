-- P15: OWNER-decided role template grant (4 October 2026), closing one of the two open permission gaps
-- recorded in docs/DECISIONS.md decision 168 and the "Open items for later phases" bullet that tracked it.
--
-- OWNER decided: `approver` and `tax` should see real vendor/customer names (Contacts), not the generic
-- "Vendor" fallback a caller without `contacts.view` gets on a bill (decision 168).
--
-- The companion decision 171 ("finance_staff/approver should see journal numbers on Cash/Bank Activity") is
-- deliberately NOT included here: `accounting.view` is not a narrow "see the journal number" permission --
-- it also gates the full Journal List/Detail, Trial Balance, Opening Balances, and the Asset/Financing/
-- Payroll/Tax Control reports (confirmed against every `accounting.view` guard in `supabase/migrations/`,
-- and against `supabase/tests/90_p3_posting.sql`'s own "staff cannot read the trial balance" pgTAP case,
-- which this migration would otherwise break). That is a materially bigger grant than what was asked;
-- going back to the OWNER to confirm the real scope before touching it.
--
-- Reference data only, same shape as the original templates in `20260920100100_p2_permission_catalog.sql`:
-- an insert of new (role_id, permission_key) rows, never editing a prior migration. `on conflict do nothing`
-- makes this safe to apply even if a role already somehow holds the key (e.g. via a later manual grant).

alter table public.role_permissions disable trigger tg_audit;

insert into public.role_permissions (role_id, permission_key)
select r.id, k
from public.roles r
join (values
  ('approver', array['contacts.view']),
  ('tax', array['contacts.view'])
) as t(role_key, keys) on t.role_key = r.role_key
cross join lateral unnest(t.keys) as k
on conflict (role_id, permission_key) do nothing;

alter table public.role_permissions enable trigger tg_audit;
