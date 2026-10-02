-- P14 decision 260 (OWNER): marketplace sales, recorded per settlement (payout), with the marketplace's
-- income-tax collection (PPh Pasal 22, PMK 37/2025, collected from 1 October 2026).
-- Authority: OWNER decisions of 2026-10-02 ("rekap per pencairan", "biaya admin otomatis sebagai beban",
-- "PPh marketplace saya setuju", "ada akun marketplace ... sudah kita rancang dari sekarang"); Step 05 §2,
-- §5-§6, §15 (rules in the versioned master; the final tax is a period computation); Step 03 §6 (category
-- to account mapping); Step 08 (cash movements and journals are posted together).
--
-- One settlement = what one store's payout report says for a span of days:
--   gross sales (before VAT)  ->  Cr revenue (the store's revenue category, else the Entity default)
--   output VAT                ->  Cr Tax Payable, computed from the VAT rule only while the Entity is PKP
--   marketplace fees          ->  Dr expense (the store's fee category, else the Entity default)
--   PPh 22 collected          ->  Dr income-tax expense: for a taxpayer on the final regime it is part of the
--                                 settlement of the final tax (pajak.go.id), so the monthly final-tax
--                                 computation counts the turnover and deducts what was already collected
--   payout                    ->  Dr the receiving cash/bank account = gross + VAT - fees - PPh 22
-- The PPh 22 amount is computed from the rule (0.5% of gross for a designated marketplace, unless the store
-- is recorded as exempt); when the payout report states another amount, that stated amount is the fact.
-- A recorded settlement is never edited: it is reversed and recorded again.

-- ------------------------------------------------------------ stores (marketplace accounts)
create table public.marketplace_stores (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  platform text not null check (platform in
    ('shopee', 'tokopedia', 'lazada', 'blibli', 'tiktok_shop', 'bukalapak', 'other')),
  name text not null check (length(btrim(name)) between 2 and 120),
  settlement_financial_account_id uuid,
  revenue_category_id uuid,
  fee_category_id uuid,
  -- An individual below the turnover threshold who gave the marketplace the statement letter is not collected.
  pph22_exempt boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (entity_id, name),
  foreign key (entity_id, settlement_financial_account_id)
    references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, revenue_category_id) references public.categories (entity_id, id) on delete restrict,
  foreign key (entity_id, fee_category_id) references public.categories (entity_id, id) on delete restrict
);
create trigger tg_forbid_delete before delete on public.marketplace_stores
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.marketplace_stores
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.marketplace_stores');
call app_private.secure_table('public.marketplace_stores');
call app_private.expose_select('public.marketplace_stores');
create trigger tg_audit after insert or update or delete on public.marketplace_stores
  for each row execute function app_private.tg_audit('entity_id');
create policy marketplace_stores_select on public.marketplace_stores for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view'));

-- ------------------------------------------------------------ settlements
create table public.marketplace_settlements (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  store_id uuid not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'reversed')),
  period_start date not null,
  period_end date not null,
  -- The date the money arrived; it is also the date of the journal and the tax period of the sale.
  settlement_date date not null,
  currency public.currency_code not null,
  gross_sales public.money_amount not null check (gross_sales > 0),
  vat_amount public.money_amount not null default 0 check (vat_amount >= 0),
  fee_amount public.money_amount not null default 0 check (fee_amount >= 0),
  pph22_amount public.money_amount not null default 0 check (pph22_amount >= 0),
  -- What the rule computed, kept beside the amount actually collected.
  pph22_computed public.money_amount not null default 0 check (pph22_computed >= 0),
  payout_amount public.money_amount not null check (payout_amount >= 0),
  financial_account_id uuid not null,
  reference text check (reference is null or length(reference) <= 200),
  note text check (note is null or length(note) <= 1000),
  tax_trace jsonb not null default '[]'::jsonb,
  journal_id uuid not null,
  reversal_journal_id uuid,
  reversed_at timestamptz,
  reversed_date date,
  reversed_by uuid,
  reverse_reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, store_id) references public.marketplace_stores (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id, currency)
    references public.financial_accounts (entity_id, id, currency) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint marketplace_settlement_span check (period_end >= period_start and settlement_date >= period_start),
  constraint marketplace_settlement_payout check (
    payout_amount = gross_sales + vat_amount - fee_amount - pph22_amount),
  constraint marketplace_settlement_state check (
    (status = 'confirmed' and reversal_journal_id is null and reversed_at is null)
    or (status = 'reversed' and reversal_journal_id is not null and reversed_at is not null
        and reversed_date is not null and reverse_reason is not null))
);
create index marketplace_settlements_date_idx on public.marketplace_settlements (entity_id, settlement_date);
create index marketplace_settlements_store_idx on public.marketplace_settlements (entity_id, store_id, settlement_date);

