-- P3 (Step 15 §7): the posting engine — the single authoritative path that creates journals.
-- Authority: Step 04 §1, §2, §11, §15, §16 (accounting engine), Step 08 §6, §14, §17, Step 13 §9 (idempotency).
--
-- Layers:
--   app_private.*  building blocks and the system posting service. Unreachable by browser roles; called by
--                  later phases' commands (sales, purchases, money, ...) inside their own transaction.
--   public.*       reviewed RPCs for manual/adjusting journals, reversal and reporting reads. They derive the
--                  actor from the verified JWT, check capabilities per Entity and are idempotent.
-- The hard invariants (balanced, period open, accounts active, immutable, reversal mirrors original) stay in
-- the database triggers from P1; this file adds validation with clear messages, source linkage, numbering
-- and retry safety on top of them.

-- ------------------------------------------------------------ hardening of P1 primitives
-- Two sessions creating the first journal of a month used to race on the period row and one lost with a raw
-- exclusion violation. Creation of a period is now serialised per (Entity, month); the loser simply finds
-- the row the winner created.
create or replace function app_private.ensure_accounting_period(p_entity uuid, p_date date) returns uuid
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

  perform pg_advisory_xact_lock(hashtextextended('period:' || p_entity::text || ':' || v_start::text, 0));
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

-- "Numbered at posting" is enforced by the database, not by convention: whichever path posts a journal, it
-- leaves the draft state with its number (Step 08 §16-§17). Runs after the P1 guard has validated the posting.
create function app_private.tg_journal_number() returns trigger
language plpgsql as $$
begin
  if new.status = 'posted' and old.status = 'draft' and new.journal_number is null then
    insert into public.numbering_sequences (entity_id, scope, prefix)
    values (new.entity_id, 'journal', 'JV')
    on conflict (entity_id, scope) do nothing;
    new.journal_number := app_private.allocate_document_number(new.entity_id, 'journal', new.entry_date);
  end if;
  return new;
end
$$;
create trigger tg_number before update on public.journal_entries
  for each row execute function app_private.tg_journal_number();

-- Business dates are sanity-bounded: no journal is dated before 2000 or more than a year ahead, so a typo can
-- never conjure periods (and journal number years) far away from the working calendar.
create function app_private.assert_business_date(p_date date) returns void
language plpgsql stable as $$
begin
  if p_date is null or p_date < date '2000-01-01'
     or p_date > (now() at time zone 'UTC')::date + 366 then
    raise exception 'INVALID: the date is missing or outside the accepted range (2000-01-01 up to one year ahead)'
      using errcode = 'invalid_parameter_value';
  end if;
end
$$;

-- ------------------------------------------------------------ line normalisation and fingerprints
-- Validates a journal's lines and returns them in canonical form. Lines may name an account by `account_id`
-- or by its stable system key (`account_key`, Step 03 §1) — never by name or code.
create function app_private.normalise_lines(
  p_entity uuid, p_lines jsonb, p_manual boolean default false, p_override boolean default false)
returns jsonb
language plpgsql stable as $$
declare
  v_base public.currency_code;
  v_scale integer;
  v_line jsonb;
  v_no integer := 0;
  v_out jsonb := '[]'::jsonb;
  v_acct uuid;
  r public.ledger_accounts%rowtype;
  v_debit numeric;
  v_credit numeric;
  v_orig_cur text;
  v_orig_amt numeric;
  v_rate numeric;
  v_total_debit numeric := 0;
  v_total_credit numeric := 0;
