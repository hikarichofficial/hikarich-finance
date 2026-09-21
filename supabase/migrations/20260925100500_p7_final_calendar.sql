-- P7 part 5 (Step 05 §5-§6, §13, Step 09 §15): the final-tax computation of a period, the tax calendar, the tax
-- overview and the tax checks of the period close.
--
--   * PPh Final UMKM is a PERIOD computation, not a per-document one: 0.5% of the month's gross turnover, with the
--     annual ceiling, the individual-only exempt band and the eligibility facts of the taxpayer. Anything not settled
--     by facts goes to NEEDS_REVIEW (Step 05 §15). Recomputing a period supersedes the earlier result and posts only
--     the difference; the earlier result stays visible.
--   * The calendar derives due dates from the effective-dated deadline rules; a holiday is not modelled, so the
--     nominal date is shown.
--   * The period close is blocked while the tax ledger differs from the General Ledger.

-- One live computation per Entity and period.
create unique index tax_det_period_live_uq on public.tax_determinations (entity_id, tax_kind, tax_period)
  where source_type = 'period' and superseded_at is null;

-- ------------------------------------------------------------ evaluating the final tax of a month
create function app_private.tax_final_evaluate(p_entity uuid, p_period date) returns jsonb
language plpgsql stable as $$
declare
  v_end date := (p_period + interval '1 month' - interval '1 day')::date;
  v_today date := app_private.entity_today(p_entity);
  v_eng date := app_private.tax_engine_from(p_entity);
  v_base_cur public.currency_code := app_private.entity_base_currency(p_entity);
  v_scale integer := app_private.currency_scale(v_base_cur);
  v_year_start date := date_trunc('year', p_period)::date;
  p public.tax_entity_profiles%rowtype;
  r public.tax_rule_versions%rowtype;
  v_reasons jsonb := '[]'::jsonb;
  v_trace jsonb := '[]'::jsonb;
  v_status text;
  v_month numeric;
  v_prior numeric;
  v_outside numeric := 0;
  v_ceiling numeric;
  v_band numeric := 0;
  v_taxable numeric;
  v_rate numeric;
  v_tax numeric := 0;
  v_out jsonb;
  v_mode text;
  v_dp integer;
