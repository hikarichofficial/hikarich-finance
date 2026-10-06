-- P15 decision 303 (OWNER, 6 October 2026: "laporan kustom ikut rekomendasimu"): the Custom Reports leave out
-- invoices and bills that were cancelled (void). Sales by Customer counts issued invoices only and Expense by
-- Vendor approved bills only, so a cancelled document no longer inflates the totals. Nothing else changes: the
-- same columns, permission checks, date range and grouping.
create or replace function public.run_custom_report(p_entity uuid, p_dataset text, p_start date default null, p_end date default null)
returns table (dimension text, row_count bigint, total_amount text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_permission text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'reports.view') then
    raise exception 'FORBIDDEN: missing reports.view' using errcode = 'insufficient_privilege';
  end if;
  select required_permission into v_permission from public.report_datasets where dataset_key = p_dataset;
  if v_permission is null then
    raise exception 'NOT_FOUND: unknown report dataset %', p_dataset using errcode = 'no_data_found';
  end if;
  if not app_authz.has_permission(p_entity, v_permission) then
    raise exception 'FORBIDDEN: missing %', v_permission using errcode = 'insufficient_privilege';
  end if;

  if p_dataset = 'invoices_by_customer' then
    return query
    select coalesce(c.display_name, 'Unknown'), count(*), coalesce(sum(i.total), 0)::text
    from public.invoices i
    join public.contacts c on c.id = i.customer_id and c.entity_id = i.entity_id
    where i.entity_id = p_entity and i.status = 'issued'
      and (p_start is null or i.issue_date >= p_start) and (p_end is null or i.issue_date <= p_end)
    group by c.display_name order by 3 desc;
  elsif p_dataset = 'bills_by_vendor' then
    return query
    select coalesce(c.display_name, 'Unknown'), count(*), coalesce(sum(b.total), 0)::text
    from public.bills b
    join public.contacts c on c.id = b.vendor_id and c.entity_id = b.entity_id
    where b.entity_id = p_entity and b.status = 'approved'
      and (p_start is null or b.bill_date >= p_start) and (p_end is null or b.bill_date <= p_end)
    group by c.display_name order by 3 desc;
  elsif p_dataset = 'expenses_by_payee' then
    return query
    select coalesce(c.display_name, e.payee_name, 'Unknown'), count(*), coalesce(sum(e.total), 0)::text
    from public.expenses e
    left join public.contacts c on c.id = e.payee_id and c.entity_id = e.entity_id
    where e.entity_id = p_entity and e.status = 'confirmed'
      and (p_start is null or e.expense_date >= p_start) and (p_end is null or e.expense_date <= p_end)
    group by coalesce(c.display_name, e.payee_name, 'Unknown') order by 3 desc;
  end if;
end
$$;