begin
  select base_currency into v_base from public.entities where id = p_entity;
  if not found then
    raise exception 'INVALID: unknown Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(v_base);

  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'INVALID: a journal needs at least two lines' using errcode = 'invalid_parameter_value';
  end if;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    if jsonb_typeof(v_line) <> 'object' then
      raise exception 'INVALID: line % is not an object', v_no using errcode = 'invalid_parameter_value';
    end if;

    v_acct := null;
    if nullif(v_line ->> 'account_id', '') is not null then
      begin
        v_acct := (v_line ->> 'account_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'INVALID: line % account_id is not a valid identifier', v_no using errcode = 'invalid_parameter_value';
      end;
    elsif nullif(v_line ->> 'account_key', '') is not null then
      select id into v_acct from public.ledger_accounts
      where entity_id = p_entity and system_key = v_line ->> 'account_key';
    end if;
    if v_acct is null then
      raise exception 'INVALID: line % needs a known account_id or account_key of this Entity', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    select * into r from public.ledger_accounts where id = v_acct and entity_id = p_entity;
    if not found then
      raise exception 'INVALID: line % account does not belong to this Entity', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    if r.status <> 'active' or r.is_group then
      raise exception 'INVALID: line % account % cannot receive postings', v_no, r.code
        using errcode = 'invalid_parameter_value';
    end if;
    if p_manual and not r.allows_manual_posting and not p_override then
      raise exception 'INVALID: account % is protected; a manual journal needs an authorized override reason', r.code
        using errcode = 'invalid_parameter_value';
    end if;

    begin
      v_debit := coalesce(nullif(v_line ->> 'debit', '')::numeric, 0);
      v_credit := coalesce(nullif(v_line ->> 'credit', '')::numeric, 0);
      v_orig_cur := nullif(v_line ->> 'original_currency', '');
      v_orig_amt := nullif(v_line ->> 'original_amount', '')::numeric;
      v_rate := nullif(v_line ->> 'exchange_rate', '')::numeric;
    exception when invalid_text_representation or numeric_value_out_of_range then
      raise exception 'INVALID: line % has an amount that is not a valid number', v_no using errcode = 'invalid_parameter_value';
    end;
    if not app_private.is_finite(v_debit) or not app_private.is_finite(v_credit)
       or v_debit >= 10::numeric ^ 16 or v_credit >= 10::numeric ^ 16 then
      raise exception 'INVALID: line % amount is not a finite number below 10^16', v_no using errcode = 'invalid_parameter_value';
    end if;
    if v_debit < 0 or v_credit < 0 or (v_debit > 0) = (v_credit > 0) then
      raise exception 'INVALID: line % must have exactly one positive side', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    if app_private.round_amount(v_debit, v_scale, 'down') <> v_debit
       or app_private.round_amount(v_credit, v_scale, 'down') <> v_credit then
      raise exception 'INVALID: line % has more decimals than the base currency allows (%)', v_no, v_scale
        using errcode = 'invalid_parameter_value';
    end if;
    v_total_debit := v_total_debit + v_debit;
    v_total_credit := v_total_credit + v_credit;

    if (v_orig_cur is null) <> (v_orig_amt is null) or (v_orig_amt is null) <> (v_rate is null) then
      raise exception 'INVALID: line % original currency, amount and rate go together', v_no
        using errcode = 'invalid_parameter_value';
    end if;
    if v_orig_cur is not null then
      if not exists (select 1 from public.currencies where code = v_orig_cur) then
        raise exception 'INVALID: line % unknown currency', v_no using errcode = 'invalid_parameter_value';
      end if;
      if not app_private.is_finite(v_orig_amt) or not app_private.is_finite(v_rate)
         or v_orig_amt <= 0 or v_rate <= 0 or v_orig_amt >= 10::numeric ^ 16 or v_rate >= 10::numeric ^ 10 then
        raise exception 'INVALID: line % original amount and rate must be positive, finite and within range', v_no
          using errcode = 'invalid_parameter_value';
      end if;
      -- The snapshot is stored with 4 (amount) and 10 (rate) decimals; anything finer would be altered silently.
      if app_private.round_amount(v_orig_amt, 4, 'down') <> v_orig_amt
         or app_private.round_amount(v_rate, 10, 'down') <> v_rate then
        raise exception 'INVALID: line % original amount allows 4 decimals and the rate 10', v_no
          using errcode = 'invalid_parameter_value';
      end if;
      -- The preserved original amount x rate must reproduce the base amount (Step 04 §14).
      if app_private.round_amount(v_orig_amt * v_rate, v_scale, 'half_up') <> v_debit + v_credit then
        raise exception 'INVALID: line % base amount does not equal original amount x rate', v_no
          using errcode = 'invalid_parameter_value';
      end if;
    end if;

    v_out := v_out || jsonb_build_object(
      'line_no', v_no, 'account_id', v_acct,
      'debit', trim_scale(v_debit), 'credit', trim_scale(v_credit),
      'description', nullif(btrim(coalesce(v_line ->> 'description', '')), ''),
      'original_currency', v_orig_cur, 'original_amount', v_orig_amt, 'exchange_rate', v_rate);
  end loop;

  if v_total_debit <> v_total_credit then
    raise exception 'INVALID: journal is not balanced (debit % <> credit %)', v_total_debit, v_total_credit
      using errcode = 'invalid_parameter_value';
  end if;
  return v_out;
end
$$;

-- Content identity of a journal's lines: same accounts and amounts in the same order => same fingerprint.
create function app_private.lines_fingerprint(p_lines jsonb) returns text
language sql immutable as $$
  select md5(coalesce(string_agg(
    format('%s|%s|%s', l ->> 'account_id', trim_scale((l ->> 'debit')::numeric), trim_scale((l ->> 'credit')::numeric)),
    ';' order by (l ->> 'line_no')::integer), ''))
  from jsonb_array_elements(p_lines) l
$$;

create function app_private.journal_fingerprint(p_journal uuid) returns text
language sql stable as $$
  select md5(coalesce(string_agg(
    format('%s|%s|%s', ledger_account_id, trim_scale(debit), trim_scale(credit)), ';' order by line_no), ''))
  from public.journal_lines where journal_id = p_journal
$$;

-- ------------------------------------------------------------ idempotency (Step 13 §9)
-- One namespace per operation (`scope`), never a global key space. The record is written in the SAME
-- transaction as its effect: a failed attempt leaves nothing behind and may retry; a committed attempt is
-- replayed instead of repeated. A concurrent duplicate waits on the unique index, then sees the outcome.
create function app_private.idem_begin(p_scope text, p_entity uuid, p_key text, p_fingerprint text)
returns uuid   -- null = new request; otherwise the recorded result id (replay)
language plpgsql as $$
declare
  v_new uuid;
  v_row public.idempotency_keys%rowtype;
begin
  if p_key is null or length(p_key) not between 8 and 200 then
    raise exception 'INVALID: idempotency key must be 8-200 characters' using errcode = 'invalid_parameter_value';
  end if;
  insert into public.idempotency_keys (scope, entity_id, key, actor_id, request_fingerprint)
  values (p_scope, p_entity, p_key, auth.uid(), p_fingerprint)
  on conflict (scope, entity_id, key) do nothing
  returning id into v_new;
  if v_new is not null then
    return null;
  end if;

  select * into v_row from public.idempotency_keys
  where scope = p_scope and entity_id = p_entity and key = p_key;
  if v_row.request_fingerprint is distinct from p_fingerprint then
    raise exception 'INVALID: idempotency key was already used for a different request'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_row.status <> 'succeeded' then
    raise exception 'CONFLICT: this request is still in progress' using errcode = 'integrity_constraint_violation';
  end if;
  return v_row.result_id;
end
$$;

create function app_private.idem_complete(
  p_scope text, p_entity uuid, p_key text, p_result_table text, p_result_id uuid)
returns void
language sql as $$
  update public.idempotency_keys
  set status = 'succeeded', result_table = p_result_table, result_id = p_result_id, completed_at = now()
  where scope = p_scope and entity_id = p_entity and key = p_key
$$;

-- ------------------------------------------------------------ journal construction and posting
-- Creates a DRAFT journal (period created on demand) with its lines. `p_lines` must already be normalised.
-- Returns null when a journal with the same posting key already exists (retry / concurrent duplicate).
create function app_private.build_journal(
  p_entity uuid, p_entry_type text, p_date date, p_description text, p_lines jsonb,
  p_source_type text default null, p_source_id uuid default null, p_posting_key text default null,
  p_rule_version text default null, p_reverses uuid default null, p_override_reason text default null,
  p_batch uuid default null)
returns uuid
language plpgsql as $$
declare
  v_id uuid;
  v_period uuid;
  v_status text;
begin
  perform app_private.assert_business_date(p_date);
  perform app_private.assert_period_postable(p_entity, p_date);
  v_period := app_private.ensure_accounting_period(p_entity, p_date);
  -- Share-lock the period so a concurrent Close cannot slip between this check and the insert.
  select status into v_status from public.accounting_periods where id = v_period for share;
  if v_status not in ('open', 'reopened') then
    raise exception 'CONFLICT: the accounting period of % is % and does not accept postings', p_date, v_status
      using errcode = 'integrity_constraint_violation';
  end if;

  insert into public.journal_entries
    (entity_id, entry_date, period_id, entry_type, description, source_type, source_id, posting_key,
     posting_rule_version, reverses_journal_id, control_override_reason, batch_id)
  values
    (p_entity, p_date, v_period, p_entry_type, p_description,
     p_source_type, p_source_id, p_posting_key, p_rule_version, p_reverses, p_override_reason, p_batch)
  on conflict (entity_id, posting_key) where posting_key is not null do nothing
  returning id into v_id;
  if v_id is null then
    return null;
  end if;

  insert into public.journal_lines
    (entity_id, journal_id, line_no, ledger_account_id, debit, credit, description,
     original_currency, original_amount, exchange_rate)
  select p_entity, v_id, (l ->> 'line_no')::integer, (l ->> 'account_id')::uuid,
         (l ->> 'debit')::numeric, (l ->> 'credit')::numeric, l ->> 'description',
         (l ->> 'original_currency')::public.currency_code, (l ->> 'original_amount')::numeric,
         (l ->> 'exchange_rate')::numeric
  from jsonb_array_elements(p_lines) l;
  return v_id;
end
$$;

-- draft -> posted, with the Entity's journal number allocated in the same transaction. The period row is
-- share-locked so a concurrent Close/Reopen and this posting serialise (a closing period never misses a
-- journal that was already on its way).
create function app_private.finalize_post(p_journal uuid) returns text
language plpgsql as $$
declare
  v_period uuid;
  v_number text;
begin
  select period_id into v_period from public.journal_entries where id = p_journal for update;
  if not found then
    raise exception 'INVALID: unknown journal' using errcode = 'invalid_parameter_value';
  end if;
  perform 1 from public.accounting_periods where id = v_period for share;

  begin
    -- The tg_number trigger allocates the number inside this same UPDATE, after the P1 guard validated it.
    update public.journal_entries set status = 'posted' where id = p_journal returning journal_number into v_number;
  exception when check_violation then
    -- A guard refused the posting (period status changed meanwhile, an account was deactivated, ...).
    raise exception 'CONFLICT: %', sqlerrm using errcode = 'integrity_constraint_violation';
  end;
  return v_number;
end
$$;

-- Readable check that a business date may receive new postings (the trigger remains the hard gate).
create function app_private.assert_period_postable(p_entity uuid, p_date date) returns void
language plpgsql stable as $$
declare
  v_status text;
begin
  select status into v_status from public.accounting_periods
  where entity_id = p_entity and p_date between period_start and period_end;
  if v_status is not null and v_status not in ('open', 'reopened') then
    raise exception 'CONFLICT: the accounting period of % is % and does not accept postings', p_date, v_status
      using errcode = 'integrity_constraint_violation';
  end if;
  -- Closing a period seals everything before it: a month that never had a period row must not be created
  -- behind a closed period, or Close would not really stop backdating (Step 04 §12).
  if v_status is null and exists (
       select 1 from public.accounting_periods
       where entity_id = p_entity and status = 'closed' and period_start > p_date) then
    raise exception 'CONFLICT: % lies before a closed accounting period; earlier months are sealed', p_date
      using errcode = 'integrity_constraint_violation';
  end if;
end
$$;

-- ------------------------------------------------------------ the system posting service (Step 04 §16)
-- Every automatic economic event posts through this function. Identity = source event + rule, so the same
-- event can never post twice: a retry returns the existing journal, and a retry whose content differs is
-- refused instead of silently ignored. Later phases call it inside their own command transaction.
create function app_private.post_system_journal(
  p_entity uuid, p_source_type text, p_source_id uuid, p_rule_key text, p_rule_version text,
  p_date date, p_description text, p_lines jsonb,
  p_entry_type text default 'system', p_batch uuid default null)
returns uuid
language plpgsql as $$
declare
  v_key text;
  v_lines jsonb;
  v_id uuid;
  v_existing public.journal_entries%rowtype;
begin
  if p_entry_type not in ('system', 'opening', 'closing') then
    raise exception 'INVALID: the posting service creates system, opening or closing journals only'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_source_type !~ '^[a-z][a-z0-9_]*$' or p_rule_key !~ '^[a-z][a-z0-9_.]*$' or p_source_id is null then
    raise exception 'INVALID: source type, source id and rule key are required' using errcode = 'invalid_parameter_value';
  end if;
  v_key := p_source_type || ':' || p_source_id::text || ':' || p_rule_key;
  v_lines := app_private.normalise_lines(p_entity, p_lines);

  v_id := app_private.build_journal(
    p_entity, p_entry_type, p_date, p_description, v_lines, p_source_type, p_source_id, v_key,
    p_rule_version, null, null, p_batch);

  if v_id is null then
    -- Already posted (or being posted by a concurrent identical request): replay if identical.
    select * into v_existing from public.journal_entries where entity_id = p_entity and posting_key = v_key;
    if v_existing.status <> 'posted'
       or v_existing.entry_date <> p_date
       or app_private.journal_fingerprint(v_existing.id) <> app_private.lines_fingerprint(v_lines) then
      raise exception 'CONFLICT: posting key % already exists with different content', v_key
        using errcode = 'integrity_constraint_violation';
    end if;
    return v_existing.id;
  end if;

  perform app_private.finalize_post(v_id);
  return v_id;
end
$$;

-- Mirrors a posted journal (debit/credit swapped) as a linked reversal. Used by the public command for
-- manual/adjusting journals and, later, by source modules that void or cancel their own events.
create function app_private.reverse_journal_core(p_original uuid, p_date date, p_reason text) returns uuid
language plpgsql as $$
declare
  v_o public.journal_entries%rowtype;
  v_lines jsonb;
  v_id uuid;
begin
  select * into v_o from public.journal_entries where id = p_original for update;
  if not found or v_o.status <> 'posted' then
    raise exception 'INVALID: only a posted journal can be reversed' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.journal_entries where reverses_journal_id = p_original) then
    raise exception 'CONFLICT: this journal has already been reversed' using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < v_o.entry_date then
    raise exception 'INVALID: a reversal cannot be dated before the original entry' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_period_postable(v_o.entity_id, p_date);

  select jsonb_agg(jsonb_build_object(
      'line_no', line_no, 'account_id', ledger_account_id, 'debit', credit, 'credit', debit,
      'description', description, 'original_currency', original_currency,
      'original_amount', original_amount, 'exchange_rate', exchange_rate) order by line_no)
    into v_lines
  from public.journal_lines where journal_id = p_original;

  v_id := app_private.build_journal(
    v_o.entity_id, 'reversal', p_date,
    format('Reversal of %s: %s', coalesce(v_o.journal_number, v_o.id::text), p_reason),
    v_lines, 'journal_reversal', p_original, 'reversal:' || p_original::text, 'reversal.v1', p_original);
  perform app_private.finalize_post(v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ public RPCs
create function public.create_journal_draft(
  p_entity uuid, p_key text, p_entry_type text, p_date date, p_description text, p_lines jsonb,
  p_override_reason text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_override text := nullif(btrim(coalesce(p_override_reason, '')), '');
  v_replay uuid;
  v_lines jsonb;
  v_id uuid;
  v_min_len integer;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'accounting.journal_create') then
    raise exception 'FORBIDDEN: missing accounting.journal_create' using errcode = 'insufficient_privilege';
  end if;
  if v_override is not null and not app_authz.has_permission(p_entity, 'accounting.protected_manage') then
    raise exception 'FORBIDDEN: overriding protected accounts needs accounting.protected_manage'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_entry_type, '') not in ('manual', 'adjusting') then
    raise exception 'INVALID: entry type must be manual or adjusting' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  v_min_len := case when p_entry_type = 'adjusting' then 10 else 1 end;
  if p_date is null or length(btrim(coalesce(p_description, ''))) < v_min_len then
    raise exception 'INVALID: date and an explanation are required (adjusting journals need at least 10 characters)'
      using errcode = 'invalid_parameter_value';
  end if;

  v_replay := app_private.idem_begin('journal.create', p_entity, p_key,
    md5(jsonb_build_object('type', p_entry_type, 'date', p_date, 'desc', p_description,
                           'lines', p_lines, 'override', v_override)::text));
  if v_replay is not null then
    -- The draft may have been discarded since: answer clearly instead of handing back a dead identifier.
    if not exists (select 1 from public.journal_entries where id = v_replay) then
      raise exception 'CONFLICT: the draft of this request was discarded; use a new idempotency key'
        using errcode = 'integrity_constraint_violation';
    end if;
    return v_replay;
  end if;

  perform app_private.assert_period_postable(p_entity, p_date);
  v_lines := app_private.normalise_lines(p_entity, p_lines, true, v_override is not null);
  v_id := app_private.build_journal(p_entity, p_entry_type, p_date, btrim(p_description), v_lines,
                                    null, null, null, null, null, v_override);
  perform app_private.idem_complete('journal.create', p_entity, p_key, 'journal_entries', v_id);
  return v_id;