begin
  v_out := jsonb_build_object('entity_id', p_entity, 'tax_period', p_period, 'event_date', v_end, 'currency', v_base_cur,
                              'engine', case when v_eng is null then 'inactive' else 'active' end);
  if v_eng is null then
    return v_out || jsonb_build_object('status', 'not_configured', 'reasons', jsonb_build_array('The tax engine is not active for this Entity'),
                                       'trace', '[]'::jsonb, 'tax', '0');
  end if;
  if p_period is null or p_period <> date_trunc('month', p_period)::date then
    raise exception 'INVALID: the tax period is the first day of a month' using errcode = 'invalid_parameter_value';
  end if;
  if v_eng > p_period then
    return v_out || jsonb_build_object('status', 'not_configured', 'trace', '[]'::jsonb, 'tax', '0',
      'reasons', jsonb_build_array(format('The tax engine starts on %s, after this period began; the period is not computed automatically', v_eng)));
  end if;
  if v_end >= v_today then
    return v_out || jsonb_build_object('status', 'not_configured', 'trace', '[]'::jsonb, 'tax', '0',
      'reasons', jsonb_build_array('The period is not over yet; the final tax is computed once the month has ended'));
  end if;

  p := app_private.tax_profile_at(p_entity, v_end);
  if p.id is null then
    v_reasons := v_reasons || to_jsonb('No taxpayer profile is in force on the last day of the period'::text);
  else
    v_trace := app_private.tax_trace_add(v_trace, format('Taxpayer profile in force on %s: kind %s, income-tax regime %s', v_end, p.taxpayer_kind, p.income_regime));
    if p.income_regime = 'general' then
      return v_out || jsonb_build_object('status', 'not_applicable', 'trace', v_trace, 'tax', '0',
        'reasons', jsonb_build_array('The Entity is on the general regime; income tax is settled with the annual return, not as a monthly final tax'));
    elsif p.income_regime = 'unknown' then
      v_reasons := v_reasons || to_jsonb('The income-tax regime of the taxpayer is not confirmed'::text);
    end if;
  end if;
  r := app_private.tax_rule_at('PPH_FINAL_UMKM', v_end);
  if r.id is null then
    v_reasons := v_reasons || to_jsonb(format('No PPh Final UMKM rule is in force on %s', v_end));
  end if;
  if p.id is not null and r.id is not null and p.income_regime = 'final_umkm' then
    if not (r.params -> 'eligible_kinds') ? p.taxpayer_kind then
      v_reasons := v_reasons || to_jsonb(format('A taxpayer of kind "%s" is not in the rule''s list of eligible kinds; the regime needs review', p.taxpayer_kind));
    end if;
    if p.umkm_exclusion = 'excluded' then
      v_reasons := v_reasons || to_jsonb('The taxpayer is recorded as excluded from the final regime'::text);
    elsif p.umkm_exclusion = 'unknown' then
      v_reasons := v_reasons || to_jsonb('Whether an exclusion applies to the taxpayer is not confirmed'::text);
    end if;
    if p.aggregation_status = 'unknown' then
      v_reasons := v_reasons || to_jsonb('Whether turnover of spouse, minor children or related individual companies must be added is not confirmed'::text);
    end if;
  end if;
  if jsonb_array_length(v_reasons) > 0 then
    return v_out || jsonb_build_object('status', 'needs_review', 'reasons', v_reasons, 'trace', v_trace, 'tax', '0');
  end if;

  v_rate := (r.params ->> 'rate')::numeric;
  v_ceiling := (r.params ->> 'annual_ceiling')::numeric;
  v_mode := coalesce(r.params -> 'rounding' ->> 'mode', 'half_up');
  v_dp := coalesce((r.params -> 'rounding' ->> 'scale')::integer, 0);
  if p.taxpayer_kind = 'individual' then
    v_band := coalesce((r.params -> 'exempt_band' ->> 'individual')::numeric, 0);
  end if;

  -- Gross turnover: invoices issued in the month, before VAT, in the base currency. Voided and cancelled invoices
  -- are not turnover; refunds and credit notes are not deducted (a stated simplification, see DECISIONS).
  select coalesce(sum(i.base_total - case when i.currency = v_base_cur then i.tax_total else 0 end), 0) into v_month
  from public.invoices i
  where i.entity_id = p_entity and i.status = 'issued' and i.issue_date between p_period and v_end;
  select coalesce(sum(i.base_total - case when i.currency = v_base_cur then i.tax_total else 0 end), 0) into v_prior
  from public.invoices i
  where i.entity_id = p_entity and i.status = 'issued' and i.issue_date >= v_year_start and i.issue_date < p_period;
  if p.aggregation_status = 'applies' then
    select coalesce(sum(f.amount), 0) into v_outside from public.tax_aggregation_facts f
    where f.entity_id = p_entity and f.tax_year = extract(year from p_period)::integer and f.superseded_at is null;
  end if;
  v_trace := app_private.tax_trace_add(v_trace, format('Gross turnover of %s: %s; earlier this year: %s; turnover outside this system counted toward the ceiling: %s',
    to_char(p_period, 'YYYY-MM'), trim_scale(v_month), trim_scale(v_prior), trim_scale(v_outside)));

  if v_prior + v_month + v_outside > v_ceiling then
    return v_out || jsonb_build_object('status', 'needs_review', 'trace', v_trace, 'tax', '0',
      'reasons', jsonb_build_array(format('Turnover for the year (%s) exceeds the annual ceiling of %s; the regime ends and the excess is not computed automatically',
        trim_scale(v_prior + v_month + v_outside), trim_scale(v_ceiling))));
  end if;
  if v_band > 0 and v_year_start < date_trunc('month', v_eng)::date then
    return v_out || jsonb_build_object('status', 'needs_review', 'trace', v_trace, 'tax', '0',
      'reasons', jsonb_build_array('The exempt band of an individual depends on the whole year''s turnover, and part of this year predates the tax engine; confirm the earlier turnover first'));
  end if;

  v_taxable := greatest(0, v_prior + v_month - v_band) - greatest(0, v_prior - v_band);
  v_tax := app_private.round_amount(v_taxable * v_rate, v_dp, v_mode);
  if v_band > 0 then
    v_trace := app_private.tax_trace_add(v_trace, format('The first %s of the year''s turnover is not taxed for an individual; taxable turnover of the month: %s', trim_scale(v_band), trim_scale(v_taxable)));
  else
    v_trace := app_private.tax_trace_add(v_trace, format('No exempt band applies to a taxpayer of kind "%s"; taxable turnover of the month: %s', p.taxpayer_kind, trim_scale(v_taxable)));
  end if;
  v_trace := app_private.tax_trace_add(v_trace, format('PPh Final = %s x %s = %s (rounded %s to %s decimals)', trim_scale(v_taxable), trim_scale(v_rate), trim_scale(v_tax), v_mode, v_dp));
  return v_out || jsonb_build_object(
    'status', 'auto_determined', 'reasons', '[]'::jsonb, 'trace', v_trace, 'tax', trim_scale(v_tax)::text,
    'base', trim_scale(v_taxable)::text, 'rate', trim_scale(v_rate)::text,
    'turnover_month', trim_scale(v_month)::text, 'turnover_prior', trim_scale(v_prior)::text,
    'turnover_outside', trim_scale(v_outside)::text, 'ceiling', trim_scale(v_ceiling)::text, 'exempt_band', trim_scale(v_band)::text,
    'rules', jsonb_build_array(app_private.tax_rule_ref(r)),
    'facts', jsonb_build_object('taxpayer_kind', p.taxpayer_kind, 'income_regime', p.income_regime,
                                'umkm_exclusion', p.umkm_exclusion, 'aggregation_status', p.aggregation_status),
    'consequence', 'The final income tax of the month is a tax expense and a liability to pay by the deadline of the following month');
