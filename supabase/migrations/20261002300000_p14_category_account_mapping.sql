-- P14 decision 265: choosing the ledger account a category posts to (Step 03 §6).
--
-- `category_account_mappings` (P1) is effective-dated and has been read by invoices, bills and expenses
-- since P5/P6, but no command wrote it, so every category posted to the Entity's default revenue or
-- expense account. This adds the one command. A mapping is never rewritten for the past: the mapping in
-- force is ended the day before the new one starts, so documents already posted keep their account.
--   * a revenue category maps the account that is CREDITED in the "sales" context;
--   * an expense category maps the account that is DEBITED in the "purchases" context.
-- Passing no account ends the mapping (the category falls back to the Entity default again).

create function public.set_category_account(
  p_entity uuid, p_category uuid, p_account uuid, p_effective_from date)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  c public.categories%rowtype;
  v_context text;
  v_live public.category_account_mappings%rowtype;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not (app_authz.has_permission(p_entity, 'categories.manage') and app_authz.has_permission(p_entity, 'coa.manage')) then
    raise exception 'FORBIDDEN: mapping a category to an account needs categories.manage and coa.manage'
      using errcode = 'insufficient_privilege';
  end if;
  select * into c from public.categories where id = p_category and entity_id = p_entity;
  if not found then
    raise exception 'INVALID: unknown category of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  if c.kind not in ('revenue', 'expense') then
    raise exception 'INVALID: only revenue and expense categories are mapped to an account here'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_effective_from is null then
    raise exception 'INVALID: the date the mapping starts is required' using errcode = 'invalid_parameter_value';
  end if;
  v_context := case c.kind when 'revenue' then 'sales' else 'purchases' end;
  if p_account is not null then
    if c.kind = 'revenue' and not exists (
         select 1 from public.ledger_accounts a
         where a.id = p_account and a.entity_id = p_entity and a.status = 'active' and not a.is_group
           and a.account_class in ('revenue', 'other_income')) then
      raise exception 'INVALID: a revenue category maps to an active, non-group revenue account'
        using errcode = 'invalid_parameter_value';
    end if;
    if c.kind = 'expense' and not app_private.purchase_account_ok(p_entity, p_account, 'expense') then
      raise exception 'INVALID: an expense category maps to an active, non-group expense account'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('category_map:' || p_category::text || ':' || v_context, 0));
  if exists (select 1 from public.category_account_mappings m
             where m.entity_id = p_entity and m.category_id = p_category and m.context = v_context
               and m.effective_from > p_effective_from) then
    raise exception 'CONFLICT: a later mapping already exists; choose a date after it'
      using errcode = 'integrity_constraint_violation';
  end if;
  select * into v_live from public.category_account_mappings m
  where m.entity_id = p_entity and m.category_id = p_category and m.context = v_context
    and m.effective_from <= p_effective_from and (m.effective_to is null or m.effective_to >= p_effective_from)
  for update;
  if v_live.id is not null then
    if v_live.effective_from = p_effective_from then
      if p_account is null then
        raise exception 'CONFLICT: the mapping starts on this date; choose a later date to end it'
          using errcode = 'integrity_constraint_violation';
      end if;
      update public.category_account_mappings
      set debit_ledger_account_id = case when c.kind = 'expense' then p_account end,
          credit_ledger_account_id = case when c.kind = 'revenue' then p_account end
      where id = v_live.id;
      return v_live.id;
    end if;
    update public.category_account_mappings set effective_to = p_effective_from - 1 where id = v_live.id;
  end if;
  if p_account is null then
    return v_live.id;
  end if;
  insert into public.category_account_mappings
    (entity_id, category_id, context, debit_ledger_account_id, credit_ledger_account_id, effective_from)
  values (p_entity, p_category, v_context, case when c.kind = 'expense' then p_account end,
          case when c.kind = 'revenue' then p_account end, p_effective_from)
  returning id into v_id;
  return v_id;
end
$$;

revoke all on function public.set_category_account(uuid, uuid, uuid, date) from public, anon;
grant execute on function public.set_category_account(uuid, uuid, uuid, date) to authenticated;