end
$$;

create function public.discard_journal_draft(p_journal uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_j public.journal_entries%rowtype;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_j from public.journal_entries where id = p_journal;
  if not found or not app_authz.has_permission(v_j.entity_id, 'accounting.journal_create') then
    raise exception 'FORBIDDEN' using errcode = 'insufficient_privilege';
  end if;
  -- Lock only after the caller is known to be entitled to this journal.
  select * into v_j from public.journal_entries where id = p_journal for update;
  if not found or v_j.status <> 'draft' or v_j.entry_type not in ('manual', 'adjusting') then
    raise exception 'CONFLICT: only manual or adjusting drafts can be discarded' using errcode = 'integrity_constraint_violation';
  end if;
  delete from public.journal_entries where id = p_journal;
end
$$;

create function public.post_journal(p_journal uuid, p_key text, p_expected_version integer default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_j public.journal_entries%rowtype;
  v_replay uuid;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_j from public.journal_entries where id = p_journal;
  -- The same answer for "does not exist" and "not allowed": no existence leak across Entities.
  if not found or not app_authz.has_permission(v_j.entity_id, 'accounting.journal_post') then
    raise exception 'FORBIDDEN: missing accounting.journal_post' using errcode = 'insufficient_privilege';
  end if;
  select * into v_j from public.journal_entries where id = p_journal for update;
  if v_j.entry_type not in ('manual', 'adjusting') then
    raise exception 'FORBIDDEN: system journals are posted by their source workflow' using errcode = 'insufficient_privilege';
  end if;

  v_replay := app_private.idem_begin('journal.post', v_j.entity_id, p_key, md5(p_journal::text));
  if v_replay is not null then
    return v_replay;
  end if;

  if v_j.status <> 'draft' then
    raise exception 'CONFLICT: journal is already posted' using errcode = 'integrity_constraint_violation';
  end if;
  if p_expected_version is not null and v_j.version <> p_expected_version then
    raise exception 'CONFLICT: the draft was changed by someone else (stale version)' using errcode = 'integrity_constraint_violation';
  end if;
  if v_j.control_override_reason is not null
     and not app_authz.has_permission(v_j.entity_id, 'accounting.protected_manage') then
    raise exception 'FORBIDDEN: posting to protected accounts needs accounting.protected_manage'
      using errcode = 'insufficient_privilege';
  end if;

  perform app_private.assert_period_postable(v_j.entity_id, v_j.entry_date);
  perform app_private.finalize_post(p_journal);
  perform app_private.idem_complete('journal.post', v_j.entity_id, p_key, 'journal_entries', p_journal);
  return p_journal;
end
$$;

create function public.reverse_journal(p_journal uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_uid uuid := auth.uid();
  v_o public.journal_entries%rowtype;
  v_replay uuid;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_o from public.journal_entries where id = p_journal;
  if not found or not app_authz.has_permission(v_o.entity_id, 'accounting.journal_post') then
    raise exception 'FORBIDDEN: missing accounting.journal_post' using errcode = 'insufficient_privilege';
  end if;
  if v_o.entry_type not in ('manual', 'adjusting') then
    raise exception 'FORBIDDEN: source-driven journals are corrected through their source module (Step 04 §11)'
      using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'INVALID: a reversal needs a date and a reason of at least 5 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  -- Undoing a journal that needed an override is as sensitive as posting it.
  if v_o.control_override_reason is not null
     and not app_authz.has_permission(v_o.entity_id, 'accounting.protected_manage') then
    raise exception 'FORBIDDEN: reversing a protected-account override needs accounting.protected_manage'
      using errcode = 'insufficient_privilege';
  end if;

  v_replay := app_private.idem_begin('journal.reverse', v_o.entity_id, p_key,
    md5(jsonb_build_object('journal', p_journal, 'date', p_date, 'reason', p_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;

  perform set_config('app.audit_reason', btrim(p_reason), true);
  v_id := app_private.reverse_journal_core(p_journal, p_date, btrim(p_reason));
  perform app_private.idem_complete('journal.reverse', v_o.entity_id, p_key, 'journal_entries', v_id);
  return v_id;
end
$$;

-- Trial balance over POSTED lines only (Step 04 §13: balances derive from posted journals). Amounts are
-- returned as exact decimal text, never as JSON numbers (Step 13 §25).
create function public.trial_balance(p_entity uuid, p_as_of date default null)
returns table (account_id uuid, code text, name text, account_class text, debit text, credit text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'accounting.view') then
    raise exception 'FORBIDDEN: missing accounting.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select a.id, a.code, a.name, a.account_class,
         coalesce(sum(l.debit), 0)::text, coalesce(sum(l.credit), 0)::text
  from public.ledger_accounts a
  join public.journal_lines l on l.ledger_account_id = a.id and l.entity_id = a.entity_id
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  where a.entity_id = p_entity and j.status = 'posted' and (p_as_of is null or j.entry_date <= p_as_of)
  group by a.id, a.code, a.name, a.account_class
  order by a.code;
end
$$;

-- ------------------------------------------------------------ privileges
revoke all on function app_private.normalise_lines(uuid, jsonb, boolean, boolean) from public;
revoke all on function app_private.lines_fingerprint(jsonb) from public;
revoke all on function app_private.journal_fingerprint(uuid) from public;
revoke all on function app_private.idem_begin(text, uuid, text, text) from public;
revoke all on function app_private.idem_complete(text, uuid, text, text, uuid) from public;
revoke all on function app_private.build_journal(uuid, text, date, text, jsonb, text, uuid, text, text, uuid, text, uuid) from public;
revoke all on function app_private.finalize_post(uuid) from public;
revoke all on function app_private.assert_period_postable(uuid, date) from public;
revoke all on function app_private.assert_business_date(date) from public;
revoke all on function app_private.tg_journal_number() from public;
revoke all on function app_private.post_system_journal(uuid, text, uuid, text, text, date, text, jsonb, text, uuid) from public;
revoke all on function app_private.reverse_journal_core(uuid, date, text) from public;

revoke all on function public.create_journal_draft(uuid, text, text, date, text, jsonb, text) from public, anon;
revoke all on function public.discard_journal_draft(uuid) from public, anon;
revoke all on function public.post_journal(uuid, text, integer) from public, anon;
revoke all on function public.reverse_journal(uuid, text, date, text) from public, anon;
revoke all on function public.trial_balance(uuid, date) from public, anon;
grant execute on function public.create_journal_draft(uuid, text, text, date, text, jsonb, text) to authenticated;
grant execute on function public.discard_journal_draft(uuid) to authenticated;
grant execute on function public.post_journal(uuid, text, integer) to authenticated;
grant execute on function public.reverse_journal(uuid, text, date, text) to authenticated;
grant execute on function public.trial_balance(uuid, date) to authenticated;
