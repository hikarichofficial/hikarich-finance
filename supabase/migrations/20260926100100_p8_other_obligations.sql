-- P8 (Step 15 §12, Step 04 §8, Step 07 §12-§13) part 2: other receivables and other payables, and the small helpers
-- every P8 workflow shares.
--
-- An "other" receivable or payable is money owed to or by the Entity that is not a sale, a purchase, a tax or a loan
-- agreement: an advance to a person, a deposit to be returned, the unpaid price of an asset that was sold. It is
-- recognised once (cash moves, or a counter account is chosen), settled in parts (principal, interest, fee), and can be
-- written off with a reason. Nothing here rewrites history: a mistaken step is reversed, never edited.
--
-- Money is base-currency only in P8 (DECISIONS 102). Every amount in a result is exact decimal text.

-- ------------------------------------------------------------ shared helpers
-- A validated amount argument: a finite number with at most the currency's decimals.
create function app_private.money_arg(p_text text, p_label text, p_scale integer, p_allow_zero boolean default false)
returns numeric
language plpgsql immutable as $$
declare
  v numeric := app_private.parse_amount(p_text, p_label);
begin
  if v < 0 or (v = 0 and not p_allow_zero) then
    raise exception 'INVALID: % must be %', p_label, case when p_allow_zero then 'zero or more' else 'greater than zero' end
      using errcode = 'invalid_parameter_value';
  end if;
  if app_private.round_amount(v, p_scale, 'down') <> v then
    raise exception 'INVALID: % has more than % decimals', p_label, p_scale using errcode = 'invalid_parameter_value';
  end if;
  return v;
end
$$;

-- A financial account that can carry a P8 cash movement: known, active and in the Entity's base currency.
create function app_private.base_cash_account(p_entity uuid, p_account uuid) returns public.financial_accounts
language plpgsql stable as $$
declare
  fa public.financial_accounts%rowtype;
begin
  select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
  if not found or not fa.is_active then
    raise exception 'INVALID: the financial account is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;
  if fa.currency <> app_private.entity_base_currency(p_entity) then
    raise exception 'INVALID: this workflow uses an account in the Entity''s base currency (%)',
      app_private.entity_base_currency(p_entity) using errcode = 'invalid_parameter_value';
  end if;
  return fa;
end
$$;

-- The account a P&L or balance-sheet role lands on, by stable key (PT and Personal COAs differ in their keys).
create function app_private.role_account(p_entity uuid, p_role text) returns uuid
language plpgsql stable as $$
declare
  v_keys text[];
  v_id uuid;
begin
  v_keys := case p_role
    when 'interest_income' then array['INTEREST_INCOME', 'INVESTMENT_INCOME']
    when 'interest_expense' then array['INTEREST_EXPENSE', 'PERSONAL_INTEREST_EXPENSE']
    when 'other_income' then array['OTHER_NONOPERATING_INCOME', 'OTHER_PERSONAL_INCOME']
    when 'other_expense' then array['OTHER_NONOPERATING_EXPENSE', 'OTHER_PERSONAL_EXPENSE']
    when 'bad_debt' then array['BAD_DEBT_EXPENSE', 'OTHER_PERSONAL_EXPENSE']
    when 'other_receivable' then array['OTHER_RECEIVABLE']
    when 'other_payable' then array['OTHER_PAYABLE']
    when 'loan_short_term' then array['LOAN_SHORT_TERM', 'PERSONAL_LOAN']
    when 'loan_long_term' then array['LOAN_LONG_TERM', 'PERSONAL_LOAN']
    when 'disposal_result' then array['ASSET_DISPOSAL_GAIN_LOSS']
    when 'accumulated_depreciation' then array['ACCUMULATED_DEPRECIATION']
    when 'depreciation_expense' then array['DEPRECIATION_EXPENSE']
    when 'dividend_payable' then array['DIVIDEND_PAYABLE']
    when 'equity_capital' then array['OWNER_CAPITAL']
    when 'equity_additional' then array['ADDITIONAL_EQUITY']
    when 'personal_investment' then array['PERSONAL_INVESTMENT']
    when 'distribution_income' then array['BUSINESS_DISTRIBUTION_INCOME']
    when 'retained_earnings' then array['RETAINED_EARNINGS', 'PERSONAL_ACCUMULATED_SURPLUS']
    else array[]::text[] end;
  select a.id into v_id from public.ledger_accounts a
  where a.entity_id = p_entity and a.status = 'active' and not a.is_group and a.system_key = any (v_keys)
  order by array_position(v_keys, a.system_key)
  limit 1;
  if v_id is null then
    raise exception 'CONFLICT: this Entity has no account for "%"; check its chart of accounts', p_role
      using errcode = 'integrity_constraint_violation';
  end if;
  return v_id;
end
$$;

-- Cross-Entity analytics tag (PT <-> Personal): analytics only, never a posting (DECISIONS 105).
create function app_private.check_related_entity(p_entity uuid, p_related uuid, p_basis text) returns void
language plpgsql stable as $$
begin
  if p_related is null then
    if nullif(btrim(coalesce(p_basis, '')), '') is not null then
      raise exception 'INVALID: a relationship basis needs the related Entity' using errcode = 'invalid_parameter_value';
    end if;
    return;
  end if;
  if p_related = p_entity or not exists (select 1 from public.entities where id = p_related)
     or not app_authz.is_member(p_related) then
    raise exception 'INVALID: the related Entity is unknown or not one you can access' using errcode = 'invalid_parameter_value';
  end if;
  if length(btrim(coalesce(p_basis, ''))) < 3 or length(p_basis) > 300 then
    raise exception 'INVALID: state the basis of the relationship (3 to 300 characters)' using errcode = 'invalid_parameter_value';
  end if;
