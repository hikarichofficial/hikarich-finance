-- P7 (Step 15 §11) part 4: the tax determination is part of recognising a document.
-- Authority: Step 04 §9 (the accounting engine consumes the approved tax determination and posts the resulting tax
-- lines together with the source event), Step 05 §10-12 (withholding separated from the vendor's net settlement, VAT
-- on the tax ledger), Step 07 §3, §5, §6 (posting creates the tax determination together with the journal, exactly
-- once), Step 08 §10 (tax integrity), Step 13 §25 (money and rounding).
--
-- What changes
--   * ISSUING an invoice determines its output VAT first. The tax is added to the invoice total (the receivable
--     includes it), credited to Tax Payables, and never nets against revenue. A document that needs a tax review is
--     not issued.
--   * APPROVING a bill and CONFIRMING an expense determine input VAT and withholding first. Creditable input VAT is
--     debited to Tax Assets; VAT that is not creditable stays in the cost of its lines; the withholding is credited
--     to Tax Payables and lowers what is owed to the vendor (or paid from the account) while the gross expense is
--     unchanged (Step 05 §10, §15: withholding is never netted into the expense).
--   * The determination, its rule versions and its facts are stored with the journal, and the tax ledger accrues.
--   * VOIDING, CANCELLING or REVERSING a recognised document supersedes its determinations and reverses the tax
--     ledger in the period of the reversal.
--   * The payable of a bill is total - withheld_total: the AP sub-ledger, payment capacity and aging use it, so the
--     sub-ledger keeps reconciling to the General Ledger.
-- Documents dated before the Entity's engine start date behave exactly as before (no tax is recognised).

-- ------------------------------------------------------------ invoices
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
  if i.payment_account_id is not null then
    select * into fa from public.financial_accounts where id = i.payment_account_id;
    if i.payment_channel_id is not null then
      select * into ch from public.payment_channels where id = i.payment_channel_id;
    end if;
    v_payment := jsonb_build_object(
      'account_name', fa.name, 'institution_name', fa.institution_name, 'account_number', fa.account_number,
      'account_holder', fa.account_holder, 'currency', fa.currency, 'kind', fa.kind,
      'channel_name', ch.name, 'channel_kind', ch.method_kind);
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

-- ------------------------------------------------------------ bills
create or replace function app_private.approve_bill_core(p_bill uuid, p_duplicate_reason text) returns uuid
language plpgsql as $$
declare
  b public.bills%rowtype;
  e public.entities%rowtype;
  c public.contacts%rowtype;
  l record;
  d record;
  v_base public.currency_code;
  v_scale integer;
  v_today date;
  v_base_total numeric;
  v_weights numeric[];
  v_alloc numeric[];
  v_ap uuid;
  v_number text;
  v_desc text;
  v_journal uuid;
  v_lines jsonb := '[]'::jsonb;
  v_posted uuid;
  v_ack text := nullif(btrim(coalesce(p_duplicate_reason, '')), '');
  n integer := 0;
  k integer;
  v_eval jsonb;
  v_wht numeric := 0;
  v_credit numeric := 0;
  v_cost numeric := 0;
  v_base_sub numeric;
  v_tax_weights numeric[];
  v_cost_alloc numeric[];
