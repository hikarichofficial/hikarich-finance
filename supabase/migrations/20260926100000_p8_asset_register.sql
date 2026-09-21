-- P8 (Step 15 §12, Step 16 §16) part 1: the Asset Register - vocabulary, tables and the depreciation arithmetic.
-- Authority: Step 01 #29 (asset-classified lines create Asset Register records; operational tracking is separate from
-- capitalisation and depreciation), Step 02 (Assets domain), Step 03 §5 (fixed-asset and accumulated-depreciation
-- control accounts), Step 04 §7 (depreciation and disposal posting), Step 05 (fiscal depreciation is separate from
-- accounting depreciation), Step 07 §11 (asset workflow), Step 08 §11 (asset integrity).
--
-- What this part delivers
--   * numbering scopes for every P8 document family (assets, loans, other receivables/payables, equity events);
--   * the Personal COA gets the three accounts the P8 workflows need (other receivable / payable, disposal result);
--   * the fiscal depreciation groups as RULE DATA in the P7 rule master (statutory values are data, not code);
--   * `fixed_assets`, its depreciation schedule, its operational event log and the disposal record;
--   * the pure arithmetic of a depreciation plan.
-- The lifecycle commands (activation, posting, disposal ...) follow in the next parts.

-- ------------------------------------------------------------ numbering families
alter table public.numbering_sequences drop constraint numbering_sequences_scope_check;
alter table public.numbering_sequences add constraint numbering_sequences_scope_check
  check (scope in ('invoice', 'payment_receipt', 'refund_receipt', 'bill', 'bill_payment', 'expense', 'journal',
                   'transfer', 'tax_payment', 'asset', 'loan', 'loan_payment', 'other_receivable', 'other_payable',
                   'obligation_settlement', 'equity', 'other'));

create function app_private.ensure_asset_numbering(p_entity uuid) returns void
language plpgsql as $$
begin
  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (p_entity, 'asset', 'AST')
  on conflict (entity_id, scope) do nothing;
end
$$;

-- ------------------------------------------------------------ Personal COA: accounts the P8 workflows need
-- A Personal Entity lends and borrows small amounts outside the loan agreements, and sells things it owns. These
-- accounts follow the PT template (same keys, same protection); they were absent from Step 03 §4 (DECISIONS 101).
insert into public.coa_template_accounts
  (template_key, code, name, account_class, normal_balance, system_key, parent_code, is_group, is_control, allows_manual_posting)
values
  ('personal_default', '1210', 'Other Personal Receivables', 'asset', 'debit', 'OTHER_RECEIVABLE', null, false, true, false),
  ('personal_default', '2110', 'Other Personal Payables', 'liability', 'credit', 'OTHER_PAYABLE', null, false, true, false),
  ('personal_default', '7400', 'Gain / Loss on Asset Disposal', 'other', 'debit', 'ASSET_DISPOSAL_GAIN_LOSS', null, false, false, true);

-- Existing Entities receive the new accounts (the provisioning is idempotent).
select app_private.provision_default_coa(e.id) from public.entities e where e.entity_type = 'personal';

-- ------------------------------------------------------------ fiscal depreciation groups: rule data
-- The statutory groups of Art. 11 UU PPh are values, not code: they live in the effective-dated rule master of P7
-- so a change of law is a new published version and every determination keeps the version it used.
alter table public.tax_rule_versions drop constraint tax_rule_versions_family_check;
alter table public.tax_rule_versions add constraint tax_rule_versions_family_check
  check (family in ('ppn', 'pph23', 'pph_final_umkm', 'pph4_2', 'pph26', 'pph21', 'corporate_income', 'personal_income',
                    'deadline', 'fiscal_depreciation', 'other'));

insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
values
  ('fiscal_depreciation', 'FISCAL_DEP_CLASSES', 1, date '2020-01-01',
   '{"first_year":"prorate_months_from_acquisition_month",
     "classes":[
       {"key":"group_1","name":"Group 1 (4 years)","life_years":4,"sl_rate":"0.25","db_rate":"0.5","building":false,"depreciable":true},
       {"key":"group_2","name":"Group 2 (8 years)","life_years":8,"sl_rate":"0.125","db_rate":"0.25","building":false,"depreciable":true},
       {"key":"group_3","name":"Group 3 (16 years)","life_years":16,"sl_rate":"0.0625","db_rate":"0.125","building":false,"depreciable":true},
       {"key":"group_4","name":"Group 4 (20 years)","life_years":20,"sl_rate":"0.05","db_rate":"0.1","building":false,"depreciable":true},
       {"key":"building_permanent","name":"Permanent building (20 years)","life_years":20,"sl_rate":"0.05","db_rate":null,"building":true,"depreciable":true},
       {"key":"building_non_permanent","name":"Non-permanent building (10 years)","life_years":10,"sl_rate":"0.1","db_rate":null,"building":true,"depreciable":true},
       {"key":"land","name":"Land (not depreciable)","life_years":null,"sl_rate":null,"db_rate":null,"building":false,"depreciable":false}
     ]}'::jsonb,
   'DJP guidance: Penyusutan dan Amortisasi - the fiscal depreciation groups of Article 11 of the Income Tax Law',
   'UU PPh Pasal 11; PMK 72 Tahun 2023 (depreciation and amortisation groups)',
   'https://pajak.go.id/en/node/34293', date '2026-09-21', 'verified', 'published', now(),
   'Groups 1-4 may use straight-line or declining balance; buildings straight-line only; land is not depreciated. Depreciation starts in the month the asset is acquired (or completed). Which group an asset belongs to is the legal list of the regulation; the user assigns it. Confirm against the regulation text with the tax adviser before go-live.');

