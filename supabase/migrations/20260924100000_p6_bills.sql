-- P6 (Step 15 §10) part 1: vendor bills - draft, submit, approve (recognition) and their arithmetic.
-- Authority: Step 01 #15-#17 (bills, direct expenses, contacts, multi-item bills), Step 02 §4 (Purchases),
-- Step 04 §4 (purchase posting matrix), Step 06 §3/§7 (capabilities, maker-checker), Step 07 §5 (bill workflow),
-- Step 08 §8/§17 (AP integrity, duplicate prevention), Step 09 §12 (purchase screens).
--
-- What this part delivers
--   * Vendors are the unified contacts of P1 (kind vendor/both); `create_contact` (P5) already creates them.
--   * Draft bills with server-authoritative line arithmetic. Every line carries its own treatment: an operating
--     expense, an asset purchase (handed to the Asset Register of P8) or a prepayment (Step 04 §4).
--   * Submitted -> Approved workflow with maker-checker. Approving is the ONE step that recognises the bill: the
--     internal bill number is allocated, the vendor snapshot is frozen and "Dr expense/asset/prepaid, Cr Accounts
--     Payable" is posted through the posting engine, once (Step 04 §4, Step 08 §8).
--   * Tax is a separate engine (Step 05, P7): bill lines carry a tax amount that is always zero until that phase
--     plugs in; approving a bill that already carries tax is refused instead of guessed.
-- Vendor payments, settlement state, cancel/void/correct and the AP control follow in part 2; direct expenses,
-- duplicate detection and evidence in part 3.

-- ------------------------------------------------------------ numbering families of the purchase documents
alter table public.numbering_sequences drop constraint numbering_sequences_scope_check;
alter table public.numbering_sequences add constraint numbering_sequences_scope_check
  check (scope in ('invoice', 'payment_receipt', 'refund_receipt', 'bill', 'bill_payment', 'expense', 'journal',
                   'transfer', 'other'));

-- Existing configuration is never touched; the OWNER can change a prefix afterwards.
create function app_private.ensure_purchase_numbering(p_entity uuid) returns void
language plpgsql as $$
begin
  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (p_entity, 'bill', 'BILL'),
         (p_entity, 'bill_payment', 'PAY'),
         (p_entity, 'expense', 'EXP')
  on conflict (entity_id, scope) do nothing;
end
$$;

-- ------------------------------------------------------------ which ledger account a purchase line may use
-- Fixed-asset accounts: the system fixed-asset accounts and the accounts the OWNER added under the same parent
-- group (Step 03 §5). Names and codes are never matched (Step 04 §16).
create function app_private.is_fixed_asset_account(p_entity uuid, p_account uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.ledger_accounts a
    where a.id = p_account and a.entity_id = p_entity and a.account_class = 'asset' and not a.is_group
      and (a.system_key in ('FIXED_ASSET_EQUIPMENT', 'FIXED_ASSET_FURNITURE', 'FIXED_ASSET_OTHER', 'PERSONAL_FIXED_ASSET')
           or (a.system_key is null and a.parent_id is not null
               and a.parent_id = (select c.parent_id from public.ledger_accounts c
                                  where c.entity_id = p_entity and c.system_key = 'FIXED_ASSET_EQUIPMENT'))))
$$;

create function app_private.purchase_account_ok(
  p_entity uuid, p_account uuid, p_treatment text, p_require_active boolean default true)
returns boolean
language sql stable as $$
  select exists (
    select 1 from public.ledger_accounts a
    where a.id = p_account and a.entity_id = p_entity and not a.is_group
      and (a.status = 'active' or not p_require_active)
      and case p_treatment
            when 'expense' then a.account_class in ('expense', 'other_expense')
            when 'asset' then app_private.is_fixed_asset_account(p_entity, a.id)
            when 'prepaid' then a.system_key in ('PREPAID_EXPENSE', 'PREPAID_DEPOSIT', 'ADVANCES_DEPOSITS')
            else false end)
$$;

