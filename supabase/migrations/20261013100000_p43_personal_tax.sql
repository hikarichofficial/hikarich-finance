-- P43 (decision 365, OWNER request of 9 October 2026): Pajak Pribadi.
--
-- "perhitungan pajak untuk entitas PRIBADI ... harus ada ... UMKM FINAL 0,5% dan PPh progresif ... otomatis ...
--  jangan buat saya repot mengisi integrasi data antara PT dan PRIBADI ... potongan dari klien lain juga simple."
--
-- What this adds, all read-only for tax (nothing is posted for the yearly estimate, like decision 352):
--   * categories.personal_tax_role: the one tag that sorts a Personal (household) book into the two tax
--     calculations. Revenue categories: 'umkm_business' (sales; PPh Final 0,5%), 'freelance' (services of an
--     independent worker; progressive rates on net income), 'company_payout' (money paid by the owner's own PT;
--     only the cash is recorded here, the income and the withheld PPh are read from the PT's own documents).
--     Expense categories: 'business_cost' (reduces the net income of the services). No tag = private /
--     not part of this calculation.
--   * Ready Personal categories and accounts for those roles, and "PPh yang sudah dipotong klien" on Catat Pendapatan
--     (one optional number; the amount that arrived is what is typed, the gross is worked out).
--   * personal_tax_settings: the PTKP status of the person per tax year.
--   * Rule data (not code): PERSONAL_INCOME_TARIFF (Art. 17(1)(a) UU PPh as amended by UU HPP, PTKP amounts).
--   * public.personal_tax_summary(entity, year) and public.tax_group_turnover(entity, year).
--   * The Rp 4,8 billion ceiling of PPh Final now counts the turnover of the other books of the same owner by itself
--     (PT and Personal), so nobody types "omzet di luar sistem" for that any more.
-- Production holds no personal income entry that depends on the old meaning of in_turnover for a Personal book
-- except test data; it is corrected below.

-- ------------------------------------------------------------ the tag on categories
alter table public.categories add column personal_tax_role text
  check (personal_tax_role is null or personal_tax_role in ('umkm_business', 'freelance', 'company_payout', 'business_cost'));
alter table public.categories add constraint categories_personal_tax_role_kind check (
  personal_tax_role is null
  or (personal_tax_role in ('umkm_business', 'freelance', 'company_payout') and kind = 'revenue')
  or (personal_tax_role = 'business_cost' and kind = 'expense'));

-- ------------------------------------------------------------ Personal chart of accounts
insert into public.coa_template_accounts
  (template_key, code, name, account_class, normal_balance, system_key, parent_code, is_group, is_control, allows_manual_posting)
values
  ('personal_default', '1310', 'Kredit Pajak (PPh Dipotong Klien)', 'asset', 'debit', 'PERSONAL_TAX_CREDIT', null, false, true, false),
  ('personal_default', '4500', 'Pendapatan Jasa & Pekerjaan Bebas', 'revenue', 'credit', 'FREELANCE_INCOME', null, false, false, true),
  ('personal_default', '4600', 'Pendapatan Usaha (Penjualan)', 'revenue', 'credit', 'BUSINESS_SALES_INCOME', null, false, false, true),
  ('personal_default', '6050', 'Biaya Usaha & Jasa', 'expense', 'debit', 'BUSINESS_SERVICE_COST', null, false, false, true);

select app_private.provision_default_accounts(e.id) from public.entities e where e.entity_type = 'personal';

-- ------------------------------------------------------------ ready Personal categories
create function app_private.provision_personal_tax_categories(p_entity uuid) returns integer
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
      ('Biaya Usaha & Jasa', 'expense', '6050', 'business_cost', 105)
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

create or replace function app_private.provision_default_coa(p_entity uuid) returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare
  v_count integer;
begin
  v_count := app_private.provision_default_accounts(p_entity);
  perform app_private.provision_default_categories(p_entity);
  perform app_private.provision_income_categories(p_entity);
  perform app_private.provision_personal_tax_categories(p_entity);
  return v_count;
end
$$;

select app_private.provision_personal_tax_categories(e.id) from public.entities e where e.entity_type = 'personal';

-- ------------------------------------------------------------ income entries: tax already withheld, turnover meaning
alter table public.income_entries add column tax_withheld public.money_amount not null default 0
  check (tax_withheld >= 0 and tax_withheld < amount);

-- A Personal book counts as PPh Final turnover only what is tagged as sales (before, every revenue account did,
-- which wrongly included salary, dividends and interest). Corrected for the entries already recorded.
alter table public.income_entries disable trigger tg_guard;
update public.income_entries n
set in_turnover = false
where n.in_turnover
  and exists (select 1 from public.entities e where e.id = n.entity_id and e.entity_type = 'personal')
  and not exists (select 1 from public.categories c
                  where c.id = n.category_id and c.entity_id = n.entity_id and c.personal_tax_role = 'umkm_business');
alter table public.income_entries enable trigger tg_guard;

drop function public.record_income_entry(uuid, text, uuid, date, uuid, text, uuid, text, text);
create function public.record_income_entry(
  p_entity uuid, p_key text, p_category uuid, p_date date, p_account uuid, p_amount text,
  p_contact uuid default null, p_reference text default null, p_note text default null,
  p_withheld text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  fa public.financial_accounts%rowtype;
  cat public.categories%rowtype;
  v_in_turnover boolean;
  v_replay uuid;
  v_scale integer;
  v_amount numeric;
  v_withheld numeric := 0;
  v_income_account uuid;
  v_credit_account uuid;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid := gen_random_uuid();
  v_desc text;
  v_journal uuid;
  v_lines jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not (app_authz.has_permission(p_entity, 'invoices.issue') and app_authz.has_permission(p_entity, 'invoices.confirm_payment')) then
    raise exception 'FORBIDDEN: recording income needs invoices.issue and invoices.confirm_payment'
      using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('income.record', p_entity, p_key,
    md5(jsonb_build_object('t', p_category, 'd', p_date, 'a', p_account, 'm', p_amount, 'c', p_contact, 'r', p_reference,
                           'n', p_note, 'w', coalesce(nullif(btrim(p_withheld), ''), '0'))::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  select * into cat from public.categories
  where id = p_category and entity_id = p_entity and kind = 'revenue' and is_active;
  if not found then
    raise exception 'INVALID: unknown or inactive income category' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(p_entity) then
    raise exception 'INVALID: the date the money arrived cannot be in the future' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(v_ref, '')) > 200 or length(coalesce(v_note, '')) > 1000 then
    raise exception 'INVALID: the reference is limited to 200 and the note to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
  if not found or not fa.is_active then
    raise exception 'INVALID: the receiving account is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;
  if fa.currency <> e.base_currency then
    raise exception 'INVALID: income is received in the Entity''s base currency (%)', e.base_currency
      using errcode = 'invalid_parameter_value';
  end if;
  if p_contact is not null and not exists (select 1 from public.contacts where id = p_contact and entity_id = p_entity) then
    raise exception 'INVALID: the contact is unknown in this Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(e.base_currency);
  -- p_amount is the GROSS income (what the client owed); the money that arrives is the gross less the tax withheld.
  v_amount := app_private.parse_amount(p_amount, 'the amount');
  if v_amount <= 0 or app_private.round_amount(v_amount, v_scale, 'down') <> v_amount then
    raise exception 'INVALID: the amount must be positive, with at most % decimals', v_scale
      using errcode = 'invalid_parameter_value';
  end if;
  if nullif(btrim(coalesce(p_withheld, '')), '') is not null then
    v_withheld := app_private.parse_amount(p_withheld, 'the tax withheld');
    if v_withheld < 0 or app_private.round_amount(v_withheld, v_scale, 'down') <> v_withheld then
      raise exception 'INVALID: the tax withheld cannot be negative, with at most % decimals', v_scale
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  if v_withheld > 0 then
    if e.entity_type <> 'personal' then
      raise exception 'INVALID: tax withheld by the client is recorded in a Personal book only' using errcode = 'invalid_parameter_value';
    end if;
    if v_withheld >= v_amount then
      raise exception 'INVALID: the tax withheld must be less than the income' using errcode = 'invalid_parameter_value';
    end if;
    select a.id into v_credit_account from public.ledger_accounts a
    where a.entity_id = p_entity and a.system_key = 'PERSONAL_TAX_CREDIT' and a.status = 'active';
    if v_credit_account is null then
      raise exception 'INVALID: the tax credit account is missing from the chart of accounts' using errcode = 'invalid_parameter_value';
    end if;
  end if;
  v_income_account := app_private.resolve_revenue_account(p_entity, p_category, p_date);
  if v_income_account is null then
    raise exception 'INVALID: the income account of "%" is missing or inactive in the chart of accounts', cat.name
      using errcode = 'invalid_parameter_value';
  end if;
  if e.entity_type = 'personal' then
    v_in_turnover := coalesce(cat.personal_tax_role = 'umkm_business', false);
  else
    select a.account_class = 'revenue' into v_in_turnover from public.ledger_accounts a where a.id = v_income_account;
  end if;
  v_desc := 'Pendapatan - ' || cat.name || coalesce(' - ' || left(v_note, 120), '');
  perform 1 from public.financial_accounts where id = p_account and entity_id = p_entity for no key update;
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', fa.ledger_account_id, 'debit', v_amount - v_withheld, 'credit', 0, 'description', v_desc),
    jsonb_build_object('account_id', v_income_account, 'debit', 0, 'credit', v_amount, 'description', v_desc));
  if v_withheld > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', v_credit_account, 'debit', v_withheld, 'credit', 0,
      'description', 'PPh dipotong klien: ' || v_desc);
  end if;
  v_journal := app_private.post_system_journal(p_entity, 'income_entry', v_id, 'income_entry.record',
    'income_entry.v1', p_date, v_desc, v_lines);
  perform app_private.record_movement(p_entity, p_account, 'in', v_amount - v_withheld, v_amount - v_withheld, null, p_date,
    'income_entry', v_id, 'principal', v_journal, v_desc);
  insert into public.income_entries
    (id, entity_id, entry_date, category_id, currency, amount, financial_account_id, contact_id, income_account_id,
     in_turnover, reference, note, journal_id, tax_withheld)
  values
    (v_id, p_entity, p_date, p_category, e.base_currency, v_amount, p_account, p_contact, v_income_account,
     v_in_turnover, v_ref, v_note, v_journal, v_withheld);
  perform app_private.idem_complete('income.record', p_entity, p_key, 'income_entries', v_id);
  return v_id;
end
$$;
revoke all on function public.record_income_entry(uuid, text, uuid, date, uuid, text, uuid, text, text, text) from public, anon;
grant execute on function public.record_income_entry(uuid, text, uuid, date, uuid, text, uuid, text, text, text) to authenticated;

create or replace function public.list_income_categories(p_entity uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.view') then
    raise exception 'FORBIDDEN: missing invoices.view' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'account_code', a.code, 'account_name', a.name,
        'in_turnover', case when ent.entity_type = 'personal' then coalesce(c.personal_tax_role = 'umkm_business', false)
                            else coalesce(a.account_class = 'revenue', false) end,
        'tax_role', c.personal_tax_role, 'available', a.id is not null)
      order by c.sort_order, c.name)
    from public.categories c
    join public.entities ent on ent.id = c.entity_id
    left join public.ledger_accounts a
      on a.id = app_private.resolve_revenue_account(p_entity, c.id, app_private.entity_today(p_entity))
    where c.entity_id = p_entity and c.kind = 'revenue' and c.is_active), '[]'::jsonb);
