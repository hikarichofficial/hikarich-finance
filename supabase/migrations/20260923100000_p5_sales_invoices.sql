-- P5 (Step 15 §9) part 1: customers, invoices and their issuance.
-- Authority: Step 01 #8-#14/#39/#40, Step 02 §4 (Sales / Invoice), Step 04 §3 (sales posting matrix),
-- Step 07 §3 (invoice workflow), Step 08 §7/§16/§17 (AR integrity, numbering, duplicates), Step 11 §14 (snapshots).
--
-- What this part delivers
--   * Duplicate-aware customer creation (`create_contact`), so an invoice never auto-creates a second copy of a
--     customer without the user seeing the candidates.
--   * Draft invoices with server-authoritative line arithmetic (the browser never supplies totals).
--   * `issue_invoice`: the ONE step that finalises the number, freezes the issuer/customer/payment snapshots,
--     posts "Dr Accounts Receivable / Cr Revenue" through the posting engine and activates the public link.
--   * Tax is a separate engine (Step 05, P7): invoice lines carry a tax amount that is always zero until that
--     phase plugs in; issuing an invoice that already carries tax is refused instead of guessed.
-- Payments, settlement state, cancel/void/correct and AR controls follow in part 2; refunds and the public
-- token surface in part 3.

-- ------------------------------------------------------------ small shared helpers
create function app_private.entity_base_currency(p_entity uuid) returns public.currency_code
language sql stable as $$ select e.base_currency from public.entities e where e.id = p_entity $$;

-- The current calendar date in the Entity's own timezone (Step 08 §14: the Entity timezone is authoritative
-- for day boundaries).
create function app_private.entity_today(p_entity uuid) returns date
language sql stable as $$
  select (now() at time zone e.timezone)::date from public.entities e where e.id = p_entity
$$;

-- Strict numeric parsing with a clear message; NaN/Infinity are never accepted.
create function app_private.parse_amount(p_text text, p_label text) returns numeric
language plpgsql immutable as $$
declare
  v numeric;
begin
  if p_text is null or btrim(p_text) = '' then
    raise exception 'INVALID: % is required', p_label using errcode = 'invalid_parameter_value';
  end if;
  begin
    v := p_text::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'INVALID: % is not a valid number', p_label using errcode = 'invalid_parameter_value';
  end;
  if not app_private.is_finite(v) then
    raise exception 'INVALID: % must be a finite number', p_label using errcode = 'invalid_parameter_value';
  end if;
  return v;
end
$$;

-- The amount an approval threshold is compared with: always in the Entity's base currency (a rule states its
-- minimum in base currency), whatever currency the document is in.
create function app_private.approval_base_amount(p_entity uuid, p_amount numeric, p_rate numeric)
returns numeric
language sql stable as $$
  select case when p_rate is null or p_rate <= 0 then coalesce(p_amount, 0)
              else app_private.round_amount(coalesce(p_amount, 0) * p_rate,
                     app_private.currency_scale(app_private.entity_base_currency(p_entity)), 'half_up') end
$$;

-- Effective approval rule (maker-checker, Step 06 §7): a rule for the module/action at or below the amount may
-- forbid confirming one's own work. The OWNER may always act on their own event (Step 04 §11).
create function app_private.assert_maker_checker(
  p_entity uuid, p_module text, p_action text, p_amount numeric, p_creator uuid, p_label text)
returns void
language plpgsql stable as $$
declare
  v_rule public.approval_rules%rowtype;
  v_today date := app_private.entity_today(p_entity);
begin
  select r.* into v_rule from public.approval_rules r
  where r.entity_id = p_entity and r.module = p_module and r.action = p_action
    and r.effective_from <= v_today and (r.effective_to is null or r.effective_to >= v_today)
    and coalesce(r.min_amount, 0) <= p_amount
  order by coalesce(r.min_amount, 0) desc
  limit 1;
  if found and v_rule.requires_approval and not v_rule.allow_self_approval
     and p_creator is not distinct from auth.uid() and not app_authz.is_owner(p_entity) then
    raise exception 'FORBIDDEN: an approval rule requires a different person to %', p_label
      using errcode = 'insufficient_privilege';
  end if;
end
$$;

-- Default numbering families for sales documents (Step 01 #40: PT invoices use the HKD prefix; receipts have
-- their own families). Existing configuration is never touched; the OWNER can change the prefix afterwards.
create function app_private.ensure_sales_numbering(p_entity uuid) returns void
language plpgsql as $$
declare
  v_type text;
