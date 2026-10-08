-- P38 (decision 352): income outside the PPh Final, shown on Ringkasan Pajak.
--
-- Interest, dividends, investment rent, investment yield, bonus and cashback, crypto, forex and other trading
-- results are booked in the 7xxx accounts and are kept out of the 0,5% final-tax base (decisions 344-345, 350).
-- Until now nothing showed them in a tax screen. `tax_non_final_income(entity, year)` reads the posted journals of a
-- calendar year and returns, per 7xxx account and per month, the net result (credits minus debits: a gain is
-- positive, a loss or a cost is negative), the total, and an ESTIMATE of the yearly income tax on that result.
--
--   * Nothing is recorded: the function only reads (like the estimate of the running month, decision 342).
--   * Year-end closing journals (entry_type 'closing') are left out, so a closed year still shows its result.
--   * Rounding differences (system key ROUNDING_DIFFERENCE) are left out; the unrealised revaluation account (7370) is
--     shown but not counted, because a paper gain or loss is not taxed until it is realised.
--   * The estimate uses 22% for a company, a cooperative and a sole-owner company (perseroan perorangan); it is an
--     assumption (no facility, no loss carried forward, no deduction of costs of the business), never a final figure.
--     For other taxpayer kinds no rate is assumed.
--   * The year is settled on 1 January of the next year (owner, 8 October 2026); the annual return is still due on
--     30 April (decision 345). `status` is 'running' for the current year and 'settled' for an earlier one.
-- Permission: tax.view.

create function public.tax_non_final_income(p_entity uuid, p_year integer default null) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_today date;
  v_year integer;
  v_kind text;
  v_rate numeric;
  v_rows jsonb;
  v_months jsonb;
  v_total numeric;
  v_est numeric;
  v_cur text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  v_today := app_private.entity_today(p_entity);
  v_year := coalesce(p_year, extract(year from v_today)::integer);
  if v_year < 2000 or v_year > extract(year from v_today)::integer then
    raise exception 'INVALID: the year must be between 2000 and the current year' using errcode = 'invalid_parameter_value';
  end if;
  v_cur := app_private.entity_base_currency(p_entity)::text;

  with acc as (
    select a.id, a.code, a.name, a.account_class, a.code <> '7370' as counted
    from public.ledger_accounts a
    where a.entity_id = p_entity and a.code ~ '^7' and not a.is_group
      and a.account_class in ('other_income', 'other_expense', 'other')
      and coalesce(a.system_key, '') <> 'ROUNDING_DIFFERENCE'
  ), m as (
    select l.ledger_account_id as account_id, extract(month from j.entry_date)::integer as mo, sum(l.credit - l.debit) as net
    from public.journal_lines l
    join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
    join acc on acc.id = l.ledger_account_id
    where l.entity_id = p_entity and j.status = 'posted' and j.entry_type <> 'closing'
      and j.entry_date >= make_date(v_year, 1, 1) and j.entry_date < make_date(v_year + 1, 1, 1)
    group by l.ledger_account_id, extract(month from j.entry_date)::integer
  )
  select
    coalesce((select jsonb_agg(jsonb_build_object(
        'code', acc.code, 'name', acc.name, 'account_class', acc.account_class, 'counted', acc.counted,
        'months', (select jsonb_agg(coalesce(m.net, 0)::text order by g)
                   from generate_series(1, 12) g left join m on m.account_id = acc.id and m.mo = g),
        'total', (select coalesce(sum(m.net), 0)::text from m where m.account_id = acc.id)) order by acc.code)
      from acc where exists (select 1 from m where m.account_id = acc.id)), '[]'::jsonb),
    (select jsonb_agg(coalesce((select sum(m.net) from m join acc on acc.id = m.account_id where m.mo = g and acc.counted), 0)::text order by g)
     from generate_series(1, 12) g),
    coalesce((select sum(m.net) from m join acc on acc.id = m.account_id where acc.counted), 0)
  into v_rows, v_months, v_total;

  select p.taxpayer_kind into v_kind from app_private.tax_profile_at(p_entity, v_today) p;
  v_rate := case when v_kind in ('company', 'cooperative', 'perseroan_perorangan') then 0.22 else null end;
  v_est := case when v_rate is null then null else round(greatest(v_total, 0) * v_rate, 2) end;

  return jsonb_build_object(
    'year', v_year,
    'currency', v_cur,
    'status', case when v_year < extract(year from v_today)::integer then 'settled' else 'running' end,
    'settles_on', make_date(v_year + 1, 1, 1),
    'annual_return_due', make_date(v_year + 1, 4, 30),
    'taxpayer_kind', v_kind,
    'rate', v_rate::text,
    'rows', v_rows,
    'month_totals', v_months,
    'total', v_total::text,
    'estimated_tax', v_est::text);
end
$$;

revoke all on function public.tax_non_final_income(uuid, integer) from public, anon;
grant execute on function public.tax_non_final_income(uuid, integer) to authenticated;