end
$$;

-- ------------------------------------------------------------ PTKP status per tax year
create table public.personal_tax_settings (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  tax_year integer not null check (tax_year between 2000 and 2999),
  ptkp_status text not null check (ptkp_status in
    ('TK/0', 'TK/1', 'TK/2', 'TK/3', 'K/0', 'K/1', 'K/2', 'K/3', 'K/I/0', 'K/I/1', 'K/I/2', 'K/I/3')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, tax_year),
  unique (entity_id, id)
);
call app_private.apply_standard_triggers('public.personal_tax_settings');
call app_private.secure_table('public.personal_tax_settings');
call app_private.expose_select('public.personal_tax_settings');
create trigger tg_forbid_delete before delete on public.personal_tax_settings
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.personal_tax_settings
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_audit after insert or update or delete on public.personal_tax_settings
  for each row execute function app_private.tg_audit('entity_id');
create policy personal_tax_settings_select on public.personal_tax_settings for select to authenticated
  using (coalesce(entity_id = any (((select app_authz.permitted_entities('tax.view')))::uuid[]), false));

create function public.personal_tax_set_ptkp(p_entity uuid, p_year integer, p_status text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.confirm_facts') then
    raise exception 'FORBIDDEN: missing tax.confirm_facts' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.entities where id = p_entity and entity_type = 'personal' and status = 'active') then
    raise exception 'INVALID: the PTKP status belongs to a Personal book' using errcode = 'invalid_parameter_value';
  end if;
  if p_year is null or p_year < 2000 or p_year > extract(year from app_private.entity_today(p_entity))::integer then
    raise exception 'INVALID: the tax year must be between 2000 and the current year' using errcode = 'invalid_parameter_value';
  end if;
  insert into public.personal_tax_settings (entity_id, tax_year, ptkp_status)
  values (p_entity, p_year, p_status)
  on conflict (entity_id, tax_year) do update set ptkp_status = excluded.ptkp_status;