begin
  select entity_type into v_type from public.entities where id = p_entity;
  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (p_entity, 'invoice', case when v_type = 'company' then 'HKD' else 'INV' end),
         (p_entity, 'payment_receipt', 'RCP'),
         (p_entity, 'refund_receipt', 'RFD')
  on conflict (entity_id, scope) do nothing;
end
$$;

-- Unguessable public link token: 256 random bits, URL-safe (Step 11 §21, Step 17 §16).
create function app_private.new_public_token() returns text
language sql volatile as $$
  select translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_')
$$;

-- Revenue account of an invoice line: the effective category mapping for context "sales", else the Entity's
-- default operating revenue account (Step 03 §6). Names and codes are never matched (Step 04 §16).
create function app_private.default_revenue_account(p_entity uuid) returns uuid
language sql stable as $$
  select a.id from public.ledger_accounts a
  where a.entity_id = p_entity and a.status = 'active' and not a.is_group
    and a.system_key in ('OTHER_OPERATING_REVENUE', 'OTHER_PERSONAL_INCOME')
  order by (a.system_key = 'OTHER_OPERATING_REVENUE') desc
  limit 1
$$;

-- Where discounts and refunds are booked: the contra-revenue account when the Entity's COA has one, otherwise
-- (Personal) the default income account.
create function app_private.sales_contra_account(p_entity uuid) returns uuid
language sql stable as $$
  select a.id from public.ledger_accounts a
  where a.entity_id = p_entity and a.status = 'active' and not a.is_group
    and a.system_key in ('SALES_CONTRA', 'OTHER_PERSONAL_INCOME')
  order by (a.system_key = 'SALES_CONTRA') desc
  limit 1
$$;

create function app_private.resolve_revenue_account(p_entity uuid, p_category uuid, p_date date) returns uuid
language plpgsql stable as $$
declare
  v_id uuid;
begin
  if p_category is not null then
    select m.credit_ledger_account_id into v_id
    from public.category_account_mappings m
    join public.ledger_accounts a on a.id = m.credit_ledger_account_id and a.entity_id = m.entity_id
    where m.entity_id = p_entity and m.category_id = p_category and m.context in ('sales', 'default')
      and m.credit_ledger_account_id is not null and a.status = 'active' and not a.is_group
      and m.effective_from <= p_date and (m.effective_to is null or m.effective_to >= p_date)
    order by (m.context = 'sales') desc
    limit 1;
  end if;
  return coalesce(v_id, app_private.default_revenue_account(p_entity));
end
$$;

-- ------------------------------------------------------------ customers (Step 01 #9, Step 08 §15/§17)
-- Candidates that may be the same person: exact identifiers (email, phone, tax identifier) are "exact", the
-- same normalised name is only "suspected". Nothing is ever merged automatically.
create function app_private.contact_duplicates(
  p_entity uuid, p_name text, p_email text, p_phone text, p_tax text, p_exclude uuid)
returns table (contact_id uuid, display_name text, kind text, severity text, reason text)
language sql stable as $$
  select c.id, c.display_name, c.kind,
         case when x.reason = 'same_name' then 'suspected' else 'exact' end, x.reason
  from public.contacts c
  cross join lateral (
    select 'same_email'::text as reason
      where nullif(btrim(coalesce(p_email, '')), '') is not null and c.normalized_email = lower(btrim(p_email))
    union all
    select 'same_phone'
      where regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') <> ''
        -- "0812..." and "+62 812..." are the same Indonesian number: a leading 0 reads as the country code 62.
        and regexp_replace(c.normalized_phone, '^0', '62') = regexp_replace(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), '^0', '62')
    union all
    select 'same_tax_identifier'
      where nullif(btrim(coalesce(p_tax, '')), '') is not null and c.tax_identifier is not null
        and lower(regexp_replace(c.tax_identifier, '[^0-9A-Za-z]', '', 'g'))
            = lower(regexp_replace(p_tax, '[^0-9A-Za-z]', '', 'g'))
    union all
    select 'same_name'
      where nullif(btrim(coalesce(p_name, '')), '') is not null
        and c.normalized_name = lower(regexp_replace(btrim(p_name), '\s+', ' ', 'g'))
  ) x
  where c.entity_id = p_entity and c.id is distinct from p_exclude
$$;

create function public.find_contact_duplicates(
  p_entity uuid, p_name text default null, p_email text default null, p_phone text default null,
  p_tax_identifier text default null, p_exclude uuid default null)
