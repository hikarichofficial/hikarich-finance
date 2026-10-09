-- P15 decision 374 (OWNER, 9 October 2026): Bunga Berjenjang - a loan whose interest changes over time.
--
--   1. When a loan is made: an opening rate plus up to 20 later rates, each "from" a date (for example fixed for
--      three years, then floating). An instalment uses the rate in force on its due date; an annuity recomputes its
--      payment from the remaining balance and remaining instalments whenever the rate changes.
--   2. "Ubah Bunga" on a running loan (`loan_change_rate`): a new rate from a date, which may lie in the future.
--      Instalments falling due before that date stay as they are (what is still unpaid on them is carried over);
--      the instalments from that date on are recalculated from the remaining principal over the same remaining
--      number of instalments, so the term does not change. The old schedule stays as history, and - as with a
--      restructuring - payments made under it can no longer be reversed afterwards.
--   3. A restructuring can carry later rates too.
--
-- The schedule methods, postings and the allocation of payments are unchanged; rates stay terms, never postings.

alter table public.loan_schedule_versions add column rate_steps jsonb not null default '[]'::jsonb
  check (jsonb_typeof(rate_steps) = 'array' and jsonb_array_length(rate_steps) <= 21);

-- Validates and normalises the later rates: [{"from": date, "rate": percent}], 1 to 20 entries, dates strictly
-- ascending and not before p_min. Returns them as [{"from": "YYYY-MM-DD", "rate": "7.5"}].
create function app_private.loan_rate_steps_arg(p_steps jsonb, p_min date) returns jsonb
language plpgsql immutable as $$
declare
  v_out jsonb := '[]'::jsonb;
  x jsonb;
  v_from date;
  v_prev date;
  v_rate numeric;
begin
  if p_steps is null or p_steps = 'null'::jsonb then
    return '[]'::jsonb;
  end if;
  if jsonb_typeof(p_steps) <> 'array' or jsonb_array_length(p_steps) > 20 then
    raise exception 'INVALID: a loan has at most 20 later interest rates' using errcode = 'invalid_parameter_value';
  end if;
  for x in select * from jsonb_array_elements(p_steps) loop
    begin
      v_from := (x ->> 'from')::date;
    exception when others then
      raise exception 'INVALID: a later interest rate has an unreadable start date' using errcode = 'invalid_parameter_value';
    end;
    if v_from is null or v_from <= p_min or (v_prev is not null and v_from <= v_prev) then
      raise exception 'INVALID: later interest rates start after %, each after the one before', p_min
        using errcode = 'invalid_parameter_value';
    end if;
    v_rate := app_private.rate_arg(x ->> 'rate', 'a later interest rate');
    v_out := v_out || jsonb_build_object('from', v_from, 'rate', trim_scale(v_rate)::text);
    v_prev := v_from;
  end loop;
  return v_out;
end
$$;

-- The rate in force on a date: the opening rate, or the latest later rate starting on or before it.
create function app_private.loan_rate_on(p_rate numeric, p_steps jsonb, p_date date) returns numeric
language sql immutable as $$
  select coalesce((select (s ->> 'rate')::numeric from jsonb_array_elements(coalesce(p_steps, '[]'::jsonb)) s
                   where (s ->> 'from')::date <= p_date order by (s ->> 'from')::date desc limit 1), p_rate)
$$;

drop function app_private.loan_plan(text, numeric, numeric, integer, integer, date, integer);
drop function app_private.loan_schedule_rows(text, numeric, numeric, integer, integer, date, jsonb, integer, date);
drop function app_private.loan_write_version(uuid, integer, text, text, numeric, integer, integer, date, jsonb, numeric, date, date, text);
drop function public.loan_create(uuid, text, text, text, uuid, text, text, date, text, text, text, integer, integer, date, jsonb, uuid, uuid, text);
drop function public.loan_restructure(uuid, text, date, text, text, integer, integer, date, jsonb, text);


create function app_private.loan_plan(
  p_method text, p_principal numeric, p_rate numeric, p_n integer, p_step integer, p_first date, p_scale integer,
  p_steps jsonb default '[]'::jsonb)
