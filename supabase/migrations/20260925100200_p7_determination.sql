-- P7 (Step 15 §11) part 3: the determination engine and the tax ledger.
-- Authority: Step 05 §1 (separate determination layer), §5 (determination pipeline), §10 (withholding), §11 (PPN/PKP),
-- §12 (tax ledger), §14 (review states and explainability), §15 (safety rules), Step 04 §9 (tax accounting
-- interface), Step 07 §15 (tax workflow), Step 08 §10 (tax integrity).
--
-- What this part delivers
--   * EVALUATORS. Pure, deterministic functions that read the Entity's tax profile in force on the document date, the
--     counterparty's tax facts, the classification carried by each line and the rule versions in force on that date,
--     and return an explainable result: which tax, why, on which facts, under which rule version, on which base and
--     formula, and what the accounting and compliance consequence is. Three families: output VAT on an invoice, input
--     VAT on a bill or expense (creditability), income-tax withholding (PPh 23) on a bill or expense. Whenever a
--     material fact is missing or the treatment is ambiguous or unsupported the result is NEEDS_REVIEW with the
--     reasons; nothing is guessed (Step 05 §1, §14, §15).
--   * OVERRIDES. A permitted, reasoned, evidenced and audited deviation from the computed amount (tax.override +
--     recent step-up). The rule and the computed amount stay visible; the rule master is never touched.
--   * CONFIRMATION of a line's classification by a tax reviewer (OWNER_CONFIRMED).
--   * DETERMINATIONS. What was decided for a posted document, stored once with the rule versions and the facts that
--     were used, immutable except for being superseded (the document was reversed). A later change of the rule
--     master never rewrites them (Step 05 §13, §15).
--   * The TAX LEDGER: one append-only entry per accrual or reversal, by tax type and tax period. Payments, filings
--     and reconciliation (next part) work on it.
-- The document commands that post the accounting consequence come in the next part.

-- ------------------------------------------------------------ line confirmation columns (invoices)
alter table public.invoice_lines
  add column tax_confirmed_by uuid,
  add column tax_confirmed_at timestamptz,
  add constraint invoice_line_tax_confirm_shape check ((tax_confirmed_by is null) = (tax_confirmed_at is null));

-- ------------------------------------------------------------ overrides
create table public.tax_overrides (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  source_type text not null check (source_type in ('invoice', 'bill', 'expense')),
  source_id uuid not null,
  tax_kind text not null check (tax_kind in ('vat_output', 'vat_input', 'wht_pph23')),
  -- The tax amount the OWNER decided on (the creditable input VAT for vat_input; the withheld amount for wht).
  amount public.money_amount not null check (amount >= 0),
  reason text not null check (length(btrim(reason)) between 10 and 1000),
  evidence_note text not null check (length(btrim(evidence_note)) between 5 and 1000),
  evidence_document_id uuid,
  status text not null default 'active' check (status in ('active', 'withdrawn')),
  -- Set when a posted determination consumed the override; from then on it is history.
  determination_id uuid,
  withdrawn_at timestamptz,
  withdrawn_by uuid,
  withdraw_reason text check (withdraw_reason is null or length(withdraw_reason) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, evidence_document_id) references public.documents (entity_id, id) on delete restrict,
  constraint tax_override_withdraw_shape check ((status = 'withdrawn') = (withdrawn_at is not null))
);
create unique index tax_overrides_active_uq on public.tax_overrides (entity_id, source_type, source_id, tax_kind)
  where status = 'active';
create index tax_overrides_source_idx on public.tax_overrides (entity_id, source_type, source_id);

create function app_private.tg_tax_overrides_guard() returns trigger
language plpgsql as $$
declare
  v_ok constant text[] := array['status', 'determination_id', 'withdrawn_at', 'withdrawn_by', 'withdraw_reason',
                                'updated_at', 'updated_by', 'version'];
begin
  if tg_op = 'UPDATE' then
    if old.status = 'withdrawn' then
      raise exception 'A withdrawn override cannot change any more' using errcode = 'integrity_constraint_violation';
    end if;
    if (to_jsonb(new) - v_ok) is distinct from (to_jsonb(old) - v_ok) then
      raise exception 'An override is never edited; withdraw it and record a new one' using errcode = 'integrity_constraint_violation';
    end if;
    if old.determination_id is not null and new.status = 'withdrawn' then
      raise exception 'CONFLICT: this override was used by a posted determination and is part of its history'
        using errcode = 'integrity_constraint_violation';
    end if;
    if old.determination_id is not null and new.determination_id is distinct from old.determination_id then
      raise exception 'An override is consumed once' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.tax_overrides
  for each row execute function app_private.tg_tax_overrides_guard();
create trigger tg_forbid_delete before delete on public.tax_overrides
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_overrides
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_overrides');
call app_private.secure_table('public.tax_overrides');
create trigger tg_audit after insert or update or delete on public.tax_overrides
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ determinations
-- One row per tax result of a posted document (or of a tax period run). It stores the answer to "what tax, why,
-- which facts, which rule version, which base/rate/formula, which consequence" (Step 05 §14) at the time it was made.
create table public.tax_determinations (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  tax_kind text not null check (tax_kind in ('vat_output', 'vat_input', 'wht_pph23', 'final_umkm')),
  -- The settlement grouping: VAT output and input are settled together, withholding and final tax on their own.
  tax_type text not null check (tax_type in ('vat', 'wht_pph23', 'final_umkm')),
  source_type text not null check (source_type in ('invoice', 'bill', 'expense', 'period')),
  source_id uuid,
  event_date date not null,
  -- First day of the month the tax belongs to (monthly returns; Step 08 §22 keeps it separate from posting date).
  tax_period date not null check (tax_period = date_trunc('month', tax_period)::date),
  status text not null check (status in ('auto_determined', 'needs_review', 'owner_confirmed', 'overridden', 'superseded')),
  currency public.currency_code not null,
  base_amount public.money_amount not null default 0 check (base_amount >= 0),
  rate numeric(12, 8) check (rate is null or (rate >= 0 and rate <= 1)),
  -- The amount that creates the ledger consequence (a liability, or for input VAT a tax asset).
  tax_amount public.money_amount not null default 0 check (tax_amount >= 0),
  direction text not null check (direction in ('payable', 'asset')),
  rules jsonb not null default '[]'::jsonb,
  facts jsonb not null default '{}'::jsonb,
  trace jsonb not null default '[]'::jsonb,
  components jsonb not null default '[]'::jsonb,
  consequence text,
  -- What the engine computed before an override replaced it.
  computed_tax_amount public.money_amount,
  override_id uuid,
  journal_id uuid,
  -- The document line facts were confirmed by a tax reviewer.
  confirmed boolean not null default false,
  revision integer not null default 1 check (revision > 0),
  supersedes_id uuid,
  superseded_at timestamptz,
  superseded_reason text check (superseded_reason is null or length(superseded_reason) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, supersedes_id) references public.tax_determinations (entity_id, id) on delete restrict,
  foreign key (entity_id, override_id) references public.tax_overrides (entity_id, id) on delete restrict,
  constraint tax_det_source_shape check ((source_type = 'period') = (source_id is null)),
  constraint tax_det_review_only_period check (status <> 'needs_review' or (source_type = 'period' and tax_amount = 0)),
  constraint tax_det_superseded_shape check ((status = 'superseded') = (superseded_at is not null)),
  constraint tax_det_direction_shape check (
    (tax_kind = 'vat_input' and direction = 'asset') or (tax_kind <> 'vat_input' and direction = 'payable')),
  constraint tax_det_type_shape check (
    tax_type = case tax_kind when 'vat_output' then 'vat' when 'vat_input' then 'vat' else tax_kind end)
);
-- A document has one live determination per kind; a period keeps every run (each is an adjustment).
create unique index tax_det_source_live_uq on public.tax_determinations (entity_id, source_type, source_id, tax_kind)
  where superseded_at is null and source_type <> 'period';
