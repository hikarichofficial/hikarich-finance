-- P8 final controls (Step 15 §12, Step 16 §16-17): the financing control, the tax-review command for the financing
-- events, and the period close with the asset / loan / other receivable and payable / equity checks.

-- ------------------------------------------------------------ financing control
-- Each sub-ledger against its control account in the General Ledger, as of a date (Step 04 §13). Loans and
-- other receivables/payables and dividends payable are control accounts: nothing but their workflows may post to them,
-- so the comparison is against the whole ledger balance.
create function app_private.financing_control(p_entity uuid, p_as_of date default null)
returns table (account_key text, sub_ledger numeric, ledger_total numeric)
language plpgsql stable as $$
declare
  v_asof date := coalesce(p_as_of, app_private.entity_today(p_entity));
  a record;
begin
  for a in select x.id, x.system_key from public.ledger_accounts x
           where x.entity_id = p_entity and x.system_key in ('LOAN_SHORT_TERM', 'LOAN_LONG_TERM', 'PERSONAL_LOAN')
           order by x.system_key loop
    account_key := a.system_key;
    sub_ledger := app_private.loans_total(p_entity, 'borrowed', v_asof, a.id);
    ledger_total := app_private.account_balance(p_entity, a.id, v_asof);
    return next;
  end loop;

  for a in select x.id, x.system_key from public.ledger_accounts x
           where x.entity_id = p_entity and x.system_key = 'OTHER_RECEIVABLE' loop
    account_key := a.system_key;
    sub_ledger := app_private.loans_total(p_entity, 'lent', v_asof) + app_private.obligations_total(p_entity, 'receivable', v_asof);
    ledger_total := app_private.account_balance(p_entity, a.id, v_asof);
    return next;
  end loop;

  for a in select x.id, x.system_key from public.ledger_accounts x
           where x.entity_id = p_entity and x.system_key = 'OTHER_PAYABLE' loop
    account_key := a.system_key;
    sub_ledger := app_private.obligations_total(p_entity, 'payable', v_asof);
    ledger_total := app_private.account_balance(p_entity, a.id, v_asof);
    return next;
  end loop;

  for a in select x.id, x.system_key from public.ledger_accounts x
           where x.entity_id = p_entity and x.system_key = 'DIVIDEND_PAYABLE' loop
    account_key := a.system_key;
    sub_ledger := app_private.dividends_payable_total(p_entity, v_asof);
    ledger_total := app_private.account_balance(p_entity, a.id, v_asof);
    return next;
  end loop;
end
$$;

create function public.financing_control_report(p_entity uuid, p_as_of date default null)
returns table (account_key text, sub_ledger text, ledger_total text, difference text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'accounting.view') or not app_authz.has_permission(p_entity, 'loans.view')
     or not app_authz.has_permission(p_entity, 'equity.view') then
    raise exception 'FORBIDDEN: the financing control needs accounting.view, loans.view and equity.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select c.account_key, c.sub_ledger::text, c.ledger_total::text, (c.sub_ledger - c.ledger_total)::text
  from app_private.financing_control(p_entity, p_as_of) c
  order by c.account_key;
end
$$;