end
$$;

create function app_private.ensure_obligation_numbering(p_entity uuid) returns void
language plpgsql as $$
begin
  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (p_entity, 'other_receivable', 'ORC'),
         (p_entity, 'other_payable', 'OPY'),
         (p_entity, 'obligation_settlement', 'OSET')
  on conflict (entity_id, scope) do nothing;
end
$$;

-- ------------------------------------------------------------ other receivables / payables
create table public.other_obligations (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  kind text not null check (kind in ('receivable', 'payable')),
  obligation_number text not null,
  status text not null default 'open' check (status in ('open', 'settled', 'void')),
  counterparty_name text not null check (length(btrim(counterparty_name)) between 1 and 200),
  contact_id uuid,
  purpose text not null check (length(btrim(purpose)) between 3 and 500),
  obligation_date date not null,
  due_date date,
  principal public.money_amount not null check (principal > 0),
  -- How it was recognised: cash moved through a financial account, a counter account was chosen, or the Asset
  -- Register created it from the sale of an asset.
  recognition text not null check (recognition in ('cash', 'offset', 'asset_disposal')),
  financial_account_id uuid,
  counter_account_id uuid,
  source_type text not null default 'manual' check (source_type in ('manual', 'asset_disposal')),
  source_id uuid,
  journal_id uuid not null,
  reversal_journal_id uuid,
  voided_at timestamptz,
  voided_by uuid,
  voided_date date,
  void_reason text check (void_reason is null or length(void_reason) <= 1000),
  -- PT <-> Personal analytics tag (never a posting).
  related_entity_id uuid references public.entities (id) on delete restrict,
  relationship_basis text check (relationship_basis is null or length(relationship_basis) <= 300),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, contact_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, counter_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint other_obligation_due check (due_date is null or due_date >= obligation_date),
  constraint other_obligation_recognition_shape check (
    case recognition
      when 'cash' then financial_account_id is not null and counter_account_id is null
      when 'offset' then counter_account_id is not null and financial_account_id is null
      else financial_account_id is null and counter_account_id is null end),
  constraint other_obligation_source_shape check (
    (source_type = 'manual') = (source_id is null) and (source_type = 'asset_disposal') = (recognition = 'asset_disposal')),
  constraint other_obligation_related check (
    related_entity_id is null or (related_entity_id <> entity_id and relationship_basis is not null)),
  constraint other_obligation_void_shape check (
    (status = 'void') = (voided_at is not null and reversal_journal_id is not null and voided_date is not null
                         and void_reason is not null))
);
create unique index other_obligations_number_uq on public.other_obligations (entity_id, obligation_number);
create index other_obligations_open_idx on public.other_obligations (entity_id, kind, status, due_date);

create function app_private.tg_other_obligations_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversal_journal_id', 'voided_at', 'voided_by', 'voided_date',
                                   'void_reason', 'updated_at', 'updated_by', 'version'];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'open' then
      raise exception 'An obligation starts open' using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;
  if old.status = 'void' then
    raise exception 'A void obligation cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of an obligation cannot be changed; reverse it instead' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status and (old.status, new.status) not in (('open', 'settled'), ('settled', 'open'), ('open', 'void')) then
    raise exception 'An obligation cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.other_obligations
  for each row execute function app_private.tg_other_obligations_guard();