begin
  select * into b from public.bills where id = p_bill;
  select * into e from public.entities where id = b.entity_id;
  v_base := e.base_currency;
  v_scale := app_private.currency_scale(v_base);
  v_today := app_private.entity_today(b.entity_id);

  if b.status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: only a draft or submitted bill can be approved (now %)', b.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if e.status <> 'active' then
    raise exception 'CONFLICT: the Entity is disabled' using errcode = 'integrity_constraint_violation';
  end if;
  if b.bill_date > v_today then
    raise exception 'INVALID: a bill dated in the future stays a draft until its date (Step 08 §14)'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.bill_check_header(b.entity_id, b.vendor_id, b.bill_date, b.due_date, b.currency, b.exchange_rate,
                                        b.vendor_reference);
  perform app_private.assert_period_postable(b.entity_id, b.bill_date);
  if not exists (select 1 from public.bill_lines where bill_id = b.id) then
    raise exception 'INVALID: a bill needs at least one line' using errcode = 'invalid_parameter_value';
  end if;
  if b.total <= 0 then
    raise exception 'INVALID: a zero-value bill cannot be approved (Step 08 §8)' using errcode = 'invalid_parameter_value';
  end if;
  -- The tax determination comes first (Step 04 §9, Step 05 §1). Unknown material facts stop the approval.
  v_eval := app_private.tax_evaluate('bill', b.id);
  if v_eval ->> 'engine' = 'active' then
    if v_eval ->> 'status' = 'needs_review' then
      raise exception 'CONFLICT: the tax determination of this bill needs review before it can be approved: %',
        v_eval -> 'reasons' ->> 0 using errcode = 'integrity_constraint_violation';
    end if;
    v_wht := (v_eval ->> 'withheld_total')::numeric;
    v_credit := (v_eval ->> 'vat_input_creditable')::numeric;
    v_cost := (v_eval ->> 'vat_input_cost')::numeric;
  elsif exists (select 1 from public.bill_lines where bill_id = b.id and tax_amount <> 0) or b.tax_total <> 0 then
    raise exception 'CONFLICT: tax is recognised only from the Entity''s tax-engine start date; nothing is guessed'
      using errcode = 'integrity_constraint_violation';
  end if;

  -- Every line must resolve to a valid account NOW (Step 08 §8: category/account mapping before recognition).
  for l in select * from public.bill_lines where bill_id = b.id order by line_no loop
    v_posted := app_private.resolve_purchase_account(b.entity_id, l.category_id, l.treatment, l.account_id, b.bill_date);
    if v_posted is null or not app_private.purchase_account_ok(b.entity_id, v_posted, l.treatment) then
      raise exception 'INVALID: line % has no usable % account; choose a category with a mapping or an account',
        l.line_no, l.treatment using errcode = 'invalid_parameter_value';
    end if;
  end loop;

  -- The same purchase must not be recognised twice (Step 08 §8/§17). A likely duplicate is refused unless the
  -- approver states why it is a different document.
  -- The party is locked first, so two concurrent approvals of the same purchase cannot both pass the check.
  perform app_private.lock_purchase_party(b.entity_id, b.vendor_id, null);
  select * into d from app_private.purchase_duplicates(
    b.entity_id, 'bill', b.vendor_id, null, b.vendor_reference, b.bill_date, b.currency, b.total, b.id)
    where severity = 'exact' limit 1;
  if found then
    if v_ack is null or length(v_ack) < 5 then
      raise exception 'CONFLICT: this looks like a duplicate of % % (%); approve again with a reason if it is a different document',
        d.doc_kind, coalesce(d.doc_number, d.doc_id::text), d.reason using errcode = 'integrity_constraint_violation';
    end if;
  else
    v_ack := null;
  end if;

  -- Base-currency values: the payable is the total converted once; the debit side is spread over the lines with
  -- the largest-remainder method so the journal balances to the cent (Step 04 §14).
  if b.currency = v_base then
    v_base_total := b.total;
  else
    v_base_total := app_private.round_amount(b.total * b.exchange_rate, v_scale, 'half_up');
  end if;
  if v_base_total <= 0 then
    raise exception 'INVALID: the bill is too small to book in %', v_base using errcode = 'invalid_parameter_value';
  end if;
  -- The debit side is the cost of each line: its amount before VAT, plus the VAT that is not creditable. Creditable
  -- input VAT is a separate debit to Tax Assets.
  v_base_sub := v_base_total - v_credit - v_cost;
  select array_agg(line_subtotal order by line_no) into v_weights from public.bill_lines where bill_id = b.id;
  v_alloc := app_private.allocate_amount(v_base_sub, v_weights, v_scale);
  if v_cost > 0 then
    select array_agg(tax_amount order by line_no) into v_tax_weights from public.bill_lines where bill_id = b.id;
    v_cost_alloc := app_private.allocate_amount(v_cost, v_tax_weights, v_scale);
    for k in 1..array_length(v_alloc, 1) loop
      v_alloc[k] := v_alloc[k] + v_cost_alloc[k];
    end loop;
  end if;

  select * into c from public.contacts where id = b.vendor_id and entity_id = b.entity_id;
  select a.id into v_ap from public.ledger_accounts a
  where a.entity_id = b.entity_id and a.system_key = 'ACCOUNTS_PAYABLE' and a.status = 'active';
  if v_ap is null then
    raise exception 'CONFLICT: this Entity has no Accounts Payable account' using errcode = 'integrity_constraint_violation';
  end if;

  perform app_private.ensure_purchase_numbering(b.entity_id);
  v_number := app_private.allocate_document_number(b.entity_id, 'bill', b.bill_date);
  v_desc := format('Bill %s - %s%s', v_number, c.display_name,
                   case when b.vendor_reference is null then '' else ' (' || b.vendor_reference || ')' end);

  n := 0;
  for l in select * from public.bill_lines where bill_id = b.id order by line_no loop
    n := n + 1;
    v_posted := app_private.resolve_purchase_account(b.entity_id, l.category_id, l.treatment, l.account_id, b.bill_date);
    update public.bill_lines
    set posted_account_id = v_posted, base_amount = v_alloc[n],
        asset_link_status = case when l.treatment = 'asset' then 'pending' else 'none' end
    where id = l.id;
    v_lines := app_private.add_line(v_lines, v_posted, v_alloc[n], 0, left(l.description, 200) || ' (' || v_number || ')',
      app_private.orig_fields(b.currency, v_base, l.line_total, b.exchange_rate, v_alloc[n]));
  end loop;
  if v_credit > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_key', 'TAX_ASSET', 'debit', v_credit, 'credit', 0, 'description', 'Input VAT: ' || v_desc);
  end if;
  -- What the vendor is owed is the total less the income tax withheld; the withholding is a liability to the tax office.
  v_lines := app_private.add_line(v_lines, v_ap, 0, v_base_total - v_wht, v_desc,
    app_private.orig_fields(b.currency, v_base, b.total, b.exchange_rate, v_base_total - v_wht));
  if v_wht > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_key', 'TAX_PAYABLE', 'debit', 0, 'credit', v_wht, 'description', 'PPh 23 withheld: ' || v_desc);
  end if;

  v_journal := app_private.post_system_journal(
    b.entity_id, 'bill', b.id, 'bill.approve', 'bill.v1', b.bill_date, v_desc, v_lines);
  perform app_private.tax_record_results('bill', b.id, v_eval, v_journal, v_desc);

  update public.bills
  set status = 'approved', bill_number = v_number, journal_id = v_journal, approved_at = now(), approved_by = auth.uid(),
      base_total = v_base_total - v_wht, withheld_total = v_wht,
      tax_status = case when v_eval ->> 'engine' = 'active' then 'determined' else tax_status end,
      duplicate_ack_reason = left(v_ack, 1000),
      vendor_snapshot = jsonb_build_object(
        'display_name', c.display_name, 'legal_name', c.legal_name, 'email', c.email, 'phone', c.phone,
        'address_line', c.address_line, 'city', c.city, 'country_code', c.country_code)
  where id = b.id;

  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (b.entity_id, 'BillApproved', 'bill', b.id,
          jsonb_build_object('bill_number', v_number, 'total', b.total, 'currency', b.currency));
  return v_journal;