create index tax_det_period_idx on public.tax_determinations (entity_id, tax_type, tax_period);
create index tax_det_source_idx on public.tax_determinations (entity_id, source_type, source_id);

create function app_private.tg_tax_determinations_guard() returns trigger
language plpgsql as $$
declare
  v_ok constant text[] := array['status', 'superseded_at', 'superseded_reason', 'updated_at', 'updated_by', 'version'];
begin
  if tg_op = 'UPDATE' then
    if old.status = 'superseded' then
      raise exception 'A superseded determination cannot change any more' using errcode = 'integrity_constraint_violation';
    end if;
    if new.status <> 'superseded' or (to_jsonb(new) - v_ok) is distinct from (to_jsonb(old) - v_ok) then
      raise exception 'A determination is history: it can only be superseded (Step 05 §13)'
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.tax_determinations
  for each row execute function app_private.tg_tax_determinations_guard();
create trigger tg_forbid_delete before delete on public.tax_determinations
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_determinations
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_determinations');
call app_private.secure_table('public.tax_determinations');
create trigger tg_audit after insert or update or delete on public.tax_determinations
  for each row execute function app_private.tg_audit('entity_id');

alter table public.tax_overrides
  add constraint tax_overrides_determination_fk
  foreign key (entity_id, determination_id) references public.tax_determinations (entity_id, id) on delete restrict;

-- ------------------------------------------------------------ the tax ledger
-- Append-only. A positive amount increases the balance of its (tax type, period, direction), a negative amount (a
-- reversal of a document) decreases it. Paid amounts are the tax payments of the next part, never ledger rows, so a
-- payment cannot create an expense (Step 05 §15) and the liability stays visible next to what was paid.
create table public.tax_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  determination_id uuid not null,
  tax_kind text not null check (tax_kind in ('vat_output', 'vat_input', 'wht_pph23', 'final_umkm')),
  tax_type text not null check (tax_type in ('vat', 'wht_pph23', 'final_umkm')),
  tax_period date not null check (tax_period = date_trunc('month', tax_period)::date),
  direction text not null check (direction in ('payable', 'asset')),
  entry_kind text not null check (entry_kind in ('accrual', 'reversal')),
  amount public.money_amount not null check (amount <> 0),
  entry_date date not null,
  journal_id uuid not null,
  description text,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  foreign key (entity_id, determination_id) references public.tax_determinations (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint tax_ledger_sign check ((entry_kind = 'accrual') = (amount > 0))
);
create index tax_ledger_period_idx on public.tax_ledger_entries (entity_id, tax_type, tax_period, direction);
create index tax_ledger_det_idx on public.tax_ledger_entries (entity_id, determination_id);
create trigger tg_forbid_update before update on public.tax_ledger_entries
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.tax_ledger_entries
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_ledger_entries
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_stamp_created before insert on public.tax_ledger_entries
  for each row execute function app_private.tg_stamp_created();
call app_private.secure_table('public.tax_ledger_entries');

-- ------------------------------------------------------------ small helpers
create function app_private.tax_period_start(p_date date) returns date
language sql immutable as $$ select date_trunc('month', p_date)::date $$;

-- Amounts inside result documents are decimal strings (never floating point).
create function app_private.tax_money(p_amount numeric) returns jsonb
language sql immutable as $$ select to_jsonb(trim_scale(coalesce(p_amount, 0))::text) $$;

create function app_private.tax_trace_add(p_trace jsonb, p_text text) returns jsonb
language sql immutable as $$
  select p_trace || jsonb_build_array(jsonb_build_object('n', jsonb_array_length(p_trace) + 1, 'text', p_text))
$$;

create function app_private.tax_rule_ref(r public.tax_rule_versions) returns jsonb
language sql immutable as $$
  select jsonb_build_object('rule_id', r.id, 'code', r.code, 'rule_version', r.rule_version,
                            'effective_from', r.effective_from, 'source_ref', r.source_ref, 'verified_on', r.verified_on)
$$;

create function app_private.tax_round(p_params jsonb, p_amount numeric) returns numeric
language sql immutable as $$
  select app_private.round_amount(p_amount, (p_params -> 'rounding' ->> 'scale')::integer, p_params -> 'rounding' ->> 'mode')
$$;

-- The classification a category maps to, when it carries a valid key of the given side. A mapping the user set up on
-- the category is a recorded fact; the category NAME is never read (Step 05 §15).
create function app_private.tax_key_for_category(p_entity uuid, p_category uuid, p_side text) returns text
language sql stable as $$
  select c.tax_category_key
  from public.categories c
  join public.tax_treatment_catalog t on t.treatment_key = c.tax_category_key and t.side = p_side
  where c.id = p_category and c.entity_id = p_entity
$$;

-- The withholding rule that covers an object on a date; null when none or more than one does (a configuration
-- ambiguity is a review, never a coin toss).
create function app_private.tax_pph23_rule_for(p_object text, p_date date) returns public.tax_rule_versions
language plpgsql stable as $$
declare
  v_code text;
  v_r public.tax_rule_versions;
  v_hit public.tax_rule_versions;
  v_n integer := 0;
begin
  for v_code in select distinct code from public.tax_rule_versions where family = 'pph23' and status = 'published' loop
    v_r := app_private.tax_rule_at(v_code, p_date);
    if v_r.id is not null and (v_r.params -> 'objects') ? p_object then
      v_n := v_n + 1;
      v_hit := v_r;
    end if;
  end loop;
  if v_n <> 1 then
    return null;
  end if;
  return v_hit;
end
$$;

-- ------------------------------------------------------------ evaluator: output VAT of an invoice
-- Step 05 §11: PKP status is effective-dated; before valid PKP status no output VAT is created merely because a
-- supply is taxable in nature. After it, each line's classification decides; the DPP formula, rate and rounding are
-- read from the rule version in force on the invoice date.
create function app_private.tax_eval_vat_output(p_invoice uuid) returns jsonb
language plpgsql stable as $$
declare
  i public.invoices%rowtype;
  v_base public.currency_code;
  v_prof public.tax_entity_profiles;
  v_rule public.tax_rule_versions;
  v_reasons text[] := '{}';
  v_trace jsonb := '[]'::jsonb;
  v_rules jsonb := '[]'::jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_components jsonb := '[]'::jsonb;
  v_confirmed boolean := false;
  l record;
  v_key text;
  v_src text;
  v_std numeric := 0;
  v_full numeric := 0;
  v_none numeric := 0;
  v_num numeric;
  v_den numeric;
  v_rate numeric;
  v_dpp numeric;
  v_tax_std numeric := 0;
  v_tax_full numeric := 0;
  v_label text;
