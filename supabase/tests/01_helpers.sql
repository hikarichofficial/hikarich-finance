-- Test helpers (harness only; never part of a migration). Excluded from the schema fingerprint.
create schema if not exists test_helpers;

create or replace function test_helpers.assert(p_cond boolean, p_label text) returns void
language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'TEST FAIL [%]', p_label;
  end if;
end
$$;

-- Runs a statement and requires it to fail (optionally with a specific SQLSTATE).
create or replace function test_helpers.expect_error(p_sql text, p_sqlstate text, p_label text) returns void
language plpgsql as $$
declare
  v_state text;
  v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if p_sqlstate is not null and v_state <> p_sqlstate then
      raise exception 'TEST FAIL [%]: expected SQLSTATE % but got % (%)', p_label, p_sqlstate, v_state, v_msg;
    end if;
    return;
  end;
  raise exception 'TEST FAIL [%]: statement unexpectedly succeeded', p_label;
end
$$;

create or replace function test_helpers.entity(p_code text) returns uuid
language sql stable as $$ select id from public.entities where code = p_code $$;

create or replace function test_helpers.acct(p_entity uuid, p_key text) returns uuid
language sql stable as $$
  select id from public.ledger_accounts where entity_id = p_entity and system_key = p_key
$$;

-- Draft journal in the period containing p_date (period created on demand).
create or replace function test_helpers.draft_journal(
  p_entity uuid, p_date date, p_type text default 'manual', p_reverses uuid default null)
returns uuid
language plpgsql as $$
declare
  v_id uuid;
begin
  insert into public.journal_entries
    (entity_id, entry_date, period_id, entry_type, description, source_type, source_id, posting_key, reverses_journal_id)
  values
    (p_entity, p_date, app_private.ensure_accounting_period(p_entity, p_date), p_type, 'test journal',
     case when p_type in ('manual', 'adjusting') then null else 'test' end,
     case when p_type in ('manual', 'adjusting') then null else gen_random_uuid() end,
     case when p_type in ('manual', 'adjusting') then null else 'test:' || gen_random_uuid()::text end,
     p_reverses)
  returning id into v_id;
  return v_id;
end
$$;

create or replace function test_helpers.add_line(p_journal uuid, p_account uuid, p_debit numeric, p_credit numeric)
returns void
language plpgsql as $$
begin
  insert into public.journal_lines (entity_id, journal_id, line_no, ledger_account_id, debit, credit)
  select j.entity_id, j.id, coalesce((select max(line_no) from public.journal_lines where journal_id = j.id), 0) + 1,
         p_account, p_debit, p_credit
  from public.journal_entries j where j.id = p_journal;
end
$$;

create or replace function test_helpers.post(p_journal uuid) returns void
language sql as $$ update public.journal_entries set status = 'posted' where id = p_journal $$;

-- Balanced two-line journal between two accounts, posted unless p_post is false.
create or replace function test_helpers.simple_journal(
  p_entity uuid, p_date date, p_debit_acct uuid, p_credit_acct uuid, p_amount numeric,
  p_type text default 'system', p_post boolean default true)
returns uuid
language plpgsql as $$
declare
  v_id uuid := test_helpers.draft_journal(p_entity, p_date, p_type);
begin
  perform test_helpers.add_line(v_id, p_debit_acct, p_amount, 0);
  perform test_helpers.add_line(v_id, p_credit_acct, 0, p_amount);
  if p_post then
    perform test_helpers.post(v_id);
  end if;
  return v_id;
end
$$;