end
$$;

-- The payable of a bill is its total less the income tax withheld from the vendor.
create or replace function app_private.tg_vendor_allocations_capacity() returns trigger
language plpgsql as $$
declare
  b public.bills%rowtype;
  pay public.vendor_payments%rowtype;
  v_amount numeric;
  v_base numeric;
begin
  select * into b from public.bills where id = new.bill_id and entity_id = new.entity_id for update;
  if not found or b.status <> 'approved' then
    raise exception 'CONFLICT: only an approved bill can receive an allocation' using errcode = 'integrity_constraint_violation';
  end if;
  -- The payment and the bill must agree on who is paid, in what currency, and the allocation on the payment's date.
  select * into pay from public.vendor_payments where id = new.payment_id and entity_id = new.entity_id;
  if not found or pay.vendor_id <> b.vendor_id or pay.currency <> b.currency or pay.payment_date <> new.allocation_date then
    raise exception 'CONFLICT: the allocation does not match its payment (vendor, currency or date)'
      using errcode = 'integrity_constraint_violation';
  end if;
  select coalesce(sum(a.amount), 0), coalesce(sum(a.base_ap_amount), 0) into v_amount, v_base
  from public.vendor_payment_allocations a where a.bill_id = new.bill_id and a.status = 'active';
  if v_amount + new.amount > b.total - b.withheld_total or v_base + new.base_ap_amount > b.base_total then
    raise exception 'CONFLICT: the allocation exceeds what is outstanding on bill %', b.bill_number
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;

create or replace function app_private.bill_positions(p_entity uuid, p_as_of date default null)
returns table (
  bill_id uuid, bill_number text, vendor_id uuid, vendor_reference text, currency public.currency_code, status text,
  bill_date date, due_date date, total numeric, settled numeric, outstanding numeric, base_total numeric,
  base_settled numeric, base_outstanding numeric, settlement_status text, is_overdue boolean, days_overdue integer)
language plpgsql stable as $$
declare
  v_asof date := coalesce(p_as_of, app_private.entity_today(p_entity));
begin
  return query
  with base as (
    select b.*,
           (b.status = 'void' and b.closed_date <= v_asof) as is_closed,
           s.settled as s_settled, s.base_settled as s_base_settled
    from public.bills b
    cross join lateral app_private.bill_settled(b.id, v_asof) s
    where b.entity_id = p_entity and b.bill_number is not null and b.bill_date <= v_asof
  )
  select b.id, b.bill_number, b.vendor_id, b.vendor_reference, b.currency,
         case when b.status = 'void' and not b.is_closed then 'approved' else b.status end,
         b.bill_date, b.due_date, (b.total - b.withheld_total)::numeric, b.s_settled,
         case when b.is_closed then 0 else (b.total - b.withheld_total) - b.s_settled end,
         b.base_total::numeric, b.s_base_settled,
         case when b.is_closed then 0 else b.base_total - b.s_base_settled end,
         case when b.is_closed then null
              when (b.total - b.withheld_total) - b.s_settled = 0 then 'paid'
              when b.s_settled = 0 then 'unpaid'
              else 'partial' end,
         (not b.is_closed and (b.total - b.withheld_total) - b.s_settled > 0 and b.due_date < v_asof),
         case when not b.is_closed and (b.total - b.withheld_total) - b.s_settled > 0 and b.due_date < v_asof then v_asof - b.due_date else 0 end
  from base b;
end
$$;