-- Where a treatment lands when neither the line nor its category names an account.
create function app_private.default_purchase_account(p_entity uuid, p_treatment text) returns uuid
language sql stable as $$
  select a.id from public.ledger_accounts a
  where a.entity_id = p_entity and a.status = 'active' and not a.is_group
    and a.system_key = any (case p_treatment
      when 'expense' then array['OTHER_OPERATING_EXPENSE', 'OTHER_PERSONAL_EXPENSE']
      when 'asset' then array['FIXED_ASSET_OTHER', 'PERSONAL_FIXED_ASSET']
      else array['PREPAID_EXPENSE', 'PREPAID_DEPOSIT'] end)
  order by a.system_key
  limit 1
$$;

-- The account a line is booked to: the line's own choice, else the effective category mapping for the purchase
-- context (then the default context), else the Entity default of its treatment (Step 03 §6).
create function app_private.resolve_purchase_account(
  p_entity uuid, p_category uuid, p_treatment text, p_account uuid, p_date date)
returns uuid
language plpgsql stable as $$
declare
  v_id uuid;
begin
  if p_account is not null then
    return p_account;
  end if;
  if p_category is not null then
    select m.debit_ledger_account_id into v_id
    from public.category_account_mappings m
    where m.entity_id = p_entity and m.category_id = p_category and m.context in ('purchases', 'default')
      and m.debit_ledger_account_id is not null
      and app_private.purchase_account_ok(p_entity, m.debit_ledger_account_id, p_treatment)
      and m.effective_from <= p_date and (m.effective_to is null or m.effective_to >= p_date)
    order by (m.context = 'purchases') desc
    limit 1;
  end if;
  return coalesce(v_id, app_private.default_purchase_account(p_entity, p_treatment));
end
$$;

-- ------------------------------------------------------------ line arithmetic (server-authoritative)
-- Canonical, fully computed lines for bills and direct expenses. The caller never supplies a total: quantity x
-- unit price rounds once per line, half-up in the document currency. Lenient mode (corrections) accepts what was
-- valid when the original was recorded, even if a category or account was deactivated since.
create function app_private.purchase_prepare_lines(
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

    v_total := v_total + v_sub;
    v_out := v_out || jsonb_build_object(
      'line_no', v_no, 'description', v_desc, 'quantity', trim_scale(v_qty), 'unit_price', trim_scale(v_price),
      'line_total', v_sub, 'treatment', v_treat, 'category_id', v_cid, 'account_id', v_aid);
  end loop;

  return jsonb_build_object('lines', v_out, 'subtotal', v_total, 'total', v_total);
end
$$;

-- ------------------------------------------------------------ bills
create table public.bills (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  -- Workflow state only. Paid / partially paid / outstanding are DERIVED from active allocations and overdue from
  -- the due date (Step 07 §5); none of them overwrites this column.
  status text not null default 'draft' check (status in ('draft', 'submitted', 'approved', 'cancelled', 'void')),
  -- Our own number, allocated when the bill is recognised (approved) and never reused (Step 08 §16).
  bill_number text,
  vendor_id uuid not null,
  -- The vendor's own invoice / document number: the key of duplicate detection (Step 08 §17).
  vendor_reference text check (vendor_reference is null or length(vendor_reference) <= 100),
  currency public.currency_code not null references public.currencies (code),
  -- Base currency per unit of the bill currency; present exactly for foreign-currency bills.
  exchange_rate public.fx_rate,
  bill_date date not null,
  due_date date not null,
  notes text check (notes is null or length(notes) <= 2000),
  internal_note text check (internal_note is null or length(internal_note) <= 2000),
  subtotal public.money_amount not null default 0 check (subtotal >= 0),
  -- P7 fills tax; until then it is always zero and the approve command refuses anything else.
  tax_total public.money_amount not null default 0 check (tax_total >= 0),
  total public.money_amount not null default 0 check (total >= 0),
  -- The payable in base currency booked at approval (what the sub-ledger later reconciles to the GL).
  base_total public.money_amount not null default 0 check (base_total >= 0),
  tax_status text not null default 'pending_engine' check (tax_status in ('pending_engine')),
  -- Snapshot taken at approval (Step 08 §3): later edits of the contact never rewrite it. The vendor's tax
  -- identifier is deliberately not part of it (Step 06 §6).
  vendor_snapshot jsonb,
  journal_id uuid,
  reversal_journal_id uuid,
  submitted_at timestamptz,
  submitted_by uuid,
  rejected_at timestamptz,
  rejected_by uuid,
  reject_reason text check (reject_reason is null or length(reject_reason) <= 1000),
  approved_at timestamptz,
  approved_by uuid,
  -- When approval went ahead although a likely duplicate exists, the approver's reason stays with the bill.
  duplicate_ack_reason text check (duplicate_ack_reason is null or length(duplicate_ack_reason) <= 1000),
  closed_at timestamptz,
  closed_by uuid,
  closed_date date,
  closed_reason text,
  replaces_bill_id uuid,
  replaced_by_bill_id uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, vendor_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, replaces_bill_id) references public.bills (entity_id, id) on delete restrict,
  foreign key (entity_id, replaced_by_bill_id) references public.bills (entity_id, id) on delete restrict,
  constraint bill_due_after_date check (due_date >= bill_date),
  constraint bill_total_formula check (total = subtotal + tax_total),
  constraint bill_no_self_replacement check (replaces_bill_id is distinct from id and replaced_by_bill_id is distinct from id),
  constraint bill_state_consistent check (
    case status
      when 'draft' then bill_number is null and journal_id is null and reversal_journal_id is null
        and submitted_at is null and approved_at is null and closed_at is null and vendor_snapshot is null
      when 'submitted' then bill_number is null and journal_id is null and reversal_journal_id is null
        and submitted_at is not null and approved_at is null and closed_at is null and vendor_snapshot is null
      when 'approved' then bill_number is not null and journal_id is not null and reversal_journal_id is null
        and approved_at is not null and closed_at is null and vendor_snapshot is not null
        and total > 0 and base_total > 0
      when 'cancelled' then closed_at is not null and closed_date is not null and closed_reason is not null
        and bill_number is null and journal_id is null and reversal_journal_id is null
      else bill_number is not null and journal_id is not null and reversal_journal_id is not null
        and closed_at is not null and closed_date is not null and closed_reason is not null
    end)
);
create unique index bills_number_uq on public.bills (entity_id, bill_number) where bill_number is not null;
create index bills_entity_status_idx on public.bills (entity_id, status, bill_date);
create index bills_vendor_idx on public.bills (entity_id, vendor_id);
create index bills_due_idx on public.bills (entity_id, due_date) where status = 'approved';
create index bills_reference_idx on public.bills (entity_id, vendor_id, lower(btrim(vendor_reference)))
  where vendor_reference is not null;
