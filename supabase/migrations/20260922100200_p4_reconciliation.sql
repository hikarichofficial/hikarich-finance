-- P4 (Step 15 §8): bank reconciliation - statement staging, match / unmatch / exclude, complete / reopen.
-- Authority: Step 01 §28 (manual reconciliation; differences never silently overwrite the ledger), Step 07 §10
-- (reconciliation workflow), Step 08 §20 (reconciliation integrity), Step 09 §13 (workspace), Step 04 §12-§13.
--
-- Principles
--   * Reconciliation COMPARES the system's money movements with the bank's evidence. It never edits a movement
--     or a journal: a difference is either explained by outstanding items, corrected through an explicit balance
--     adjustment (P4 money movements), or accepted with a written reason that is stored on the session.
--   * A session covers one financial account and one statement period. Statement lines are staged (imported or
--     typed), then each line is matched to one or more movements, or excluded with a reason.
--   * Reconciliation status is separate from posting status (Step 07 §9): matching never changes a transfer or a
--     movement. A matched movement cannot be reversed until it is unmatched.

-- ------------------------------------------------------------ sessions
create table public.reconciliation_sessions (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  financial_account_id uuid not null,
  period_start date not null,
  period_end date not null,
  -- The bank's evidence, in the account's own currency (signed).
  statement_opening public.money_amount not null,
  statement_closing public.money_amount not null,
  status text not null default 'open' check (status in ('open', 'reconciled', 'reopened')),
  note text,
  -- Evidence recorded when the session is completed (Step 08 §20).
  system_book_balance public.money_amount,
  system_cleared_balance public.money_amount,
  outstanding_balance public.money_amount,
  difference public.money_amount,
  accepted_difference_reason text,
  excluded_lines integer,
  outstanding_items integer,
  reconciled_at timestamptz,
  reconciled_by uuid,
  reopen_reason text,
  reopened_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  check (period_end >= period_start),
  constraint recon_completion_consistent check (
    (status = 'reconciled') = (reconciled_at is not null and difference is not null
                               and system_cleared_balance is not null)),
  constraint recon_difference_explained check (
    difference is null or difference = 0 or length(btrim(coalesce(accepted_difference_reason, ''))) >= 10),
  -- Sessions of one account never overlap in time.
  exclude using gist (
    financial_account_id with =,
    daterange(period_start, period_end, '[]') with &&
  )
);
-- One session at a time is being worked on per account.
create unique index reconciliation_one_active_uq
  on public.reconciliation_sessions (financial_account_id) where status in ('open', 'reopened');
create index reconciliation_sessions_account_idx
  on public.reconciliation_sessions (entity_id, financial_account_id, period_end);

-- Completed evidence is not overwritten in place: only the lifecycle moves (open -> reconciled -> reopened ->
-- reconciled ...). Deletion is possible only for a session in progress (open or reopened).
create function app_private.tg_recon_sessions_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    -- A reopened session has already given up its completion evidence (kept in the audit trail with the reason),
    -- so it may be discarded; a completed one may not.
    if old.status not in ('open', 'reopened') then
      raise exception 'A reconciliation session that was completed cannot be deleted'
        using errcode = 'integrity_constraint_violation';
    end if;
    return old;
  end if;
  if (new.financial_account_id, new.period_start, new.period_end, new.statement_opening, new.statement_closing,
      new.created_at, new.created_by)
     is distinct from
     (old.financial_account_id, old.period_start, old.period_end, old.statement_opening, old.statement_closing,
      old.created_at, old.created_by) then
    raise exception 'The account, period and statement balances of a session cannot be changed'
      using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status
     and (old.status, new.status) not in (('open', 'reconciled'), ('reconciled', 'reopened'), ('reopened', 'reconciled')) then
    raise exception 'A reconciliation session cannot move from % to %', old.status, new.status
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update or delete on public.reconciliation_sessions
  for each row execute function app_private.tg_recon_sessions_guard();
create trigger tg_forbid_truncate before truncate on public.reconciliation_sessions
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.reconciliation_sessions');
call app_private.secure_table('public.reconciliation_sessions');
create trigger tg_audit after insert or update or delete on public.reconciliation_sessions
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ statement lines (staging)
create table public.statement_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  session_id uuid not null,
  financial_account_id uuid not null,
  line_date date not null,
  description text,
  reference text,
  -- Signed, in the account's currency: positive = money in, negative = money out.
  amount public.money_amount not null check (amount <> 0),
  balance_after public.money_amount,
  -- Content identity, so a statement uploaded twice never stages the same line twice (Step 08 §19).
  fingerprint text not null,
  is_excluded boolean not null default false,
  exclusion_reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (financial_account_id, fingerprint),
  foreign key (entity_id, session_id) references public.reconciliation_sessions (entity_id, id) on delete cascade,
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  constraint statement_line_exclusion check (
    is_excluded = (exclusion_reason is not null and length(btrim(exclusion_reason)) >= 5))
);
create index statement_lines_session_idx on public.statement_lines (entity_id, session_id, line_date);

create function app_private.tg_statement_lines_guard() returns trigger
language plpgsql as $$
begin
  if (new.session_id, new.financial_account_id, new.line_date, new.description, new.reference, new.amount,
      new.balance_after, new.fingerprint)
     is distinct from
     (old.session_id, old.financial_account_id, old.line_date, old.description, old.reference, old.amount,
      old.balance_after, old.fingerprint) then
    raise exception 'A statement line cannot be edited; it can only be matched or excluded'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.statement_lines
  for each row execute function app_private.tg_statement_lines_guard();
