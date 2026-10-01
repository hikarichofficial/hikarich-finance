-- P14 decision 252: the last three Step 09 screens that had no backend.
--   1. Documents Archive (Step 09 §20 "Archive is accessible but visually separated from active
--      evidence"): documents replaced by a newer version (`supersedes_document_id`) and documents whose
--      every link was removed. Visible with documents.view, and -- like list_documents -- a document is
--      shown only through a former target the caller may view.
--   2. Sales/Purchase report (Step 09 §19 "Reports home groups reports by ... Sales/Purchase"): issued
--      invoices (sales) or approved bills plus confirmed expenses (purchases) in a date range, grouped by
--      party, category, product (sales only) or month, in base currency, before tax and with tax.
--   3. Saved Reports (Step 09 §19 "Saved Reports preserve filters/layout"): a person's own named shortcuts
--      to a report view (the report path and its filter query), per Entity, under reports.view.

-- ------------------------------------------------------------ 1. documents archive
create function public.list_document_archive(
  p_entity uuid, p_q text default null, p_limit int default 50, p_offset int default 0)
returns table (
  document_id uuid, file_name text, mime_type text, size_bytes bigint, created_at timestamptz,
  archive_reason text, superseded_by uuid, superseded_by_name text, archived_at timestamptz,
  removed_reason text, former_target_types text[])
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'documents.view') then
    raise exception 'FORBIDDEN: missing documents.view' using errcode = 'insufficient_privilege';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'INVALID: limit must be between 1 and 200' using errcode = 'invalid_parameter_value';
  end if;
  return query
  with arch as (
    select d.*,
           (select n.id from public.documents n
             where n.entity_id = d.entity_id and n.supersedes_document_id = d.id
             order by n.created_at desc limit 1) as newer_id,
           exists (select 1 from public.document_links l where l.document_id = d.id) as ever_linked,
           exists (select 1 from public.document_links l where l.document_id = d.id and l.status = 'active') as has_active
    from public.documents d
    where d.entity_id = p_entity
      and (p_q is null or d.file_name ilike '%' || p_q || '%')
  )
  select a.id, a.file_name, a.mime_type, a.size_bytes, a.created_at,
         case when a.newer_id is not null then 'superseded' else 'unlinked' end,
         a.newer_id,
         (select n.file_name from public.documents n where n.id = a.newer_id),
         coalesce((select max(l.removed_at) from public.document_links l where l.document_id = a.id),
                  (select n.created_at from public.documents n where n.id = a.newer_id)),
         (select l.removed_reason from public.document_links l
           where l.document_id = a.id and l.status = 'removed' order by l.removed_at desc limit 1),
         coalesce((select array_agg(distinct l.target_type) from public.document_links l where l.document_id = a.id), '{}')
  from arch a
  where (a.newer_id is not null or (a.ever_linked and not a.has_active))
    -- visible through a former (or current) target the caller can view, or, when it was never linked, with
    -- documents.view alone (a superseded upload that was never attached)
    and (not a.ever_linked or exists (
          select 1 from public.document_links x
          join app_private.document_target_kinds k on k.target_type = x.target_type
          where x.document_id = a.id and app_authz.has_permission(p_entity, k.view_permission)))
  order by 9 desc nulls last, a.created_at desc
  limit p_limit offset greatest(coalesce(p_offset, 0), 0);
end
$$;

-- ------------------------------------------------------------ 2. sales / purchase report
create function public.sales_purchase_report(
  p_entity uuid, p_side text, p_dimension text, p_start date, p_end date)