begin
  select * into i from public.invoices where id = p_invoice;
  v_base := app_private.entity_base_currency(i.entity_id);
  v_prof := app_private.tax_profile_at(i.entity_id, i.issue_date);
  if v_prof.id is null then
    v_reasons := array_append(v_reasons, format('The Entity has no tax profile in force on %s.', i.issue_date));
  elsif v_prof.vat_status = 'unknown' then
    v_reasons := array_append(v_reasons, format('The Entity''s VAT status (PKP or not) is not recorded for %s.', i.issue_date));
  else
    v_trace := app_private.tax_trace_add(v_trace, format('The Entity''s VAT status on %s is %s (profile effective %s).',
      i.issue_date, case v_prof.vat_status when 'pkp' then 'PKP' else 'non-PKP' end, v_prof.effective_from));
  end if;

  for l in select line_no, line_total, vat_treatment, category_id, tax_confirmed_by
           from public.invoice_lines where invoice_id = p_invoice order by line_no loop
    v_key := l.vat_treatment;
    v_src := 'line';
    if v_key is null then
      v_key := app_private.tax_key_for_category(i.entity_id, l.category_id, 'sales_vat');
      v_src := 'category';
    end if;
    if l.tax_confirmed_by is not null then
      v_confirmed := true;
    end if;
    v_lines := v_lines || jsonb_build_object('line_no', l.line_no, 'treatment', v_key, 'source', case when v_key is null then null else v_src end,
                                             'base', app_private.tax_money(l.line_total));
    if v_prof.vat_status = 'pkp' then
      if v_key is null then
        v_reasons := array_append(v_reasons, format('Line %s has no VAT treatment: choose one on the line or map its category.', l.line_no));
      elsif v_key = 'vat_taxable' then
        v_std := v_std + l.line_total;
      elsif v_key = 'vat_taxable_full_dpp' then
        v_full := v_full + l.line_total;
      elsif v_key in ('vat_exempt', 'vat_not_object') then
        v_none := v_none + l.line_total;
      else
        v_reasons := array_append(v_reasons, format('Line %s uses a special VAT treatment (%s) that the engine does not compute; review it.', l.line_no, v_key));
      end if;
    end if;
  end loop;

  if v_prof.vat_status = 'non_pkp' then
    v_trace := app_private.tax_trace_add(v_trace,
      'The Entity is not PKP on this date, so no output VAT is collected even where a supply is taxable in nature (Step 05 §11).');
  elsif v_prof.vat_status = 'pkp' and array_length(v_reasons, 1) is null then
    if v_std + v_full > 0 then
      v_rule := app_private.tax_rule_at('PPN_STANDARD', i.issue_date);
      if v_rule.id is null then
        v_reasons := array_append(v_reasons, format('No VAT rule is in force on %s; the rate is never guessed.', i.issue_date));
      elsif v_base::text <> 'IDR' or i.currency <> v_base then
        v_reasons := array_append(v_reasons,
          'VAT is computed in rupiah on a rupiah invoice; a foreign-currency invoice needs the statutory exchange rate and goes to review.');
      else
        v_rules := v_rules || app_private.tax_rule_ref(v_rule);
        v_rate := (v_rule.params ->> 'rate')::numeric;
        v_num := (v_rule.params ->> 'dpp_numerator')::numeric;
        v_den := (v_rule.params ->> 'dpp_denominator')::numeric;
        if v_std > 0 then
          v_dpp := v_std * v_num / v_den;
          v_tax_std := app_private.tax_round(v_rule.params, v_dpp * v_rate);
          v_label := format('Standard supplies: DPP = %s x %s/%s; VAT = DPP x %s', trim_scale(v_std), v_num, v_den, v_rate);
          v_components := v_components || jsonb_build_object('label', v_label, 'base', app_private.tax_money(v_std),
            'dpp', app_private.tax_money(v_dpp), 'rate', v_rate::text, 'tax', app_private.tax_money(v_tax_std));
          v_trace := app_private.tax_trace_add(v_trace, v_label || format(' = %s (rounded per rule %s v%s).', trim_scale(v_tax_std), v_rule.code, v_rule.rule_version));
        end if;
        if v_full > 0 then
          v_tax_full := app_private.tax_round(v_rule.params, v_full * v_rate);
          v_label := format('Full-DPP supplies: DPP = %s; VAT = DPP x %s', trim_scale(v_full), v_rate);
          v_components := v_components || jsonb_build_object('label', v_label, 'base', app_private.tax_money(v_full),
            'dpp', app_private.tax_money(v_full), 'rate', v_rate::text, 'tax', app_private.tax_money(v_tax_full));
          v_trace := app_private.tax_trace_add(v_trace, v_label || format(' = %s (rounded per rule %s v%s).', trim_scale(v_tax_full), v_rule.code, v_rule.rule_version));
        end if;
      end if;
    end if;
    if v_none > 0 then
      v_trace := app_private.tax_trace_add(v_trace, format('%s of the invoice is exempt or not a VAT object and creates no output VAT.', trim_scale(v_none)));
    end if;
  end if;

  return jsonb_build_object(
    'kind', 'vat_output', 'tax_type', 'vat', 'direction', 'payable',
    'status', case when array_length(v_reasons, 1) is not null then 'needs_review'
                   when v_confirmed then 'owner_confirmed' else 'auto_determined' end,
    'reasons', to_jsonb(v_reasons),
    'base', app_private.tax_money(v_std + v_full), 'tax', app_private.tax_money(v_tax_std + v_tax_full),
    'rate', case when v_rate is null then null else v_rate::text end,
    'components', v_components, 'rules', v_rules, 'trace', v_trace,
    'facts', jsonb_build_object('profile_id', v_prof.id, 'profile_effective_from', v_prof.effective_from,
                                'vat_status', v_prof.vat_status, 'currency', i.currency, 'lines', v_lines),
    'consequence', case when v_tax_std + v_tax_full > 0
      then format('Output VAT of %s is added to the invoice total and credited to Tax Payables; it accrues in the VAT ledger for %s.',
                  trim_scale(v_tax_std + v_tax_full), to_char(app_private.tax_period_start(i.issue_date), 'YYYY-MM'))
      else 'No output VAT: the invoice total is unchanged and no tax liability is created.' end);
end
$$;

-- ------------------------------------------------------------ evaluator: input VAT of a bill or expense
-- The vendor's tax invoice is the fact; the engine decides whether it is creditable (Step 05 §11: creditability is
-- determined separately, from status, evidence and restrictions). A non-creditable amount is part of the cost.
create function app_private.tax_eval_vat_input(p_entity uuid, p_date date, p_currency public.currency_code, p_lines jsonb)
returns jsonb
language plpgsql stable as $$
declare
  v_base public.currency_code := app_private.entity_base_currency(p_entity);
  v_prof public.tax_entity_profiles;
  v_rule public.tax_rule_versions;
  v_reasons text[] := '{}';
  v_trace jsonb := '[]'::jsonb;
  v_rules jsonb := '[]'::jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_components jsonb := '[]'::jsonb;
  v_confirmed boolean := false;
  l jsonb;
  v_stated numeric := 0;
  v_credit numeric := 0;
  v_cost numeric := 0;
  v_vbase numeric := 0;
  v_tax numeric;
  v_no integer;
  v_expected numeric;