returns table (seq integer, due_date date, principal numeric, interest numeric)
language plpgsql immutable as $$
declare
  v_r numeric;
  v_r_prev numeric;
  v_due date;
  v_bal numeric := p_principal;
  v_pmt numeric;
  v_int numeric;
  v_prin numeric;
  k integer;
begin
  if p_method not in ('annuity', 'flat', 'interest_only') then
    raise exception 'INVALID: unknown schedule method %', p_method using errcode = 'invalid_parameter_value';
  end if;
  if p_principal <= 0 or p_n not between 1 and 600 or p_step not in (1, 3, 6, 12) then
    raise exception 'INVALID: a schedule needs a principal, 1 to 600 installments and a step of 1, 3, 6 or 12 months'
      using errcode = 'invalid_parameter_value';
  end if;
  for k in 1..p_n loop
    v_due := (p_first + make_interval(months => (k - 1) * p_step))::date;
    v_r := app_private.loan_rate_on(p_rate, p_steps, v_due) / 100 * p_step / 12;
    -- An annuity's payment is set from the balance and the instalments left whenever the rate changes.
    if p_method = 'annuity' and (k = 1 or v_r is distinct from v_r_prev) then
      v_pmt := case when v_r = 0 then app_private.round_amount(v_bal / (p_n - k + 1), p_scale, 'half_up')
                    else app_private.round_amount(v_bal * v_r / (1 - power(1 + v_r, -(p_n - k + 1))), p_scale, 'half_up') end;
    end if;
    v_r_prev := v_r;
    if p_method = 'flat' then
      v_int := app_private.round_amount(p_principal * v_r, p_scale, 'half_up');
      v_prin := case when k = p_n then v_bal else least(app_private.round_amount(p_principal / p_n, p_scale, 'half_up'), v_bal) end;
    elsif p_method = 'interest_only' then
      v_int := app_private.round_amount(v_bal * v_r, p_scale, 'half_up');
      v_prin := case when k = p_n then v_bal else 0 end;
    else
      v_int := app_private.round_amount(v_bal * v_r, p_scale, 'half_up');
      v_prin := case when k = p_n then v_bal else least(greatest(v_pmt - v_int, 0), v_bal) end;
    end if;
    seq := k;
    due_date := v_due;
    principal := v_prin;
    interest := v_int;
    return next;
    v_bal := v_bal - v_prin;
  end loop;
end
$$;

create function app_private.loan_schedule_rows(
  p_method text, p_basis numeric, p_rate numeric, p_n integer, p_step integer, p_first date, p_items jsonb,
  p_scale integer, p_min_date date, p_steps jsonb default '[]'::jsonb)
returns table (seq integer, due_date date, principal numeric, interest numeric, fee numeric)
language plpgsql stable as $$
declare
  v_item jsonb;
  v_n integer := 0;
  v_date date;
  v_prev date;
  v_p numeric;
  v_i numeric;
  v_f numeric;
  v_sum numeric := 0;
  r record;
