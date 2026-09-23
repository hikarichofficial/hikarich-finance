-- P12 (Step 15 Phase 12, Step 12 §3-§5, §17, §31): canonical financial statement services.
-- Authority: Step 12 (Reports Architecture). Reuses P3's trial_balance and P5/P6's ar_aging/ap_aging
-- (Step 12 Table 1: "Reports never invent a second financial truth") rather than duplicating them; adds
-- Profit & Loss, Balance Sheet, Statement of Changes in Equity, Cash Flow Statement and a General Ledger
-- drill-down. Every function reads posted data only (Step 12 §2) and is gated by `reports.view` (already
-- catalogued in P2), never a new permission, matching decision #5's mapping of Step 12 onto P12.
--
-- Every statement below returns raw `debit`/`credit` (or, for a computed line with no ledger postings of
-- its own, an equivalent net pair) as exact decimal text, exactly like `trial_balance` (Step 13 §25: money
-- crosses the API as text, never a JSON number). This deliberately never multiplies by a per-account sign
-- convention inside the database: which side is "the natural, positive reading" for a given account_class
-- is a presentation rule, applied once in `src/domain/reports` (never duplicated per statement here), and
-- keeping every function on the same debit/credit shape as `trial_balance` is what makes that possible.

-- ------------------------------------------------------------ Profit & Loss (Step 12 §3, Table 2)
-- Each row is the account's own debit/credit movement inside the period (not cumulative: a P&L is a
-- flow, not a balance). An optional comparison period returns a second debit/credit pair.
create function public.profit_and_loss(
  p_entity uuid, p_start date, p_end date, p_compare_start date default null, p_compare_end date default null)
returns table (account_id uuid, code text, name text, account_class text, parent_id uuid,
               debit text, credit text, compare_debit text, compare_credit text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'reports.view') then
    raise exception 'FORBIDDEN: missing reports.view' using errcode = 'insufficient_privilege';
  end if;
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'INVALID: a Profit & Loss needs a valid start and end date' using errcode = 'invalid_parameter_value';
  end if;
  if (p_compare_start is null) <> (p_compare_end is null) or (p_compare_end is not null and p_compare_end < p_compare_start) then
    raise exception 'INVALID: the comparison period needs both a valid start and end date' using errcode = 'invalid_parameter_value';
  end if;

  return query
  select a.id, a.code, a.name, a.account_class, a.parent_id,
         coalesce(sum(l.debit) filter (where j.entry_date between p_start and p_end), 0)::text,
         coalesce(sum(l.credit) filter (where j.entry_date between p_start and p_end), 0)::text,
         case when p_compare_start is null then null
           else coalesce(sum(l.debit) filter (where j.entry_date between p_compare_start and p_compare_end), 0)::text end,
         case when p_compare_start is null then null
           else coalesce(sum(l.credit) filter (where j.entry_date between p_compare_start and p_compare_end), 0)::text end
  from public.ledger_accounts a
  left join public.journal_lines l on l.ledger_account_id = a.id and l.entity_id = a.entity_id
  left join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
    and j.status = 'posted' and j.entry_type <> 'closing'
    and (j.entry_date between p_start and p_end
         or (p_compare_start is not null and j.entry_date between p_compare_start and p_compare_end))
  where a.entity_id = p_entity and not a.is_group
    and a.account_class in ('revenue', 'contra_revenue', 'other_income', 'expense', 'other_expense', 'other', 'tax')
  group by a.id, a.code, a.name, a.account_class, a.parent_id
  having coalesce(sum(l.debit) filter (where j.entry_date between p_start and p_end), 0) <> 0
      or coalesce(sum(l.credit) filter (where j.entry_date between p_start and p_end), 0) <> 0
      or (p_compare_start is not null and (
            coalesce(sum(l.debit) filter (where j.entry_date between p_compare_start and p_compare_end), 0) <> 0
            or coalesce(sum(l.credit) filter (where j.entry_date between p_compare_start and p_compare_end), 0) <> 0))
  order by code;
end
$$;

