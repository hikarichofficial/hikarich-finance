-- P6 (Step 15 §10) part 3: direct expenses, duplicate detection and evidence documents.
-- Authority: Step 01 #15-#17 (direct expenses paid at once), Step 04 §4 (expense posting), Step 07 §5/§6 (purchase
-- workflow), Step 08 §8/§17 (duplicate prevention, missing evidence), Step 06 §3 (capabilities), Step 11 (documents).
--
-- What this part delivers
--   * A direct expense is a purchase paid at the moment it is recorded (a receipt from a shop, a fuel top-up): it has
--     no payable. Confirming it posts "Dr expense/asset/prepaid, Cr the paying cash/bank account" and records the
--     money leaving that account, once, in one transaction. Staff prepare and submit; a person with `bills.pay`
--     confirms (the OWNER may confirm their own entry).
--   * Duplicate detection across bills and expenses (same vendor and the same vendor reference, or the same vendor,
--     date, currency and total). An exact duplicate is refused unless the approver states why it is different.
--   * Evidence: documents are registered by their content hash and linked to a bill or an expense. In this phase a
--     document is metadata plus a SHA-256 hash; the file storage and the upload screens arrive with P11.

-- ------------------------------------------------------------ serialising the party of a purchase
-- Two people approving the same vendor invoice at the same time must not both pass the duplicate check.
create function app_private.lock_purchase_party(p_entity uuid, p_vendor uuid, p_payee text) returns void
language plpgsql as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(
    'purchase-party:' || p_entity::text || ':' || coalesce(p_vendor::text, 'name:' || lower(btrim(coalesce(p_payee, '')))), 0));
end
$$;

-- ------------------------------------------------------------ direct expenses
create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  status text not null default 'draft'
    check (status in ('draft', 'submitted', 'confirmed', 'reversed', 'cancelled')),
  expense_number text,
  -- A vendor of the Entity, or a free-text payee for a one-off shop that is not worth a contact.
  payee_id uuid,
  payee_name text check (payee_name is null or length(payee_name) <= 200),
  -- The receipt / till number: the key of duplicate detection.
  receipt_reference text check (receipt_reference is null or length(receipt_reference) <= 100),
  -- The account the money leaves. The expense is in this account's currency.
  financial_account_id uuid not null,
  currency public.currency_code not null,
  exchange_rate public.fx_rate,
  expense_date date not null,
  notes text check (notes is null or length(notes) <= 2000),
  internal_note text check (internal_note is null or length(internal_note) <= 2000),
  subtotal public.money_amount not null default 0 check (subtotal >= 0),
  tax_total public.money_amount not null default 0 check (tax_total >= 0),
  total public.money_amount not null default 0 check (total >= 0),
  base_total public.money_amount not null default 0 check (base_total >= 0),
  tax_status text not null default 'pending_engine' check (tax_status in ('pending_engine')),
  journal_id uuid,
  reversal_journal_id uuid,
  submitted_at timestamptz,
  submitted_by uuid,
  rejected_at timestamptz,
  rejected_by uuid,
  reject_reason text check (reject_reason is null or length(reject_reason) <= 1000),
  confirmed_at timestamptz,
  confirmed_by uuid,
  duplicate_ack_reason text check (duplicate_ack_reason is null or length(duplicate_ack_reason) <= 1000),
  -- The payee as it was when the expense was confirmed (a contact's later edits never rewrite history).
  payee_snapshot jsonb,
  closed_at timestamptz,
  closed_by uuid,
  closed_date date,
  closed_reason text,
  replaces_expense_id uuid,
  replaced_by_expense_id uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, payee_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id, currency)
    references public.financial_accounts (entity_id, id, currency) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, replaces_expense_id) references public.expenses (entity_id, id) on delete restrict,
  foreign key (entity_id, replaced_by_expense_id) references public.expenses (entity_id, id) on delete restrict,
  constraint expense_total_formula check (total = subtotal + tax_total),
  constraint expense_payee_present check (payee_id is not null or length(btrim(coalesce(payee_name, ''))) > 0),
  constraint expense_no_self_replacement
    check (replaces_expense_id is distinct from id and replaced_by_expense_id is distinct from id),
  constraint expense_state_consistent check (
    case status
      when 'draft' then expense_number is null and journal_id is null and reversal_journal_id is null
        and submitted_at is null and confirmed_at is null and closed_at is null
      when 'submitted' then expense_number is null and journal_id is null and reversal_journal_id is null
        and submitted_at is not null and confirmed_at is null and closed_at is null
      when 'confirmed' then expense_number is not null and journal_id is not null and reversal_journal_id is null
        and confirmed_at is not null and closed_at is null and total > 0 and base_total > 0
      when 'cancelled' then closed_at is not null and closed_date is not null and closed_reason is not null
        and expense_number is null and journal_id is null and reversal_journal_id is null
      else expense_number is not null and journal_id is not null and reversal_journal_id is not null
        and closed_at is not null and closed_date is not null and closed_reason is not null
    end)
);
create unique index expenses_number_uq on public.expenses (entity_id, expense_number) where expense_number is not null;
create index expenses_entity_status_idx on public.expenses (entity_id, status, expense_date);
create index expenses_payee_idx on public.expenses (entity_id, payee_id) where payee_id is not null;
create index expenses_account_idx on public.expenses (entity_id, financial_account_id);
create index expenses_reference_idx on public.expenses (entity_id, lower(btrim(receipt_reference)))
  where receipt_reference is not null;
create unique index expenses_one_replacement_uq on public.expenses (replaces_expense_id) where replaces_expense_id is not null;