returns table (
  dimension_id uuid, dimension_label text, period_month date, document_count bigint,
  net_amount text, gross_amount text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_base public.currency_code;
  v_scale integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_side not in ('sales', 'purchases') then
    raise exception 'INVALID: side is sales or purchases' using errcode = 'invalid_parameter_value';
  end if;
  if p_dimension not in ('party', 'category', 'product', 'month')
     or (p_side = 'purchases' and p_dimension = 'product') then
    raise exception 'INVALID: unsupported dimension for this side' using errcode = 'invalid_parameter_value';
  end if;
  if p_start is null or p_end is null or p_end < p_start or p_end - p_start > 3660 then
    raise exception 'INVALID: a date range of at most 10 years is required' using errcode = 'invalid_parameter_value';
  end if;
  if not app_authz.has_permission(p_entity, 'reports.view')
     or not app_authz.has_permission(p_entity, case p_side when 'sales' then 'invoices.view' else 'bills.view' end) then
    raise exception 'FORBIDDEN: missing reports.view or the source permission' using errcode = 'insufficient_privilege';
  end if;
  v_base := app_private.entity_base_currency(p_entity);
  v_scale := app_private.currency_scale(v_base);

  return query
  with src as (
    select i.id as doc_id, i.customer_id as party_id, il.category_id, il.product_id,
           date_trunc('month', i.issue_date)::date as pm,
           case when i.currency = v_base then il.line_subtotal - il.discount_amount
                else app_private.round_amount((il.line_subtotal - il.discount_amount) * i.exchange_rate, v_scale, 'half_up') end as net,
           case when i.currency = v_base then il.line_total
                else app_private.round_amount(il.line_total * i.exchange_rate, v_scale, 'half_up') end as gross
    from public.invoice_lines il join public.invoices i on i.id = il.invoice_id and i.entity_id = il.entity_id
    where p_side = 'sales' and il.entity_id = p_entity and i.status = 'issued'
      and i.issue_date between p_start and p_end
    union all
    select b.id, b.vendor_id, bl.category_id, null::uuid, date_trunc('month', b.bill_date)::date,
           case when b.currency = v_base then bl.line_subtotal
                else app_private.round_amount(bl.line_subtotal * b.exchange_rate, v_scale, 'half_up') end,
           case when b.currency = v_base then bl.line_total
                else app_private.round_amount(bl.line_total * b.exchange_rate, v_scale, 'half_up') end
    from public.bill_lines bl join public.bills b on b.id = bl.bill_id and b.entity_id = bl.entity_id
    where p_side = 'purchases' and bl.entity_id = p_entity and b.status = 'approved'
      and b.bill_date between p_start and p_end
    union all
    select e.id, e.payee_id, el.category_id, null::uuid, date_trunc('month', e.expense_date)::date,
           case when e.currency = v_base then el.line_subtotal
                else app_private.round_amount(el.line_subtotal * e.exchange_rate, v_scale, 'half_up') end,
           case when e.currency = v_base then el.line_total
                else app_private.round_amount(el.line_total * e.exchange_rate, v_scale, 'half_up') end
    from public.expense_lines el join public.expenses e on e.id = el.expense_id and e.entity_id = el.entity_id
    where p_side = 'purchases' and el.entity_id = p_entity and e.status = 'confirmed'
      and e.expense_date between p_start and p_end
  ),
  keyed as (
    select case p_dimension when 'party' then s.party_id when 'category' then s.category_id
                            when 'product' then s.product_id else null end as k,
           case when p_dimension = 'month' then s.pm else null end as m,
           s.doc_id, s.net, s.gross
    from src s
  )
  select g.k,
         case p_dimension
           when 'party' then coalesce((select c.display_name from public.contacts c where c.id = g.k), 'Tanpa kontak')
           when 'category' then coalesce((select c.name from public.categories c where c.id = g.k), 'Tanpa kategori')
           when 'product' then coalesce((select p.name from public.products p where p.id = g.k), 'Tanpa produk')
           else to_char(g.m, 'YYYY-MM') end,
         g.m, g.n, g.net::text, g.gross::text
  from (select k, m, count(distinct doc_id) as n, sum(net) as net, sum(gross) as gross
        from keyed group by k, m) g
  order by case when p_dimension = 'month' then null else g.gross end desc nulls last, g.m;
end
$$;

-- ------------------------------------------------------------ hardening
-- `restore_jobs` (decision 247) enabled RLS but skipped `secure_table`, so on a hosted project the
-- platform's default table grants could still reach it (RLS would refuse every write, but the house rule
-- is "revoke everything, then expose select only"). Apply the rule.
call app_private.secure_table('public.restore_jobs');
call app_private.expose_select('public.restore_jobs');

-- ------------------------------------------------------------ 3. saved reports
create table public.saved_reports (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  user_id uuid not null references public.profiles (id) on delete restrict,
  name text not null check (length(btrim(name)) between 2 and 120),
  -- Where the report lives and its filters, e.g. '/reports' + 'statement=profit_and_loss&start=...'.
  report_path text not null check (report_path ~ '^/(reports|tax/ledger)(/[a-z0-9-]+)*$'),
  report_query text not null default '' check (length(report_query) <= 1000 and report_query !~ '[[:cntrl:]]'),
  created_at timestamptz not null default now(),
  unique (entity_id, user_id, name)
);
create index saved_reports_owner_idx on public.saved_reports (entity_id, user_id, created_at desc);
call app_private.secure_table('public.saved_reports');
call app_private.expose_select('public.saved_reports');
create policy saved_reports_select on public.saved_reports for select to authenticated
  using (user_id = auth.uid() and app_authz.has_permission(entity_id, 'reports.view'));

create function public.save_report(p_entity uuid, p_name text, p_path text, p_query text default '')
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'reports.view') then
    raise exception 'FORBIDDEN: missing reports.view' using errcode = 'insufficient_privilege';
  end if;
  if (select count(*) from public.saved_reports where entity_id = p_entity and user_id = auth.uid()) >= 100 then
    raise exception 'INVALID: at most 100 saved reports per person' using errcode = 'invalid_parameter_value';
  end if;
  begin
    insert into public.saved_reports (entity_id, user_id, name, report_path, report_query)
    values (p_entity, auth.uid(), btrim(coalesce(p_name, '')), coalesce(p_path, ''), coalesce(p_query, ''))
    returning id into v_id;
  exception
    when unique_violation then
      raise exception 'CONFLICT: a saved report with this name already exists' using errcode = 'unique_violation';
    when check_violation then
      raise exception 'INVALID: a name of 2 to 120 characters and a report page are required'
        using errcode = 'invalid_parameter_value';
  end;
  return v_id;
end
$$;

create function public.delete_saved_report(p_id uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  delete from public.saved_reports where id = p_id and user_id = auth.uid();
  if not found then
    raise exception 'FORBIDDEN: not your saved report' using errcode = 'insufficient_privilege';
  end if;
end
$$;

revoke all on function public.list_document_archive(uuid, text, int, int), public.sales_purchase_report(uuid, text, text, date, date),
  public.save_report(uuid, text, text, text), public.delete_saved_report(uuid) from public;
grant execute on function public.list_document_archive(uuid, text, int, int) to authenticated;
grant execute on function public.sales_purchase_report(uuid, text, text, date, date) to authenticated;
grant execute on function public.save_report(uuid, text, text, text) to authenticated;
grant execute on function public.delete_saved_report(uuid) to authenticated;
