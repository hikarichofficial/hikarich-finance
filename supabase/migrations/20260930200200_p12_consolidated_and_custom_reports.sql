-- P12 (Step 15 Phase 12, Step 12 §15, §19, §31): Consolidated Analysis and a minimal Custom Report
-- Builder over curated datasets.
--
-- Consolidated Analysis (Step 12 §15): read-only, cross-Entity, gated by the existing `reports.cross_entity`
-- permission (catalogued in P2 for exactly this), clearly labelled non-statutory, cannot create postings.
--
-- Custom Report Builder (Step 12 §19, decision #5 maps it onto P12): "constrained to safe curated
-- datasets/metrics/dimensions -- not arbitrary SQL". This ships a first, genuinely safe slice: three
-- read-only datasets (invoices by customer, bills by vendor, expenses by payee), each a fixed, reviewed
-- query selected by a PL/pgSQL branch on `p_dataset` -- never dynamic SQL, string concatenation or a
-- client-supplied column/table name. `report_datasets` is the discovery catalog a future picker reads.
-- Broader dataset/dimension/measure coverage, Saved Reports and Export are a later slice, exactly like
-- every phase's screens (decision #35 pattern); recorded, not silently dropped.

create table public.report_datasets (
  dataset_key text primary key check (dataset_key ~ '^[a-z][a-z0-9_]*$'),
  name text not null,
  description text not null,
  dimension_label text not null,
  measure_label text not null,
  required_permission text not null references public.permissions (key)
);
call app_private.secure_table('public.report_datasets');
call app_private.expose_select('public.report_datasets');
create policy report_datasets_select on public.report_datasets for select to authenticated
  using (app_authz.is_active_user());

insert into public.report_datasets (dataset_key, name, description, dimension_label, measure_label, required_permission) values
  ('invoices_by_customer', 'Sales by Customer', 'Issued invoices grouped by customer (Step 12 Table 3).', 'Customer', 'Invoice total', 'invoices.view'),
  ('bills_by_vendor', 'Expense by Vendor', 'Recognized bills grouped by vendor (Step 12 Table 4).', 'Vendor', 'Bill total', 'bills.view'),
  ('expenses_by_payee', 'Direct Expenses by Payee', 'Confirmed direct expenses grouped by payee (Step 12 Table 4).', 'Payee', 'Expense total', 'bills.view');

-- Runs one curated dataset: group -> count -> sum, permission-filtered before aggregation (Step 12 §19).
create function public.run_custom_report(p_entity uuid, p_dataset text, p_start date default null, p_end date default null)
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
    where i.entity_id = p_entity and i.status in ('issued', 'void')
      and (p_start is null or i.issue_date >= p_start) and (p_end is null or i.issue_date <= p_end)
    group by c.display_name order by 3 desc;
  elsif p_dataset = 'bills_by_vendor' then
    return query
    select coalesce(c.display_name, 'Unknown'), count(*), coalesce(sum(b.total), 0)::text
    from public.bills b
    join public.contacts c on c.id = b.vendor_id and c.entity_id = b.entity_id
    where b.entity_id = p_entity and b.status in ('approved', 'void')
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

-- Consolidated cash position across authorized Entities (Step 12 §15, Table 6, Table 10). Read-only; never
-- eliminates or merges PT and Personal books; fails closed on any Entity the caller lacks the capability
-- for rather than silently dropping it (Step 06 §11: aggregates must not leak restricted records, and the
-- inverse here -- an unauthorized Entity never quietly disappears into someone else's total either).
create function public.consolidated_cash_position(p_entities uuid[], p_as_of date default null)
returns table (entity_id uuid, entity_code text, entity_name text, entity_type text, cash_balance text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_as_of date := coalesce(p_as_of, current_date);
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_entities is null or array_length(p_entities, 1) is null then
    raise exception 'INVALID: at least one Entity is required' using errcode = 'invalid_parameter_value';
  end if;
  foreach v_entity in array p_entities loop
    if not app_authz.has_permission(v_entity, 'reports.cross_entity') then
      raise exception 'FORBIDDEN: missing reports.cross_entity for one of the requested Entities'
        using errcode = 'insufficient_privilege';
    end if;
  end loop;

  return query
  select e.id, e.code, e.legal_name, e.entity_type,
         coalesce(sum(l.debit) - sum(l.credit), 0)::text
  from public.entities e
  join public.ledger_accounts grp on grp.entity_id = e.id and grp.code = '1100' and grp.is_group
  join public.ledger_accounts ca on ca.entity_id = e.id and ca.parent_id = grp.id
  left join public.journal_lines l on l.ledger_account_id = ca.id and l.entity_id = ca.entity_id
  left join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
    and j.status = 'posted' and j.entry_date <= v_as_of
  where e.id = any (p_entities)
  group by e.id, e.code, e.legal_name, e.entity_type
  order by e.legal_name;
end
$$;

revoke all on function public.run_custom_report(uuid, text, date, date) from public, anon;
revoke all on function public.consolidated_cash_position(uuid[], date) from public, anon;
grant execute on function public.run_custom_report(uuid, text, date, date) to authenticated;
grant execute on function public.consolidated_cash_position(uuid[], date) to authenticated;
