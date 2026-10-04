-- P15 (decision 118's open item, closed by decision 281; DECISIONS 304): foreign-currency loans - the OWNER's
-- "Versi Sederhana" choice. Any loan may be tagged with a foreign currency; principal/proceeds/repayments stay
-- exactly as P8 built them (base currency only, `loan_create`/`loan_activate`/`loan_repay` untouched). What is new
-- is a manual, monthly, informational revaluation: the OWNER enters the loan's outstanding balance in the foreign
-- currency and the period-end rate, and the engine posts the FX difference to P&L (FX_GAIN_LOSS, seeded for every
-- Entity since P1) against the loan's own principal account - additively, the same way P4 Transfers already does.
--
-- Why additive and not a redesign of the loan itself (Step 01 #19, Step 04 §6 untouched):
--   `app_private.loan_outstanding` is the ONE place every reader (`loan_list`, `loan_detail`, `loan_summary`,
--   `loan_due`) and the financing-control reconciliation (`app_private.loans_total`) gets the carrying amount from.
--   Patching it to add the running sum of posted revaluations (exactly like it already adds up reversed-aware
--   payments) makes every one of those correct automatically, with zero other code touched.
--
-- Postings (mirrors the sign convention of transfer_figures/confirm_transfer_core, Step 04 §14):
--   the outstanding balance INCREASES (adjustment > 0)      the outstanding balance DECREASES (adjustment < 0)
--     borrowed (liability grows): Dr FX_GAIN_LOSS / Cr loan      borrowed (liability shrinks): Dr loan / Cr FX_GAIN_LOSS
--     lent (receivable grows):    Dr loan / Cr FX_GAIN_LOSS      lent (receivable shrinks):    Dr FX_GAIN_LOSS / Cr loan
-- A mistyped rate cannot conjure a large, unnoticed gain or loss: a revaluation whose difference exceeds 20% of the
-- outstanding balance is refused, the same guard `transfer_figures` already uses.

-- ------------------------------------------------------------ the FX setting of a loan (one row, set once)
create table public.loan_fx_terms (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  loan_id uuid not null,
  currency public.currency_code not null,
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, loan_id) references public.loans (entity_id, id) on delete restrict
);
create unique index loan_fx_terms_loan_uq on public.loan_fx_terms (loan_id);

create function app_private.tg_loan_fx_terms_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    if new.loan_id is distinct from old.loan_id or new.entity_id is distinct from old.entity_id then
      raise exception 'The loan of an FX setting cannot change' using errcode = 'integrity_constraint_violation';
    end if;
    if new.currency is distinct from old.currency
       and exists (select 1 from public.loan_fx_revaluations r where r.loan_id = old.loan_id) then
      raise exception 'CONFLICT: this loan already has an FX revaluation; its currency cannot change any more'
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.loan_fx_terms
  for each row execute function app_private.tg_loan_fx_terms_guard();
create trigger tg_forbid_delete before delete on public.loan_fx_terms
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.loan_fx_terms
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.loan_fx_terms');
call app_private.secure_table('public.loan_fx_terms');
create trigger tg_audit after insert or update or delete on public.loan_fx_terms
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ one row per posted (or reversed) revaluation
create table public.loan_fx_revaluations (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  loan_id uuid not null,
  revaluation_date date not null,
  status text not null default 'posted' check (status in ('posted', 'reversed')),
  -- The outstanding balance in the foreign currency, as the OWNER read it off the statement/agreement.
  fc_outstanding public.money_amount not null check (fc_outstanding > 0),
  rate public.fx_rate not null,
  -- fc_outstanding converted at `rate`; outstanding_before is the base-currency carrying amount just before this
  -- row; adjustment is what loan_outstanding() adds from this row onward (base_equivalent = outstanding_before + adjustment).
  base_equivalent public.money_amount not null check (base_equivalent >= 0),
  outstanding_before public.money_amount not null check (outstanding_before >= 0),
  adjustment public.money_amount not null,
  note text check (note is null or length(note) <= 1000),
  journal_id uuid,
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
  foreign key (entity_id, loan_id) references public.loans (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint loan_fx_reval_math check (base_equivalent = outstanding_before + adjustment),
  constraint loan_fx_reval_state check (
    (status = 'posted' and reversal_journal_id is null and reversed_at is null and reversed_date is null
       and reversed_by is null and reverse_reason is null)
    or (status = 'reversed' and reversed_at is not null and reversed_date is not null and reversed_by is not null
       and reverse_reason is not null))
);
create index loan_fx_reval_loan_idx on public.loan_fx_revaluations (entity_id, loan_id, revaluation_date);
create unique index loan_fx_reval_date_uq on public.loan_fx_revaluations (loan_id, revaluation_date) where status = 'posted';

create function app_private.tg_loan_fx_revaluations_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by',
                                   'reverse_reason', 'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' then
    raise exception 'A reversed FX revaluation cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of an FX revaluation cannot be changed; reverse it instead' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status and (old.status, new.status) <> ('posted', 'reversed') then
    raise exception 'An FX revaluation cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.loan_fx_revaluations
  for each row execute function app_private.tg_loan_fx_revaluations_guard();
create trigger tg_forbid_delete before delete on public.loan_fx_revaluations
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.loan_fx_revaluations
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.loan_fx_revaluations');
call app_private.secure_table('public.loan_fx_revaluations');
create trigger tg_audit after insert or update or delete on public.loan_fx_revaluations
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ the additive patch: what is outstanding
-- Unchanged from P8 except for the added term: the running sum of posted revaluations (reversed-aware exactly like
-- the payments sum beside it) is added to the base-currency carrying amount.
create or replace function app_private.loan_outstanding(p_loan uuid, p_as_of date default null)
returns numeric
language sql stable as $$
  select case when l.effective_date is null or l.status in ('draft', 'cancelled') or (p_as_of is not null and p_as_of < l.effective_date)
              then 0
         else l.funded_principal - coalesce((
           select sum(p.principal) from public.loan_payments p
           where p.loan_id = l.id and (p_as_of is null or p.payment_date <= p_as_of)
             and (p.status = 'active' or (p_as_of is not null and p.reversed_date > p_as_of))), 0)
           + coalesce((
           select sum(r.adjustment) from public.loan_fx_revaluations r
           where r.loan_id = l.id and (p_as_of is null or r.revaluation_date <= p_as_of)
             and (r.status = 'posted' or (p_as_of is not null and r.reversed_date > p_as_of))), 0)
         end
  from public.loans l
  where l.id = p_loan
$$;

-- ------------------------------------------------------------ set (or change, before any revaluation) the FX currency
create function public.loan_set_fx_terms(p_loan uuid, p_currency text, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  v_base public.currency_code;
  v_currency text := upper(btrim(coalesce(p_currency, '')));
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_old text;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: setting the FX currency of a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if l.status not in ('active', 'closed') then
    raise exception 'INVALID: only an active or closed loan can be set to a foreign currency' using errcode = 'invalid_parameter_value';
  end if;
  v_base := app_private.entity_base_currency(l.entity_id);
  if v_currency !~ '^[A-Z]{3}$' or not exists (select 1 from public.currencies where code = v_currency and is_active) then
    raise exception 'INVALID: unknown currency' using errcode = 'invalid_parameter_value';
  end if;
  if v_currency = v_base then
    raise exception 'INVALID: the FX currency must differ from the Entity base currency (%)', v_base using errcode = 'invalid_parameter_value';
  end if;
  if v_note is not null and length(v_note) > 500 then
    raise exception 'INVALID: the note allows up to 500 characters' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select currency into v_old from public.loan_fx_terms where loan_id = l.id;
  if v_old is not null and v_old <> v_currency and exists (select 1 from public.loan_fx_revaluations where loan_id = l.id) then
    raise exception 'CONFLICT: this loan already has an FX revaluation; its currency cannot change any more'
      using errcode = 'integrity_constraint_violation';
  end if;
  insert into public.loan_fx_terms (entity_id, loan_id, currency, note, created_by)
  values (l.entity_id, l.id, v_currency, v_note, auth.uid())
  on conflict (loan_id) do update set currency = excluded.currency, note = excluded.note, updated_at = now(), updated_by = auth.uid()
  returning id into v_id;
  return v_id;
end
$$;

-- ------------------------------------------------------------ post a monthly revaluation
create function public.loan_revalue_fx(
  p_loan uuid, p_key text, p_date date, p_fc_outstanding text, p_rate text, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  t public.loan_fx_terms%rowtype;
  v_replay uuid;
  v_fc_scale integer;
  v_fc numeric;
  v_rate numeric;
  v_base_equiv numeric;
  v_before numeric;
  v_adj numeric;
  v_last date;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid := gen_random_uuid();
  v_desc text;
  v_lines jsonb;
  v_journal uuid;
  v_fx_account uuid;
  v_debit_fx boolean;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: revaluing a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  select * into t from public.loan_fx_terms where loan_id = l.id;
  if not found then
    raise exception 'INVALID: set this loan''s FX currency before revaluing it' using errcode = 'invalid_parameter_value';
  end if;
  v_replay := app_private.idem_begin('loan.revalue_fx', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_loan, 'd', p_date, 'fc', p_fc_outstanding, 'r', p_rate, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: only an active loan can be revalued (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_date is null or p_date <> app_private.month_end(p_date) then
    raise exception 'INVALID: a revaluation is dated on the last day of a month' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(l.entity_id) then
    raise exception 'INVALID: a revaluation cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_date < l.effective_date then
    raise exception 'INVALID: a revaluation cannot be dated before the proceeds (%)', l.effective_date using errcode = 'invalid_parameter_value';
  end if;
  select max(r.revaluation_date) into v_last from public.loan_fx_revaluations r where r.loan_id = l.id and r.status = 'posted';
  if v_last is not null and p_date <= v_last then
    raise exception 'INVALID: a revaluation must be dated after the last one (%)', v_last using errcode = 'invalid_parameter_value';
  end if;
  v_fc_scale := app_private.currency_scale(t.currency);
  v_fc := app_private.money_arg(p_fc_outstanding, 'the outstanding balance in ' || t.currency, v_fc_scale);
  if p_rate is null or btrim(p_rate) = '' then
    raise exception 'INVALID: the exchange rate is required' using errcode = 'invalid_parameter_value';
  end if;
  begin
    v_rate := btrim(p_rate)::numeric;
  exception when others then
    raise exception 'INVALID: the exchange rate is not a valid number' using errcode = 'invalid_parameter_value';
  end;
  if not app_private.is_finite(v_rate) or v_rate <= 0 or app_private.round_amount(v_rate, 10, 'down') <> v_rate then
    raise exception 'INVALID: the exchange rate must be a positive number with up to 10 decimals' using errcode = 'invalid_parameter_value';
  end if;
  if v_note is not null and length(v_note) > 1000 then
    raise exception 'INVALID: the note allows up to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_base_equiv := app_private.convert_amount(v_fc, v_rate, app_private.entity_base_currency(l.entity_id));
  v_before := app_private.loan_outstanding(l.id, p_date);
  if v_before <= 0 then
    raise exception 'CONFLICT: nothing is outstanding on this loan at %', p_date using errcode = 'integrity_constraint_violation';
  end if;
  v_adj := v_base_equiv - v_before;
  if abs(v_adj) * 5 > v_before then
    raise exception 'INVALID: the FX difference exceeds 20%% of the outstanding balance; check the rate and the outstanding balance'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_maker_checker(l.entity_id, 'loans', 'revalue_fx', abs(v_adj), auth.uid(), 'revalue this loan');

  if v_adj <> 0 then
    select a.id into v_fx_account from public.ledger_accounts a
    where a.entity_id = l.entity_id and a.system_key = 'FX_GAIN_LOSS' and a.status = 'active';
    if v_fx_account is null then
      raise exception 'CONFLICT: this Entity has no FX gain/loss account' using errcode = 'integrity_constraint_violation';
    end if;
    v_desc := format('Loan FX revaluation %s - %s (%s %s @ %s)', l.loan_number, left(l.counterparty_name, 80),
                     trim_scale(v_fc), t.currency, trim_scale(v_rate));
    -- adjustment>0 & borrowed (liability grows), or adjustment<0 & lent (receivable shrinks): a loss -> debit FX_GAIN_LOSS.
    v_debit_fx := (v_adj > 0) = (l.direction = 'borrowed');
    if v_debit_fx then
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_fx_account, 'debit', abs(v_adj), 'credit', 0, 'description', v_desc),
        jsonb_build_object('account_id', l.principal_account_id, 'debit', 0, 'credit', abs(v_adj), 'description', v_desc));
    else
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', l.principal_account_id, 'debit', abs(v_adj), 'credit', 0, 'description', v_desc),
        jsonb_build_object('account_id', v_fx_account, 'debit', 0, 'credit', abs(v_adj), 'description', v_desc));
    end if;
    v_journal := app_private.post_system_journal(l.entity_id, 'loan_fx_revaluation', v_id, 'loan.fx_revaluation', 'loan.fx.v1',
                                                 p_date, v_desc, v_lines);
  end if;

  insert into public.loan_fx_revaluations
    (id, entity_id, loan_id, revaluation_date, fc_outstanding, rate, base_equivalent, outstanding_before, adjustment,
     journal_id, note, created_by)
  values
    (v_id, l.entity_id, l.id, p_date, v_fc, v_rate, v_base_equiv, v_before, v_adj, v_journal, v_note, auth.uid());
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (l.entity_id, 'LoanFxRevalued', 'loan', l.id, jsonb_build_object('number', l.loan_number, 'adjustment', v_adj::text));
  perform app_private.idem_complete('loan.revalue_fx', l.entity_id, p_key, 'loan_fx_revaluations', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ reverse the most recent revaluation
create function public.loan_reverse_fx_revaluation(p_revaluation uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.loan_fx_revaluations%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
  v_last date;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into r from public.loan_fx_revaluations where id = p_revaluation;
  if not found or not app_authz.has_permission(r.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: reversing an FX revaluation needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a reversal needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  if p_date is null or p_date > app_private.entity_today(r.entity_id) then
    raise exception 'INVALID: a reversal needs a date that is not in the future' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  v_replay := app_private.idem_begin('loan.reverse_fx_revaluation', r.entity_id, p_key,
    md5(jsonb_build_object('r', p_revaluation, 'd', p_date, 'x', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || r.loan_id::text, 0));
  select * into r from public.loan_fx_revaluations where id = p_revaluation for update;
  if r.status <> 'posted' then
    raise exception 'CONFLICT: only a posted FX revaluation can be reversed (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  select max(x.revaluation_date) into v_last from public.loan_fx_revaluations x where x.loan_id = r.loan_id and x.status = 'posted';
  if r.revaluation_date <> v_last then
    raise exception 'CONFLICT: only the most recent FX revaluation of a loan can be reversed' using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < r.revaluation_date then
    raise exception 'INVALID: a reversal cannot be dated before the revaluation it reverses' using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  if r.journal_id is not null then
    v_rev := app_private.reverse_journal_core(r.journal_id, p_date, v_reason);
  end if;
  update public.loan_fx_revaluations
  set status = 'reversed', reversal_journal_id = v_rev, reversed_date = p_date, reversed_at = now(), reversed_by = auth.uid(),
      reverse_reason = v_reason
  where id = r.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (r.entity_id, 'LoanFxRevaluationReversed', 'loan', r.loan_id, jsonb_build_object('revaluation', r.id));
  perform app_private.idem_complete('loan.reverse_fx_revaluation', r.entity_id, p_key, 'loan_fx_revaluations', r.id);
  return coalesce(v_rev, r.id);
end
$$;

-- ------------------------------------------------------------ surface the FX setting and history on the loan detail
create or replace function public.loan_detail(p_loan uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.view') then
    raise exception 'FORBIDDEN: missing loans.view' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'id', l.id, 'number', l.loan_number, 'direction', l.direction, 'status', l.status,
    'counterparty', l.counterparty_name, 'contact_id', l.contact_id, 'purpose', l.purpose,
    'principal', l.principal::text, 'funded_principal', l.funded_principal::text,
    'outstanding', app_private.loan_outstanding(l.id)::text, 'source_type', l.source_type,
    'agreement_date', l.agreement_date, 'effective_date', l.effective_date, 'closed_date', l.closed_date,
    'term_class', l.term_class, 'principal_account_id', l.principal_account_id,
    'financial_account_id', l.financial_account_id, 'proceeds_journal_id', l.proceeds_journal_id,
    'asset_id', l.asset_id, 'related_entity_id', l.related_entity_id, 'relationship_basis', l.relationship_basis,
    'cancel_reason', l.cancel_reason,
    'versions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id, 'version_no', v.version_no, 'status', v.status, 'method', v.method, 'rate', v.rate::text,
        'installments', v.installments, 'step_months', v.step_months, 'effective_from', v.effective_from,
        'principal_basis', v.principal_basis::text, 'maturity_date', v.maturity_date, 'reason', v.reason)
        order by v.version_no) from public.loan_schedule_versions v where v.loan_id = l.id), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'number', p.payment_number, 'kind', p.kind, 'status', p.status, 'date', p.payment_date,
        'principal', p.principal::text, 'interest', p.interest::text, 'fee', p.fee::text, 'tax_status', p.tax_status,
        'journal_id', p.journal_id, 'reversal_journal_id', p.reversal_journal_id, 'note', p.note,
        'schedule_version_id', p.schedule_version_id,
        'allocations', coalesce((
          select jsonb_agg(jsonb_build_object('item_id', a.item_id, 'seq', i.seq, 'principal', a.principal::text,
                                              'interest', a.interest::text, 'fee', a.fee::text) order by i.seq nulls last)
          from public.loan_payment_allocations a
          left join public.loan_schedule_items i on i.id = a.item_id and i.entity_id = a.entity_id
          where a.payment_id = p.id), '[]'::jsonb))
        order by p.payment_date, p.payment_number)
      from public.loan_payments p where p.loan_id = l.id), '[]'::jsonb),
    'fx_terms', (
      select jsonb_build_object('currency', t.currency, 'note', t.note)
      from public.loan_fx_terms t where t.loan_id = l.id),
    'fx_revaluations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'date', r.revaluation_date, 'status', r.status, 'fc_outstanding', r.fc_outstanding::text,
        'rate', r.rate::text, 'base_equivalent', r.base_equivalent::text, 'outstanding_before', r.outstanding_before::text,
        'adjustment', r.adjustment::text, 'note', r.note, 'journal_id', r.journal_id,
        'reversal_journal_id', r.reversal_journal_id, 'reverse_reason', r.reverse_reason)
        order by r.revaluation_date desc)
      from public.loan_fx_revaluations r where r.loan_id = l.id), '[]'::jsonb));
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.loan_fx_terms');
create policy loan_fx_terms_select on public.loan_fx_terms for select to authenticated
  using (app_authz.has_permission(entity_id, 'loans.view'));
call app_private.expose_select('public.loan_fx_revaluations');
create policy loan_fx_revaluations_select on public.loan_fx_revaluations for select to authenticated
  using (app_authz.has_permission(entity_id, 'loans.view'));

revoke all on function app_private.tg_loan_fx_terms_guard() from public;
revoke all on function app_private.tg_loan_fx_revaluations_guard() from public;

revoke all on function public.loan_set_fx_terms(uuid, text, text) from public, anon;
revoke all on function public.loan_revalue_fx(uuid, text, date, text, text, text) from public, anon;
revoke all on function public.loan_reverse_fx_revaluation(uuid, text, date, text) from public, anon;
grant execute on function public.loan_set_fx_terms(uuid, text, text) to authenticated;
grant execute on function public.loan_revalue_fx(uuid, text, date, text, text, text) to authenticated;
grant execute on function public.loan_reverse_fx_revaluation(uuid, text, date, text) to authenticated;
