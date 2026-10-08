-- P37 (decision 350, owner request of 8 October 2026): "Catat Pendapatan" -- income that does not go through an
-- invoice (cash sale, service paid by transfer, commission, interest, dividend, ...) is entered in a few plain
-- fields; the system makes the debit and credit itself. Until now the only way was a manual journal, which
-- needs accounting knowledge and, worse, never reaches the final-tax base.
-- The kind of income is a revenue CATEGORY, the same type-pick-or-add field an invoice line uses (OWNER, 8 October
-- 2026: "isian yang bisa diketik manual, bisa ditambah ... gunakan sistem yang sama"): the category's mapped
-- account (or the Entity's default revenue account) is credited. Whether it counts for the PPh Final UMKM base
-- follows that account: a revenue account (4xxx) is business turnover; an other-income account (7xxx: interest,
-- dividend, investment, crypto, bonus, ...) is booked but kept out of the 0,5% base (decisions 344-345).
--   * app_private.provision_income_categories(): the ready categories for income that is not business turnover
--     (and Komisi & Afiliasi), each tied to its account; given to every Entity and to every new one.
--   * public.income_entries: one row per entry, with the journal and the cash movement it made; never edited,
--     only reversed (like a marketplace settlement).
--   * public.record_income_entry / reverse_income_entry / list_income_categories.
--   * the final tax (tax_final_evaluate) adds the recorded business income of the month and of the year before it
--     (so also the Rp 4,8 billion ceiling); built by exact text replacement of the live function.
--   * attachments: the entry accepts documents like an invoice or an expense does.
-- Permissions are those of marketplace settlements: invoices.view to see, invoices.issue + invoices.confirm_payment
-- to record, invoices.void to reverse.

-- ------------------------------------------------------------ ready categories
create function app_private.provision_income_categories(p_entity uuid) returns integer
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
      ('Bunga Bank & Deposito', '7100', 110),
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
revoke all on function app_private.provision_income_categories(uuid) from public;

create or replace function app_private.provision_default_coa(p_entity uuid) returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare
  v_count integer;
begin
  v_count := app_private.provision_default_accounts(p_entity);
  perform app_private.provision_default_categories(p_entity);
  perform app_private.provision_income_categories(p_entity);
  return v_count;
end
$$;

select app_private.provision_income_categories(e.id) from public.entities e;

-- ------------------------------------------------------------ table
create table public.income_entries (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  status text not null default 'recorded' check (status in ('recorded', 'reversed')),
  -- The date the money arrived: the date of the journal, of the cash movement and of the tax month.
  entry_date date not null,
  category_id uuid not null,
  currency public.currency_code not null,
  amount public.money_amount not null check (amount > 0),
  financial_account_id uuid not null,
  contact_id uuid,
  -- Kept as they were when the entry was made, so a later change of the category's account never rewrites history.
  income_account_id uuid not null,
  in_turnover boolean not null,
  reference text check (reference is null or length(reference) <= 200),
  note text check (note is null or length(note) <= 1000),
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
  foreign key (entity_id, financial_account_id, currency)
    references public.financial_accounts (entity_id, id, currency) on delete restrict,
  foreign key (entity_id, category_id) references public.categories (entity_id, id) on delete restrict,
  foreign key (entity_id, contact_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, income_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint income_entry_state check (
    (status = 'recorded' and reversal_journal_id is null and reversed_at is null)
    or (status = 'reversed' and reversal_journal_id is not null and reversed_at is not null
        and reversed_date is not null and reverse_reason is not null))
);
create index income_entries_date_idx on public.income_entries (entity_id, entry_date);

create function app_private.tg_income_entries_guard() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
declare
  v_lock constant text[] := array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by',
                                   'reverse_reason', 'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' then
    raise exception 'A reversed income entry cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a recorded income entry cannot be changed; reverse it instead'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
revoke all on function app_private.tg_income_entries_guard() from public;
create trigger tg_guard before update on public.income_entries
  for each row execute function app_private.tg_income_entries_guard();
create trigger tg_forbid_delete before delete on public.income_entries
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.income_entries
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.income_entries');
call app_private.secure_table('public.income_entries');
call app_private.expose_select('public.income_entries');
create trigger tg_audit after insert or update or delete on public.income_entries
  for each row execute function app_private.tg_audit('entity_id');
create policy income_entries_select on public.income_entries for select to authenticated
  using (coalesce(entity_id = any (((select app_authz.permitted_entities('invoices.view')))::uuid[]), false));

-- ------------------------------------------------------------ attachments
insert into app_private.document_target_kinds
  (target_type, table_name, view_permission, edit_permission_any, blocked_link_statuses, removable_statuses, generic_linker)
values
  ('income_entry', 'public.income_entries', 'invoices.view', array['invoices.issue', 'invoices.confirm_payment'],
   array['reversed'], array[]::text[], true);

-- ------------------------------------------------------------ the final tax counts business income
do $$
declare
  v_patch text[][] := array[
    array[$o$  v_mp_prior numeric := 0;
  v_credit numeric := 0;
$o$,
          $n$  v_mp_prior numeric := 0;
  v_in_month numeric := 0;
  v_in_prior numeric := 0;
  v_credit numeric := 0;
$n$, '1'],
    array[$o$  v_month := v_month + v_mp_month;
  v_prior := v_prior + v_mp_prior;
$o$,
          $n$  v_month := v_month + v_mp_month;
  v_prior := v_prior + v_mp_prior;
  -- income entered without an invoice (menu "Catat Pendapatan"): business income counts as turnover
  select coalesce(sum(n.amount) filter (where n.entry_date >= p_period), 0),
         coalesce(sum(n.amount) filter (where n.entry_date < p_period), 0)
    into v_in_month, v_in_prior
  from public.income_entries n
  where n.entity_id = p_entity and n.status = 'recorded' and n.in_turnover
    and n.currency = v_base_cur and n.entry_date between v_year_start and v_end;
  v_month := v_month + v_in_month;
  v_prior := v_prior + v_in_prior;
$n$, '1'],
    array[$o$  if v_prior + v_month + v_outside > v_ceiling then$o$,
          $n$  if v_in_month > 0 then
    v_trace := app_private.tax_trace_add(v_trace, format('Income entered without an invoice this month (counted in the turnover above): %s', trim_scale(v_in_month)));
  end if;
  if v_prior + v_month + v_outside > v_ceiling then$n$, '1'],
    array[$o$'turnover_marketplace', trim_scale(v_mp_month)::text,$o$,
          $n$'turnover_marketplace', trim_scale(v_mp_month)::text, 'turnover_income', trim_scale(v_in_month)::text,$n$, '1']
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
      raise exception 'income patch % expected % function(s), found %', i, v_patch[i][3], v_n;
    end if;
  end loop;
end
$$;

-- ------------------------------------------------------------ commands
-- The categories the person can pick, each with the account it credits in this Entity and whether that income
-- counts as business turnover, so the form can say it in words.
create function public.list_income_categories(p_entity uuid) returns jsonb
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
        'in_turnover', coalesce(a.account_class = 'revenue', false), 'available', a.id is not null)
      order by c.sort_order, c.name)
    from public.categories c
    left join public.ledger_accounts a
      on a.id = app_private.resolve_revenue_account(p_entity, c.id, app_private.entity_today(p_entity))
    where c.entity_id = p_entity and c.kind = 'revenue' and c.is_active), '[]'::jsonb);
