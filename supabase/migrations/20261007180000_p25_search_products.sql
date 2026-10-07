-- P25: products join Global Search (the SKU generator's requirement: a SKU, a product name, a brand or a
-- type finds the product and opens its detail). `product` is a tenth indexed kind; its permission is
-- `products.view`, the same key the product screens and RLS use (one authorization source, decision 145).
-- Variants are product rows too, so they are indexed like any other product.
--
-- Everything else about Global Search is unchanged: kept current from the outbox (generic trigger),
-- re-derived from the source row, filtered by has_permission before ranking, rebuildable per Entity.

create trigger tg_search_reindex after insert or update on public.products
  for each row execute function app_private.tg_search_reindex('product');

-- Renaming a brand/type/variant (or changing its code) must refresh every product that uses it, otherwise
-- the index would keep finding the old name.
create function app_private.tg_search_reindex_products_of_master() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if tg_table_name = 'product_brands' then
    insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
    select p.entity_id, 'SearchReindexRequested', 'product', p.id, '{}'::jsonb
      from public.products p where p.entity_id = new.entity_id and p.brand_id = new.id;
  else
    insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
    select p.entity_id, 'SearchReindexRequested', 'product', p.id, '{}'::jsonb
      from public.products p where p.entity_id = new.entity_id and p.product_type_id = new.id;
  end if;
  return new;
end
$$;
create trigger tg_search_reindex_products after update of name, code on public.product_brands
  for each row when (old.name is distinct from new.name or old.code is distinct from new.code)
  execute function app_private.tg_search_reindex_products_of_master();
create trigger tg_search_reindex_products after update of name, code on public.product_types
  for each row when (old.name is distinct from new.name or old.code is distinct from new.code)
  execute function app_private.tg_search_reindex_products_of_master();

create or replace function app_private.search_reindex_one(p_type text, p_id uuid) returns void
language plpgsql set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
  v_title text;
  v_subtitle text;
  v_date date;
  v_perm text;
begin
  if p_type = 'contact' then
    select entity_id, display_name, initcap(kind), created_at::date, 'contacts.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.contacts where id = p_id;
  elsif p_type = 'invoice' then
    select i.entity_id, coalesce(i.invoice_number, 'Invoice (draft)'), c.display_name, i.issue_date, 'invoices.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.invoices i join public.contacts c on c.id = i.customer_id where i.id = p_id;
  elsif p_type = 'bill' then
    select b.entity_id, coalesce(b.bill_number, 'Bill (draft)'), c.display_name, b.bill_date, 'bills.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.bills b join public.contacts c on c.id = b.vendor_id where b.id = p_id;
  elsif p_type = 'expense' then
    select x.entity_id, coalesce(x.expense_number, 'Expense (draft)'),
           coalesce(x.payee_name, (select display_name from public.contacts where id = x.payee_id)),
           x.expense_date, 'bills.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.expenses x where x.id = p_id;
  elsif p_type = 'fixed_asset' then
    select a.entity_id, a.name, a.asset_code, a.created_at::date, 'assets.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.fixed_assets a where a.id = p_id;
  elsif p_type = 'loan' then
    select l.entity_id, coalesce(l.loan_number, 'Loan (draft)'), l.counterparty_name, l.agreement_date, 'loans.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.loans l where l.id = p_id;
  elsif p_type = 'other_obligation' then
    select o.entity_id, coalesce(o.obligation_number, 'Obligation (draft)'), o.counterparty_name, o.obligation_date, 'loans.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.other_obligations o where o.id = p_id;
  elsif p_type = 'equity_event' then
    select e.entity_id, coalesce(e.event_number, 'Equity event (draft)'), e.counterparty_name, e.event_date, 'equity.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.equity_events e where e.id = p_id;
  elsif p_type = 'journal_entry' then
    select j.entity_id, coalesce(j.journal_number, 'Journal (draft)'), left(j.description, 200), j.entry_date, 'accounting.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.journal_entries j where j.id = p_id;
  elsif p_type = 'product' then
    -- Searchable by SKU, product name, brand and type (the SKU generator's own columns; a variant row is a
    -- product row too, so its full SKU finds it). The subtitle carries the SKU first so the result reads
    -- "KEA-EA-001-1B · Brand · Type".
    select p.entity_id, p.name,
           concat_ws(' · ', p.sku, b.name, t.name),
           p.created_at::date, 'products.view'
      into v_entity, v_title, v_subtitle, v_date, v_perm
      from public.products p
      left join public.product_brands b on b.id = p.brand_id
      left join public.product_types t on t.id = p.product_type_id
      where p.id = p_id;
  else
    return;
  end if;

  if v_entity is null then
    delete from public.search_index where target_type = p_type and target_id = p_id;
    return;
  end if;

  insert into public.search_index (entity_id, target_type, target_id, title, subtitle, occurred_on, permission_key)
  values (v_entity, p_type, p_id, coalesce(v_title, '(untitled)'), v_subtitle, v_date, v_perm)
  on conflict (entity_id, target_type, target_id)
  do update set title = excluded.title, subtitle = excluded.subtitle, occurred_on = excluded.occurred_on,
                permission_key = excluded.permission_key, updated_at = now();