create trigger tg_forbid_truncate before truncate on public.statement_lines
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.statement_lines');
call app_private.secure_table('public.statement_lines');
create trigger tg_audit after insert or update or delete on public.statement_lines
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ matches
create table public.reconciliation_matches (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  session_id uuid not null,
  statement_line_id uuid not null,
  movement_id uuid not null,
  -- Set when the match was confirmed outside the configured matching rules (Step 08 §20).
  manual_reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  -- A movement clears against at most one statement line.
  unique (movement_id),
  foreign key (entity_id, session_id) references public.reconciliation_sessions (entity_id, id) on delete cascade,
  foreign key (entity_id, statement_line_id) references public.statement_lines (entity_id, id) on delete cascade,
  foreign key (entity_id, movement_id) references public.money_movements (entity_id, id) on delete restrict
);
create index reconciliation_matches_line_idx on public.reconciliation_matches (entity_id, statement_line_id);
create index reconciliation_matches_session_idx on public.reconciliation_matches (entity_id, session_id);

create function app_private.tg_recon_matches_guard() returns trigger
language plpgsql as $$
declare
  v_line public.statement_lines%rowtype;
  v_mov public.money_movements%rowtype;
begin
  select * into v_line from public.statement_lines where id = new.statement_line_id and entity_id = new.entity_id;
  select * into v_mov from public.money_movements where id = new.movement_id and entity_id = new.entity_id;
  if v_line.session_id <> new.session_id or v_line.financial_account_id <> v_mov.financial_account_id then
    raise exception 'A movement can only be matched to a statement line of the same session and financial account'
      using errcode = 'integrity_constraint_violation';
  end if;
  if v_line.is_excluded then
    raise exception 'An excluded statement line cannot be matched' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before insert on public.reconciliation_matches
  for each row execute function app_private.tg_recon_matches_guard();
-- A match is never edited: unmatch (delete, audited) and match again.
create trigger tg_forbid_update before update on public.reconciliation_matches
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_truncate before truncate on public.reconciliation_matches
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_stamp_created before insert on public.reconciliation_matches
  for each row execute function app_private.tg_stamp_created();
call app_private.secure_table('public.reconciliation_matches');
create trigger tg_audit after insert or update or delete on public.reconciliation_matches
  for each row execute function app_private.tg_audit('entity_id');

call app_private.expose_select('public.reconciliation_sessions');
call app_private.expose_select('public.statement_lines');
call app_private.expose_select('public.reconciliation_matches');
create policy reconciliation_sessions_select on public.reconciliation_sessions for select to authenticated
  using (app_authz.has_permission(entity_id, 'money.view'));
create policy statement_lines_select on public.statement_lines for select to authenticated
  using (app_authz.has_permission(entity_id, 'money.view'));
create policy reconciliation_matches_select on public.reconciliation_matches for select to authenticated
  using (app_authz.has_permission(entity_id, 'money.view'));

-- A matched movement is locked against reversal (the guard trigger of P4 money movements asks this function).
create or replace function app_private.movement_is_matched(p_movement uuid) returns boolean
language sql stable as $$
  select exists (select 1 from public.reconciliation_matches where movement_id = p_movement)
$$;

-- ------------------------------------------------------------ helpers
-- Date tolerance of the automatic matching rule (Entity setting, default 5 days, at most 31).
create function app_private.match_tolerance_days(p_entity uuid) returns integer
language sql stable as $$
  select least(greatest(coalesce((
    select case when jsonb_typeof(s.setting_value) = 'number' then (s.setting_value)::text::numeric::integer end
    from public.entity_settings s
    where s.entity_id = p_entity and s.setting_key = 'money.match_date_tolerance_days'), 5), 0), 31)
$$;

-- Signed effect of a movement on its account (money in positive, out negative).
create function app_private.movement_signed(p_movement public.money_movements) returns numeric
language sql immutable as $$
  select case p_movement.direction when 'in' then p_movement.amount else -p_movement.amount end
$$;

-- A reversed movement and its mirror are a correction inside the books: money that never reached the bank. They
-- are never matched and never count as outstanding (their net effect on the book balance is zero).
create function app_private.movement_in_reversal_pair(p_movement uuid) returns boolean
language sql stable as $$
  select exists (select 1 from public.money_movements x where x.id = p_movement and x.reverses_movement_id is not null)
      or exists (select 1 from public.money_movements x where x.reverses_movement_id = p_movement)
$$;

