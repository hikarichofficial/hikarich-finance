-- P1 (Step 15 §5): accounting foundation tables and their HARD invariants.
-- Authority: Step 02 §4/§6 (Accounting), Step 03 (COA architecture), Step 04 §2/§11/§12/§15,
-- Step 07 §17 (period workflow), Step 08 §3/§6/§14/§15.
--
-- P1 delivers the data model and the database-enforced invariants (balanced, immutable journals;
-- closed periods; protected accounts; idempotent posting identity). The posting ENGINE (rules that
-- generate journals, reversal orchestration, closing) is P3 and must use these tables.

-- =========================================================== ledger accounts (Step 03)
create table public.ledger_accounts (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  code text not null check (code ~ '^[0-9]{4,10}$'),
  name text not null check (length(btrim(name)) > 0),
  account_class text not null check (account_class in (
    'asset', 'contra_asset', 'liability', 'equity', 'revenue', 'contra_revenue',
    'expense', 'other_income', 'other_expense', 'other', 'tax', 'special')),
  -- For "mixed" accounts (Step 03 §2 ranges 7xxx/8xxx) this is a presentation default only.
  normal_balance text not null check (normal_balance in ('debit', 'credit')),
  -- Stable internal accounting key (Step 03 §1). Posting logic uses keys, never names or codes.
  system_key text check (system_key is null or system_key ~ '^[A-Z][A-Z0-9_]*$'),
  parent_id uuid,
  is_group boolean not null default false,
  is_control boolean not null default false,
  allows_manual_posting boolean not null default false,
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (entity_id, code),
  foreign key (entity_id, parent_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  check (parent_id is null or parent_id <> id),
  check (not (is_group and allows_manual_posting))
);
create unique index ledger_accounts_system_key_uq
  on public.ledger_accounts (entity_id, system_key) where system_key is not null;

create function app_private.tg_ledger_accounts_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.system_key is not null or old.is_control then
      raise exception 'Protected account % (%) cannot be deleted; deactivate a normal account instead', old.code, old.name
        using errcode = 'integrity_constraint_violation';
    end if;
    return old;
  end if;

  if old.system_key is not null and new.system_key is distinct from old.system_key then
    raise exception 'System key of account % is stable and cannot change (Step 03 §1)', old.code
      using errcode = 'integrity_constraint_violation';
  end if;
  if old.system_key is not null and new.status = 'inactive' and old.status = 'active' then
    raise exception 'System account % cannot be deactivated (Step 03 §10)', old.code
      using errcode = 'integrity_constraint_violation';
  end if;
  if (new.account_class, new.normal_balance, new.is_group)
     is distinct from (old.account_class, old.normal_balance, old.is_group)
     and exists (select 1 from public.journal_lines jl where jl.ledger_account_id = old.id limit 1) then
    raise exception 'Account % already has posted history; class/normal balance/group flag cannot change', old.code
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update or delete on public.ledger_accounts
  for each row execute function app_private.tg_ledger_accounts_guard();
create trigger tg_no_cycle before insert or update of parent_id on public.ledger_accounts
  for each row execute function app_private.tg_no_parent_cycle();
call app_private.apply_standard_triggers('public.ledger_accounts');
call app_private.secure_table('public.ledger_accounts');
create trigger tg_audit after insert or update or delete on public.ledger_accounts
  for each row execute function app_private.tg_audit('entity_id');

-- =========================================================== default COA templates (Step 03 §3-§4, §11)
-- Reference data (configuration, not hard-coded UI logic). New Entities receive a copy through
-- app_private.provision_default_coa(). Later phases add accounts by extending the template and
-- calling the (idempotent) provisioning function for existing Entities in a forward migration.
create table public.coa_templates (
  template_key text primary key check (template_key ~ '^[a-z][a-z0-9_]*$'),
  entity_type text not null check (entity_type in ('company', 'personal')),
  name text not null,
  revision integer not null default 1
);
create table public.coa_template_accounts (
  template_key text not null references public.coa_templates (template_key) on delete cascade,
  code text not null check (code ~ '^[0-9]{4,10}$'),
  name text not null,
  account_class text not null,
  normal_balance text not null check (normal_balance in ('debit', 'credit')),
  system_key text,
  parent_code text,
  is_group boolean not null default false,
  is_control boolean not null default false,
  allows_manual_posting boolean not null default false,
  primary key (template_key, code)
);
call app_private.secure_table('public.coa_templates');
call app_private.secure_table('public.coa_template_accounts');

insert into public.coa_templates (template_key, entity_type, name)
values ('company_default', 'company', 'PT Hikarich Kitana Digital default COA (Step 03 §3)'),
       ('personal_default', 'personal', 'Personal Entity default COA (Step 03 §4)');

-- Source rows: (template, code, name, class, system_key, parent_code, is_group).
-- Classes: Step 03 "Net Assets/Income/Other/Special" map to equity/revenue/other/special.
with src (template_key, code, name, account_class, system_key, parent_code, is_group) as (values
  -- ---------------- PT (Step 03 §3)
  ('company_default', '1100', 'Cash & Cash Equivalents', 'asset', null, null, true),
  ('company_default', '1110', 'Cash on Hand', 'asset', 'CASH', '1100', false),
  ('company_default', '1120', 'BCA Operating Account', 'asset', 'BANK_OPERATING', '1100', false),
  ('company_default', '1190', 'Other Bank / E-wallet Accounts', 'asset', 'OTHER_CASH_ACCOUNT', '1100', false),
  ('company_default', '1200', 'Accounts Receivable', 'asset', 'ACCOUNTS_RECEIVABLE', null, false),
  ('company_default', '1210', 'Other Receivables', 'asset', 'OTHER_RECEIVABLE', null, false),
  ('company_default', '1300', 'Prepaid Expenses', 'asset', 'PREPAID_EXPENSE', null, false),
  ('company_default', '1310', 'Advances / Deposits', 'asset', 'ADVANCES_DEPOSITS', null, false),
  ('company_default', '1400', 'Tax Assets / Prepaid Tax', 'asset', 'TAX_ASSET', null, false),
  ('company_default', '1500', 'Fixed Assets', 'asset', null, null, true),
  ('company_default', '1510', 'Computer & Electronic Equipment', 'asset', 'FIXED_ASSET_EQUIPMENT', '1500', false),
  ('company_default', '1520', 'Furniture & Office Equipment', 'asset', 'FIXED_ASSET_FURNITURE', '1500', false),
  ('company_default', '1530', 'Other Fixed Assets', 'asset', 'FIXED_ASSET_OTHER', '1500', false),
  ('company_default', '1590', 'Accumulated Depreciation', 'contra_asset', 'ACCUMULATED_DEPRECIATION', '1500', false),
  ('company_default', '2100', 'Accounts Payable', 'liability', 'ACCOUNTS_PAYABLE', null, false),
  ('company_default', '2110', 'Other Payables', 'liability', 'OTHER_PAYABLE', null, false),
  ('company_default', '2200', 'Tax Payables', 'liability', 'TAX_PAYABLE', null, false),
  ('company_default', '2210', 'Employee / Payroll Liabilities', 'liability', 'PAYROLL_LIABILITY', null, false),
  ('company_default', '2220', 'BPJS / Related Liabilities', 'liability', 'BPJS_LIABILITY', null, false),
  ('company_default', '2300', 'Short-term Loans', 'liability', 'LOAN_SHORT_TERM', null, false),
  ('company_default', '2400', 'Long-term Loans', 'liability', 'LOAN_LONG_TERM', null, false),
  ('company_default', '2500', 'Customer Advances / Unearned Revenue', 'liability', 'CUSTOMER_ADVANCE', null, false),
  ('company_default', '3100', 'Owner Capital / Paid-in Capital', 'equity', 'OWNER_CAPITAL', null, false),
  ('company_default', '3200', 'Additional Equity / Contributions', 'equity', 'ADDITIONAL_EQUITY', null, false),
  ('company_default', '3300', 'Retained Earnings', 'equity', 'RETAINED_EARNINGS', null, false),
  ('company_default', '3400', 'Current Year Earnings', 'equity', 'CURRENT_YEAR_EARNINGS', null, false),
  ('company_default', '4100', 'Digital Product Revenue', 'revenue', 'DIGITAL_PRODUCT_REVENUE', null, false),
  ('company_default', '4110', 'E-book / Digital Publication Revenue', 'revenue', 'EBOOK_REVENUE', null, false),
  ('company_default', '4120', 'Software / Digital Tool Revenue', 'revenue', 'SOFTWARE_REVENUE', null, false),
  ('company_default', '4190', 'Other Operating Revenue', 'revenue', 'OTHER_OPERATING_REVENUE', null, false),
  ('company_default', '4200', 'Sales Discounts / Refund Adjustments', 'contra_revenue', 'SALES_CONTRA', null, false),
  ('company_default', '5100', 'Direct Product / Delivery Costs', 'expense', 'DIRECT_COST', null, false),
  ('company_default', '5200', 'Payment Gateway / Merchant Direct Fees', 'expense', 'PAYMENT_PROCESSING_COST', null, false),
  ('company_default', '6100', 'Marketing & Advertising', 'expense', 'MARKETING_EXPENSE', null, false),
  ('company_default', '6110', 'Content / Creative Production', 'expense', 'CONTENT_PRODUCTION_EXPENSE', null, false),
  ('company_default', '6200', 'Software & Subscriptions', 'expense', 'SOFTWARE_SUBSCRIPTION_EXPENSE', null, false),
  ('company_default', '6210', 'Hosting / Domain / Cloud Services', 'expense', 'HOSTING_CLOUD_EXPENSE', null, false),
  ('company_default', '6300', 'Bank & Administration Fees', 'expense', 'BANK_FEE_EXPENSE', null, false),
  ('company_default', '6400', 'Professional / Legal / Accounting Fees', 'expense', 'PROFESSIONAL_FEE_EXPENSE', null, false),
  ('company_default', '6500', 'Office & General Expenses', 'expense', 'OFFICE_GENERAL_EXPENSE', null, false),
  ('company_default', '6510', 'Communication & Internet', 'expense', 'COMMUNICATION_EXPENSE', null, false),
  ('company_default', '6520', 'Travel & Transportation', 'expense', 'TRAVEL_TRANSPORT_EXPENSE', null, false),
  ('company_default', '6600', 'Salary & Employee Benefits', 'expense', 'SALARY_EXPENSE', null, false),
  ('company_default', '6610', 'Employer BPJS / Employee-related Cost', 'expense', 'EMPLOYER_BENEFIT_EXPENSE', null, false),
  ('company_default', '6700', 'Depreciation Expense', 'expense', 'DEPRECIATION_EXPENSE', null, false),
  ('company_default', '6800', 'Rent / Workspace', 'expense', 'RENT_EXPENSE', null, false),
  ('company_default', '6900', 'Other Operating Expenses', 'expense', 'OTHER_OPERATING_EXPENSE', null, false),
  ('company_default', '7100', 'Interest Income', 'other_income', 'INTEREST_INCOME', null, false),
  ('company_default', '7190', 'Other Non-operating Income', 'other_income', 'OTHER_NONOPERATING_INCOME', null, false),
  ('company_default', '7200', 'Interest Expense', 'other_expense', 'INTEREST_EXPENSE', null, false),
  ('company_default', '7290', 'Other Non-operating Expense', 'other_expense', 'OTHER_NONOPERATING_EXPENSE', null, false),
  ('company_default', '7300', 'Foreign Exchange Gain / Loss', 'other', 'FX_GAIN_LOSS', null, false),
  ('company_default', '8100', 'Current Income Tax Expense / Tax Adjustment', 'tax', 'INCOME_TAX_EXPENSE', null, false),
  ('company_default', '8200', 'Tax Penalty / Non-deductible Tax-related Expense', 'tax', 'TAX_PENALTY_EXPENSE', null, false),
  ('company_default', '8900', 'Opening Balance / Migration Clearing', 'special', 'OPENING_BALANCE_CLEARING', null, false),
  -- Accounts the Step 04 posting matrix needs but Step 03 does not list (DECISIONS: resolved by authority #4).
  ('company_default', '2120', 'Dividend / Distribution Payable', 'liability', 'DIVIDEND_PAYABLE', null, false),
  ('company_default', '6950', 'Bad Debt Expense', 'expense', 'BAD_DEBT_EXPENSE', null, false),
  ('company_default', '7310', 'Rounding Differences', 'other', 'ROUNDING_DIFFERENCE', null, false),
  ('company_default', '7400', 'Gain / Loss on Asset Disposal', 'other', 'ASSET_DISPOSAL_GAIN_LOSS', null, false),
  -- ---------------- Personal (Step 03 §4)
  ('personal_default', '1100', 'Cash & Cash Equivalents', 'asset', null, null, true),
  ('personal_default', '1110', 'Cash on Hand', 'asset', 'CASH', '1100', false),
  ('personal_default', '1120', 'Personal Bank Accounts', 'asset', 'PERSONAL_BANK', '1100', false),
  ('personal_default', '1190', 'Personal E-wallet / Other Cash', 'asset', 'OTHER_CASH_ACCOUNT', '1100', false),
  ('personal_default', '1200', 'Personal Receivables', 'asset', 'ACCOUNTS_RECEIVABLE', null, false),
  ('personal_default', '1300', 'Deposits / Prepayments', 'asset', 'PREPAID_DEPOSIT', null, false),
  ('personal_default', '1400', 'Personal Investments / Financial Assets', 'asset', 'PERSONAL_INVESTMENT', null, false),
  ('personal_default', '1500', 'Personal Fixed / Valuable Assets', 'asset', 'PERSONAL_FIXED_ASSET', null, false),
  ('personal_default', '2100', 'Personal Payables', 'liability', 'ACCOUNTS_PAYABLE', null, false),
  ('personal_default', '2200', 'Personal Tax Payable', 'liability', 'TAX_PAYABLE', null, false),
  ('personal_default', '2300', 'Personal Loans / Debt', 'liability', 'PERSONAL_LOAN', null, false),
  ('personal_default', '3100', 'Opening Net Worth', 'equity', 'OPENING_NET_WORTH', null, false),
  ('personal_default', '3200', 'Owner Transfers / Contributions from Business', 'equity', 'OWNER_TRANSFER', null, false),
  ('personal_default', '3300', 'Accumulated Personal Surplus / Deficit', 'equity', 'PERSONAL_ACCUMULATED_SURPLUS', null, false),
  ('personal_default', '4100', 'Salary / Employment Income', 'revenue', 'SALARY_INCOME', null, false),
  ('personal_default', '4200', 'Business Distribution / Dividend Income', 'revenue', 'BUSINESS_DISTRIBUTION_INCOME', null, false),
  ('personal_default', '4300', 'Interest / Investment Income', 'revenue', 'INVESTMENT_INCOME', null, false),
  ('personal_default', '4400', 'Other Personal Income', 'revenue', 'OTHER_PERSONAL_INCOME', null, false),
  ('personal_default', '6100', 'Housing / Rent', 'expense', 'PERSONAL_HOUSING', null, false),
  ('personal_default', '6200', 'Food & Daily Living', 'expense', 'PERSONAL_FOOD', null, false),
  ('personal_default', '6300', 'Transportation & Travel', 'expense', 'PERSONAL_TRANSPORT', null, false),
  ('personal_default', '6400', 'Utilities / Communication / Subscriptions', 'expense', 'PERSONAL_UTILITIES', null, false),
  ('personal_default', '6500', 'Personal Shopping & Lifestyle', 'expense', 'PERSONAL_LIFESTYLE', null, false),
  ('personal_default', '6600', 'Health / Wellness', 'expense', 'PERSONAL_HEALTH', null, false),
  ('personal_default', '6700', 'Education / Professional Development', 'expense', 'PERSONAL_EDUCATION', null, false),
  ('personal_default', '6800', 'Family / Gifts / Support', 'expense', 'PERSONAL_FAMILY_SUPPORT', null, false),
  ('personal_default', '6900', 'Other Personal Expenses', 'expense', 'OTHER_PERSONAL_EXPENSE', null, false),
  ('personal_default', '7100', 'Investment Gain / Loss', 'other', 'INVESTMENT_GAIN_LOSS', null, false),
  ('personal_default', '7200', 'Interest / Financing Cost', 'other_expense', 'PERSONAL_INTEREST_EXPENSE', null, false),
  ('personal_default', '7300', 'Foreign Exchange Gain / Loss', 'other', 'FX_GAIN_LOSS', null, false),
  ('personal_default', '8100', 'Personal Income Tax / Tax Settlement', 'tax', 'PERSONAL_TAX', null, false),
  ('personal_default', '8900', 'Opening Balance / Migration Clearing', 'special', 'OPENING_BALANCE_CLEARING', null, false),
  ('personal_default', '7310', 'Rounding Differences', 'other', 'ROUNDING_DIFFERENCE', null, false)
)
insert into public.coa_template_accounts
  (template_key, code, name, account_class, normal_balance, system_key, parent_code, is_group, is_control, allows_manual_posting)
select
  s.template_key, s.code, s.name, s.account_class,
  case when s.account_class in ('asset', 'expense', 'other_expense', 'other', 'tax', 'special', 'contra_revenue')
       then 'debit' else 'credit' end,
  s.system_key, s.parent_code, s.is_group,
  -- Control / protected accounts (Step 03 §5): bank/cash, AR/AP and other receivables/payables,
  -- tax, fixed assets and depreciation, loans, payroll, distributions payable, equity closing accounts.
  coalesce(s.system_key in (
    'CASH', 'BANK_OPERATING', 'OTHER_CASH_ACCOUNT', 'PERSONAL_BANK',
    'ACCOUNTS_RECEIVABLE', 'OTHER_RECEIVABLE', 'ACCOUNTS_PAYABLE', 'OTHER_PAYABLE',
    'TAX_ASSET', 'TAX_PAYABLE',
    'FIXED_ASSET_EQUIPMENT', 'FIXED_ASSET_FURNITURE', 'FIXED_ASSET_OTHER', 'ACCUMULATED_DEPRECIATION',
    'PERSONAL_FIXED_ASSET', 'LOAN_SHORT_TERM', 'LOAN_LONG_TERM', 'PERSONAL_LOAN',
    'PAYROLL_LIABILITY', 'BPJS_LIABILITY', 'DIVIDEND_PAYABLE', 'CUSTOMER_ADVANCE',
    'RETAINED_EARNINGS', 'CURRENT_YEAR_EARNINGS', 'PERSONAL_ACCUMULATED_SURPLUS',
    'OPENING_BALANCE_CLEARING', 'OPENING_NET_WORTH'), false),
  not s.is_group and coalesce(s.system_key not in (
    'CASH', 'BANK_OPERATING', 'OTHER_CASH_ACCOUNT', 'PERSONAL_BANK',
    'ACCOUNTS_RECEIVABLE', 'OTHER_RECEIVABLE', 'ACCOUNTS_PAYABLE', 'OTHER_PAYABLE',
    'TAX_ASSET', 'TAX_PAYABLE',
    'FIXED_ASSET_EQUIPMENT', 'FIXED_ASSET_FURNITURE', 'FIXED_ASSET_OTHER', 'ACCUMULATED_DEPRECIATION',
    'PERSONAL_FIXED_ASSET', 'LOAN_SHORT_TERM', 'LOAN_LONG_TERM', 'PERSONAL_LOAN',
    'PAYROLL_LIABILITY', 'BPJS_LIABILITY', 'DIVIDEND_PAYABLE', 'CUSTOMER_ADVANCE',
    'RETAINED_EARNINGS', 'CURRENT_YEAR_EARNINGS', 'PERSONAL_ACCUMULATED_SURPLUS',
    'OPENING_BALANCE_CLEARING', 'OPENING_NET_WORTH'), true)
from src s;

-- Copies the default COA into an Entity. Idempotent: existing codes are left untouched, so it can be
-- re-run after the template grows. Returns the number of accounts created.
create function app_private.provision_default_coa(p_entity uuid) returns integer
language plpgsql as $$
declare
  v_type text;
  v_template text;
  v_count integer;
begin
  select entity_type into v_type from public.entities where id = p_entity;
  if v_type is null then
    raise exception 'Unknown entity %', p_entity using errcode = 'no_data_found';
  end if;
  v_template := case v_type when 'company' then 'company_default' when 'personal' then 'personal_default' end;
  if v_template is null then
    raise exception 'No default COA template for entity type %', v_type using errcode = 'no_data_found';
  end if;

  insert into public.ledger_accounts
    (entity_id, code, name, account_class, normal_balance, system_key, is_group, is_control, allows_manual_posting)
  select p_entity, t.code, t.name, t.account_class, t.normal_balance, t.system_key, t.is_group, t.is_control,
         t.allows_manual_posting
  from public.coa_template_accounts t
  where t.template_key = v_template
  on conflict (entity_id, code) do nothing;
  get diagnostics v_count = row_count;

  update public.ledger_accounts a
  set parent_id = p.id
  from public.coa_template_accounts t
  join public.ledger_accounts p on p.entity_id = p_entity and p.code = t.parent_code
  where t.template_key = v_template
    and a.entity_id = p_entity and a.code = t.code
    and t.parent_code is not null
    and a.parent_id is null;

  return v_count;
end
$$;
revoke all on function app_private.provision_default_coa(uuid) from public;

-- =========================================================== accounting periods (Step 07 §17)
create table public.accounting_periods (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  fiscal_year integer not null check (fiscal_year between 2000 and 2999),
  period_start date not null,
  period_end date not null,
  status text not null default 'open' check (status in ('open', 'closing_review', 'closed', 'reopened')),
  closed_at timestamptz,
  closed_by uuid,
  reopened_at timestamptz,
  reopened_by uuid,
  reopen_reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  check (period_end >= period_start),
  check (status <> 'reopened' or length(btrim(coalesce(reopen_reason, ''))) > 0),
  -- Periods of one Entity never overlap.
  exclude using gist (entity_id with =, daterange(period_start, period_end, '[]') with &&)
);

create function app_private.tg_period_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'open' then
      raise exception 'New accounting periods must start Open' using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;

  if (new.period_start, new.period_end, new.fiscal_year)
     is distinct from (old.period_start, old.period_end, old.fiscal_year)
     and exists (select 1 from public.journal_entries j where j.period_id = old.id limit 1) then
    raise exception 'Period boundaries cannot change once journals exist in the period'
      using errcode = 'integrity_constraint_violation';
  end if;

  if new.status is distinct from old.status then
    -- open -> closing_review -> closed -> reopened -> (closing_review | closed); closing_review -> open.
    if not ((old.status, new.status) in (
        ('open', 'closing_review'), ('closing_review', 'open'), ('closing_review', 'closed'),
        ('closed', 'reopened'), ('reopened', 'closing_review'), ('reopened', 'closed'))) then
      raise exception 'Invalid accounting period transition % -> %', old.status, new.status
        using errcode = 'integrity_constraint_violation';
    end if;
    if new.status = 'closed' then
      new.closed_at := now();
      new.closed_by := auth.uid();
    elsif new.status = 'reopened' then
      new.reopened_at := now();
      new.reopened_by := auth.uid();
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.accounting_periods
  for each row execute function app_private.tg_period_guard();
call app_private.apply_standard_triggers('public.accounting_periods');
call app_private.secure_table('public.accounting_periods');
create trigger tg_audit after insert or update or delete on public.accounting_periods
  for each row execute function app_private.tg_audit('entity_id');

-- Creates (if missing) the calendar-month period containing p_date and returns its id.
-- Fiscal year is labelled by the calendar year in which the fiscal year starts.
create function app_private.ensure_accounting_period(p_entity uuid, p_date date) returns uuid
language plpgsql as $$
declare
  v_id uuid;
  v_start_month smallint;
  v_start date := date_trunc('month', p_date)::date;
  v_fy integer;
begin
  select id into v_id
  from public.accounting_periods
  where entity_id = p_entity and p_date between period_start and period_end;
  if found then
    return v_id;
  end if;

  select fiscal_year_start_month into v_start_month from public.entities where id = p_entity;
  if v_start_month is null then
    raise exception 'Unknown entity %', p_entity using errcode = 'no_data_found';
  end if;
  v_fy := extract(year from p_date)::integer - case when extract(month from p_date) < v_start_month then 1 else 0 end;

  insert into public.accounting_periods (entity_id, fiscal_year, period_start, period_end)
  values (p_entity, v_fy, v_start, (v_start + interval '1 month' - interval '1 day')::date)
  returning id into v_id;
  return v_id;
end
$$;
revoke all on function app_private.ensure_accounting_period(uuid, date) from public;

-- =========================================================== posting batches (Step 02 §2)
create table public.posting_batches (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  batch_type text not null check (batch_type ~ '^[a-z][a-z0-9_]*$'),
  source_type text,
  source_id uuid,
  description text,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id)
);
create trigger tg_forbid_update before update on public.posting_batches
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.posting_batches
  for each row execute function app_private.tg_forbid_delete();
call app_private.secure_table('public.posting_batches');

-- =========================================================== journals (Step 04, Step 08 §6)
create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  journal_number text,
  entry_date date not null,
  period_id uuid not null,
  status text not null default 'draft' check (status in ('draft', 'posted')),
  entry_type text not null check (entry_type in ('system', 'manual', 'adjusting', 'reversal', 'opening', 'closing')),
  description text not null check (length(btrim(description)) > 0),
  -- Source linkage (Step 08 §6): mandatory for everything except manual/adjusting journals.
  source_type text,
  source_id uuid,
  -- Posting identity = source event + rule. Unique per Entity: the same event can never post twice.
  posting_key text,
  posting_rule_version text,
  reverses_journal_id uuid,
  control_override_reason text,
  batch_id uuid,
  posted_at timestamptz,
  posted_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, period_id) references public.accounting_periods (entity_id, id) on delete restrict,
  foreign key (entity_id, reverses_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, batch_id) references public.posting_batches (entity_id, id) on delete restrict,
  constraint journal_posted_consistency check ((status = 'posted') = (posted_at is not null)),
  constraint journal_source_linkage check (
    entry_type in ('manual', 'adjusting')
    or (source_type is not null and source_id is not null and posting_key is not null)),
  constraint journal_reversal_link check ((entry_type = 'reversal') = (reverses_journal_id is not null)),
  constraint journal_override_reason_not_blank check (
    control_override_reason is null or length(btrim(control_override_reason)) > 0)
);
create unique index journal_entries_posting_key_uq
  on public.journal_entries (entity_id, posting_key) where posting_key is not null;