end
$$;

create or replace function public.refresh_search_index_batch(p_limit integer default 200)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_event record;
  v_count integer := 0;
begin
  if auth.role() = 'service_role' then
    perform set_config('app.actor_type', 'system', true);
  elsif auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  elsif not app_authz.has_any_permission('system.import') then
    raise exception 'FORBIDDEN: refreshing the search index needs system.import' using errcode = 'insufficient_privilege';
  end if;
  if p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'INVALID: limit must be between 1 and 1000' using errcode = 'invalid_parameter_value';
  end if;

  for v_event in
    select * from public.outbox_events
    where status = 'pending' and event_type = 'SearchReindexRequested'
      and aggregate_type in ('contact', 'invoice', 'bill', 'expense', 'fixed_asset', 'loan',
                              'other_obligation', 'equity_event', 'journal_entry', 'product')
    order by created_at
    limit p_limit
    for update skip locked
  loop
    begin
      update public.outbox_events set status = 'processing' where id = v_event.id;
      perform app_private.search_reindex_one(v_event.aggregate_type, v_event.aggregate_id);
      update public.outbox_events set status = 'processed', processed_at = now() where id = v_event.id;
      v_count := v_count + 1;
    exception when others then
      update public.outbox_events
        set status = 'failed', attempts = attempts + 1, last_error = sqlerrm, next_attempt_at = now() + interval '5 minutes'
        where id = v_event.id;
    end;
  end loop;

  return v_count;
end
$$;

create or replace function public.rebuild_search_index(p_entity uuid) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_count integer := 0;
  r record;
begin
  if auth.role() = 'service_role' then
    perform set_config('app.actor_type', 'system', true);
  elsif auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  elsif not app_authz.has_permission(p_entity, 'system.import') then
    raise exception 'FORBIDDEN: rebuilding the search index needs system.import' using errcode = 'insufficient_privilege';
  end if;

  delete from public.search_index where entity_id = p_entity;

  for r in select id from public.contacts where entity_id = p_entity loop
    perform app_private.search_reindex_one('contact', r.id); v_count := v_count + 1;
  end loop;
  for r in select id from public.invoices where entity_id = p_entity loop
    perform app_private.search_reindex_one('invoice', r.id); v_count := v_count + 1;
  end loop;
  for r in select id from public.bills where entity_id = p_entity loop
    perform app_private.search_reindex_one('bill', r.id); v_count := v_count + 1;
  end loop;
  for r in select id from public.expenses where entity_id = p_entity loop
    perform app_private.search_reindex_one('expense', r.id); v_count := v_count + 1;
  end loop;
  for r in select id from public.fixed_assets where entity_id = p_entity loop
    perform app_private.search_reindex_one('fixed_asset', r.id); v_count := v_count + 1;
  end loop;
  for r in select id from public.loans where entity_id = p_entity loop
    perform app_private.search_reindex_one('loan', r.id); v_count := v_count + 1;
  end loop;
  for r in select id from public.other_obligations where entity_id = p_entity loop
    perform app_private.search_reindex_one('other_obligation', r.id); v_count := v_count + 1;
  end loop;
  for r in select id from public.equity_events where entity_id = p_entity loop
    perform app_private.search_reindex_one('equity_event', r.id); v_count := v_count + 1;
  end loop;
  for r in select id from public.journal_entries where entity_id = p_entity loop
    perform app_private.search_reindex_one('journal_entry', r.id); v_count := v_count + 1;
  end loop;

  for r in select id from public.products where entity_id = p_entity loop
    perform app_private.search_reindex_one('product', r.id); v_count := v_count + 1;
  end loop;

  return v_count;
end
$$;

-- Existing products (every Entity): queue them so the next index refresh picks them up.
insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
select p.entity_id, 'SearchReindexRequested', 'product', p.id, '{}'::jsonb from public.products p;