create function app_private.tg_expenses_guard() returns trigger
language plpgsql as $$
declare
  v_base public.currency_code;
  v_state constant text[] := array['status', 'submitted_at', 'submitted_by', 'rejected_at', 'rejected_by',
                                    'reject_reason', 'updated_at', 'updated_by', 'version'];
  v_confirm constant text[] := array['status', 'expense_number', 'journal_id', 'base_total', 'confirmed_at',
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
create trigger tg_guard before insert or update on public.expenses
  for each row execute function app_private.tg_expenses_guard();
create trigger tg_forbid_delete before delete on public.expenses
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.expenses
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.expenses');
call app_private.secure_table('public.expenses');
create trigger tg_audit after insert or update or delete on public.expenses
  for each row execute function app_private.tg_audit('entity_id');

create table public.expense_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  expense_id uuid not null,
  line_no smallint not null check (line_no > 0),
  description text not null check (length(btrim(description)) between 1 and 500),
  quantity numeric(20, 4) not null check (quantity > 0),
  unit_price public.money_amount not null check (unit_price >= 0),
  line_subtotal public.money_amount not null check (line_subtotal > 0),
  tax_amount public.money_amount not null default 0 check (tax_amount >= 0),
  line_total public.money_amount not null check (line_total > 0),
  treatment text not null default 'expense' check (treatment in ('expense', 'asset', 'prepaid')),
  category_id uuid,
  account_id uuid,
  posted_account_id uuid,
  base_amount public.money_amount check (base_amount is null or base_amount >= 0),
  asset_link_status text not null default 'none' check (asset_link_status in ('none', 'pending', 'linked')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (expense_id, line_no),
  foreign key (entity_id, expense_id) references public.expenses (entity_id, id) on delete restrict,
  foreign key (entity_id, category_id) references public.categories (entity_id, id) on delete restrict,
  foreign key (entity_id, account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, posted_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  constraint expense_line_formula check (line_total = line_subtotal + tax_amount),
  constraint expense_line_asset_shape check (asset_link_status = 'none' or treatment = 'asset')
);
create index expense_lines_expense_idx on public.expense_lines (entity_id, expense_id, line_no);

create function app_private.tg_expense_lines_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
  v_resolved constant text[] := array['posted_account_id', 'base_amount', 'asset_link_status', 'updated_at',
                                       'updated_by', 'version'];
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
create trigger tg_guard before insert or update or delete on public.expense_lines
  for each row execute function app_private.tg_expense_lines_guard();
create trigger tg_forbid_truncate before truncate on public.expense_lines
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.expense_lines');
call app_private.secure_table('public.expense_lines');
create trigger tg_audit after insert or update or delete on public.expense_lines
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ duplicate detection (Step 08 §17)
-- Recognised bills and confirmed expenses that look like the one described. `exact`: the same party and the same
-- vendor reference / receipt number (a vendor's own number is unique per vendor). `likely`: the same party, date,
-- currency and total. A voided, cancelled or reversed document never counts, so a correction is not its own duplicate.
create function app_private.purchase_duplicates(
  p_entity uuid, p_kind text, p_vendor uuid, p_payee text, p_reference text, p_date date,
  p_currency public.currency_code, p_total numeric, p_exclude uuid default null)
returns table (doc_kind text, doc_id uuid, doc_number text, doc_date date, severity text, reason text)
language plpgsql stable as $$
declare
  v_ref text := nullif(lower(btrim(coalesce(p_reference, ''))), '');
  v_payee text := nullif(lower(btrim(coalesce(p_payee, ''))), '');
begin
  return query
  with cand as (
    select 'bill'::text as k, b.id as id, b.bill_number as num, b.bill_date as d, b.currency as cur, b.total::numeric as tot,
           nullif(lower(btrim(coalesce(b.vendor_reference, ''))), '') as ref, b.vendor_id as pid, null::text as pname
    from public.bills b where b.entity_id = p_entity and b.status = 'approved'
    union all
    select 'expense', x.id, x.expense_number, x.expense_date, x.currency, x.total::numeric,
           nullif(lower(btrim(coalesce(x.receipt_reference, ''))), ''), x.payee_id,
           nullif(lower(btrim(coalesce(x.payee_name, ''))), '')
    from public.expenses x where x.entity_id = p_entity and x.status = 'confirmed'
  )
  select c.k, c.id, c.num, c.d,
         case when v_ref is not null and c.ref = v_ref then 'exact' else 'likely' end,
         case when v_ref is not null and c.ref = v_ref
                then 'the same vendor reference ' || coalesce(p_reference, '')
              else 'the same vendor, date, currency and total' end
  from cand c
  where not (c.k = p_kind and c.id is not distinct from p_exclude)
    and ((p_vendor is not null and c.pid = p_vendor)
         or (p_vendor is null and v_payee is not null and c.pid is null and c.pname = v_payee))
    and ((v_ref is not null and c.ref = v_ref)
         or (c.d = p_date and c.cur = p_currency and c.tot = p_total))
  order by (v_ref is not null and c.ref = v_ref) desc, c.d desc, c.num;
end
$$;

create function public.find_purchase_duplicates(
  p_entity uuid, p_vendor uuid default null, p_payee_name text default null, p_reference text default null,
  p_date date default null, p_currency text default null, p_total numeric default null,
  p_exclude_kind text default null, p_exclude_id uuid default null)
returns table (doc_kind text, doc_id uuid, doc_number text, doc_date date, severity text, reason text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.view') then
    raise exception 'FORBIDDEN: missing bills.view' using errcode = 'insufficient_privilege';
  end if;
  if p_vendor is null and nullif(btrim(coalesce(p_payee_name, '')), '') is null then
    raise exception 'INVALID: name a vendor or a payee' using errcode = 'invalid_parameter_value';
  end if;
  return query
  select d.doc_kind, d.doc_id, d.doc_number, d.doc_date, d.severity, d.reason
  from app_private.purchase_duplicates(
    p_entity, coalesce(p_exclude_kind, 'none'), p_vendor, p_payee_name, p_reference, p_date,
    coalesce(p_currency, app_private.entity_base_currency(p_entity)::text)::public.currency_code, p_total,
    p_exclude_id) d;
end
$$;

-- ------------------------------------------------------------ expense header and lines
create function app_private.expense_check_header(
  p_entity uuid, p_payee uuid, p_payee_name text, p_account uuid, p_date date, p_rate numeric, p_reference text)
returns public.currency_code
language plpgsql stable as $$
declare
  v_base public.currency_code := app_private.entity_base_currency(p_entity);
  fa public.financial_accounts%rowtype;
  c public.contacts%rowtype;
begin
  if p_payee is null and length(btrim(coalesce(p_payee_name, ''))) = 0 then
    raise exception 'INVALID: name the vendor or the payee' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(p_payee_name, '')) > 200 or length(coalesce(p_reference, '')) > 100 then
    raise exception 'INVALID: the payee is limited to 200 and the receipt reference to 100 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_payee is not null then
    select * into c from public.contacts where id = p_payee and entity_id = p_entity;
    if not found or c.kind not in ('vendor', 'both') then
      raise exception 'INVALID: the vendor is unknown or is not a vendor of this Entity' using errcode = 'invalid_parameter_value';
    end if;
    if c.status <> 'active' then
      raise exception 'INVALID: an inactive contact cannot be used for a new expense' using errcode = 'invalid_parameter_value';
    end if;
  end if;
  select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
  if not found or not fa.is_active then
    raise exception 'INVALID: choose an active paying account of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_date is null then
    raise exception 'INVALID: the expense date is required' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  if fa.currency = v_base then
    if p_rate is not null then
      raise exception 'INVALID: a base-currency expense has no exchange rate' using errcode = 'invalid_parameter_value';
    end if;
  else
    if p_rate is null or not app_private.is_finite(p_rate) or p_rate <= 0 or p_rate >= 10::numeric ^ 10
       or app_private.round_amount(p_rate, 10, 'down') <> p_rate then
      raise exception 'INVALID: a foreign-currency expense needs a positive exchange rate with at most 10 decimals'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  return fa.currency;
end
$$;

create function app_private.expense_write_lines(p_entity uuid, p_expense uuid, p_prepared jsonb) returns void
language plpgsql as $$
begin
  delete from public.expense_lines where expense_id = p_expense and entity_id = p_entity;
  insert into public.expense_lines
    (entity_id, expense_id, line_no, description, quantity, unit_price, line_subtotal, line_total, treatment,
     category_id, account_id)
  select p_entity, p_expense, (l ->> 'line_no')::smallint, l ->> 'description', (l ->> 'quantity')::numeric,
         (l ->> 'unit_price')::numeric, (l ->> 'line_total')::numeric, (l ->> 'line_total')::numeric, l ->> 'treatment',
         nullif(l ->> 'category_id', '')::uuid, nullif(l ->> 'account_id', '')::uuid
  from jsonb_array_elements(p_prepared -> 'lines') l;
end
$$;

-- ------------------------------------------------------------ draft commands
create function public.create_expense_draft(
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
     notes, internal_note, subtotal, total)
  values
    (p_entity, p_payee_id, v_name, v_ref, p_account, v_currency, p_rate, p_expense_date,
     nullif(btrim(coalesce(p_notes, '')), ''), nullif(btrim(coalesce(p_internal_note, '')), ''),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'total')::numeric)
  returning id into v_id;
  perform app_private.expense_write_lines(p_entity, v_id, v_prep);
  perform app_private.idem_complete('expense.create', p_entity, p_key, 'expenses', v_id);
  return v_id;
end
$$;

create function public.update_expense_draft(p_expense uuid, p_patch jsonb, p_expected_version integer default null)
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
        'category_id', l.category_id, 'account_id', l.account_id) order by l.line_no), '[]'::jsonb)
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
      subtotal = (v_prep ->> 'subtotal')::numeric, total = (v_prep ->> 'total')::numeric
  where id = x.id
  returning version into v_new_version;
  perform app_private.expense_write_lines(x.entity_id, x.id, v_prep);
  return v_new_version;