-- A journal can be reversed at most once.
create unique index journal_entries_one_reversal_uq
  on public.journal_entries (reverses_journal_id) where reverses_journal_id is not null;
create unique index journal_entries_number_uq
  on public.journal_entries (entity_id, journal_number) where journal_number is not null;
create index journal_entries_period_idx on public.journal_entries (entity_id, period_id);
create index journal_entries_date_idx on public.journal_entries (entity_id, entry_date);
create index journal_entries_source_idx on public.journal_entries (entity_id, source_type, source_id);

create table public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  journal_id uuid not null,
  line_no integer not null check (line_no > 0),
  ledger_account_id uuid not null,
  -- Base-currency amounts (Step 08 §6): exactly one side is positive; zero-value lines do not exist.
  debit public.money_amount not null default 0 check (debit >= 0),
  credit public.money_amount not null default 0 check (credit >= 0),
  description text,
  -- Optional original-currency snapshot (Step 04 §14); all three or none.
  original_currency public.currency_code references public.currencies (code),
  original_amount public.money_amount check (original_amount is null or original_amount > 0),
  exchange_rate public.fx_rate,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (journal_id, line_no),
  unique (entity_id, id),
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete cascade,
  foreign key (entity_id, ledger_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  constraint journal_line_one_side check ((debit > 0) <> (credit > 0)),
  constraint journal_line_fx_all_or_none check (
    (original_currency is null) = (original_amount is null)
    and (original_amount is null) = (exchange_rate is null))
);
create index journal_lines_account_idx on public.journal_lines (entity_id, ledger_account_id);
create index journal_lines_journal_idx on public.journal_lines (journal_id);