-- ------------------------------------------------------------ tax review of the financing events
-- What is waiting for a tax decision (loan interest, write-offs, dividends, capital returns).
create function public.financing_tax_reviews(p_entity uuid)
returns table (source_type text, source_id uuid, document_number text, event_date date, amount text, description text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select * from (
    select 'obligation_settlement'::text, s.id, s.settlement_number, s.settlement_date,
           (s.principal + s.interest + s.fee)::text,
           ('Other ' || o.kind || ' ' || s.kind)::text
    from public.other_obligation_settlements s
    join public.other_obligations o on o.id = s.obligation_id and o.entity_id = s.entity_id
    where s.entity_id = p_entity and s.status = 'active' and s.tax_status = 'needs_review'
    union all
    select 'loan_payment'::text, p.id, p.payment_number, p.payment_date,
           (p.principal + p.interest + p.fee)::text,
           (case p.kind when 'write_off' then 'Loan write-off' else 'Loan repayment' end)::text
    from public.loan_payments p
    where p.entity_id = p_entity and p.status = 'active' and p.tax_status = 'needs_review'
    union all
    select 'equity_event'::text, e.id, e.event_number, e.event_date, e.amount::text, e.kind::text
    from public.equity_events e
    where e.entity_id = p_entity and e.status = 'confirmed' and e.tax_status = 'needs_review'
    union all
    select 'dividend_payment'::text, d.id, d.payment_number, d.payment_date, d.amount::text, 'Dividend payment'::text
    from public.equity_dividend_payments d
    where d.entity_id = p_entity and d.status = 'active' and d.tax_status = 'needs_review'
  ) q
  order by 4, 3;
end
$$;

-- A person with tax.confirm_facts records that the tax treatment was looked at, and what was concluded. Nothing is
-- computed or posted: the tax decision itself stays with the person (and the adviser).
create function public.financing_tax_review(p_entity uuid, p_source text, p_id uuid, p_note text)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_note text := btrim(coalesce(p_note, ''));
  v_status text;
  v_n integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.confirm_facts') then
    raise exception 'FORBIDDEN: missing tax.confirm_facts' using errcode = 'insufficient_privilege';
  end if;
  if p_source is null or p_source not in ('obligation_settlement', 'loan_payment', 'equity_event', 'dividend_payment') then
    raise exception 'INVALID: unknown source' using errcode = 'invalid_parameter_value';
  end if;
  if length(v_note) < 5 or length(v_note) > 1000 then
    raise exception 'INVALID: write what was concluded (5 to 1000 characters)' using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('app.audit_reason', 'tax review of a financing event', true);

  if p_source = 'obligation_settlement' then
    select tax_status into v_status from public.other_obligation_settlements where id = p_id and entity_id = p_entity for update;
  elsif p_source = 'loan_payment' then
    select tax_status into v_status from public.loan_payments where id = p_id and entity_id = p_entity for update;
  elsif p_source = 'equity_event' then
    select tax_status into v_status from public.equity_events where id = p_id and entity_id = p_entity for update;
  else
    select tax_status into v_status from public.equity_dividend_payments where id = p_id and entity_id = p_entity for update;
  end if;
  if not found then
    raise exception 'INVALID: unknown record' using errcode = 'invalid_parameter_value';
  end if;
  if v_status <> 'needs_review' then
    raise exception 'CONFLICT: this record has no tax review pending (%)', v_status using errcode = 'invalid_parameter_value';
  end if;

  if p_source = 'obligation_settlement' then
    update public.other_obligation_settlements
    set tax_status = 'reviewed', tax_reviewed_at = now(), tax_reviewed_by = auth.uid(), tax_note = v_note where id = p_id;
  elsif p_source = 'loan_payment' then
    update public.loan_payments
    set tax_status = 'reviewed', tax_reviewed_at = now(), tax_reviewed_by = auth.uid(), tax_note = v_note where id = p_id;
  elsif p_source = 'equity_event' then
    update public.equity_events
    set tax_status = 'reviewed', tax_reviewed_at = now(), tax_reviewed_by = auth.uid(), tax_note = v_note where id = p_id;
  else
    update public.equity_dividend_payments
    set tax_status = 'reviewed', tax_reviewed_at = now(), tax_reviewed_by = auth.uid(), tax_note = v_note where id = p_id;
  end if;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CONFLICT: the record changed, try again' using errcode = 'invalid_parameter_value';
  end if;
end
$$;

-- ------------------------------------------------------------ rule shape: the fiscal depreciation groups
-- Re-emitted from P7 with one more family: a published version of the groups is read by every asset registration, so its
-- shape is checked like the other rule families' (the seeded version already satisfies it).
create or replace function app_private.tax_rule_params_problem(p_family text, p_params jsonb) returns text
language plpgsql stable as $$
declare
  v_num numeric;
  v_den numeric;
  v_x jsonb;
  v_key text;
begin
  if jsonb_typeof(p_params) is distinct from 'object' then
    return 'the parameters must be a JSON object';
  end if;
  if p_family in ('ppn', 'pph23', 'pph_final_umkm') then
    if jsonb_typeof(p_params -> 'rounding') is distinct from 'object'
       or coalesce(p_params -> 'rounding' ->> 'mode', '') not in ('half_up', 'half_even', 'down', 'up')
       or coalesce(p_params -> 'rounding' ->> 'scale', '') !~ '^[0-4]$' then
      return 'rounding needs a mode (half_up, half_even, down, up) and a scale from 0 to 4';
    end if;
    if coalesce(p_params ->> 'rate', '') !~ '^0\.[0-9]{1,6}$' or (p_params ->> 'rate')::numeric <= 0 then
      return 'rate must be a decimal string between 0 and 1, for example "0.12"';
    end if;
  end if;
  if p_family = 'ppn' then
    if coalesce(p_params ->> 'dpp_numerator', '') !~ '^[1-9][0-9]{0,3}$'
       or coalesce(p_params ->> 'dpp_denominator', '') !~ '^[1-9][0-9]{0,3}$' then
      return 'dpp_numerator and dpp_denominator must be positive whole numbers';
    end if;
    v_num := (p_params ->> 'dpp_numerator')::numeric;
    v_den := (p_params ->> 'dpp_denominator')::numeric;
    if v_num > v_den then
      return 'the DPP factor cannot exceed 1';
    end if;
  elsif p_family = 'pph23' then
    if coalesce(p_params ->> 'non_npwp_multiplier', '') !~ '^[1-9](\.[0-9]{1,2})?$' then
      return 'non_npwp_multiplier must be a decimal string of at least 1, for example "2"';
    end if;
    if jsonb_typeof(p_params -> 'objects') is distinct from 'array' or jsonb_array_length(p_params -> 'objects') = 0 then
      return 'objects must list the withholding objects this rule covers';
    end if;
    for v_x in select * from jsonb_array_elements(p_params -> 'objects') loop
      v_key := case when jsonb_typeof(v_x) = 'string' then v_x #>> '{}' end;
      if v_key is null or not exists (select 1 from public.tax_treatment_catalog c
                                      where c.treatment_key = v_key and c.side = 'purchase_wht')
         or v_key in ('wht_none', 'wht_review') then
        return format('unknown or non-taxable withholding object %s', coalesce(v_key, v_x::text));
      end if;
    end loop;
  elsif p_family = 'pph_final_umkm' then
    if coalesce(p_params ->> 'annual_ceiling', '') !~ '^[1-9][0-9]{0,15}$' then
      return 'annual_ceiling must be a whole-number string';
    end if;
    if jsonb_typeof(p_params -> 'eligible_kinds') is distinct from 'array'
       or jsonb_array_length(p_params -> 'eligible_kinds') = 0 then
      return 'eligible_kinds must list the taxpayer kinds the regime covers';
    end if;
    for v_x in select * from jsonb_array_elements(p_params -> 'eligible_kinds') loop
      if jsonb_typeof(v_x) <> 'string'
         or (v_x #>> '{}') not in ('individual', 'perseroan_perorangan', 'company', 'cooperative', 'other') then
        return format('unknown taxpayer kind %s in eligible_kinds', v_x::text);
      end if;
    end loop;
    if jsonb_typeof(p_params -> 'exempt_band') is distinct from 'object' then
      return 'exempt_band must be an object (taxpayer kind -> whole-number amount), possibly empty';
    end if;
    for v_key in select k from jsonb_object_keys(p_params -> 'exempt_band') as k loop
      if v_key not in ('individual', 'perseroan_perorangan', 'company', 'cooperative', 'other')
         or coalesce(p_params -> 'exempt_band' ->> v_key, '') !~ '^[1-9][0-9]{0,15}$' then
        return format('invalid exempt band for %s', v_key);
      end if;
    end loop;
  elsif p_family = 'deadline' then
    for v_key in select unnest(array['payment', 'filing']) loop
      v_x := p_params -> v_key;
      if jsonb_typeof(v_x) is distinct from 'object' then
        return format('%s must describe the deadline', v_key);
      end if;
      if coalesce(v_x ->> 'month_offset', '') !~ '^[0-3]$' then
        return format('%s.month_offset must be 0 to 3 months after the tax period', v_key);
      end if;
      if not ((coalesce(v_x ->> 'eom', '') = 'true')
              or coalesce(v_x ->> 'day', '') ~ '^([1-9]|[12][0-9]|3[01])$') then
        return format('%s needs a day of the month (1 to 31) or "eom": true', v_key);
      end if;
    end loop;
  elsif p_family = 'fiscal_depreciation' then
    -- The statutory groups of Art. 11 UU PPh (P8): what asset registration and the fiscal schedule read.
    if coalesce(p_params ->> 'first_year', '') <> 'prorate_months_from_acquisition_month' then
      return 'first_year must be "prorate_months_from_acquisition_month"';
    end if;
    if jsonb_typeof(p_params -> 'classes') is distinct from 'array' or jsonb_array_length(p_params -> 'classes') not between 1 and 30 then
      return 'classes must list the depreciation groups';
    end if;
    for v_x in select * from jsonb_array_elements(p_params -> 'classes') loop
      if jsonb_typeof(v_x) is distinct from 'object' or coalesce(v_x ->> 'key', '') !~ '^[a-z][a-z0-9_]{1,40}$'
         or length(btrim(coalesce(v_x ->> 'name', ''))) not between 1 and 100
         or jsonb_typeof(v_x -> 'building') is distinct from 'boolean' or jsonb_typeof(v_x -> 'depreciable') is distinct from 'boolean' then
        return 'each group needs a key, a name, and building and depreciable flags';
      end if;
      if (v_x ->> 'depreciable')::boolean then
        if coalesce(v_x ->> 'life_years', '') !~ '^[1-9][0-9]{0,2}$'
           or coalesce(v_x ->> 'sl_rate', '') !~ '^0\.[0-9]{1,6}$' or (v_x ->> 'sl_rate')::numeric <= 0
           or (jsonb_typeof(v_x -> 'db_rate') is distinct from 'null'
               and (coalesce(v_x ->> 'db_rate', '') !~ '^0\.[0-9]{1,6}$' or (v_x ->> 'db_rate')::numeric <= 0)) then
          return format('the group %s needs a life in years, a straight-line rate and a declining-balance rate (or null)', v_x ->> 'key');
        end if;
        if (v_x ->> 'building')::boolean and jsonb_typeof(v_x -> 'db_rate') is distinct from 'null' then
          return format('the building group %s allows straight-line only', v_x ->> 'key');
        end if;
      end if;
    end loop;
    if (select count(distinct c ->> 'key') from jsonb_array_elements(p_params -> 'classes') c) <> jsonb_array_length(p_params -> 'classes') then
      return 'the group keys must be unique';
    end if;
  end if;
  return null;
end
$$;

-- ------------------------------------------------------------ the period close, with the P8 checks
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
  -- ---- P8: fixed assets, financing and equity (Step 15 §12, Step 16 §16-17)
  -- The asset register (cost and accumulated depreciation) against the General Ledger, as of the end of the period.
  select count(*) into v_n from app_private.asset_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_total;
  if v_n > 0 then
    return query select 'asset_ledger_mismatch'::text, 'blocker'::text,
      'The fixed asset register differs from the fixed asset accounts in the General Ledger'::text, v_n;
  end if;

  -- Loans, other receivables/payables and dividends payable against their control accounts.
  select count(*) into v_n from app_private.financing_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_total;
  if v_n > 0 then
    return query select 'financing_ledger_mismatch'::text, 'blocker'::text,
      'Loans, other receivables/payables or dividends payable differ from their accounts in the General Ledger'::text, v_n;
  end if;

  -- Depreciation of a month inside this period that is over but not posted: the expense would be missing from it.
  select count(*) into v_n
  from public.asset_depreciation_lines l
  join public.fixed_assets f on f.id = l.asset_id and f.entity_id = l.entity_id
  where l.entity_id = v_p.entity_id and l.status = 'scheduled' and f.status = 'active'
    and app_private.month_end(l.period_month) between v_p.period_start and v_p.period_end
    and app_private.month_end(l.period_month) < app_private.entity_today(v_p.entity_id);
  if v_n > 0 then
    return query select 'depreciation_not_posted'::text, 'blocker'::text,
      'Depreciation due in this period has not been posted'::text, v_n;
  end if;

  select count(*) into v_n from (
    select l.id from public.bill_lines l
    join public.bills b on b.id = l.bill_id and b.entity_id = l.entity_id
    where l.entity_id = v_p.entity_id and l.asset_link_status = 'pending' and b.status = 'approved'
      and b.bill_date between v_p.period_start and v_p.period_end
    union all
    select l.id from public.expense_lines l
    join public.expenses x on x.id = l.expense_id and x.entity_id = l.entity_id
    where l.entity_id = v_p.entity_id and l.asset_link_status = 'pending' and x.status = 'confirmed'
      and x.expense_date between v_p.period_start and v_p.period_end
  ) q;
  if v_n > 0 then
    return query select 'asset_lines_pending'::text, 'warning'::text,
      'Purchase lines booked as fixed assets in this period are not registered as assets yet'::text, v_n;
  end if;

  -- Loan installments due by the end of the period that are still unpaid (information: no interest is booked before it is paid).
  select count(*) into v_n
  from public.loans ln
  cross join lateral app_private.loan_items(ln.id, null, v_p.period_end) i
  where ln.entity_id = v_p.entity_id and ln.status = 'active' and ln.effective_date <= v_p.period_end
    and i.state <> 'paid' and i.due_date <= v_p.period_end;
  if v_n > 0 then
    return query select 'loan_installments_overdue'::text, 'warning'::text,
      'Loan installments due by the end of this period are unpaid'::text, v_n;
  end if;

  -- Interest, write-offs, dividends and capital returns have tax consequences the rules do not decide (DECISIONS 106).
  select (select count(*) from public.other_obligation_settlements s
          where s.entity_id = v_p.entity_id and s.status = 'active' and s.tax_status = 'needs_review'
            and s.settlement_date between v_p.period_start and v_p.period_end)
       + (select count(*) from public.loan_payments p
          where p.entity_id = v_p.entity_id and p.status = 'active' and p.tax_status = 'needs_review'
            and p.payment_date between v_p.period_start and v_p.period_end)
       + (select count(*) from public.equity_events e
          where e.entity_id = v_p.entity_id and e.status = 'confirmed' and e.tax_status = 'needs_review'
            and e.event_date between v_p.period_start and v_p.period_end)
       + (select count(*) from public.equity_dividend_payments d
          where d.entity_id = v_p.entity_id and d.status = 'active' and d.tax_status = 'needs_review'
            and d.payment_date between v_p.period_start and v_p.period_end)
    into v_n;
  if v_n > 0 then
    return query select 'financing_tax_review_pending'::text, 'warning'::text,
      'Loan interest, write-offs, dividends or capital returns of this period still need a tax review'::text, v_n;
  end if;
end
$$;

-- ------------------------------------------------------------ privileges
revoke all on function app_private.financing_control(uuid, date) from public;
revoke all on function app_private.period_blockers(uuid) from public;

revoke all on function public.financing_control_report(uuid, date) from public, anon;
revoke all on function public.financing_tax_reviews(uuid) from public, anon;
revoke all on function public.financing_tax_review(uuid, text, uuid, text) from public, anon;
grant execute on function public.financing_control_report(uuid, date) to authenticated;
grant execute on function public.financing_tax_reviews(uuid) to authenticated;
grant execute on function public.financing_tax_review(uuid, text, uuid, text) to authenticated;
