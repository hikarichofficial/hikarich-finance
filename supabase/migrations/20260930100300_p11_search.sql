-- P11 part 3 (Step 15 §15, Step 01 #34, Step 13 §17): Global Search.
-- Authority: Step 13 §17 ("Global Search uses a curated search service/index... Every result carries
-- Entity/type/record identity... Sensitive records excluded before delivery, not merely hidden in the
-- UI... Command Menu navigation/action search remains separate from financial content search"),
-- Step 06 §11 ("Global Search returns only records the user could open directly"), Step 08 §22 ("search
-- indexes are derived/rebuildable, never authoritative").
--
-- Design (docs/DECISIONS.md 145):
--   * `search_index` covers exactly the nine business-record kinds decision 141 already catalogued in
--     `app_private.document_target_kinds` with `generic_linker = true` MINUS `import_batch` (a technical
--     artifact, not content a user searches for): contact, invoice, bill, expense, fixed_asset, loan,
--     other_obligation, equity_event, journal_entry. `permission_key` on every row is the SAME
--     `view_permission` already recorded for that kind, so search and document-linking share one
--     authorization source. Payroll is never indexed (decision 131) and neither is tax (decision 145) --
--     both are reached through their own permission-gated screens.
--   * Kept current from the outbox: a small generic trigger on each of the nine source tables queues a
--     `SearchReindexRequested` event on every insert/update, so freshness never depends on every existing
--     command function remembering to emit one. `refresh_search_index_batch` is the consumer -- it claims
--     pending events (for update skip locked, mirroring P10's due-occurrence pattern) and re-derives each
--     row's title/subtitle/date from the source table itself, never trusting the event payload.
--   * `search()` filters by `app_authz.has_permission(entity, row.permission_key)` before ranking, so an
--     inaccessible record is excluded before delivery, not merely hidden in the UI (Step 06 §11).
--   * `rebuild_search_index(entity)` is the full, derived-and-rebuildable recovery path (Step 08 §22):
--     wipes and repopulates one Entity's rows straight from the nine source tables.

create table public.search_index (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  target_type text not null,
  target_id uuid not null,
  title text not null check (length(btrim(title)) > 0),
  subtitle text,
  occurred_on date,
  -- The same permission key document_target_kinds records for this kind (decision 145: one authorization
  -- source for both document-linking and search).
  permission_key text not null references public.permissions (key),
  tsv tsvector generated always as (
    setweight(to_tsvector('simple', coalesce(title, '')), 'A')
    || setweight(to_tsvector('simple', coalesce(subtitle, '')), 'B')
  ) stored,
  updated_at timestamptz not null default now(),
  unique (entity_id, id),
  unique (entity_id, target_type, target_id)
);
create index search_index_tsv_idx on public.search_index using gin (tsv);
create index search_index_entity_permission_idx on public.search_index (entity_id, permission_key);

create trigger tg_lock_entity before update on public.search_index
  for each row execute function app_private.tg_lock_entity();
create trigger tg_forbid_truncate before truncate on public.search_index
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.search_index');
-- Derived data (Step 08 §22): never audited like a business record, just rebuilt when wrong.

-- ------------------------------------------------------------ keeping the index current
-- One generic trigger, attached to each of the nine searchable tables, queues a reindex request on
-- every insert/update. This is deliberately table-driven rather than relying on each command function's
-- own domain event (those are inconsistent for this purpose: several fire only on specific transitions,
-- e.g. issue/approve, not on draft creation or a later edit -- Global Search should still find a draft
-- the caller could open directly).
-- security definer: contacts (unlike every other searchable table) grants authenticated a direct table
-- INSERT/UPDATE (Step 06's narrow browser-write allowlist), so this trigger must not depend on the
-- invoking role's own privileges to reach outbox_events, exactly like tg_audit above it.
create function app_private.tg_search_reindex() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (new.entity_id, 'SearchReindexRequested', TG_ARGV[0], new.id, '{}'::jsonb);
  return new;
end
$$;

create trigger tg_search_reindex after insert or update on public.contacts
  for each row execute function app_private.tg_search_reindex('contact');
create trigger tg_search_reindex after insert or update on public.invoices
  for each row execute function app_private.tg_search_reindex('invoice');
create trigger tg_search_reindex after insert or update on public.bills
  for each row execute function app_private.tg_search_reindex('bill');
create trigger tg_search_reindex after insert or update on public.expenses
  for each row execute function app_private.tg_search_reindex('expense');
create trigger tg_search_reindex after insert or update on public.fixed_assets
  for each row execute function app_private.tg_search_reindex('fixed_asset');
create trigger tg_search_reindex after insert or update on public.loans
  for each row execute function app_private.tg_search_reindex('loan');
create trigger tg_search_reindex after insert or update on public.other_obligations
  for each row execute function app_private.tg_search_reindex('other_obligation');
create trigger tg_search_reindex after insert or update on public.equity_events
  for each row execute function app_private.tg_search_reindex('equity_event');
create trigger tg_search_reindex after insert or update on public.journal_entries
  for each row execute function app_private.tg_search_reindex('journal_entry');

-- Re-derives one record's title/subtitle/date/permission_key straight from its source table (never
-- trusting the outbox payload -- Step 08 §22) and upserts it. A row whose source record no longer exists
-- (should not happen; entity_id/target_id FKs are all on delete restrict) is removed from the index.
create function app_private.search_reindex_one(p_type text, p_id uuid) returns void
language plpgsql as $$
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

-- The outbox consumer (Step 13 §14-15 background job: "Derived refresh"). Claims up to p_limit pending
-- SearchReindexRequested events for the nine searchable aggregate types, refreshes each record's index
-- row, then marks the event processed. Callable by service_role (the scheduled path, structurally
-- authorized -- no signed-in user exists there, same pattern as P10's run_due_recurring_occurrences) or
-- by an authenticated caller holding system.import (the closest existing system-maintenance capability;
-- decision 146's minimalism -- no new permission key for search), for an on-demand "reindex now".
create function public.refresh_search_index_batch(p_limit integer default 200)
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
                              'other_obligation', 'equity_event', 'journal_entry')
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

-- Full, derived rebuild for one Entity (Step 08 §22): wipes and repopulates straight from the nine
-- source tables. Same callers as refresh_search_index_batch.
create function public.rebuild_search_index(p_entity uuid) returns integer
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

  return v_count;
end
$$;

-- ------------------------------------------------------------ query
-- Filters by has_permission BEFORE ranking (Step 06 §11): an inaccessible record never reaches the
-- ranking step, let alone the result set.
create function public.search(p_entity uuid, p_query text, p_limit integer default 20)
returns table (target_type text, target_id uuid, title text, subtitle text, occurred_on date, rank real)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_tsquery tsquery;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.is_member(p_entity) then
    raise exception 'FORBIDDEN: not a member of this Entity' using errcode = 'insufficient_privilege';
  end if;
  if nullif(btrim(coalesce(p_query, '')), '') is null then
    raise exception 'INVALID: a search query is required' using errcode = 'invalid_parameter_value';
  end if;
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'INVALID: limit must be between 1 and 100' using errcode = 'invalid_parameter_value';
  end if;

  begin
    v_tsquery := websearch_to_tsquery('simple', p_query);
  exception when others then
    v_tsquery := plainto_tsquery('simple', p_query);
  end;
  if v_tsquery is null or v_tsquery = ''::tsquery then
    return;
  end if;

  return query
    select s.target_type, s.target_id, s.title, s.subtitle, s.occurred_on, ts_rank(s.tsv, v_tsquery)
    from public.search_index s
    where s.entity_id = p_entity
      and s.tsv @@ v_tsquery
      and app_authz.has_permission(p_entity, s.permission_key)
    order by ts_rank(s.tsv, v_tsquery) desc, s.occurred_on desc nulls last
    limit p_limit;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.search_index');
create policy search_index_select on public.search_index for select to authenticated
  using (app_authz.has_permission(entity_id, permission_key));

revoke all on function app_private.tg_search_reindex() from public;
revoke all on function app_private.search_reindex_one(text, uuid) from public;

grant execute on function public.refresh_search_index_batch(integer) to authenticated;
grant execute on function public.refresh_search_index_batch(integer) to service_role;
grant execute on function public.rebuild_search_index(uuid) to authenticated;
grant execute on function public.rebuild_search_index(uuid) to service_role;
grant execute on function public.search(uuid, text, integer) to authenticated;