begin
  for l in select value from jsonb_array_elements(p_lines) loop
    v_tax := (l ->> 'tax_amount')::numeric;
    if v_tax > 0 then
      v_stated := v_stated + v_tax;
      v_vbase := v_vbase + (l ->> 'subtotal')::numeric;
    end if;
  end loop;
  if v_stated = 0 then
    return null;
  end if;

  v_prof := app_private.tax_profile_at(p_entity, p_date);
  if v_prof.id is null then
    v_reasons := array_append(v_reasons, format('The Entity has no tax profile in force on %s.', p_date));
  elsif v_prof.vat_status = 'unknown' then
    v_reasons := array_append(v_reasons, format('The Entity''s VAT status (PKP or not) is not recorded for %s.', p_date));
  end if;
  if p_currency <> v_base or v_base::text <> 'IDR' then
    v_reasons := array_append(v_reasons, 'Input VAT on a foreign-currency document needs the statutory exchange rate and goes to review.');
  end if;
  v_rule := app_private.tax_rule_at('PPN_STANDARD', p_date);
  if v_rule.id is null then
    v_reasons := array_append(v_reasons, format('No VAT rule is in force on %s.', p_date));
  else
    v_rules := v_rules || app_private.tax_rule_ref(v_rule);
  end if;

  if array_length(v_reasons, 1) is null then
    for l in select value from jsonb_array_elements(p_lines) loop
      v_tax := (l ->> 'tax_amount')::numeric;
      v_no := (l ->> 'line_no')::integer;
      if coalesce((l ->> 'confirmed')::boolean, false) then
        v_confirmed := true;
      end if;
      if v_tax = 0 then
        continue;
      end if;
      v_lines := v_lines || jsonb_build_object('line_no', v_no, 'vat', app_private.tax_money(v_tax),
        'invoice_ref', l ->> 'vat_invoice_ref', 'not_creditable', coalesce((l ->> 'vat_not_creditable')::boolean, false));
      if v_prof.vat_status = 'non_pkp' then
        v_cost := v_cost + v_tax;
      elsif coalesce((l ->> 'vat_not_creditable')::boolean, false) then
        v_cost := v_cost + v_tax;
      elsif nullif(l ->> 'vat_invoice_ref', '') is null then
        v_reasons := array_append(v_reasons,
          format('Line %s carries VAT but no tax-invoice reference: enter the vendor''s tax-invoice number, or mark the line not creditable.', v_no));
      else
        v_credit := v_credit + v_tax;
      end if;
    end loop;

    if array_length(v_reasons, 1) is null then
      if v_prof.vat_status = 'non_pkp' then
        v_trace := app_private.tax_trace_add(v_trace,
          'The Entity is not PKP on this date, so input VAT cannot be credited; the whole amount is part of the cost.');
      end if;
      v_expected := app_private.tax_round(v_rule.params,
        v_vbase * (v_rule.params ->> 'dpp_numerator')::numeric / (v_rule.params ->> 'dpp_denominator')::numeric
        * (v_rule.params ->> 'rate')::numeric);
      v_trace := app_private.tax_trace_add(v_trace, format(
        'The vendor charged %s VAT on a base of %s; the standard formula of rule %s v%s would give %s (for information only: the charged amount is the fact).',
        trim_scale(v_stated), trim_scale(v_vbase), v_rule.code, v_rule.rule_version, trim_scale(v_expected)));
      if v_credit > 0 then
        v_trace := app_private.tax_trace_add(v_trace, format(
          '%s is creditable: the Entity is PKP, a tax-invoice reference is recorded and no restriction is asserted.', trim_scale(v_credit)));
        v_components := v_components || jsonb_build_object('label', 'Creditable input VAT', 'tax', app_private.tax_money(v_credit));
      end if;
      if v_cost > 0 then
        v_trace := app_private.tax_trace_add(v_trace, format(
          '%s is not creditable and is added to the cost of the purchase.', trim_scale(v_cost)));
        v_components := v_components || jsonb_build_object('label', 'Not creditable (part of the cost)', 'tax', app_private.tax_money(v_cost));
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'kind', 'vat_input', 'tax_type', 'vat', 'direction', 'asset',
    'status', case when array_length(v_reasons, 1) is not null then 'needs_review'
                   when v_confirmed then 'owner_confirmed' else 'auto_determined' end,
    'reasons', to_jsonb(v_reasons),
    'base', app_private.tax_money(v_vbase), 'tax', app_private.tax_money(v_credit),
    'not_creditable', app_private.tax_money(v_cost), 'stated', app_private.tax_money(v_stated),
    'rate', null, 'components', v_components, 'rules', v_rules, 'trace', v_trace,
    'facts', jsonb_build_object('profile_id', v_prof.id, 'profile_effective_from', v_prof.effective_from,
                                'vat_status', v_prof.vat_status, 'currency', p_currency, 'lines', v_lines),
    'consequence', case when v_credit > 0
      then format('%s is debited to Tax Assets as creditable input VAT and accrues in the VAT ledger for %s%s.',
                  trim_scale(v_credit), to_char(app_private.tax_period_start(p_date), 'YYYY-MM'),
                  case when v_cost > 0 then format('; %s stays in the cost', trim_scale(v_cost)) else '' end)
      else 'No creditable input VAT: the VAT charged is part of the cost.' end);
end
$$;

-- ------------------------------------------------------------ evaluator: income-tax withholding (PPh 23)
-- Step 05 §10: withholding is determined from the legal OBJECT and the COUNTERPARTY, never from the expense
-- category. The withholding is separated from the vendor's net settlement and from the gross expense.
create function app_private.tax_eval_wht(
  p_entity uuid, p_date date, p_currency public.currency_code, p_party uuid, p_lines jsonb)
returns jsonb
language plpgsql stable as $$
declare
  v_base public.currency_code := app_private.entity_base_currency(p_entity);
  v_prof public.tax_entity_profiles;
  v_facts public.tax_contact_facts;
  v_rule public.tax_rule_versions;
  v_reasons text[] := '{}';
  v_trace jsonb := '[]'::jsonb;
  v_rules jsonb := '[]'::jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_taxable jsonb := '[]'::jsonb;
  v_components jsonb := '[]'::jsonb;
  v_confirmed boolean := false;
  v_needs_party boolean := false;
  v_exempt_base numeric := 0;
  v_none_base numeric := 0;
  v_base_total numeric := 0;
  v_tax_total numeric := 0;
  v_mult numeric := 1;
  v_rate numeric;
  v_tax numeric;
  v_key text;
  v_src text;
  v_no integer;
  v_sub numeric;
  l jsonb;
  g record;
  v_rules_seen text[] := '{}';