create unique index bills_one_replacement_uq on public.bills (replaces_bill_id) where replaces_bill_id is not null;

create function app_private.tg_bills_guard() returns trigger
language plpgsql as $$
declare
  v_base public.currency_code;
  v_state constant text[] := array['status', 'submitted_at', 'submitted_by', 'rejected_at', 'rejected_by',
                                    'reject_reason', 'updated_at', 'updated_by', 'version'];
  v_approve constant text[] := array['status', 'bill_number', 'journal_id', 'vendor_snapshot', 'base_total',
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
create trigger tg_guard before insert or update on public.bills
  for each row execute function app_private.tg_bills_guard();
create trigger tg_forbid_delete before delete on public.bills
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.bills
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.bills');
call app_private.secure_table('public.bills');
create trigger tg_audit after insert or update or delete on public.bills
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ bill lines
create table public.bill_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  bill_id uuid not null,
  line_no smallint not null check (line_no > 0),
  description text not null check (length(btrim(description)) between 1 and 500),
  quantity numeric(20, 4) not null check (quantity > 0),
  unit_price public.money_amount not null check (unit_price >= 0),
  line_subtotal public.money_amount not null check (line_subtotal > 0),
  -- Interface to the tax engine (P7): zero until then.
  tax_amount public.money_amount not null default 0 check (tax_amount >= 0),
  line_total public.money_amount not null check (line_total > 0),
  treatment text not null default 'expense' check (treatment in ('expense', 'asset', 'prepaid')),
  category_id uuid,
  -- The account the user chose for this line, if any; otherwise the category mapping / Entity default applies.
  account_id uuid,
  -- Set at approval: the account that was debited and the base-currency amount that was booked.
  posted_account_id uuid,
  base_amount public.money_amount check (base_amount is null or base_amount >= 0),
  -- Hand-off to the Asset Register (P8): asset lines are `pending` from approval on and `linked` once P8 registers them.
  asset_link_status text not null default 'none' check (asset_link_status in ('none', 'pending', 'linked')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (bill_id, line_no),
  foreign key (entity_id, bill_id) references public.bills (entity_id, id) on delete restrict,
  foreign key (entity_id, category_id) references public.categories (entity_id, id) on delete restrict,
  foreign key (entity_id, account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, posted_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  constraint bill_line_formula check (line_total = line_subtotal + tax_amount),
  constraint bill_line_asset_shape check (asset_link_status = 'none' or treatment = 'asset')
);
create index bill_lines_bill_idx on public.bill_lines (entity_id, bill_id, line_no);

-- Lines are edited on drafts only. When the bill is being approved the resolved columns (posted account, base
-- amount, asset hand-off) are written while it is still draft or submitted; nothing else may change then. The
-- parent row is share-locked so a concurrent approval and a line edit serialise.
create function app_private.tg_bill_lines_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
  v_resolved constant text[] := array['posted_account_id', 'base_amount', 'asset_link_status', 'updated_at',
                                       'updated_by', 'version'];
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
create trigger tg_guard before insert or update or delete on public.bill_lines
  for each row execute function app_private.tg_bill_lines_guard();
create trigger tg_forbid_truncate before truncate on public.bill_lines
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.bill_lines');
call app_private.secure_table('public.bill_lines');
create trigger tg_audit after insert or update or delete on public.bill_lines
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ header validation shared by create, update, submit
create function app_private.bill_check_header(
  p_entity uuid, p_vendor uuid, p_date date, p_due date, p_currency public.currency_code, p_rate numeric,
  p_reference text)
returns void
language plpgsql stable as $$
declare
  v_base public.currency_code := app_private.entity_base_currency(p_entity);
  c public.contacts%rowtype;
begin
  if p_vendor is null then
    raise exception 'INVALID: choose a vendor' using errcode = 'invalid_parameter_value';
  end if;
  select * into c from public.contacts where id = p_vendor and entity_id = p_entity;
  if not found or c.kind not in ('vendor', 'both') then
    raise exception 'INVALID: the vendor is unknown or is not a vendor of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  if c.status <> 'active' then
    raise exception 'INVALID: an inactive contact cannot be used for a new bill' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(p_reference, '')) > 100 then
    raise exception 'INVALID: the vendor reference is limited to 100 characters' using errcode = 'invalid_parameter_value';
  end if;
  if p_date is null then
    raise exception 'INVALID: the bill date is required' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_due is not null then
    perform app_private.assert_business_date(p_due);
  end if;
  if p_due is null or p_due < p_date then
    raise exception 'INVALID: the due date cannot be before the bill date' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.currencies where code = p_currency and is_active) then
    raise exception 'INVALID: unknown currency' using errcode = 'invalid_parameter_value';
  end if;
  if p_currency = v_base then
    if p_rate is not null then
      raise exception 'INVALID: a base-currency bill has no exchange rate' using errcode = 'invalid_parameter_value';
    end if;
  else
    if p_rate is null or not app_private.is_finite(p_rate) or p_rate <= 0 or p_rate >= 10::numeric ^ 10
       or app_private.round_amount(p_rate, 10, 'down') <> p_rate then
      raise exception 'INVALID: a foreign-currency bill needs a positive exchange rate with at most 10 decimals'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