end
$$;

create function public.tax_final_preview(p_entity uuid, p_period date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  return app_private.tax_final_evaluate(p_entity, p_period);
end
$$;

-- ------------------------------------------------------------ computing and recording it
create function public.tax_final_compute(p_entity uuid, p_key text, p_period date) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  e jsonb;
  v_old public.tax_determinations%rowtype;
  v_new uuid := gen_random_uuid();
  v_tax numeric;
  v_delta numeric;
  v_end date;
  v_date date;
  v_today date;
  v_expense text;
  v_journal uuid;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_rev integer := 1;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.confirm_facts') then
    raise exception 'FORBIDDEN: computing the final tax needs tax.confirm_facts' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.final_compute', p_entity, p_key, md5(jsonb_build_object('p', p_period)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('tax_final:' || p_entity::text || ':' || coalesce(p_period::text, ''), 0));
  e := app_private.tax_final_evaluate(p_entity, p_period);
  if e ->> 'status' <> 'auto_determined' then
    raise exception 'CONFLICT: the final tax of % cannot be computed now (%): %', to_char(p_period, 'YYYY-MM'), e ->> 'status',
      e -> 'reasons' ->> 0 using errcode = 'integrity_constraint_violation';
  end if;
  v_tax := (e ->> 'tax')::numeric;
  v_end := (e ->> 'event_date')::date;
  v_today := app_private.entity_today(p_entity);
  select * into v_old from public.tax_determinations
  where entity_id = p_entity and tax_kind = 'final_umkm' and tax_period = p_period and source_type = 'period' and superseded_at is null
  for update;
  if v_old.id is not null then
    v_delta := v_tax - v_old.tax_amount;
    v_rev := v_old.revision + 1;
    if v_delta = 0 then
      perform app_private.idem_complete('tax.final_compute', p_entity, p_key, 'tax_determinations', v_old.id);
      return v_old.id;
    end if;
  else
    v_delta := v_tax;
  end if;

  -- The journal is dated at the end of the period, or today when that accounting period is already closed.
  v_date := v_end;
  if exists (select 1 from public.accounting_periods ap
             where ap.entity_id = p_entity and ap.status = 'closed' and v_end between ap.period_start and ap.period_end) then
    v_date := v_today;
  end if;
  if v_delta <> 0 then
    v_expense := case (select entity_type from public.entities where id = p_entity) when 'company' then 'INCOME_TAX_EXPENSE' else 'PERSONAL_TAX' end;
    v_desc := format('PPh Final UMKM %s%s', to_char(p_period, 'YYYY-MM'), case when v_old.id is not null then ' (recomputed)' else '' end);
    v_lines := jsonb_build_array(
      jsonb_build_object('account_key', v_expense, 'debit', greatest(v_delta, 0), 'credit', greatest(-v_delta, 0), 'description', v_desc),
      jsonb_build_object('account_key', 'TAX_PAYABLE', 'debit', greatest(-v_delta, 0), 'credit', greatest(v_delta, 0), 'description', v_desc));
    v_journal := app_private.post_system_journal(p_entity, 'tax_period', v_new, 'tax_final.accrual', 'tax_final.v1', v_date, v_desc, v_lines);
  end if;
  if v_old.id is not null then
    update public.tax_determinations
    set status = 'superseded', superseded_at = now(), superseded_reason = 'Recomputed with the current turnover'
    where id = v_old.id;
  end if;
  insert into public.tax_determinations
    (id, entity_id, tax_kind, tax_type, source_type, source_id, event_date, tax_period, status, currency, base_amount, rate,
     tax_amount, direction, rules, facts, trace, components, consequence, journal_id, revision, supersedes_id)
  values
    (v_new, p_entity, 'final_umkm', 'final_umkm', 'period', null, v_end, p_period, 'auto_determined', (e ->> 'currency')::public.currency_code,
     (e ->> 'base')::numeric, (e ->> 'rate')::numeric, v_tax, 'payable', e -> 'rules',
     (e -> 'facts') || jsonb_build_object('turnover_month', e ->> 'turnover_month', 'turnover_prior', e ->> 'turnover_prior',
                                          'turnover_outside', e ->> 'turnover_outside'),
     e -> 'trace',
     jsonb_build_array(jsonb_build_object('name', 'PPh Final UMKM', 'base', e ->> 'base', 'rate', e ->> 'rate', 'amount', e ->> 'tax')),
     e ->> 'consequence', v_journal, v_rev, v_old.id);
  if v_delta <> 0 then
    insert into public.tax_ledger_entries
      (entity_id, determination_id, tax_kind, tax_type, tax_period, direction, entry_kind, amount, entry_date, journal_id, description)
    values (p_entity, v_new, 'final_umkm', 'final_umkm', p_period, 'payable', case when v_delta > 0 then 'accrual' else 'reversal' end,
            v_delta, v_date, v_journal, v_desc);
  end if;
  perform app_private.idem_complete('tax.final_compute', p_entity, p_key, 'tax_determinations', v_new);
  return v_new;
end
$$;

-- ------------------------------------------------------------ the tax calendar
create function app_private.tax_due_date(p_params jsonb, p_step text, p_period date) returns date
language plpgsql immutable as $$
declare
  o jsonb := p_params -> p_step;
  v_month date;
  v_last date;
begin
  if o is null then
    return null;
  end if;
  v_month := (p_period + make_interval(months => coalesce((o ->> 'month_offset')::integer, 1)))::date;
  v_last := (date_trunc('month', v_month) + interval '1 month' - interval '1 day')::date;
  if coalesce((o ->> 'eom')::boolean, false) then
    return v_last;
  end if;
  return least(v_last, make_date(extract(year from v_month)::integer, extract(month from v_month)::integer, (o ->> 'day')::integer));
end
$$;

create function public.tax_calendar(p_entity uuid, p_from date default null, p_to date default null)
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
    foreach t in array array['vat', 'wht_pph23', 'final_umkm'] loop
      v_code := case t when 'vat' then 'DEADLINE_PPN' when 'wht_pph23' then 'DEADLINE_PPH23' else 'DEADLINE_PPH_FINAL_UMKM' end;
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

-- ------------------------------------------------------------ the tax overview
create function public.tax_overview(p_entity uuid) returns jsonb
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

-- ------------------------------------------------------------ tax checks of the period close
-- Draft and submitted documents of a period whose tax would need review (counted for the close warning).
create function app_private.tax_review_count(p_entity uuid, p_from date, p_to date) returns bigint
language plpgsql stable as $$
declare
  r record;
  v_n bigint := 0;
begin
  for r in
    select 'invoice'::text as st, i.id from public.invoices i
      where i.entity_id = p_entity and i.status = 'draft' and i.issue_date between p_from and p_to
    union all
    select 'bill', b.id from public.bills b
      where b.entity_id = p_entity and b.status in ('draft', 'submitted') and b.bill_date between p_from and p_to
    union all
    select 'expense', x.id from public.expenses x
      where x.entity_id = p_entity and x.status in ('draft', 'submitted') and x.expense_date between p_from and p_to
    limit 500
  loop
    if app_private.tax_evaluate(r.st, r.id) ->> 'status' = 'needs_review' then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end
$$;

-- The period close: the P6 checks, plus the tax checks.
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

  -- Tax ledger against Tax Payable and Tax Asset in the General Ledger, as of the end of the period (Step 08 §19).
  -- Only journals the tax workflow produced take part; other postings to the tax accounts are shown in the tax control.
  select count(*) into v_n from app_private.tax_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_workflow;
  if v_n > 0 then
    return query select 'tax_ledger_mismatch'::text, 'blocker'::text,
      'The tax ledger differs from Tax Payable / Tax Asset in the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from app_private.tax_review_count(v_p.entity_id, v_p.period_start, v_p.period_end) c where c > 0;
  if v_n > 0 then
    return query select 'tax_review_pending'::text, 'warning'::text,
      'Draft or submitted documents dated in this period need a tax review before they can be recognised'::text,
      app_private.tax_review_count(v_p.entity_id, v_p.period_start, v_p.period_end);
  end if;

  -- Final income tax of a completed month that is on the final regime but not computed yet.
  select count(*) into v_n
  from generate_series(date_trunc('month', v_p.period_start)::date, v_p.period_end, interval '1 month') g(m)
  where app_private.tax_engine_from(v_p.entity_id) is not null and app_private.tax_engine_from(v_p.entity_id) <= g.m::date
    and (g.m::date + interval '1 month' - interval '1 day')::date <= v_p.period_end
    and (g.m::date + interval '1 month' - interval '1 day')::date < app_private.entity_today(v_p.entity_id)
    and (select p.income_regime from app_private.tax_profile_at(v_p.entity_id, (g.m::date + interval '1 month' - interval '1 day')::date) p) = 'final_umkm'
    and not exists (select 1 from public.tax_determinations d
                    where d.entity_id = v_p.entity_id and d.tax_kind = 'final_umkm' and d.tax_period = g.m::date
                      and d.source_type = 'period' and d.superseded_at is null);
  if v_n > 0 then
    return query select 'final_tax_not_computed'::text, 'warning'::text,
      'The final income tax of a completed month in this period is not computed yet'::text, v_n;
  end if;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
revoke all on function app_private.tax_final_evaluate(uuid, date) from public;
revoke all on function app_private.tax_due_date(jsonb, text, date) from public;
revoke all on function app_private.tax_review_count(uuid, date, date) from public;
revoke all on function app_private.period_blockers(uuid) from public;

revoke all on function public.tax_final_preview(uuid, date) from public, anon;
revoke all on function public.tax_final_compute(uuid, text, date) from public, anon;
revoke all on function public.tax_calendar(uuid, date, date) from public, anon;
revoke all on function public.tax_overview(uuid) from public, anon;
grant execute on function public.tax_final_preview(uuid, date) to authenticated;
grant execute on function public.tax_final_compute(uuid, text, date) to authenticated;
grant execute on function public.tax_calendar(uuid, date, date) to authenticated;
grant execute on function public.tax_overview(uuid) to authenticated;