begin
  if p_method = 'manual' then
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 600 then
      raise exception 'INVALID: a manual schedule lists 1 to 600 installments' using errcode = 'invalid_parameter_value';
    end if;
    for v_item in select * from jsonb_array_elements(p_items) loop
      if jsonb_typeof(v_item) <> 'object' then
        raise exception 'INVALID: every installment is an object with a due date and amounts' using errcode = 'invalid_parameter_value';
      end if;
      begin
        v_date := (v_item ->> 'due_date')::date;
      exception when others then
        raise exception 'INVALID: an installment has an unreadable due date' using errcode = 'invalid_parameter_value';
      end;
      if v_date is null or v_date < p_min_date or (v_prev is not null and v_date < v_prev) then
        raise exception 'INVALID: installments are dated in order, none before %', p_min_date using errcode = 'invalid_parameter_value';
      end if;
      v_p := app_private.money_arg(coalesce(v_item ->> 'principal', '0'), 'the installment principal', p_scale, true);
      v_i := app_private.money_arg(coalesce(v_item ->> 'interest', '0'), 'the installment interest', p_scale, true);
      v_f := app_private.money_arg(coalesce(v_item ->> 'fee', '0'), 'the installment fee', p_scale, true);
      if v_p + v_i + v_f = 0 then
        raise exception 'INVALID: an installment needs an amount' using errcode = 'invalid_parameter_value';
      end if;
      v_n := v_n + 1;
      v_sum := v_sum + v_p;
      v_prev := v_date;
      seq := v_n;
      due_date := v_date;
      principal := v_p;
      interest := v_i;
      fee := v_f;
      return next;
    end loop;
    if v_sum <> p_basis then
      raise exception 'INVALID: the installments schedule % of principal, not the % to be scheduled', trim_scale(v_sum), trim_scale(p_basis)
        using errcode = 'invalid_parameter_value';
    end if;
    return;
  end if;
  if p_first is null or p_first < p_min_date then
    raise exception 'INVALID: the first installment cannot fall before %', p_min_date using errcode = 'invalid_parameter_value';
  end if;
  if p_method = 'interest_only' and p_rate = 0 and coalesce(jsonb_array_length(p_steps), 0) = 0 then
    raise exception 'INVALID: an interest-only schedule needs a rate' using errcode = 'invalid_parameter_value';
  end if;
  for r in select * from app_private.loan_plan(p_method, p_basis, p_rate, p_n, p_step, p_first, p_scale, p_steps) loop
    if r.principal + r.interest = 0 then
      raise exception 'INVALID: this rate and term leave an installment without an amount; change the term or use a manual schedule'
        using errcode = 'invalid_parameter_value';
    end if;
    seq := r.seq;
    due_date := r.due_date;
    principal := r.principal;
    interest := r.interest;
    fee := 0;
    return next;
  end loop;
end
$$;

create function app_private.loan_write_version(
  p_loan uuid, p_version_no integer, p_status text, p_method text, p_rate numeric, p_n integer, p_step integer,
  p_first date, p_items jsonb, p_basis numeric, p_effective date, p_min_date date, p_reason text,
  p_steps jsonb default '[]'::jsonb)
returns uuid
language plpgsql as $$
declare
  l public.loans%rowtype;
  v_scale integer;
  v_id uuid := gen_random_uuid();
  v_count integer;
  v_last date;
  v_rows jsonb;
begin
  select * into l from public.loans where id = p_loan;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(l.entity_id));
  select jsonb_agg(to_jsonb(r) order by r.seq), count(*), max(r.due_date) into v_rows, v_count, v_last
  from app_private.loan_schedule_rows(p_method, p_basis, p_rate, p_n, p_step, p_first, p_items, v_scale, p_min_date,
                                       coalesce(p_steps, '[]'::jsonb)) r;
  insert into public.loan_schedule_versions
    (id, entity_id, loan_id, version_no, status, method, rate, installments, step_months, effective_from, principal_basis,
     maturity_date, reason, activated_at, created_by, rate_steps)
  values
    (v_id, l.entity_id, l.id, p_version_no, p_status, p_method, p_rate, v_count, case when p_method = 'manual' then null else p_step end,
     case when p_status = 'active' then p_effective end, p_basis, v_last, nullif(btrim(coalesce(p_reason, '')), ''),
     case when p_status = 'active' then now() end, auth.uid(), coalesce(p_steps, '[]'::jsonb));
  insert into public.loan_schedule_items (entity_id, loan_id, version_id, seq, due_date, principal_due, interest_due, fee_due)
  select l.entity_id, l.id, v_id, t.seq, t.due_date, t.principal, t.interest, t.fee
  from jsonb_to_recordset(v_rows) as t(seq integer, due_date date, principal numeric, interest numeric, fee numeric)
  order by t.seq;
  return v_id;
end
$$;

