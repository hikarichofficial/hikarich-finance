-- P27: "Rekening Koran" (bank-statement style monthly view) of the cash and bank accounts, built from the posted
-- journal (Owner request, 7 October 2026: follow money in and out month by month, in pages when long).
-- One read-only call returns everything a screen needs: the opening balance of the chosen month, its total in
-- and out, the closing balance, one page of the month's lines with a running balance, and a 12-month overview.
-- "Masuk" is the debit side of a cash/bank account and "Keluar" the credit side, in base currency.
-- p_financial_account null = all cash/bank accounts of the Entity together. Needs accounting.view, the same
-- permission as the journal screens. Only posted journals count.

create function public.cash_statement(
  p_entity uuid, p_financial_account uuid default null, p_month date default null,
  p_limit integer default 25, p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_ledgers uuid[];
  v_start date;
  v_end date;
  v_last date;
  v_open numeric;
  v_in numeric;
  v_out numeric;
  v_total integer;
  v_rows jsonb;
  v_months jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'accounting.view') then
    raise exception 'FORBIDDEN: missing accounting.view' using errcode = 'insufficient_privilege';
  end if;
  if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset < 0 then
    raise exception 'INVALID: page size must be 1-100 and the offset not negative' using errcode = 'invalid_parameter_value';
  end if;
  if p_financial_account is not null and not exists (
    select 1 from public.financial_accounts where id = p_financial_account and entity_id = p_entity) then
    raise exception 'NOT_FOUND: unknown cash or bank account of this Entity' using errcode = 'no_data_found';
  end if;

  select coalesce(array_agg(fa.ledger_account_id), '{}') into v_ledgers
    from public.financial_accounts fa
    where fa.entity_id = p_entity and (p_financial_account is null or fa.id = p_financial_account);

  v_start := date_trunc('month', coalesce(p_month, current_date))::date;
  v_end := (v_start + interval '1 month - 1 day')::date;
  v_last := greatest(v_start, date_trunc('month', current_date)::date);

  -- Posted lines of the chosen accounts up to the end of the chosen month (opening, totals and the page).
  select coalesce(sum(case when j.entry_date < v_start then ln.debit - ln.credit end), 0),
         coalesce(sum(case when j.entry_date >= v_start then ln.debit end), 0),
         coalesce(sum(case when j.entry_date >= v_start then ln.credit end), 0),
         count(*) filter (where j.entry_date >= v_start)
    into v_open, v_in, v_out, v_total
    from public.journal_lines ln
    join public.journal_entries j on j.id = ln.journal_id and j.entity_id = ln.entity_id
    where ln.entity_id = p_entity and j.status = 'posted' and ln.ledger_account_id = any (v_ledgers)
      and j.entry_date <= v_end;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.rn), '[]'::jsonb) into v_rows
  from (
    select q.rn, to_char(q.entry_date, 'YYYY-MM-DD') as entry_date, q.journal_id, q.journal_number,
           q.descr as description, q.account_name, q.debit::text as masuk, q.credit::text as keluar,
           q.balance::text as saldo
    from (
      select row_number() over w as rn, j.entry_date, j.id as journal_id, j.journal_number,
             coalesce(nullif(btrim(ln.description), ''), j.description) as descr, fa.name as account_name,
             ln.debit, ln.credit,
             v_open + sum(ln.debit - ln.credit) over (w rows between unbounded preceding and current row) as balance
      from public.journal_lines ln
      join public.journal_entries j on j.id = ln.journal_id and j.entity_id = ln.entity_id
      join public.financial_accounts fa on fa.ledger_account_id = ln.ledger_account_id and fa.entity_id = ln.entity_id
      where ln.entity_id = p_entity and j.status = 'posted' and ln.ledger_account_id = any (v_ledgers)
        and j.entry_date >= v_start and j.entry_date <= v_end
      window w as (order by j.entry_date, j.created_at, ln.line_no, j.id)
    ) q
    where q.rn > p_offset and q.rn <= p_offset + p_limit
  ) x;

  -- 12-month overview ending at the later of the chosen month and the current month.
  with a as (
    select j.entry_date, ln.debit, ln.credit
    from public.journal_lines ln
    join public.journal_entries j on j.id = ln.journal_id and j.entity_id = ln.entity_id
    where ln.entity_id = p_entity and j.status = 'posted' and ln.ledger_account_id = any (v_ledgers)
  ), months as (
    select g.m::date as m from generate_series((v_last - interval '11 months')::date, v_last, interval '1 month') as g(m)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'month', to_char(months.m, 'YYYY-MM-DD'),
           'masuk', (select coalesce(sum(a.debit), 0) from a where a.entry_date >= months.m and a.entry_date < months.m + interval '1 month')::text,
           'keluar', (select coalesce(sum(a.credit), 0) from a where a.entry_date >= months.m and a.entry_date < months.m + interval '1 month')::text,
           'saldo_akhir', (select coalesce(sum(a.debit - a.credit), 0) from a where a.entry_date < months.m + interval '1 month')::text)
         order by months.m), '[]'::jsonb)
    into v_months
    from months;

  return jsonb_build_object(
    'month_start', to_char(v_start, 'YYYY-MM-DD'),
    'month_end', to_char(v_end, 'YYYY-MM-DD'),
    'opening', v_open::text, 'total_in', v_in::text, 'total_out', v_out::text,
    'closing', (v_open + v_in - v_out)::text,
    'total_rows', v_total, 'rows', v_rows, 'months', v_months);
end
$$;

revoke all on function public.cash_statement(uuid, uuid, date, integer, integer) from public, anon;
grant execute on function public.cash_statement(uuid, uuid, date, integer, integer) to authenticated;