end
$$;

-- ------------------------------------------------------------ submit, recall, reject
create function public.submit_expense(p_expense uuid, p_key text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  x public.expenses%rowtype;
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into x from public.expenses where id = p_expense;
  if not found or not app_authz.has_permission(x.entity_id, 'bills.submit') then
    raise exception 'FORBIDDEN: missing bills.submit' using errcode = 'insufficient_privilege';
  end if;
  select * into x from public.expenses where id = p_expense for update;
  v_replay := app_private.idem_begin('expense.submit', x.entity_id, p_key, md5(p_expense::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if x.status <> 'draft' then
    raise exception 'CONFLICT: only a draft expense can be submitted (now %)', x.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.expense_check_header(x.entity_id, x.payee_id, x.payee_name, x.financial_account_id, x.expense_date,
                                           x.exchange_rate, x.receipt_reference);
  if not exists (select 1 from public.expense_lines where expense_id = x.id) or x.total <= 0 then
    raise exception 'INVALID: an expense needs at least one line with an amount' using errcode = 'invalid_parameter_value';
  end if;
  update public.expenses set status = 'submitted', submitted_at = now(), submitted_by = auth.uid() where id = x.id;
  perform app_private.idem_complete('expense.submit', x.entity_id, p_key, 'expenses', x.id);
  return x.id;
end
$$;

create function public.recall_expense(p_expense uuid) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  x public.expenses%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into x from public.expenses where id = p_expense;
  if not found or not app_authz.has_permission(x.entity_id, 'bills.edit') then
    raise exception 'FORBIDDEN: missing bills.edit' using errcode = 'insufficient_privilege';
  end if;
  select * into x from public.expenses where id = p_expense for update;
  if x.status <> 'submitted' then
    raise exception 'CONFLICT: only a submitted expense can be recalled (now %)', x.status
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.expenses set status = 'draft', submitted_at = null, submitted_by = null where id = x.id;
  return 'draft';
end
$$;

create function public.reject_expense(p_expense uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  x public.expenses%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into x from public.expenses where id = p_expense;
  if not found or not app_authz.has_permission(x.entity_id, 'bills.pay') then
    raise exception 'FORBIDDEN: missing bills.pay' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 3 and 1000 then
    raise exception 'INVALID: a rejection needs a reason' using errcode = 'invalid_parameter_value';
  end if;
  select * into x from public.expenses where id = p_expense for update;
  if x.status <> 'submitted' then
    raise exception 'CONFLICT: only a submitted expense can be rejected (now %)', x.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.expenses
  set status = 'draft', submitted_at = null, submitted_by = null, rejected_at = now(), rejected_by = auth.uid(),
      reject_reason = left(v_reason, 1000)
  where id = x.id;
  return 'draft';
end
$$;

-- ------------------------------------------------------------ confirm = recognise and pay (Step 04 §4)
-- Assumes the caller holds the expense row lock and has checked permission, idempotency and maker-checker.
create function app_private.confirm_expense_core(p_expense uuid, p_duplicate_reason text) returns uuid
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
  if exists (select 1 from public.expense_lines where expense_id = x.id and tax_amount <> 0) or x.tax_total <> 0 then
    raise exception 'CONFLICT: tax lines are produced by the tax engine, which is not active yet; nothing is guessed'
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
  select array_agg(line_total order by line_no) into v_weights from public.expense_lines where expense_id = x.id;
  v_alloc := app_private.allocate_amount(v_base_total, v_weights, v_scale);

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
  v_lines := app_private.add_line(v_lines, fa.ledger_account_id, 0, v_base_total, v_desc,
    app_private.orig_fields(x.currency, v_base, x.total, x.exchange_rate, v_base_total));

  v_journal := app_private.post_system_journal(
    x.entity_id, 'expense', x.id, 'expense.confirm', 'expense.v1', x.expense_date, v_desc, v_lines);
  perform app_private.record_movement(x.entity_id, x.financial_account_id, 'out', x.total, v_base_total, x.exchange_rate,
    x.expense_date, 'expense', x.id, 'principal', v_journal, v_desc);

  update public.expenses
  set status = 'confirmed', expense_number = v_number, journal_id = v_journal, confirmed_at = now(),
      confirmed_by = auth.uid(), base_total = v_base_total, duplicate_ack_reason = left(v_ack, 1000),
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

create function public.confirm_expense(p_expense uuid, p_key text, p_duplicate_reason text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  x public.expenses%rowtype;
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into x from public.expenses where id = p_expense;
  if not found or not app_authz.has_permission(x.entity_id, 'bills.pay') then
    raise exception 'FORBIDDEN: missing bills.pay' using errcode = 'insufficient_privilege';
  end if;
  select * into x from public.expenses where id = p_expense for update;
  v_replay := app_private.idem_begin('expense.confirm', x.entity_id, p_key,
    md5(jsonb_build_object('x', p_expense, 'dup', p_duplicate_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if x.status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: only a draft or submitted expense can be confirmed (now %)', x.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_maker_checker(x.entity_id, 'bills', 'pay',
    app_private.approval_base_amount(x.entity_id, x.total, x.exchange_rate),
    case when auth.uid() in (x.created_by, x.submitted_by, x.updated_by) then auth.uid() else x.created_by end,
    'confirm this expense');
  perform app_private.confirm_expense_core(p_expense, p_duplicate_reason);
  perform app_private.idem_complete('expense.confirm', x.entity_id, p_key, 'expenses', p_expense);
  return p_expense;
end
$$;

-- ------------------------------------------------------------ cancel / reverse / correct
create function app_private.close_expense_core(
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

create function public.cancel_expense(p_expense uuid, p_key text, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  x public.expenses%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into x from public.expenses where id = p_expense;
  if not found or not (app_authz.has_permission(x.entity_id, 'bills.edit')
                       or app_authz.has_permission(x.entity_id, 'bills.void')) then
    raise exception 'FORBIDDEN: missing bills.edit' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a cancellation needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into x from public.expenses where id = p_expense for update;
  v_replay := app_private.idem_begin('expense.close', x.entity_id, p_key,
    md5(jsonb_build_object('x', p_expense, 't', 'cancelled', 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not app_authz.has_permission(x.entity_id, case when x.status = 'draft' then 'bills.edit' else 'bills.void' end) then
    raise exception 'FORBIDDEN: missing bills.void' using errcode = 'insufficient_privilege';
  end if;
  if x.status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: only a draft or submitted expense can be cancelled (now %); reverse a confirmed expense instead', x.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.close_expense_core(p_expense, 'cancelled', v_reason, null);
  perform app_private.idem_complete('expense.close', x.entity_id, p_key, 'expenses', p_expense);
  return p_expense;
end
$$;

create function public.reverse_expense(p_expense uuid, p_key text, p_reason text, p_date date default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  x public.expenses%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into x from public.expenses where id = p_expense;
  if not found or not app_authz.has_permission(x.entity_id, 'bills.void') then
    raise exception 'FORBIDDEN: missing bills.void' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a reversal needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into x from public.expenses where id = p_expense for update;
  v_replay := app_private.idem_begin('expense.close', x.entity_id, p_key,
    md5(jsonb_build_object('x', p_expense, 't', 'reversed', 'r', v_reason, 'd', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if x.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed expense can be reversed (now %)', x.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.close_expense_core(p_expense, 'reversed', v_reason, p_date);
  perform app_private.idem_complete('expense.close', x.entity_id, p_key, 'expenses', p_expense);
  return p_expense;
end
$$;

create function public.correct_expense(p_expense uuid, p_key text, p_reason text, p_date date default null) returns uuid
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
      'category_id', l.category_id, 'account_id', l.account_id) order by l.line_no), '[]'::jsonb)
    into v_lines from public.expense_lines l where l.expense_id = x.id;
  v_prep := app_private.purchase_prepare_lines(x.entity_id, x.currency, v_lines, true);
  insert into public.expenses
    (entity_id, payee_id, payee_name, receipt_reference, financial_account_id, currency, exchange_rate, expense_date,
     notes, internal_note, subtotal, total, replaces_expense_id)
  values
    (x.entity_id, x.payee_id, x.payee_name, x.receipt_reference, x.financial_account_id, x.currency, x.exchange_rate,
     x.expense_date, x.notes, left('Replaces ' || x.expense_number || ': ' || v_reason, 2000),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'total')::numeric, x.id)
  returning id into v_new;
  perform app_private.expense_write_lines(x.entity_id, v_new, v_prep);

  perform app_private.close_expense_core(p_expense, 'reversed', v_reason, p_date, v_new);
  perform app_private.idem_complete('expense.correct', x.entity_id, p_key, 'expenses', v_new);
  return v_new;
end
$$;

-- ------------------------------------------------------------ evidence documents (Step 08 §17, Step 11)
-- A document is registered by its content hash. The bytes themselves are stored by the upload flow of P11;
-- `storage_path` stays empty until then. Identical content is registered once per Entity.
create table public.documents (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  file_name text not null check (length(file_name) between 1 and 255 and file_name !~ '[\\/[:cntrl:]]'),
  mime_type text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 26214400),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  storage_path text check (storage_path is null or length(storage_path) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (entity_id, sha256)
);

-- Only the storage location may be set later (by the upload flow); the identity of a document never changes.
create function app_private.tg_documents_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['storage_path', 'updated_at', 'updated_by', 'version'];
begin
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'A registered document cannot be changed' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.documents
  for each row execute function app_private.tg_documents_guard();
create trigger tg_forbid_delete before delete on public.documents
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.documents
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.documents');
call app_private.secure_table('public.documents');
create trigger tg_audit after insert or update or delete on public.documents
  for each row execute function app_private.tg_audit('entity_id');

create table public.document_links (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  document_id uuid not null,
  target_type text not null check (target_type in ('bill', 'expense')),
  target_id uuid not null,
  purpose text not null default 'receipt' check (purpose in ('vendor_invoice', 'receipt', 'contract', 'other')),
  status text not null default 'active' check (status in ('active', 'removed')),
  removed_at timestamptz,
  removed_by uuid,
  removed_reason text check (removed_reason is null or length(removed_reason) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, document_id) references public.documents (entity_id, id) on delete restrict,
  constraint document_link_removed_shape check (
    (status = 'active' and removed_at is null and removed_by is null)
    or (status = 'removed' and removed_at is not null and removed_reason is not null))
);
create unique index document_links_active_uq on public.document_links (document_id, target_type, target_id)
  where status = 'active';
create index document_links_target_idx on public.document_links (entity_id, target_type, target_id, status);

-- A polymorphic target cannot be a foreign key: the trigger checks it exists in the same Entity and is not closed.
create function app_private.tg_document_links_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
  v_lock constant text[] := array['status', 'removed_at', 'removed_by', 'removed_reason', 'updated_at', 'updated_by',
                                   'version'];
begin
  if tg_op = 'INSERT' then
    if new.target_type = 'bill' then
      select b.status into v_status from public.bills b
      where b.id = new.target_id and b.entity_id = new.entity_id for share;
    else
      select x.status into v_status from public.expenses x
      where x.id = new.target_id and x.entity_id = new.entity_id for share;
    end if;
    if v_status is null then
      raise exception 'INVALID: the % does not exist in this Entity', new.target_type using errcode = 'invalid_parameter_value';
    end if;
    if v_status in ('cancelled', 'void', 'reversed') then
      raise exception 'CONFLICT: a % % takes no more documents', v_status, new.target_type
        using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;
  if old.status = 'removed' then
    raise exception 'A removed document link cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'A document link cannot be edited; remove it and add a new one' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.document_links
  for each row execute function app_private.tg_document_links_guard();
create trigger tg_forbid_delete before delete on public.document_links
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.document_links
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.document_links');
call app_private.secure_table('public.document_links');
create trigger tg_audit after insert or update or delete on public.document_links
  for each row execute function app_private.tg_audit('entity_id');

-- Registers a document by content hash. The same content in the same Entity returns the document already there.
create function public.register_document(
  p_entity uuid, p_key text, p_file_name text, p_mime_type text, p_size_bytes bigint, p_sha256 text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
  v_hash text := lower(btrim(coalesce(p_sha256, '')));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'documents.upload') then
    raise exception 'FORBIDDEN: missing documents.upload' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('document.register', p_entity, p_key,
    md5(jsonb_build_object('n', p_file_name, 'm', p_mime_type, 's', p_size_bytes, 'h', v_hash)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_mime_type is null or p_size_bytes is null then
    raise exception 'INVALID: the document needs a file type and a size' using errcode = 'invalid_parameter_value';
  end if;
  select d.id into v_id from public.documents d where d.entity_id = p_entity and d.sha256 = v_hash;
  if v_id is null then
    begin
      insert into public.documents (entity_id, file_name, mime_type, size_bytes, sha256)
      values (p_entity, btrim(coalesce(p_file_name, '')), p_mime_type, p_size_bytes, v_hash)
      returning id into v_id;
    exception
      when check_violation then
        raise exception 'INVALID: the document needs a plain file name, a PDF or image type, a size up to 25 MB and a SHA-256 hash'
          using errcode = 'invalid_parameter_value';
      when unique_violation then
        -- The same content was registered by a concurrent call: it is the same document.
        select d.id into v_id from public.documents d where d.entity_id = p_entity and d.sha256 = v_hash;
    end;
  end if;
  perform app_private.idem_complete('document.register', p_entity, p_key, 'documents', v_id);
  return v_id;
end
$$;

create function public.link_document(p_document uuid, p_target_type text, p_target_id uuid, p_purpose text default 'receipt')
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  d public.documents%rowtype;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into d from public.documents where id = p_document;
  if not found or not app_authz.has_permission(d.entity_id, 'documents.upload')
     or not (app_authz.has_permission(d.entity_id, 'bills.create') or app_authz.has_permission(d.entity_id, 'bills.edit')) then
    raise exception 'FORBIDDEN: attaching a document needs documents.upload and bills.create' using errcode = 'insufficient_privilege';
  end if;
  if p_target_type not in ('bill', 'expense') then
    raise exception 'INVALID: documents attach to a bill or an expense' using errcode = 'invalid_parameter_value';
  end if;
  if coalesce(p_purpose, 'receipt') not in ('vendor_invoice', 'receipt', 'contract', 'other') then
    raise exception 'INVALID: the purpose is vendor_invoice, receipt, contract or other' using errcode = 'invalid_parameter_value';
  end if;
  select l.id into v_id from public.document_links l
  where l.document_id = d.id and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active';
  if v_id is not null then
    return v_id;
  end if;
  begin
    insert into public.document_links (entity_id, document_id, target_type, target_id, purpose)
    values (d.entity_id, d.id, p_target_type, p_target_id, coalesce(p_purpose, 'receipt'))
    returning id into v_id;
  exception when unique_violation then
    -- A concurrent call attached the same document to the same target: return that link.
    select l.id into v_id from public.document_links l
    where l.document_id = d.id and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active';
  end;
  return v_id;
end
$$;

-- Evidence can be removed only while the purchase is still being prepared; afterwards it is part of the record.
create function public.unlink_document(p_link uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.document_links%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.document_links where id = p_link;
  if not found or not app_authz.has_permission(l.entity_id, 'documents.upload')
     or not (app_authz.has_permission(l.entity_id, 'bills.create') or app_authz.has_permission(l.entity_id, 'bills.edit')) then
    raise exception 'FORBIDDEN: removing a document needs documents.upload and bills.create' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 3 and 1000 then
    raise exception 'INVALID: a reason is required' using errcode = 'invalid_parameter_value';
  end if;
  select * into l from public.document_links where id = p_link for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: this document link is already removed' using errcode = 'integrity_constraint_violation';
  end if;
  if l.target_type = 'bill' then
    select b.status into v_status from public.bills b where b.id = l.target_id and b.entity_id = l.entity_id for share;
  else
    select x.status into v_status from public.expenses x where x.id = l.target_id and x.entity_id = l.entity_id for share;
  end if;
  if v_status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: evidence of a % % is part of the record and cannot be removed', v_status, l.target_type
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.document_links
  set status = 'removed', removed_at = now(), removed_by = auth.uid(), removed_reason = left(v_reason, 500)
  where id = l.id;
  return 'removed';
end
$$;

create function public.list_document_links(p_entity uuid, p_target_type text, p_target_id uuid)
returns table (
  link_id uuid, document_id uuid, file_name text, mime_type text, size_bytes bigint, sha256 text, purpose text,
  created_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'documents.view') or not app_authz.has_permission(p_entity, 'bills.view') then
    raise exception 'FORBIDDEN: missing documents.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select l.id, d.id, d.file_name, d.mime_type, d.size_bytes, d.sha256, l.purpose, l.created_at
  from public.document_links l
  join public.documents d on d.id = l.document_id and d.entity_id = l.entity_id
  where l.entity_id = p_entity and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active'
  order by l.created_at, l.id;
end
$$;

-- Recognised purchases without any evidence attached (Step 08 §17): a list to work through, never a block.
create function public.list_missing_evidence(p_entity uuid, p_from date default null, p_to date default null)
returns table (
  doc_kind text, doc_id uuid, doc_number text, doc_date date, party_name text, currency text, total text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.view') or not app_authz.has_permission(p_entity, 'documents.view') then
    raise exception 'FORBIDDEN: missing bills.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select 'bill'::text, b.id, b.bill_number, b.bill_date, c.display_name, b.currency::text, b.total::text
  from public.bills b
  join public.contacts c on c.id = b.vendor_id and c.entity_id = b.entity_id
  where b.entity_id = p_entity and b.status = 'approved'
    and (p_from is null or b.bill_date >= p_from) and (p_to is null or b.bill_date <= p_to)
    and not exists (select 1 from public.document_links l
                    where l.entity_id = b.entity_id and l.target_type = 'bill' and l.target_id = b.id and l.status = 'active')
  union all
  select 'expense'::text, x.id, x.expense_number, x.expense_date,
         coalesce((select co.display_name from public.contacts co where co.id = x.payee_id and co.entity_id = x.entity_id),
                  x.payee_name),
         x.currency::text, x.total::text
  from public.expenses x
  where x.entity_id = p_entity and x.status = 'confirmed'
    and (p_from is null or x.expense_date >= p_from) and (p_to is null or x.expense_date <= p_to)
    and not exists (select 1 from public.document_links l
                    where l.entity_id = x.entity_id and l.target_type = 'expense' and l.target_id = x.id and l.status = 'active')
  order by 4, 3;
end
$$;

-- ------------------------------------------------------------ period close checks (final form for P6)
create or replace function app_private.period_blockers(p_period uuid)
returns table (code text, severity text, message text, item_count bigint)
language plpgsql stable as $$
declare
  v_p public.accounting_periods%rowtype;
  v_n bigint;
begin
  select * into v_p from public.accounting_periods where id = p_period;
  if not found then
    raise exception 'INVALID: unknown accounting period' using errcode = 'invalid_parameter_value';
  end if;

  select count(*) into v_n from public.journal_entries j where j.period_id = p_period and j.status = 'draft';
  if v_n > 0 then
    return query select 'draft_journals'::text, 'blocker'::text,
      'Draft journals exist in this period and must be posted or discarded'::text, v_n;
  end if;

  -- Detective control: posted journals are balanced by construction; a mismatch means corruption.
  select count(*) into v_n from (
    select j.id
    from public.journal_entries j
    join public.journal_lines l on l.journal_id = j.id
    where j.period_id = p_period and j.status = 'posted'
    group by j.id
    having sum(l.debit) <> sum(l.credit)
  ) q;
  if v_n > 0 then
    return query select 'unbalanced_posted_journals'::text, 'blocker'::text,
      'Posted journals with debit different from credit were found'::text, v_n;
  end if;

  -- Migration must be signed off before normal production posting (Step 15 §24).
  select count(*) into v_n
  from public.opening_balance_batches b
  where b.entity_id = v_p.entity_id and b.status = 'posted'
    and b.cutover_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'opening_not_completed'::text, 'blocker'::text,
      'Opening balances in this period have not been completed and signed off'::text, v_n;
  end if;

  select count(*) into v_n from public.journal_entries j where j.period_id = p_period and j.status = 'posted';
  if v_n = 0 then
    return query select 'empty_period'::text, 'warning'::text,
      'The period has no posted journals'::text, 0::bigint;
  end if;

  -- Money layer against the General Ledger, as of the end of the period (Step 04 §13).
  select count(*) into v_n from app_private.money_control_rows(v_p.entity_id, v_p.period_end) r
  where r.ledger_balance <> r.movement_base_balance;
  if v_n > 0 then
    return query select 'money_ledger_mismatch'::text, 'blocker'::text,
      'Cash/bank balances from money movements differ from the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from app_private.money_control_rows(v_p.entity_id, v_p.period_end) r
  where r.movement_balance < 0;
  if v_n > 0 then
    return query select 'negative_cash_balance'::text, 'warning'::text,
      'A cash/bank account has a negative balance at the end of the period'::text, v_n;
  end if;

  select count(*) into v_n
  from public.statement_lines l
  join public.reconciliation_sessions s on s.id = l.session_id and s.status in ('open', 'reopened')
  where l.entity_id = v_p.entity_id and l.line_date between v_p.period_start and v_p.period_end
    and not l.is_excluded
    and not exists (select 1 from public.reconciliation_matches m where m.statement_line_id = l.id);
  if v_n > 0 then
    return query select 'unresolved_statement_lines'::text, 'warning'::text,
      'Bank statement lines of this period are neither matched nor excluded'::text, v_n;
  end if;

  select count(*) into v_n
  from public.financial_accounts fa
  where fa.entity_id = v_p.entity_id and fa.is_active
    and exists (select 1 from public.money_movements mv
                where mv.financial_account_id = fa.id and mv.movement_date between v_p.period_start and v_p.period_end
                  and mv.source_type <> 'opening_balance')
    and not exists (select 1 from public.reconciliation_sessions s
                    where s.financial_account_id = fa.id and s.status = 'reconciled' and s.period_end >= v_p.period_end);
  if v_n > 0 then
    return query select 'account_not_reconciled'::text, 'warning'::text,
      'Active cash/bank accounts with movements in this period are not reconciled up to its end'::text, v_n;
  end if;

  -- A completed reconciliation whose book balance no longer matches what it recorded: something was booked
  -- inside the reconciled window afterwards, so its evidence is stale.
  select count(*) into v_n
  from public.reconciliation_sessions s
  where s.entity_id = v_p.entity_id and s.status = 'reconciled'
    and s.period_start <= v_p.period_end and s.period_end >= v_p.period_start
    and s.system_book_balance is distinct from app_private.account_balance(s.financial_account_id, s.period_end);
  if v_n > 0 then
    return query select 'reconciliation_stale'::text, 'warning'::text,
      'A completed reconciliation no longer matches the books: movements were added inside its period afterwards'::text, v_n;
  end if;

  -- Cash/bank ledger accounts with postings but no financial account are invisible to the money control.
  select count(distinct a.id) into v_n
  from public.ledger_accounts a
  join public.journal_lines l on l.ledger_account_id = a.id
  join public.journal_entries j on j.id = l.journal_id and j.status = 'posted' and j.period_id = p_period
  where a.entity_id = v_p.entity_id and app_private.is_cash_ledger_account(v_p.entity_id, a.id)
    and not exists (select 1 from public.financial_accounts fa where fa.ledger_account_id = a.id);
  if v_n > 0 then
    return query select 'unmapped_cash_account'::text, 'warning'::text,
      'Cash/bank ledger accounts with postings in this period have no financial account, so the money layer cannot check them'::text, v_n;
  end if;
  -- Sales sub-ledgers against the General Ledger, as of the end of the period (Step 04 §13). Only journals the sales
  -- workflow produced take part; opening balances and other sources are shown separately in the AR control report.
  select count(*) into v_n from app_private.ar_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_sales;
  if v_n > 0 then
    return query select 'ar_ledger_mismatch'::text, 'blocker'::text,
      'Accounts receivable from invoices and payments differs from the General Ledger'::text, v_n;
  end if;
  select count(*) into v_n from app_private.ar_control(v_p.entity_id, v_p.period_end) c
  where c.advance_sub_ledger <> c.advance_ledger_sales;
  if v_n > 0 then
    return query select 'advance_ledger_mismatch'::text, 'blocker'::text,
      'Customer advances from payments differ from the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from public.invoices i
  where i.entity_id = v_p.entity_id and i.status = 'draft' and i.issue_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'draft_invoices'::text, 'warning'::text,
      'Draft invoices dated in this period are not issued yet and are not in the books'::text, v_n;
  end if;

  select count(*) into v_n from public.payment_submissions s
  where s.entity_id = v_p.entity_id and s.status = 'pending' and s.payment_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'pending_payment_claims'::text, 'warning'::text,
      'Customer payment claims dated in this period are still waiting for verification'::text, v_n;
  end if;

  -- Purchase sub-ledger against the General Ledger, as of the end of the period (Step 04 §13). Only journals the
  -- purchase workflow produced take part; opening balances and other sources are shown separately in the AP control.
  select count(*) into v_n from app_private.ap_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_purchases;
  if v_n > 0 then
    return query select 'ap_ledger_mismatch'::text, 'blocker'::text,
      'Accounts payable from bills and vendor payments differs from the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from public.bills b
  where b.entity_id = v_p.entity_id and b.status in ('draft', 'submitted')
    and b.bill_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'unapproved_bills'::text, 'warning'::text,
      'Draft or submitted bills dated in this period are not approved yet and are not in the books'::text, v_n;
  end if;

  select count(*) into v_n from public.expenses x
  where x.entity_id = v_p.entity_id and x.status in ('draft', 'submitted')
    and x.expense_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'unconfirmed_expenses'::text, 'warning'::text,
      'Draft or submitted expenses dated in this period are not confirmed yet and are not in the books'::text, v_n;
  end if;

  -- Recognised purchases with no evidence attached (Step 08 §17): worth a look before closing, never a block.
  select count(*) into v_n from (
    select b.id from public.bills b
    where b.entity_id = v_p.entity_id and b.status = 'approved'
      and b.bill_date between v_p.period_start and v_p.period_end
      and not exists (select 1 from public.document_links l
                      where l.entity_id = b.entity_id and l.target_type = 'bill' and l.target_id = b.id and l.status = 'active')
    union all
    select x.id from public.expenses x
    where x.entity_id = v_p.entity_id and x.status = 'confirmed'
      and x.expense_date between v_p.period_start and v_p.period_end
      and not exists (select 1 from public.document_links l
                      where l.entity_id = x.entity_id and l.target_type = 'expense' and l.target_id = x.id and l.status = 'active')
  ) q;
  if v_n > 0 then
    return query select 'purchases_without_evidence'::text, 'warning'::text,
      'Bills and expenses of this period have no supporting document attached'::text, v_n;
  end if;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.expenses');
create policy expenses_select on public.expenses for select to authenticated
  using (app_authz.has_permission(entity_id, 'bills.view'));
call app_private.expose_select('public.expense_lines');
create policy expense_lines_select on public.expense_lines for select to authenticated
  using (app_authz.has_permission(entity_id, 'bills.view'));
call app_private.expose_select('public.documents');
create policy documents_select on public.documents for select to authenticated
  using (app_authz.has_permission(entity_id, 'documents.view'));
call app_private.expose_select('public.document_links');
create policy document_links_select on public.document_links for select to authenticated
  using (app_authz.has_permission(entity_id, 'documents.view'));

revoke all on function app_private.lock_purchase_party(uuid, uuid, text) from public;
revoke all on function app_private.tg_expenses_guard() from public;
revoke all on function app_private.tg_expense_lines_guard() from public;
revoke all on function app_private.tg_documents_guard() from public;
revoke all on function app_private.tg_document_links_guard() from public;
revoke all on function app_private.purchase_duplicates(uuid, text, uuid, text, text, date, public.currency_code, numeric, uuid) from public;
revoke all on function app_private.expense_check_header(uuid, uuid, text, uuid, date, numeric, text) from public;
revoke all on function app_private.expense_write_lines(uuid, uuid, jsonb) from public;
revoke all on function app_private.confirm_expense_core(uuid, text) from public;
revoke all on function app_private.close_expense_core(uuid, text, text, date, uuid) from public;
revoke all on function app_private.period_blockers(uuid) from public;

revoke all on function public.find_purchase_duplicates(uuid, uuid, text, text, date, text, numeric, text, uuid) from public, anon;
revoke all on function public.create_expense_draft(uuid, text, uuid, date, jsonb, uuid, text, text, numeric, text, text) from public, anon;
revoke all on function public.update_expense_draft(uuid, jsonb, integer) from public, anon;
revoke all on function public.submit_expense(uuid, text) from public, anon;
revoke all on function public.recall_expense(uuid) from public, anon;
revoke all on function public.reject_expense(uuid, text) from public, anon;
revoke all on function public.confirm_expense(uuid, text, text) from public, anon;
revoke all on function public.cancel_expense(uuid, text, text) from public, anon;
revoke all on function public.reverse_expense(uuid, text, text, date) from public, anon;
revoke all on function public.correct_expense(uuid, text, text, date) from public, anon;
revoke all on function public.register_document(uuid, text, text, text, bigint, text) from public, anon;
revoke all on function public.link_document(uuid, text, uuid, text) from public, anon;
revoke all on function public.unlink_document(uuid, text) from public, anon;
revoke all on function public.list_document_links(uuid, text, uuid) from public, anon;
revoke all on function public.list_missing_evidence(uuid, date, date) from public, anon;
grant execute on function public.find_purchase_duplicates(uuid, uuid, text, text, date, text, numeric, text, uuid) to authenticated;
grant execute on function public.create_expense_draft(uuid, text, uuid, date, jsonb, uuid, text, text, numeric, text, text) to authenticated;
grant execute on function public.update_expense_draft(uuid, jsonb, integer) to authenticated;
grant execute on function public.submit_expense(uuid, text) to authenticated;
grant execute on function public.recall_expense(uuid) to authenticated;
grant execute on function public.reject_expense(uuid, text) to authenticated;
grant execute on function public.confirm_expense(uuid, text, text) to authenticated;
grant execute on function public.cancel_expense(uuid, text, text) to authenticated;
grant execute on function public.reverse_expense(uuid, text, text, date) to authenticated;
grant execute on function public.correct_expense(uuid, text, text, date) to authenticated;
grant execute on function public.register_document(uuid, text, text, text, bigint, text) to authenticated;
grant execute on function public.link_document(uuid, text, uuid, text) to authenticated;
grant execute on function public.unlink_document(uuid, text) to authenticated;
grant execute on function public.list_document_links(uuid, text, uuid) to authenticated;
grant execute on function public.list_missing_evidence(uuid, date, date) to authenticated;