end
$$;

create function public.record_income_entry(
  p_entity uuid, p_key text, p_category uuid, p_date date, p_account uuid, p_amount text,
  p_contact uuid default null, p_reference text default null, p_note text default null)
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
  v_income_account uuid;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid := gen_random_uuid();
  v_desc text;
  v_journal uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not (app_authz.has_permission(p_entity, 'invoices.issue') and app_authz.has_permission(p_entity, 'invoices.confirm_payment')) then
    raise exception 'FORBIDDEN: recording income needs invoices.issue and invoices.confirm_payment'
      using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('income.record', p_entity, p_key,
    md5(jsonb_build_object('t', p_category, 'd', p_date, 'a', p_account, 'm', p_amount, 'c', p_contact, 'r', p_reference, 'n', p_note)::text));
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
  v_amount := app_private.parse_amount(p_amount, 'the amount');
  if v_amount <= 0 or app_private.round_amount(v_amount, v_scale, 'down') <> v_amount then
    raise exception 'INVALID: the amount must be positive, with at most % decimals', v_scale
      using errcode = 'invalid_parameter_value';
  end if;
  v_income_account := app_private.resolve_revenue_account(p_entity, p_category, p_date);
  if v_income_account is null then
    raise exception 'INVALID: the income account of "%" is missing or inactive in the chart of accounts', cat.name
      using errcode = 'invalid_parameter_value';
  end if;
  select a.account_class = 'revenue' into v_in_turnover from public.ledger_accounts a where a.id = v_income_account;
  v_desc := 'Pendapatan - ' || cat.name || coalesce(' - ' || left(v_note, 120), '');
  perform 1 from public.financial_accounts where id = p_account and entity_id = p_entity for no key update;
  v_journal := app_private.post_system_journal(p_entity, 'income_entry', v_id, 'income_entry.record',
    'income_entry.v1', p_date, v_desc, jsonb_build_array(
      jsonb_build_object('account_id', fa.ledger_account_id, 'debit', v_amount, 'credit', 0, 'description', v_desc),
      jsonb_build_object('account_id', v_income_account, 'debit', 0, 'credit', v_amount, 'description', v_desc)));
  perform app_private.record_movement(p_entity, p_account, 'in', v_amount, v_amount, null, p_date,
    'income_entry', v_id, 'principal', v_journal, v_desc);
  insert into public.income_entries
    (id, entity_id, entry_date, category_id, currency, amount, financial_account_id, contact_id, income_account_id,
     in_turnover, reference, note, journal_id)
  values
    (v_id, p_entity, p_date, p_category, e.base_currency, v_amount, p_account, p_contact, v_income_account,
     v_in_turnover, v_ref, v_note, v_journal);
  perform app_private.idem_complete('income.record', p_entity, p_key, 'income_entries', v_id);
  return v_id;
