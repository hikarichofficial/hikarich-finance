-- P15: delete a financial account ("Hapus Rekening"), OWNER request of 5 October 2026.
-- A cash/bank/e-wallet account can be deleted only while it has no history at all: no money movement, no
-- journal line on its ledger account and no other record (invoice payment account, transfer, reconciliation,
-- loan, asset...) pointing at it. Every such link is `on delete restrict`, so a leftover reference stops the
-- delete instead of orphaning a record; the function turns that into a plain message. An account that already has
-- history is never erased -- it can only be disabled (`set_financial_account_active`), which keeps the books intact.
-- The ledger account the system created for it is switched to inactive so it no longer shows up in pickers;
-- a default control account that was mapped by hand (it carries a system key) is left untouched.
create function public.delete_financial_account(p_account uuid, p_reason text default null)
returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_fa public.financial_accounts%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_fa from public.financial_accounts where id = p_account;
  if not found or not app_authz.has_permission(v_fa.entity_id, 'money.edit') then
    raise exception 'FORBIDDEN: missing money.edit' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.has_permission(v_fa.entity_id, 'coa.manage') then
    raise exception 'FORBIDDEN: deleting an account needs coa.manage' using errcode = 'insufficient_privilege';
  end if;
  select * into v_fa from public.financial_accounts where id = p_account for update;

  if exists (select 1 from public.money_movements where financial_account_id = p_account)
     or exists (select 1 from public.journal_lines where entity_id = v_fa.entity_id and ledger_account_id = v_fa.ledger_account_id) then
    raise exception 'CONFLICT: this account already has transactions and cannot be deleted; disable it instead'
      using errcode = 'integrity_constraint_violation';
  end if;

  perform set_config('app.audit_reason', coalesce(v_reason, 'Financial account deleted'), true);
  begin
    delete from public.financial_accounts where id = p_account;
  exception when foreign_key_violation then
    raise exception 'CONFLICT: this account is still used by other records (for example a payment channel, invoice or loan); disable it instead'
      using errcode = 'integrity_constraint_violation';
  end;

  update public.ledger_accounts set status = 'inactive'
  where id = v_fa.ledger_account_id and entity_id = v_fa.entity_id and system_key is null and status = 'active';
  return true;
end
$$;

revoke all on function public.delete_financial_account(uuid, text) from public, anon;
grant execute on function public.delete_financial_account(uuid, text) to authenticated;
