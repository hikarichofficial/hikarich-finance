-- P12 (Step 15 Phase 12, Step 12 §2/§4/§31): year-end closing entries.
-- Authority: Step 12 §4 ("Retained/current earnings presentation derives from accounting architecture
-- rather than duplicated manual balances"); DECISIONS #45 ("Year-end closing entries ... are not in the
-- Step 15 P3 scope and are built with financial statements and report snapshots in P12").
--
-- Design: closing a fiscal year zeroes that year's posted P&L-class accounts (revenue, contra_revenue,
-- other_income, expense, other_expense, other, tax) into the Entity's retained-earnings control account
-- (RETAINED_EARNINGS for a company, PERSONAL_ACCUMULATED_SURPLUS for a Personal Entity) with one balanced
-- system journal, entry_type = 'closing' (reserved for exactly this since P1). Balance Sheet and Trial
-- Balance never special-case this: a cumulative "as of" sum over P&L-class accounts already nets to just
-- the currently-unclosed portion once a closing journal has run, which is how "Current Year Earnings" is
-- computed in 20260930200100_p12_financial_statements.sql (a derived report line, never a posted balance
-- of its own placeholder account 3400/CURRENT_YEAR_EARNINGS).
--
-- The closing journal is dated the day AFTER the fiscal year's last existing period ends (always inside
-- a fresh or still-open period, auto-created on demand exactly like every other posting date) rather than
-- inside the year's own, now-closed periods, which `assert_period_postable` would refuse (Step 04 §12,
-- DECISIONS #42/#47: closing a period seals postings into it, system journals included). This never
-- changes a locked spec: it is the same "closed periods refuse postings" invariant already enforced for
-- every other module, applied here instead of carving out an exception for this one caller.