begin
  v_prof := app_private.tax_profile_at(p_entity, p_date);
  if v_prof.id is null then
    v_reasons := array_append(v_reasons, format('The Entity has no tax profile in force on %s.', p_date));
  else
    v_trace := app_private.tax_trace_add(v_trace, format('Withholding role of the Entity on %s: %s (profile effective %s).',
      p_date, case v_prof.withholding_agent when 'yes' then 'withholding agent' when 'no' then 'not a withholding agent' else 'not recorded' end,
      v_prof.effective_from));
  end if;

  -- Resolve each line's withholding object: the line's own fact first, then the category mapping the user set up.
  for l in select value from jsonb_array_elements(p_lines) loop
    v_no := (l ->> 'line_no')::integer;
    v_sub := (l ->> 'subtotal')::numeric;
    v_key := nullif(l ->> 'wht_object', '');
    v_src := 'line';
    if v_key is null and nullif(l ->> 'category_id', '') is not null then
      v_key := app_private.tax_key_for_category(p_entity, (l ->> 'category_id')::uuid, 'purchase_wht');
      v_src := 'category';
    end if;
    if coalesce((l ->> 'confirmed')::boolean, false) then
      v_confirmed := true;
    end if;
    v_lines := v_lines || jsonb_build_object('line_no', v_no, 'object', v_key, 'source', case when v_key is null then null else v_src end,
                                             'base', app_private.tax_money(v_sub));
    if v_key = 'wht_none' then
      v_none_base := v_none_base + v_sub;
    elsif v_key is null then
      if v_prof.withholding_agent = 'no' then
        v_none_base := v_none_base + v_sub;
      else
        v_reasons := array_append(v_reasons, format(
          'Line %s has no withholding classification: choose "not a withholding object" or the object on the line, or map its category.', v_no));
      end if;
    elsif v_key = 'wht_review' then
      v_reasons := array_append(v_reasons, format('Line %s is marked "not sure" and waits for a tax review.', v_no));
    else
      v_taxable := v_taxable || jsonb_build_object('line_no', v_no, 'object', v_key, 'base', v_sub);
      v_needs_party := true;
    end if;
  end loop;

  if v_prof.id is not null and jsonb_array_length(v_taxable) > 0 then
    if v_prof.withholding_agent = 'unknown' then
      v_reasons := array_append(v_reasons, 'The Entity''s withholding role (whether it must withhold) is not recorded.');
    elsif v_prof.withholding_agent = 'no' then
      v_reasons := array_append(v_reasons,
        'A line carries a withholding object but the Entity is recorded as not being a withholding agent; review the profile or the line.');
    end if;
  end if;

  if v_needs_party and array_length(v_reasons, 1) is null then
    if p_currency <> v_base or v_base::text <> 'IDR' then
      v_reasons := array_append(v_reasons, 'Withholding on a foreign-currency document needs the statutory exchange rate and goes to review.');
    end if;
    if p_party is null then
      v_reasons := array_append(v_reasons, 'The payee is not a contact of the Entity, so its tax facts are unknown; register the payee and record its tax facts.');
    else
      v_facts := app_private.tax_contact_facts_at(p_entity, p_party, p_date);
      if v_facts.id is null then
        v_reasons := array_append(v_reasons, format('No tax facts are recorded for the payee on %s.', p_date));
      elsif v_facts.residency <> 'resident' then
        v_reasons := array_append(v_reasons, 'The payee is not recorded as a resident taxpayer; non-resident withholding (PPh 26 / treaties) is not computed and needs review.');
      elsif v_facts.tax_id_status = 'unknown' or v_facts.party_kind = 'unknown' or v_facts.wht_exemption = 'unknown' then
        v_reasons := array_append(v_reasons, 'The payee''s kind, tax-number status or withholding exemption is not recorded.');
      end if;
    end if;
  end if;

  if v_needs_party and array_length(v_reasons, 1) is null then
    v_trace := app_private.tax_trace_add(v_trace, format('Payee facts on %s: %s, resident, %s, exemption certificate %s.', p_date,
      v_facts.party_kind, case v_facts.tax_id_status when 'has_npwp' then 'has a tax number' else 'no tax number' end,
      case v_facts.wht_exemption when 'certificate' then 'on file' else 'none' end));
    for l in select value from jsonb_array_elements(v_taxable) loop
      v_rule := app_private.tax_pph23_rule_for(l ->> 'object', p_date);
      if v_rule.id is null then
        v_reasons := array_append(v_reasons, format('No single withholding rule covers line %s (%s) on %s.', l ->> 'line_no', l ->> 'object', p_date));
      elsif v_facts.party_kind = 'individual' and (v_rule.params -> 'individual_review_objects') ? (l ->> 'object') then
        v_reasons := array_append(v_reasons, format(
          'Line %s (%s) is paid to an individual; whether income-tax article 23 or 21 applies is a legal classification that needs review.',
          l ->> 'line_no', l ->> 'object'));
      end if;
    end loop;
  end if;

  if v_needs_party and array_length(v_reasons, 1) is null then
    if v_facts.wht_exemption = 'certificate' then
      for l in select value from jsonb_array_elements(v_taxable) loop
        v_exempt_base := v_exempt_base + (l ->> 'base')::numeric;
      end loop;
      v_trace := app_private.tax_trace_add(v_trace, format(
        'The payee holds a withholding exemption certificate, so nothing is withheld on %s (the certificate is evidence to keep).', trim_scale(v_exempt_base)));
    else
      v_mult := 1;
      for g in
        select t.rule_code, sum(t.base) as base
        from (select (app_private.tax_pph23_rule_for(x ->> 'object', p_date)).code as rule_code, (x ->> 'base')::numeric as base
              from jsonb_array_elements(v_taxable) x) t
        group by t.rule_code order by t.rule_code
      loop
        v_rule := app_private.tax_rule_at(g.rule_code, p_date);
        v_rules := v_rules || app_private.tax_rule_ref(v_rule);
        v_rate := (v_rule.params ->> 'rate')::numeric;
        v_mult := case when v_facts.tax_id_status = 'no_npwp' then (v_rule.params ->> 'non_npwp_multiplier')::numeric else 1 end;
        v_tax := app_private.tax_round(v_rule.params, g.base * v_rate * v_mult);
        v_base_total := v_base_total + g.base;
        v_tax_total := v_tax_total + v_tax;
        v_components := v_components || jsonb_build_object(
          'label', format('%s v%s: %s of the gross amount%s', v_rule.code, v_rule.rule_version, trim_scale(v_rate * v_mult * 100) || '%',
                          case when v_mult > 1 then ' (payee has no tax number: rate x ' || trim_scale(v_mult) || ')' else '' end),
          'base', app_private.tax_money(g.base), 'rate', trim_scale(v_rate * v_mult)::text, 'tax', app_private.tax_money(v_tax));
        v_trace := app_private.tax_trace_add(v_trace, format('Withholding on %s at %s = %s (rule %s v%s, rounded).',
          trim_scale(g.base), trim_scale(v_rate * v_mult), trim_scale(v_tax), v_rule.code, v_rule.rule_version));
      end loop;
    end if;
  elsif not v_needs_party and array_length(v_reasons, 1) is null then
    v_trace := app_private.tax_trace_add(v_trace, format(
      'No line is a withholding object (%s); nothing is withheld.',
      case when v_prof.withholding_agent = 'no' then 'the Entity is not a withholding agent' else 'every line is classified as not a withholding object' end));
  end if;

  return jsonb_build_object(
    'kind', 'wht_pph23', 'tax_type', 'wht_pph23', 'direction', 'payable',
    'status', case when array_length(v_reasons, 1) is not null then 'needs_review'
                   when v_confirmed then 'owner_confirmed' else 'auto_determined' end,
    'reasons', to_jsonb(v_reasons),
    'base', app_private.tax_money(v_base_total + v_exempt_base), 'tax', app_private.tax_money(v_tax_total),
    'rate', null, 'components', v_components, 'rules', v_rules, 'trace', v_trace,
    'facts', jsonb_build_object('profile_id', v_prof.id, 'profile_effective_from', v_prof.effective_from,
                                'withholding_agent', v_prof.withholding_agent, 'party_id', p_party,
                                'party_facts_id', v_facts.id, 'currency', p_currency, 'lines', v_lines),
    'consequence', case when v_tax_total > 0
      then format('%s is withheld from the payee: the vendor is owed that much less, and it is credited to Tax Payables and accrues in the PPh 23 ledger for %s. The gross expense is unchanged.',
                  trim_scale(v_tax_total), to_char(app_private.tax_period_start(p_date), 'YYYY-MM'))
      else 'Nothing is withheld: the vendor is owed the full amount.' end);
end
$$;

-- ------------------------------------------------------------ document evaluation
create function app_private.tax_purchase_lines(p_source_type text, p_id uuid) returns jsonb
language plpgsql stable as $$
begin
  if p_source_type = 'bill' then
    return coalesce((select jsonb_agg(jsonb_build_object(
        'line_no', l.line_no, 'subtotal', l.line_subtotal::text, 'tax_amount', l.tax_amount::text,
        'wht_object', l.wht_object, 'vat_invoice_ref', l.vat_invoice_ref, 'vat_not_creditable', l.vat_not_creditable,
        'category_id', l.category_id, 'confirmed', l.tax_confirmed_by is not null) order by l.line_no)
      from public.bill_lines l where l.bill_id = p_id), '[]'::jsonb);
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'line_no', l.line_no, 'subtotal', l.line_subtotal::text, 'tax_amount', l.tax_amount::text,
      'wht_object', l.wht_object, 'vat_invoice_ref', l.vat_invoice_ref, 'vat_not_creditable', l.vat_not_creditable,
      'category_id', l.category_id, 'confirmed', l.tax_confirmed_by is not null) order by l.line_no)
    from public.expense_lines l where l.expense_id = p_id), '[]'::jsonb);