-- ------------------------------------------------------------ calendar helpers
create function app_private.month_end(p_date date) returns date
language sql immutable as $$
  select (date_trunc('month', p_date) + interval '1 month' - interval '1 day')::date
$$;

-- True when the accounting period of a date accepts postings (the boolean form of assert_period_postable).
create function app_private.period_postable(p_entity uuid, p_date date) returns boolean
language plpgsql stable as $$
begin
  perform app_private.assert_period_postable(p_entity, p_date);
  return true;
exception when integrity_constraint_violation then
  return false;
end
$$;

-- ------------------------------------------------------------ the depreciation plan (pure arithmetic)
-- One row per month from p_from, for the remaining months of the useful life:
--   straight_line      the depreciable amount spread evenly; the last month absorbs the rounding remainder;
--   declining_balance  the double-declining rate (2 / life) on the net book value each month, switching to
--                      straight-line over the remaining months once that gives more; the last month lands exactly
--                      on the residual value.
-- p_nbv is the net book value at the start (cost less accumulated depreciation), p_life the whole useful life in
-- months (it sets the declining rate) and p_months the months that remain. Zero months are not listed.
create function app_private.asset_plan(
  p_method text, p_nbv numeric, p_residual numeric, p_months integer, p_life integer, p_from date, p_scale integer)
returns table (period_month date, amount numeric)
language plpgsql immutable as $$
declare
  v_dep numeric := p_nbv - p_residual;
  v_left numeric := p_nbv;
  v_amt numeric;
  v_sl numeric;
  v_db numeric;
  k integer;
begin
  if p_method not in ('straight_line', 'declining_balance') then
    raise exception 'INVALID: unknown depreciation method %', p_method using errcode = 'invalid_parameter_value';
  end if;
  if p_months < 1 or p_life < 1 or p_nbv < p_residual or p_residual < 0 then
    raise exception 'INVALID: a depreciation plan needs at least one month and a value not below the residual'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_dep = 0 then
    return;
  end if;
  for k in 1..p_months loop
    if k = p_months then
      v_amt := v_left - p_residual;
    elsif p_method = 'straight_line' then
      v_amt := app_private.round_amount(v_dep / p_months, p_scale, 'half_up');
      v_amt := least(v_amt, v_left - p_residual);
    else
      v_db := app_private.round_amount(v_left * 2 / p_life, p_scale, 'half_up');
      v_sl := app_private.round_amount((v_left - p_residual) / (p_months - k + 1), p_scale, 'half_up');
      v_amt := least(greatest(v_db, v_sl), v_left - p_residual);
    end if;
    if v_amt > 0 then
      period_month := (date_trunc('month', p_from) + make_interval(months => k - 1))::date;
      amount := v_amt;
      return next;
      v_left := v_left - v_amt;
    end if;
  end loop;
end
$$;