-- Lines are editable only while their journal is a draft.
create function app_private.tg_journal_lines_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
begin
  select status into v_status
  from public.journal_entries
  where id = case when tg_op = 'DELETE' then old.journal_id else new.journal_id end;

  if v_status is not null and v_status <> 'draft' then
    raise exception 'Lines of a posted journal are immutable (Step 04 §1)'
      using errcode = 'integrity_constraint_violation';
  end if;
  if tg_op = 'UPDATE' and (new.journal_id, new.entity_id) is distinct from (old.journal_id, old.entity_id) then
    raise exception 'A journal line cannot move to another journal or Entity'
      using errcode = 'integrity_constraint_violation';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;
create trigger tg_guard before insert or update or delete on public.journal_lines
  for each row execute function app_private.tg_journal_lines_guard();
create trigger tg_forbid_truncate before truncate on public.journal_lines
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.journal_lines');

-- Posting = the draft -> posted transition. All hard invariants are checked here, in the database,
-- so no client, service or import path can bypass them (Step 08 §1, §6; Step 17 §13).
create function app_private.tg_journal_entries_guard() returns trigger
language plpgsql as $$
declare
  v_lines integer;
  v_debit numeric;
  v_credit numeric;
  v_period public.accounting_periods%rowtype;
  v_orig public.journal_entries%rowtype;
  r record;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.posted_at is not null or new.posted_by is not null then
      raise exception 'Journals are created as drafts and become posted only through the posting transition'
        using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.status = 'posted' then
      raise exception 'Posted journals are never deleted; use a reversal (Step 04 §11)'
        using errcode = 'integrity_constraint_violation';
    end if;
    return old;
  end if;

  -- UPDATE
  if old.status = 'posted' then
    raise exception 'Posted journals are immutable; use a reversal or adjusting journal (Step 04 §1)'
      using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> 'posted' then
    return new;
  end if;

  -- ---- draft -> posted: validate everything.
  select count(*), coalesce(sum(debit), 0), coalesce(sum(credit), 0)
    into v_lines, v_debit, v_credit
  from public.journal_lines where journal_id = new.id;

  if v_lines < 2 then
    raise exception 'A posted journal needs at least two lines' using errcode = 'check_violation';
  end if;
  if v_debit <> v_credit then
    raise exception 'Journal is not balanced: debit % <> credit %', v_debit, v_credit using errcode = 'check_violation';
  end if;

  select * into v_period from public.accounting_periods where id = new.period_id and entity_id = new.entity_id;
  if not found then
    raise exception 'Accounting period not found for this Entity' using errcode = 'check_violation';
  end if;
  if new.entry_date < v_period.period_start or new.entry_date > v_period.period_end then
    raise exception 'Entry date % is outside its accounting period', new.entry_date using errcode = 'check_violation';
  end if;
  if v_period.status not in ('open', 'reopened') then
    raise exception 'Posting into a % period is blocked (Step 08 §6, §14)', v_period.status
      using errcode = 'check_violation';
  end if;

  for r in
    select l.line_no, a.code, a.status, a.is_group, a.allows_manual_posting
    from public.journal_lines l
    join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
    where l.journal_id = new.id
  loop
    if r.status <> 'active' then
      raise exception 'Account % is inactive and cannot receive postings', r.code using errcode = 'check_violation';
    end if;
    if r.is_group then
      raise exception 'Account % is a group header and cannot receive postings', r.code using errcode = 'check_violation';
    end if;
    if new.entry_type in ('manual', 'adjusting') and not r.allows_manual_posting
       and new.control_override_reason is null then
      raise exception 'Account % is protected; a manual journal needs an authorized override reason (Step 04 §11)', r.code
        using errcode = 'check_violation';
    end if;
  end loop;

  if new.entry_type = 'reversal' then
    select * into v_orig from public.journal_entries
    where id = new.reverses_journal_id and entity_id = new.entity_id;
    if not found or v_orig.status <> 'posted' then
      raise exception 'A reversal must reference a posted journal of the same Entity' using errcode = 'check_violation';
    end if;
    if exists (
         (select ledger_account_id, sum(debit), sum(credit) from public.journal_lines
          where journal_id = new.id group by ledger_account_id)
         except
         (select ledger_account_id, sum(credit), sum(debit) from public.journal_lines
          where journal_id = v_orig.id group by ledger_account_id)
       )
       or exists (
         (select ledger_account_id, sum(credit), sum(debit) from public.journal_lines
          where journal_id = v_orig.id group by ledger_account_id)
         except
         (select ledger_account_id, sum(debit), sum(credit) from public.journal_lines
          where journal_id = new.id group by ledger_account_id)
       ) then
      raise exception 'A reversal must exactly mirror the original journal (debit/credit swapped)'
        using errcode = 'check_violation';
    end if;
  end if;

  new.posted_at := now();
  new.posted_by := auth.uid();
  return new;
end
$$;
create trigger tg_guard before insert or update or delete on public.journal_entries
  for each row execute function app_private.tg_journal_entries_guard();
create trigger tg_forbid_truncate before truncate on public.journal_entries
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.journal_entries');
call app_private.secure_table('public.journal_entries');
create trigger tg_audit after insert or update or delete on public.journal_entries
  for each row execute function app_private.tg_audit('entity_id');