create function public.loan_create(
  p_entity uuid, p_key text, p_direction text, p_counterparty text, p_contact uuid, p_purpose text, p_principal text,
  p_agreement date, p_term_class text, p_rate text, p_method text, p_installments integer, p_step_months integer,
  p_first_due date, p_items jsonb default null, p_asset uuid default null, p_related uuid default null,
  p_basis text default null, p_rate_steps jsonb default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  v_replay uuid;
  v_scale integer;
  v_principal numeric;
  v_rate numeric;
  v_account uuid;
  v_term text;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_steps jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'loans.manage') then
    raise exception 'FORBIDDEN: recording a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('loan.create', p_entity, p_key,
    md5(jsonb_build_object('dir', p_direction, 'n', p_counterparty, 'c', p_contact, 'p', p_purpose, 'a', p_principal,
                           'ag', p_agreement, 't', p_term_class, 'r', p_rate, 'm', p_method, 'i', p_installments,
                           's', p_step_months, 'f', p_first_due, 'it', p_items, 'as', p_asset, 're', p_related,
                           'b', p_basis, 'rs', p_rate_steps)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(e.base_currency);
  if p_direction not in ('borrowed', 'lent') then
    raise exception 'INVALID: a loan is borrowed or lent' using errcode = 'invalid_parameter_value';
  end if;
  if length(btrim(coalesce(p_counterparty, ''))) not between 1 and 200 or length(btrim(coalesce(p_purpose, ''))) not between 3 and 500 then
    raise exception 'INVALID: name the counterparty (up to 200 characters) and the purpose (3 to 500)' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_agreement);
  if p_agreement > app_private.entity_today(p_entity) then
    raise exception 'INVALID: the agreement cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_contact is not null and not exists (select 1 from public.contacts where id = p_contact and entity_id = p_entity) then
    raise exception 'INVALID: unknown contact' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.check_related_entity(p_entity, p_related, p_basis);
  v_principal := app_private.money_arg(p_principal, 'the principal', v_scale);
  v_rate := app_private.rate_arg(coalesce(nullif(btrim(p_rate), ''), '0'), 'the annual interest rate');
  if p_method not in ('annuity', 'flat', 'interest_only', 'manual') then
    raise exception 'INVALID: the schedule method is annuity, flat, interest_only or manual' using errcode = 'invalid_parameter_value';
  end if;
  if p_method <> 'manual' and (p_installments is null or p_installments not between 1 and 600 or p_step_months is null
                               or p_step_months not in (1, 3, 6, 12) or p_first_due is null) then
    raise exception 'INVALID: a generated schedule needs the installments (1 to 600), a step of 1, 3, 6 or 12 months and the first due date'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_method = 'manual' and coalesce(jsonb_array_length(nullif(p_rate_steps, 'null'::jsonb)), 0) > 0 then
    raise exception 'INVALID: a manual schedule carries its own amounts; later interest rates apply to a generated schedule'
      using errcode = 'invalid_parameter_value';
  end if;
  v_steps := app_private.loan_rate_steps_arg(p_rate_steps, p_agreement);
  -- Which ledger account carries the balance.
  if p_direction = 'lent' then
    if p_term_class is not null then
      raise exception 'INVALID: a loan given has no short or long term class' using errcode = 'invalid_parameter_value';
    end if;
    v_account := app_private.role_account(p_entity, 'other_receivable');
  else
    if e.entity_type = 'company' and (p_term_class is null or p_term_class not in ('short', 'long')) then
      raise exception 'INVALID: a loan received is short-term or long-term' using errcode = 'invalid_parameter_value';
    end if;
    v_term := case when e.entity_type = 'company' then p_term_class end;
    v_account := app_private.role_account(p_entity, case when v_term = 'long' then 'loan_long_term' else 'loan_short_term' end);
  end if;
  if p_asset is not null then
    if p_direction <> 'borrowed' then
      raise exception 'INVALID: only a loan received can finance an asset' using errcode = 'invalid_parameter_value';
    end if;
    if not exists (select 1 from public.fixed_assets where id = p_asset and entity_id = p_entity and status <> 'cancelled') then
      raise exception 'INVALID: unknown or cancelled asset' using errcode = 'invalid_parameter_value';
    end if;
  end if;

  perform app_private.ensure_loan_numbering(p_entity);
  v_number := app_private.allocate_document_number(p_entity, 'loan', p_agreement);
  insert into public.loans
    (id, entity_id, loan_number, direction, status, counterparty_name, contact_id, purpose, principal, source_type,
     agreement_date, principal_account_id, term_class, asset_id, related_entity_id, relationship_basis, created_by)
  values
    (v_id, p_entity, v_number, p_direction, 'draft', btrim(p_counterparty), p_contact, btrim(p_purpose), v_principal, 'proceeds',
     p_agreement, v_account, v_term, p_asset, p_related, nullif(btrim(coalesce(p_basis, '')), ''), auth.uid());
  perform app_private.loan_write_version(v_id, 1, 'draft', p_method, v_rate, p_installments, p_step_months, p_first_due,
                                         p_items, v_principal, null, p_agreement, null, v_steps);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_entity, 'LoanDrafted', 'loan', v_id, jsonb_build_object('number', v_number, 'direction', p_direction));
  perform app_private.idem_complete('loan.create', p_entity, p_key, 'loans', v_id);
  return v_id;