create table public.fiscal_year_closures (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  fiscal_year integer not null check (fiscal_year between 2000 and 2999),
  closing_journal_id uuid not null,
  closed_at timestamptz not null default now(),
  closed_by uuid,
  reversed_at timestamptz,
  reversed_by uuid,
  reversal_journal_id uuid,
  reversal_reason text,
  unique (entity_id, id),
  foreign key (entity_id, closing_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint fiscal_year_closure_reversal_shape check (
    (reversed_at is null) = (reversed_by is null)
    and (reversed_at is null) = (reversal_journal_id is null)
    and (reversed_at is null) = (reversal_reason is null))
);
-- At most one ACTIVE (not-yet-reversed) closure per Entity/fiscal year; a reversed one may be re-closed,
-- which posts a fresh closing journal (see close_fiscal_year) rather than replaying the reversed one.
create unique index fiscal_year_closures_active_uq
  on public.fiscal_year_closures (entity_id, fiscal_year) where reversed_at is null;
create trigger tg_forbid_delete before delete on public.fiscal_year_closures
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_lock_entity before update on public.fiscal_year_closures
  for each row execute function app_private.tg_lock_entity();
call app_private.secure_table('public.fiscal_year_closures');
create trigger tg_audit after insert or update or delete on public.fiscal_year_closures
  for each row execute function app_private.tg_audit('entity_id');
call app_private.expose_select('public.fiscal_year_closures');
create policy fiscal_year_closures_select on public.fiscal_year_closures for select to authenticated
  using (app_authz.has_permission(entity_id, 'accounting.view'));

-- Closes every P&L-class account's posted net movement for the fiscal year into retained earnings.
-- Idempotency-keyed like every other command (Step 13 §9): a retry with the same key replays the same
-- closing journal id; a retry with a different fiscal year is refused with CONFLICT.
create function public.close_fiscal_year(p_entity uuid, p_fiscal_year integer, p_key text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_entity_type text;
  v_retained_key text;
  v_open_periods integer;
  v_total_periods integer;
  v_period_start date;
  v_period_end date;
  v_close_date date;
  v_lines jsonb;
  v_total_net numeric(20, 4);
  v_closure_id uuid := gen_random_uuid();
  v_journal uuid;
  v_retained_id uuid;
  v_retained_name text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'periods.close') then
    raise exception 'FORBIDDEN: missing periods.close' using errcode = 'insufficient_privilege';
  end if;
  if p_fiscal_year is null or p_fiscal_year not between 2000 and 2999 then
    raise exception 'INVALID: fiscal year must be between 2000 and 2999' using errcode = 'invalid_parameter_value';
  end if;

  v_replay := app_private.idem_begin('fiscal_year.close', p_entity, p_key, md5(p_fiscal_year::text));
  if v_replay is not null then
    return v_replay;
  end if;

  select entity_type into v_entity_type from public.entities where id = p_entity;
  if v_entity_type is null then
    raise exception 'Unknown entity %', p_entity using errcode = 'no_data_found';
  end if;
  v_retained_key := case v_entity_type when 'personal' then 'PERSONAL_ACCUMULATED_SURPLUS' else 'RETAINED_EARNINGS' end;
  select id, name into v_retained_id, v_retained_name
  from public.ledger_accounts where entity_id = p_entity and system_key = v_retained_key;
  if v_retained_id is null then
    raise exception 'Entity % has no % account provisioned', p_entity, v_retained_key using errcode = 'no_data_found';
  end if;

  -- A period whose ONLY posted activity is a prior 'closing' journal for this same Entity is a housekeeping
  -- vessel created by an earlier close_fiscal_year call, not a real business period of the fiscal year: it
  -- is excluded here so that closing, reversing and re-closing the same fiscal year never gets permanently
  -- blocked by the very period the first closing journal itself created (that period sits inside the same
  -- fiscal year whenever the year's last real period ends before December, and never becomes 'closed' on
  -- its own). A period with zero posted entries, or with any non-closing posted entry, still counts.
  select count(*) filter (where p.status <> 'closed'), count(*), min(p.period_start), max(p.period_end)
  into v_open_periods, v_total_periods, v_period_start, v_period_end
  from public.accounting_periods p
  where p.entity_id = p_entity and p.fiscal_year = p_fiscal_year
    and not (
      exists (select 1 from public.journal_entries j
              where j.entity_id = p.entity_id and j.period_id = p.id and j.status = 'posted')
      and not exists (select 1 from public.journal_entries j
                      where j.entity_id = p.entity_id and j.period_id = p.id and j.status = 'posted'
                        and j.entry_type <> 'closing')
    );
  if v_total_periods = 0 then
    raise exception 'NOT_FOUND: entity % has no accounting periods in fiscal year %', p_entity, p_fiscal_year
      using errcode = 'no_data_found';
  end if;
  if v_open_periods > 0 then
    raise exception 'CONFLICT: % of the % periods in fiscal year % are not closed yet', v_open_periods, v_total_periods, p_fiscal_year
      using errcode = 'integrity_constraint_violation';
  end if;

  if exists (
    select 1 from public.fiscal_year_closures
    where entity_id = p_entity and fiscal_year = p_fiscal_year and reversed_at is null
  ) then
    raise exception 'CONFLICT: fiscal year % is already closed', p_fiscal_year
      using errcode = 'integrity_constraint_violation';
  end if;
  if exists (
    select 1 from public.fiscal_year_closures
    where entity_id = p_entity and fiscal_year > p_fiscal_year and reversed_at is null
  ) then
    raise exception 'CONFLICT: a later fiscal year is already closed; close fiscal years in order'
      using errcode = 'integrity_constraint_violation';
  end if;

  -- One closing line per nonzero P&L-class account (credit-debit is its signed FY net movement), plus one
  -- balancing line on retained earnings so the journal balances to the cent (Step 04 §14).
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', a.line_no,
           'account_id', a.account_id,
           'debit', greatest(a.net, 0)::text,
           'credit', greatest(-a.net, 0)::text,
           'description', 'FY ' || p_fiscal_year || ' closing: ' || a.name)), '[]'::jsonb),
         coalesce(sum(a.net), 0)
  into v_lines, v_total_net
  from (
    select row_number() over (order by la.code) as line_no,
           l.ledger_account_id as account_id, la.code, la.name, sum(l.credit) - sum(l.debit) as net
    from public.journal_lines l
    join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
    join public.ledger_accounts la on la.id = l.ledger_account_id and la.entity_id = l.entity_id
    where j.entity_id = p_entity and j.status = 'posted'
      and j.entry_date between v_period_start and v_period_end
      and la.account_class in ('revenue', 'contra_revenue', 'other_income', 'expense', 'other_expense', 'other', 'tax')
    group by l.ledger_account_id, la.code, la.name
    having sum(l.credit) - sum(l.debit) <> 0
  ) a;

  if jsonb_array_length(v_lines) = 0 then
    raise exception 'CONFLICT: fiscal year % has no posted profit-and-loss activity to close', p_fiscal_year
      using errcode = 'integrity_constraint_violation';
  end if;

  -- Only append the balancing line when the year's net result is nonzero: the per-account closing lines
  -- already balance against each other on their own when the fiscal year's net result is exactly zero, and
  -- a zero/zero line would fail the "exactly one positive side" rule every journal line must satisfy.
  if v_total_net <> 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'line_no', jsonb_array_length(v_lines) + 1,
      'account_id', v_retained_id,
      'debit', greatest(-v_total_net, 0)::text,
      'credit', greatest(v_total_net, 0)::text,
      'description', 'FY ' || p_fiscal_year || ' net result to ' || v_retained_name));
  end if;

  v_close_date := v_period_end + 1;
  v_journal := app_private.post_system_journal(
    p_entity, 'fiscal_year_closing', v_closure_id, 'year_end_close', 'v1', v_close_date,
    'Year-end closing FY ' || p_fiscal_year, v_lines, 'closing');

  insert into public.fiscal_year_closures (id, entity_id, fiscal_year, closing_journal_id, closed_by)
  values (v_closure_id, p_entity, p_fiscal_year, v_journal, auth.uid());

  perform app_private.idem_complete('fiscal_year.close', p_entity, p_key, 'journal_entries', v_journal);
  return v_journal;