end
$$;

create function app_private.bill_write_lines(p_entity uuid, p_bill uuid, p_prepared jsonb) returns void
language plpgsql as $$
begin
  delete from public.bill_lines where bill_id = p_bill and entity_id = p_entity;
  insert into public.bill_lines
    (entity_id, bill_id, line_no, description, quantity, unit_price, line_subtotal, line_total, treatment,
     category_id, account_id)
  select p_entity, p_bill, (l ->> 'line_no')::smallint, l ->> 'description', (l ->> 'quantity')::numeric,
         (l ->> 'unit_price')::numeric, (l ->> 'line_total')::numeric, (l ->> 'line_total')::numeric, l ->> 'treatment',
         nullif(l ->> 'category_id', '')::uuid, nullif(l ->> 'account_id', '')::uuid
  from jsonb_array_elements(p_prepared -> 'lines') l;
end
$$;

-- ------------------------------------------------------------ draft commands
create function public.create_bill_draft(
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
     subtotal, total)
  values
    (p_entity, p_vendor, v_ref, v_currency, p_rate, p_bill_date, p_due_date,
     nullif(btrim(coalesce(p_notes, '')), ''), nullif(btrim(coalesce(p_internal_note, '')), ''),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'total')::numeric)
  returning id into v_id;
  perform app_private.bill_write_lines(p_entity, v_id, v_prep);

  perform app_private.idem_complete('bill.create', p_entity, p_key, 'bills', v_id);
  return v_id;