returns table (contact_id uuid, display_name text, kind text, severity text, reason text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'contacts.view') then
    raise exception 'FORBIDDEN: missing contacts.view' using errcode = 'insufficient_privilege';
  end if;
  -- Tax identifiers are sensitive (Step 06 §6): they take part in the match only for those allowed to see them.
  return query
    select d.contact_id, d.display_name, d.kind, d.severity, d.reason
    from app_private.contact_duplicates(
      p_entity, p_name, p_email, p_phone,
      case when app_authz.has_permission(p_entity, 'contacts.view_sensitive') then p_tax_identifier end,
      p_exclude) d
    order by d.severity, d.display_name;
end
$$;

-- Creates a customer/vendor. Exact identifier matches are always refused; a suspected match (same name) is
-- refused unless the caller explicitly confirms it is a different party. The tax identifier is a sensitive
-- column that browser roles cannot write directly, so it can only be set here, by a holder of the sensitive
-- capability.
create function public.create_contact(
  p_entity uuid, p_key text, p_kind text, p_display_name text, p_email text default null,
  p_phone text default null, p_tax_identifier text default null, p_legal_name text default null,
  p_address_line text default null, p_city text default null, p_country_code text default null,
  p_notes text default null, p_allow_similar_name boolean default false)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_name text := btrim(coalesce(p_display_name, ''));
  v_id uuid;
  d record;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'contacts.create') then
    raise exception 'FORBIDDEN: missing contacts.create' using errcode = 'insufficient_privilege';
  end if;
  if nullif(btrim(coalesce(p_tax_identifier, '')), '') is not null
     and not app_authz.has_permission(p_entity, 'contacts.view_sensitive') then
    raise exception 'FORBIDDEN: setting a tax identifier needs contacts.view_sensitive'
      using errcode = 'insufficient_privilege';
  end if;

  v_replay := app_private.idem_begin('contact.create', p_entity, p_key,
    md5(jsonb_build_object('kind', p_kind, 'name', v_name, 'email', p_email, 'phone', p_phone,
                           'tax', p_tax_identifier, 'legal', p_legal_name, 'addr', p_address_line,
                           'city', p_city, 'country', p_country_code, 'notes', p_notes,
                           'similar', coalesce(p_allow_similar_name, false))::text));
  if v_replay is not null then
    return v_replay;
  end if;

  if p_kind not in ('customer', 'vendor', 'both') then
    raise exception 'INVALID: kind must be customer, vendor or both' using errcode = 'invalid_parameter_value';
  end if;
  if length(v_name) not between 1 and 200 then
    raise exception 'INVALID: a contact needs a name of up to 200 characters' using errcode = 'invalid_parameter_value';
  end if;
  if p_country_code is not null and p_country_code !~ '^[A-Z]{2}$' then
    raise exception 'INVALID: country must be a two-letter code' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;

  select * into d from app_private.contact_duplicates(
    p_entity, v_name, p_email, p_phone, p_tax_identifier, null)
    order by (severity = 'exact') desc limit 1;
  if found and (d.severity = 'exact' or not coalesce(p_allow_similar_name, false)) then
    raise exception 'CONFLICT: this looks like an existing contact "%" (%); use it, or confirm it is a different party',
      d.display_name, d.reason using errcode = 'integrity_constraint_violation';
  end if;

  insert into public.contacts
    (entity_id, kind, display_name, legal_name, email, phone, tax_identifier, address_line, city, country_code, notes)
  values
    (p_entity, p_kind, v_name, nullif(btrim(coalesce(p_legal_name, '')), ''),
     nullif(btrim(coalesce(p_email, '')), ''), nullif(btrim(coalesce(p_phone, '')), ''),
     nullif(btrim(coalesce(p_tax_identifier, '')), ''), nullif(btrim(coalesce(p_address_line, '')), ''),
     nullif(btrim(coalesce(p_city, '')), ''), p_country_code, nullif(btrim(coalesce(p_notes, '')), ''))
  returning id into v_id;

  perform app_private.idem_complete('contact.create', p_entity, p_key, 'contacts', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ invoices
create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  -- Issuance state only. Paid / partially paid / refunded are DERIVED from confirmed allocations and refunds,
  -- and overdue from the due date (Step 07 §3); none of them overwrites this column.
  status text not null default 'draft' check (status in ('draft', 'issued', 'cancelled', 'void')),
  invoice_number text,
  customer_id uuid not null,
  currency public.currency_code not null references public.currencies (code),
  -- Base currency per unit of the invoice currency; present exactly for foreign-currency invoices.
  exchange_rate public.fx_rate,
  issue_date date not null,
  due_date date not null,
  payment_account_id uuid,
  payment_channel_id uuid,
  -- Customer-facing text (Step 01 #40: customer, internal and payment notes are distinct).
  notes text check (notes is null or length(notes) <= 2000),
  terms text check (terms is null or length(terms) <= 4000),
  payment_note text check (payment_note is null or length(payment_note) <= 1000),
  internal_note text check (internal_note is null or length(internal_note) <= 2000),
  subtotal public.money_amount not null default 0 check (subtotal >= 0),
  discount_total public.money_amount not null default 0 check (discount_total >= 0),
  -- P7 fills tax; until then it is always zero and the issue command refuses anything else.
  tax_total public.money_amount not null default 0 check (tax_total >= 0),
  total public.money_amount not null default 0 check (total >= 0),
  -- The receivable in base currency booked at issue (what the sub-ledger later reconciles to the GL).
  base_total public.money_amount not null default 0 check (base_total >= 0),
  base_discount_total public.money_amount not null default 0 check (base_discount_total >= 0),
  tax_status text not null default 'pending_engine' check (tax_status in ('pending_engine')),
  -- Snapshots taken at Issue (Step 02 §4, Step 08 §3): later edits of the masters never rewrite them.
  issuer_snapshot jsonb,
  customer_snapshot jsonb,
  payment_snapshot jsonb,
  journal_id uuid,
  reversal_journal_id uuid,
  issued_at timestamptz,
  issued_by uuid,
  closed_at timestamptz,
  closed_by uuid,
  closed_date date,
  closed_reason text,
  replaces_invoice_id uuid,
  replaced_by_invoice_id uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, customer_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, payment_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, payment_channel_id) references public.payment_channels (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, replaces_invoice_id) references public.invoices (entity_id, id) on delete restrict,
  foreign key (entity_id, replaced_by_invoice_id) references public.invoices (entity_id, id) on delete restrict,
  constraint invoice_due_after_issue check (due_date >= issue_date),
  constraint invoice_total_formula check (total = subtotal - discount_total + tax_total),
  constraint invoice_no_self_replacement check (replaces_invoice_id is distinct from id and replaced_by_invoice_id is distinct from id),
  constraint invoice_state_consistent check (
    case status
      when 'draft' then invoice_number is null and journal_id is null and reversal_journal_id is null
        and issued_at is null and closed_at is null and issuer_snapshot is null and customer_snapshot is null
      when 'issued' then invoice_number is not null and journal_id is not null and reversal_journal_id is null
        and issued_at is not null and closed_at is null and issuer_snapshot is not null
        and customer_snapshot is not null and total > 0 and base_total > 0
      when 'cancelled' then closed_at is not null and closed_date is not null and closed_reason is not null
        and ((invoice_number is null and journal_id is null and reversal_journal_id is null)
             or (invoice_number is not null and journal_id is not null and reversal_journal_id is not null))
      else invoice_number is not null and journal_id is not null and reversal_journal_id is not null
        and closed_at is not null and closed_date is not null and closed_reason is not null
    end)
);
-- A final number is unique within the Entity and never reused (Step 08 §16).
create unique index invoices_number_uq on public.invoices (entity_id, invoice_number) where invoice_number is not null;
create index invoices_entity_status_idx on public.invoices (entity_id, status, issue_date);
create index invoices_customer_idx on public.invoices (entity_id, customer_id);
create index invoices_due_idx on public.invoices (entity_id, due_date) where status = 'issued';
create unique index invoices_one_replacement_uq on public.invoices (replaces_invoice_id) where replaces_invoice_id is not null;