end
$$;

create function public.reverse_income_entry(p_entry uuid, p_key text, p_date date, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  n public.income_entries%rowtype;
  m public.money_movements%rowtype;
  v_replay uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into n from public.income_entries where id = p_entry for update;
  if not found or not app_authz.has_permission(n.entity_id, 'invoices.void') then
    raise exception 'FORBIDDEN: reversing an income entry needs invoices.void' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('income.reverse', n.entity_id, p_key,
    md5(jsonb_build_object('e', p_entry, 'd', p_date, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if n.status <> 'recorded' then
    raise exception 'CONFLICT: the income entry is already reversed' using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date < n.entry_date or p_date > app_private.entity_today(n.entity_id) then
    raise exception 'INVALID: the reversal date cannot be before the entry or in the future' using errcode = 'invalid_parameter_value';
  end if;
  if length(v_reason) not between 5 and 500 then
    raise exception 'INVALID: a reason of 5 to 500 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  v_rev := app_private.reverse_journal_core(n.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = n.entity_id and source_type = 'income_entry' and source_id = n.id and reverses_movement_id is null
  loop
    perform app_private.record_movement(n.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'income_entry', n.id, m.component, v_rev,
      'Pembalikan: ' || v_reason, m.id);
  end loop;
  update public.income_entries
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date,
      reversed_by = auth.uid(), reverse_reason = v_reason
  where id = n.id;
  perform app_private.idem_complete('income.reverse', n.entity_id, p_key, 'income_entries', n.id);
  return n.id;
end
$$;

revoke all on function public.list_income_categories(uuid) from public, anon;
revoke all on function public.record_income_entry(uuid, text, uuid, date, uuid, text, uuid, text, text) from public, anon;
revoke all on function public.reverse_income_entry(uuid, text, date, text) from public, anon;
grant execute on function public.list_income_categories(uuid) to authenticated;
grant execute on function public.record_income_entry(uuid, text, uuid, date, uuid, text, uuid, text, text) to authenticated;
grant execute on function public.reverse_income_entry(uuid, text, date, text) to authenticated;