create trigger tg_forbid_delete before delete on public.other_obligations
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.other_obligations
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.other_obligations');
call app_private.secure_table('public.other_obligations');
create trigger tg_audit after insert or update or delete on public.other_obligations
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ settlements (cash) and write-offs
create table public.other_obligation_settlements (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  obligation_id uuid not null,
  settlement_number text not null,
  kind text not null check (kind in ('cash', 'write_off')),
  status text not null default 'active' check (status in ('active', 'reversed')),
  settlement_date date not null,
  principal public.money_amount not null check (principal > 0),
  interest public.money_amount not null default 0 check (interest >= 0),
  fee public.money_amount not null default 0 check (fee >= 0),
  financial_account_id uuid,
  note text check (note is null or length(note) <= 1000),
  -- Interest and forgiven debt have tax consequences the P7 rule families do not cover: they are flagged for review
  -- (Step 05 §14 "needs review") and never guessed (DECISIONS 106).
  tax_status text not null default 'not_applicable' check (tax_status in ('not_applicable', 'needs_review', 'reviewed')),
  tax_reviewed_at timestamptz,
  tax_reviewed_by uuid,
  tax_note text check (tax_note is null or length(tax_note) <= 1000),
  journal_id uuid not null,
  reversal_journal_id uuid,
  reversed_at timestamptz,
  reversed_date date,
  reversed_by uuid,
  reverse_reason text check (reverse_reason is null or length(reverse_reason) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, obligation_id) references public.other_obligations (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint obligation_settlement_shape check (
    case kind when 'cash' then financial_account_id is not null
              else financial_account_id is null and interest = 0 and fee = 0 and length(coalesce(note, '')) >= 5 end),
  constraint obligation_settlement_state check (
    (status = 'active' and reversal_journal_id is null and reversed_at is null)
    or (status = 'reversed' and reversal_journal_id is not null and reversed_at is not null and reversed_date is not null
        and reverse_reason is not null)),
  constraint obligation_settlement_tax_shape check (
    (tax_status = 'reviewed') = (tax_reviewed_at is not null and tax_reviewed_by is not null))
);
create unique index obligation_settlements_number_uq on public.other_obligation_settlements (entity_id, settlement_number);
create index obligation_settlements_obl_idx on public.other_obligation_settlements (entity_id, obligation_id, settlement_date);

create function app_private.tg_obligation_settlements_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by',
                                   'reverse_reason', 'tax_status', 'tax_reviewed_at', 'tax_reviewed_by', 'tax_note',
                                   'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' and (to_jsonb(new) - array['tax_status', 'tax_reviewed_at', 'tax_reviewed_by', 'tax_note',
                                                          'updated_at', 'updated_by', 'version'])
                               is distinct from (to_jsonb(old) - array['tax_status', 'tax_reviewed_at', 'tax_reviewed_by',
                                                                        'tax_note', 'updated_at', 'updated_by', 'version']) then
    raise exception 'A reversed settlement cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a settlement cannot be changed; reverse it instead' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status and (old.status, new.status) <> ('active', 'reversed') then
    raise exception 'A settlement cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.other_obligation_settlements
  for each row execute function app_private.tg_obligation_settlements_guard();
create trigger tg_forbid_delete before delete on public.other_obligation_settlements
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.other_obligation_settlements
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.other_obligation_settlements');
call app_private.secure_table('public.other_obligation_settlements');
create trigger tg_audit after insert or update or delete on public.other_obligation_settlements
  for each row execute function app_private.tg_audit('entity_id');

-- Defence in depth for the capacity rule: whatever writes a settlement, the principal settled never exceeds the
-- principal recognised, and a settlement is never dated before its obligation.
create function app_private.tg_obligation_settlements_capacity() returns trigger
language plpgsql as $$
declare
  o public.other_obligations%rowtype;
begin
  select * into o from public.other_obligations where id = new.obligation_id and entity_id = new.entity_id for update;
  if not found or o.status = 'void' then
    raise exception 'CONFLICT: a void or unknown obligation cannot be settled' using errcode = 'integrity_constraint_violation';
  end if;
  if new.settlement_date < o.obligation_date then
    raise exception 'INVALID: a settlement cannot be dated before the obligation (%)', o.obligation_date
      using errcode = 'invalid_parameter_value';
  end if;
  if (select coalesce(sum(s.principal), 0) from public.other_obligation_settlements s
      where s.obligation_id = o.id and s.status = 'active') > o.principal then
    raise exception 'INVALID: the settlements would exceed the principal of this obligation' using errcode = 'invalid_parameter_value';
  end if;
  return new;
end
$$;
create constraint trigger tg_capacity after insert on public.other_obligation_settlements
  deferrable initially immediate for each row execute function app_private.tg_obligation_settlements_capacity();

-- ------------------------------------------------------------ what is outstanding
-- As of a date: settled principal counts from its date until (and unless) it was reversed.
create function app_private.obligation_outstanding(p_obligation uuid, p_as_of date default null)
returns numeric
language sql stable as $$
  select o.principal - coalesce((
    select sum(s.principal) from public.other_obligation_settlements s
    where s.obligation_id = o.id and (p_as_of is null or s.settlement_date <= p_as_of)
      and (s.status = 'active' or (p_as_of is not null and s.reversed_date > p_as_of))), 0)
  from public.other_obligations o
  where o.id = p_obligation
$$;

-- The sub-ledger total of one side as of a date (obligations recognised and not yet voided as of then).
create function app_private.obligations_total(p_entity uuid, p_kind text, p_as_of date) returns numeric
language sql stable as $$
  select coalesce(sum(app_private.obligation_outstanding(o.id, p_as_of)), 0)
  from public.other_obligations o
  where o.entity_id = p_entity and o.kind = p_kind and o.obligation_date <= p_as_of
    and (o.status <> 'void' or o.voided_date > p_as_of)
$$;

-- ------------------------------------------------------------ recognition
-- Inserts the obligation row for a journal that was already posted (the disposal of an asset posts its own).
create function app_private.obligation_insert(
  p_entity uuid, p_id uuid, p_kind text, p_name text, p_contact uuid, p_date date, p_due date, p_principal numeric,
  p_recognition text, p_account uuid, p_counter uuid, p_purpose text, p_source_type text, p_source_id uuid,
  p_journal uuid, p_related uuid, p_basis text)
returns text   -- the number
language plpgsql as $$
declare
  v_number text;
begin
  perform app_private.ensure_obligation_numbering(p_entity);
  v_number := app_private.allocate_document_number(
    p_entity, case p_kind when 'receivable' then 'other_receivable' else 'other_payable' end, p_date);
  insert into public.other_obligations
    (id, entity_id, kind, obligation_number, counterparty_name, contact_id, purpose, obligation_date, due_date, principal,
     recognition, financial_account_id, counter_account_id, source_type, source_id, journal_id, related_entity_id,
     relationship_basis, created_by)
  values
    (p_id, p_entity, p_kind, v_number, btrim(p_name), p_contact, btrim(p_purpose), p_date, p_due, p_principal,
     p_recognition, p_account, p_counter, p_source_type, p_source_id, p_journal, p_related,
     nullif(btrim(coalesce(p_basis, '')), ''), auth.uid());
  return v_number;
end
$$;

create function public.obligation_create(
  p_entity uuid, p_key text, p_kind text, p_counterparty text, p_contact uuid, p_date date, p_due date, p_amount text,
  p_method text, p_account uuid, p_counter uuid, p_purpose text, p_related uuid default null, p_basis text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  fa public.financial_accounts%rowtype;
  ca public.ledger_accounts%rowtype;
  v_replay uuid;
  v_scale integer;
  v_amount numeric;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_ctl uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'loans.manage') then
    raise exception 'FORBIDDEN: recording an other receivable or payable needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('obligation.create', p_entity, p_key,
    md5(jsonb_build_object('k', p_kind, 'n', p_counterparty, 'c', p_contact, 'd', p_date, 'due', p_due, 'a', p_amount,
                           'm', p_method, 'acc', p_account, 'ctr', p_counter, 'p', p_purpose, 'r', p_related,
                           'b', p_basis)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(e.base_currency);
  if p_kind not in ('receivable', 'payable') or p_method not in ('cash', 'offset') then
    raise exception 'INVALID: the kind is receivable or payable and the method cash or offset' using errcode = 'invalid_parameter_value';
  end if;
  if length(btrim(coalesce(p_counterparty, ''))) not between 1 and 200 or length(btrim(coalesce(p_purpose, ''))) not between 3 and 500 then
    raise exception 'INVALID: name the counterparty (up to 200 characters) and the purpose (3 to 500)' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(p_entity) then
    raise exception 'INVALID: an obligation cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_due is not null and p_due < p_date then
    raise exception 'INVALID: the due date cannot be before the obligation date' using errcode = 'invalid_parameter_value';
  end if;
  if p_contact is not null and not exists (select 1 from public.contacts where id = p_contact and entity_id = p_entity) then
    raise exception 'INVALID: unknown contact' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.check_related_entity(p_entity, p_related, p_basis);
  v_amount := app_private.money_arg(p_amount, 'the amount', v_scale);
  perform app_private.assert_maker_checker(p_entity, 'obligations', 'recognize', v_amount, auth.uid(), 'record this obligation');

  v_ctl := app_private.role_account(p_entity, case p_kind when 'receivable' then 'other_receivable' else 'other_payable' end);
  if p_method = 'cash' then
    fa := app_private.base_cash_account(p_entity, p_account);
    if p_counter is not null then
      raise exception 'INVALID: a cash obligation takes no counter account' using errcode = 'invalid_parameter_value';
    end if;
  else
    -- A counter account is a free choice of account: it needs the same right as a manual journal.
    if not app_authz.has_permission(p_entity, 'accounting.journal_create') then
      raise exception 'FORBIDDEN: recognising an obligation against an account needs accounting.journal_create'
        using errcode = 'insufficient_privilege';
    end if;
    select * into ca from public.ledger_accounts where id = p_counter and entity_id = p_entity;
    if not found or ca.status <> 'active' or ca.is_group or ca.is_control or not ca.allows_manual_posting
       or app_private.is_cash_ledger_account(p_entity, ca.id) or p_account is not null then
      raise exception 'INVALID: the counter account must be an active, postable, non-control account and not a cash account'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;

  perform app_private.ensure_obligation_numbering(p_entity);
  -- The journal needs the number; the row is inserted right after with the same number (allocated once, here).
  v_number := app_private.allocate_document_number(
    p_entity, case p_kind when 'receivable' then 'other_receivable' else 'other_payable' end, p_date);
  v_desc := format('%s %s - %s', case p_kind when 'receivable' then 'Other receivable' else 'Other payable' end, v_number,
                   left(btrim(p_counterparty), 100));
  if p_kind = 'receivable' then
    v_lines := v_lines || jsonb_build_object('account_id', v_ctl, 'debit', v_amount, 'credit', 0, 'description', v_desc);
    v_lines := v_lines || jsonb_build_object('account_id', case p_method when 'cash' then fa.ledger_account_id else p_counter end,
                                             'debit', 0, 'credit', v_amount, 'description', v_desc);
  else
    v_lines := v_lines || jsonb_build_object('account_id', case p_method when 'cash' then fa.ledger_account_id else p_counter end,
                                             'debit', v_amount, 'credit', 0, 'description', v_desc);
    v_lines := v_lines || jsonb_build_object('account_id', v_ctl, 'debit', 0, 'credit', v_amount, 'description', v_desc);
  end if;
  v_journal := app_private.post_system_journal(p_entity, 'other_obligation', v_id, 'obligation.recognize',
    'obligation.v1', p_date, v_desc, v_lines);
  if p_method = 'cash' then
    perform app_private.record_movement(p_entity, p_account, case p_kind when 'receivable' then 'out' else 'in' end,
      v_amount, v_amount, null, p_date, 'other_obligation', v_id, 'principal', v_journal, v_desc);
  end if;
  insert into public.other_obligations
    (id, entity_id, kind, obligation_number, counterparty_name, contact_id, purpose, obligation_date, due_date, principal,
     recognition, financial_account_id, counter_account_id, source_type, source_id, journal_id, related_entity_id,
     relationship_basis, created_by)
  values
    (v_id, p_entity, p_kind, v_number, btrim(p_counterparty), p_contact, btrim(p_purpose), p_date, p_due, v_amount,
     p_method, case p_method when 'cash' then p_account end, case p_method when 'offset' then p_counter end,
     'manual', null, v_journal, p_related, nullif(btrim(coalesce(p_basis, '')), ''), auth.uid());
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_entity, 'ObligationRecognised', 'other_obligation', v_id,
          jsonb_build_object('number', v_number, 'kind', p_kind));
  perform app_private.idem_complete('obligation.create', p_entity, p_key, 'other_obligations', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ settlement
create function public.obligation_settle(
  p_obligation uuid, p_key text, p_date date, p_account uuid, p_principal text, p_interest text default '0',
  p_fee text default '0', p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  o public.other_obligations%rowtype;
  fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_scale integer;
  v_principal numeric;
  v_interest numeric;
  v_fee numeric;
  v_outstanding numeric;
  v_last date;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_total numeric;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into o from public.other_obligations where id = p_obligation;
  if not found or not app_authz.has_permission(o.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: settling an obligation needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('obligation.settle', o.entity_id, p_key,
    md5(jsonb_build_object('o', p_obligation, 'd', p_date, 'a', p_account, 'p', p_principal, 'i', p_interest,
                           'f', p_fee, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('obligation:' || o.id::text, 0));
  select * into o from public.other_obligations where id = p_obligation for update;
  if o.status <> 'open' then
    raise exception 'CONFLICT: only an open obligation can be settled (now %)', o.status using errcode = 'integrity_constraint_violation';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(o.entity_id));
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(o.entity_id) then
    raise exception 'INVALID: a settlement cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_date < o.obligation_date then
    raise exception 'INVALID: a settlement cannot be dated before the obligation (%)', o.obligation_date
      using errcode = 'invalid_parameter_value';
  end if;
  -- Dated on or after every earlier settlement and reversal, so the outstanding amount is right on every day.
  select greatest(coalesce(max(s.settlement_date), o.obligation_date), coalesce(max(s.reversed_date), o.obligation_date))
    into v_last from public.other_obligation_settlements s where s.obligation_id = o.id;
  if p_date < v_last then
    raise exception 'INVALID: the date cannot be before the last settlement activity on this obligation (%)', v_last
      using errcode = 'invalid_parameter_value';
  end if;
  v_principal := app_private.money_arg(p_principal, 'the principal settled', v_scale);
  v_interest := app_private.money_arg(coalesce(nullif(btrim(p_interest), ''), '0'), 'the interest', v_scale, true);
  v_fee := app_private.money_arg(coalesce(nullif(btrim(p_fee), ''), '0'), 'the fee', v_scale, true);
  v_outstanding := app_private.obligation_outstanding(o.id);
  if v_principal > v_outstanding then
    raise exception 'INVALID: % is outstanding; the principal settled cannot exceed it', trim_scale(v_outstanding)
      using errcode = 'invalid_parameter_value';
  end if;
  if (v_interest > 0 or v_fee > 0) and length(coalesce(v_note, '')) < 5 then
    raise exception 'INVALID: interest or a fee needs a note that explains it' using errcode = 'invalid_parameter_value';
  end if;
  v_total := v_principal + v_interest + v_fee;
  perform app_private.assert_maker_checker(o.entity_id, 'obligations', 'settle', v_total, auth.uid(), 'record this settlement');
  fa := app_private.base_cash_account(o.entity_id, p_account);

  perform app_private.ensure_obligation_numbering(o.entity_id);
  v_number := app_private.allocate_document_number(o.entity_id, 'obligation_settlement', p_date);
  v_desc := format('Settlement %s - %s %s', v_number, o.obligation_number, left(o.counterparty_name, 80));
  if o.kind = 'receivable' then
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', v_total, 'credit', 0, 'description', v_desc);
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_receivable'),
                                             'debit', 0, 'credit', v_principal, 'description', v_desc);
    if v_interest > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'interest_income'),
                                               'debit', 0, 'credit', v_interest, 'description', 'Interest: ' || v_desc);
    end if;
    if v_fee > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_income'),
                                               'debit', 0, 'credit', v_fee, 'description', 'Fee: ' || v_desc);
    end if;
  else
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_payable'),
                                             'debit', v_principal, 'credit', 0, 'description', v_desc);
    if v_interest > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'interest_expense'),
                                               'debit', v_interest, 'credit', 0, 'description', 'Interest: ' || v_desc);
    end if;
    if v_fee > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_expense'),
                                               'debit', v_fee, 'credit', 0, 'description', 'Fee: ' || v_desc);
    end if;
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', v_total, 'description', v_desc);
  end if;
  perform 1 from public.financial_accounts where id = p_account and entity_id = o.entity_id for no key update;
  v_journal := app_private.post_system_journal(o.entity_id, 'obligation_settlement', v_id, 'obligation.settle',
    'obligation.v1', p_date, v_desc, v_lines);
  perform app_private.record_movement(o.entity_id, p_account, case o.kind when 'receivable' then 'in' else 'out' end,
    v_total, v_total, null, p_date, 'obligation_settlement', v_id, 'principal', v_journal, v_desc);
  insert into public.other_obligation_settlements
    (id, entity_id, obligation_id, settlement_number, kind, settlement_date, principal, interest, fee, financial_account_id,
     note, tax_status, journal_id, created_by)
  values
    (v_id, o.entity_id, o.id, v_number, 'cash', p_date, v_principal, v_interest, v_fee, p_account, v_note,
     case when v_interest > 0 then 'needs_review' else 'not_applicable' end, v_journal, auth.uid());
  if v_principal = v_outstanding then
    update public.other_obligations set status = 'settled' where id = o.id;
  end if;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (o.entity_id, 'ObligationSettled', 'other_obligation', o.id,
          jsonb_build_object('number', o.obligation_number, 'settlement', v_number));
  perform app_private.idem_complete('obligation.settle', o.entity_id, p_key, 'other_obligation_settlements', v_id);
  return v_id;
