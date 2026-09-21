-- P7 (Step 15 §11) part 2: tax facts on document lines.
-- Authority: Step 05 §5 (determination pipeline: transaction facts), §10-11 (withholding and VAT facts), §14
-- (review states), Step 08 §10 (tax integrity), Step 07 (document lifecycles).
--
-- A tax outcome is decided from FACTS the document carries, never from a category label (Step 05 §15). This part
-- gives the document lines those facts and lets the drafting commands carry them:
--   * invoice line  : vat_treatment  (the supply classification, from the classification vocabulary)
--   * bill/expense line: tax_amount (the input VAT the vendor charged, a fact from the vendor's tax invoice),
--                     vat_invoice_ref, vat_not_creditable (a restriction the user asserts), wht_object (the
--                     withholding object), and who confirmed a classification (tax.confirm_facts).
--   * bill/expense header: withheld_total (income tax withheld from the vendor, set by the engine when the document
--                     is recognised). For a bill, what is really owed to the vendor is total - withheld_total
--                     (Step 05 §10: withholding is separate from the vendor's net cash settlement and from the
--                     gross expense); the sub-ledger, payments and aging work on that amount.
-- Nothing is calculated here; the determination follows in the next parts. Documents keep working as before while
-- the Entity's tax engine is not active.

-- ------------------------------------------------------------ columns
alter table public.invoice_lines
  add column vat_treatment text references public.tax_treatment_catalog (treatment_key) on delete restrict;

alter table public.bill_lines
  add column wht_object text references public.tax_treatment_catalog (treatment_key) on delete restrict,
  add column vat_not_creditable boolean not null default false,
  add column vat_invoice_ref text check (vat_invoice_ref is null or length(vat_invoice_ref) <= 100),
  add column tax_confirmed_by uuid,
  add column tax_confirmed_at timestamptz,
  add constraint bill_line_tax_confirm_shape check ((tax_confirmed_by is null) = (tax_confirmed_at is null));

alter table public.expense_lines
  add column wht_object text references public.tax_treatment_catalog (treatment_key) on delete restrict,
  add column vat_not_creditable boolean not null default false,
  add column vat_invoice_ref text check (vat_invoice_ref is null or length(vat_invoice_ref) <= 100),
  add column tax_confirmed_by uuid,
  add column tax_confirmed_at timestamptz,
  add constraint expense_line_tax_confirm_shape check ((tax_confirmed_by is null) = (tax_confirmed_at is null));

-- The header of a bill or expense: income tax withheld from the payee (base currency, set at recognition).
alter table public.bills
  add column withheld_total public.money_amount not null default 0,
  add constraint bill_withheld_within check (withheld_total >= 0 and withheld_total <= subtotal);

alter table public.expenses
  add column withheld_total public.money_amount not null default 0,
  add constraint expense_withheld_within check (withheld_total >= 0 and withheld_total <= subtotal);

-- A document that was recognised by the engine says so; "pending_engine" stays for drafts and for documents dated
-- before the Entity's engine start date.
alter table public.invoices drop constraint invoices_tax_status_check;
alter table public.invoices add constraint invoices_tax_status_check check (tax_status in ('pending_engine', 'determined'));
alter table public.bills drop constraint bills_tax_status_check;
alter table public.bills add constraint bills_tax_status_check check (tax_status in ('pending_engine', 'determined'));
alter table public.expenses drop constraint expenses_tax_status_check;
alter table public.expenses add constraint expenses_tax_status_check check (tax_status in ('pending_engine', 'determined'));

-- ------------------------------------------------------------ invoice drafting carries the VAT treatment
create or replace function app_private.invoice_prepare_lines(
  p_entity uuid, p_currency public.currency_code, p_lines jsonb, p_allow_inactive boolean default false)
returns jsonb
language plpgsql stable as $$
declare
  v_scale integer := app_private.currency_scale(p_currency);
  v_elem jsonb;
  v_no integer := 0;
  v_out jsonb := '[]'::jsonb;
  v_prod public.products%rowtype;
  v_pid uuid;
  v_cid uuid;
  v_vat text;
  v_desc text;
  v_qty numeric;
  v_price numeric;
  v_dtype text;
  v_dval numeric;
  v_sub numeric;
  v_disc numeric;
  v_subtotal numeric := 0;
  v_discount numeric := 0;
begin
  if p_lines is null then
    p_lines := '[]'::jsonb;
  end if;
  if jsonb_typeof(p_lines) <> 'array' then
    raise exception 'INVALID: lines must be a list' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_lines) > 200 then
    raise exception 'INVALID: an invoice can have at most 200 lines' using errcode = 'invalid_parameter_value';
  end if;

  for v_elem in select value from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'INVALID: line % is not an object', v_no using errcode = 'invalid_parameter_value';
    end if;
    v_prod := null;
    v_pid := null;
    if nullif(v_elem ->> 'product_id', '') is not null then
      begin
        v_pid := (v_elem ->> 'product_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'INVALID: line % product is not a valid identifier', v_no using errcode = 'invalid_parameter_value';
      end;
      select * into v_prod from public.products where id = v_pid and entity_id = p_entity;
      if not found then
        raise exception 'INVALID: line % product does not belong to this Entity', v_no using errcode = 'invalid_parameter_value';
      end if;
      if not v_prod.is_active and not p_allow_inactive then
        raise exception 'INVALID: line % product is inactive and cannot be sold', v_no using errcode = 'invalid_parameter_value';
      end if;
    end if;

    v_desc := btrim(coalesce(nullif(btrim(coalesce(v_elem ->> 'description', '')), ''), v_prod.name, ''));
    if length(v_desc) not between 1 and 500 then
      raise exception 'INVALID: line % needs a description of up to 500 characters', v_no
        using errcode = 'invalid_parameter_value';
    end if;

    v_qty := app_private.parse_amount(coalesce(nullif(v_elem ->> 'quantity', ''), '1'), format('line %s quantity', v_no));
    if v_qty <= 0 or v_qty >= 10::numeric ^ 9 or app_private.round_amount(v_qty, 4, 'down') <> v_qty then
      raise exception 'INVALID: line % quantity must be positive with at most 4 decimals', v_no
        using errcode = 'invalid_parameter_value';
    end if;

    if nullif(v_elem ->> 'unit_price', '') is not null then
      v_price := app_private.parse_amount(v_elem ->> 'unit_price', format('line %s unit price', v_no));
    elsif v_prod.id is not null and v_prod.default_unit_price is not null and v_prod.default_currency = p_currency then
      v_price := v_prod.default_unit_price;
    else
      raise exception 'INVALID: line % needs a unit price', v_no using errcode = 'invalid_parameter_value';
    end if;
    if v_price < 0 or v_price >= 10::numeric ^ 12 or app_private.round_amount(v_price, 4, 'down') <> v_price then
      raise exception 'INVALID: line % unit price must not be negative and has at most 4 decimals', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    v_sub := app_private.round_amount(v_qty * v_price, v_scale, 'half_up');
    if v_sub >= 10::numeric ^ 13 then
      raise exception 'INVALID: line % amount is too large', v_no using errcode = 'invalid_parameter_value';
    end if;

    v_dtype := coalesce(nullif(v_elem ->> 'discount_type', ''), 'none');
    if v_dtype not in ('none', 'percent', 'fixed') then
      raise exception 'INVALID: line % discount type must be none, percent or fixed', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    v_dval := case when v_dtype = 'none' then 0
                   else app_private.parse_amount(coalesce(nullif(v_elem ->> 'discount_value', ''), '0'),
                                                 format('line %s discount', v_no)) end;
    if v_dtype = 'none' and nullif(v_elem ->> 'discount_value', '') is not null
       and (v_elem ->> 'discount_value')::numeric <> 0 then
      raise exception 'INVALID: line % has a discount value but no discount type', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    if v_dval < 0 or app_private.round_amount(v_dval, 4, 'down') <> v_dval then
      raise exception 'INVALID: line % discount must not be negative and has at most 4 decimals', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    if v_dtype = 'percent' then
      if v_dval > 100 then
        raise exception 'INVALID: line % percentage discount cannot exceed 100', v_no
          using errcode = 'invalid_parameter_value';
      end if;
      v_disc := app_private.round_amount(v_sub * v_dval * 0.01, v_scale, 'half_up');
    elsif v_dtype = 'fixed' then
      if app_private.round_amount(v_dval, v_scale, 'down') <> v_dval then
        raise exception 'INVALID: line % fixed discount allows % decimals for %', v_no, v_scale, p_currency
          using errcode = 'invalid_parameter_value';
      end if;
      if v_dval > v_sub then
        raise exception 'INVALID: line % discount exceeds the line amount', v_no using errcode = 'invalid_parameter_value';
      end if;
      v_disc := v_dval;
    else
      v_disc := 0;
    end if;

    v_cid := null;
    if nullif(v_elem ->> 'category_id', '') is not null then
      begin
        v_cid := (v_elem ->> 'category_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'INVALID: line % category is not a valid identifier', v_no using errcode = 'invalid_parameter_value';
      end;
    else
      v_cid := v_prod.default_category_id;
    end if;
    if v_cid is not null and not exists (
         select 1 from public.categories c
         where c.id = v_cid and c.entity_id = p_entity and c.kind = 'revenue' and c.is_active) then
      raise exception 'INVALID: line % category must be an active revenue category of this Entity', v_no
        using errcode = 'invalid_parameter_value';
    end if;

    v_vat := nullif(btrim(coalesce(v_elem ->> 'vat_treatment', '')), '');
    if v_vat is not null and not exists (
         select 1 from public.tax_treatment_catalog t where t.treatment_key = v_vat and t.side = 'sales_vat') then
      raise exception 'INVALID: line % has an unknown VAT treatment', v_no using errcode = 'invalid_parameter_value';
    end if;

    v_subtotal := v_subtotal + v_sub;
    v_discount := v_discount + v_disc;
    v_out := v_out || jsonb_build_object(
      'line_no', v_no, 'product_id', v_pid, 'description', v_desc, 'quantity', trim_scale(v_qty),
      'unit_price', trim_scale(v_price), 'discount_type', v_dtype, 'discount_value', trim_scale(v_dval),
      'line_subtotal', v_sub, 'discount_amount', v_disc, 'line_total', v_sub - v_disc, 'category_id', v_cid,
      'vat_treatment', v_vat);
  end loop;

  return jsonb_build_object('lines', v_out, 'subtotal', v_subtotal, 'discount_total', v_discount,
                            'total', v_subtotal - v_discount);
end
$$;

create or replace function app_private.invoice_write_lines(p_entity uuid, p_invoice uuid, p_prepared jsonb) returns void
language plpgsql as $$
begin
  delete from public.invoice_lines where invoice_id = p_invoice and entity_id = p_entity;
  insert into public.invoice_lines
    (entity_id, invoice_id, line_no, product_id, description, quantity, unit_price, discount_type, discount_value,
     line_subtotal, discount_amount, line_total, category_id, vat_treatment)
  select p_entity, p_invoice, (l ->> 'line_no')::smallint, nullif(l ->> 'product_id', '')::uuid, l ->> 'description',
         (l ->> 'quantity')::numeric, (l ->> 'unit_price')::numeric, l ->> 'discount_type',
         (l ->> 'discount_value')::numeric, (l ->> 'line_subtotal')::numeric, (l ->> 'discount_amount')::numeric,
         (l ->> 'line_total')::numeric, nullif(l ->> 'category_id', '')::uuid,
         nullif(l ->> 'vat_treatment', '')
  from jsonb_array_elements(p_prepared -> 'lines') l;
end
$$;

create or replace function public.update_invoice_draft(p_invoice uuid, p_patch jsonb, p_expected_version integer default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_bad text;
  v_customer uuid;
  v_issue date;
  v_due date;
  v_currency public.currency_code;
  v_rate numeric;
  v_account uuid;
  v_channel uuid;
  v_lines jsonb;
  v_prep jsonb;
  v_new_version integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.edit') then
    raise exception 'FORBIDDEN: missing invoices.edit' using errcode = 'insufficient_privilege';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'INVALID: the patch must be an object' using errcode = 'invalid_parameter_value';
  end if;
  select k into v_bad from jsonb_object_keys(p_patch) k
  where k <> all (array['customer_id', 'issue_date', 'due_date', 'currency', 'exchange_rate', 'notes', 'terms',
                        'payment_note', 'internal_note', 'payment_account_id', 'payment_channel_id', 'lines']) limit 1;
  if v_bad is not null then
    raise exception 'INVALID: field % cannot be edited on a draft invoice', v_bad using errcode = 'invalid_parameter_value';
  end if;

  select * into i from public.invoices where id = p_invoice for update;
  if i.status <> 'draft' then
    raise exception 'CONFLICT: only a draft invoice can be edited (now %); correct an issued invoice through a replacement', i.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_expected_version is not null and p_expected_version <> i.version then
    raise exception 'CONFLICT: this invoice was changed by someone else; reload it (version % vs %)', i.version, p_expected_version
      using errcode = 'integrity_constraint_violation';
  end if;

  v_customer := case when p_patch ? 'customer_id' then nullif(p_patch ->> 'customer_id', '')::uuid else i.customer_id end;
  v_issue := case when p_patch ? 'issue_date' then nullif(p_patch ->> 'issue_date', '')::date else i.issue_date end;
  v_due := case when p_patch ? 'due_date' then nullif(p_patch ->> 'due_date', '')::date else i.due_date end;
  v_currency := case when p_patch ? 'currency' then p_patch ->> 'currency' else i.currency end;
  v_rate := case when p_patch ? 'exchange_rate' then nullif(p_patch ->> 'exchange_rate', '')::numeric
                 when p_patch ? 'currency' and v_currency = i.currency then i.exchange_rate
                 when p_patch ? 'currency' then null
                 else i.exchange_rate end;
  v_account := case when p_patch ? 'payment_account_id' then nullif(p_patch ->> 'payment_account_id', '')::uuid else i.payment_account_id end;
  v_channel := case when p_patch ? 'payment_channel_id' then nullif(p_patch ->> 'payment_channel_id', '')::uuid else i.payment_channel_id end;
  perform app_private.invoice_check_header(i.entity_id, v_customer, v_issue, v_due, v_currency, v_rate, v_account, v_channel);

  if p_patch ? 'lines' then
    v_lines := p_patch -> 'lines';
  else
    select coalesce(jsonb_agg(jsonb_build_object(
        'product_id', l.product_id, 'description', l.description, 'quantity', l.quantity,
        'unit_price', l.unit_price, 'discount_type', l.discount_type, 'discount_value', l.discount_value,
        'category_id', l.category_id, 'vat_treatment', l.vat_treatment) order by l.line_no), '[]'::jsonb)
      into v_lines
    from public.invoice_lines l where l.invoice_id = i.id;
  end if;
  -- A changed currency re-prices nothing silently: the existing prices are re-read in the new currency.
  v_prep := app_private.invoice_prepare_lines(i.entity_id, v_currency, v_lines);

  update public.invoices
  set customer_id = v_customer, issue_date = v_issue, due_date = v_due, currency = v_currency, exchange_rate = v_rate,
      payment_account_id = v_account, payment_channel_id = v_channel,
      notes = case when p_patch ? 'notes' then nullif(btrim(coalesce(p_patch ->> 'notes', '')), '') else notes end,
      terms = case when p_patch ? 'terms' then nullif(btrim(coalesce(p_patch ->> 'terms', '')), '') else terms end,
      payment_note = case when p_patch ? 'payment_note' then nullif(btrim(coalesce(p_patch ->> 'payment_note', '')), '') else payment_note end,
      internal_note = case when p_patch ? 'internal_note' then nullif(btrim(coalesce(p_patch ->> 'internal_note', '')), '') else internal_note end,
      subtotal = (v_prep ->> 'subtotal')::numeric, discount_total = (v_prep ->> 'discount_total')::numeric,
      total = (v_prep ->> 'total')::numeric
  where id = i.id
  returning version into v_new_version;
  perform app_private.invoice_write_lines(i.entity_id, i.id, v_prep);
  return v_new_version;
end
$$;

create or replace function public.correct_invoice(p_invoice uuid, p_key text, p_reason text, p_date date default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_new uuid;
  v_lines jsonb;
  v_prep jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.void')
     or not app_authz.has_permission(i.entity_id, 'invoices.create') then
    raise exception 'FORBIDDEN: correcting an invoice needs invoices.void and invoices.create'
      using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 5 then
    raise exception 'INVALID: a correction needs a reason of at least 5 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into i from public.invoices where id = p_invoice for update;
  v_replay := app_private.idem_begin('invoice.correct', i.entity_id, p_key,
    md5(jsonb_build_object('i', p_invoice, 'r', v_reason, 'd', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if i.status <> 'issued' then
    raise exception 'CONFLICT: only an issued invoice can be corrected (now %)', i.status using errcode = 'integrity_constraint_violation';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'product_id', l.product_id, 'description', l.description, 'quantity', l.quantity, 'unit_price', l.unit_price,
      'discount_type', l.discount_type, 'discount_value', l.discount_value, 'category_id', l.category_id,
      'vat_treatment', l.vat_treatment)
      order by l.line_no), '[]'::jsonb)
    into v_lines from public.invoice_lines l where l.invoice_id = i.id;
  -- The lines were valid when issued: a product deactivated since then must not block the correction.
  v_prep := app_private.invoice_prepare_lines(i.entity_id, i.currency, v_lines, true);
  insert into public.invoices
    (entity_id, customer_id, currency, exchange_rate, issue_date, due_date, payment_account_id, payment_channel_id,
     notes, terms, payment_note, internal_note, subtotal, discount_total, total, replaces_invoice_id)
  values
    (i.entity_id, i.customer_id, i.currency, i.exchange_rate, i.issue_date, i.due_date, i.payment_account_id,
     i.payment_channel_id, i.notes, i.terms, i.payment_note,
     left('Replaces ' || i.invoice_number || ': ' || v_reason, 2000),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'discount_total')::numeric, (v_prep ->> 'total')::numeric, i.id)
  returning id into v_new;
  perform app_private.invoice_write_lines(i.entity_id, v_new, v_prep);

  perform app_private.close_invoice_core(p_invoice, 'void', v_reason, p_date, v_new);
  perform app_private.idem_complete('invoice.correct', i.entity_id, p_key, 'invoices', v_new);
  return v_new;
end
$$;

-- ------------------------------------------------------------ purchase drafting carries the tax facts
create or replace function app_private.purchase_prepare_lines(
  p_entity uuid, p_currency public.currency_code, p_lines jsonb, p_lenient boolean default false)
returns jsonb
language plpgsql stable as $$
declare
  v_scale integer := app_private.currency_scale(p_currency);
  v_elem jsonb;
  v_no integer := 0;
  v_out jsonb := '[]'::jsonb;
  v_desc text;
  v_qty numeric;
  v_price numeric;
  v_sub numeric;
  v_treat text;
  v_tax numeric;
  v_wht text;
  v_ref text;
  v_nc boolean;
  v_tax_total numeric := 0;
  v_cid uuid;
  v_aid uuid;
  v_total numeric := 0;
begin
  if p_lines is null then
    p_lines := '[]'::jsonb;
  end if;
  if jsonb_typeof(p_lines) <> 'array' then
    raise exception 'INVALID: lines must be a list' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_lines) > 200 then
    raise exception 'INVALID: a document can have at most 200 lines' using errcode = 'invalid_parameter_value';
  end if;

  for v_elem in select value from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'INVALID: line % is not an object', v_no using errcode = 'invalid_parameter_value';
    end if;
    v_desc := btrim(coalesce(v_elem ->> 'description', ''));
    if length(v_desc) not between 1 and 500 then
      raise exception 'INVALID: line % needs a description of up to 500 characters', v_no
        using errcode = 'invalid_parameter_value';
    end if;

    v_qty := app_private.parse_amount(coalesce(nullif(v_elem ->> 'quantity', ''), '1'), format('line %s quantity', v_no));
    if v_qty <= 0 or v_qty >= 10::numeric ^ 9 or app_private.round_amount(v_qty, 4, 'down') <> v_qty then
      raise exception 'INVALID: line % quantity must be positive with at most 4 decimals', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    v_price := app_private.parse_amount(v_elem ->> 'unit_price', format('line %s unit price', v_no));
    if v_price < 0 or v_price >= 10::numeric ^ 12 or app_private.round_amount(v_price, 4, 'down') <> v_price then
      raise exception 'INVALID: line % unit price must not be negative and has at most 4 decimals', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    v_sub := app_private.round_amount(v_qty * v_price, v_scale, 'half_up');
    if v_sub <= 0 then
      raise exception 'INVALID: line % amount must be greater than zero', v_no using errcode = 'invalid_parameter_value';
    end if;
    if v_sub >= 10::numeric ^ 13 then
      raise exception 'INVALID: line % amount is too large', v_no using errcode = 'invalid_parameter_value';
    end if;

    v_treat := coalesce(nullif(v_elem ->> 'treatment', ''), 'expense');
    if v_treat not in ('expense', 'asset', 'prepaid') then
      raise exception 'INVALID: line % treatment must be expense, asset or prepaid', v_no
        using errcode = 'invalid_parameter_value';
    end if;

    v_cid := null;
    if nullif(v_elem ->> 'category_id', '') is not null then
      begin
        v_cid := (v_elem ->> 'category_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'INVALID: line % category is not a valid identifier', v_no using errcode = 'invalid_parameter_value';
      end;
      if not exists (
           select 1 from public.categories c
           where c.id = v_cid and c.entity_id = p_entity and (c.is_active or p_lenient)
             and c.kind = case when v_treat = 'expense' then 'expense' else 'asset' end) then
        raise exception 'INVALID: line % category must be an active % category of this Entity', v_no,
          case when v_treat = 'expense' then 'expense' else 'asset' end using errcode = 'invalid_parameter_value';
      end if;
    end if;

    v_aid := null;
    if nullif(v_elem ->> 'account_id', '') is not null then
      begin
        v_aid := (v_elem ->> 'account_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'INVALID: line % account is not a valid identifier', v_no using errcode = 'invalid_parameter_value';
      end;
      if not app_private.purchase_account_ok(p_entity, v_aid, v_treat, not p_lenient) then
        raise exception 'INVALID: line % account does not fit the % treatment (or is inactive or not of this Entity)',
          v_no, v_treat using errcode = 'invalid_parameter_value';
      end if;
    end if;

    -- Tax facts of the line (P7): the input VAT the vendor charged, its evidence and the withholding object. They
    -- are facts the drafter asserts; the engine decides what they mean when the document is recognised.
    v_tax := app_private.parse_amount(coalesce(nullif(v_elem ->> 'tax_amount', ''), '0'), format('line %s VAT amount', v_no));
    if v_tax < 0 or v_tax >= 10::numeric ^ 13 or app_private.round_amount(v_tax, v_scale, 'down') <> v_tax then
      raise exception 'INVALID: line % VAT amount must not be negative and must fit the currency decimals', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    v_wht := nullif(btrim(coalesce(v_elem ->> 'wht_object', '')), '');
    if v_wht is not null and not exists (
         select 1 from public.tax_treatment_catalog t where t.treatment_key = v_wht and t.side = 'purchase_wht') then
      raise exception 'INVALID: line % has an unknown withholding object', v_no using errcode = 'invalid_parameter_value';
    end if;
    v_ref := nullif(btrim(coalesce(v_elem ->> 'vat_invoice_ref', '')), '');
    if v_ref is not null and length(v_ref) > 100 then
      raise exception 'INVALID: line % tax-invoice reference is limited to 100 characters', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    v_nc := lower(coalesce(v_elem ->> 'vat_not_creditable', 'false')) in ('true', 't', '1', 'yes');
    v_tax_total := v_tax_total + v_tax;

    v_total := v_total + v_sub;
    v_out := v_out || jsonb_build_object(
      'line_no', v_no, 'description', v_desc, 'quantity', trim_scale(v_qty), 'unit_price', trim_scale(v_price),
      'line_subtotal', v_sub, 'tax_amount', v_tax, 'line_total', v_sub + v_tax, 'treatment', v_treat,
      'category_id', v_cid, 'account_id', v_aid, 'wht_object', v_wht, 'vat_invoice_ref', v_ref,
      'vat_not_creditable', v_nc);
  end loop;

  return jsonb_build_object('lines', v_out, 'subtotal', v_total, 'tax_total', v_tax_total, 'total', v_total + v_tax_total);
end
$$;

create or replace function app_private.bill_write_lines(p_entity uuid, p_bill uuid, p_prepared jsonb) returns void
language plpgsql as $$
begin
  delete from public.bill_lines where bill_id = p_bill and entity_id = p_entity;
  insert into public.bill_lines
    (entity_id, bill_id, line_no, description, quantity, unit_price, line_subtotal, tax_amount, line_total,
     treatment, category_id, account_id, wht_object, vat_not_creditable, vat_invoice_ref)
  select p_entity, p_bill, (l ->> 'line_no')::smallint, l ->> 'description', (l ->> 'quantity')::numeric,
         (l ->> 'unit_price')::numeric, (l ->> 'line_subtotal')::numeric, (l ->> 'tax_amount')::numeric,
         (l ->> 'line_total')::numeric, l ->> 'treatment', nullif(l ->> 'category_id', '')::uuid,
         nullif(l ->> 'account_id', '')::uuid, nullif(l ->> 'wht_object', ''),
         coalesce((l ->> 'vat_not_creditable')::boolean, false), nullif(l ->> 'vat_invoice_ref', '')
  from jsonb_array_elements(p_prepared -> 'lines') l;
end
$$;

create or replace function app_private.expense_write_lines(p_entity uuid, p_expense uuid, p_prepared jsonb) returns void
language plpgsql as $$
begin
  delete from public.expense_lines where expense_id = p_expense and entity_id = p_entity;
  insert into public.expense_lines
    (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, tax_amount, line_total,
     treatment, category_id, account_id, wht_object, vat_not_creditable, vat_invoice_ref)
  select p_entity, p_expense, (l ->> 'line_no')::smallint, l ->> 'description', (l ->> 'quantity')::numeric,
         (l ->> 'unit_price')::numeric, (l ->> 'line_subtotal')::numeric, (l ->> 'tax_amount')::numeric,
         (l ->> 'line_total')::numeric, l ->> 'treatment', nullif(l ->> 'category_id', '')::uuid,
         nullif(l ->> 'account_id', '')::uuid, nullif(l ->> 'wht_object', ''),
         coalesce((l ->> 'vat_not_creditable')::boolean, false), nullif(l ->> 'vat_invoice_ref', '')
  from jsonb_array_elements(p_prepared -> 'lines') l;
end
$$;

create or replace function public.create_bill_draft(
  p_entity uuid, p_key text, p_vendor uuid, p_bill_date date, p_due_date date, p_lines jsonb default '[]'::jsonb,
  p_vendor_reference text default null, p_currency text default null, p_rate numeric default null,
  p_notes text default null, p_internal_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_currency public.currency_code;
  v_prep jsonb;
  v_id uuid;
  v_ref text := nullif(btrim(coalesce(p_vendor_reference, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.create') then
    raise exception 'FORBIDDEN: missing bills.create' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('bill.create', p_entity, p_key,
    md5(jsonb_build_object('vendor', p_vendor, 'date', p_bill_date, 'due', p_due_date, 'lines', p_lines,
                           'ref', p_vendor_reference, 'currency', p_currency, 'rate', p_rate, 'notes', p_notes,
                           'inote', p_internal_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;

  v_currency := coalesce(p_currency, app_private.entity_base_currency(p_entity));
  perform app_private.bill_check_header(p_entity, p_vendor, p_bill_date, p_due_date, v_currency, p_rate, v_ref);
  v_prep := app_private.purchase_prepare_lines(p_entity, v_currency, p_lines);
  if length(btrim(coalesce(p_notes, ''))) > 2000 or length(btrim(coalesce(p_internal_note, ''))) > 2000 then
    raise exception 'INVALID: the notes are limited to 2000 characters' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.bills
    (entity_id, vendor_id, vendor_reference, currency, exchange_rate, bill_date, due_date, notes, internal_note,
     subtotal, tax_total, total)
  values
    (p_entity, p_vendor, v_ref, v_currency, p_rate, p_bill_date, p_due_date,
     nullif(btrim(coalesce(p_notes, '')), ''), nullif(btrim(coalesce(p_internal_note, '')), ''),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'tax_total')::numeric, (v_prep ->> 'total')::numeric)
  returning id into v_id;
  perform app_private.bill_write_lines(p_entity, v_id, v_prep);

  perform app_private.idem_complete('bill.create', p_entity, p_key, 'bills', v_id);
  return v_id;
end
$$;

create or replace function public.update_bill_draft(p_bill uuid, p_patch jsonb, p_expected_version integer default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
  v_bad text;
  v_vendor uuid;
  v_ref text;
  v_date date;
  v_due date;
  v_currency public.currency_code;
  v_rate numeric;
  v_lines jsonb;
  v_prep jsonb;
  v_new_version integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  if not found or not app_authz.has_permission(b.entity_id, 'bills.edit') then
    raise exception 'FORBIDDEN: missing bills.edit' using errcode = 'insufficient_privilege';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'INVALID: the patch must be an object' using errcode = 'invalid_parameter_value';
  end if;
  select k into v_bad from jsonb_object_keys(p_patch) k
  where k <> all (array['vendor_id', 'vendor_reference', 'bill_date', 'due_date', 'currency', 'exchange_rate', 'notes',
                        'internal_note', 'lines']) limit 1;
  if v_bad is not null then
    raise exception 'INVALID: field % cannot be edited on a draft bill', v_bad using errcode = 'invalid_parameter_value';
  end if;

  select * into b from public.bills where id = p_bill for update;
  if b.status <> 'draft' then
    raise exception 'CONFLICT: only a draft bill can be edited (now %); correct an approved bill through a replacement', b.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_expected_version is not null and p_expected_version <> b.version then
    raise exception 'CONFLICT: this bill was changed by someone else; reload it (version % vs %)', b.version, p_expected_version
      using errcode = 'integrity_constraint_violation';
  end if;

  v_vendor := case when p_patch ? 'vendor_id' then nullif(p_patch ->> 'vendor_id', '')::uuid else b.vendor_id end;
  v_ref := case when p_patch ? 'vendor_reference' then nullif(btrim(coalesce(p_patch ->> 'vendor_reference', '')), '')
                else b.vendor_reference end;
  v_date := case when p_patch ? 'bill_date' then nullif(p_patch ->> 'bill_date', '')::date else b.bill_date end;
  v_due := case when p_patch ? 'due_date' then nullif(p_patch ->> 'due_date', '')::date else b.due_date end;
  v_currency := case when p_patch ? 'currency' then p_patch ->> 'currency' else b.currency end;
  v_rate := case when p_patch ? 'exchange_rate' then nullif(p_patch ->> 'exchange_rate', '')::numeric
                 when p_patch ? 'currency' and v_currency = b.currency then b.exchange_rate
                 when p_patch ? 'currency' then null
                 else b.exchange_rate end;
  perform app_private.bill_check_header(b.entity_id, v_vendor, v_date, v_due, v_currency, v_rate, v_ref);

  if p_patch ? 'lines' then
    v_lines := p_patch -> 'lines';
  else
    select coalesce(jsonb_agg(jsonb_build_object(
        'description', l.description, 'quantity', l.quantity, 'unit_price', l.unit_price, 'treatment', l.treatment,
        'category_id', l.category_id, 'account_id', l.account_id, 'tax_amount', l.tax_amount,
        'wht_object', l.wht_object, 'vat_not_creditable', l.vat_not_creditable,
        'vat_invoice_ref', l.vat_invoice_ref) order by l.line_no), '[]'::jsonb)
      into v_lines
    from public.bill_lines l where l.bill_id = b.id;
  end if;
  v_prep := app_private.purchase_prepare_lines(b.entity_id, v_currency, v_lines);
  if length(btrim(coalesce(p_patch ->> 'notes', ''))) > 2000
     or length(btrim(coalesce(p_patch ->> 'internal_note', ''))) > 2000 then
    raise exception 'INVALID: the notes are limited to 2000 characters' using errcode = 'invalid_parameter_value';
  end if;

  update public.bills
  set vendor_id = v_vendor, vendor_reference = v_ref, bill_date = v_date, due_date = v_due, currency = v_currency,
      exchange_rate = v_rate,
      notes = case when p_patch ? 'notes' then nullif(btrim(coalesce(p_patch ->> 'notes', '')), '') else notes end,
      internal_note = case when p_patch ? 'internal_note' then nullif(btrim(coalesce(p_patch ->> 'internal_note', '')), '')
                           else internal_note end,
      subtotal = (v_prep ->> 'subtotal')::numeric, tax_total = (v_prep ->> 'tax_total')::numeric,
      total = (v_prep ->> 'total')::numeric
  where id = b.id
  returning version into v_new_version;
  perform app_private.bill_write_lines(b.entity_id, b.id, v_prep);
  return v_new_version;
end
$$;

create or replace function public.correct_bill(p_bill uuid, p_key text, p_reason text, p_date date default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_new uuid;
  v_lines jsonb;
  v_prep jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  if not found or not app_authz.has_permission(b.entity_id, 'bills.void')
     or not app_authz.has_permission(b.entity_id, 'bills.create') then
    raise exception 'FORBIDDEN: correcting a bill needs bills.void and bills.create' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a correction needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into b from public.bills where id = p_bill for update;
  v_replay := app_private.idem_begin('bill.correct', b.entity_id, p_key,
    md5(jsonb_build_object('b', p_bill, 'r', v_reason, 'd', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if b.status <> 'approved' then
    raise exception 'CONFLICT: only an approved bill can be corrected (now %)', b.status
      using errcode = 'integrity_constraint_violation';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'description', l.description, 'quantity', l.quantity, 'unit_price', l.unit_price, 'treatment', l.treatment,
      'category_id', l.category_id, 'account_id', l.account_id, 'tax_amount', l.tax_amount,
        'wht_object', l.wht_object, 'vat_not_creditable', l.vat_not_creditable,
        'vat_invoice_ref', l.vat_invoice_ref) order by l.line_no), '[]'::jsonb)
    into v_lines from public.bill_lines l where l.bill_id = b.id;
  -- The lines were valid when approved: a category or account deactivated since then must not block the correction.
  v_prep := app_private.purchase_prepare_lines(b.entity_id, b.currency, v_lines, true);
  insert into public.bills
    (entity_id, vendor_id, vendor_reference, currency, exchange_rate, bill_date, due_date, notes, internal_note,
     subtotal, tax_total, total, replaces_bill_id)
  values
    (b.entity_id, b.vendor_id, b.vendor_reference, b.currency, b.exchange_rate, b.bill_date, b.due_date, b.notes,
     left('Replaces ' || b.bill_number || ': ' || v_reason, 2000),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'tax_total')::numeric, (v_prep ->> 'total')::numeric, b.id)
  returning id into v_new;
  perform app_private.bill_write_lines(b.entity_id, v_new, v_prep);

  perform app_private.close_bill_core(p_bill, 'void', v_reason, p_date, v_new);
  perform app_private.idem_complete('bill.correct', b.entity_id, p_key, 'bills', v_new);
  return v_new;
end
$$;

create or replace function public.create_expense_draft(
  p_entity uuid, p_key text, p_account uuid, p_expense_date date, p_lines jsonb, p_payee_id uuid default null,
  p_payee_name text default null, p_receipt_reference text default null, p_rate numeric default null,
  p_notes text default null, p_internal_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_currency public.currency_code;
  v_prep jsonb;
  v_id uuid;
  v_ref text := nullif(btrim(coalesce(p_receipt_reference, '')), '');
  v_name text := case when p_payee_id is null then nullif(btrim(coalesce(p_payee_name, '')), '') else null end;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.create') then
    raise exception 'FORBIDDEN: missing bills.create' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('expense.create', p_entity, p_key,
    md5(jsonb_build_object('payee', p_payee_id, 'name', p_payee_name, 'account', p_account, 'date', p_expense_date,
                           'lines', p_lines, 'ref', p_receipt_reference, 'rate', p_rate, 'notes', p_notes,
                           'inote', p_internal_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_currency := app_private.expense_check_header(p_entity, p_payee_id, v_name, p_account, p_expense_date, p_rate, v_ref);
  v_prep := app_private.purchase_prepare_lines(p_entity, v_currency, p_lines);
  if length(btrim(coalesce(p_notes, ''))) > 2000 or length(btrim(coalesce(p_internal_note, ''))) > 2000 then
    raise exception 'INVALID: the notes are limited to 2000 characters' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.expenses
    (entity_id, payee_id, payee_name, receipt_reference, financial_account_id, currency, exchange_rate, expense_date,
     notes, internal_note, subtotal, tax_total, total)
  values
    (p_entity, p_payee_id, v_name, v_ref, p_account, v_currency, p_rate, p_expense_date,
     nullif(btrim(coalesce(p_notes, '')), ''), nullif(btrim(coalesce(p_internal_note, '')), ''),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'tax_total')::numeric, (v_prep ->> 'total')::numeric)
  returning id into v_id;
  perform app_private.expense_write_lines(p_entity, v_id, v_prep);
  perform app_private.idem_complete('expense.create', p_entity, p_key, 'expenses', v_id);
  return v_id;
end
$$;

create or replace function public.update_expense_draft(p_expense uuid, p_patch jsonb, p_expected_version integer default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  x public.expenses%rowtype;
  v_bad text;
  v_payee uuid;
  v_name text;
  v_account uuid;
  v_date date;
  v_ref text;
  v_rate numeric;
  v_currency public.currency_code;
  v_lines jsonb;
  v_prep jsonb;
  v_new_version integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into x from public.expenses where id = p_expense;
  if not found or not app_authz.has_permission(x.entity_id, 'bills.edit') then
    raise exception 'FORBIDDEN: missing bills.edit' using errcode = 'insufficient_privilege';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'INVALID: the patch must be an object' using errcode = 'invalid_parameter_value';
  end if;
  select k into v_bad from jsonb_object_keys(p_patch) k
  where k <> all (array['payee_id', 'payee_name', 'account_id', 'expense_date', 'receipt_reference', 'exchange_rate',
                        'notes', 'internal_note', 'lines']) limit 1;
  if v_bad is not null then
    raise exception 'INVALID: field % cannot be edited on a draft expense', v_bad using errcode = 'invalid_parameter_value';
  end if;

  select * into x from public.expenses where id = p_expense for update;
  if x.status <> 'draft' then
    raise exception 'CONFLICT: only a draft expense can be edited (now %); correct a confirmed expense through a replacement', x.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_expected_version is not null and p_expected_version <> x.version then
    raise exception 'CONFLICT: this expense was changed by someone else; reload it (version % vs %)', x.version, p_expected_version
      using errcode = 'integrity_constraint_violation';
  end if;

  v_payee := case when p_patch ? 'payee_id' then nullif(p_patch ->> 'payee_id', '')::uuid else x.payee_id end;
  v_name := case when v_payee is not null then null
                 when p_patch ? 'payee_name' then nullif(btrim(coalesce(p_patch ->> 'payee_name', '')), '')
                 else x.payee_name end;
  v_account := case when p_patch ? 'account_id' then nullif(p_patch ->> 'account_id', '')::uuid else x.financial_account_id end;
  v_date := case when p_patch ? 'expense_date' then nullif(p_patch ->> 'expense_date', '')::date else x.expense_date end;
  v_ref := case when p_patch ? 'receipt_reference' then nullif(btrim(coalesce(p_patch ->> 'receipt_reference', '')), '')
                else x.receipt_reference end;
  select fa.currency into v_currency from public.financial_accounts fa where fa.id = v_account and fa.entity_id = x.entity_id;
  v_rate := case when p_patch ? 'exchange_rate' then nullif(p_patch ->> 'exchange_rate', '')::numeric
                 when v_currency is not distinct from x.currency then x.exchange_rate
                 else null end;
  v_currency := app_private.expense_check_header(x.entity_id, v_payee, v_name, v_account, v_date, v_rate, v_ref);

  if p_patch ? 'lines' then
    v_lines := p_patch -> 'lines';
  else
    select coalesce(jsonb_agg(jsonb_build_object(
        'description', l.description, 'quantity', l.quantity, 'unit_price', l.unit_price, 'treatment', l.treatment,
        'category_id', l.category_id, 'account_id', l.account_id, 'tax_amount', l.tax_amount,
        'wht_object', l.wht_object, 'vat_not_creditable', l.vat_not_creditable,
        'vat_invoice_ref', l.vat_invoice_ref) order by l.line_no), '[]'::jsonb)
      into v_lines
    from public.expense_lines l where l.expense_id = x.id;
  end if;
  v_prep := app_private.purchase_prepare_lines(x.entity_id, v_currency, v_lines);
  if length(btrim(coalesce(p_patch ->> 'notes', ''))) > 2000
     or length(btrim(coalesce(p_patch ->> 'internal_note', ''))) > 2000 then
    raise exception 'INVALID: the notes are limited to 2000 characters' using errcode = 'invalid_parameter_value';
  end if;

  update public.expenses
  set payee_id = v_payee, payee_name = v_name, financial_account_id = v_account, currency = v_currency,
      exchange_rate = v_rate, expense_date = v_date, receipt_reference = v_ref,
      notes = case when p_patch ? 'notes' then nullif(btrim(coalesce(p_patch ->> 'notes', '')), '') else notes end,
      internal_note = case when p_patch ? 'internal_note' then nullif(btrim(coalesce(p_patch ->> 'internal_note', '')), '')
                           else internal_note end,
      subtotal = (v_prep ->> 'subtotal')::numeric, tax_total = (v_prep ->> 'tax_total')::numeric,
      total = (v_prep ->> 'total')::numeric
  where id = x.id
  returning version into v_new_version;
  perform app_private.expense_write_lines(x.entity_id, x.id, v_prep);
  return v_new_version;
end
$$;

create or replace function public.correct_expense(p_expense uuid, p_key text, p_reason text, p_date date default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  x public.expenses%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_new uuid;
  v_lines jsonb;
  v_prep jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into x from public.expenses where id = p_expense;
  if not found or not app_authz.has_permission(x.entity_id, 'bills.void')
     or not app_authz.has_permission(x.entity_id, 'bills.create') then
    raise exception 'FORBIDDEN: correcting an expense needs bills.void and bills.create' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a correction needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into x from public.expenses where id = p_expense for update;
  v_replay := app_private.idem_begin('expense.correct', x.entity_id, p_key,
    md5(jsonb_build_object('x', p_expense, 'r', v_reason, 'd', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if x.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed expense can be corrected (now %)', x.status
      using errcode = 'integrity_constraint_violation';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'description', l.description, 'quantity', l.quantity, 'unit_price', l.unit_price, 'treatment', l.treatment,
      'category_id', l.category_id, 'account_id', l.account_id, 'tax_amount', l.tax_amount,
        'wht_object', l.wht_object, 'vat_not_creditable', l.vat_not_creditable,
        'vat_invoice_ref', l.vat_invoice_ref) order by l.line_no), '[]'::jsonb)
    into v_lines from public.expense_lines l where l.expense_id = x.id;
  v_prep := app_private.purchase_prepare_lines(x.entity_id, x.currency, v_lines, true);
  insert into public.expenses
    (entity_id, payee_id, payee_name, receipt_reference, financial_account_id, currency, exchange_rate, expense_date,
     notes, internal_note, subtotal, tax_total, total, replaces_expense_id)
  values
    (x.entity_id, x.payee_id, x.payee_name, x.receipt_reference, x.financial_account_id, x.currency, x.exchange_rate,
     x.expense_date, x.notes, left('Replaces ' || x.expense_number || ': ' || v_reason, 2000),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'tax_total')::numeric, (v_prep ->> 'total')::numeric, x.id)
  returning id into v_new;
  perform app_private.expense_write_lines(x.entity_id, v_new, v_prep);

  perform app_private.close_expense_core(p_expense, 'reversed', v_reason, p_date, v_new);
  perform app_private.idem_complete('expense.correct', x.entity_id, p_key, 'expenses', v_new);
  return v_new;
end
$$;

-- ------------------------------------------------------------ guards: what may change when the engine recognises a document

create or replace function app_private.tg_bill_lines_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
  v_resolved constant text[] := array['posted_account_id', 'base_amount', 'asset_link_status', 'wht_object',
                                       'tax_confirmed_by', 'tax_confirmed_at', 'updated_at', 'updated_by', 'version'];
begin
  select b.status into v_status from public.bills b
  where b.id = coalesce(new.bill_id, old.bill_id) and b.entity_id = coalesce(new.entity_id, old.entity_id)
  for share;
  if v_status = 'draft' then
    null;
  elsif v_status = 'submitted' and tg_op = 'UPDATE'
        and (to_jsonb(new) - v_resolved) is not distinct from (to_jsonb(old) - v_resolved) then
    null;
  else
    raise exception 'The lines of a % bill are frozen', coalesce(v_status, 'missing')
      using errcode = 'integrity_constraint_violation';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;

create or replace function app_private.tg_expense_lines_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
  v_resolved constant text[] := array['posted_account_id', 'base_amount', 'asset_link_status', 'wht_object',
                                       'tax_confirmed_by', 'tax_confirmed_at', 'updated_at', 'updated_by', 'version'];
begin
  select x.status into v_status from public.expenses x
  where x.id = coalesce(new.expense_id, old.expense_id) and x.entity_id = coalesce(new.entity_id, old.entity_id)
  for share;
  if v_status = 'draft' then
    null;
  elsif v_status = 'submitted' and tg_op = 'UPDATE'
        and (to_jsonb(new) - v_resolved) is not distinct from (to_jsonb(old) - v_resolved) then
    null;
  else
    raise exception 'The lines of a % expense are frozen', coalesce(v_status, 'missing')
      using errcode = 'integrity_constraint_violation';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;

create or replace function app_private.tg_bills_guard() returns trigger
language plpgsql as $$
declare
  v_base public.currency_code;
  v_state constant text[] := array['status', 'submitted_at', 'submitted_by', 'rejected_at', 'rejected_by',
                                    'reject_reason', 'updated_at', 'updated_by', 'version'];
  v_approve constant text[] := array['status', 'bill_number', 'journal_id', 'vendor_snapshot', 'base_total',
                                      'withheld_total', 'tax_status',
                                      'approved_at', 'approved_by', 'duplicate_ack_reason', 'submitted_at',
                                      'submitted_by', 'updated_at', 'updated_by', 'version'];
  v_close constant text[] := array['status', 'reversal_journal_id', 'closed_at', 'closed_by', 'closed_date',
                                    'closed_reason', 'replaced_by_bill_id', 'updated_at', 'updated_by', 'version'];
  v_live constant text[] := array['due_date', 'internal_note', 'updated_at', 'updated_by', 'version'];
  v_touch constant text[] := array['updated_at', 'updated_by', 'version'];
  v_mut text[];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'A bill starts as a draft' using errcode = 'integrity_constraint_violation';
    end if;
  else
    if old.status in ('cancelled', 'void') then
      raise exception 'A % bill cannot change any more', old.status using errcode = 'integrity_constraint_violation';
    end if;
    if new.status <> old.status
       and (old.status, new.status) not in
           (('draft', 'submitted'), ('draft', 'approved'), ('draft', 'cancelled'), ('submitted', 'draft'),
            ('submitted', 'approved'), ('submitted', 'cancelled'), ('approved', 'void')) then
      raise exception 'A bill cannot move from % to %', old.status, new.status
        using errcode = 'integrity_constraint_violation';
    end if;
    -- Whoever writes the row: a bill with money still allocated to it is never voided (the payment goes first).
    if new.status = 'void' and old.status = 'approved'
       and exists (select 1 from public.vendor_payment_allocations a where a.bill_id = old.id and a.status = 'active') then
      raise exception 'CONFLICT: this bill has active payment allocations; reverse those payments first'
        using errcode = 'integrity_constraint_violation';
    end if;
    v_mut := case
      when old.status = 'draft' and new.status = 'draft' then null
      when new.status = 'submitted' and old.status = 'draft' then v_state
      when new.status = 'submitted' and old.status = 'submitted' then v_touch
      when new.status = 'draft' then v_state
      when new.status = 'approved' and old.status in ('draft', 'submitted') then v_approve
      when new.status = 'approved' and old.status = 'approved' then v_live
      else v_close
    end;
    if v_mut is not null and (to_jsonb(new) - v_mut) is distinct from (to_jsonb(old) - v_mut) then
      raise exception 'A % bill is frozen; only its workflow fields may change', old.status
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;

  if new.status = 'draft' then
    v_base := app_private.entity_base_currency(new.entity_id);
    if (new.currency = v_base) <> (new.exchange_rate is null) then
      raise exception 'INVALID: a foreign-currency bill needs an exchange rate and a base-currency bill has none'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  return new;
end
$$;

create or replace function app_private.tg_expenses_guard() returns trigger
language plpgsql as $$
declare
  v_base public.currency_code;
  v_state constant text[] := array['status', 'submitted_at', 'submitted_by', 'rejected_at', 'rejected_by',
                                    'reject_reason', 'updated_at', 'updated_by', 'version'];
  v_confirm constant text[] := array['status', 'expense_number', 'journal_id', 'base_total', 'withheld_total',
                                      'tax_status', 'confirmed_at',
                                      'confirmed_by', 'duplicate_ack_reason', 'payee_snapshot', 'submitted_at',
                                      'submitted_by', 'updated_at', 'updated_by', 'version'];
  v_close constant text[] := array['status', 'reversal_journal_id', 'closed_at', 'closed_by', 'closed_date',
                                    'closed_reason', 'replaced_by_expense_id', 'updated_at', 'updated_by', 'version'];
  v_touch constant text[] := array['updated_at', 'updated_by', 'version'];
  v_mut text[];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'An expense starts as a draft' using errcode = 'integrity_constraint_violation';
    end if;
  else
    if old.status in ('cancelled', 'reversed') then
      raise exception 'A % expense cannot change any more', old.status using errcode = 'integrity_constraint_violation';
    end if;
    if new.status <> old.status
       and (old.status, new.status) not in
           (('draft', 'submitted'), ('draft', 'confirmed'), ('draft', 'cancelled'), ('submitted', 'draft'),
            ('submitted', 'confirmed'), ('submitted', 'cancelled'), ('confirmed', 'reversed')) then
      raise exception 'An expense cannot move from % to %', old.status, new.status
        using errcode = 'integrity_constraint_violation';
    end if;
    v_mut := case
      when old.status = 'draft' and new.status = 'draft' then null
      when new.status = 'submitted' and old.status = 'draft' then v_state
      when new.status = 'submitted' and old.status = 'submitted' then v_touch
      when new.status = 'draft' then v_state
      when new.status = 'confirmed' and old.status in ('draft', 'submitted') then v_confirm
      when new.status = 'confirmed' and old.status = 'confirmed' then v_touch
      else v_close
    end;
    if v_mut is not null and (to_jsonb(new) - v_mut) is distinct from (to_jsonb(old) - v_mut) then
      raise exception 'A % expense is frozen; only its workflow fields may change', old.status
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;

  if new.status = 'draft' then
    v_base := app_private.entity_base_currency(new.entity_id);
    if (new.currency = v_base) <> (new.exchange_rate is null) then
      raise exception 'INVALID: a foreign-currency expense needs an exchange rate and a base-currency expense has none'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  return new;
end
$$;