-- ------------------------------------------------------------ session commands
create function public.create_reconciliation_session(
  p_entity uuid, p_key text, p_account uuid, p_start date, p_end date,
  p_opening numeric, p_closing numeric, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_prev public.reconciliation_sessions%rowtype;
  v_id uuid;
  v_scale integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'money.reconcile') then
    raise exception 'FORBIDDEN: missing money.reconcile' using errcode = 'insufficient_privilege';
  end if;
  perform app_private.assert_business_date(p_start);
  perform app_private.assert_business_date(p_end);
  if p_end < p_start then
    raise exception 'INVALID: the statement period ends before it starts' using errcode = 'invalid_parameter_value';
  end if;
  if p_opening is null or p_closing is null or not app_private.is_finite(p_opening) or not app_private.is_finite(p_closing)
     or abs(p_opening) >= 10::numeric ^ 16 or abs(p_closing) >= 10::numeric ^ 16 then
    raise exception 'INVALID: the statement opening and closing balances are required' using errcode = 'invalid_parameter_value';
  end if;

  v_replay := app_private.idem_begin('reconciliation.create', p_entity, p_key,
    md5(jsonb_build_object('account', p_account, 'start', p_start, 'end', p_end, 'opening', p_opening,
                           'closing', p_closing, 'note', p_note)::text));
  if v_replay is not null then
    if not exists (select 1 from public.reconciliation_sessions where id = v_replay) then
      raise exception 'CONFLICT: that reconciliation was discarded; start it again with a new key'
        using errcode = 'integrity_constraint_violation';
    end if;
    return v_replay;
  end if;

  select * into v_fa from public.financial_accounts where id = p_account and entity_id = p_entity for no key update;
  if not found then
    raise exception 'INVALID: unknown financial account of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(v_fa.currency);
  if app_private.round_amount(p_opening, v_scale, 'down') <> p_opening
     or app_private.round_amount(p_closing, v_scale, 'down') <> p_closing then
    raise exception 'INVALID: balances allow % decimals for %', v_scale, v_fa.currency using errcode = 'invalid_parameter_value';
  end if;

  -- Statement evidence is continuous: a new session starts where the last completed one ended.
  select * into v_prev from public.reconciliation_sessions
  where financial_account_id = p_account and status = 'reconciled'
  order by period_end desc limit 1;
  if found and v_prev.statement_closing <> p_opening then
    raise exception 'INVALID: the opening balance must equal the closing balance of the previous reconciliation (%)', v_prev.statement_closing
      using errcode = 'invalid_parameter_value';
  end if;

  begin
    insert into public.reconciliation_sessions
      (entity_id, financial_account_id, period_start, period_end, statement_opening, statement_closing, note)
    values (p_entity, p_account, p_start, p_end, p_opening, p_closing, nullif(btrim(coalesce(p_note, '')), ''))
    returning id into v_id;
  exception
    when unique_violation then
      raise exception 'CONFLICT: this account already has a reconciliation in progress' using errcode = 'integrity_constraint_violation';
    when exclusion_violation then
      raise exception 'CONFLICT: the period overlaps an existing reconciliation of this account' using errcode = 'integrity_constraint_violation';
  end;
  perform app_private.idem_complete('reconciliation.create', p_entity, p_key, 'reconciliation_sessions', v_id);
  return v_id;
end
$$;

-- Locks a session the caller may work on (money.reconcile in its Entity) and returns it. Unknown and not-allowed
-- look the same. `p_working` = the session must be open or reopened (not completed).
create function app_private.lock_recon_session(p_session uuid, p_working boolean default true)
returns public.reconciliation_sessions
language plpgsql as $$
declare
  s public.reconciliation_sessions%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into s from public.reconciliation_sessions where id = p_session;
  if not found or not app_authz.has_permission(s.entity_id, 'money.reconcile') then
    raise exception 'FORBIDDEN: missing money.reconcile' using errcode = 'insufficient_privilege';
  end if;
  select * into s from public.reconciliation_sessions where id = p_session for update;
  if p_working and s.status not in ('open', 'reopened') then
    raise exception 'CONFLICT: the reconciliation is already completed; reopen it to change matches'
      using errcode = 'integrity_constraint_violation';
  end if;
  return s;
end
$$;

