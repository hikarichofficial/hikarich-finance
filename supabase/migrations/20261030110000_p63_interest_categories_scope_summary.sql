-- P63 (decision 409, owner request of 12 October 2026): interest income is kept apart by kind, and the interest a
-- bank already withheld final tax on is no longer taxed a second time in the yearly estimate.
--   * Three categories replace the single "Bunga Bank & Deposito": "Bunga Tabungan" and "Bunga Deposito" (own accounts
--     7101 and 7102, interest on which the bank withholds PPh final of 20%, PP 131/2000 as amended by PP 123/2015,
--     unless the amount is exempt under PMK 212/PMK.03/2018 article 7) and "Bunga Lainnya" (account 7100: interest on
--     a loan given, a receivable, anything else). The old category is renamed "Bunga Lainnya" where that name is free,
--     so what was already recorded stays on account 7100 and in the estimate.
--   * tax_non_final_income leaves accounts 7101 and 7102 out of the estimate ("counted" false, "withheld" true): the
--     tax on them was settled by the bank (final), so the estimate no longer adds 22% on them.
--   * tax_scope_summary(entity, from, to): per tax type, the tax counted (ledger accruals net of reversals), the tax
--     paid (confirmed payments) and what is left, for tax periods inside the range. View only: the Ringkasan Pajak
--     filter (month, year or since the start).
-- Everything is by tax period (the month the tax belongs to), not by the day the entry was made.

insert into public.coa_template_accounts
  (template_key, code, name, account_class, normal_balance, system_key, parent_code, is_group, is_control, allows_manual_posting)
values
  ('company_default', '7101', 'Pendapatan Bunga Tabungan (PPh final dipotong bank)', 'other_income', 'credit', null, null, false, false, true),
  ('company_default', '7102', 'Pendapatan Bunga Deposito (PPh final dipotong bank)', 'other_income', 'credit', null, null, false, false, true)
on conflict (template_key, code) do nothing;

create or replace function app_private.provision_income_categories(p_entity uuid) returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare
  r record;
  v_cat uuid;
  v_account uuid;
  v_count integer := 0;
begin
  if not exists (select 1 from public.entities where id = p_entity and entity_type = 'company') then
    return 0;
  end if;
  for r in
    select * from (values
      ('Komisi & Afiliasi', '4190', 60),
      ('Bunga Tabungan', '7101', 110),
      ('Bunga Deposito', '7102', 111),
      ('Bunga Lainnya', '7100', 112),
      ('Dividen', '7110', 120),
      ('Sewa Properti Investasi', '7120', 130),
      ('Imbal Hasil Investasi', '7130', 140),
      ('Bonus, Cashback & Rebate', '7140', 150),
      ('Pendapatan Kripto', '7150', 160),
      ('Pendapatan Investasi Lainnya', '7160', 170),
      ('Pendapatan di Luar Usaha', '7190', 180)
    ) as t (name, account_code, sort_order)
  loop
    if exists (select 1 from public.categories c
               where c.entity_id = p_entity
                 and c.normalized_name = lower(regexp_replace(btrim(r.name), '\s+', ' ', 'g'))) then
      continue;
    end if;
    select a.id into v_account from public.ledger_accounts a
    where a.entity_id = p_entity and a.code = r.account_code and a.status = 'active' and not a.is_group;
    if v_account is null then
      continue;
    end if;
    insert into public.categories (entity_id, name, kind, sort_order)
    values (p_entity, r.name, 'revenue', r.sort_order)
    returning id into v_cat;
    insert into public.category_account_mappings
      (entity_id, category_id, context, debit_ledger_account_id, credit_ledger_account_id, effective_from)
    values (p_entity, v_cat, 'sales', null, v_account, date '2000-01-01');
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;

-- The accounts and categories for every active company; the old single category is renamed first so the new ones
-- do not collide with it.
update public.categories c
set name = 'Bunga Lainnya'
where c.normalized_name = 'bunga bank & deposito'
  and not exists (select 1 from public.categories o
                  where o.entity_id = c.entity_id and o.normalized_name = 'bunga lainnya');

select app_private.provision_default_coa(e.id) from public.entities e where e.entity_type = 'company' and e.status = 'active';

create or replace function public.tax_non_final_income(p_entity uuid, p_year integer default null) returns jsonb
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
    select a.id, a.code, a.name, a.account_class, a.code not in ('7370', '7101', '7102') as counted,
           a.code in ('7101', '7102') as withheld
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
        'withheld', acc.withheld,
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

-- ------------------------------------------------------------ the filtered summary of Ringkasan Pajak
create function public.tax_scope_summary(p_entity uuid, p_from date default null, p_to date default null)
returns table (tax_type text, accrued text, paid text, outstanding text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  if p_from is not null and p_to is not null and p_from > p_to then
    raise exception 'INVALID: the start of the range is after its end' using errcode = 'invalid_parameter_value';
  end if;
  return query
  with a as (
    select e.tax_type, sum(e.amount) as amt
    from public.tax_ledger_entries e
    where e.entity_id = p_entity and e.direction = 'payable'
      and (p_from is null or e.tax_period >= p_from) and (p_to is null or e.tax_period <= p_to)
    group by e.tax_type
  ), p as (
    select t.tax_type, sum(t.payable_applied) as amt
    from public.tax_payments t
    where t.entity_id = p_entity and t.status = 'confirmed'
      and (p_from is null or t.tax_period >= p_from) and (p_to is null or t.tax_period <= p_to)
    group by t.tax_type
  )
  select coalesce(a.tax_type, p.tax_type), coalesce(a.amt, 0)::text, coalesce(p.amt, 0)::text,
         (coalesce(a.amt, 0) - coalesce(p.amt, 0))::text
  from a full join p on p.tax_type = a.tax_type
  order by 1;
end
$$;

revoke all on function public.tax_scope_summary(uuid, date, date) from public, anon;
grant execute on function public.tax_scope_summary(uuid, date, date) to authenticated;