create function app_private.tg_invoices_guard() returns trigger
language plpgsql as $$
declare
  v_base public.currency_code;
  v_mutable constant text[] := array['status', 'due_date', 'internal_note', 'closed_at', 'closed_by', 'closed_date',
    'closed_reason', 'reversal_journal_id', 'replaced_by_invoice_id', 'updated_at', 'updated_by', 'version'];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'An invoice starts as a draft' using errcode = 'integrity_constraint_violation';
    end if;
  else
    if old.status in ('cancelled', 'void') then
      raise exception 'A % invoice cannot change any more', old.status using errcode = 'integrity_constraint_violation';
    end if;
    if new.status <> old.status
       and (old.status, new.status) not in
           (('draft', 'issued'), ('draft', 'cancelled'), ('issued', 'cancelled'), ('issued', 'void')) then
      raise exception 'An invoice cannot move from % to %', old.status, new.status
        using errcode = 'integrity_constraint_violation';
    end if;
    if old.status = 'issued' and (to_jsonb(new) - v_mutable) is distinct from (to_jsonb(old) - v_mutable) then
      raise exception 'An issued invoice is frozen; only its due date (audited) and internal note may change'
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;

  if new.status = 'draft' then
    v_base := app_private.entity_base_currency(new.entity_id);
    if (new.currency = v_base) <> (new.exchange_rate is null) then
      raise exception 'INVALID: a foreign-currency invoice needs an exchange rate and a base-currency invoice has none'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.invoices
  for each row execute function app_private.tg_invoices_guard();