create or replace function public.record_vendor_payment(
  p_entity uuid, p_key text, p_vendor uuid, p_account uuid, p_date date, p_amount numeric, p_allocations jsonb,
  p_rate numeric default null, p_reference text default null, p_channel uuid default null, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  fa public.financial_accounts%rowtype;
  c public.contacts%rowtype;
  r record;
  v_replay uuid;
  v_base public.currency_code;
  v_bscale integer;
  v_ascale integer;
  v_today date;
  v_ids uuid[] := '{}';
  v_amts numeric[] := '{}';
  v_elem jsonb;
  v_id uuid;
  v_amt numeric;
  v_n integer := 0;
  v_rem_amount numeric;
  v_rem_base numeric;
  v_settled numeric;
  v_base_settled numeric;
  v_last_rev date;
  v_alloc_bills uuid[] := '{}';
  v_alloc_amts numeric[] := '{}';
  v_alloc_bases numeric[] := '{}';
  v_alloc_sum numeric := 0;
  v_ap_sum numeric := 0;
  v_base_ap numeric;
  v_cash_base numeric;
  v_fx numeric := 0;
  v_ap uuid;
  v_fx_acct uuid;
  v_payment uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  k integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.pay') then
    raise exception 'FORBIDDEN: missing bills.pay' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('vendor_payment.record', p_entity, p_key,
    md5(jsonb_build_object('vendor', p_vendor, 'account', p_account, 'date', p_date, 'amount', p_amount,
                           'alloc', p_allocations, 'rate', p_rate, 'ref', p_reference, 'channel', p_channel,
                           'note', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform app_private.assert_maker_checker(p_entity, 'bills', 'pay',
                                           app_private.approval_base_amount(p_entity, p_amount, p_rate), auth.uid(),
                                           'pay this bill');

  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_base := e.base_currency;
  v_bscale := app_private.currency_scale(v_base);
  v_today := app_private.entity_today(p_entity);

  select * into c from public.contacts where id = p_vendor and entity_id = p_entity;
  if not found or c.kind not in ('vendor', 'both') then
    raise exception 'INVALID: the payee is unknown or is not a vendor of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
  if not found or not fa.is_active then
    raise exception 'INVALID: the paying account is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;
  v_ascale := app_private.currency_scale(fa.currency);

  perform app_private.assert_business_date(p_date);
  if p_date > v_today then
    raise exception 'INVALID: a payment cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_amount is null or not app_private.is_finite(p_amount) or p_amount <= 0 or p_amount >= 10::numeric ^ 13
     or app_private.round_amount(p_amount, v_ascale, 'down') <> p_amount then
    raise exception 'INVALID: the payment amount must be positive and allows % decimals for %', v_ascale, fa.currency
      using errcode = 'invalid_parameter_value';
  end if;
  if (fa.currency = v_base) <> (p_rate is null) then
    raise exception 'INVALID: an exchange rate is required for a foreign-currency account, and only then'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_rate is not null and (not app_private.is_finite(p_rate) or p_rate <= 0 or p_rate >= 10::numeric ^ 10
                             or app_private.round_amount(p_rate, 10, 'down') <> p_rate) then
    raise exception 'INVALID: the exchange rate must be positive with at most 10 decimals' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(v_ref, '')) > 200 or length(coalesce(v_note, '')) > 1000 then
    raise exception 'INVALID: the reference is limited to 200 and the note to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_channel is not null and not exists (
       select 1 from public.payment_channels ch where ch.id = p_channel and ch.entity_id = p_entity and ch.is_active) then
    raise exception 'INVALID: the payment channel is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;

  -- Parse the allocation list.
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' or jsonb_array_length(p_allocations) = 0 then
    raise exception 'INVALID: a vendor payment needs at least one bill to pay' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_allocations) > 100 then
    raise exception 'INVALID: a payment can be allocated to at most 100 bills' using errcode = 'invalid_parameter_value';
  end if;
  for v_elem in select value from jsonb_array_elements(p_allocations) loop
    v_n := v_n + 1;
    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'INVALID: allocation % is not an object', v_n using errcode = 'invalid_parameter_value';
    end if;
    begin
      v_id := (v_elem ->> 'bill_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'INVALID: allocation % has an invalid bill', v_n using errcode = 'invalid_parameter_value';
    end;
    if v_id is null then
      raise exception 'INVALID: allocation % needs a bill', v_n using errcode = 'invalid_parameter_value';
    end if;
    if v_id = any (v_ids) then
      raise exception 'INVALID: a bill can appear only once in the allocations' using errcode = 'invalid_parameter_value';
    end if;
    v_amt := app_private.parse_amount(v_elem ->> 'amount', format('allocation %s amount', v_n));
    if v_amt <= 0 or app_private.round_amount(v_amt, v_ascale, 'down') <> v_amt then
      raise exception 'INVALID: allocation % must be positive and allows % decimals for %', v_n, v_ascale, fa.currency
        using errcode = 'invalid_parameter_value';
    end if;
    v_ids := v_ids || v_id;
    v_amts := v_amts || v_amt;
  end loop;

  -- Lock the bills in a fixed order (two payments over the same bills can never deadlock), then validate and
  -- split each allocation against what is outstanding NOW.
  v_n := 0;
  for r in
    select b.id, b.bill_number, b.status, b.vendor_id, b.currency, b.bill_date, b.total - b.withheld_total as total, b.base_total, b.exchange_rate,
           x.amt
    from public.bills b
    join unnest(v_ids, v_amts) as x(id, amt) on x.id = b.id
    where b.entity_id = p_entity
    order by b.id
    for update of b
  loop
    v_n := v_n + 1;
    if r.status <> 'approved' then
      raise exception 'CONFLICT: bill % is % and cannot be paid', coalesce(r.bill_number, 'a draft'), r.status
        using errcode = 'integrity_constraint_violation';
    end if;
    if r.vendor_id <> p_vendor then
      raise exception 'INVALID: bill % belongs to a different vendor', r.bill_number using errcode = 'invalid_parameter_value';
    end if;
    if r.currency <> fa.currency then
      raise exception 'INVALID: bill % is in % but the paying account is in %', r.bill_number, r.currency, fa.currency
        using errcode = 'invalid_parameter_value';
    end if;
    if p_date < r.bill_date then
      raise exception 'INVALID: the payment date is before the date of bill %', r.bill_number
        using errcode = 'invalid_parameter_value';
    end if;
    -- A payment cannot be dated before a reversal on the same bill: between the two dates the earlier payment
    -- and the new one would both count, and the payable would go negative as of those days.
    select max(x.reversed_date) into v_last_rev
    from public.vendor_payment_allocations x where x.bill_id = r.id and x.status = 'reversed';
    if v_last_rev is not null and p_date < v_last_rev then
      raise exception 'INVALID: bill % had a payment reversed on %; a new payment cannot be dated before that',
        r.bill_number, v_last_rev using errcode = 'invalid_parameter_value';
    end if;
    select s.settled, s.base_settled into v_settled, v_base_settled from app_private.bill_settled(r.id) s;
    v_rem_amount := r.total - v_settled;
    v_rem_base := r.base_total - v_base_settled;
    if r.amt > v_rem_amount then
      raise exception 'INVALID: the allocation of % exceeds what is outstanding (%) on bill %', r.amt, v_rem_amount, r.bill_number
        using errcode = 'invalid_parameter_value';
    end if;
    v_base_ap := app_private.prorate_remaining(v_rem_amount, v_rem_base, r.amt, v_bscale);
    v_alloc_bills := v_alloc_bills || r.id;
    v_alloc_amts := v_alloc_amts || r.amt;
    v_alloc_bases := v_alloc_bases || v_base_ap;
    v_alloc_sum := v_alloc_sum + r.amt;
    v_ap_sum := v_ap_sum + v_base_ap;
  end loop;
  if v_n <> coalesce(array_length(v_ids, 1), 0) then
    raise exception 'INVALID: a bill in the allocations does not exist in this Entity' using errcode = 'invalid_parameter_value';
  end if;
  if v_alloc_sum <> p_amount then
    raise exception 'INVALID: the payment (%) must equal the sum of its allocations (%); vendor advances are not supported',
      p_amount, v_alloc_sum using errcode = 'invalid_parameter_value';
  end if;

  v_cash_base := case when fa.currency = v_base then p_amount else app_private.round_amount(p_amount * p_rate, v_bscale, 'half_up') end;
  if v_cash_base <= 0 then
    raise exception 'INVALID: the payment is too small to book in %', v_base using errcode = 'invalid_parameter_value';
  end if;
  -- Payable relieved minus cash paid: a positive difference is a gain (we paid less base value than was booked).
  v_fx := v_ap_sum - v_cash_base;
  perform app_private.assert_fx_reasonable(v_fx, v_cash_base);
  if v_fx <> 0 then
    v_fx_acct := app_private.fx_account(p_entity);
    if v_fx_acct is null then
      raise exception 'CONFLICT: this Entity has no FX gain/loss account' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  select a.id into v_ap from public.ledger_accounts a
  where a.entity_id = p_entity and a.system_key = 'ACCOUNTS_PAYABLE' and a.status = 'active';
  if v_ap is null then
    raise exception 'CONFLICT: this Entity has no Accounts Payable account' using errcode = 'integrity_constraint_violation';
  end if;

  -- Lock order everywhere: bills, then the payment, then the paying account, then the numbering and journal
  -- counters. The account lock is taken before the counters (reversals already do), so a payment and a reversal on
  -- the same account can never wait on each other.
  perform 1 from public.financial_accounts where id = p_account and entity_id = p_entity for no key update;
  perform app_private.ensure_purchase_numbering(p_entity);
  v_number := app_private.allocate_document_number(p_entity, 'bill_payment', p_date);
  v_desc := format('Vendor payment %s - %s', v_number, c.display_name);

  for k in 1 .. array_length(v_alloc_bills, 1) loop
    select b.bill_number, b.exchange_rate, b.currency into r from public.bills b where b.id = v_alloc_bills[k];
    v_lines := app_private.add_line(v_lines, v_ap, v_alloc_bases[k], 0, v_desc || ' / ' || r.bill_number,
      app_private.orig_fields(r.currency, v_base, v_alloc_amts[k], r.exchange_rate, v_alloc_bases[k]));
  end loop;
  v_lines := app_private.add_line(v_lines, fa.ledger_account_id, 0, v_cash_base, v_desc,
    app_private.orig_fields(fa.currency, v_base, p_amount, p_rate, v_cash_base));
  v_lines := app_private.add_line(v_lines, v_fx_acct, case when v_fx < 0 then -v_fx else 0 end,
    case when v_fx > 0 then v_fx else 0 end, 'FX difference: ' || v_desc);

  v_journal := app_private.post_system_journal(
    p_entity, 'vendor_payment', v_payment, 'vendor_payment.confirm', 'vendor_payment.v1', p_date, v_desc, v_lines);
  perform app_private.record_movement(p_entity, p_account, 'out', p_amount, v_cash_base, p_rate, p_date,
    'vendor_payment', v_payment, 'principal', v_journal, v_desc);

  insert into public.vendor_payments
    (id, entity_id, payment_number, vendor_id, financial_account_id, currency, amount, exchange_rate, base_amount,
     payment_date, reference, payment_channel_id, note, fx_difference, journal_id)
  values
    (v_payment, p_entity, v_number, p_vendor, p_account, fa.currency, p_amount, p_rate, v_cash_base, p_date, v_ref,
     p_channel, v_note, v_fx, v_journal);
  for k in 1 .. array_length(v_alloc_bills, 1) loop
    insert into public.vendor_payment_allocations
      (entity_id, payment_id, bill_id, amount, base_ap_amount, allocation_date, journal_id)
    values (p_entity, v_payment, v_alloc_bills[k], v_alloc_amts[k], v_alloc_bases[k], p_date, v_journal);
  end loop;

  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_entity, 'VendorPaymentConfirmed', 'vendor_payment', v_payment,
          jsonb_build_object('payment_number', v_number, 'amount', p_amount, 'currency', fa.currency));
  perform app_private.idem_complete('vendor_payment.record', p_entity, p_key, 'vendor_payments', v_payment);
  return v_payment;
end
$$;

create or replace function app_private.close_bill_core(
  p_bill uuid, p_target text, p_reason text, p_date date, p_replacement uuid default null)
returns void
language plpgsql as $$
declare
  b public.bills%rowtype;
  v_today date;
  v_date date;
  v_rev uuid;
  v_n bigint;
  v_min date;
begin
  select * into b from public.bills where id = p_bill;
  v_today := app_private.entity_today(b.entity_id);
  v_date := coalesce(p_date, v_today);
  perform set_config('app.audit_reason', p_reason, true);

  if b.status in ('draft', 'submitted') then
    if p_target <> 'cancelled' then
      raise exception 'INVALID: a bill that is not approved is cancelled, not voided' using errcode = 'invalid_parameter_value';
    end if;
    update public.bills
    set status = 'cancelled', closed_at = now(), closed_by = auth.uid(), closed_date = v_today, closed_reason = p_reason,
        replaced_by_bill_id = p_replacement
    where id = b.id;
    return;
  end if;

  if b.status <> 'approved' then
    raise exception 'CONFLICT: the bill is already %', b.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_target <> 'void' then
    raise exception 'INVALID: an approved bill is voided, not cancelled' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(v_date);
  if v_date > v_today then
    raise exception 'INVALID: the date cannot be in the future' using errcode = 'invalid_parameter_value';
  end if;
  select count(*) into v_n from public.vendor_payment_allocations a where a.bill_id = b.id and a.status = 'active';
  if v_n > 0 then
    raise exception 'CONFLICT: this bill has % active payment allocation(s); reverse those payments first', v_n
      using errcode = 'integrity_constraint_violation';
  end if;
  if exists (select 1 from public.bill_lines l where l.bill_id = b.id and l.asset_link_status = 'linked') then
    raise exception 'CONFLICT: a line of this bill is registered as a fixed asset; deal with the asset first'
      using errcode = 'integrity_constraint_violation';
  end if;
  -- Voiding is dated after every payment and reversal on the bill, so the payable never goes negative on any day
  -- in between (the sub-ledger and the ledger agree as of every date).
  select greatest(b.bill_date, coalesce(max(a.allocation_date), b.bill_date), coalesce(max(a.reversed_date), b.bill_date))
    into v_min from public.vendor_payment_allocations a where a.bill_id = b.id;
  if v_date < v_min then
    raise exception 'INVALID: the date cannot be before the last payment activity on this bill (%)', v_min
      using errcode = 'invalid_parameter_value';
  end if;

  v_rev := app_private.reverse_journal_core(b.journal_id, v_date, p_reason);
  perform app_private.tax_reverse_source('bill', b.id, v_rev, v_date, p_reason);
  update public.bills
  set status = 'void', reversal_journal_id = v_rev, closed_at = now(), closed_by = auth.uid(), closed_date = v_date,
      closed_reason = p_reason, replaced_by_bill_id = p_replacement
  where id = b.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (b.entity_id, 'BillVoided', 'bill', b.id, jsonb_build_object('bill_number', b.bill_number));
end
$$;

create or replace function app_private.close_invoice_core(
  p_invoice uuid, p_target text, p_reason text, p_date date, p_replacement uuid default null)
returns void
language plpgsql as $$
declare
  i public.invoices%rowtype;
  v_today date;
  v_date date;
  v_rev uuid;
  v_n bigint;
  v_min date;
begin
  select * into i from public.invoices where id = p_invoice;
  v_today := app_private.entity_today(i.entity_id);
  v_date := coalesce(p_date, v_today);
  perform set_config('app.audit_reason', p_reason, true);

  if i.status = 'draft' then
    if p_target <> 'cancelled' then
      raise exception 'INVALID: a draft invoice is cancelled, not voided' using errcode = 'invalid_parameter_value';
    end if;
    update public.invoices
    set status = 'cancelled', closed_at = now(), closed_by = auth.uid(), closed_date = v_today, closed_reason = p_reason,
        replaced_by_invoice_id = p_replacement
    where id = i.id;
    return;
  end if;

  if i.status <> 'issued' then
    raise exception 'CONFLICT: the invoice is already %', i.status using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(v_date);
  if v_date > v_today then
    raise exception 'INVALID: the date cannot be in the future' using errcode = 'invalid_parameter_value';
  end if;
  select count(*) into v_n from public.payment_allocations a where a.invoice_id = i.id and a.status = 'active';
  if v_n > 0 then
    raise exception 'CONFLICT: this invoice has % active payment allocation(s); reverse those payments first', v_n
      using errcode = 'integrity_constraint_violation';
  end if;
  -- Closing is dated after every payment and reversal on the invoice, so the receivable never goes negative on
  -- any day in between (the sub-ledger and the ledger agree as of every date).
  select greatest(i.issue_date, coalesce(max(a.allocation_date), i.issue_date), coalesce(max(a.reversed_date), i.issue_date))
    into v_min from public.payment_allocations a where a.invoice_id = i.id;
  if v_date < v_min then
    raise exception 'INVALID: the date cannot be before the last payment activity on this invoice (%)', v_min
      using errcode = 'invalid_parameter_value';
  end if;

  v_rev := app_private.reverse_journal_core(i.journal_id, v_date, p_reason);
  perform app_private.tax_reverse_source('invoice', i.id, v_rev, v_date, p_reason);
  update public.invoice_public_links
  set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), revoked_reason = 'invoice ' || p_target
  where invoice_id = i.id and status = 'active';
  update public.payment_submissions
  set status = 'rejected', review_reason = 'The invoice was ' || p_target, reviewed_by = auth.uid(), reviewed_at = now()
  where invoice_id = i.id and status = 'pending';
  update public.invoices
  set status = p_target, reversal_journal_id = v_rev, closed_at = now(), closed_by = auth.uid(), closed_date = v_date,
      closed_reason = p_reason, replaced_by_invoice_id = p_replacement
  where id = i.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (i.entity_id, case p_target when 'void' then 'InvoiceVoided' else 'InvoiceCancelled' end, 'invoice', i.id,
          jsonb_build_object('invoice_number', i.invoice_number));