-- ------------------------------------------------------------ Balance Sheet (Step 12 §4, Table 2, Table 9)
-- Balance-sheet-class accounts carry their real cumulative posted debit/credit (same method as
-- trial_balance). "Current Year Earnings" is never a posted balance (Step 12 §4: "derives from accounting
-- architecture rather than duplicated manual balances"): it is always the live cumulative net of every
-- P&L-class account as of the same date, expressed as the equivalent debit/credit pair. That live figure
-- is exactly the not-yet-closed remainder once a fiscal year's closing journal has run
-- (20260930200000_p12_year_end_closing.sql), and the full year-to-date result before it has, because a
-- closing journal is itself made of P&L-class debits/credits that this same cumulative sum already
-- includes. The real CURRENT_YEAR_EARNINGS placeholder account (company COA only, Step 03 §3) is excluded
-- from the plain balance pass below and replaced by this computed row under the same account identity, so
-- it keeps the label and code the OWNER already sees on the COA and still drills into the P&L.
create function public.balance_sheet(p_entity uuid, p_as_of date default null)
returns table (account_id uuid, code text, name text, account_class text, parent_id uuid, debit text, credit text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_as_of date := coalesce(p_as_of, current_date);
  v_cye_id uuid;
  v_cye_code text;
  v_cye_name text;
  v_pl_debit numeric(20, 4);
  v_pl_credit numeric(20, 4);
  v_pl_net numeric(20, 4);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'reports.view') then
    raise exception 'FORBIDDEN: missing reports.view' using errcode = 'insufficient_privilege';
  end if;

  select a.id, a.code, a.name into v_cye_id, v_cye_code, v_cye_name
  from public.ledger_accounts a where a.entity_id = p_entity and a.system_key = 'CURRENT_YEAR_EARNINGS';

  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0) into v_pl_debit, v_pl_credit
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts la on la.id = l.ledger_account_id and la.entity_id = l.entity_id
  where l.entity_id = p_entity and j.status = 'posted' and j.entry_date <= v_as_of
    and la.account_class in ('revenue', 'contra_revenue', 'other_income', 'expense', 'other_expense', 'other', 'tax');
  v_pl_net := v_pl_credit - v_pl_debit;

  return query
  select a.id, a.code, a.name, a.account_class, a.parent_id,
         coalesce(sum(l.debit), 0)::text, coalesce(sum(l.credit), 0)::text
  from public.ledger_accounts a
  left join public.journal_lines l on l.ledger_account_id = a.id and l.entity_id = a.entity_id
  left join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
    and j.status = 'posted' and j.entry_date <= v_as_of
  where a.entity_id = p_entity and not a.is_group
    and a.account_class in ('asset', 'contra_asset', 'liability', 'equity')
    and a.id is distinct from v_cye_id
  group by a.id, a.code, a.name, a.account_class, a.parent_id
  union all
  select coalesce(v_cye_id, gen_random_uuid()), coalesce(v_cye_code, '3400'),
         coalesce(v_cye_name, 'Current Year Earnings'), 'equity', null,
         greatest(-v_pl_net, 0)::text, greatest(v_pl_net, 0)::text
  order by code;
end
$$;

-- ------------------------------------------------------------ Statement of Changes in Equity (Table 2)
-- "Opening equity + contributions/distributions + profit/loss + adjustments = closing equity": one row per
-- equity-class account (opening/period movement/closing debit and credit, same cumulative method as
-- Balance Sheet) plus one computed row for the period's own net result (never a posted balance, same
-- derivation as the Balance Sheet's Current Year Earnings line).
create function public.statement_of_changes_in_equity(p_entity uuid, p_start date, p_end date)
returns table (account_id uuid, code text, name text,
               opening_debit text, opening_credit text, period_debit text, period_credit text,
               closing_debit text, closing_credit text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_net_debit numeric(20, 4);
  v_net_credit numeric(20, 4);
  v_net numeric(20, 4);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'reports.view') then
    raise exception 'FORBIDDEN: missing reports.view' using errcode = 'insufficient_privilege';
  end if;
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'INVALID: a Statement of Changes in Equity needs a valid start and end date' using errcode = 'invalid_parameter_value';
  end if;

  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0) into v_net_debit, v_net_credit
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts la on la.id = l.ledger_account_id and la.entity_id = l.entity_id
  where l.entity_id = p_entity and j.status = 'posted' and j.entry_date between p_start and p_end
    and la.account_class in ('revenue', 'contra_revenue', 'other_income', 'expense', 'other_expense', 'other', 'tax');
  v_net := v_net_credit - v_net_debit;

  return query
  select a.id, a.code, a.name,
         coalesce(sum(l.debit) filter (where j.entry_date < p_start), 0)::text,
         coalesce(sum(l.credit) filter (where j.entry_date < p_start), 0)::text,
         coalesce(sum(l.debit) filter (where j.entry_date between p_start and p_end), 0)::text,
         coalesce(sum(l.credit) filter (where j.entry_date between p_start and p_end), 0)::text,
         coalesce(sum(l.debit) filter (where j.entry_date <= p_end), 0)::text,
         coalesce(sum(l.credit) filter (where j.entry_date <= p_end), 0)::text
  from public.ledger_accounts a
  left join public.journal_lines l on l.ledger_account_id = a.id and l.entity_id = a.entity_id
  left join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id and j.status = 'posted'
    and j.entry_date <= p_end
  where a.entity_id = p_entity and not a.is_group and a.account_class = 'equity'
  group by a.id, a.code, a.name
  union all
  select null, null, 'Net result for the period', '0', '0',
         greatest(-v_net, 0)::text, greatest(v_net, 0)::text,
         greatest(-v_net, 0)::text, greatest(v_net, 0)::text
  order by code nulls last;
end
$$;