create trigger tg_forbid_delete before delete on public.invoices
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.invoices
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.invoices');
call app_private.secure_table('public.invoices');
create trigger tg_audit after insert or update or delete on public.invoices
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ invoice lines
create table public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  invoice_id uuid not null,
  line_no smallint not null check (line_no > 0),
  product_id uuid,
  description text not null check (length(btrim(description)) between 1 and 500),
  quantity numeric(20, 4) not null check (quantity > 0),
  unit_price public.money_amount not null check (unit_price >= 0),
  discount_type text not null default 'none' check (discount_type in ('none', 'percent', 'fixed')),
  discount_value numeric(20, 4) not null default 0 check (discount_value >= 0),
  line_subtotal public.money_amount not null check (line_subtotal >= 0),
  discount_amount public.money_amount not null default 0 check (discount_amount >= 0),
  -- Interface to the tax engine (P7): zero until then.
  tax_amount public.money_amount not null default 0 check (tax_amount >= 0),
  line_total public.money_amount not null check (line_total >= 0),
  category_id uuid,
  -- Set at Issue: the revenue account that was credited and the base-currency amounts that were booked.
  revenue_account_id uuid,
  base_amount public.money_amount check (base_amount is null or base_amount >= 0),
  base_discount_amount public.money_amount check (base_discount_amount is null or base_discount_amount >= 0),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (invoice_id, line_no),
  foreign key (entity_id, invoice_id) references public.invoices (entity_id, id) on delete restrict,
  foreign key (entity_id, product_id) references public.products (entity_id, id) on delete restrict,
  foreign key (entity_id, category_id) references public.categories (entity_id, id) on delete restrict,
  foreign key (entity_id, revenue_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  constraint invoice_line_formula check (line_total = line_subtotal - discount_amount + tax_amount),
  constraint invoice_line_discount_within check (discount_amount <= line_subtotal),
  constraint invoice_line_discount_shape check ((discount_type = 'none') = (discount_value = 0 and discount_amount = 0)
                                                or discount_type <> 'none')
);
create index invoice_lines_invoice_idx on public.invoice_lines (entity_id, invoice_id, line_no);

-- Lines exist for drafts only; the issued document is frozen (Step 11 §14). The parent row is share-locked so a
-- concurrent Issue and a line edit serialise.
create function app_private.tg_invoice_lines_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
begin
  select i.status into v_status from public.invoices i
  where i.id = coalesce(new.invoice_id, old.invoice_id) and i.entity_id = coalesce(new.entity_id, old.entity_id)
  for share;
  if v_status is distinct from 'draft' then
    raise exception 'The lines of a % invoice are frozen', coalesce(v_status, 'missing')
      using errcode = 'integrity_constraint_violation';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update or delete on public.invoice_lines
  for each row execute function app_private.tg_invoice_lines_guard();