end
$$;

create or replace function app_private.close_expense_core(
  p_expense uuid, p_target text, p_reason text, p_date date, p_replacement uuid default null)
returns void
language plpgsql as $$
declare
  x public.expenses%rowtype;
  m public.money_movements%rowtype;
  v_today date;
  v_date date;
  v_rev uuid;
begin
  select * into x from public.expenses where id = p_expense;
  v_today := app_private.entity_today(x.entity_id);
  v_date := coalesce(p_date, v_today);
  perform set_config('app.audit_reason', p_reason, true);

  if x.status in ('draft', 'submitted') then
    if p_target <> 'cancelled' then
      raise exception 'INVALID: an expense that is not confirmed is cancelled, not reversed' using errcode = 'invalid_parameter_value';
    end if;
    update public.expenses
    set status = 'cancelled', closed_at = now(), closed_by = auth.uid(), closed_date = v_today, closed_reason = p_reason,
        replaced_by_expense_id = p_replacement
    where id = x.id;
    return;
  end if;

  if x.status <> 'confirmed' then
    raise exception 'CONFLICT: the expense is already %', x.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_target <> 'reversed' then
    raise exception 'INVALID: a confirmed expense is reversed, not cancelled' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(v_date);
  if v_date > v_today then
    raise exception 'INVALID: the date cannot be in the future' using errcode = 'invalid_parameter_value';
  end if;
  if v_date < x.expense_date then
    raise exception 'INVALID: a reversal cannot be dated before the expense' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.expense_lines l where l.expense_id = x.id and l.asset_link_status = 'linked') then
    raise exception 'CONFLICT: a line of this expense is registered as a fixed asset; deal with the asset first'
      using errcode = 'integrity_constraint_violation';
  end if;
  perform 1 from public.financial_accounts where id = x.financial_account_id and entity_id = x.entity_id for no key update;

  v_rev := app_private.reverse_journal_core(x.journal_id, v_date, p_reason);
  perform app_private.tax_reverse_source('expense', x.id, v_rev, v_date, p_reason);
  for m in
    select * from public.money_movements
    where entity_id = x.entity_id and source_type = 'expense' and source_id = x.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(
      x.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, v_date, 'expense', x.id, m.component, v_rev,
      'Reversal: ' || p_reason, m.id);
  end loop;
  update public.expenses
  set status = 'reversed', reversal_journal_id = v_rev, closed_at = now(), closed_by = auth.uid(), closed_date = v_date,
      closed_reason = p_reason, replaced_by_expense_id = p_replacement
  where id = x.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (x.entity_id, 'ExpenseReversed', 'expense', x.id, jsonb_build_object('expense_number', x.expense_number));
