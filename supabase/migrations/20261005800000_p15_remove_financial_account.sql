-- P15: "Hapus Rekening" for an account that already has transactions (OWNER request, 5 October 2026: an account
-- must be deletable whether or not it has transactions, behind a double confirmation).
-- Step 03 §1 keeps posted history intact, so an account with history is never physically erased: it is archived.
-- An archived account disappears from every list and picker (`money_control` skips it), keeps its own ledger
-- account, journal lines and money movements exactly as they were (reports and period close still add up) and
-- its name is given a "(dihapus ...)" suffix so the same name can be used again for a new account.
-- An account with no history at all is still erased for real by `delete_financial_account`.
alter table public.financial_accounts add column deleted_at timestamptz;

-- The same list as before, without archived accounts. Period close keeps reading `money_control_rows`, which
-- still includes them, so a balance left on an archived account can never slip out of the reconciliation.
create or replace function public.money_control(p_entity uuid, p_as_of date default null)
returns table (
  financial_account_id uuid, name text, kind text, currency text, is_active boolean,
  movement_balance text, movement_base_balance text, ledger_balance text, difference text,
  is_negative boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'money.view') then
    raise exception 'FORBIDDEN: missing money.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select r.financial_account_id, r.name, r.kind, r.currency, r.is_active,
         r.movement_balance::text, r.movement_base_balance::text, r.ledger_balance::text,
         (r.ledger_balance - r.movement_base_balance)::text,
         r.movement_balance < 0
  from app_private.money_control_rows(p_entity, p_as_of) r
  join public.financial_accounts fa on fa.id = r.financial_account_id
  where fa.deleted_at is null
  order by r.name;
end
$$;

-- One call for the screen: erases an account with no history, archives one that has history. Returns
-- 'deleted' or 'archived'.
create function public.remove_financial_account(p_account uuid, p_reason text default null)
returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_fa public.financial_accounts%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_fa from public.financial_accounts where id = p_account;
  if not found or v_fa.deleted_at is not null or not app_authz.has_permission(v_fa.entity_id, 'money.edit') then
    raise exception 'FORBIDDEN: missing money.edit' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.has_permission(v_fa.entity_id, 'coa.manage') then
    raise exception 'FORBIDDEN: deleting an account needs coa.manage' using errcode = 'insufficient_privilege';
  end if;
  select * into v_fa from public.financial_accounts where id = p_account for update;

  if not exists (select 1 from public.money_movements where financial_account_id = p_account)
     and not exists (select 1 from public.journal_lines
                     where entity_id = v_fa.entity_id and ledger_account_id = v_fa.ledger_account_id) then
    begin
      perform public.delete_financial_account(p_account, v_reason);
      return 'deleted';
    exception when integrity_constraint_violation then
      null; -- another record still points at it: archive it instead
    end;
  end if;

  perform set_config('app.audit_reason', coalesce(v_reason, 'Financial account removed from the list'), true);
  update public.financial_accounts
  set is_active = false,
      deleted_at = now(),
      name = left(v_fa.name, 150) || ' (dihapus ' || to_char(now() at time zone 'Asia/Jakarta', 'YYYY-MM-DD') || ' ' || left(v_fa.id::text, 4) || ')'
  where id = p_account;
  return 'archived';
end
$$;

revoke all on function public.remove_financial_account(uuid, text) from public, anon;
grant execute on function public.remove_financial_account(uuid, text) to authenticated;