end
$$;

create function app_private.tax_source_entity(p_source_type text, p_source_id uuid) returns uuid
language sql stable as $$
  select case p_source_type
    when 'invoice' then (select i.entity_id from public.invoices i where i.id = p_source_id)
    when 'bill' then (select b.entity_id from public.bills b where b.id = p_source_id)
    when 'expense' then (select x.entity_id from public.expenses x where x.id = p_source_id)
  end
$$;

-- Evaluates a document (draft, submitted or already recognised) and returns the complete, explainable result.
-- Active overrides are applied unless the caller asks for the raw computation.
create function app_private.tax_evaluate(p_source_type text, p_source_id uuid, p_ignore_overrides boolean default false)
returns jsonb
language plpgsql stable as $$
declare
  v_entity uuid;
  v_date date;
  v_currency public.currency_code;
  v_party uuid;
  v_engine date;
  v_results jsonb := '[]'::jsonb;
  v_out jsonb := '[]'::jsonb;
  v_r jsonb;
  v_lines jsonb;
  v_vin jsonb;
  ov public.tax_overrides;
  v_reasons jsonb := '[]'::jsonb;
  v_status text;
begin
  if p_source_type = 'invoice' then
    select i.entity_id, i.issue_date, i.currency, i.customer_id into v_entity, v_date, v_currency, v_party
    from public.invoices i where i.id = p_source_id;
  elsif p_source_type = 'bill' then
    select b.entity_id, b.bill_date, b.currency, b.vendor_id into v_entity, v_date, v_currency, v_party
    from public.bills b where b.id = p_source_id;
  elsif p_source_type = 'expense' then
    select x.entity_id, x.expense_date, x.currency, x.payee_id into v_entity, v_date, v_currency, v_party
    from public.expenses x where x.id = p_source_id;
  else
    raise exception 'INVALID: unknown document type' using errcode = 'invalid_parameter_value';
  end if;
  if v_entity is null then
    raise exception 'INVALID: unknown document' using errcode = 'invalid_parameter_value';
  end if;

  v_engine := app_private.tax_engine_from(v_entity);
  if v_engine is null or v_date < v_engine then
    return jsonb_build_object('source_type', p_source_type, 'source_id', p_source_id, 'entity_id', v_entity,
      'event_date', v_date, 'tax_period', app_private.tax_period_start(v_date), 'engine', 'inactive',
      'engine_active_from', v_engine, 'status', 'not_configured', 'reasons', '[]'::jsonb, 'results', '[]'::jsonb,
      'vat_output_total', '0', 'withheld_total', '0', 'vat_input_creditable', '0', 'vat_input_cost', '0');
  end if;

  if p_source_type = 'invoice' then
    v_results := jsonb_build_array(app_private.tax_eval_vat_output(p_source_id));
  else
    v_lines := app_private.tax_purchase_lines(p_source_type, p_source_id);
    v_vin := app_private.tax_eval_vat_input(v_entity, v_date, v_currency, v_lines);
    if v_vin is not null then
      v_results := v_results || v_vin;
    end if;
    v_results := v_results || app_private.tax_eval_wht(v_entity, v_date, v_currency, v_party, v_lines);
  end if;

  for v_r in select value from jsonb_array_elements(v_results) loop
    ov := null;
    if not p_ignore_overrides then
      select * into ov from public.tax_overrides o
      where o.entity_id = v_entity and o.source_type = p_source_type and o.source_id = p_source_id
        and o.tax_kind = v_r ->> 'kind' and o.status = 'active';
    end if;
    if ov.id is not null then
      v_r := v_r || jsonb_build_object(
        'computed_tax', case when v_r ->> 'status' = 'needs_review' then null else v_r -> 'tax' end,
        'tax', app_private.tax_money(ov.amount),
        'status', 'overridden', 'reasons', '[]'::jsonb,
        'override', jsonb_build_object('id', ov.id, 'amount', app_private.tax_money(ov.amount), 'reason', ov.reason,
                                       'evidence_note', ov.evidence_note, 'by', ov.created_by, 'at', ov.created_at),
        'trace', app_private.tax_trace_add(v_r -> 'trace', format(
          'Overridden by an authorised user to %s%s. Reason: %s', trim_scale(ov.amount),
          case when v_r ->> 'status' = 'needs_review' then ' (the engine had asked for review)'
               else format(' (the engine computed %s)', v_r ->> 'tax') end, ov.reason)));
      if v_r ->> 'kind' = 'vat_input' then
        v_r := v_r || jsonb_build_object('not_creditable', app_private.tax_money((v_r ->> 'stated')::numeric - ov.amount));
      end if;
    end if;
    v_out := v_out || v_r;
    if v_r ->> 'status' = 'needs_review' then
      v_reasons := v_reasons || (v_r -> 'reasons');
    end if;
  end loop;

  v_status := case
    when exists (select 1 from jsonb_array_elements(v_out) x where x ->> 'status' = 'needs_review') then 'needs_review'
    when exists (select 1 from jsonb_array_elements(v_out) x where x ->> 'status' = 'overridden') then 'overridden'
    when exists (select 1 from jsonb_array_elements(v_out) x where x ->> 'status' = 'owner_confirmed') then 'owner_confirmed'
    else 'auto_determined' end;

  return jsonb_build_object(
    'source_type', p_source_type, 'source_id', p_source_id, 'entity_id', v_entity, 'event_date', v_date,
    'tax_period', app_private.tax_period_start(v_date), 'currency', v_currency, 'engine', 'active',
    'engine_active_from', v_engine, 'status', v_status, 'reasons', v_reasons, 'results', v_out,
    'vat_output_total', coalesce((select x ->> 'tax' from jsonb_array_elements(v_out) x where x ->> 'kind' = 'vat_output'), '0'),
    'withheld_total', coalesce((select x ->> 'tax' from jsonb_array_elements(v_out) x where x ->> 'kind' = 'wht_pph23'), '0'),
    'vat_input_creditable', coalesce((select x ->> 'tax' from jsonb_array_elements(v_out) x where x ->> 'kind' = 'vat_input'), '0'),
    'vat_input_cost', coalesce((select x ->> 'not_creditable' from jsonb_array_elements(v_out) x where x ->> 'kind' = 'vat_input'), '0'));
end
$$;

create function app_private.tax_can_view_source(p_entity uuid, p_source_type text) returns boolean
language sql stable as $$
  select app_authz.has_permission(p_entity, 'tax.view')
      or app_authz.has_permission(p_entity, case p_source_type when 'invoice' then 'invoices.view' else 'bills.view' end)
$$;