-- ------------------------------------------------------------ fixed assets
create table public.fixed_assets (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  asset_code text not null,
  name text not null check (length(btrim(name)) between 1 and 200),
  description text check (description is null or length(description) <= 2000),
  serial_number text check (serial_number is null or length(serial_number) <= 100),
  -- The accounting lifecycle (Step 07 §11). Operational tracking is the separate `condition` / location / custody.
  status text not null default 'draft' check (status in ('draft', 'active', 'sold', 'disposed', 'cancelled')),
  condition text not null default 'in_use' check (condition in ('in_use', 'in_storage', 'under_repair', 'damaged', 'lost')),
  location text check (location is null or length(location) <= 200),
  custodian text check (custodian is null or length(custodian) <= 200),
  -- Where the cost came from: a purchase line already booked, or an opening balance.
  source_type text not null check (source_type in ('bill_line', 'expense_line', 'opening')),
  bill_line_id uuid,
  expense_line_id uuid,
  cost_account_id uuid not null,
  acquisition_date date not null,
  acquisition_cost public.money_amount not null check (acquisition_cost > 0),
  -- Depreciation facts. They are set when the asset is activated and change afterwards only through a re-plan.
  in_service_date date,
  depreciation_method text check (depreciation_method in ('none', 'straight_line', 'declining_balance')),
  useful_life_months integer check (useful_life_months between 1 and 1200),
  residual_value public.money_amount not null default 0 check (residual_value >= 0),
  -- Opening assets: the accumulated depreciation already recorded at the cut-over date (no journal is posted for it).
  opening_accumulated public.money_amount not null default 0 check (opening_accumulated >= 0),
  opening_cutover date,
  plan_version integer not null default 0 check (plan_version >= 0),
  -- The fiscal group is a memo (Step 05): it never posts anything.
  fiscal_class_key text check (fiscal_class_key is null or fiscal_class_key ~ '^[a-z][a-z0-9_]{1,40}$'),
  fiscal_method text check (fiscal_method is null or fiscal_method in ('straight_line', 'declining_balance')),
  activated_at timestamptz,
  activated_by uuid,
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancelled_date date,
  cancel_reason text check (cancel_reason is null or length(cancel_reason) <= 1000),
  split_from_asset_id uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, cost_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, bill_line_id) references public.bill_lines (entity_id, id) on delete restrict,
  foreign key (entity_id, expense_line_id) references public.expense_lines (entity_id, id) on delete restrict,
  foreign key (entity_id, split_from_asset_id) references public.fixed_assets (entity_id, id) on delete restrict,
  constraint fixed_asset_source_shape check (
    case source_type
      when 'bill_line' then bill_line_id is not null and expense_line_id is null
      when 'expense_line' then expense_line_id is not null and bill_line_id is null
      else bill_line_id is null and expense_line_id is null end),
  constraint fixed_asset_opening_shape check (
    (source_type = 'opening') or (opening_accumulated = 0 and opening_cutover is null)),
  constraint fixed_asset_opening_dates check (opening_cutover is null or opening_cutover >= acquisition_date),
  constraint fixed_asset_residual check (residual_value <= acquisition_cost),
  constraint fixed_asset_opening_accum check (opening_accumulated <= acquisition_cost - residual_value),
  -- An asset that is in service carries a complete depreciation setup (Step 08 §11).
  constraint fixed_asset_setup check (
    status in ('draft', 'cancelled')
    or (in_service_date is not null and depreciation_method is not null and activated_at is not null
        and in_service_date >= acquisition_date
        and ((depreciation_method = 'none' and useful_life_months is null and residual_value = 0)
             or (depreciation_method <> 'none' and useful_life_months is not null)))),
  constraint fixed_asset_cancel_shape check (
    (status = 'cancelled') = (cancelled_at is not null and cancelled_date is not null and cancel_reason is not null))
);
create unique index fixed_assets_code_uq on public.fixed_assets (entity_id, asset_code);
create index fixed_assets_status_idx on public.fixed_assets (entity_id, status, acquisition_date);
create index fixed_assets_bill_line_idx on public.fixed_assets (entity_id, bill_line_id) where bill_line_id is not null;
create index fixed_assets_expense_line_idx on public.fixed_assets (entity_id, expense_line_id) where expense_line_id is not null;

-- The identity and cost of an asset never change under the register; the state machine is explicit.
create function app_private.tg_fixed_assets_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status not in ('draft', 'active') then
      raise exception 'An asset starts as a draft or (opening) active' using errcode = 'integrity_constraint_violation';
    end if;
    if new.status = 'active' and new.source_type <> 'opening' then
      raise exception 'Only an opening asset is created active' using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;
  if (new.entity_id, new.asset_code, new.source_type, new.bill_line_id, new.expense_line_id, new.cost_account_id,
      new.split_from_asset_id, new.created_at, new.created_by)
     is distinct from
     (old.entity_id, old.asset_code, old.source_type, old.bill_line_id, old.expense_line_id, old.cost_account_id,
      old.split_from_asset_id, old.created_at, old.created_by) then
    raise exception 'The identity of an asset (code, source, cost account) cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  if old.status = 'cancelled' then
    raise exception 'A cancelled asset cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status
     and (old.status, new.status) not in
         (('draft', 'active'), ('draft', 'cancelled'), ('active', 'cancelled'), ('active', 'sold'),
          ('active', 'disposed'), ('sold', 'active'), ('disposed', 'active')) then
    raise exception 'An asset cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  -- Cost and acquisition facts are fixed once the asset leaves the draft (a draft is split or corrected first).
  if old.status <> 'draft' and (new.acquisition_cost, new.acquisition_date, new.opening_accumulated, new.opening_cutover)
     is distinct from (old.acquisition_cost, old.acquisition_date, old.opening_accumulated, old.opening_cutover) then
    raise exception 'The cost of an asset that has left the draft cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  if old.status in ('sold', 'disposed') and new.status = old.status
     and (new.in_service_date, new.depreciation_method, new.useful_life_months, new.residual_value)
         is distinct from (old.in_service_date, old.depreciation_method, old.useful_life_months, old.residual_value) then
    raise exception 'A sold or disposed asset keeps its depreciation facts' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.fixed_assets
  for each row execute function app_private.tg_fixed_assets_guard();