create trigger tg_forbid_truncate before truncate on public.invoice_lines
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.invoice_lines');
call app_private.secure_table('public.invoice_lines');
create trigger tg_audit after insert or update or delete on public.invoice_lines
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ public links (Step 01 #39, Step 11 §8)
-- One secure token per issued invoice. Draft invoices have none. The token is readable through a dedicated
-- RPC only (never by a plain select) and never enters the audit trail.
create table public.invoice_public_links (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  invoice_id uuid not null,
  token text not null check (length(token) >= 40 and token ~ '^[A-Za-z0-9_-]+$'),
  status text not null default 'active' check (status in ('active', 'revoked')),
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  revoked_reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (token),
  foreign key (entity_id, invoice_id) references public.invoices (entity_id, id) on delete restrict,
  constraint public_link_revoked_consistency check ((status = 'revoked') = (revoked_at is not null))
);
create unique index invoice_public_links_one_active_uq on public.invoice_public_links (invoice_id) where status = 'active';
create index invoice_public_links_invoice_idx on public.invoice_public_links (entity_id, invoice_id);
create function app_private.tg_public_links_guard() returns trigger
language plpgsql as $$
begin
  if (new.invoice_id, new.token, new.created_at) is distinct from (old.invoice_id, old.token, old.created_at) then
    raise exception 'A public link keeps its token; regenerate to get a new one' using errcode = 'integrity_constraint_violation';
  end if;
  if old.status = 'revoked' then
    raise exception 'A revoked link stays revoked' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.invoice_public_links
  for each row execute function app_private.tg_public_links_guard();
create trigger tg_forbid_delete before delete on public.invoice_public_links
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.invoice_public_links
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.invoice_public_links');
call app_private.secure_table('public.invoice_public_links');
create trigger tg_audit after insert or update or delete on public.invoice_public_links
  for each row execute function app_private.tg_audit('entity_id', 'token');

-- ------------------------------------------------------------ line arithmetic (server-authoritative)
-- Turns the caller's lines into canonical, fully computed lines. The caller never supplies a total: quantity x
-- unit price rounds once per line, a percentage discount rounds once, a fixed discount must already fit the
-- currency's minor unit and can never exceed the line. All rounding is half-up in the invoice currency.
create function app_private.invoice_prepare_lines(
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

    v_subtotal := v_subtotal + v_sub;
    v_discount := v_discount + v_disc;
    v_out := v_out || jsonb_build_object(
      'line_no', v_no, 'product_id', v_pid, 'description', v_desc, 'quantity', trim_scale(v_qty),
      'unit_price', trim_scale(v_price), 'discount_type', v_dtype, 'discount_value', trim_scale(v_dval),
      'line_subtotal', v_sub, 'discount_amount', v_disc, 'line_total', v_sub - v_disc, 'category_id', v_cid);
  end loop;

  return jsonb_build_object('lines', v_out, 'subtotal', v_subtotal, 'discount_total', v_discount,
                            'total', v_subtotal - v_discount);
end
$$;

-- Validates the header facts shared by create and update (Step 08 §5, §7, §14).
create function app_private.invoice_check_header(
  p_entity uuid, p_customer uuid, p_issue date, p_due date, p_currency public.currency_code, p_rate numeric,
  p_account uuid, p_channel uuid)
returns void
language plpgsql stable as $$
declare
  v_base public.currency_code := app_private.entity_base_currency(p_entity);
  c public.contacts%rowtype;
  a public.financial_accounts%rowtype;
begin
  if p_customer is null then
    raise exception 'INVALID: choose a customer' using errcode = 'invalid_parameter_value';
  end if;
  select * into c from public.contacts where id = p_customer and entity_id = p_entity;
  if not found or c.kind not in ('customer', 'both') then
    raise exception 'INVALID: the customer is unknown or is not a customer of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  if c.status <> 'active' then
    raise exception 'INVALID: an inactive contact cannot be used for a new invoice' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_issue);
  if p_due is not null then
    perform app_private.assert_business_date(p_due);
  end if;
  if p_due is null or p_due < p_issue then
    raise exception 'INVALID: the due date cannot be before the issue date' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.currencies where code = p_currency and is_active) then
    raise exception 'INVALID: unknown currency' using errcode = 'invalid_parameter_value';
  end if;
  if p_currency = v_base then
    if p_rate is not null then
      raise exception 'INVALID: a base-currency invoice has no exchange rate' using errcode = 'invalid_parameter_value';
    end if;
  else
    if p_rate is null or not app_private.is_finite(p_rate) or p_rate <= 0 or p_rate >= 10::numeric ^ 10
       or app_private.round_amount(p_rate, 10, 'down') <> p_rate then
      raise exception 'INVALID: a foreign-currency invoice needs a positive exchange rate with at most 10 decimals'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  if p_account is not null then
    select * into a from public.financial_accounts where id = p_account and entity_id = p_entity;
    if not found or not a.is_active then
      raise exception 'INVALID: the payment destination is unknown or inactive' using errcode = 'invalid_parameter_value';
    end if;
    if a.currency <> p_currency then
      raise exception 'INVALID: the payment destination must be an account in the invoice currency (%)', p_currency
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  if p_channel is not null and not exists (
       select 1 from public.payment_channels ch
       where ch.id = p_channel and ch.entity_id = p_entity and ch.is_active
         and (ch.settlement_financial_account_id is null or ch.settlement_financial_account_id = p_account)) then
    raise exception 'INVALID: the payment channel is unknown, inactive or does not settle into the chosen account'
      using errcode = 'invalid_parameter_value';
  end if;
end
$$;

create function app_private.invoice_write_lines(p_entity uuid, p_invoice uuid, p_prepared jsonb) returns void
language plpgsql as $$
begin
  delete from public.invoice_lines where invoice_id = p_invoice and entity_id = p_entity;
  insert into public.invoice_lines
    (entity_id, invoice_id, line_no, product_id, description, quantity, unit_price, discount_type, discount_value,
     line_subtotal, discount_amount, line_total, category_id)
  select p_entity, p_invoice, (l ->> 'line_no')::smallint, nullif(l ->> 'product_id', '')::uuid, l ->> 'description',
         (l ->> 'quantity')::numeric, (l ->> 'unit_price')::numeric, l ->> 'discount_type',
         (l ->> 'discount_value')::numeric, (l ->> 'line_subtotal')::numeric, (l ->> 'discount_amount')::numeric,
         (l ->> 'line_total')::numeric, nullif(l ->> 'category_id', '')::uuid
  from jsonb_array_elements(p_prepared -> 'lines') l;