end
$$;

-- A write-off (bad debt on a receivable, forgiven payable) is a formal resolution without cash: OWNER-level care, a
-- recent step-up and a written reason (Step 07 §12 "settled or formally resolved").
create function public.obligation_write_off(p_obligation uuid, p_key text, p_date date, p_amount text, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  o public.other_obligations%rowtype;
  v_replay uuid;
  v_scale integer;
  v_amount numeric;
  v_outstanding numeric;
  v_last date;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into o from public.other_obligations where id = p_obligation;
  if not found or not app_authz.has_permission(o.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: writing off an obligation needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('obligation.write_off', o.entity_id, p_key,
    md5(jsonb_build_object('o', p_obligation, 'd', p_date, 'a', p_amount, 'r', p_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 5 or length(v_reason) > 1000 then
    raise exception 'INVALID: a write-off needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('obligation:' || o.id::text, 0));
  select * into o from public.other_obligations where id = p_obligation for update;
  if o.status <> 'open' then
    raise exception 'CONFLICT: only an open obligation can be written off (now %)', o.status using errcode = 'integrity_constraint_violation';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(o.entity_id));
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(o.entity_id) or p_date < o.obligation_date then
    raise exception 'INVALID: the write-off date is not in the future and not before the obligation (%)', o.obligation_date
      using errcode = 'invalid_parameter_value';
  end if;
  select greatest(coalesce(max(s.settlement_date), o.obligation_date), coalesce(max(s.reversed_date), o.obligation_date))
    into v_last from public.other_obligation_settlements s where s.obligation_id = o.id;
  if p_date < v_last then
    raise exception 'INVALID: the date cannot be before the last settlement activity on this obligation (%)', v_last
      using errcode = 'invalid_parameter_value';
  end if;
  v_amount := app_private.money_arg(p_amount, 'the amount written off', v_scale);
  v_outstanding := app_private.obligation_outstanding(o.id);
  if v_amount > v_outstanding then
    raise exception 'INVALID: % is outstanding; the write-off cannot exceed it', trim_scale(v_outstanding)
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_maker_checker(o.entity_id, 'obligations', 'write_off', v_amount, auth.uid(), 'write this off');

  perform app_private.ensure_obligation_numbering(o.entity_id);
  v_number := app_private.allocate_document_number(o.entity_id, 'obligation_settlement', p_date);
  v_desc := format('Write-off %s - %s %s', v_number, o.obligation_number, left(o.counterparty_name, 80));
  if o.kind = 'receivable' then
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'bad_debt'),
                                             'debit', v_amount, 'credit', 0, 'description', v_desc);
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_receivable'),
                                             'debit', 0, 'credit', v_amount, 'description', v_desc);
  else
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_payable'),
                                             'debit', v_amount, 'credit', 0, 'description', v_desc);
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_income'),
                                             'debit', 0, 'credit', v_amount, 'description', v_desc);
  end if;
  v_journal := app_private.post_system_journal(o.entity_id, 'obligation_settlement', v_id, 'obligation.write_off',
    'obligation.v1', p_date, v_desc, v_lines);
  perform set_config('app.audit_reason', v_reason, true);
  insert into public.other_obligation_settlements
    (id, entity_id, obligation_id, settlement_number, kind, settlement_date, principal, note, tax_status, journal_id, created_by)
  values
    (v_id, o.entity_id, o.id, v_number, 'write_off', p_date, v_amount, v_reason, 'needs_review', v_journal, auth.uid());
  if v_amount = v_outstanding then
    update public.other_obligations set status = 'settled' where id = o.id;
  end if;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (o.entity_id, 'ObligationWrittenOff', 'other_obligation', o.id,
          jsonb_build_object('number', o.obligation_number, 'settlement', v_number));
  perform app_private.idem_complete('obligation.write_off', o.entity_id, p_key, 'other_obligation_settlements', v_id);
  return v_id;