-- What the engine would decide for a document right now (a preview for drafts, the answer for recognised ones).
create function public.tax_preview_document(p_source_type text, p_source_id uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_source_type not in ('invoice', 'bill', 'expense') then
    raise exception 'INVALID: unknown document type' using errcode = 'invalid_parameter_value';
  end if;
  v_entity := app_private.tax_source_entity(p_source_type, p_source_id);
  if v_entity is null or not app_private.tax_can_view_source(v_entity, p_source_type) then
    raise exception 'FORBIDDEN: not allowed to see this document''s tax' using errcode = 'insufficient_privilege';
  end if;
  return app_private.tax_evaluate(p_source_type, p_source_id);
end
$$;

-- ------------------------------------------------------------ recording a determination with the posted document
-- Called by the document commands after the accounting consequence is booked. A document that still needs review
-- never gets here: its command refuses first (Step 05 §1).
create function app_private.tax_record_results(
  p_source_type text, p_source_id uuid, p_eval jsonb, p_journal uuid, p_description text)
returns void
language plpgsql as $$
declare
  v_entity uuid := (p_eval ->> 'entity_id')::uuid;
  v_date date := (p_eval ->> 'event_date')::date;
  v_period date := (p_eval ->> 'tax_period')::date;
  r jsonb;
  v_id uuid;
  v_tax numeric;
  v_ov uuid;
begin
  if p_eval ->> 'engine' <> 'active' then
    return;
  end if;
  if p_eval ->> 'status' = 'needs_review' then
    raise exception 'CONFLICT: the tax determination needs review; nothing is posted until it is resolved'
      using errcode = 'integrity_constraint_violation';
  end if;
  for r in select value from jsonb_array_elements(p_eval -> 'results') loop
    v_tax := (r ->> 'tax')::numeric;
    v_ov := nullif(r -> 'override' ->> 'id', '')::uuid;
    insert into public.tax_determinations
      (entity_id, tax_kind, tax_type, source_type, source_id, event_date, tax_period, status, currency, base_amount,
       rate, tax_amount, direction, rules, facts, trace, components, consequence, computed_tax_amount, override_id,
       journal_id, confirmed)
    values
      (v_entity, r ->> 'kind', r ->> 'tax_type', p_source_type, p_source_id, v_date, v_period, r ->> 'status',
       (p_eval ->> 'currency')::public.currency_code, (r ->> 'base')::numeric, nullif(r ->> 'rate', '')::numeric, v_tax,
       r ->> 'direction', r -> 'rules', r -> 'facts', r -> 'trace', r -> 'components', r ->> 'consequence',
       nullif(r ->> 'computed_tax', '')::numeric, v_ov, p_journal, r ->> 'status' = 'owner_confirmed')
    returning id into v_id;
    if v_ov is not null then
      update public.tax_overrides set determination_id = v_id where id = v_ov and entity_id = v_entity;
    end if;
    if v_tax > 0 then
      insert into public.tax_ledger_entries
        (entity_id, determination_id, tax_kind, tax_type, tax_period, direction, entry_kind, amount, entry_date,
         journal_id, description)
      values (v_entity, v_id, r ->> 'kind', r ->> 'tax_type', v_period, r ->> 'direction', 'accrual', v_tax, v_date,
              p_journal, left(p_description, 300));
    end if;
  end loop;
end
$$;

-- The document was voided, cancelled or reversed: its determinations become history (SUPERSEDED) and each ledger
-- consequence is reversed in the period of the reversal. Nothing is deleted or edited (Step 05 §12, §15).
create function app_private.tax_reverse_source(
  p_source_type text, p_source_id uuid, p_reversal_journal uuid, p_date date, p_reason text)
returns void
language plpgsql as $$
declare
  d public.tax_determinations%rowtype;
begin
  for d in select * from public.tax_determinations
           where source_type = p_source_type and source_id = p_source_id and superseded_at is null
           order by created_at, id
           for update loop
    update public.tax_determinations
    set status = 'superseded', superseded_at = now(), superseded_reason = left(p_reason, 500)
    where id = d.id;
    if d.tax_amount > 0 then
      insert into public.tax_ledger_entries
        (entity_id, determination_id, tax_kind, tax_type, tax_period, direction, entry_kind, amount, entry_date,
         journal_id, description)
      values (d.entity_id, d.id, d.tax_kind, d.tax_type, app_private.tax_period_start(p_date), d.direction, 'reversal',
              -d.tax_amount, p_date, p_reversal_journal, left('Reversal: ' || coalesce(p_reason, ''), 300));
    end if;
  end loop;
end
$$;

-- ------------------------------------------------------------ overrides (Step 05 §15, Step 06 §8)
create function public.tax_override_set(
  p_source_type text, p_source_id uuid, p_key text, p_kind text, p_amount text, p_reason text, p_evidence_note text,
  p_evidence_document uuid default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
  v_status text;
  v_amount numeric;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_note text := btrim(coalesce(p_evidence_note, ''));
  v_replay uuid;
  v_eval jsonb;
  v_res jsonb;
  v_max numeric;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_source_type not in ('invoice', 'bill', 'expense') or p_kind not in ('vat_output', 'vat_input', 'wht_pph23') then
    raise exception 'INVALID: unknown document type or tax kind' using errcode = 'invalid_parameter_value';
  end if;
  v_entity := app_private.tax_source_entity(p_source_type, p_source_id);
  if v_entity is null or not app_authz.has_permission(v_entity, 'tax.override') then
    raise exception 'FORBIDDEN: a tax override needs tax.override' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED: confirm your identity again to override a tax result' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 10 and 1000 or length(v_note) not between 5 and 1000 then
    raise exception 'INVALID: an override needs a reason (10-1000 characters) and an evidence note (5-1000 characters)'
      using errcode = 'invalid_parameter_value';
  end if;
  v_amount := app_private.parse_amount(p_amount, 'the override amount');
  if v_amount < 0 then
    raise exception 'INVALID: the override amount cannot be negative' using errcode = 'invalid_parameter_value';
  end if;
  v_replay := app_private.idem_begin('tax.override_set', v_entity, p_key,
    md5(jsonb_build_object('t', p_source_type, 's', p_source_id, 'k', p_kind, 'a', v_amount, 'r', v_reason,
                           'e', v_note, 'd', p_evidence_document)::text));
  if v_replay is not null then
    return v_replay;
  end if;

  v_status := case p_source_type
    when 'invoice' then (select i.status from public.invoices i where i.id = p_source_id)
    when 'bill' then (select b.status from public.bills b where b.id = p_source_id)
    else (select x.status from public.expenses x where x.id = p_source_id) end;
  if v_status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: an override applies before the document is recognised; a recognised document is corrected instead (now %)', v_status
      using errcode = 'integrity_constraint_violation';
  end if;
  v_eval := app_private.tax_evaluate(p_source_type, p_source_id, true);
  if v_eval ->> 'engine' <> 'active' then
    raise exception 'CONFLICT: the tax engine is not active for this document date, so there is nothing to override'
      using errcode = 'integrity_constraint_violation';
  end if;
  select x into v_res from jsonb_array_elements(v_eval -> 'results') x where x ->> 'kind' = p_kind;
  if v_res is null then
    raise exception 'CONFLICT: this document has no % result to override', p_kind using errcode = 'integrity_constraint_violation';
  end if;
  v_max := case p_kind
    when 'vat_input' then (v_res ->> 'stated')::numeric
    when 'vat_output' then (select coalesce(sum(l.line_total), 0) from public.invoice_lines l where l.invoice_id = p_source_id)
    else (select coalesce(sum((l ->> 'subtotal')::numeric), 0) from jsonb_array_elements(app_private.tax_purchase_lines(p_source_type, p_source_id)) l)
  end;
  if v_amount > v_max then
    raise exception 'INVALID: the override cannot exceed %', trim_scale(v_max) using errcode = 'invalid_parameter_value';
  end if;
  if p_evidence_document is not null and not exists (
       select 1 from public.documents d where d.id = p_evidence_document and d.entity_id = v_entity) then
    raise exception 'INVALID: unknown evidence document of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  -- One live override per document and kind: a new decision withdraws the previous one first.
  update public.tax_overrides
  set status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(), withdraw_reason = 'Replaced by a newer override'
  where entity_id = v_entity and source_type = p_source_type and source_id = p_source_id and tax_kind = p_kind
    and status = 'active';
  insert into public.tax_overrides
    (entity_id, source_type, source_id, tax_kind, amount, reason, evidence_note, evidence_document_id)
  values (v_entity, p_source_type, p_source_id, p_kind, v_amount, v_reason, v_note, p_evidence_document)
  returning id into v_id;
  perform app_private.idem_complete('tax.override_set', v_entity, p_key, 'tax_overrides', v_id);
  return v_id;
end
$$;

create function public.tax_override_withdraw(p_override uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  o public.tax_overrides%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into o from public.tax_overrides where id = p_override for update;
  if not found or not app_authz.has_permission(o.entity_id, 'tax.override') then
    raise exception 'FORBIDDEN: withdrawing a tax override needs tax.override' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED: confirm your identity again' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 500 then
    raise exception 'INVALID: give a reason of 5 to 500 characters' using errcode = 'invalid_parameter_value';
  end if;
  if o.status <> 'active' or o.determination_id is not null then
    raise exception 'CONFLICT: only an override that no posted document has used yet can be withdrawn'
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.tax_overrides
  set status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(), withdraw_reason = v_reason
  where id = o.id;
end
$$;

-- ------------------------------------------------------------ confirmation of a line's classification
-- A tax reviewer settles what the drafter was unsure about (OWNER_CONFIRMED, Step 05 §14). It is a change of a fact
-- of a document that is not recognised yet; the audit trail keeps who and when.
create function public.tax_confirm_line(p_source_type text, p_source_id uuid, p_line_no integer, p_treatment text)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
  v_status text;
  v_side text;
  v_n integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_source_type not in ('invoice', 'bill', 'expense') then
    raise exception 'INVALID: unknown document type' using errcode = 'invalid_parameter_value';
  end if;
  v_entity := app_private.tax_source_entity(p_source_type, p_source_id);
  if v_entity is null or not app_authz.has_permission(v_entity, 'tax.confirm_facts') then
    raise exception 'FORBIDDEN: confirming a tax classification needs tax.confirm_facts' using errcode = 'insufficient_privilege';
  end if;
  v_side := case when p_source_type = 'invoice' then 'sales_vat' else 'purchase_wht' end;
  if p_treatment is null or not exists (
       select 1 from public.tax_treatment_catalog t where t.treatment_key = p_treatment and t.side = v_side)
     or p_treatment = 'wht_review' then
    raise exception 'INVALID: choose a concrete classification of the % family', v_side using errcode = 'invalid_parameter_value';
  end if;
  if p_source_type = 'invoice' then
    perform 1 from public.invoices where id = p_source_id and entity_id = v_entity for update;
    select i.status into v_status from public.invoices i where i.id = p_source_id;
  elsif p_source_type = 'bill' then
    perform 1 from public.bills where id = p_source_id and entity_id = v_entity for update;
    select b.status into v_status from public.bills b where b.id = p_source_id;
  else
    perform 1 from public.expenses where id = p_source_id and entity_id = v_entity for update;
    select x.status into v_status from public.expenses x where x.id = p_source_id;
  end if;
  if v_status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: a recognised document keeps its classification; correct it instead (now %)', v_status
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_source_type = 'invoice' then
    update public.invoice_lines set vat_treatment = p_treatment, tax_confirmed_by = auth.uid(), tax_confirmed_at = now()
    where invoice_id = p_source_id and entity_id = v_entity and line_no = p_line_no;
  elsif p_source_type = 'bill' then
    update public.bill_lines set wht_object = p_treatment, tax_confirmed_by = auth.uid(), tax_confirmed_at = now()
    where bill_id = p_source_id and entity_id = v_entity and line_no = p_line_no;
  else
    update public.expense_lines set wht_object = p_treatment, tax_confirmed_by = auth.uid(), tax_confirmed_at = now()
    where expense_id = p_source_id and entity_id = v_entity and line_no = p_line_no;
  end if;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'INVALID: unknown line %', p_line_no using errcode = 'invalid_parameter_value';
  end if;
end
$$;

-- ------------------------------------------------------------ the review queue
-- Every draft or submitted document of an Entity whose tax would need review today, with the reasons.
create function public.tax_review_queue(p_entity uuid)
returns table (source_type text, source_id uuid, reference text, event_date date, status text, reasons jsonb)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  r record;
  v_eval jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  for r in
    select 'invoice'::text as st, i.id, coalesce(i.invoice_number, 'draft ' || left(i.id::text, 8)) as ref, i.issue_date as d
      from public.invoices i where i.entity_id = p_entity and i.status = 'draft'
    union all
    select 'bill', b.id, coalesce(b.bill_number, nullif(b.vendor_reference, ''), 'draft ' || left(b.id::text, 8)), b.bill_date
      from public.bills b where b.entity_id = p_entity and b.status in ('draft', 'submitted')
    union all
    select 'expense', x.id, coalesce(x.expense_number, nullif(x.receipt_reference, ''), 'draft ' || left(x.id::text, 8)), x.expense_date
      from public.expenses x where x.entity_id = p_entity and x.status in ('draft', 'submitted')
    order by 4, 3
    limit 500
  loop
    v_eval := app_private.tax_evaluate(r.st, r.id);
    if v_eval ->> 'status' = 'needs_review' then
      source_type := r.st; source_id := r.id; reference := r.ref; event_date := r.d;
      status := v_eval ->> 'status'; reasons := v_eval -> 'reasons';
      return next;
    end if;
  end loop;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.tax_overrides');
create policy tax_overrides_select on public.tax_overrides for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));
call app_private.expose_select('public.tax_determinations');
create policy tax_determinations_select on public.tax_determinations for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));
call app_private.expose_select('public.tax_ledger_entries');
create policy tax_ledger_entries_select on public.tax_ledger_entries for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));