create function app_private.tg_marketplace_settlements_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by',
                                   'reverse_reason', 'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' then
    raise exception 'A reversed settlement cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a recorded settlement cannot be changed; reverse it instead'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
revoke all on function app_private.tg_marketplace_settlements_guard() from public;
create trigger tg_guard before update on public.marketplace_settlements
  for each row execute function app_private.tg_marketplace_settlements_guard();
create trigger tg_forbid_delete before delete on public.marketplace_settlements
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.marketplace_settlements
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.marketplace_settlements');
call app_private.secure_table('public.marketplace_settlements');
call app_private.expose_select('public.marketplace_settlements');
create trigger tg_audit after insert or update or delete on public.marketplace_settlements
  for each row execute function app_private.tg_audit('entity_id');
create policy marketplace_settlements_select on public.marketplace_settlements for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view'));

-- ------------------------------------------------------------ rule master
-- Stored under the family "other": the engine reads the rate, the designated marketplaces and the rounding.
insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
values
  ('other', 'PPH22_MARKETPLACE', 1, date '2026-10-01',
   '{"rate":"0.005","platforms":["shopee","tokopedia","lazada","blibli"],"rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'PMK 37 Tahun 2025: PPh Pasal 22 collected by designated marketplaces, 0.5% of gross turnover excluding VAT; collection starts 1 October 2026',
   'PMK 37/2025; DJP announcement "Pemungutan PPh Pasal 22 Melalui Marketplace Mulai Dilaksanakan 1 Oktober 2026"',
   'https://pajak.go.id/en/node/120661', date '2026-10-02', 'verified', 'published', now(),
   'Designated collectors on the verification date: Shopee, Tokopedia, Blibli (Global Digital Niaga), Lazada (Ecart Webportal). An individual with yearly turnover up to Rp500 million who gave the marketplace the statement letter is not collected: record that on the store. For a taxpayer on the final regime the amount collected is part of the settlement of the final tax; otherwise it is a credit of the tax year (not modelled).')
on conflict (code, rule_version) do nothing;

-- ------------------------------------------------------------ vocabulary of the tax layer
alter table public.tax_determinations drop constraint tax_determinations_source_type_check;
alter table public.tax_determinations add constraint tax_determinations_source_type_check
  check (source_type in ('invoice', 'bill', 'expense', 'period', 'payroll_run', 'marketplace_settlement'));

