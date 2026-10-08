-- p44 (decision 366): the tax a person pays in themselves (PPh Final UMKM and the monthly PPh 25 instalment) is
-- recorded as an ordinary expense in two ready categories; the Pajak Pribadi estimate subtracts it, so "masih harus
-- dibayar" stays true after the person has paid. Researched first (PMK 215/PMK.03/2018 Art. 2, 10; PMK 164/2023
-- Art. 3(3)(a), 6(3)-(6); UU PPh Art. 17(4)): the Rp 500 juta band belongs to the final-tax turnover only, so freelance
-- income neither uses it nor needs it; the taxable income is rounded down to whole thousands (already so); the PPh 25
-- instalment of an individual is last year's tax payable less credits, divided by 12, due on the 15th.

alter table public.categories drop constraint categories_personal_tax_role_kind;
alter table public.categories drop constraint categories_personal_tax_role_check;
alter table public.categories add constraint categories_personal_tax_role_check
  check (personal_tax_role is null or personal_tax_role in
    ('umkm_business', 'freelance', 'company_payout', 'business_cost', 'tax_paid_final', 'tax_paid_installment'));
alter table public.categories add constraint categories_personal_tax_role_kind check (
  personal_tax_role is null
  or (personal_tax_role in ('umkm_business', 'freelance', 'company_payout') and kind = 'revenue')
  or (personal_tax_role in ('business_cost', 'tax_paid_final', 'tax_paid_installment') and kind = 'expense'));

insert into public.coa_template_accounts
  (template_key, code, name, account_class, normal_balance, system_key, parent_code, is_group, is_control, allows_manual_posting)
values
  ('personal_default', '6060', 'Setoran Pajak Penghasilan', 'expense', 'debit', 'PERSONAL_INCOME_TAX_PAID', null, false, false, true);

select app_private.provision_default_accounts(e.id) from public.entities e where e.entity_type = 'personal';

create or replace function app_private.provision_personal_tax_categories(p_entity uuid) returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare
  r record;
  v_cat uuid;
  v_account uuid;
  v_count integer := 0;