end
$$;

-- Reverses one settlement or write-off: the ledger and the money layer are mirrored, the row stays as history.
create function app_private.obligation_reverse_settlement_core(p_settlement uuid, p_date date, p_reason text) returns uuid
language plpgsql as $$
declare
  s public.other_obligation_settlements%rowtype;
  o public.other_obligations%rowtype;
  m public.money_movements%rowtype;
  v_rev uuid;
begin
  select * into s from public.other_obligation_settlements where id = p_settlement for update;
  select * into o from public.other_obligations where id = s.obligation_id for update;
  if s.status <> 'active' then
    raise exception 'CONFLICT: only an active settlement can be reversed (now %)', s.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < s.settlement_date then
    raise exception 'INVALID: a reversal cannot be dated before the settlement' using errcode = 'invalid_parameter_value';
  end if;
  if s.financial_account_id is not null then
    perform 1 from public.financial_accounts where id = s.financial_account_id and entity_id = s.entity_id for no key update;
  end if;
  perform set_config('app.audit_reason', p_reason, true);
  v_rev := app_private.reverse_journal_core(s.journal_id, p_date, p_reason);
  for m in
    select * from public.money_movements
    where entity_id = s.entity_id and source_type = 'obligation_settlement' and source_id = s.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(s.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'obligation_settlement', s.id, m.component, v_rev,
      'Reversal: ' || p_reason, m.id);
  end loop;
  update public.other_obligation_settlements
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date,
      reversed_by = auth.uid(), reverse_reason = p_reason
  where id = s.id;
  if o.status = 'settled' then
    update public.other_obligations set status = 'open' where id = o.id;
  end if;
  return v_rev;