create trigger tg_forbid_delete before delete on public.fixed_assets
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.fixed_assets
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.fixed_assets');
call app_private.secure_table('public.fixed_assets');
create trigger tg_audit after insert or update or delete on public.fixed_assets
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ the accounting depreciation schedule
create table public.asset_depreciation_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  asset_id uuid not null,
  period_month date not null check (period_month = date_trunc('month', period_month)::date),
  amount public.money_amount not null check (amount > 0),
  status text not null default 'scheduled' check (status in ('scheduled', 'posted', 'reversed', 'cancelled')),
  plan_version integer not null check (plan_version >= 0),
  journal_id uuid,
  posted_at timestamptz,
  posted_by uuid,
  reversal_journal_id uuid,
  reversed_date date,
  reversed_at timestamptz,
  reversed_by uuid,
  reverse_reason text check (reverse_reason is null or length(reverse_reason) <= 1000),
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, asset_id) references public.fixed_assets (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint asset_dep_state_shape check (
    case status
      when 'scheduled' then journal_id is null and reversal_journal_id is null and cancelled_at is null
      when 'posted' then journal_id is not null and posted_at is not null and reversal_journal_id is null and cancelled_at is null
      when 'reversed' then journal_id is not null and reversal_journal_id is not null and reversed_date is not null
                           and reversed_at is not null and reverse_reason is not null
      else cancelled_at is not null and journal_id is null end)
);
-- One live line per asset and month: a month is either waiting, or posted; reversed and cancelled lines are history.
create unique index asset_dep_live_uq on public.asset_depreciation_lines (asset_id, period_month)
  where status in ('scheduled', 'posted');
create index asset_dep_due_idx on public.asset_depreciation_lines (entity_id, period_month) where status = 'scheduled';
create index asset_dep_asset_idx on public.asset_depreciation_lines (entity_id, asset_id, period_month);

create function app_private.tg_asset_dep_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'scheduled' then
      raise exception 'A depreciation line starts as scheduled' using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;
  if (new.entity_id, new.asset_id, new.period_month, new.amount, new.plan_version)
     is distinct from (old.entity_id, old.asset_id, old.period_month, old.amount, old.plan_version) then
    raise exception 'The facts of a depreciation line cannot change; cancel it and re-plan instead'
      using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status
     and (old.status, new.status) not in (('scheduled', 'posted'), ('scheduled', 'cancelled'), ('posted', 'reversed')) then
    raise exception 'A depreciation line cannot move from % to %', old.status, new.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if old.status in ('reversed', 'cancelled') then
    raise exception 'A % depreciation line cannot change any more', old.status using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.asset_depreciation_lines
  for each row execute function app_private.tg_asset_dep_guard();
create trigger tg_forbid_delete before delete on public.asset_depreciation_lines
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.asset_depreciation_lines
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.asset_depreciation_lines');
call app_private.secure_table('public.asset_depreciation_lines');
create trigger tg_audit after insert or update or delete on public.asset_depreciation_lines
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ the operational and lifecycle history of an asset
-- Append-only: what happened to the asset and when. Operational events (transfers, damage) post nothing (Step 07 §11,
-- Step 08 §11 "asset status changes alone do not fabricate accounting entries").
create table public.asset_events (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  asset_id uuid not null,
  event_type text not null check (event_type in (
    'registered', 'split', 'activated', 'replanned', 'condition_changed', 'transferred', 'details_changed',
    'cancelled', 'depreciation_posted', 'depreciation_reversed', 'disposed', 'disposal_reversed', 'opening_loaded',
    'fiscal_class_set')),
  event_date date not null,
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  note text check (note is null or length(note) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  foreign key (entity_id, asset_id) references public.fixed_assets (entity_id, id) on delete restrict
);
create index asset_events_asset_idx on public.asset_events (entity_id, asset_id, created_at);
create trigger tg_forbid_update before update on public.asset_events
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.asset_events
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.asset_events
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.asset_events');

-- ------------------------------------------------------------ privileges of the internal functions
revoke all on function app_private.ensure_asset_numbering(uuid) from public;
revoke all on function app_private.month_end(date) from public;
revoke all on function app_private.period_postable(uuid, date) from public;
revoke all on function app_private.asset_plan(text, numeric, numeric, integer, integer, date, integer) from public;
revoke all on function app_private.tg_fixed_assets_guard() from public;
revoke all on function app_private.tg_asset_dep_guard() from public;