end
$$;
revoke all on function public.personal_tax_set_ptkp(uuid, integer, text) from public, anon;
grant execute on function public.personal_tax_set_ptkp(uuid, integer, text) to authenticated;

-- ------------------------------------------------------------ rule data: progressive rates and PTKP
insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
values
  ('personal_income', 'PERSONAL_INCOME_TARIFF', 1, date '2022-01-01',
   '{"brackets":[
       {"up_to":"60000000","rate":"0.05"},
       {"up_to":"250000000","rate":"0.15"},
       {"up_to":"500000000","rate":"0.25"},
       {"up_to":"5000000000","rate":"0.30"},
       {"up_to":null,"rate":"0.35"}],
     "ptkp":{"TK/0":"54000000","TK/1":"58500000","TK/2":"63000000","TK/3":"67500000",
             "K/0":"58500000","K/1":"63000000","K/2":"67500000","K/3":"72000000",
             "K/I/0":"112500000","K/I/1":"117000000","K/I/2":"121500000","K/I/3":"126000000"},
     "pkp_round_down_to":"1000"}'::jsonb,
   'UU PPh Pasal 17 ayat (1) huruf a as amended by UU HPP: progressive rates 5%, 15%, 25%, 30%, 35%; PTKP amounts',
   'UU 7/2021 (UU HPP); PMK 101/PMK.010/2016 (PTKP)',
   'https://www.pajak.com/pajak/mekanisme-perhitungan-pph-orang-pribadi-dalam-uu-hpp/2/',
   date '2026-10-09', 'verified', 'published', now(),
   'The five brackets and the PTKP amounts were read from secondary sources (pajak.com, pajakku.com, 9 October 2026); PTKP is unchanged for 2026 in those sources. Rounding of the taxable income down to whole thousands follows the SPT form instructions and is not confirmed by a primary source here. Monthly PPh 25 instalments are not modelled.');