revoke all on function app_private.tg_tax_overrides_guard() from public;
revoke all on function app_private.tg_tax_determinations_guard() from public;
revoke all on function app_private.tax_period_start(date) from public;
revoke all on function app_private.tax_money(numeric) from public;
revoke all on function app_private.tax_trace_add(jsonb, text) from public;
revoke all on function app_private.tax_rule_ref(public.tax_rule_versions) from public;
revoke all on function app_private.tax_round(jsonb, numeric) from public;
revoke all on function app_private.tax_key_for_category(uuid, uuid, text) from public;
revoke all on function app_private.tax_pph23_rule_for(text, date) from public;
revoke all on function app_private.tax_eval_vat_output(uuid) from public;
revoke all on function app_private.tax_eval_vat_input(uuid, date, public.currency_code, jsonb) from public;
revoke all on function app_private.tax_eval_wht(uuid, date, public.currency_code, uuid, jsonb) from public;
revoke all on function app_private.tax_purchase_lines(text, uuid) from public;
revoke all on function app_private.tax_source_entity(text, uuid) from public;
revoke all on function app_private.tax_evaluate(text, uuid, boolean) from public;
revoke all on function app_private.tax_can_view_source(uuid, text) from public;
revoke all on function app_private.tax_record_results(text, uuid, jsonb, uuid, text) from public;
revoke all on function app_private.tax_reverse_source(text, uuid, uuid, date, text) from public;

revoke all on function public.tax_preview_document(text, uuid) from public, anon;
revoke all on function public.tax_override_set(text, uuid, text, text, text, text, text, uuid) from public, anon;
revoke all on function public.tax_override_withdraw(uuid, text) from public, anon;
revoke all on function public.tax_confirm_line(text, uuid, integer, text) from public, anon;
revoke all on function public.tax_review_queue(uuid) from public, anon;
grant execute on function public.tax_preview_document(text, uuid) to authenticated;
grant execute on function public.tax_override_set(text, uuid, text, text, text, text, text, uuid) to authenticated;
grant execute on function public.tax_override_withdraw(uuid, text) to authenticated;
grant execute on function public.tax_confirm_line(text, uuid, integer, text) to authenticated;
grant execute on function public.tax_review_queue(uuid) to authenticated;