end
$$;

create function public.obligation_reverse_settlement(p_settlement uuid, p_key text, p_date date, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.other_obligation_settlements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into s from public.other_obligation_settlements where id = p_settlement;
  if not found or not app_authz.has_permission(s.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: reversing a settlement needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 or length(v_reason) > 1000 or p_date > app_private.entity_today(s.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of 5 to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform pg_advisory_xact_lock(hashtextextended('obligation:' || s.obligation_id::text, 0));
  v_replay := app_private.idem_begin('obligation.reverse_settlement', s.entity_id, p_key,
    md5(jsonb_build_object('s', p_settlement, 'd', p_date, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if s.kind = 'write_off' and not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.obligation_reverse_settlement_core(p_settlement, p_date, v_reason);
  perform app_private.idem_complete('obligation.reverse_settlement', s.entity_id, p_key, 'journal_entries', v_replay);
  return v_replay;
end
$$;

-- Voids an obligation recognised by hand (before any settlement, or after each was reversed). An obligation that the
-- Asset Register created is voided by reversing the disposal that created it.
create function app_private.obligation_void_core(p_obligation uuid, p_date date, p_reason text) returns uuid
language plpgsql as $$
declare
  o public.other_obligations%rowtype;
  m public.money_movements%rowtype;
  v_rev uuid;
  v_min date;
begin
  select * into o from public.other_obligations where id = p_obligation for update;
  if o.status <> 'open' or exists (select 1 from public.other_obligation_settlements s
                                   where s.obligation_id = o.id and s.status = 'active') then
    raise exception 'CONFLICT: an obligation with settlements cannot be voided; reverse them first'
      using errcode = 'integrity_constraint_violation';
  end if;
  select greatest(o.obligation_date, coalesce(max(s.settlement_date), o.obligation_date),
                  coalesce(max(s.reversed_date), o.obligation_date))
    into v_min from public.other_obligation_settlements s where s.obligation_id = o.id;
  if p_date < v_min then
    raise exception 'INVALID: the date cannot be before the last activity on this obligation (%)', v_min
      using errcode = 'invalid_parameter_value';
  end if;
  if o.financial_account_id is not null then
    perform 1 from public.financial_accounts where id = o.financial_account_id and entity_id = o.entity_id for no key update;
  end if;
  perform set_config('app.audit_reason', p_reason, true);
  v_rev := app_private.reverse_journal_core(o.journal_id, p_date, p_reason);
  for m in
    select * from public.money_movements
    where entity_id = o.entity_id and source_type = 'other_obligation' and source_id = o.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(o.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'other_obligation', o.id, m.component, v_rev,
      'Reversal: ' || p_reason, m.id);
  end loop;
  update public.other_obligations
  set status = 'void', reversal_journal_id = v_rev, voided_at = now(), voided_by = auth.uid(), voided_date = p_date,
      void_reason = p_reason
  where id = o.id;
  return v_rev;
end
$$;

create function public.obligation_void(p_obligation uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  o public.other_obligations%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into o from public.other_obligations where id = p_obligation;
  if not found or not app_authz.has_permission(o.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: voiding an obligation needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 or length(v_reason) > 1000 or p_date > app_private.entity_today(o.entity_id) then
    raise exception 'INVALID: a void needs a date (not in the future) and a reason of 5 to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform pg_advisory_xact_lock(hashtextextended('obligation:' || o.id::text, 0));
  v_replay := app_private.idem_begin('obligation.void', o.entity_id, p_key,
    md5(jsonb_build_object('o', p_obligation, 'd', p_date, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if o.source_type <> 'manual' then
    raise exception 'CONFLICT: this obligation was created by an asset sale; reverse the disposal instead'
      using errcode = 'integrity_constraint_violation';
  end if;
  v_replay := app_private.obligation_void_core(p_obligation, p_date, v_reason);
  perform app_private.idem_complete('obligation.void', o.entity_id, p_key, 'journal_entries', v_replay);
  return v_replay;
end
$$;

-- ------------------------------------------------------------ reading
create function public.obligation_list(
  p_entity uuid, p_kind text default null, p_status text default null, p_limit integer default 100)
returns table (obligation_id uuid, obligation_number text, kind text, status text, counterparty_name text, purpose text,
               obligation_date date, due_date date, principal text, outstanding text, overdue boolean, source_type text,
               related_entity_id uuid, journal_id uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'loans.view') then
    raise exception 'FORBIDDEN: missing loans.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select o.id, o.obligation_number, o.kind, o.status, o.counterparty_name, o.purpose, o.obligation_date, o.due_date,
         o.principal::text, app_private.obligation_outstanding(o.id)::text,
         (o.status = 'open' and o.due_date is not null and o.due_date < app_private.entity_today(p_entity)),
         o.source_type, o.related_entity_id, o.journal_id
  from public.other_obligations o
  where o.entity_id = p_entity and (p_kind is null or o.kind = p_kind) and (p_status is null or o.status = p_status)
  order by o.obligation_date desc, o.obligation_number desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end
$$;

create function public.obligation_detail(p_obligation uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  o public.other_obligations%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into o from public.other_obligations where id = p_obligation;
  if not found or not app_authz.has_permission(o.entity_id, 'loans.view') then
    raise exception 'FORBIDDEN: missing loans.view' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'id', o.id, 'number', o.obligation_number, 'kind', o.kind, 'status', o.status,
    'counterparty', o.counterparty_name, 'contact_id', o.contact_id, 'purpose', o.purpose,
    'date', o.obligation_date, 'due_date', o.due_date, 'principal', o.principal::text,
    'outstanding', app_private.obligation_outstanding(o.id)::text, 'recognition', o.recognition,
    'financial_account_id', o.financial_account_id, 'counter_account_id', o.counter_account_id,
    'source_type', o.source_type, 'source_id', o.source_id, 'journal_id', o.journal_id,
    'reversal_journal_id', o.reversal_journal_id, 'related_entity_id', o.related_entity_id,
    'relationship_basis', o.relationship_basis,
    'settlements', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'number', s.settlement_number, 'kind', s.kind, 'status', s.status, 'date', s.settlement_date,
        'principal', s.principal::text, 'interest', s.interest::text, 'fee', s.fee::text, 'tax_status', s.tax_status,
        'journal_id', s.journal_id, 'reversal_journal_id', s.reversal_journal_id, 'note', s.note)
        order by s.settlement_date, s.settlement_number)
      from public.other_obligation_settlements s where s.obligation_id = o.id), '[]'::jsonb));
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.other_obligations');
create policy other_obligations_select on public.other_obligations for select to authenticated
  using (app_authz.has_permission(entity_id, 'loans.view'));
call app_private.expose_select('public.other_obligation_settlements');
create policy other_obligation_settlements_select on public.other_obligation_settlements for select to authenticated
  using (app_authz.has_permission(entity_id, 'loans.view'));

revoke all on function app_private.money_arg(text, text, integer, boolean) from public;
revoke all on function app_private.base_cash_account(uuid, uuid) from public;
revoke all on function app_private.role_account(uuid, text) from public;
revoke all on function app_private.check_related_entity(uuid, uuid, text) from public;
revoke all on function app_private.ensure_obligation_numbering(uuid) from public;
revoke all on function app_private.tg_other_obligations_guard() from public;
revoke all on function app_private.tg_obligation_settlements_guard() from public;
revoke all on function app_private.tg_obligation_settlements_capacity() from public;
revoke all on function app_private.obligation_outstanding(uuid, date) from public;
revoke all on function app_private.obligations_total(uuid, text, date) from public;
revoke all on function app_private.obligation_insert(uuid, uuid, text, text, uuid, date, date, numeric, text, uuid, uuid, text, text, uuid, uuid, uuid, text) from public;
revoke all on function app_private.obligation_reverse_settlement_core(uuid, date, text) from public;
revoke all on function app_private.obligation_void_core(uuid, date, text) from public;

revoke all on function public.obligation_create(uuid, text, text, text, uuid, date, date, text, text, uuid, uuid, text, uuid, text) from public, anon;
revoke all on function public.obligation_settle(uuid, text, date, uuid, text, text, text, text) from public, anon;
revoke all on function public.obligation_write_off(uuid, text, date, text, text) from public, anon;
revoke all on function public.obligation_reverse_settlement(uuid, text, date, text) from public, anon;
revoke all on function public.obligation_void(uuid, text, date, text) from public, anon;
revoke all on function public.obligation_list(uuid, text, text, integer) from public, anon;
revoke all on function public.obligation_detail(uuid) from public, anon;
grant execute on function public.obligation_create(uuid, text, text, text, uuid, date, date, text, text, uuid, uuid, text, uuid, text) to authenticated;
grant execute on function public.obligation_settle(uuid, text, date, uuid, text, text, text, text) to authenticated;
grant execute on function public.obligation_write_off(uuid, text, date, text, text) to authenticated;
grant execute on function public.obligation_reverse_settlement(uuid, text, date, text) to authenticated;
grant execute on function public.obligation_void(uuid, text, date, text) to authenticated;
grant execute on function public.obligation_list(uuid, text, text, integer) to authenticated;
grant execute on function public.obligation_detail(uuid) to authenticated;