-- ------------------------------------------------------------ the owner's other books
create function app_private.tax_group_entities(p_entity uuid) returns setof uuid
language sql stable security definer set search_path = pg_catalog, public as $$
  select distinct m2.entity_id
  from public.entity_memberships m1
  join public.roles r1 on r1.id = m1.role_id and r1.role_key = 'owner'
  join public.entity_memberships m2 on m2.user_id = m1.user_id and m2.entity_id <> m1.entity_id and m2.status = 'active'
  join public.roles r2 on r2.id = m2.role_id and r2.role_key = 'owner'
  join public.entities e on e.id = m2.entity_id and e.status = 'active'
  where m1.entity_id = p_entity and m1.status = 'active'
$$;
revoke all on function app_private.tax_group_entities(uuid) from public;

-- Income of a Personal book that its owner's PT paid as a vendor payment (bill or expense), read from the PT's own
-- documents: the payee of the PT matches the person by tax number (NPWP / NIK) or by name. Gross is before VAT and
-- before the income tax the PT withheld; the withheld amount is the PPh credit.
create function app_private.personal_pt_income(p_entity uuid, p_from date, p_to date)
returns table (source_entity uuid, source_name text, contact_id uuid, contact_name text, mo integer, gross numeric, withheld numeric)
language sql stable security definer set search_path = pg_catalog, public as $$
  with me as (
    select e.id, lower(regexp_replace(btrim(e.legal_name), '\s+', ' ', 'g')) as legal_n,
           lower(regexp_replace(btrim(coalesce(e.brand_name, '')), '\s+', ' ', 'g')) as brand_n,
           regexp_replace(coalesce((select p.tax_identifier from public.tax_entity_profiles p
                                    where p.entity_id = e.id and p.superseded_at is null and p.tax_identifier is not null
                                    order by p.effective_from desc limit 1), ''), '[^0-9]', '', 'g') as digits
    from public.entities e where e.id = p_entity and e.entity_type = 'personal'
  ), matches as (
    select c.entity_id, c.id as cid, c.display_name, se.legal_name as ename
    from public.contacts c
    join public.entities se on se.id = c.entity_id and se.entity_type = 'company' and se.status = 'active'
    cross join me
    where c.entity_id in (select app_private.tax_group_entities(p_entity))
      and c.status = 'active'
      and ((length(me.digits) >= 15 and regexp_replace(coalesce(c.tax_identifier, ''), '[^0-9]', '', 'g') = me.digits)
           or c.normalized_name = me.legal_n
           or (me.brand_n <> '' and c.normalized_name = me.brand_n))
  )
  select m.entity_id, m.ename, m.cid, m.display_name, extract(month from b.bill_date)::integer,
         greatest(0, b.base_total + b.withheld_total - b.tax_total * coalesce(b.exchange_rate, 1)), b.withheld_total
  from public.bills b join matches m on m.cid = b.vendor_id and m.entity_id = b.entity_id
  where b.status = 'approved' and b.bill_date between p_from and p_to
  union all
  select m.entity_id, m.ename, m.cid, m.display_name, extract(month from x.expense_date)::integer,
         greatest(0, x.base_total + x.withheld_total - x.tax_total * coalesce(x.exchange_rate, 1)), x.withheld_total
  from public.expenses x join matches m on m.cid = x.payee_id and m.entity_id = x.entity_id
  where x.status = 'confirmed' and x.expense_date between p_from and p_to