begin
  if not exists (select 1 from public.entities where id = p_entity and entity_type = 'personal') then
    return 0;
  end if;
  for r in
    select * from (values
      ('Honor dari PT Saya', 'revenue', '4500', 'company_payout', 8),
      ('Pendapatan Jasa & Pekerjaan Bebas', 'revenue', '4500', 'freelance', 11),
      ('Pendapatan Usaha (Penjualan)', 'revenue', '4600', 'umkm_business', 12),
      ('Biaya Usaha & Jasa', 'expense', '6050', 'business_cost', 105),
      ('Setoran PPh Final UMKM', 'expense', '6060', 'tax_paid_final', 106),
      ('Setoran PPh 25 (Angsuran)', 'expense', '6060', 'tax_paid_installment', 107)
    ) as t (name, kind, account_code, role, sort_order)
  loop
    select c.id into v_cat from public.categories c
    where c.entity_id = p_entity and c.normalized_name = lower(regexp_replace(btrim(r.name), '\s+', ' ', 'g'));
    if v_cat is not null then
      -- Already there (maybe the owner's own): only fill the tag when it has none.
      update public.categories set personal_tax_role = r.role
      where id = v_cat and personal_tax_role is null and kind = r.kind;
      v_cat := null;
      continue;
    end if;
    select a.id into v_account from public.ledger_accounts a
    where a.entity_id = p_entity and a.code = r.account_code and a.status = 'active' and not a.is_group;
    if v_account is null then
      continue;
    end if;
    insert into public.categories (entity_id, name, kind, sort_order, personal_tax_role)
    values (p_entity, r.name, r.kind, r.sort_order, r.role)
    returning id into v_cat;
    insert into public.category_account_mappings
      (entity_id, category_id, context, debit_ledger_account_id, credit_ledger_account_id, effective_from)
    values (p_entity, v_cat,
            case r.kind when 'revenue' then 'sales' else 'purchases' end,
            case when r.kind = 'expense' then v_account end,
            case when r.kind = 'revenue' then v_account end,
            date '2000-01-01');
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;
revoke all on function app_private.provision_personal_tax_categories(uuid) from public;

select app_private.provision_personal_tax_categories(e.id) from public.entities e where e.entity_type = 'personal';

-- The summary now also returns what the person has already paid in.
create or replace function public.personal_tax_summary(p_entity uuid, p_year integer default null) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  v_today date;
  v_year integer;
  v_from date;
  v_to date;
  v_ptkp text;
  v_final public.tax_rule_versions%rowtype;
  v_tariff public.tax_rule_versions%rowtype;
  v_ie jsonb;
  v_pt jsonb;
  v_cost jsonb;
  v_pay jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.entity_type <> 'personal' then
    return jsonb_build_object('applicable', false);
  end if;
  v_today := app_private.entity_today(p_entity);
  v_year := coalesce(p_year, extract(year from v_today)::integer);
  if v_year < 2000 or v_year > extract(year from v_today)::integer then
    raise exception 'INVALID: the year must be between 2000 and the current year' using errcode = 'invalid_parameter_value';
  end if;
  v_from := make_date(v_year, 1, 1);
  v_to := make_date(v_year, 12, 31);
  select s.ptkp_status into v_ptkp from public.personal_tax_settings s where s.entity_id = p_entity and s.tax_year = v_year;
  select * into v_final from app_private.tax_rule_at('PPH_FINAL_UMKM', v_to);
  select * into v_tariff from app_private.tax_rule_at('PERSONAL_INCOME_TARIFF', v_to);

  -- income recorded in this book (before tax withheld), tagged
  select coalesce(jsonb_agg(jsonb_build_object('mo', extract(month from n.entry_date)::integer, 'role', c.personal_tax_role,
                                               'amt', n.amount, 'wh', n.tax_withheld)), '[]'::jsonb)
    into v_ie
  from public.income_entries n join public.categories c on c.id = n.category_id and c.entity_id = n.entity_id
  where n.entity_id = p_entity and n.status = 'recorded' and n.entry_date between v_from and v_to;
  -- income paid to this person by the owner's own PT
  select coalesce(jsonb_agg(jsonb_build_object('mo', t.mo, 'cid', t.contact_id, 'cname', t.contact_name,
                                               'eid', t.source_entity, 'ename', t.source_name, 'gross', t.gross, 'wh', t.withheld)), '[]'::jsonb)
    into v_pt
  from app_private.personal_pt_income(p_entity, v_from, v_to) t;
  -- costs of the services (tagged expense categories), from confirmed expenses and approved bills
  select coalesce(jsonb_agg(jsonb_build_object('mo', q.mo, 'amt', q.amt)), '[]'::jsonb) into v_cost
  from (
    select extract(month from x.expense_date)::integer as mo, coalesce(l.base_amount, l.line_total) as amt
    from public.expense_lines l
    join public.expenses x on x.id = l.expense_id and x.entity_id = l.entity_id
    join public.categories c on c.id = l.category_id and c.entity_id = l.entity_id
    where l.entity_id = p_entity and x.status = 'confirmed' and l.treatment = 'expense'
      and c.personal_tax_role = 'business_cost' and x.expense_date between v_from and v_to
    union all
    select extract(month from b.bill_date)::integer, coalesce(l.base_amount, l.line_total)
    from public.bill_lines l
    join public.bills b on b.id = l.bill_id and b.entity_id = l.entity_id
    join public.categories c on c.id = l.category_id and c.entity_id = l.entity_id
    where l.entity_id = p_entity and b.status = 'approved' and l.treatment = 'expense'
      and c.personal_tax_role = 'business_cost' and b.bill_date between v_from and v_to
  ) q;

  -- tax the person paid in themselves, from confirmed expenses and approved bills of the two payment categories
  select coalesce(jsonb_agg(jsonb_build_object('mo', q.mo, 'role', q.role, 'amt', q.amt)), '[]'::jsonb) into v_pay
  from (
    select extract(month from x.expense_date)::integer as mo, c.personal_tax_role as role, coalesce(l.base_amount, l.line_total) as amt
    from public.expense_lines l
    join public.expenses x on x.id = l.expense_id and x.entity_id = l.entity_id
    join public.categories c on c.id = l.category_id and c.entity_id = l.entity_id
    where l.entity_id = p_entity and x.status = 'confirmed' and l.treatment = 'expense'
      and c.personal_tax_role in ('tax_paid_final', 'tax_paid_installment') and x.expense_date between v_from and v_to
    union all
    select extract(month from b.bill_date)::integer, c.personal_tax_role, coalesce(l.base_amount, l.line_total)
    from public.bill_lines l
    join public.bills b on b.id = l.bill_id and b.entity_id = l.entity_id
    join public.categories c on c.id = l.category_id and c.entity_id = l.entity_id
    where l.entity_id = p_entity and b.status = 'approved' and l.treatment = 'expense'
      and c.personal_tax_role in ('tax_paid_final', 'tax_paid_installment') and b.bill_date between v_from and v_to
  ) q;

  return jsonb_build_object(
    'applicable', true, 'entity_id', p_entity, 'year', v_year, 'currency', e.base_currency::text,
    'status', case when v_year < extract(year from v_today)::integer then 'settled' else 'running' end,
    'ptkp_status', v_ptkp,
    'business', jsonb_build_object(
      'turnover', (select trim_scale(coalesce(sum(r.amt), 0))::text from jsonb_to_recordset(v_ie) as r(mo integer, role text, amt numeric, wh numeric) where r.role = 'umkm_business'),
      'months', (select jsonb_agg(trim_scale(coalesce((select sum(r.amt) from jsonb_to_recordset(v_ie) as r(mo integer, role text, amt numeric, wh numeric)
                                                         where r.role = 'umkm_business' and r.mo = g.m), 0))::text order by g.m)
                 from generate_series(1, 12) g(m)),
      'withheld_not_credited', (select trim_scale(coalesce(sum(r.wh), 0))::text from jsonb_to_recordset(v_ie) as r(mo integer, role text, amt numeric, wh numeric) where r.role = 'umkm_business')),
    'freelance', jsonb_build_object(
      'own_gross', (select trim_scale(coalesce(sum(r.amt), 0))::text from jsonb_to_recordset(v_ie) as r(mo integer, role text, amt numeric, wh numeric) where r.role = 'freelance'),
      'own_withheld', (select trim_scale(coalesce(sum(r.wh), 0))::text from jsonb_to_recordset(v_ie) as r(mo integer, role text, amt numeric, wh numeric) where r.role = 'freelance'),
      'pt_gross', (select trim_scale(coalesce(sum(r.gross), 0))::text from jsonb_to_recordset(v_pt) as r(mo integer, cid uuid, cname text, eid uuid, ename text, gross numeric, wh numeric)),
      'pt_withheld', (select trim_scale(coalesce(sum(r.wh), 0))::text from jsonb_to_recordset(v_pt) as r(mo integer, cid uuid, cname text, eid uuid, ename text, gross numeric, wh numeric)),
      'months', (select jsonb_agg(trim_scale(
                   coalesce((select sum(r.amt) from jsonb_to_recordset(v_ie) as r(mo integer, role text, amt numeric, wh numeric) where r.role = 'freelance' and r.mo = g.m), 0)
                   + coalesce((select sum(r.gross) from jsonb_to_recordset(v_pt) as r(mo integer, cid uuid, cname text, eid uuid, ename text, gross numeric, wh numeric) where r.mo = g.m), 0))::text order by g.m)
                 from generate_series(1, 12) g(m))),
    'costs', jsonb_build_object(
      'total', (select trim_scale(coalesce(sum(r.amt), 0))::text from jsonb_to_recordset(v_cost) as r(mo integer, amt numeric)),
      'months', (select jsonb_agg(trim_scale(coalesce((select sum(r.amt) from jsonb_to_recordset(v_cost) as r(mo integer, amt numeric) where r.mo = g.m), 0))::text order by g.m)
                 from generate_series(1, 12) g(m))),
    'payments', jsonb_build_object(
      'final', (select trim_scale(coalesce(sum(r.amt), 0))::text from jsonb_to_recordset(v_pay) as r(mo integer, role text, amt numeric) where r.role = 'tax_paid_final'),
      'installment', (select trim_scale(coalesce(sum(r.amt), 0))::text from jsonb_to_recordset(v_pay) as r(mo integer, role text, amt numeric) where r.role = 'tax_paid_installment'),
      'installment_months', (select jsonb_agg(trim_scale(coalesce((select sum(r.amt) from jsonb_to_recordset(v_pay) as r(mo integer, role text, amt numeric)
                                                                   where r.role = 'tax_paid_installment' and r.mo = g.m), 0))::text order by g.m)
                             from generate_series(1, 12) g(m))),
    'linked_pt', (select coalesce(jsonb_agg(jsonb_build_object('entity_id', s.eid, 'entity_name', s.ename, 'contact_id', s.cid,
                         'contact_name', s.cname, 'documents', s.docs, 'gross', trim_scale(s.gross)::text, 'withheld', trim_scale(s.wh)::text)
                         order by s.ename, s.cname), '[]'::jsonb)
                  from (select r.eid, r.ename, r.cid, r.cname, count(*) as docs, sum(r.gross) as gross, sum(r.wh) as wh
                        from jsonb_to_recordset(v_pt) as r(mo integer, cid uuid, cname text, eid uuid, ename text, gross numeric, wh numeric)
                        group by r.eid, r.ename, r.cid, r.cname) s),
    'group', jsonb_build_object(
      'own_turnover', trim_scale(app_private.entity_gross_turnover(p_entity, v_from, v_to))::text,
      'others', (select coalesce(jsonb_agg(jsonb_build_object('entity_id', g.id, 'name', coalesce(en.brand_name, en.legal_name),
                         'entity_type', en.entity_type, 'turnover', trim_scale(app_private.entity_gross_turnover(g.id, v_from, v_to))::text)), '[]'::jsonb)
                 from app_private.tax_group_entities(p_entity) as g(id) join public.entities en on en.id = g.id)),
    'rules', jsonb_build_object(
      'final', case when v_final.id is null then null else jsonb_build_object('code', v_final.code, 'version', v_final.rule_version, 'params', v_final.params) end,
      'tariff', case when v_tariff.id is null then null else jsonb_build_object('code', v_tariff.code, 'version', v_tariff.rule_version, 'params', v_tariff.params) end));
end
$$;
revoke all on function public.personal_tax_summary(uuid, integer) from public, anon;
grant execute on function public.personal_tax_summary(uuid, integer) to authenticated;
