-- Decision 307 (OWNER, 6 October 2026): invoice header with the company logo, a payer name that is always asked, and
-- clickable payment links on the invoice.
--
--  * `entity_profiles.logo_data_url`: the Entity's logo as a small image stored in the row (png, jpeg or webp, at
--    most about 300 KB). `set_entity_logo` changes it (needs `system.entity_config` and a recent step-up like the
--    other identity changes); the audit trail records that it changed, never the image. The public invoice and
--    receipt views carry the logo, so the page of a customer shows it.
--  * `payment_channels.payment_url` and the channel kind `payment_link`: the "Tautan Pembayaran" master (name and
--    https address of a payment gateway page). `create_payment_link` / `update_payment_link` need `invoices.create`.
--    An invoice picks a link through its existing `payment_channel_id`; issuing copies the address into the frozen
--    payment details. The customer opens it from the invoice; recording the payment stays manual.
--  * `public_submit_payment_claim` refuses a claim without a payer name.

-- ------------------------------------------------------------ logo
alter table public.entity_profiles add column logo_data_url text
  check (logo_data_url is null
         or (logo_data_url ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$' and length(logo_data_url) <= 400000));

-- The image itself never goes into the audit trail.
drop trigger tg_audit on public.entity_profiles;
create trigger tg_audit after insert or update or delete on public.entity_profiles
  for each row execute function app_private.tg_audit('entity_id', 'logo_data_url');

create function public.set_entity_logo(p_entity uuid, p_logo text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_logo text := nullif(btrim(coalesce(p_logo, '')), '');
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
  if v_logo is not null and (v_logo !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$') then
    raise exception 'INVALID: the logo must be a png, jpeg or webp image' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(v_logo, '')) > 400000 then
    raise exception 'INVALID: the logo is too large (about 300 KB at most)' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.entities where id = p_entity) then
    raise exception 'FORBIDDEN: unknown Entity' using errcode = 'insufficient_privilege';
  end if;
  select (logo_data_url is not null) into v_had from public.entity_profiles where entity_id = p_entity;
  insert into public.entity_profiles (entity_id, logo_data_url) values (p_entity, v_logo)
  on conflict (entity_id) do update set logo_data_url = excluded.logo_data_url;
  insert into public.audit_events (entity_id, actor_type, actor_id, action, target_table, target_id,
                                   before_state, after_state)
  values (p_entity, 'user', auth.uid(), 'entities.logo_changed', 'entity_profiles', p_entity,
          jsonb_build_object('has_logo', coalesce(v_had, false)),
          jsonb_build_object('has_logo', v_logo is not null, 'size_chars', length(coalesce(v_logo, ''))));
end
$$;
revoke all on function public.set_entity_logo(uuid, text) from public, anon;
grant execute on function public.set_entity_logo(uuid, text) to authenticated;

-- ------------------------------------------------------------ payment links
alter table public.payment_channels drop constraint if exists payment_channels_method_kind_check;
alter table public.payment_channels add constraint payment_channels_method_kind_check
  check (method_kind in ('bank_transfer', 'cash', 'qris', 'ewallet', 'card', 'other', 'payment_link'));
alter table public.payment_channels add column payment_url text
  check (payment_url is null or (payment_url ~ '^https://[^[:space:]]+$' and length(payment_url) <= 500));
alter table public.payment_channels add constraint payment_channels_link_has_url
  check (method_kind <> 'payment_link' or payment_url is not null);

create function public.create_payment_link(p_entity uuid, p_key text, p_name text, p_url text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_name text := btrim(coalesce(p_name, ''));
  v_url text := btrim(coalesce(p_url, ''));
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.create') then
    raise exception 'FORBIDDEN: adding a payment link needs invoices.create' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('payment_link.create', p_entity, p_key,
    md5(jsonb_build_object('n', v_name, 'u', v_url)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if length(v_name) not between 2 and 120 then
    raise exception 'INVALID: the link name needs 2 to 120 characters' using errcode = 'invalid_parameter_value';
  end if;
  if v_url !~ '^https://[^[:space:]]+$' or length(v_url) > 500 then
    raise exception 'INVALID: the payment link must be an https address (up to 500 characters)' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.payment_channels c where c.entity_id = p_entity and lower(c.name) = lower(v_name)) then
    raise exception 'CONFLICT: a payment channel or link with this name already exists' using errcode = 'unique_violation';
  end if;
  insert into public.payment_channels (entity_id, method_kind, name, payment_url)
  values (p_entity, 'payment_link', v_name, v_url)
  returning id into v_id;
  perform app_private.idem_complete('payment_link.create', p_entity, p_key, 'payment_channels', v_id);
  return v_id;
end
$$;

create function public.update_payment_link(p_entity uuid, p_id uuid, p_name text, p_url text, p_active boolean) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_url text := btrim(coalesce(p_url, ''));
  c public.payment_channels%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.create') then
    raise exception 'FORBIDDEN: changing a payment link needs invoices.create' using errcode = 'insufficient_privilege';
  end if;
  select * into c from public.payment_channels where id = p_id and entity_id = p_entity and method_kind = 'payment_link' for update;
  if not found then
    raise exception 'INVALID: unknown payment link' using errcode = 'invalid_parameter_value';
  end if;
  if length(v_name) not between 2 and 120 then
    raise exception 'INVALID: the link name needs 2 to 120 characters' using errcode = 'invalid_parameter_value';
  end if;
  if v_url !~ '^https://[^[:space:]]+$' or length(v_url) > 500 then
    raise exception 'INVALID: the payment link must be an https address (up to 500 characters)' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.payment_channels x
             where x.entity_id = p_entity and x.id <> p_id and lower(x.name) = lower(v_name)) then
    raise exception 'CONFLICT: a payment channel or link with this name already exists' using errcode = 'unique_violation';
  end if;
  update public.payment_channels
  set name = v_name, payment_url = v_url, is_active = coalesce(p_active, c.is_active)
  where id = p_id;
end
$$;
revoke all on function public.create_payment_link(uuid, text, text, text) from public, anon;
revoke all on function public.update_payment_link(uuid, uuid, text, text, boolean) from public, anon;
grant execute on function public.create_payment_link(uuid, text, text, text) to authenticated;
grant execute on function public.update_payment_link(uuid, uuid, text, text, boolean) to authenticated;

-- ------------------------------------------------------------ issuing keeps the link; public views carry the logo
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
        'website', pr.website),
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

create or replace function public.public_invoice_view(p_token text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  l public.invoice_public_links%rowtype;
  v_doc jsonb;
  v_pending boolean;
begin
  l := app_private.public_link_lookup(p_token);
  if l.id is null then
    return jsonb_build_object('state', 'unavailable');
  end if;
  v_doc := app_private.invoice_document_json(l.invoice_id, true);
  select exists (select 1 from public.payment_submissions s where s.invoice_id = l.invoice_id and s.status = 'pending')
    into v_pending;
  return jsonb_build_object(
    'state', 'ok',
    'invoice', v_doc - 'document' - 'is_draft',
    'logo', (select p.logo_data_url from public.entity_profiles p where p.entity_id = l.entity_id),
    'pending_claim', v_pending,
    'can_claim', (v_doc ->> 'outstanding')::numeric > 0);
end
$$;

create or replace function public.public_receipt_view(p_token text, p_receipt_number text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  l public.invoice_public_links%rowtype;
  v_payment uuid;
begin
  l := app_private.public_link_lookup(p_token);
  if l.id is null then
    return jsonb_build_object('state', 'unavailable');
  end if;
  select p.id into v_payment
  from public.payments p
  join public.payment_allocations a on a.payment_id = p.id and a.invoice_id = l.invoice_id and a.status = 'active'
  where p.entity_id = l.entity_id and p.payment_number = p_receipt_number and p.status = 'confirmed'
  limit 1;
  if v_payment is null then
    return jsonb_build_object('state', 'unavailable');
  end if;
  return jsonb_build_object('state', 'ok',
    'logo', (select p.logo_data_url from public.entity_profiles p where p.entity_id = l.entity_id),
    'receipt',
    (app_private.payment_receipt_json(v_payment, true, l.invoice_id) - 'refundable' - 'advance_amount' - 'payer_name'));
end
$$;

-- ------------------------------------------------------------ payer name is required on a public claim
create or replace function public.public_submit_payment_claim(
  p_token text, p_amount numeric, p_date date, p_payer_name text, p_reference text, p_note text, p_client text)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.invoice_public_links%rowtype;
  v_n bigint;
  v_id uuid;
  v_existing boolean;
begin
  l := app_private.public_link_lookup(p_token);
  if l.id is null then
    raise exception 'UNAVAILABLE: this link is not valid' using errcode = 'insufficient_privilege';
  end if;
  if p_client is null or length(p_client) not between 16 and 128 then
    raise exception 'INVALID: the request could not be verified' using errcode = 'invalid_parameter_value';
  end if;
  -- The payer name is required (OWNER, 6 October 2026): only the reference and the note stay optional.
  if length(btrim(regexp_replace(coalesce(p_payer_name, ''), '[\x01-\x1f\x7f]', '', 'g'))) = 0 then
    raise exception 'INVALID: the payer name is required' using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('app.actor_type', 'public_token', true);
  perform set_config('app.actor_id', l.id::text, true);

  -- Abuse limits: per requester per hour, per invoice per day, and pending claims per invoice. The counts are
  -- serialised per invoice so that concurrent claims cannot all slip under a limit.
  perform pg_advisory_xact_lock(hashtextextended('public_claim:' || l.invoice_id::text, 0));
  select count(*) into v_n from public.payment_submissions s
  where s.client_hash = p_client and s.created_at > now() - interval '1 hour';
  if v_n >= 8 then
    raise exception 'THROTTLED: too many requests, try again later' using errcode = 'insufficient_privilege';
  end if;
  select count(*) into v_n from public.payment_submissions s
  where s.invoice_id = l.invoice_id and s.source = 'public' and s.created_at > now() - interval '1 day';
  if v_n >= 20 then
    raise exception 'THROTTLED: too many requests for this invoice today' using errcode = 'insufficient_privilege';
  end if;
  select count(*) into v_n from public.payment_submissions s where s.invoice_id = l.invoice_id and s.status = 'pending';
  if v_n >= 5 then
    raise exception 'THROTTLED: this invoice already has several claims awaiting verification' using errcode = 'insufficient_privilege';
  end if;

  select x.submission_id, x.was_existing into v_id, v_existing
  from app_private.insert_submission(
    l.invoice_id, 'public', p_amount, p_date,
    regexp_replace(coalesce(p_payer_name, ''), '[\x01-\x1f\x7f]', '', 'g'),
    regexp_replace(coalesce(p_reference, ''), '[\x01-\x1f\x7f]', '', 'g'),
    null,
    regexp_replace(coalesce(p_note, ''), '[\x01-\x1f\x7f]', '', 'g'),
    p_client, null) x;
  return jsonb_build_object('state', 'pending', 'already_received', v_existing);
end
$$;