$$;
revoke all on function app_private.personal_pt_income(uuid, date, date) from public;

-- Gross turnover of one book between two dates (the same sources the PPh Final base uses, plus, for a Personal
-- book, services of an independent worker and the income read from the owner's own PT).
create function app_private.entity_gross_turnover(p_entity uuid, p_from date, p_to date) returns numeric
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_cur public.currency_code := app_private.entity_base_currency(p_entity);
  v_type text;
  v_total numeric := 0;
begin
  select entity_type into v_type from public.entities where id = p_entity;
  select v_total + coalesce(sum(i.base_total - case when i.currency = v_cur then i.tax_total else 0 end), 0) into v_total
  from public.invoices i where i.entity_id = p_entity and i.status = 'issued' and i.issue_date between p_from and p_to;
  select v_total + coalesce(sum(s.gross_sales), 0) into v_total
  from public.marketplace_settlements s
  where s.entity_id = p_entity and s.status = 'confirmed' and s.settlement_date between p_from and p_to;
  if v_type = 'personal' then
    select v_total + coalesce(sum(n.amount), 0) into v_total
    from public.income_entries n
    join public.categories c on c.id = n.category_id and c.entity_id = n.entity_id
    where n.entity_id = p_entity and n.status = 'recorded' and n.currency = v_cur
      and n.entry_date between p_from and p_to and c.personal_tax_role in ('umkm_business', 'freelance');
    select v_total + coalesce(sum(t.gross), 0) into v_total from app_private.personal_pt_income(p_entity, p_from, p_to) t;
  else
    select v_total + coalesce(sum(n.amount), 0) into v_total
    from public.income_entries n
    where n.entity_id = p_entity and n.status = 'recorded' and n.in_turnover and n.currency = v_cur
      and n.entry_date between p_from and p_to;
  end if;
  return v_total;
end
$$;
revoke all on function app_private.entity_gross_turnover(uuid, date, date) from public;

-- What counts toward the ceiling of an Entity besides its own final-tax base: the other books of the same owner,
-- and, in a Personal book, the services income that the final base itself leaves out.
create function app_private.group_other_turnover(p_entity uuid, p_year integer, p_to date) returns numeric
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_from date := make_date(p_year, 1, 1);
  v_total numeric := 0;
  v_cur public.currency_code := app_private.entity_base_currency(p_entity);
  g uuid;
begin
  for g in select app_private.tax_group_entities(p_entity) loop
    v_total := v_total + app_private.entity_gross_turnover(g, v_from, p_to);
  end loop;
  if exists (select 1 from public.entities where id = p_entity and entity_type = 'personal') then
    select v_total + coalesce(sum(n.amount), 0) into v_total
    from public.income_entries n
    join public.categories c on c.id = n.category_id and c.entity_id = n.entity_id
    where n.entity_id = p_entity and n.status = 'recorded' and n.currency = v_cur
      and n.entry_date between v_from and p_to and c.personal_tax_role = 'freelance';
    select v_total + coalesce(sum(t.gross), 0) into v_total from app_private.personal_pt_income(p_entity, v_from, p_to) t;
  end if;
  return v_total;
end
$$;
revoke all on function app_private.group_other_turnover(uuid, integer, date) from public;

-- The final tax now adds that turnover to the ceiling check by itself. The "is it confirmed" question about
-- spouse and minor children stays as it was: the system cannot read other people's books.
do $$
declare
  v_patch text[][] := array[
    array[$o$v_trace := app_private.tax_trace_add(v_trace, format('Gross turnover of %s: %s; earlier this year$o$,
          $n$v_outside := v_outside + app_private.group_other_turnover(p_entity, extract(year from p_period)::integer, v_end);
  v_trace := app_private.tax_trace_add(v_trace, format('Gross turnover of %s: %s; earlier this year$n$, '1']
  ];
  i integer;
  f record;
  v_n integer;
begin
  for i in 1 .. array_length(v_patch, 1) loop
    v_n := 0;
    for f in
      select p.oid from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'app_private') and p.prokind = 'f' and position(v_patch[i][1] in p.prosrc) > 0
      order by p.oid
    loop
      execute replace(pg_catalog.pg_get_functiondef(f.oid), v_patch[i][1], v_patch[i][2]);
      v_n := v_n + 1;
    end loop;
    if v_n <> v_patch[i][3]::integer then
      raise exception 'group turnover patch % expected % function(s), found %', i, v_patch[i][3], v_n;
    end if;
  end loop;
end
$$;

-- ------------------------------------------------------------ the yearly summary of a Personal book
-- Only reads: the amounts the calculation needs, by month, from the posted documents. The tax itself (tiers, PTKP,
-- Rp 500 juta band) is computed from the rule data returned here, by the application, so it can be tested apart.
create function public.personal_tax_summary(p_entity uuid, p_year integer default null) returns jsonb
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

-- The turnover of the owner's books together, for the Rp 4,8 billion ceiling: shown on Ringkasan Pajak of every book.
create function public.tax_group_turnover(p_entity uuid, p_year integer default null) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_today date;
  v_year integer;
  v_from date;
  v_to date;
  v_final public.tax_rule_versions%rowtype;
  v_rows jsonb;
  v_own numeric;
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
  v_from := make_date(v_year, 1, 1);
  v_to := make_date(v_year, 12, 31);
  select * into v_final from app_private.tax_rule_at('PPH_FINAL_UMKM', v_to);
  v_own := app_private.entity_gross_turnover(p_entity, v_from, v_to);
  select coalesce(jsonb_agg(jsonb_build_object('entity_id', g.id, 'name', coalesce(en.brand_name, en.legal_name),
                     'entity_type', en.entity_type, 'turnover', trim_scale(app_private.entity_gross_turnover(g.id, v_from, v_to))::text)
                     order by en.entity_type, en.legal_name), '[]'::jsonb)
    into v_rows
  from app_private.tax_group_entities(p_entity) as g(id)
  join public.entities en on en.id = g.id
  where app_authz.has_permission(g.id, 'tax.view');
  return jsonb_build_object('year', v_year, 'own_turnover', trim_scale(v_own)::text, 'others', v_rows,
    'ceiling', case when v_final.id is null then null else v_final.params ->> 'annual_ceiling' end);
end
$$;
revoke all on function public.tax_group_turnover(uuid, integer) from public, anon;
grant execute on function public.tax_group_turnover(uuid, integer) to authenticated;