end
$$;

-- ------------------------------------------------------------ draft commands
create function public.create_invoice_draft(
  p_entity uuid, p_key text, p_customer uuid, p_issue_date date, p_due_date date, p_lines jsonb default '[]'::jsonb,
  p_currency text default null, p_rate numeric default null, p_notes text default null, p_terms text default null,
  p_payment_note text default null, p_internal_note text default null, p_payment_account uuid default null,
  p_payment_channel uuid default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_currency public.currency_code;
  v_prep jsonb;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.create') then
    raise exception 'FORBIDDEN: missing invoices.create' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('invoice.create', p_entity, p_key,
    md5(jsonb_build_object('customer', p_customer, 'issue', p_issue_date, 'due', p_due_date, 'lines', p_lines,
                           'currency', p_currency, 'rate', p_rate, 'notes', p_notes, 'terms', p_terms,
                           'pnote', p_payment_note, 'inote', p_internal_note, 'acct', p_payment_account,
                           'channel', p_payment_channel)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;

  v_currency := coalesce(p_currency, app_private.entity_base_currency(p_entity));
  perform app_private.invoice_check_header(p_entity, p_customer, p_issue_date, p_due_date, v_currency, p_rate,
                                           p_payment_account, p_payment_channel);
  v_prep := app_private.invoice_prepare_lines(p_entity, v_currency, p_lines);

  insert into public.invoices
    (entity_id, customer_id, currency, exchange_rate, issue_date, due_date, payment_account_id, payment_channel_id,
     notes, terms, payment_note, internal_note, subtotal, discount_total, total)
  values
    (p_entity, p_customer, v_currency, p_rate, p_issue_date, p_due_date, p_payment_account, p_payment_channel,
     nullif(btrim(coalesce(p_notes, '')), ''), nullif(btrim(coalesce(p_terms, '')), ''),
     nullif(btrim(coalesce(p_payment_note, '')), ''), nullif(btrim(coalesce(p_internal_note, '')), ''),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'discount_total')::numeric, (v_prep ->> 'total')::numeric)
  returning id into v_id;
  perform app_private.invoice_write_lines(p_entity, v_id, v_prep);

  perform app_private.idem_complete('invoice.create', p_entity, p_key, 'invoices', v_id);
  return v_id;
end
$$;

-- Edits a draft. The patch names the fields to change; `lines`, when present, replaces all lines. A stale
-- version is refused (Step 08 §18).
create function public.update_invoice_draft(p_invoice uuid, p_patch jsonb, p_expected_version integer default null)
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
        'category_id', l.category_id) order by l.line_no), '[]'::jsonb)
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

-- ------------------------------------------------------------ issue (Step 07 §3, Step 04 §3)
-- Assumes the caller holds the invoice row lock and has checked permission and idempotency.
create function app_private.issue_invoice_core(p_invoice uuid) returns uuid
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
  if exists (select 1 from public.invoice_lines where invoice_id = i.id and tax_amount <> 0) or i.tax_total <> 0 then
    raise exception 'CONFLICT: tax lines are produced by the tax engine, which is not active yet; nothing is guessed'
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
  v_base_gross := v_base_total + v_base_disc;
  v_contra := app_private.sales_contra_account(i.entity_id);
  v_use_contra := v_base_disc > 0 and v_contra is not null;

  if v_use_contra then
    select array_agg(line_subtotal order by line_no) into v_weights from public.invoice_lines where invoice_id = i.id;
    v_alloc := app_private.allocate_amount(v_base_gross, v_weights, v_scale);
    select array_agg(discount_amount order by line_no) into v_weights from public.invoice_lines where invoice_id = i.id;
    v_alloc_disc := app_private.allocate_amount(v_base_disc, v_weights, v_scale);
  else
    select array_agg(line_total order by line_no) into v_weights from public.invoice_lines where invoice_id = i.id;
    v_alloc := app_private.allocate_amount(v_base_total, v_weights, v_scale);
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

  v_journal := app_private.post_system_journal(
    i.entity_id, 'invoice', i.id, 'invoice.issue', 'invoice.v1', i.issue_date, v_desc, v_lines);

  update public.invoices
  set status = 'issued', invoice_number = v_number, journal_id = v_journal, issued_at = now(), issued_by = auth.uid(),
      base_total = v_base_total, base_discount_total = v_base_disc,
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