-- Discarding is possible for a session in progress (open or reopened), never for a completed one. Discarding a
-- reopened session is how an earlier, wrong reconciliation is unlocked: reopen the later one, discard it, then
-- reopen the earlier one (the completion evidence of the reopened session stays in the audit trail).
create function public.discard_reconciliation_session(p_session uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.reconciliation_sessions%rowtype := app_private.lock_recon_session(p_session);
begin
  if s.status not in ('open', 'reopened') then
    raise exception 'CONFLICT: a completed reconciliation cannot be discarded; reopen it first'
      using errcode = 'integrity_constraint_violation';
  end if;
  delete from public.reconciliation_sessions where id = p_session;
end
$$;

-- Stages statement lines: [{"date": "2026-09-05", "amount": "-25000", "description": "...", "reference": "...",
-- "balance_after": "1000000"}, ...]. Lines already staged for this account (same content) are skipped, so the
-- same statement can be uploaded twice safely. Returns how many were added and skipped.
create function public.add_statement_lines(p_session uuid, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.reconciliation_sessions%rowtype := app_private.lock_recon_session(p_session);
  v_fa public.financial_accounts%rowtype;
  v_scale integer;
  v_line jsonb;
  v_no integer := 0;
  v_date date;
  v_amount numeric;
  v_bal numeric;
  v_desc text;
  v_ref text;
  v_fp text;
  v_seen jsonb := '{}'::jsonb;
  v_ord integer;
  v_id uuid;
  v_added integer := 0;
  v_skipped integer := 0;
begin
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 1000 then
    raise exception 'INVALID: between 1 and 1000 statement lines are expected per call' using errcode = 'invalid_parameter_value';
  end if;
  select * into v_fa from public.financial_accounts where id = s.financial_account_id;
  v_scale := app_private.currency_scale(v_fa.currency);

  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    if jsonb_typeof(v_line) <> 'object' then
      raise exception 'INVALID: line % is not an object', v_no using errcode = 'invalid_parameter_value';
    end if;
    begin
      v_date := (v_line ->> 'date')::date;
      v_amount := (v_line ->> 'amount')::numeric;
      v_bal := nullif(v_line ->> 'balance_after', '')::numeric;
    exception when invalid_text_representation or numeric_value_out_of_range or datetime_field_overflow
                   or invalid_datetime_format then
      raise exception 'INVALID: line % has a date or amount that cannot be read', v_no using errcode = 'invalid_parameter_value';
    end;
    if v_date is null or v_date not between s.period_start and s.period_end then
      raise exception 'INVALID: line % is outside the statement period % to %', v_no, s.period_start, s.period_end
        using errcode = 'invalid_parameter_value';
    end if;
    if v_amount is null or not app_private.is_finite(v_amount) or v_amount = 0 or abs(v_amount) >= 10::numeric ^ 16
       or app_private.round_amount(v_amount, v_scale, 'down') <> v_amount
       or (v_bal is not null and (not app_private.is_finite(v_bal) or abs(v_bal) >= 10::numeric ^ 16
                                  or app_private.round_amount(v_bal, v_scale, 'down') <> v_bal)) then
      raise exception 'INVALID: line % needs a non-zero amount with at most % decimals', v_no, v_scale
        using errcode = 'invalid_parameter_value';
    end if;
    v_desc := nullif(btrim(coalesce(v_line ->> 'description', '')), '');
    v_ref := nullif(btrim(coalesce(v_line ->> 'reference', '')), '');

    -- Identical lines of one upload (two equal fees on one day) stay distinct through their occurrence number.
    v_fp := md5(format('%s|%s|%s|%s', v_date, trim_scale(v_amount), coalesce(v_desc, ''), coalesce(v_ref, '')));
    v_ord := coalesce((v_seen ->> v_fp)::integer, 0) + 1;
    v_seen := v_seen || jsonb_build_object(v_fp, v_ord);
    v_fp := v_fp || ':' || v_ord::text;

    insert into public.statement_lines
      (entity_id, session_id, financial_account_id, line_date, description, reference, amount, balance_after, fingerprint)
    values (s.entity_id, s.id, s.financial_account_id, v_date, v_desc, v_ref, v_amount, v_bal, v_fp)
    on conflict (financial_account_id, fingerprint) do nothing
    returning id into v_id;
    if v_id is null then
      v_skipped := v_skipped + 1;
    else
      v_added := v_added + 1;
    end if;
    v_id := null;
  end loop;
  return jsonb_build_object('added', v_added, 'skipped', v_skipped);
end
$$;

-- ------------------------------------------------------------ match / unmatch / exclude
-- Matching rules: same account and session (database-enforced), the movements' signed sum equals the statement
-- amount EXACTLY (a difference is never absorbed here), and every movement lies within the date tolerance of
-- the statement line - otherwise the match needs a written manual confirmation (Step 08 §20).
create function public.match_statement_line(p_line uuid, p_movements uuid[], p_manual_reason text default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.statement_lines%rowtype;
  s public.reconciliation_sessions%rowtype;
  v_reason text := nullif(btrim(coalesce(p_manual_reason, '')), '');
  v_tol integer;
  v_ids uuid[];
  v_n integer;
  v_sum numeric;
  v_outside integer;
  v_bad integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.statement_lines where id = p_line;
  if not found then
    raise exception 'FORBIDDEN: missing money.reconcile' using errcode = 'insufficient_privilege';
  end if;
  s := app_private.lock_recon_session(l.session_id);
  select * into l from public.statement_lines where id = p_line for update;
  if l.is_excluded then
    raise exception 'CONFLICT: the statement line is excluded; include it again first' using errcode = 'integrity_constraint_violation';
  end if;
  if exists (select 1 from public.reconciliation_matches where statement_line_id = p_line) then
    raise exception 'CONFLICT: the statement line is already matched; unmatch it first' using errcode = 'integrity_constraint_violation';
  end if;

  select coalesce(array_agg(distinct x), array[]::uuid[]) into v_ids from unnest(p_movements) x where x is not null;
  v_n := cardinality(v_ids);
  if v_n < 1 or v_n > 50 or v_n <> coalesce(cardinality(p_movements), 0) then
    raise exception 'INVALID: give between 1 and 50 distinct movements' using errcode = 'invalid_parameter_value';
  end if;

  -- Lock the chosen movements' matching state so two reviewers cannot claim the same movement.
  perform 1 from public.money_movements where id = any (v_ids) and entity_id = l.entity_id order by id for update;
  select count(*), coalesce(sum(app_private.movement_signed(m)), 0),
         count(*) filter (where m.financial_account_id <> l.financial_account_id)
    into v_n, v_sum, v_bad
  from public.money_movements m where m.id = any (v_ids) and m.entity_id = l.entity_id;
  if v_n <> cardinality(v_ids) or v_bad > 0 then
    raise exception 'INVALID: every movement must belong to the same financial account as the statement line'
      using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.money_movements x
             where x.entity_id = l.entity_id
               and (x.reverses_movement_id = any (v_ids) or (x.id = any (v_ids) and x.reverses_movement_id is not null))) then
    raise exception 'INVALID: a reversed movement, or the reversal itself, is a correction inside the books and cannot be matched to a bank line'
      using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.reconciliation_matches where movement_id = any (v_ids)) then
    raise exception 'CONFLICT: a chosen movement is already matched to another statement line'
      using errcode = 'integrity_constraint_violation';
  end if;
  if v_sum <> l.amount then
    raise exception 'INVALID: the movements add up to % but the statement line is %; a difference is never absorbed by a match',
      v_sum, l.amount using errcode = 'invalid_parameter_value';
  end if;

  v_tol := app_private.match_tolerance_days(l.entity_id);
  select count(*) into v_outside from public.money_movements m
  where m.id = any (v_ids) and abs(m.movement_date - l.line_date) > v_tol;
  if v_outside > 0 and (v_reason is null or length(v_reason) < 5) then
    raise exception 'INVALID: % movement(s) lie more than % days from the statement date; confirm manually with a reason', v_outside, v_tol
      using errcode = 'invalid_parameter_value';
  end if;

  insert into public.reconciliation_matches (entity_id, session_id, statement_line_id, movement_id, manual_reason)
  select l.entity_id, s.id, l.id, m.id, case when abs(m.movement_date - l.line_date) > v_tol then v_reason end
  from public.money_movements m where m.id = any (v_ids);
  return cardinality(v_ids);
end
$$;

create function public.unmatch_statement_line(p_line uuid, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.statement_lines%rowtype;
  s public.reconciliation_sessions%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_n integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.statement_lines where id = p_line;
  if not found then
    raise exception 'FORBIDDEN: missing money.reconcile' using errcode = 'insufficient_privilege';
  end if;
  s := app_private.lock_recon_session(l.session_id);
  if length(v_reason) < 5 then
    raise exception 'INVALID: a reason of at least 5 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  delete from public.reconciliation_matches where statement_line_id = p_line;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'CONFLICT: the statement line has no match' using errcode = 'integrity_constraint_violation';
  end if;
  return v_n;
end
$$;

create function public.exclude_statement_line(p_line uuid, p_reason text) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.statement_lines%rowtype;
  s public.reconciliation_sessions%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.statement_lines where id = p_line;
  if not found then
    raise exception 'FORBIDDEN: missing money.reconcile' using errcode = 'insufficient_privilege';
  end if;
  s := app_private.lock_recon_session(l.session_id);
  if length(v_reason) < 5 then
    raise exception 'INVALID: a reason of at least 5 characters is required to exclude a statement line'
      using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.reconciliation_matches where statement_line_id = p_line) then
    raise exception 'CONFLICT: the statement line is matched; unmatch it first' using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.statement_lines set is_excluded = true, exclusion_reason = v_reason where id = p_line;
  return true;
end
$$;

create function public.include_statement_line(p_line uuid) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.statement_lines%rowtype;
  s public.reconciliation_sessions%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.statement_lines where id = p_line;
  if not found then
    raise exception 'FORBIDDEN: missing money.reconcile' using errcode = 'insufficient_privilege';
  end if;
  s := app_private.lock_recon_session(l.session_id);
  update public.statement_lines set is_excluded = false, exclusion_reason = null where id = p_line;
  return true;
end
$$;

-- ------------------------------------------------------------ completion and reopen
-- Figures of a session, as of its period end. `cleared` = movements matched to a statement line dated within the
-- statement (any session; a movement may be booked a few days either side of the bank's date) plus the
-- opening-balance movements, which are the bank's own starting point and never appear as a statement line.
create function app_private.recon_figures(p_session uuid)
returns table (
  unresolved bigint, excluded bigint, lines_total numeric, book numeric, cleared numeric, outstanding_items bigint)
language sql stable as $$
  select
    (select count(*) from public.statement_lines l
      where l.session_id = s.id and not l.is_excluded
        and not exists (select 1 from public.reconciliation_matches m where m.statement_line_id = l.id)),
    (select count(*) from public.statement_lines l where l.session_id = s.id and l.is_excluded),
    (select coalesce(sum(l.amount), 0) from public.statement_lines l where l.session_id = s.id and not l.is_excluded),
    app_private.account_balance(s.financial_account_id, s.period_end),
    (select coalesce(sum(app_private.movement_signed(m)), 0) from public.money_movements m
      where m.financial_account_id = s.financial_account_id
        and ((m.source_type = 'opening_balance' and m.movement_date <= s.period_end)
             or exists (select 1 from public.reconciliation_matches x
                        join public.statement_lines l on l.id = x.statement_line_id
                        where x.movement_id = m.id and l.line_date <= s.period_end))),
    (select count(*) from public.money_movements m
      where m.financial_account_id = s.financial_account_id and m.movement_date <= s.period_end
        and m.source_type <> 'opening_balance'
        and not app_private.movement_in_reversal_pair(m.id)
        and not exists (select 1 from public.reconciliation_matches x
                        join public.statement_lines l on l.id = x.statement_line_id
                        where x.movement_id = m.id and l.line_date <= s.period_end))
  from public.reconciliation_sessions s where s.id = p_session
$$;

create function public.complete_reconciliation(p_session uuid, p_accept_reason text default null) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.reconciliation_sessions%rowtype := app_private.lock_recon_session(p_session);
  f record;
  v_accept text := nullif(btrim(coalesce(p_accept_reason, '')), '');
  v_diff numeric;
begin
  select * into f from app_private.recon_figures(p_session);
  if f.unresolved > 0 then
    raise exception 'CONFLICT: % statement line(s) are neither matched nor excluded', f.unresolved
      using errcode = 'integrity_constraint_violation';
  end if;
  -- The staged lines must explain the statement's own movement, otherwise lines are missing.
  if s.statement_opening + f.lines_total <> s.statement_closing then
    raise exception 'CONFLICT: the statement lines add up to % but the statement moved from % to %; add the missing lines or exclude with a reason',
      f.lines_total, s.statement_opening, s.statement_closing using errcode = 'integrity_constraint_violation';
  end if;

  v_diff := s.statement_closing - f.cleared;
  if v_diff <> 0 and (v_accept is null or length(v_accept) < 10) then
    raise exception 'INVALID: the statement closing balance differs from the cleared system balance by %; correct it through an explicit adjustment, or accept the difference with a reason of at least 10 characters', v_diff
      using errcode = 'invalid_parameter_value';
  end if;

  perform set_config('app.audit_reason', coalesce(v_accept, 'Reconciliation completed without difference'), true);
  update public.reconciliation_sessions
  set status = 'reconciled', system_book_balance = f.book, system_cleared_balance = f.cleared,
      outstanding_balance = f.book - f.cleared, difference = v_diff,
      accepted_difference_reason = case when v_diff <> 0 then v_accept end,
      excluded_lines = f.excluded, outstanding_items = f.outstanding_items,
      reconciled_at = now(), reconciled_by = auth.uid()
  where id = p_session;
  return v_diff::text;   -- exact decimal text (Step 13 §25)
end
$$;

-- Reopen needs authorization and a written reason (Step 08 §20). Only the latest completed session of an account
-- can be reopened, so the chain of statement balances stays continuous.
create function public.reopen_reconciliation(p_session uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.reconciliation_sessions%rowtype := app_private.lock_recon_session(p_session, false);
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if s.status <> 'reconciled' then
    raise exception 'CONFLICT: only a completed reconciliation can be reopened (now %)', s.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if length(v_reason) < 10 then
    raise exception 'INVALID: a reopen reason of at least 10 characters is mandatory' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.reconciliation_sessions x
             where x.financial_account_id = s.financial_account_id and x.id <> s.id and x.period_start > s.period_start
               and x.status = 'reconciled') then
    raise exception 'CONFLICT: a later reconciliation of this account is completed; reopen that one first'
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  begin
    update public.reconciliation_sessions
    set status = 'reopened', reopen_reason = v_reason, reopened_at = now(),
        system_book_balance = null, system_cleared_balance = null, outstanding_balance = null, difference = null,
        accepted_difference_reason = null, excluded_lines = null, outstanding_items = null,
        reconciled_at = null, reconciled_by = null
    where id = p_session;
  exception when unique_violation then
    raise exception 'CONFLICT: another reconciliation of this account is in progress' using errcode = 'integrity_constraint_violation';
  end;
  return 'reopened';
end
$$;

-- ------------------------------------------------------------ workspace reads
-- Statement side: every line with its display status. POSSIBLE_MATCH is computed (a candidate exists), never
-- stored, so it cannot go stale (Step 07 §10).
create function public.reconciliation_workspace(p_session uuid)
returns table (
  line_id uuid, line_date date, description text, reference text, amount text,
  display_status text, matched_movements integer, candidate_count integer, exclusion_reason text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  s public.reconciliation_sessions%rowtype;
  v_tol integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into s from public.reconciliation_sessions where id = p_session;
  if not found or not app_authz.has_permission(s.entity_id, 'money.view') then
    raise exception 'FORBIDDEN: missing money.view' using errcode = 'insufficient_privilege';
  end if;
  v_tol := app_private.match_tolerance_days(s.entity_id);
  return query
  select q.id, q.line_date, q.description, q.reference, q.amount::text,
         case when q.is_excluded then 'excluded'
              when q.matched > 0 then 'matched'
              when q.candidates > 0 then 'possible_match'
              else 'unmatched' end,
         q.matched::integer, q.candidates::integer, q.exclusion_reason
  from (
    select l.id, l.line_date, l.description, l.reference, l.amount, l.is_excluded, l.exclusion_reason,
           (select count(*) from public.reconciliation_matches m where m.statement_line_id = l.id) as matched,
           (select count(*) from public.money_movements mv
             where mv.financial_account_id = l.financial_account_id
               and app_private.movement_signed(mv) = l.amount
               and abs(mv.movement_date - l.line_date) <= v_tol
               and not app_private.movement_in_reversal_pair(mv.id)
               and not exists (select 1 from public.reconciliation_matches x where x.movement_id = mv.id)) as candidates
    from public.statement_lines l where l.session_id = p_session
  ) q
  order by q.line_date, q.id;
end
$$;

-- Candidate movements for one statement line: same account, exact signed amount, within the date tolerance.
create function public.reconciliation_candidates(p_line uuid)
returns table (movement_id uuid, movement_date date, direction text, signed_amount text, source_type text,
               description text, day_difference integer)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  l public.statement_lines%rowtype;
  v_tol integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.statement_lines where id = p_line;
  if not found or not app_authz.has_permission(l.entity_id, 'money.view') then
    raise exception 'FORBIDDEN: missing money.view' using errcode = 'insufficient_privilege';
  end if;
  v_tol := app_private.match_tolerance_days(l.entity_id);
  return query
  select mv.id, mv.movement_date, mv.direction, app_private.movement_signed(mv)::text, mv.source_type, mv.description,
         abs(mv.movement_date - l.line_date)
  from public.money_movements mv
  where mv.financial_account_id = l.financial_account_id
    and app_private.movement_signed(mv) = l.amount
    and abs(mv.movement_date - l.line_date) <= v_tol
    and not app_private.movement_in_reversal_pair(mv.id)
    and not exists (select 1 from public.reconciliation_matches x where x.movement_id = mv.id)
  order by abs(mv.movement_date - l.line_date), mv.movement_date, mv.id;
end
$$;

-- System side: movements of an account that are not matched to any statement line (outstanding items).
create function public.unreconciled_movements(p_account uuid, p_until date default null)
returns table (movement_id uuid, movement_date date, direction text, signed_amount text, source_type text,
               component text, description text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select fa.entity_id into v_entity from public.financial_accounts fa where fa.id = p_account;
  if v_entity is null or not app_authz.has_permission(v_entity, 'money.view') then
    raise exception 'FORBIDDEN: missing money.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select mv.id, mv.movement_date, mv.direction, app_private.movement_signed(mv)::text, mv.source_type, mv.component,
         mv.description
  from public.money_movements mv
  where mv.financial_account_id = p_account and mv.source_type <> 'opening_balance'
    and (p_until is null or mv.movement_date <= p_until)
    and not app_private.movement_in_reversal_pair(mv.id)
    and not exists (select 1 from public.reconciliation_matches x where x.movement_id = mv.id)
  order by mv.movement_date, mv.created_at, mv.id;
end
$$;

-- Reconciliation freshness per account (Step 09 §13 "reconciliation status", Step 12 status report).
create function public.reconciliation_status(p_entity uuid)
returns table (
  financial_account_id uuid, name text, last_reconciled_until date, last_statement_closing text,
  session_in_progress boolean, unresolved_lines bigint, outstanding_movements bigint, last_difference text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'money.view') then
    raise exception 'FORBIDDEN: missing money.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select fa.id, fa.name, lr.period_end, lr.statement_closing::text,
         exists (select 1 from public.reconciliation_sessions x
                 where x.financial_account_id = fa.id and x.status in ('open', 'reopened')),
         (select count(*) from public.statement_lines l
           join public.reconciliation_sessions x on x.id = l.session_id and x.status in ('open', 'reopened')
           where l.financial_account_id = fa.id and not l.is_excluded
             and not exists (select 1 from public.reconciliation_matches m where m.statement_line_id = l.id)),
         (select count(*) from public.money_movements mv
           where mv.financial_account_id = fa.id and mv.source_type <> 'opening_balance'
             and not app_private.movement_in_reversal_pair(mv.id)
             and not exists (select 1 from public.reconciliation_matches m where m.movement_id = mv.id)),
         lr.difference::text
  from public.financial_accounts fa
  left join lateral (
    select x.period_end, x.statement_closing, x.difference
    from public.reconciliation_sessions x
    where x.financial_account_id = fa.id and x.status = 'reconciled'
    order by x.period_end desc limit 1
  ) lr on true
  where fa.entity_id = p_entity
  order by fa.name;
end
$$;

-- ------------------------------------------------------------ period close checks (final form for P4)
-- Replaces the P3 function: same checks, plus the money layer. The money-to-ledger mismatch is a BLOCKER (the
-- books and the cash layer disagree); negative balances and unresolved reconciliation are WARNINGS that surface
-- in the closing review without stopping Close (Step 04 §12 "configured blockers/warnings").
create or replace function app_private.period_blockers(p_period uuid)
returns table (code text, severity text, message text, item_count bigint)
language plpgsql stable as $$
declare
  v_p public.accounting_periods%rowtype;
  v_n bigint;
begin
  select * into v_p from public.accounting_periods where id = p_period;
  if not found then
    raise exception 'INVALID: unknown accounting period' using errcode = 'invalid_parameter_value';
  end if;

  select count(*) into v_n from public.journal_entries j where j.period_id = p_period and j.status = 'draft';
  if v_n > 0 then
    return query select 'draft_journals'::text, 'blocker'::text,
      'Draft journals exist in this period and must be posted or discarded'::text, v_n;
  end if;

  -- Detective control: posted journals are balanced by construction; a mismatch means corruption.
  select count(*) into v_n from (
    select j.id
    from public.journal_entries j
    join public.journal_lines l on l.journal_id = j.id
    where j.period_id = p_period and j.status = 'posted'
    group by j.id
    having sum(l.debit) <> sum(l.credit)
  ) q;
  if v_n > 0 then
    return query select 'unbalanced_posted_journals'::text, 'blocker'::text,
      'Posted journals with debit different from credit were found'::text, v_n;
  end if;

  -- Migration must be signed off before normal production posting (Step 15 §24).
  select count(*) into v_n
  from public.opening_balance_batches b
  where b.entity_id = v_p.entity_id and b.status = 'posted'
    and b.cutover_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'opening_not_completed'::text, 'blocker'::text,
      'Opening balances in this period have not been completed and signed off'::text, v_n;
  end if;

  select count(*) into v_n from public.journal_entries j where j.period_id = p_period and j.status = 'posted';
  if v_n = 0 then
    return query select 'empty_period'::text, 'warning'::text,
      'The period has no posted journals'::text, 0::bigint;
  end if;

  -- Money layer against the General Ledger, as of the end of the period (Step 04 §13).
  select count(*) into v_n from app_private.money_control_rows(v_p.entity_id, v_p.period_end) r
  where r.ledger_balance <> r.movement_base_balance;
  if v_n > 0 then
    return query select 'money_ledger_mismatch'::text, 'blocker'::text,
      'Cash/bank balances from money movements differ from the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from app_private.money_control_rows(v_p.entity_id, v_p.period_end) r
  where r.movement_balance < 0;
  if v_n > 0 then
    return query select 'negative_cash_balance'::text, 'warning'::text,
      'A cash/bank account has a negative balance at the end of the period'::text, v_n;
  end if;

  select count(*) into v_n
  from public.statement_lines l
  join public.reconciliation_sessions s on s.id = l.session_id and s.status in ('open', 'reopened')
  where l.entity_id = v_p.entity_id and l.line_date between v_p.period_start and v_p.period_end
    and not l.is_excluded
    and not exists (select 1 from public.reconciliation_matches m where m.statement_line_id = l.id);
  if v_n > 0 then
    return query select 'unresolved_statement_lines'::text, 'warning'::text,
      'Bank statement lines of this period are neither matched nor excluded'::text, v_n;
  end if;

  select count(*) into v_n
  from public.financial_accounts fa
  where fa.entity_id = v_p.entity_id and fa.is_active
    and exists (select 1 from public.money_movements mv
                where mv.financial_account_id = fa.id and mv.movement_date between v_p.period_start and v_p.period_end
                  and mv.source_type <> 'opening_balance')
    and not exists (select 1 from public.reconciliation_sessions s
                    where s.financial_account_id = fa.id and s.status = 'reconciled' and s.period_end >= v_p.period_end);
  if v_n > 0 then
    return query select 'account_not_reconciled'::text, 'warning'::text,
      'Active cash/bank accounts with movements in this period are not reconciled up to its end'::text, v_n;
  end if;

  -- A completed reconciliation whose book balance no longer matches what it recorded: something was booked
  -- inside the reconciled window afterwards, so its evidence is stale.
  select count(*) into v_n
  from public.reconciliation_sessions s
  where s.entity_id = v_p.entity_id and s.status = 'reconciled'
    and s.period_start <= v_p.period_end and s.period_end >= v_p.period_start
    and s.system_book_balance is distinct from app_private.account_balance(s.financial_account_id, s.period_end);
  if v_n > 0 then
    return query select 'reconciliation_stale'::text, 'warning'::text,
      'A completed reconciliation no longer matches the books: movements were added inside its period afterwards'::text, v_n;
  end if;

  -- Cash/bank ledger accounts with postings but no financial account are invisible to the money control.
  select count(distinct a.id) into v_n
  from public.ledger_accounts a
  join public.journal_lines l on l.ledger_account_id = a.id
  join public.journal_entries j on j.id = l.journal_id and j.status = 'posted' and j.period_id = p_period
  where a.entity_id = v_p.entity_id and app_private.is_cash_ledger_account(v_p.entity_id, a.id)
    and not exists (select 1 from public.financial_accounts fa where fa.ledger_account_id = a.id);
  if v_n > 0 then
    return query select 'unmapped_cash_account'::text, 'warning'::text,
      'Cash/bank ledger accounts with postings in this period have no financial account, so the money layer cannot check them'::text, v_n;
  end if;
end
$$;

-- ------------------------------------------------------------ privileges
revoke all on function app_private.tg_recon_sessions_guard() from public;
revoke all on function app_private.tg_statement_lines_guard() from public;
revoke all on function app_private.tg_recon_matches_guard() from public;
revoke all on function app_private.movement_is_matched(uuid) from public;
revoke all on function app_private.movement_in_reversal_pair(uuid) from public;
revoke all on function app_private.match_tolerance_days(uuid) from public;
revoke all on function app_private.movement_signed(public.money_movements) from public;
revoke all on function app_private.lock_recon_session(uuid, boolean) from public;
revoke all on function app_private.recon_figures(uuid) from public;
revoke all on function app_private.period_blockers(uuid) from public;

revoke all on function public.create_reconciliation_session(uuid, text, uuid, date, date, numeric, numeric, text) from public, anon;
revoke all on function public.discard_reconciliation_session(uuid) from public, anon;
revoke all on function public.add_statement_lines(uuid, jsonb) from public, anon;
revoke all on function public.match_statement_line(uuid, uuid[], text) from public, anon;
revoke all on function public.unmatch_statement_line(uuid, text) from public, anon;
revoke all on function public.exclude_statement_line(uuid, text) from public, anon;
revoke all on function public.include_statement_line(uuid) from public, anon;
revoke all on function public.complete_reconciliation(uuid, text) from public, anon;
revoke all on function public.reopen_reconciliation(uuid, text) from public, anon;
revoke all on function public.reconciliation_workspace(uuid) from public, anon;
revoke all on function public.reconciliation_candidates(uuid) from public, anon;
revoke all on function public.unreconciled_movements(uuid, date) from public, anon;
revoke all on function public.reconciliation_status(uuid) from public, anon;
grant execute on function public.create_reconciliation_session(uuid, text, uuid, date, date, numeric, numeric, text) to authenticated;
grant execute on function public.discard_reconciliation_session(uuid) to authenticated;
grant execute on function public.add_statement_lines(uuid, jsonb) to authenticated;
grant execute on function public.match_statement_line(uuid, uuid[], text) to authenticated;
grant execute on function public.unmatch_statement_line(uuid, text) to authenticated;
grant execute on function public.exclude_statement_line(uuid, text) to authenticated;
grant execute on function public.include_statement_line(uuid) to authenticated;
grant execute on function public.complete_reconciliation(uuid, text) to authenticated;
grant execute on function public.reopen_reconciliation(uuid, text) to authenticated;
grant execute on function public.reconciliation_workspace(uuid) to authenticated;
grant execute on function public.reconciliation_candidates(uuid) to authenticated;
grant execute on function public.unreconciled_movements(uuid, date) to authenticated;
grant execute on function public.reconciliation_status(uuid) to authenticated;
