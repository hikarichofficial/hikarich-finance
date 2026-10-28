-- Decision 426: how much of a month's PPh Final turnover is still unpaid. READ-ONLY: it changes no tax rule, no
-- journal and no stored value. The base of the tax (`entity_gross_turnover`) stays what it was (invoices at their
-- issue date, decision 342 and the P43 module); this function only shows, beside it, the part of the invoices issued
-- in the month that the customers have not paid yet, so the owner can reconcile the tax estimate with the bank.
-- Settlement is derived from `invoice_positions` at read time, exactly as everywhere else.
create function public.tax_turnover_receivables(p_entity uuid, p_period date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_from date := date_trunc('month', p_period::timestamp)::date;
  v_to date := (date_trunc('month', p_period::timestamp) + interval '1 month' - interval '1 day')::date;
  v_cur public.currency_code;
  v_invoiced numeric;
  v_unpaid numeric;
  v_count integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  v_cur := app_private.entity_base_currency(p_entity);

  select coalesce(sum(i.base_total - case when i.currency = v_cur then i.tax_total else 0 end), 0)
    into v_invoiced
  from public.invoices i
  where i.entity_id = p_entity and i.status = 'issued' and i.issue_date between v_from and v_to;

  -- the unpaid share of each invoice's turnover (its value without tax), pro rata to what is still outstanding
  select count(*), coalesce(sum((i.base_total - case when i.currency = v_cur then i.tax_total else 0 end)
                                * p.base_outstanding / nullif(i.base_total, 0)), 0)
    into v_count, v_unpaid
  from app_private.invoice_positions(p_entity) p
  join public.invoices i on i.id = p.invoice_id
  where p.status = 'issued' and p.issue_date between v_from and v_to and p.outstanding > 0;

  return jsonb_build_object(
    'period', v_from,
    'turnover_invoiced', trim_scale(v_invoiced)::text,
    'turnover_unpaid', trim_scale(v_unpaid)::text,
    'unpaid_invoice_count', v_count);
end
$$;

revoke all on function public.tax_turnover_receivables(uuid, date) from public, anon;
grant execute on function public.tax_turnover_receivables(uuid, date) to authenticated;