end
$$;

create function public.loan_restructure(
  p_loan uuid, p_key text, p_effective date, p_rate text, p_method text, p_installments integer, p_step_months integer,
  p_first_due date, p_items jsonb, p_reason text, p_rate_steps jsonb default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  v_replay uuid;
  v_rate numeric;
  v_outstanding numeric;
  v_last date;
  v_no integer;
  v_id uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_steps jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: restructuring a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a restructuring needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_replay := app_private.idem_begin('loan.restructure', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_loan, 'e', p_effective, 'r', p_rate, 'm', p_method, 'n', p_installments, 's', p_step_months,
                           'f', p_first_due, 'i', p_items, 'why', v_reason, 'rs', p_rate_steps)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: only an active loan can be restructured (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(p_effective);
  if p_effective > app_private.entity_today(l.entity_id) then
    raise exception 'INVALID: a restructuring cannot take effect in the future' using errcode = 'invalid_parameter_value';
  end if;
  v_last := app_private.loan_last_activity(l.id);
  if p_effective < v_last then
    raise exception 'INVALID: the restructuring cannot take effect before the last activity on this loan (%)', v_last
      using errcode = 'invalid_parameter_value';
  end if;
  if p_method not in ('annuity', 'flat', 'interest_only', 'manual') then
    raise exception 'INVALID: the schedule method is annuity, flat, interest_only or manual' using errcode = 'invalid_parameter_value';
  end if;
  if p_method <> 'manual' and (p_installments is null or p_installments not between 1 and 600 or p_step_months is null
                               or p_step_months not in (1, 3, 6, 12) or p_first_due is null) then
    raise exception 'INVALID: a generated schedule needs the installments (1 to 600), a step of 1, 3, 6 or 12 months and the first due date'
      using errcode = 'invalid_parameter_value';
  end if;
  v_rate := app_private.rate_arg(coalesce(nullif(btrim(p_rate), ''), '0'), 'the annual interest rate');
  if p_method = 'manual' and coalesce(jsonb_array_length(nullif(p_rate_steps, 'null'::jsonb)), 0) > 0 then
    raise exception 'INVALID: a manual schedule carries its own amounts; later interest rates apply to a generated schedule'
      using errcode = 'invalid_parameter_value';
  end if;
  v_steps := app_private.loan_rate_steps_arg(p_rate_steps, p_effective);
  v_outstanding := app_private.loan_outstanding(l.id);
  select coalesce(max(version_no), 0) + 1 into v_no from public.loan_schedule_versions where loan_id = l.id;
  update public.loan_schedule_versions set status = 'superseded', superseded_at = now() where loan_id = l.id and status = 'active';
  perform set_config('app.audit_reason', v_reason, true);
  v_id := app_private.loan_write_version(l.id, v_no, 'active', p_method, v_rate, p_installments, p_step_months, p_first_due,
                                         p_items, v_outstanding, p_effective, p_effective, v_reason, v_steps);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (l.entity_id, 'LoanRestructured', 'loan', l.id, jsonb_build_object('number', l.loan_number, 'version', v_no));
  perform app_private.idem_complete('loan.restructure', l.entity_id, p_key, 'loan_schedule_versions', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ Ubah Bunga: a new rate from a date
create function public.loan_change_rate(p_loan uuid, p_key text, p_from date, p_rate text, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  v public.loan_schedule_versions%rowtype;
  it record;
  r record;
  v_replay uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_rate numeric;
  v_scale integer;
  v_today date;
  v_last date;
  v_outstanding numeric;
  v_carried numeric := 0;
  v_basis numeric;
  v_n integer;
  v_first date;
  v_seq integer := 0;
  v_rows jsonb := '[]'::jsonb;
  v_steps jsonb;
  v_no integer;
  v_id uuid := gen_random_uuid();
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: changing the interest of a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a change of interest needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_replay := app_private.idem_begin('loan.change_rate', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_loan, 'f', p_from, 'r', p_rate, 'why', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: only an active loan can change its interest (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  select * into v from public.loan_schedule_versions where loan_id = l.id and status = 'active';
  if v.method = 'manual' then
    raise exception 'INVALID: a manual schedule carries its own amounts; use Restrukturisasi Jadwal to replace it'
      using errcode = 'invalid_parameter_value';
  end if;
  v_rate := app_private.rate_arg(coalesce(nullif(btrim(p_rate), ''), '0'), 'the new annual interest rate');
  perform app_private.assert_business_date(p_from);
  v_today := app_private.entity_today(l.entity_id);
  v_last := app_private.loan_last_activity(l.id);
  if p_from < v_last then
    raise exception 'INVALID: the new rate cannot start before the last activity on this loan (%)', v_last
      using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(l.entity_id));

  -- Instalments due before the new rate: what is still unpaid on them is carried over unchanged.
  for it in select * from app_private.loan_items(l.id, v.id, null) where due_date < p_from order by seq loop
    if it.principal_due - it.paid_principal + it.interest_due - it.paid_interest + it.fee_due - it.paid_fee > 0 then
      v_seq := v_seq + 1;
      v_rows := v_rows || jsonb_build_object('seq', v_seq, 'due_date', it.due_date,
        'principal', greatest(it.principal_due - it.paid_principal, 0), 'interest', greatest(it.interest_due - it.paid_interest, 0),
        'fee', greatest(it.fee_due - it.paid_fee, 0));
      v_carried := v_carried + greatest(it.principal_due - it.paid_principal, 0);
    end if;
  end loop;
  -- The instalments from the new rate on keep their number and dates; their amounts are recalculated.
  select count(*), min(due_date) into v_n, v_first from public.loan_schedule_items where version_id = v.id and due_date >= p_from;
  if v_n = 0 then
    raise exception 'INVALID: no instalment falls due on or after %; the new rate would change nothing', p_from
      using errcode = 'invalid_parameter_value';
  end if;
  v_outstanding := app_private.loan_outstanding(l.id);
  v_basis := v_outstanding - v_carried;
  if v_basis <= 0 then
    raise exception 'INVALID: no principal is left for the instalments from %', p_from using errcode = 'invalid_parameter_value';
  end if;
  if v.method = 'interest_only' and v_rate = 0 then
    raise exception 'INVALID: an interest-only schedule needs a rate' using errcode = 'invalid_parameter_value';
  end if;
  for r in select * from app_private.loan_plan(v.method, v_basis, v_rate, v_n, v.step_months, v_first, v_scale) loop
    v_seq := v_seq + 1;
    v_rows := v_rows || jsonb_build_object('seq', v_seq, 'due_date', r.due_date, 'principal', r.principal, 'interest', r.interest, 'fee', 0);
  end loop;
  -- The rates of the new version: the earlier ones up to the change, then the new rate.
  select coalesce(jsonb_agg(s order by (s ->> 'from')::date), '[]'::jsonb) into v_steps
  from jsonb_array_elements(v.rate_steps) s where (s ->> 'from')::date < p_from;
  v_steps := v_steps || jsonb_build_object('from', p_from, 'rate', trim_scale(v_rate)::text);

  select coalesce(max(version_no), 0) + 1 into v_no from public.loan_schedule_versions where loan_id = l.id;
  update public.loan_schedule_versions set status = 'superseded', superseded_at = now() where id = v.id;
  perform set_config('app.audit_reason', v_reason, true);
  insert into public.loan_schedule_versions
    (id, entity_id, loan_id, version_no, status, method, rate, installments, step_months, effective_from, principal_basis,
     maturity_date, reason, activated_at, created_by, rate_steps)
  values
    (v_id, l.entity_id, l.id, v_no, 'active', v.method, v.rate, jsonb_array_length(v_rows), v.step_months, greatest(v_today, v_last),
     v_outstanding, (select max((x ->> 'due_date')::date) from jsonb_array_elements(v_rows) x), v_reason, now(), auth.uid(), v_steps);
  insert into public.loan_schedule_items (entity_id, loan_id, version_id, seq, due_date, principal_due, interest_due, fee_due)
  select l.entity_id, l.id, v_id, (x ->> 'seq')::integer, (x ->> 'due_date')::date, (x ->> 'principal')::numeric,
         (x ->> 'interest')::numeric, (x ->> 'fee')::numeric
  from jsonb_array_elements(v_rows) x;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (l.entity_id, 'LoanRateChanged', 'loan', l.id,
          jsonb_build_object('number', l.loan_number, 'version', v_no, 'from', p_from, 'rate', trim_scale(v_rate)::text));
  perform app_private.idem_complete('loan.change_rate', l.entity_id, p_key, 'loan_schedule_versions', v_id);
  return v_id;
end
$$;


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
        'principal_basis', v.principal_basis::text, 'maturity_date', v.maturity_date, 'reason', v.reason,
        'rate_steps', v.rate_steps)
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

revoke all on function app_private.loan_rate_steps_arg(jsonb, date) from public;
revoke all on function app_private.loan_rate_on(numeric, jsonb, date) from public;
revoke all on function app_private.loan_plan(text, numeric, numeric, integer, integer, date, integer, jsonb) from public;
revoke all on function app_private.loan_schedule_rows(text, numeric, numeric, integer, integer, date, jsonb, integer, date, jsonb) from public;
revoke all on function app_private.loan_write_version(uuid, integer, text, text, numeric, integer, integer, date, jsonb, numeric, date, date, text, jsonb) from public;
revoke all on function public.loan_create(uuid, text, text, text, uuid, text, text, date, text, text, text, integer, integer, date, jsonb, uuid, uuid, text, jsonb) from public, anon;
revoke all on function public.loan_restructure(uuid, text, date, text, text, integer, integer, date, jsonb, text, jsonb) from public, anon;
revoke all on function public.loan_change_rate(uuid, text, date, text, text) from public, anon;
grant execute on function public.loan_create(uuid, text, text, text, uuid, text, text, date, text, text, text, integer, integer, date, jsonb, uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.loan_restructure(uuid, text, date, text, text, integer, integer, date, jsonb, text, jsonb) to authenticated;
grant execute on function public.loan_change_rate(uuid, text, date, text, text) to authenticated;

-- Every internal function pins its search_path (decision 314).
alter function app_private.loan_rate_steps_arg(jsonb, date) set search_path = pg_catalog, public;
alter function app_private.loan_rate_on(numeric, jsonb, date) set search_path = pg_catalog, public;
alter function app_private.loan_plan(text, numeric, numeric, integer, integer, date, integer, jsonb) set search_path = pg_catalog, public;
alter function app_private.loan_schedule_rows(text, numeric, numeric, integer, integer, date, jsonb, integer, date, jsonb) set search_path = pg_catalog, public;
alter function app_private.loan_write_version(uuid, integer, text, text, numeric, integer, integer, date, jsonb, numeric, date, date, text, jsonb) set search_path = pg_catalog, public;
