-- P9 part 3: PPh 21 joins the tax layer of P7.
-- Authority: Step 05 §9 (payroll tax architecture: payslip values reconcile to the payroll run, the tax ledger, the
-- liabilities and the payment records), Step 08 §19 (tax ledger reconciles to the GL), Step 15 P9 ("payroll
-- tax/liability integration with tax/accounting services").
--
-- Withheld PPh 21 is recorded in the SAME tax determination / ledger / payment / filing / reconciliation machinery as
-- the other taxes, as the tax type 'wht_pph21'. The payroll run is its source ('payroll_run'). What the tax layer holds
-- for a run is the AGGREGATE only - the per-employee detail stays inside the payroll boundary (payroll.tax_view).
-- Everything else of P7 (payment capacity, filing, reconciliation, calendar, control against the General Ledger)
-- therefore works for PPh 21 without a second implementation.

alter table public.tax_determinations drop constraint tax_determinations_tax_kind_check;
alter table public.tax_determinations add constraint tax_determinations_tax_kind_check
  check (tax_kind in ('vat_output', 'vat_input', 'wht_pph23', 'wht_pph21', 'final_umkm'));
alter table public.tax_determinations drop constraint tax_determinations_tax_type_check;
alter table public.tax_determinations add constraint tax_determinations_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph21', 'final_umkm'));
alter table public.tax_determinations drop constraint tax_determinations_source_type_check;
alter table public.tax_determinations add constraint tax_determinations_source_type_check
  check (source_type in ('invoice', 'bill', 'expense', 'period', 'payroll_run'));
alter table public.tax_ledger_entries drop constraint tax_ledger_entries_tax_kind_check;
alter table public.tax_ledger_entries add constraint tax_ledger_entries_tax_kind_check
  check (tax_kind in ('vat_output', 'vat_input', 'wht_pph23', 'wht_pph21', 'final_umkm'));
alter table public.tax_ledger_entries drop constraint tax_ledger_entries_tax_type_check;
alter table public.tax_ledger_entries add constraint tax_ledger_entries_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph21', 'final_umkm'));
alter table public.tax_payments drop constraint tax_payments_tax_type_check;
alter table public.tax_payments add constraint tax_payments_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph21', 'final_umkm'));
alter table public.tax_filings drop constraint tax_filings_tax_type_check;
alter table public.tax_filings add constraint tax_filings_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph21', 'final_umkm'));
alter table public.tax_reconciliations drop constraint tax_reconciliations_tax_type_check;
alter table public.tax_reconciliations add constraint tax_reconciliations_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph21', 'final_umkm'));

create or replace function public.tax_record_payment(
  p_entity uuid, p_key text, p_tax_type text, p_period date, p_date date, p_account uuid, p_payable text,
  p_asset_offset text default '0', p_penalty text default '0', p_reference text default null, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_today date;
  v_scale integer;
  v_payable numeric;
  v_asset numeric;
  v_penalty numeric;
  v_cash numeric;
  a record;
  v_outstanding numeric;
  v_avail numeric;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_label text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.mark_filed') then
    raise exception 'FORBIDDEN: recording a tax payment needs tax.mark_filed' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.payment', p_entity, p_key,
    md5(jsonb_build_object('t', p_tax_type, 'p', p_period, 'd', p_date, 'a', p_account, 'pay', p_payable,
                           'off', p_asset_offset, 'pen', p_penalty, 'r', p_reference, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_today := app_private.entity_today(p_entity);
  v_scale := app_private.currency_scale(e.base_currency);
  if p_tax_type is null or p_tax_type not in ('vat', 'wht_pph23', 'wht_pph21', 'final_umkm') then
    raise exception 'INVALID: the tax type is vat, wht_pph23, wht_pph21 or final_umkm' using errcode = 'invalid_parameter_value';
  end if;
  if p_period is null or p_period <> date_trunc('month', p_period)::date then
    raise exception 'INVALID: the tax period is the first day of a month' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date > v_today then
    raise exception 'INVALID: a payment cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_date < p_period then
    raise exception 'INVALID: a payment cannot be dated before its tax period starts' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(v_ref, '')) > 200 or length(coalesce(v_note, '')) > 1000 then
    raise exception 'INVALID: the reference is limited to 200 and the note to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_payable := app_private.parse_amount(p_payable, 'the tax paid');
  v_asset := app_private.parse_amount(coalesce(nullif(btrim(p_asset_offset), ''), '0'), 'the input VAT offset');
  v_penalty := app_private.parse_amount(coalesce(nullif(btrim(p_penalty), ''), '0'), 'the penalty');
  if v_payable <= 0 or v_asset < 0 or v_penalty < 0
     or app_private.round_amount(v_payable, v_scale, 'down') <> v_payable
     or app_private.round_amount(v_asset, v_scale, 'down') <> v_asset
     or app_private.round_amount(v_penalty, v_scale, 'down') <> v_penalty then
    raise exception 'INVALID: the tax paid must be positive, the offset and penalty not negative, all with at most % decimals', v_scale
      using errcode = 'invalid_parameter_value';
  end if;
  if v_asset > 0 and p_tax_type <> 'vat' then
    raise exception 'INVALID: only VAT can be settled against input VAT' using errcode = 'invalid_parameter_value';
  end if;
  if v_asset > v_payable then
    raise exception 'INVALID: the input VAT offset cannot exceed the VAT paid against; excess input VAT stays as a credit'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_penalty > 0 and length(coalesce(v_note, '')) < 5 then
    raise exception 'INVALID: a penalty needs a note that explains it (for example the assessment number)'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_maker_checker(p_entity, 'tax', 'pay', v_payable + v_penalty - v_asset, auth.uid(), 'record this tax payment');

  v_cash := v_payable - v_asset + v_penalty;
  if v_cash > 0 then
    select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
    if not found or not fa.is_active then
      raise exception 'INVALID: the paying account is unknown or inactive' using errcode = 'invalid_parameter_value';
    end if;
    if fa.currency <> e.base_currency then
      raise exception 'INVALID: tax is paid from an account in the Entity''s base currency (%)', e.base_currency
        using errcode = 'invalid_parameter_value';
    end if;
  elsif p_account is not null then
    raise exception 'INVALID: no account is needed when the whole payment is offset against input VAT'
      using errcode = 'invalid_parameter_value';
  end if;

  -- One writer at a time per tax type and period, so two payments can never settle the same liability twice.
  perform pg_advisory_xact_lock(hashtextextended('tax_payment:' || p_entity::text || ':' || p_tax_type || ':' || p_period::text, 0));
  select * into a from app_private.tax_period_amounts(p_entity, p_tax_type, p_period, v_today);
  v_outstanding := a.accrued_payable - a.paid_payable;
  if v_payable > v_outstanding then
    raise exception 'INVALID: % for % has % outstanding; the payment of % exceeds it', p_tax_type, to_char(p_period, 'YYYY-MM'),
      trim_scale(greatest(v_outstanding, 0)), trim_scale(v_payable) using errcode = 'invalid_parameter_value';
  end if;
  if v_asset > 0 then
    v_avail := app_private.tax_asset_available(p_entity, p_period, v_today);
    if v_asset > v_avail then
      raise exception 'INVALID: only % of input VAT is available to offset', trim_scale(v_avail) using errcode = 'invalid_parameter_value';
    end if;
  end if;

  if v_cash > 0 then
    perform 1 from public.financial_accounts where id = p_account and entity_id = p_entity for no key update;
  end if;
  perform app_private.ensure_tax_numbering(p_entity);
  v_number := app_private.allocate_document_number(p_entity, 'tax_payment', p_date);
  v_label := case p_tax_type when 'vat' then 'VAT' when 'wht_pph23' then 'PPh 23' when 'wht_pph21' then 'PPh 21' else 'PPh Final' end;
  v_desc := format('Tax payment %s - %s %s', v_number, v_label, to_char(p_period, 'YYYY-MM'));

  v_lines := v_lines || jsonb_build_object('account_key', 'TAX_PAYABLE', 'debit', v_payable, 'credit', 0, 'description', v_desc);
  if v_penalty > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'TAX_PENALTY_EXPENSE', 'debit', v_penalty, 'credit', 0,
      'description', 'Penalty: ' || v_desc);
  end if;
  if v_asset > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'TAX_ASSET', 'debit', 0, 'credit', v_asset,
      'description', 'Input VAT offset: ' || v_desc);
  end if;
  if v_cash > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', v_cash, 'description', v_desc);
  end if;
  v_journal := app_private.post_system_journal(p_entity, 'tax_payment', v_id, 'tax_payment.confirm', 'tax_payment.v1', p_date, v_desc, v_lines);
  if v_cash > 0 then
    perform app_private.record_movement(p_entity, p_account, 'out', v_cash, v_cash, null, p_date, 'tax_payment', v_id,
      'principal', v_journal, v_desc);
  end if;
  insert into public.tax_payments
    (id, entity_id, payment_number, tax_type, tax_period, payment_date, currency, payable_applied, asset_applied,
     penalty_amount, cash_amount, financial_account_id, reference, note, journal_id)
  values
    (v_id, p_entity, v_number, p_tax_type, p_period, p_date, e.base_currency, v_payable, v_asset, v_penalty, v_cash,
     case when v_cash > 0 then p_account end, v_ref, v_note, v_journal);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_entity, 'TaxPaymentRecorded', 'tax_payment', v_id,
          jsonb_build_object('payment_number', v_number, 'tax_type', p_tax_type, 'period', to_char(p_period, 'YYYY-MM')));
  perform app_private.idem_complete('tax.payment', p_entity, p_key, 'tax_payments', v_id);
  return v_id;
