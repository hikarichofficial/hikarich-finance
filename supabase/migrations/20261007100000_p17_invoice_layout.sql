-- P17 (decision 310): the owner arranges the invoice document from Settings.
--   * `entity_profiles.invoice_layout` (jsonb, null = the standard arrangement) keeps the order of the eleven
--     blocks of the document (logo, issuer, title, customer, dates, lines, totals, payments, instructions, notes,
--     terms), per block: shown or hidden, aligned left/centre/right, full or half width, and the logo size.
--   * `set_invoice_layout` changes it (needs `system.entity_config` and a recent step-up like the other identity
--     changes); a null layout puts the standard arrangement back. Only presentation: no amount, tax or
--     number can be changed or hidden through it (the six blocks that carry them cannot be hidden).
--   * Issuing an invoice copies the arrangement into the frozen issuer snapshot, so the arrangement applies to
--     NEW invoices only; an invoice issued earlier keeps the look it was issued with.

create function app_private.valid_invoice_layout(p jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog, public as $$
declare
  v_ids constant text[] := array['logo', 'issuer', 'title', 'customer', 'dates', 'lines', 'totals',
                                 'payments', 'instructions', 'notes', 'terms'];
  v_required constant text[] := array['issuer', 'title', 'customer', 'dates', 'lines', 'totals'];
  b jsonb;
  v_seen text[] := '{}';
  v_id text;
begin
  if jsonb_typeof(p) is distinct from 'object' then return false; end if;
  if exists (select 1 from jsonb_object_keys(p) k where k not in ('v', 'blocks', 'logo_size')) then return false; end if;
  if p -> 'v' is distinct from '1'::jsonb then return false; end if;
  if p ? 'logo_size' and (p ->> 'logo_size') not in ('sm', 'md', 'lg') then return false; end if;
  if jsonb_typeof(p -> 'blocks') is distinct from 'array' or jsonb_array_length(p -> 'blocks') <> array_length(v_ids, 1) then
    return false;
  end if;
  for b in select * from jsonb_array_elements(p -> 'blocks') loop
    if jsonb_typeof(b) is distinct from 'object' then return false; end if;
    if exists (select 1 from jsonb_object_keys(b) k where k not in ('key', 'show', 'align', 'width')) then return false; end if;
    v_id := b ->> 'key';
    if v_id is null or not (v_id = any (v_ids)) or v_id = any (v_seen) then return false; end if;
    v_seen := v_seen || v_id;
    if jsonb_typeof(b -> 'show') is distinct from 'boolean' then return false; end if;
    if (b ->> 'align') is null or (b ->> 'align') not in ('left', 'center', 'right') then return false; end if;
    if (b ->> 'width') is null or (b ->> 'width') not in ('full', 'half') then return false; end if;
    if v_id = any (v_required) and (b ->> 'show') <> 'true' then return false; end if;
  end loop;
  return true;
end
$$;

alter table public.entity_profiles add column invoice_layout jsonb
  check (invoice_layout is null or app_private.valid_invoice_layout(invoice_layout));

create function public.set_invoice_layout(p_entity uuid, p_layout jsonb) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_layout jsonb := case when p_layout is null or p_layout = 'null'::jsonb then null else p_layout end;
  v_had boolean;
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
  if v_layout is not null and not app_private.valid_invoice_layout(v_layout) then
    raise exception 'INVALID: the invoice layout is not valid' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.entities where id = p_entity) then
    raise exception 'FORBIDDEN: unknown Entity' using errcode = 'insufficient_privilege';
  end if;
  select (invoice_layout is not null) into v_had from public.entity_profiles where entity_id = p_entity;
  insert into public.entity_profiles (entity_id, invoice_layout) values (p_entity, v_layout)
  on conflict (entity_id) do update set invoice_layout = excluded.invoice_layout;
  insert into public.audit_events (entity_id, actor_type, actor_id, action, target_table, target_id,
                                   before_state, after_state)
  values (p_entity, 'user', auth.uid(), 'entities.invoice_layout_changed', 'entity_profiles', p_entity,
          jsonb_build_object('custom', coalesce(v_had, false)),
          jsonb_build_object('custom', v_layout is not null));
end
$$;
revoke all on function public.set_invoice_layout(uuid, jsonb) from public, anon;
grant execute on function public.set_invoice_layout(uuid, jsonb) to authenticated;
revoke all on function app_private.valid_invoice_layout(jsonb) from public;