end
$$;

-- Edits a draft. The patch names the fields to change; `lines`, when present, replaces all lines. A stale
-- version is refused (Step 08 §18).
create function public.update_bill_draft(p_bill uuid, p_patch jsonb, p_expected_version integer default null)
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
        'category_id', l.category_id, 'account_id', l.account_id) order by l.line_no), '[]'::jsonb)
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
      subtotal = (v_prep ->> 'subtotal')::numeric, total = (v_prep ->> 'total')::numeric
  where id = b.id
  returning version into v_new_version;
  perform app_private.bill_write_lines(b.entity_id, b.id, v_prep);
  return v_new_version;
end
$$;

-- ------------------------------------------------------------ submit, recall and reject (Step 07 §5)
create function public.submit_bill(p_bill uuid, p_key text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  if not found or not app_authz.has_permission(b.entity_id, 'bills.submit') then
    raise exception 'FORBIDDEN: missing bills.submit' using errcode = 'insufficient_privilege';
  end if;
  select * into b from public.bills where id = p_bill for update;
  v_replay := app_private.idem_begin('bill.submit', b.entity_id, p_key, md5(p_bill::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if b.status <> 'draft' then
    raise exception 'CONFLICT: only a draft bill can be submitted (now %)', b.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.bill_check_header(b.entity_id, b.vendor_id, b.bill_date, b.due_date, b.currency, b.exchange_rate,
                                        b.vendor_reference);
  if not exists (select 1 from public.bill_lines where bill_id = b.id) or b.total <= 0 then
    raise exception 'INVALID: a bill needs at least one line with an amount' using errcode = 'invalid_parameter_value';
  end if;
  update public.bills set status = 'submitted', submitted_at = now(), submitted_by = auth.uid() where id = b.id;
  perform app_private.idem_complete('bill.submit', b.entity_id, p_key, 'bills', b.id);
  return b.id;
end
$$;

-- The preparer takes a submitted bill back to draft to edit it again.
create function public.recall_bill(p_bill uuid) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  if not found or not app_authz.has_permission(b.entity_id, 'bills.edit') then
    raise exception 'FORBIDDEN: missing bills.edit' using errcode = 'insufficient_privilege';
  end if;
  select * into b from public.bills where id = p_bill for update;
  if b.status <> 'submitted' then
    raise exception 'CONFLICT: only a submitted bill can be recalled (now %)', b.status
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.bills set status = 'draft', submitted_at = null, submitted_by = null where id = b.id;
  return 'draft';
end
$$;

create function public.reject_bill(p_bill uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  if not found or not app_authz.has_permission(b.entity_id, 'bills.approve') then
    raise exception 'FORBIDDEN: missing bills.approve' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 3 and 1000 then
    raise exception 'INVALID: a rejection needs a reason' using errcode = 'invalid_parameter_value';
  end if;
  select * into b from public.bills where id = p_bill for update;
  if b.status <> 'submitted' then
    raise exception 'CONFLICT: only a submitted bill can be rejected (now %)', b.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.bills
  set status = 'draft', submitted_at = null, submitted_by = null, rejected_at = now(), rejected_by = auth.uid(),
      reject_reason = left(v_reason, 1000)
  where id = b.id;
  return 'draft';
end
$$;

-- ------------------------------------------------------------ approve = recognise (Step 04 §4, Step 07 §5)
-- Assumes the caller holds the bill row lock and has checked permission, idempotency and maker-checker.
create function app_private.approve_bill_core(p_bill uuid, p_duplicate_reason text) returns uuid
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
  if exists (select 1 from public.bill_lines where bill_id = b.id and tax_amount <> 0) or b.tax_total <> 0 then
    raise exception 'CONFLICT: tax lines are produced by the tax engine, which is not active yet; nothing is guessed'
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
  select array_agg(line_total order by line_no) into v_weights from public.bill_lines where bill_id = b.id;
  v_alloc := app_private.allocate_amount(v_base_total, v_weights, v_scale);

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
  v_lines := app_private.add_line(v_lines, v_ap, 0, v_base_total, v_desc,
    app_private.orig_fields(b.currency, v_base, b.total, b.exchange_rate, v_base_total));

  v_journal := app_private.post_system_journal(
    b.entity_id, 'bill', b.id, 'bill.approve', 'bill.v1', b.bill_date, v_desc, v_lines);

  update public.bills
  set status = 'approved', bill_number = v_number, journal_id = v_journal, approved_at = now(), approved_by = auth.uid(),
      base_total = v_base_total, duplicate_ack_reason = left(v_ack, 1000),
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

create function public.approve_bill(p_bill uuid, p_key text, p_duplicate_reason text default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  -- The same answer for "does not exist" and "not allowed": no existence leak across Entities.
  if not found or not app_authz.has_permission(b.entity_id, 'bills.approve') then
    raise exception 'FORBIDDEN: missing bills.approve' using errcode = 'insufficient_privilege';
  end if;
  select * into b from public.bills where id = p_bill for update;

  v_replay := app_private.idem_begin('bill.approve', b.entity_id, p_key,
    md5(jsonb_build_object('b', p_bill, 'dup', p_duplicate_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if b.status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: only a draft or submitted bill can be approved (now %)', b.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_maker_checker(b.entity_id, 'bills', 'approve',
    app_private.approval_base_amount(b.entity_id, b.total, b.exchange_rate),
    case when auth.uid() in (b.created_by, b.submitted_by, b.updated_by) then auth.uid() else b.created_by end,
    'approve this bill');
  perform app_private.approve_bill_core(p_bill, p_duplicate_reason);
  perform app_private.idem_complete('bill.approve', b.entity_id, p_key, 'bills', p_bill);
  return p_bill;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.bills');
create policy bills_select on public.bills for select to authenticated
  using (app_authz.has_permission(entity_id, 'bills.view'));
call app_private.expose_select('public.bill_lines');
create policy bill_lines_select on public.bill_lines for select to authenticated
  using (app_authz.has_permission(entity_id, 'bills.view'));

revoke all on function app_private.ensure_purchase_numbering(uuid) from public;
revoke all on function app_private.is_fixed_asset_account(uuid, uuid) from public;
revoke all on function app_private.purchase_account_ok(uuid, uuid, text, boolean) from public;
revoke all on function app_private.default_purchase_account(uuid, text) from public;
revoke all on function app_private.resolve_purchase_account(uuid, uuid, text, uuid, date) from public;
revoke all on function app_private.purchase_prepare_lines(uuid, public.currency_code, jsonb, boolean) from public;
revoke all on function app_private.tg_bills_guard() from public;
revoke all on function app_private.tg_bill_lines_guard() from public;
revoke all on function app_private.bill_check_header(uuid, uuid, date, date, public.currency_code, numeric, text) from public;
revoke all on function app_private.bill_write_lines(uuid, uuid, jsonb) from public;
revoke all on function app_private.approve_bill_core(uuid, text) from public;

revoke all on function public.create_bill_draft(uuid, text, uuid, date, date, jsonb, text, text, numeric, text, text) from public, anon;
revoke all on function public.update_bill_draft(uuid, jsonb, integer) from public, anon;
revoke all on function public.submit_bill(uuid, text) from public, anon;
revoke all on function public.recall_bill(uuid) from public, anon;
revoke all on function public.reject_bill(uuid, text) from public, anon;
revoke all on function public.approve_bill(uuid, text, text) from public, anon;
grant execute on function public.create_bill_draft(uuid, text, uuid, date, date, jsonb, text, text, numeric, text, text) to authenticated;
grant execute on function public.update_bill_draft(uuid, jsonb, integer) to authenticated;
grant execute on function public.submit_bill(uuid, text) to authenticated;
grant execute on function public.recall_bill(uuid) to authenticated;
grant execute on function public.reject_bill(uuid, text) to authenticated;
grant execute on function public.approve_bill(uuid, text, text) to authenticated;