end
$$;

create or replace function public.tax_record_filing(
  p_entity uuid, p_key text, p_tax_type text, p_period date, p_filed_date date, p_reference text,
  p_reported_base text, p_reported_tax text, p_reported_credit text default '0', p_amendment boolean default false,
  p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_today date;
  v_ref text := btrim(coalesce(p_reference, ''));
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_base numeric;
  v_tax numeric;
  v_credit numeric;
  v_live public.tax_filings%rowtype;
  v_id uuid := gen_random_uuid();
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.mark_filed') then
    raise exception 'FORBIDDEN: recording a filing needs tax.mark_filed' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.filing', p_entity, p_key,
    md5(jsonb_build_object('t', p_tax_type, 'p', p_period, 'd', p_filed_date, 'r', v_ref, 'b', p_reported_base,
                           'x', p_reported_tax, 'c', p_reported_credit, 'a', coalesce(p_amendment, false), 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_today := app_private.entity_today(p_entity);
  if p_tax_type is null or p_tax_type not in ('vat', 'wht_pph23', 'wht_pph21', 'final_umkm') then
    raise exception 'INVALID: the tax type is vat, wht_pph23, wht_pph21 or final_umkm' using errcode = 'invalid_parameter_value';
  end if;
  if p_period is null or p_period <> date_trunc('month', p_period)::date then
    raise exception 'INVALID: the tax period is the first day of a month' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_filed_date);
  if p_filed_date > v_today or p_filed_date < p_period then
    raise exception 'INVALID: the filing date cannot be in the future or before its tax period' using errcode = 'invalid_parameter_value';
  end if;
  if length(v_ref) not between 3 and 200 then
    raise exception 'INVALID: the filing reference (receipt number) is required, 3 to 200 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_base := app_private.parse_amount(coalesce(nullif(btrim(p_reported_base), ''), '0'), 'the reported base');
  v_tax := app_private.parse_amount(coalesce(nullif(btrim(p_reported_tax), ''), '0'), 'the reported tax');
  v_credit := app_private.parse_amount(coalesce(nullif(btrim(p_reported_credit), ''), '0'), 'the reported credit');
  if v_base < 0 or v_tax < 0 or v_credit < 0 or (p_tax_type <> 'vat' and v_credit <> 0) then
    raise exception 'INVALID: reported amounts cannot be negative, and only a VAT return has a credit' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('tax_filing:' || p_entity::text || ':' || p_tax_type || ':' || p_period::text, 0));
  select * into v_live from public.tax_filings
  where entity_id = p_entity and tax_type = p_tax_type and tax_period = p_period and status = 'filed';
  if found and not coalesce(p_amendment, false) then
    raise exception 'CONFLICT: this period is already filed (%); record an amendment to change it', v_live.reference
      using errcode = 'integrity_constraint_violation';
  end if;
  if not found and coalesce(p_amendment, false) then
    raise exception 'INVALID: there is no filing of this period to amend' using errcode = 'invalid_parameter_value';
  end if;
  if v_live.id is not null and length(coalesce(v_note, '')) < 5 then
    raise exception 'INVALID: an amendment needs a note that says what changed' using errcode = 'invalid_parameter_value';
  end if;
  if v_live.id is not null and p_filed_date < v_live.filed_date then
    raise exception 'INVALID: an amendment cannot be dated before the filing it amends' using errcode = 'invalid_parameter_value';
  end if;
  -- The earlier filing steps aside first (one live filing per period), then the new one takes its place.
  if v_live.id is not null then
    update public.tax_filings set status = 'superseded', superseded_at = now(), superseded_by = v_id where id = v_live.id;
  end if;
  insert into public.tax_filings
    (id, entity_id, tax_type, tax_period, filing_kind, revision, filed_date, reference, reported_base, reported_tax,
     reported_credit, note)
  values
    (v_id, p_entity, p_tax_type, p_period, case when v_live.id is not null then 'amendment' else 'original' end,
     case when v_live.id is not null then v_live.revision + 1 else 0 end, p_filed_date, v_ref, v_base, v_tax, v_credit, v_note);
  perform app_private.idem_complete('tax.filing', p_entity, p_key, 'tax_filings', v_id);
  return v_id;
end
$$;

create or replace function public.tax_reconcile_period(
  p_entity uuid, p_key text, p_tax_type text, p_period date, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_today date;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_fig jsonb;
  v_diff jsonb;
  v_id uuid := gen_random_uuid();
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.mark_filed') then
    raise exception 'FORBIDDEN: reconciling a tax period needs tax.mark_filed' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.reconcile', p_entity, p_key,
    md5(jsonb_build_object('t', p_tax_type, 'p', p_period, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_tax_type is null or p_tax_type not in ('vat', 'wht_pph23', 'wht_pph21', 'final_umkm') then
    raise exception 'INVALID: the tax type is vat, wht_pph23, wht_pph21 or final_umkm' using errcode = 'invalid_parameter_value';
  end if;
  if p_period is null or p_period <> date_trunc('month', p_period)::date then
    raise exception 'INVALID: the tax period is the first day of a month' using errcode = 'invalid_parameter_value';
  end if;
  v_today := app_private.entity_today(p_entity);
  if p_period > v_today then
    raise exception 'INVALID: a period that has not started cannot be reconciled' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('tax_reconcile:' || p_entity::text || ':' || p_tax_type || ':' || p_period::text, 0));
  v_fig := app_private.tax_period_figures(p_entity, p_tax_type, p_period, v_today);
  if (v_fig ->> 'accrued_payable')::numeric = 0 and (v_fig ->> 'accrued_asset')::numeric = 0
     and (v_fig ->> 'paid_payable')::numeric = 0 and v_fig ->> 'filing_id' is null then
    raise exception 'INVALID: there is nothing to reconcile for this period' using errcode = 'invalid_parameter_value';
  end if;
  v_diff := app_private.tax_period_differences(p_entity, p_tax_type, p_period, v_today);
  if jsonb_array_length(v_diff) > 0 and length(coalesce(v_note, '')) < 10 then
    raise exception 'INVALID: the period has % difference(s) (first: %); a note of at least 10 characters explains them',
      jsonb_array_length(v_diff), v_diff -> 0 ->> 'text' using errcode = 'invalid_parameter_value';
  end if;
  update public.tax_reconciliations set status = 'superseded', superseded_at = now()
  where entity_id = p_entity and tax_type = p_tax_type and tax_period = p_period and status = 'current';
  insert into public.tax_reconciliations (id, entity_id, tax_type, tax_period, outcome, figures, differences, note, filing_id)
  values (v_id, p_entity, p_tax_type, p_period, case when jsonb_array_length(v_diff) = 0 then 'reconciled' else 'differences_noted' end,
          v_fig, v_diff, v_note, nullif(v_fig ->> 'filing_id', '')::uuid);
  perform app_private.idem_complete('tax.reconcile', p_entity, p_key, 'tax_reconciliations', v_id);
  return v_id;
end
$$;

create or replace function public.tax_period_position(p_entity uuid, p_tax_type text, p_period date, p_as_of date default null)
returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_asof date;
  v_fig jsonb;
  v_rec public.tax_reconciliations%rowtype;
  v_evidence bigint;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  if p_tax_type is null or p_tax_type not in ('vat', 'wht_pph23', 'wht_pph21', 'final_umkm')
     or p_period is null or p_period <> date_trunc('month', p_period)::date then
    raise exception 'INVALID: a tax type and the first day of a month are required' using errcode = 'invalid_parameter_value';
  end if;
  v_asof := coalesce(p_as_of, app_private.entity_today(p_entity));
  v_fig := app_private.tax_period_figures(p_entity, p_tax_type, p_period, v_asof);
  select * into v_rec from public.tax_reconciliations
  where entity_id = p_entity and tax_type = p_tax_type and tax_period = p_period and status = 'current';
  select count(*) into v_evidence from public.document_links l
  where l.entity_id = p_entity and l.status = 'active'
    and ((l.target_type = 'tax_filing' and l.target_id = nullif(v_fig ->> 'filing_id', '')::uuid)
         or (l.target_type = 'tax_payment' and l.target_id in (
              select p.id from public.tax_payments p
              where p.entity_id = p_entity and p.tax_type = p_tax_type and p.tax_period = p_period and p.status = 'confirmed')));
  return v_fig || jsonb_build_object(
    'tax_type', p_tax_type, 'tax_period', p_period, 'as_of', v_asof,
    'asset_available', case when p_tax_type = 'vat' then app_private.tax_asset_available(p_entity, p_period, v_asof)::text end,
    'evidence_count', v_evidence,
    'differences', app_private.tax_period_differences(p_entity, p_tax_type, p_period, v_asof),
    'reconciliation', case when v_rec.id is null then null else jsonb_build_object(
        'id', v_rec.id, 'outcome', v_rec.outcome, 'note', v_rec.note, 'at', v_rec.created_at,
        -- Stale: what was compared no longer equals what the books hold now.
        'stale', (v_rec.figures - 'outstanding_payable') is distinct from (v_fig - 'outstanding_payable')) end);
end
$$;

create or replace function public.tax_calendar(p_entity uuid, p_from date default null, p_to date default null)
returns table (tax_type text, tax_period date, step text, due_date date, state text, outstanding text, rule_code text,
               rule_version integer, detail text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_today date;
  v_from date;
  v_to date;
  v_m date;
  t text;
  v_code text;
  r public.tax_rule_versions%rowtype;
  v_eng date;
  v_end date;
  v_relevant boolean;
  v_pay date;
  v_file date;
  a record;
  f public.tax_filings%rowtype;
  p public.tax_entity_profiles%rowtype;
  v_calc boolean;
  v_out numeric;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  v_today := app_private.entity_today(p_entity);
  v_eng := app_private.tax_engine_from(p_entity);
  v_from := date_trunc('month', coalesce(p_from, (v_today - interval '3 months')::date))::date;
  v_to := date_trunc('month', coalesce(p_to, v_today))::date;
  if v_to < v_from or v_to > v_from + interval '36 months' then
    raise exception 'INVALID: the calendar covers at most 36 months' using errcode = 'invalid_parameter_value';
  end if;
  v_m := v_from;
  while v_m <= v_to loop
    v_end := (v_m + interval '1 month' - interval '1 day')::date;
    foreach t in array array['vat', 'wht_pph23', 'wht_pph21', 'final_umkm'] loop
      v_code := case t when 'vat' then 'DEADLINE_PPN' when 'wht_pph23' then 'DEADLINE_PPH23' when 'wht_pph21' then 'DEADLINE_PPH21' else 'DEADLINE_PPH_FINAL_UMKM' end;
      p := app_private.tax_profile_at(p_entity, v_end);
      select * into a from app_private.tax_period_amounts(p_entity, t, v_m, v_today);
      select * into f from public.tax_filings ff where ff.entity_id = p_entity and ff.tax_type = t and ff.tax_period = v_m and ff.status = 'filed';
      v_relevant := a.accrued_payable <> 0 or a.accrued_asset <> 0 or a.paid_payable <> 0 or f.id is not null
        or (v_eng is not null and v_eng <= v_m and p.id is not null
            and ((t = 'vat' and p.vat_status = 'pkp') or (t = 'final_umkm' and p.income_regime = 'final_umkm')));
      if not v_relevant then
        continue;
      end if;
      r := app_private.tax_rule_at(v_code, v_end);
      if r.id is null then
        tax_type := t; tax_period := v_m; step := 'pay'; due_date := null; state := 'no_rule'; outstanding := null;
        rule_code := v_code; rule_version := null; detail := 'No deadline rule is in force for this period';
        return next;
        continue;
      end if;
      v_pay := app_private.tax_due_date(r.params, 'payment', v_m);
      v_file := app_private.tax_due_date(r.params, 'filing', v_m);
      v_out := a.accrued_payable - a.paid_payable;
      rule_code := r.code; rule_version := r.rule_version; tax_type := t; tax_period := v_m;

      if t = 'final_umkm' then
        v_calc := exists (select 1 from public.tax_determinations d where d.entity_id = p_entity and d.tax_kind = 'final_umkm'
                          and d.tax_period = v_m and d.source_type = 'period' and d.superseded_at is null);
        step := 'calculate'; due_date := v_end + 1; outstanding := null;
        state := case when v_calc then 'done' when v_today > v_end then 'due' else 'upcoming' end;
        detail := case when v_calc then 'The final tax of the month is computed' else 'Compute the final tax once the month has ended' end;
        return next;
      end if;

      step := 'pay'; due_date := v_pay; outstanding := trim_scale(greatest(v_out, 0))::text;
      if a.accrued_payable = 0 and t = 'final_umkm' then
        state := 'not_applicable'; detail := 'Nothing is recognised yet for this period';
      elsif v_out <= 0 and a.accrued_payable > 0 then
        state := 'done'; detail := 'Paid';
      elsif a.accrued_payable = 0 then
        state := 'not_applicable'; detail := 'No tax was recognised for this period';
      else
        state := case when v_today > v_pay then 'overdue' when v_pay - v_today <= 10 then 'due' else 'upcoming' end;
        detail := case when v_out > 0 then trim_scale(v_out)::text || ' to pay by the deadline' else 'Settled' end;
      end if;
      return next;

      step := 'file'; due_date := v_file; outstanding := null;
      if f.id is not null then
        state := 'done'; detail := 'Filed ' || f.filed_date::text || ' (' || f.reference || ')';
      else
        state := case when v_today > v_file then 'overdue' when v_file - v_today <= 10 then 'due' when v_end >= v_today then 'upcoming' else 'upcoming' end;
        detail := 'The return of the period is not recorded as filed';
      end if;
      return next;

      if f.id is not null and not exists (select 1 from public.document_links l
                                          where l.entity_id = p_entity and l.target_type = 'tax_filing' and l.target_id = f.id and l.status = 'active') then
        step := 'evidence'; due_date := f.filed_date; outstanding := null; state := 'due';
        detail := 'Attach the filing receipt as evidence';
        return next;
      end if;
    end loop;
    v_m := (v_m + interval '1 month')::date;
  end loop;
end
$$;

create or replace function public.tax_overview(p_entity uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_today date;
  v_eng date;
  p public.tax_entity_profiles%rowtype;
  v_review bigint;
  v_upcoming jsonb;
  v_out jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  v_today := app_private.entity_today(p_entity);
  v_eng := app_private.tax_engine_from(p_entity);
  p := app_private.tax_profile_at(p_entity, v_today);
  select count(*) into v_review from public.tax_review_queue(p_entity);
  select coalesce(jsonb_agg(to_jsonb(c) order by c.due_date, c.tax_type), '[]'::jsonb) into v_upcoming
  from (select * from public.tax_calendar(p_entity, (v_today - interval '2 months')::date, v_today)
        where state in ('due', 'overdue') order by due_date limit 20) c;
  select jsonb_build_object(
    'wht_pph23', ((select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e where e.entity_id = p_entity and e.tax_type = 'wht_pph23' and e.direction = 'payable')
                 - (select coalesce(sum(x.payable_applied), 0) from public.tax_payments x where x.entity_id = p_entity and x.tax_type = 'wht_pph23' and x.status = 'confirmed'))::text,
    'wht_pph21', ((select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e where e.entity_id = p_entity and e.tax_type = 'wht_pph21' and e.direction = 'payable')
                 - (select coalesce(sum(x.payable_applied), 0) from public.tax_payments x where x.entity_id = p_entity and x.tax_type = 'wht_pph21' and x.status = 'confirmed'))::text,
    'vat', ((select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e where e.entity_id = p_entity and e.tax_type = 'vat' and e.direction = 'payable')
           - (select coalesce(sum(x.payable_applied), 0) from public.tax_payments x where x.entity_id = p_entity and x.tax_type = 'vat' and x.status = 'confirmed'))::text,
    'final_umkm', ((select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e where e.entity_id = p_entity and e.tax_type = 'final_umkm' and e.direction = 'payable')
                  - (select coalesce(sum(x.payable_applied), 0) from public.tax_payments x where x.entity_id = p_entity and x.tax_type = 'final_umkm' and x.status = 'confirmed'))::text,
    'vat_credit', ((select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e where e.entity_id = p_entity and e.tax_type = 'vat' and e.direction = 'asset')
                  - (select coalesce(sum(x.asset_applied), 0) from public.tax_payments x where x.entity_id = p_entity and x.tax_type = 'vat' and x.status = 'confirmed'))::text)
    into v_out;
  return jsonb_build_object(
    'entity_id', p_entity, 'as_of', v_today, 'engine_active_from', v_eng,
    'profile', case when p.id is null then null else jsonb_build_object(
        'effective_from', p.effective_from, 'taxpayer_kind', p.taxpayer_kind, 'residency', p.residency, 'income_regime', p.income_regime,
        'vat_status', p.vat_status, 'withholding_agent', p.withholding_agent, 'umkm_exclusion', p.umkm_exclusion,
        'aggregation_status', p.aggregation_status) end,
    'needs_review_count', v_review, 'outstanding', v_out, 'attention', v_upcoming);
end
$$;

-- Payroll journals (the recognition and its correction) are part of the tax workflow: they book PPh 21 into the tax payable.
create or replace function app_private.is_tax_journal(p_journal uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.journal_entries j
    where j.id = p_journal
      and (j.source_type in ('invoice', 'bill', 'expense', 'tax_payment', 'tax_period', 'payroll_run')
           or exists (select 1 from public.journal_entries o
                      where o.id = j.reverses_journal_id and o.source_type in ('invoice', 'bill', 'expense', 'tax_payment', 'tax_period', 'payroll_run'))))
$$;

revoke all on all functions in schema app_private from public;