-- ------------------------------------------------------------ issuing keeps the arrangement
-- Identical to the previous definition except that the frozen issuer snapshot also carries the arrangement.
create or replace function app_private.issue_invoice_core(p_invoice uuid) returns uuid
language plpgsql as $$
declare
  i public.invoices%rowtype;
  e public.entities%rowtype;
  c public.contacts%rowtype;
  pr public.entity_profiles%rowtype;
  fa public.financial_accounts%rowtype;
  ch public.payment_channels%rowtype;
  v_base public.currency_code;
  v_scale integer;
  v_today date;
  v_base_total numeric;
  v_base_disc numeric;
  v_base_gross numeric;
  v_contra uuid;
  v_use_contra boolean;
  v_weights numeric[];
  v_alloc numeric[];
  v_alloc_disc numeric[];
  v_lines jsonb := '[]'::jsonb;
  v_number text;
  v_journal uuid;
  v_desc text;
  v_payment jsonb := null;
  l record;
  n integer := 0;
  v_rev uuid;
  v_orig jsonb := '{}'::jsonb;
  v_eval jsonb;
  v_vat numeric := 0;
begin
  select * into i from public.invoices where id = p_invoice;
  select * into e from public.entities where id = i.entity_id;
  v_base := e.base_currency;
  v_scale := app_private.currency_scale(v_base);
  v_today := app_private.entity_today(i.entity_id);

  if i.status <> 'draft' then
    raise exception 'CONFLICT: only a draft invoice can be issued (now %)', i.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if e.status <> 'active' then
    raise exception 'CONFLICT: the Entity is disabled' using errcode = 'integrity_constraint_violation';
  end if;
  if i.issue_date > v_today then
    raise exception 'INVALID: an invoice dated in the future stays a draft until its date (Step 08 §14)'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.invoice_check_header(i.entity_id, i.customer_id, i.issue_date, i.due_date, i.currency,
                                           i.exchange_rate, i.payment_account_id, i.payment_channel_id);
  perform app_private.assert_period_postable(i.entity_id, i.issue_date);

  if not exists (select 1 from public.invoice_lines where invoice_id = i.id) then
    raise exception 'INVALID: an invoice needs at least one line' using errcode = 'invalid_parameter_value';
  end if;
  if i.total <= 0 then
    raise exception 'INVALID: a zero-value invoice cannot be issued (Step 08 §5)' using errcode = 'invalid_parameter_value';
  end if;
  -- The tax determination comes first (Step 04 §9, Step 05 §1). Unknown material facts stop the issue: nothing is guessed.
  v_eval := app_private.tax_evaluate('invoice', i.id);
  if v_eval ->> 'engine' = 'active' then
    if v_eval ->> 'status' = 'needs_review' then
      raise exception 'CONFLICT: the tax determination of this invoice needs review before it can be issued: %',
        v_eval -> 'reasons' ->> 0 using errcode = 'integrity_constraint_violation';
    end if;
    v_vat := (v_eval ->> 'vat_output_total')::numeric;
    if v_vat > 0 then
      i.tax_total := v_vat;
      i.total := i.subtotal - i.discount_total + v_vat;
      update public.invoices set tax_total = i.tax_total, total = i.total where id = i.id;
    end if;
  elsif exists (select 1 from public.invoice_lines where invoice_id = i.id and tax_amount <> 0) or i.tax_total <> 0 then
    raise exception 'CONFLICT: tax is recognised only from the Entity''s tax-engine start date; nothing is guessed'
      using errcode = 'integrity_constraint_violation';
  end if;

  -- Base-currency values. The receivable is the invoice total converted once; the revenue and discount sides are
  -- spread over the lines with the largest-remainder method so the journal balances to the cent (Step 04 §14).
  if i.currency = v_base then
    v_base_total := i.total;
    v_base_disc := i.discount_total;
  else
    v_base_total := app_private.round_amount(i.total * i.exchange_rate, v_scale, 'half_up');
    v_base_disc := app_private.round_amount(i.discount_total * i.exchange_rate, v_scale, 'half_up');
    v_orig := jsonb_build_object('original_currency', i.currency, 'exchange_rate', i.exchange_rate);
  end if;
  if v_base_total <= 0 then
    raise exception 'INVALID: the invoice is too small to book in %', v_base using errcode = 'invalid_parameter_value';
  end if;
  v_base_gross := v_base_total - v_vat + v_base_disc;
  v_contra := app_private.sales_contra_account(i.entity_id);
  v_use_contra := v_base_disc > 0 and v_contra is not null;

  if v_use_contra then
    select array_agg(line_subtotal order by line_no) into v_weights from public.invoice_lines where invoice_id = i.id;
    v_alloc := app_private.allocate_amount(v_base_gross, v_weights, v_scale);
    select array_agg(discount_amount order by line_no) into v_weights from public.invoice_lines where invoice_id = i.id;
    v_alloc_disc := app_private.allocate_amount(v_base_disc, v_weights, v_scale);
  else
    select array_agg(line_total order by line_no) into v_weights from public.invoice_lines where invoice_id = i.id;
    v_alloc := app_private.allocate_amount(v_base_total - v_vat, v_weights, v_scale);
  end if;

  n := 0;
  for l in select * from public.invoice_lines where invoice_id = i.id order by line_no loop
    n := n + 1;
    update public.invoice_lines
    set revenue_account_id = app_private.resolve_revenue_account(i.entity_id, l.category_id, i.issue_date),
        base_amount = v_alloc[n],
        base_discount_amount = case when v_use_contra then v_alloc_disc[n] else 0 end
    where id = l.id;
  end loop;

  select * into c from public.contacts where id = i.customer_id and entity_id = i.entity_id;
  select * into pr from public.entity_profiles where entity_id = i.entity_id;
  if i.payment_account_id is not null or i.payment_channel_id is not null then
    if i.payment_account_id is not null then
      select * into fa from public.financial_accounts where id = i.payment_account_id;
    end if;
    if i.payment_channel_id is not null then
      select * into ch from public.payment_channels where id = i.payment_channel_id;
    end if;
    -- A payment link (decision 307) is copied as text like the account details: later edits of the link do
    -- not change an invoice that was already issued.
    v_payment := jsonb_build_object(
      'account_name', fa.name, 'institution_name', fa.institution_name, 'account_number', fa.account_number,
      'account_holder', fa.account_holder, 'currency', fa.currency, 'kind', fa.kind,
      'channel_name', ch.name, 'channel_kind', ch.method_kind, 'payment_url', ch.payment_url);
  end if;

  perform app_private.ensure_sales_numbering(i.entity_id);
  v_number := app_private.allocate_document_number(i.entity_id, 'invoice', i.issue_date);
  v_desc := format('Invoice %s - %s', v_number, c.display_name);

  v_lines := v_lines || (jsonb_build_object(
      'account_key', 'ACCOUNTS_RECEIVABLE', 'debit', v_base_total, 'credit', 0, 'description', v_desc)
    || case when i.currency = v_base then '{}'::jsonb
            else v_orig || jsonb_build_object('original_amount', i.total) end);
  if v_use_contra then
    v_lines := v_lines || (jsonb_build_object(
        'account_id', v_contra, 'debit', v_base_disc, 'credit', 0, 'description', 'Discount: ' || v_desc)
      || case when i.currency = v_base then '{}'::jsonb
              else v_orig || jsonb_build_object('original_amount', i.discount_total) end);
  end if;
  for l in select * from public.invoice_lines where invoice_id = i.id and base_amount > 0 order by line_no loop
    v_lines := v_lines || jsonb_build_object(
      'account_id', l.revenue_account_id, 'debit', 0, 'credit', l.base_amount,
      'description', left(l.description, 200) || ' (' || v_number || ')');
  end loop;

  if v_vat > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_key', 'TAX_PAYABLE', 'debit', 0, 'credit', v_vat, 'description', 'Output VAT: ' || v_desc);
  end if;

  v_journal := app_private.post_system_journal(
    i.entity_id, 'invoice', i.id, 'invoice.issue', 'invoice.v1', i.issue_date, v_desc, v_lines);
  perform app_private.tax_record_results('invoice', i.id, v_eval, v_journal, v_desc);

  update public.invoices
  set status = 'issued', invoice_number = v_number, journal_id = v_journal, issued_at = now(), issued_by = auth.uid(),
      base_total = v_base_total, base_discount_total = v_base_disc,
      tax_status = case when v_eval ->> 'engine' = 'active' then 'determined' else tax_status end,
      issuer_snapshot = jsonb_build_object(
        'entity_type', e.entity_type, 'legal_name', e.legal_name, 'brand_name', e.brand_name,
        'address_line', pr.address_line, 'city', pr.city, 'province', pr.province, 'postal_code', pr.postal_code,
        'country_code', pr.country_code, 'contact_email', pr.contact_email, 'contact_phone', pr.contact_phone,
        'website', pr.website, 'layout', pr.invoice_layout),
      -- The customer's tax identifier is deliberately not part of the document snapshot (Step 06 §6).
      customer_snapshot = jsonb_build_object(
        'display_name', c.display_name, 'legal_name', c.legal_name, 'email', c.email, 'phone', c.phone,
        'address_line', c.address_line, 'city', c.city, 'country_code', c.country_code),
      payment_snapshot = v_payment
  where id = i.id;

  insert into public.invoice_public_links (entity_id, invoice_id, token)
  values (i.entity_id, i.id, app_private.new_public_token());

  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (i.entity_id, 'InvoiceIssued', 'invoice', i.id,
          jsonb_build_object('invoice_number', v_number, 'total', i.total, 'currency', i.currency));
  return v_journal;
end
$$;