create function public.issue_invoice(p_invoice uuid, p_key text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  -- The same answer for "does not exist" and "not allowed": no existence leak across Entities.
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.issue') then
    raise exception 'FORBIDDEN: missing invoices.issue' using errcode = 'insufficient_privilege';
  end if;
  select * into i from public.invoices where id = p_invoice for update;

  v_replay := app_private.idem_begin('invoice.issue', i.entity_id, p_key, md5(p_invoice::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if i.status <> 'draft' then
    raise exception 'CONFLICT: only a draft invoice can be issued (now %)', i.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_maker_checker(i.entity_id, 'invoices', 'issue',
    app_private.approval_base_amount(i.entity_id, i.total, i.exchange_rate), i.created_by, 'issue this invoice');
  perform app_private.issue_invoice_core(p_invoice);
  perform app_private.idem_complete('invoice.issue', i.entity_id, p_key, 'invoices', p_invoice);
  return p_invoice;
end
$$;

-- ------------------------------------------------------------ reading the public link of an invoice
create function public.invoice_public_link(p_invoice uuid)
returns table (token text, status text, expires_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select entity_id into v_entity from public.invoices where id = p_invoice;
  -- The token is the customer's key to the page and to "Saya Sudah Bayar": only those who send invoices may read it.
  if v_entity is null or not app_authz.has_permission(v_entity, 'invoices.regenerate_link') then
    raise exception 'FORBIDDEN: missing invoices.regenerate_link' using errcode = 'insufficient_privilege';
  end if;
  return query
    select l.token, l.status, l.expires_at from public.invoice_public_links l
    where l.invoice_id = p_invoice order by (l.status = 'active') desc, l.created_at desc limit 1;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.invoices');
create policy invoices_select on public.invoices for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view'));
call app_private.expose_select('public.invoice_lines');
create policy invoice_lines_select on public.invoice_lines for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view'));
call app_private.expose_select('public.invoice_public_links', array['token']);
create policy invoice_public_links_select on public.invoice_public_links for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view'));

revoke all on function app_private.entity_base_currency(uuid) from public;
revoke all on function app_private.entity_today(uuid) from public;
revoke all on function app_private.parse_amount(text, text) from public;
revoke all on function app_private.assert_maker_checker(uuid, text, text, numeric, uuid, text) from public;
revoke all on function app_private.ensure_sales_numbering(uuid) from public;
revoke all on function app_private.new_public_token() from public;
revoke all on function app_private.default_revenue_account(uuid) from public;
revoke all on function app_private.sales_contra_account(uuid) from public;
revoke all on function app_private.resolve_revenue_account(uuid, uuid, date) from public;
revoke all on function app_private.contact_duplicates(uuid, text, text, text, text, uuid) from public;
revoke all on function app_private.tg_invoices_guard() from public;
revoke all on function app_private.tg_invoice_lines_guard() from public;
revoke all on function app_private.tg_public_links_guard() from public;
revoke all on function app_private.invoice_prepare_lines(uuid, public.currency_code, jsonb, boolean) from public;
revoke all on function app_private.approval_base_amount(uuid, numeric, numeric) from public;
revoke all on function app_private.invoice_check_header(uuid, uuid, date, date, public.currency_code, numeric, uuid, uuid) from public;
revoke all on function app_private.invoice_write_lines(uuid, uuid, jsonb) from public;
revoke all on function app_private.issue_invoice_core(uuid) from public;

revoke all on function public.find_contact_duplicates(uuid, text, text, text, text, uuid) from public, anon;
revoke all on function public.create_contact(uuid, text, text, text, text, text, text, text, text, text, text, text, boolean) from public, anon;
revoke all on function public.create_invoice_draft(uuid, text, uuid, date, date, jsonb, text, numeric, text, text, text, text, uuid, uuid) from public, anon;
revoke all on function public.update_invoice_draft(uuid, jsonb, integer) from public, anon;
revoke all on function public.issue_invoice(uuid, text) from public, anon;
revoke all on function public.invoice_public_link(uuid) from public, anon;
grant execute on function public.find_contact_duplicates(uuid, text, text, text, text, uuid) to authenticated;
grant execute on function public.create_contact(uuid, text, text, text, text, text, text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.create_invoice_draft(uuid, text, uuid, date, date, jsonb, text, numeric, text, text, text, text, uuid, uuid) to authenticated;
grant execute on function public.update_invoice_draft(uuid, jsonb, integer) to authenticated;
grant execute on function public.issue_invoice(uuid, text) to authenticated;
grant execute on function public.invoice_public_link(uuid) to authenticated;