-- The patches below change one expression each; the exact old text must be present or the migration fails.
do $$
declare
  v_patch text[][] := array[
    -- a settlement that books output VAT is part of the tax workflow
    array[$o$j.source_type in ('invoice', 'bill', 'expense', 'tax_payment', 'tax_period', 'payroll_run')$o$,
          $n$j.source_type in ('invoice', 'bill', 'expense', 'tax_payment', 'tax_period', 'payroll_run', 'marketplace_settlement')$n$, '1'],
    array[$o$o.source_type in ('invoice', 'bill', 'expense', 'tax_payment', 'tax_period', 'payroll_run')$o$,
          $n$o.source_type in ('invoice', 'bill', 'expense', 'tax_payment', 'tax_period', 'payroll_run', 'marketplace_settlement')$n$, '1'],
    -- the final tax of a month: marketplace turnover counts, and what the marketplace collected is deducted
    array[$o$  v_dp integer;
begin
  v_out := jsonb_build_object('entity_id', p_entity, 'tax_period', p_period,$o$,
          $n$  v_dp integer;
  v_mp_month numeric := 0;
  v_mp_prior numeric := 0;
  v_credit numeric := 0;
  v_gross_tax numeric := 0;
begin
  v_out := jsonb_build_object('entity_id', p_entity, 'tax_period', p_period,$n$, '1'],
    array[$o$  if p.aggregation_status = 'applies' then
    select coalesce(sum(f.amount), 0) into v_outside from public.tax_aggregation_facts f$o$,
          $n$  select coalesce(sum(s.gross_sales) filter (where s.settlement_date >= p_period), 0),
         coalesce(sum(s.gross_sales) filter (where s.settlement_date < p_period), 0),
         coalesce(sum(s.pph22_amount) filter (where s.settlement_date >= p_period), 0)
    into v_mp_month, v_mp_prior, v_credit
  from public.marketplace_settlements s
  where s.entity_id = p_entity and s.status = 'confirmed' and s.settlement_date between v_year_start and v_end;
  v_month := v_month + v_mp_month;
  v_prior := v_prior + v_mp_prior;
  if p.aggregation_status = 'applies' then
    select coalesce(sum(f.amount), 0) into v_outside from public.tax_aggregation_facts f$n$, '1'],
    array[$o$  v_tax := app_private.round_amount(v_taxable * v_rate, v_dp, v_mode);$o$,
          $n$  v_gross_tax := app_private.round_amount(v_taxable * v_rate, v_dp, v_mode);
  v_tax := greatest(0, v_gross_tax - v_credit);$n$, '1'],
    array[$o$  v_trace := app_private.tax_trace_add(v_trace, format('PPh Final = %s x %s = %s (rounded %s to %s decimals)', trim_scale(v_taxable), trim_scale(v_rate), trim_scale(v_tax), v_mode, v_dp));$o$,
          $n$  v_trace := app_private.tax_trace_add(v_trace, format('PPh Final = %s x %s = %s (rounded %s to %s decimals)', trim_scale(v_taxable), trim_scale(v_rate), trim_scale(v_gross_tax), v_mode, v_dp));
  if v_mp_month > 0 or v_credit > 0 then
    v_trace := app_private.tax_trace_add(v_trace, format(
      'Marketplace settlements of the month: turnover %s (included above); PPh 22 already collected by the marketplaces %s is part of the settlement of the final tax, so %s remains to pay%s',
      trim_scale(v_mp_month), trim_scale(v_credit), trim_scale(v_tax),
      case when v_credit > v_gross_tax then format(' (%s more was collected than the final tax of the month; the excess is not carried automatically)', trim_scale(v_credit - v_gross_tax)) else '' end));
  end if;$n$, '1'],
    array[$o$'turnover_outside', trim_scale(v_outside)::text, 'ceiling', trim_scale(v_ceiling)::text,$o$,
          $n$'turnover_outside', trim_scale(v_outside)::text, 'turnover_marketplace', trim_scale(v_mp_month)::text,
    'gross_tax', trim_scale(v_gross_tax)::text, 'collected_credit', trim_scale(v_credit)::text,
    'ceiling', trim_scale(v_ceiling)::text,$n$, '1']
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
      raise exception 'marketplace patch % expected % function(s), found %', i, v_patch[i][3], v_n;
    end if;
  end loop;
end
$$;

-- ------------------------------------------------------------ commands
create function public.create_marketplace_store(
  p_entity uuid, p_key text, p_platform text, p_name text, p_account uuid default null,
  p_revenue_category uuid default null, p_fee_category uuid default null, p_pph22_exempt boolean default false)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_name text := btrim(coalesce(p_name, ''));
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.create') then
    raise exception 'FORBIDDEN: adding a marketplace store needs invoices.create' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('marketplace.store_create', p_entity, p_key,
    md5(jsonb_build_object('p', p_platform, 'n', v_name, 'a', p_account, 'r', p_revenue_category, 'f', p_fee_category,
                           'x', coalesce(p_pph22_exempt, false))::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p_platform is null or p_platform not in ('shopee', 'tokopedia', 'lazada', 'blibli', 'tiktok_shop', 'bukalapak', 'other') then
    raise exception 'INVALID: unknown marketplace' using errcode = 'invalid_parameter_value';
  end if;
  if length(v_name) not between 2 and 120 then
    raise exception 'INVALID: the store name needs 2 to 120 characters' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.marketplace_stores s where s.entity_id = p_entity and lower(s.name) = lower(v_name)) then
    raise exception 'CONFLICT: a store with this name already exists' using errcode = 'unique_violation';
  end if;
  if p_account is not null and not exists (
       select 1 from public.financial_accounts a where a.id = p_account and a.entity_id = p_entity and a.is_active) then
    raise exception 'INVALID: the receiving account is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;
  if p_revenue_category is not null and not exists (
       select 1 from public.categories c where c.id = p_revenue_category and c.entity_id = p_entity and c.kind = 'revenue') then
    raise exception 'INVALID: the sales category must be a revenue category of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_fee_category is not null and not exists (
       select 1 from public.categories c where c.id = p_fee_category and c.entity_id = p_entity and c.kind = 'expense') then
    raise exception 'INVALID: the fee category must be an expense category of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  insert into public.marketplace_stores
    (entity_id, platform, name, settlement_financial_account_id, revenue_category_id, fee_category_id, pph22_exempt)
  values (p_entity, p_platform, v_name, p_account, p_revenue_category, p_fee_category, coalesce(p_pph22_exempt, false))
  returning id into v_id;
  perform app_private.idem_complete('marketplace.store_create', p_entity, p_key, 'marketplace_stores', v_id);
  return v_id;
end
$$;

-- What a settlement means for tax on its date: the PPh 22 the rule computes and the output VAT, with the trace.
create function app_private.marketplace_tax(p_entity uuid, p_store uuid, p_date date, p_gross numeric) returns jsonb
language plpgsql stable as $$
declare
  s public.marketplace_stores%rowtype;
  p public.tax_entity_profiles%rowtype;
  r public.tax_rule_versions%rowtype;
  v public.tax_rule_versions%rowtype;
  v_eng date := app_private.tax_engine_from(p_entity);
  v_trace jsonb := '[]'::jsonb;
  v_pph22 numeric := 0;
  v_vat numeric := 0;
  v_vat_rule jsonb := null;
begin
  select * into s from public.marketplace_stores where id = p_store and entity_id = p_entity;
  p := app_private.tax_profile_at(p_entity, p_date);
  r := app_private.tax_rule_at('PPH22_MARKETPLACE', p_date);
  if r.id is null then
    v_trace := app_private.tax_trace_add(v_trace, format('No marketplace collection rule is in force on %s: nothing is computed.', p_date));
  elsif not (r.params -> 'platforms') ? s.platform then
    v_trace := app_private.tax_trace_add(v_trace, format('%s is not a designated collector under rule %s v%s: nothing is computed.', s.platform, r.code, r.rule_version));
  elsif s.pph22_exempt then
    v_trace := app_private.tax_trace_add(v_trace, 'The store is recorded as exempt (statement letter given to the marketplace): nothing is computed.');
  else
    v_pph22 := app_private.tax_round(r.params, p_gross * (r.params ->> 'rate')::numeric);
    v_trace := app_private.tax_trace_add(v_trace, format('PPh 22 collected by the marketplace = %s x %s = %s (rule %s v%s).',
      trim_scale(p_gross), r.params ->> 'rate', trim_scale(v_pph22), r.code, r.rule_version));
  end if;
  if v_eng is not null and p_date >= v_eng and p.id is not null and p.vat_status = 'pkp' then
    v := app_private.tax_rule_at('PPN_STANDARD', p_date);
    if v.id is null then
      raise exception 'CONFLICT: the Entity is PKP but no VAT rule is in force on %; the rate is never guessed', p_date
        using errcode = 'integrity_constraint_violation';
    end if;
    v_vat := app_private.tax_round(v.params,
      p_gross * (v.params ->> 'dpp_numerator')::numeric / (v.params ->> 'dpp_denominator')::numeric * (v.params ->> 'rate')::numeric);
    v_vat_rule := app_private.tax_rule_ref(v);
    v_trace := app_private.tax_trace_add(v_trace, format('The Entity is PKP on %s: output VAT = %s x %s/%s x %s = %s (rule %s v%s).',
      p_date, trim_scale(p_gross), v.params ->> 'dpp_numerator', v.params ->> 'dpp_denominator', v.params ->> 'rate',
      trim_scale(v_vat), v.code, v.rule_version));
  else
    v_trace := app_private.tax_trace_add(v_trace, 'No output VAT: the Entity is not PKP on this date (or the tax engine is not active yet).');
  end if;
  return jsonb_build_object('pph22', v_pph22, 'vat', v_vat, 'vat_rule', v_vat_rule, 'trace', v_trace,
                            'regime', p.income_regime, 'profile_id', p.id);
end
$$;
revoke all on function app_private.marketplace_tax(uuid, uuid, date, numeric) from public;

create function public.record_marketplace_settlement(
  p_entity uuid, p_key text, p_store uuid, p_period_start date, p_period_end date, p_settlement_date date,
  p_account uuid, p_gross text, p_fees text default '0', p_pph22 text default null, p_reference text default null,
  p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  s public.marketplace_stores%rowtype;
  fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_scale integer;
  v_gross numeric;
  v_fees numeric;
  v_pph22 numeric;
  v_tax jsonb;
  v_vat numeric;
  v_payout numeric;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid := gen_random_uuid();
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_det uuid;
  v_trace jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not (app_authz.has_permission(p_entity, 'invoices.issue') and app_authz.has_permission(p_entity, 'invoices.confirm_payment')) then
    raise exception 'FORBIDDEN: recording a marketplace settlement needs invoices.issue and invoices.confirm_payment'
      using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('marketplace.settlement', p_entity, p_key,
    md5(jsonb_build_object('s', p_store, 'a', p_period_start, 'b', p_period_end, 'd', p_settlement_date, 'f', p_account,
                           'g', p_gross, 'e', p_fees, 't', p_pph22, 'r', p_reference, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  select * into s from public.marketplace_stores where id = p_store and entity_id = p_entity;
  if not found or not s.is_active then
    raise exception 'INVALID: the marketplace store is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;
  if p_period_start is null or p_period_end is null or p_period_end < p_period_start then
    raise exception 'INVALID: the sales span needs a start and an end, the end not before the start' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_settlement_date);
  if p_settlement_date > app_private.entity_today(p_entity) or p_settlement_date < p_period_start then
    raise exception 'INVALID: the payout date cannot be in the future or before the sales span starts' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(v_ref, '')) > 200 or length(coalesce(v_note, '')) > 1000 then
    raise exception 'INVALID: the reference is limited to 200 and the note to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
  if not found or not fa.is_active then
    raise exception 'INVALID: the receiving account is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;
  if fa.currency <> e.base_currency then
    raise exception 'INVALID: a settlement is received in the Entity''s base currency (%)', e.base_currency
      using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(e.base_currency);
  v_gross := app_private.parse_amount(p_gross, 'the gross sales');
  v_fees := app_private.parse_amount(coalesce(nullif(btrim(p_fees), ''), '0'), 'the marketplace fees');
  if v_gross <= 0 or v_fees < 0
     or app_private.round_amount(v_gross, v_scale, 'down') <> v_gross
     or app_private.round_amount(v_fees, v_scale, 'down') <> v_fees then
    raise exception 'INVALID: gross sales must be positive and fees not negative, with at most % decimals', v_scale
      using errcode = 'invalid_parameter_value';
  end if;

  v_tax := app_private.marketplace_tax(p_entity, p_store, p_settlement_date, v_gross);
  v_trace := v_tax -> 'trace';
  v_vat := (v_tax ->> 'vat')::numeric;
  if nullif(btrim(coalesce(p_pph22, '')), '') is null then
    v_pph22 := (v_tax ->> 'pph22')::numeric;
  else
    v_pph22 := app_private.parse_amount(p_pph22, 'the PPh 22 collected');
    if v_pph22 < 0 or app_private.round_amount(v_pph22, v_scale, 'down') <> v_pph22 then
      raise exception 'INVALID: the PPh 22 collected cannot be negative and has at most % decimals', v_scale
        using errcode = 'invalid_parameter_value';
    end if;
    if v_pph22 <> (v_tax ->> 'pph22')::numeric then
      v_trace := app_private.tax_trace_add(v_trace, format(
        'The payout report states %s collected; the rule would give %s. The stated amount is the fact that is booked.',
        trim_scale(v_pph22), trim_scale((v_tax ->> 'pph22')::numeric)));
    end if;
  end if;
  if v_pph22 > 0 and coalesce(v_tax ->> 'regime', 'unknown') <> 'final_umkm' then
    raise exception 'CONFLICT: PPh 22 collected by a marketplace is only handled for a taxpayer on the final regime; record the tax profile first or enter 0'
      using errcode = 'integrity_constraint_violation';
  end if;
  v_payout := v_gross + v_vat - v_fees - v_pph22;
  if v_payout < 0 then
    raise exception 'INVALID: fees and tax (%) exceed the sales (%); the payout cannot be negative',
      trim_scale(v_fees + v_pph22), trim_scale(v_gross + v_vat) using errcode = 'invalid_parameter_value';
  end if;

  v_desc := format('Marketplace settlement - %s %s to %s', s.name, to_char(p_period_start, 'YYYY-MM-DD'), to_char(p_period_end, 'YYYY-MM-DD'));
  if v_payout > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', v_payout, 'credit', 0, 'description', v_desc);
  end if;
  if v_fees > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_id', app_private.resolve_purchase_account(p_entity, s.fee_category_id, 'expense', null, p_settlement_date),
      'debit', v_fees, 'credit', 0, 'description', 'Marketplace fees: ' || v_desc);
  end if;
  if v_pph22 > 0 then
    v_lines := v_lines || jsonb_build_object(
      'account_key', case e.entity_type when 'company' then 'INCOME_TAX_EXPENSE' else 'PERSONAL_TAX' end,
      'debit', v_pph22, 'credit', 0, 'description', 'PPh 22 collected by the marketplace: ' || v_desc);
  end if;
  v_lines := v_lines || jsonb_build_object(
    'account_id', app_private.resolve_revenue_account(p_entity, s.revenue_category_id, p_settlement_date),
    'debit', 0, 'credit', v_gross, 'description', v_desc);
  if v_vat > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'TAX_PAYABLE', 'debit', 0, 'credit', v_vat,
      'description', 'Output VAT: ' || v_desc);
  end if;
  perform 1 from public.financial_accounts where id = p_account and entity_id = p_entity for no key update;
  v_journal := app_private.post_system_journal(p_entity, 'marketplace_settlement', v_id, 'marketplace_settlement.confirm',
    'marketplace_settlement.v1', p_settlement_date, v_desc, v_lines);
  if v_payout > 0 then
    perform app_private.record_movement(p_entity, p_account, 'in', v_payout, v_payout, null, p_settlement_date,
      'marketplace_settlement', v_id, 'principal', v_journal, v_desc);
  end if;
  insert into public.marketplace_settlements
    (id, entity_id, store_id, period_start, period_end, settlement_date, currency, gross_sales, vat_amount, fee_amount,
     pph22_amount, pph22_computed, payout_amount, financial_account_id, reference, note, tax_trace, journal_id)
  values
    (v_id, p_entity, p_store, p_period_start, p_period_end, p_settlement_date, e.base_currency, v_gross, v_vat, v_fees,
     v_pph22, (v_tax ->> 'pph22')::numeric, v_payout, p_account, v_ref, v_note, v_trace, v_journal);
  if v_vat > 0 then
    insert into public.tax_determinations
      (entity_id, tax_kind, tax_type, source_type, source_id, event_date, tax_period, status, currency, base_amount,
       rate, tax_amount, direction, rules, facts, trace, components, consequence, journal_id, confirmed)
    values
      (p_entity, 'vat_output', 'vat', 'marketplace_settlement', v_id, p_settlement_date,
       app_private.tax_period_start(p_settlement_date), 'auto_determined', e.base_currency, v_gross, null, v_vat, 'payable',
       jsonb_build_array(v_tax -> 'vat_rule'), jsonb_build_object('profile_id', v_tax ->> 'profile_id', 'store_id', p_store),
       v_trace, '[]'::jsonb,
       format('Output VAT of %s is credited to Tax Payables and accrues in the VAT ledger.', trim_scale(v_vat)), v_journal, false)
    returning id into v_det;
    insert into public.tax_ledger_entries
      (entity_id, determination_id, tax_kind, tax_type, tax_period, direction, entry_kind, amount, entry_date,
       journal_id, description)
    values (p_entity, v_det, 'vat_output', 'vat', app_private.tax_period_start(p_settlement_date), 'payable', 'accrual',
            v_vat, p_settlement_date, v_journal, left(v_desc, 300));
  end if;
  perform app_private.idem_complete('marketplace.settlement', p_entity, p_key, 'marketplace_settlements', v_id);
  return v_id;
end
$$;

create function public.reverse_marketplace_settlement(p_settlement uuid, p_key text, p_date date, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.marketplace_settlements%rowtype;
  m public.money_movements%rowtype;
  v_replay uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into s from public.marketplace_settlements where id = p_settlement for update;
  if not found or not app_authz.has_permission(s.entity_id, 'invoices.void') then
    raise exception 'FORBIDDEN: reversing a marketplace settlement needs invoices.void' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('marketplace.settlement_reverse', s.entity_id, p_key,
    md5(jsonb_build_object('s', p_settlement, 'd', p_date, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if s.status <> 'confirmed' then
    raise exception 'CONFLICT: the settlement is already reversed' using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date < s.settlement_date or p_date > app_private.entity_today(s.entity_id) then
    raise exception 'INVALID: the reversal date cannot be before the settlement or in the future' using errcode = 'invalid_parameter_value';
  end if;
  if length(v_reason) not between 5 and 500 then
    raise exception 'INVALID: a reason of 5 to 500 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  v_rev := app_private.reverse_journal_core(s.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = s.entity_id and source_type = 'marketplace_settlement' and source_id = s.id and reverses_movement_id is null
  loop
    perform app_private.record_movement(s.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'marketplace_settlement', s.id, m.component, v_rev,
      'Reversal: ' || v_reason, m.id);
  end loop;
  perform app_private.tax_reverse_source('marketplace_settlement', s.id, v_rev, p_date, v_reason);
  update public.marketplace_settlements
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date,
      reversed_by = auth.uid(), reverse_reason = v_reason
  where id = s.id;
  perform app_private.idem_complete('marketplace.settlement_reverse', s.entity_id, p_key, 'marketplace_settlements', s.id);
  return s.id;
end
$$;

-- What a settlement would book, before it is recorded (the form shows it).
create function public.preview_marketplace_settlement(p_entity uuid, p_store uuid, p_date date, p_gross text)
returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.view') then
    raise exception 'FORBIDDEN: missing invoices.view' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.marketplace_stores s where s.id = p_store and s.entity_id = p_entity) then
    raise exception 'INVALID: unknown marketplace store' using errcode = 'invalid_parameter_value';
  end if;
  v := app_private.marketplace_tax(p_entity, p_store, p_date, app_private.parse_amount(p_gross, 'the gross sales'));
  return jsonb_build_object('pph22', v ->> 'pph22', 'vat', v ->> 'vat', 'trace', v -> 'trace');
end
$$;

revoke all on function public.create_marketplace_store(uuid, text, text, text, uuid, uuid, uuid, boolean) from public, anon;
revoke all on function public.record_marketplace_settlement(uuid, text, uuid, date, date, date, uuid, text, text, text, text, text) from public, anon;
revoke all on function public.reverse_marketplace_settlement(uuid, text, date, text) from public, anon;
revoke all on function public.preview_marketplace_settlement(uuid, uuid, date, text) from public, anon;
grant execute on function public.create_marketplace_store(uuid, text, text, text, uuid, uuid, uuid, boolean) to authenticated;
grant execute on function public.record_marketplace_settlement(uuid, text, uuid, date, date, date, uuid, text, text, text, text, text) to authenticated;
grant execute on function public.reverse_marketplace_settlement(uuid, text, date, text) to authenticated;
grant execute on function public.preview_marketplace_settlement(uuid, uuid, date, text) to authenticated;