end
$$;

-- ------------------------------------------------------------ expenses
create or replace function app_private.confirm_expense_core(p_expense uuid, p_duplicate_reason text) returns uuid
language plpgsql as $$
declare
  x public.expenses%rowtype;
  e public.entities%rowtype;
  fa public.financial_accounts%rowtype;
  c public.contacts%rowtype;
  l record;
  d record;
  v_base public.currency_code;
  v_scale integer;
  v_today date;
  v_base_total numeric;
  v_weights numeric[];
  v_alloc numeric[];
  v_number text;
  v_desc text;
  v_who text;
  v_journal uuid;
  v_lines jsonb := '[]'::jsonb;
  v_posted uuid;
  v_ack text := nullif(btrim(coalesce(p_duplicate_reason, '')), '');
  n integer := 0;
  k integer;
  v_eval jsonb;
  v_wht numeric := 0;
  v_credit numeric := 0;
  v_cost numeric := 0;
  v_base_sub numeric;
  v_tax_weights numeric[];
  v_cost_alloc numeric[];
begin
  select * into x from public.expenses where id = p_expense;
  select * into e from public.entities where id = x.entity_id;
  v_base := e.base_currency;
  v_scale := app_private.currency_scale(v_base);
  v_today := app_private.entity_today(x.entity_id);

  if x.status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: only a draft or submitted expense can be confirmed (now %)', x.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if e.status <> 'active' then
    raise exception 'CONFLICT: the Entity is disabled' using errcode = 'integrity_constraint_violation';
  end if;
  if x.expense_date > v_today then
    raise exception 'INVALID: an expense dated in the future stays a draft until its date (Step 08 §14)'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.expense_check_header(x.entity_id, x.payee_id, x.payee_name, x.financial_account_id, x.expense_date,
                                           x.exchange_rate, x.receipt_reference);
  perform app_private.assert_period_postable(x.entity_id, x.expense_date);
  if not exists (select 1 from public.expense_lines where expense_id = x.id) then
    raise exception 'INVALID: an expense needs at least one line' using errcode = 'invalid_parameter_value';
  end if;
  if x.total <= 0 then
    raise exception 'INVALID: a zero-value expense cannot be confirmed (Step 08 §8)' using errcode = 'invalid_parameter_value';
  end if;
  -- The tax determination comes first (Step 04 §9, Step 05 §1). Unknown material facts stop the confirmation.
  v_eval := app_private.tax_evaluate('expense', x.id);
  if v_eval ->> 'engine' = 'active' then
    if v_eval ->> 'status' = 'needs_review' then
      raise exception 'CONFLICT: the tax determination of this expense needs review before it can be confirmed: %',
        v_eval -> 'reasons' ->> 0 using errcode = 'integrity_constraint_violation';
    end if;
    v_wht := (v_eval ->> 'withheld_total')::numeric;
    v_credit := (v_eval ->> 'vat_input_creditable')::numeric;
    v_cost := (v_eval ->> 'vat_input_cost')::numeric;
  elsif exists (select 1 from public.expense_lines where expense_id = x.id and tax_amount <> 0) or x.tax_total <> 0 then
    raise exception 'CONFLICT: tax is recognised only from the Entity''s tax-engine start date; nothing is guessed'
      using errcode = 'integrity_constraint_violation';
  end if;

  for l in select * from public.expense_lines where expense_id = x.id order by line_no loop
    v_posted := app_private.resolve_purchase_account(x.entity_id, l.category_id, l.treatment, l.account_id, x.expense_date);
    if v_posted is null or not app_private.purchase_account_ok(x.entity_id, v_posted, l.treatment) then
      raise exception 'INVALID: line % has no usable % account; choose a category with a mapping or an account',
        l.line_no, l.treatment using errcode = 'invalid_parameter_value';
    end if;
  end loop;

  perform app_private.lock_purchase_party(x.entity_id, x.payee_id, x.payee_name);
  select * into d from app_private.purchase_duplicates(
    x.entity_id, 'expense', x.payee_id, x.payee_name, x.receipt_reference, x.expense_date, x.currency, x.total, x.id)
    where severity = 'exact' limit 1;
  if found then
    if v_ack is null or length(v_ack) < 5 then
      raise exception 'CONFLICT: this looks like a duplicate of % % (%); confirm again with a reason if it is a different document',
        d.doc_kind, coalesce(d.doc_number, d.doc_id::text), d.reason using errcode = 'integrity_constraint_violation';
    end if;
  else
    v_ack := null;
  end if;

  select * into fa from public.financial_accounts where id = x.financial_account_id and entity_id = x.entity_id;
  if x.currency = v_base then
    v_base_total := x.total;
  else
    v_base_total := app_private.round_amount(x.total * x.exchange_rate, v_scale, 'half_up');
  end if;
  if v_base_total <= 0 then
    raise exception 'INVALID: the expense is too small to book in %', v_base using errcode = 'invalid_parameter_value';
  end if;
  -- The debit side is the cost of each line: its amount before VAT, plus the VAT that is not creditable. Creditable
  -- input VAT is a separate debit to Tax Assets.
  v_base_sub := v_base_total - v_credit - v_cost;
  select array_agg(line_subtotal order by line_no) into v_weights from public.expense_lines where expense_id = x.id;
  v_alloc := app_private.allocate_amount(v_base_sub, v_weights, v_scale);
  if v_cost > 0 then
    select array_agg(tax_amount order by line_no) into v_tax_weights from public.expense_lines where expense_id = x.id;
    v_cost_alloc := app_private.allocate_amount(v_cost, v_tax_weights, v_scale);
    for k in 1..array_length(v_alloc, 1) loop
      v_alloc[k] := v_alloc[k] + v_cost_alloc[k];
    end loop;
  end if;

  v_who := coalesce((select co.display_name from public.contacts co where co.id = x.payee_id and co.entity_id = x.entity_id),
                    x.payee_name);
  -- Lock order: the paying account before the numbering and journal counters (see record_vendor_payment).
  perform 1 from public.financial_accounts where id = x.financial_account_id and entity_id = x.entity_id for no key update;
  perform app_private.ensure_purchase_numbering(x.entity_id);
  v_number := app_private.allocate_document_number(x.entity_id, 'expense', x.expense_date);
  v_desc := format('Expense %s - %s%s', v_number, v_who,
                   case when x.receipt_reference is null then '' else ' (' || x.receipt_reference || ')' end);

  for l in select * from public.expense_lines where expense_id = x.id order by line_no loop
    n := n + 1;
    v_posted := app_private.resolve_purchase_account(x.entity_id, l.category_id, l.treatment, l.account_id, x.expense_date);
    update public.expense_lines
    set posted_account_id = v_posted, base_amount = v_alloc[n],
        asset_link_status = case when l.treatment = 'asset' then 'pending' else 'none' end
    where id = l.id;
    v_lines := app_private.add_line(v_lines, v_posted, v_alloc[n], 0, left(l.description, 200) || ' (' || v_number || ')',
      app_private.orig_fields(x.currency, v_base, l.line_total, x.exchange_rate, v_alloc[n]));
  end loop;
  if v_credit > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_key', 'TAX_ASSET', 'debit', v_credit, 'credit', 0, 'description', 'Input VAT: ' || v_desc);
  end if;
  -- The money that leaves the account is the total less the income tax withheld; the withholding is a liability.
  v_lines := app_private.add_line(v_lines, fa.ledger_account_id, 0, v_base_total - v_wht, v_desc,
    app_private.orig_fields(x.currency, v_base, x.total, x.exchange_rate, v_base_total - v_wht));
  if v_wht > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_key', 'TAX_PAYABLE', 'debit', 0, 'credit', v_wht, 'description', 'PPh 23 withheld: ' || v_desc);
  end if;

  v_journal := app_private.post_system_journal(
    x.entity_id, 'expense', x.id, 'expense.confirm', 'expense.v1', x.expense_date, v_desc, v_lines);
  perform app_private.record_movement(x.entity_id, x.financial_account_id, 'out', x.total - v_wht, v_base_total - v_wht,
    x.exchange_rate, x.expense_date, 'expense', x.id, 'principal', v_journal, v_desc);
  perform app_private.tax_record_results('expense', x.id, v_eval, v_journal, v_desc);

  update public.expenses
  set status = 'confirmed', expense_number = v_number, journal_id = v_journal, confirmed_at = now(),
      confirmed_by = auth.uid(), base_total = v_base_total - v_wht, withheld_total = v_wht,
      tax_status = case when v_eval ->> 'engine' = 'active' then 'determined' else tax_status end,
      duplicate_ack_reason = left(v_ack, 1000),
      payee_snapshot = (select jsonb_build_object(
                          'display_name', co.display_name, 'legal_name', co.legal_name, 'email', co.email,
                          'phone', co.phone, 'address_line', co.address_line, 'city', co.city,
                          'country_code', co.country_code)
                        from public.contacts co where co.id = x.payee_id and co.entity_id = x.entity_id)
  where id = x.id;

  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (x.entity_id, 'ExpenseConfirmed', 'expense', x.id,
          jsonb_build_object('expense_number', v_number, 'total', x.total, 'currency', x.currency));
  return v_journal;
end
$$;