end
$$;

-- Reverses a fiscal year's closing journal (decision #40: source-driven journals are corrected through
-- their source module, never through the generic reverse_journal). Undoing a closing is at least as
-- sensitive as reopening the period it closed, so it needs the same gate: periods.reopen, a recent
-- step-up and a written reason (DECISIONS #42/P3 review). The Entity's periods are NOT reopened by this
-- call; the OWNER reopens whichever periods need correction afterwards through the existing workflow.
create function public.reverse_fiscal_year_closing(p_entity uuid, p_fiscal_year integer, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
  v_closure public.fiscal_year_closures%rowtype;
  v_journal public.journal_entries%rowtype;
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'periods.reopen') then
    raise exception 'FORBIDDEN: missing periods.reopen' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 10 then
    raise exception 'INVALID: a reversal reason of at least 10 characters is mandatory' using errcode = 'invalid_parameter_value';
  end if;

  select * into v_closure from public.fiscal_year_closures
  where entity_id = p_entity and fiscal_year = p_fiscal_year and reversed_at is null
  for update;
  if not found then
    raise exception 'NOT_FOUND: fiscal year % of this entity has no active closing to reverse', p_fiscal_year
      using errcode = 'no_data_found';
  end if;
  if exists (
    select 1 from public.fiscal_year_closures
    where entity_id = p_entity and fiscal_year > p_fiscal_year and reversed_at is null
  ) then
    raise exception 'CONFLICT: a later fiscal year is still closed; reverse fiscal years in reverse order'
      using errcode = 'integrity_constraint_violation';
  end if;

  select * into v_journal from public.journal_entries where id = v_closure.closing_journal_id;
  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(v_journal.id, current_date, v_reason);

  update public.fiscal_year_closures
  set reversed_at = now(), reversed_by = auth.uid(), reversal_journal_id = v_rev, reversal_reason = v_reason
  where id = v_closure.id;

  return v_rev;
end
$$;

revoke all on function public.close_fiscal_year(uuid, integer, text) from public, anon;
revoke all on function public.reverse_fiscal_year_closing(uuid, integer, text) from public, anon;
grant execute on function public.close_fiscal_year(uuid, integer, text) to authenticated;
grant execute on function public.reverse_fiscal_year_closing(uuid, integer, text) to authenticated;
