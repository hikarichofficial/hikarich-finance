-- P15: OWNER decision (4 October 2026) on decision 55 -- "the OWNER's choice of account kinds that may
-- never go negative" -- a setting `record_movement` has read since P4 (`20260922100000_p4_money_movements.sql`,
-- `entity_settings` key `money.block_negative_balance`, a jsonb array of account kinds: `bank`, `cash` or
-- `ewallet`, `20260919100600_p1_money_links.sql`'s own `financial_accounts.kind` check) but that no RPC has
-- ever written -- setting it has always needed a direct database update, never a Settings screen flow.
--
-- This migration does two things:
--   1. Ships `set_negative_balance_block`, so the OWNER (or anyone granted `system.entity_config`) can
--      change the blocked kinds herself from Settings from now on, with a recent step-up like the other two
--      Settings write RPCs (`update_entity_time_settings`, `update_entity_identity`). No optimistic-lock
--      version is needed here (unlike those two): this key has had no writer at all until now, so there is
--      nothing to race against, and a plain idempotent upsert is simpler and just as safe.
--   2. Seeds the OWNER's own answer (4 October 2026) as the starting value for every Entity that has not
--      already had this key set some other way: block `bank` only. Her reasoning: "that's the one that
--      matters -- every expense reduces the bank balance; if cash goes negative it can be topped up from
--      the bank." This makes her decision take effect immediately, not only once she opens Settings.

create function public.set_negative_balance_block(p_entity uuid, p_kinds text[])
returns text[]
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_kind text;
  v_value jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'system.entity_config') then
    raise exception 'FORBIDDEN: missing system.entity_config' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if p_kinds is null then
    raise exception 'INVALID: give a list of account kinds (an empty list blocks none)'
      using errcode = 'invalid_parameter_value';
  end if;
  foreach v_kind in array p_kinds loop
    if v_kind not in ('bank', 'cash', 'ewallet') then
      raise exception 'INVALID: unknown account kind %', v_kind using errcode = 'invalid_parameter_value';
    end if;
  end loop;
  v_value := coalesce((select to_jsonb(array_agg(distinct k order by k)) from unnest(p_kinds) as k), '[]'::jsonb);

  insert into public.entity_settings (entity_id, setting_key, setting_value, created_by, updated_by)
  values (p_entity, 'money.block_negative_balance', v_value, auth.uid(), auth.uid())
  on conflict (entity_id, setting_key) do update
    set setting_value = excluded.setting_value, updated_at = now(), updated_by = auth.uid(),
        version = public.entity_settings.version + 1;

  insert into public.audit_events (entity_id, actor_type, actor_id, action, target_table, target_id, after_state)
  values (p_entity, 'user', auth.uid(), 'entity_settings.block_negative_balance_changed', 'entity_settings',
          p_entity, jsonb_build_object('kinds', v_value));

  return (select coalesce(array_agg(x order by x), array[]::text[]) from jsonb_array_elements_text(v_value) as x);
end
$$;

revoke all on function public.set_negative_balance_block(uuid, text[]) from public;
grant execute on function public.set_negative_balance_block(uuid, text[]) to authenticated;

-- Seed the OWNER's own answer for every Entity that has no row for this key yet.
insert into public.entity_settings (entity_id, setting_key, setting_value)
select e.id, 'money.block_negative_balance', '["bank"]'::jsonb
from public.entities e
where not exists (
  select 1 from public.entity_settings s
  where s.entity_id = e.id and s.setting_key = 'money.block_negative_balance'
);