-- ------------------------------------------------------------ Cash Flow Statement (Step 12 §5, Table 2, Table 9)
-- Direct method from money_movements (Step 04 §13: the authoritative cash layer), which already excludes
-- non-cash journals by construction. Internal transfers between the Entity's own accounts net to zero on
-- their own once summed across every account (an 'out' and an 'in' of the same amount), so no separate
-- exclusion is needed for the total; they are still bucketed under 'financing' so a transfer never
-- inflates the operating/investing subtotal. Opening-balance migration movements (component = 'opening')
-- are excluded: they are not period cash flow, they are Step 03 §9 cutover data.
--
-- Classification is source_type-driven (documented limitation, DECISIONS): an asset acquisition paid by a
-- direct expense is traced to Investing via `expense_lines.treatment = 'asset'`; the same acquisition paid
-- by settling a vendor bill is traced the same way through the payment's bill allocations. A payment that
-- mixes an asset-treatment bill line with ordinary operating lines is classified Investing as a whole,
-- since a single cash movement cannot be split below the payment it settles.
create function public.cash_flow_statement(p_entity uuid, p_start date, p_end date)
returns table (bucket text, amount text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'reports.view') then
    raise exception 'FORBIDDEN: missing reports.view' using errcode = 'insufficient_privilege';
  end if;
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'INVALID: a Cash Flow Statement needs a valid start and end date' using errcode = 'invalid_parameter_value';
  end if;

  return query
  with classified as (
    select mm.*, case
      when mm.source_type in ('transfer', 'loan_payment', 'equity_event', 'dividend_payment') then 'financing'
      when mm.source_type = 'asset_disposal' then 'investing'
      when mm.source_type = 'expense' and exists (
        select 1 from public.expense_lines el where el.entity_id = mm.entity_id and el.expense_id = mm.source_id and el.treatment = 'asset'
      ) then 'investing'
      when mm.source_type = 'bill_payment' and exists (
        select 1 from public.vendor_payment_allocations vpa
        join public.bill_lines bl on bl.entity_id = vpa.entity_id and bl.bill_id = vpa.bill_id
        where vpa.entity_id = mm.entity_id and vpa.payment_id = mm.source_id and bl.treatment = 'asset'
      ) then 'investing'
      else 'operating'
    end as category
    from public.money_movements mm
    where mm.entity_id = p_entity and mm.component <> 'opening'
  )
  select 'opening_cash', coalesce(sum(case when direction = 'in' then base_amount else -base_amount end), 0)::text
  from classified where movement_date < p_start
  union all
  select category, coalesce(sum(case when direction = 'in' then base_amount else -base_amount end), 0)::text
  from classified where movement_date between p_start and p_end
  group by category
  union all
  select 'closing_cash', coalesce(sum(case when direction = 'in' then base_amount else -base_amount end), 0)::text
  from classified where movement_date <= p_end;
end
$$;

-- ------------------------------------------------------------ General Ledger drill-down (Step 12 §17)
-- Statement line -> account(s) -> journal lines -> source transaction. p_account null returns every
-- non-group account's posted lines in the range (a "Journal Report" view); a specific account additionally
-- gets a running balance in its own natural direction (a "General Ledger" card).
create function public.general_ledger(p_entity uuid, p_account uuid default null, p_start date default null, p_end date default null)
returns table (account_id uuid, code text, name text, entry_date date, journal_id uuid, journal_number text,
               entry_type text, description text, source_type text, source_id uuid,
               debit text, credit text, running_balance text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'reports.view') then
    raise exception 'FORBIDDEN: missing reports.view' using errcode = 'insufficient_privilege';
  end if;
  if p_account is not null and not exists (
    select 1 from public.ledger_accounts where id = p_account and entity_id = p_entity) then
    raise exception 'NOT_FOUND: unknown account of this Entity' using errcode = 'no_data_found';
  end if;

  return query
  select a.id, a.code, a.name, j.entry_date, j.id, j.journal_number, j.entry_type, j.description,
         j.source_type, j.source_id, l.debit::text, l.credit::text,
         (sum(case when a.normal_balance = 'debit' then l.debit - l.credit else l.credit - l.debit end)
            over (partition by a.id order by j.entry_date, j.created_at, l.line_no))::text
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and j.status = 'posted'
    and (p_account is null or a.id = p_account)
    and (p_start is null or j.entry_date >= p_start)
    and (p_end is null or j.entry_date <= p_end)
  order by a.code, j.entry_date, j.created_at, l.line_no;
end
$$;

revoke all on function public.profit_and_loss(uuid, date, date, date, date) from public, anon;
revoke all on function public.balance_sheet(uuid, date) from public, anon;
revoke all on function public.statement_of_changes_in_equity(uuid, date, date) from public, anon;
revoke all on function public.cash_flow_statement(uuid, date, date) from public, anon;
revoke all on function public.general_ledger(uuid, uuid, date, date) from public, anon;
grant execute on function public.profit_and_loss(uuid, date, date, date, date) to authenticated;
grant execute on function public.balance_sheet(uuid, date) to authenticated;
grant execute on function public.statement_of_changes_in_equity(uuid, date, date) to authenticated;
grant execute on function public.cash_flow_statement(uuid, date, date) to authenticated;
grant execute on function public.general_ledger(uuid, uuid, date, date) to authenticated;
