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

-- ---------------------------------------------------------------- P2: acting as browser roles
-- Runs as a signed-in user exactly like PostgREST does: verified claims in request.jwt.claims + role switch.
-- p_auth_age is how long ago the user last authenticated (feeds the `amr` claim used for step-up).
create or replace function test_helpers.login(
  p_user uuid, p_aal text default 'aal2', p_auth_age interval default interval '1 minute')
returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', p_user, 'role', 'authenticated', 'aal', p_aal,
      'amr', jsonb_build_array(jsonb_build_object(
        'method', case when p_aal = 'aal2' then 'totp' else 'password' end,
        'timestamp', extract(epoch from now() - p_auth_age)::bigint)))::text, true);
  set local role authenticated;
end
$$;

create or replace function test_helpers.as_anon() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
end
$$;

create or replace function test_helpers.logout() returns void
language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', '', true);
end
$$;

-- Number of rows a query returns under the CURRENT role (RLS applies).
create or replace function test_helpers.rows(p_sql text) returns bigint
language plpgsql as $$
declare
  n bigint;
begin
  execute 'select count(*) from (' || p_sql || ') q' into n;
  return n;
end
$$;

-- Number of rows an INSERT/UPDATE/DELETE affects under the CURRENT role (RLS applies).
create or replace function test_helpers.affected(p_sql text) returns bigint
language plpgsql as $$
declare
  n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end
$$;

-- Creates an auth user + profile (superuser context).
create or replace function test_helpers.mk_user(p_id uuid, p_name text) returns void
language plpgsql as $$
begin
  insert into auth.users (id, email) values (p_id, p_name || '@example.invalid');
  insert into public.profiles (id, display_name) values (p_id, p_name);
end
$$;

create or replace function test_helpers.mk_member(p_entity uuid, p_user uuid, p_role_key text) returns uuid
language sql as $$
  insert into public.entity_memberships (entity_id, user_id, role_id)
  select p_entity, p_user, r.id from public.roles r where r.role_key = p_role_key
  returning id
$$;

-- Message of the error a statement raises ('' when it succeeds).
create or replace function test_helpers.sqlerrm_of(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return '';
exception when others then
  return sqlerrm;
end
$$;

-- Runs a statement and requires it to fail with a message starting with p_prefix (the application-level
-- error prefixes UNAUTHENTICATED / FORBIDDEN / STEP_UP_REQUIRED / INVALID / CONFLICT, Step 06 §12).
create or replace function test_helpers.expect_msg(p_sql text, p_prefix text, p_label text) returns void
language plpgsql as $$
declare
  v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if left(v_msg, length(p_prefix)) <> p_prefix then
      raise exception 'TEST FAIL [%]: expected message starting with "%" but got "%"', p_label, p_prefix, v_msg;
    end if;
    return;
  end;
  raise exception 'TEST FAIL [%]: statement unexpectedly succeeded', p_label;
end
$$;

-- ---------------------------------------------------------------- P5: sales layer helpers (also used by the concurrency rounds)
create function test_helpers.today(p_entity uuid) returns date
language sql stable security definer set search_path = pg_catalog, public as $f$ select app_private.entity_today(p_entity) $f$;

-- The reconciliation invariants of the sales layer, checked after every major step: money movements equal the
-- ledger, the AR and advance sub-ledgers equal the ledger, no invoice is over-allocated or over-refunded, and a
-- payment's split adds up.
create function test_helpers.controls(p_entity uuid, p_label text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $f$
declare
  c record;
begin
  if exists (select 1 from app_private.money_control_rows(p_entity) r where r.ledger_balance <> r.movement_base_balance) then
    raise exception 'TEST FAIL [%]: money movements differ from the ledger', p_label;
  end if;
  select * into c from app_private.ar_control(p_entity);
  if c.sub_ledger <> c.ledger_sales then
    raise exception 'TEST FAIL [%]: AR sub-ledger % differs from ledger %', p_label, c.sub_ledger, c.ledger_sales;
  end if;
  if c.advance_sub_ledger <> c.advance_ledger_sales then
    raise exception 'TEST FAIL [%]: advance sub-ledger % differs from ledger %', p_label, c.advance_sub_ledger, c.advance_ledger_sales;
  end if;
  if exists (select 1 from app_private.invoice_positions(p_entity) x where x.outstanding < 0 or x.base_outstanding < 0
             or x.settled > x.total) then
    raise exception 'TEST FAIL [%]: an invoice is over-allocated', p_label;
  end if;
  if exists (select 1 from public.payments p where p.entity_id = p_entity and p.allocated_amount + p.advance_amount <> p.amount) then
    raise exception 'TEST FAIL [%]: a payment split does not add up', p_label;
  end if;
  if exists (select 1 from public.payments p where p.entity_id = p_entity and p.status = 'confirmed'
             and (select coalesce(sum(a.amount), 0) from public.payment_allocations a
                  where a.payment_id = p.id and a.kind = 'payment' and a.status = 'active') <> p.allocated_amount) then
    raise exception 'TEST FAIL [%]: payment allocations differ from the payment', p_label;
  end if;
  if exists (select 1 from public.payments p where p.entity_id = p_entity and p.status = 'confirmed'
             and (select rem_amount from app_private.payment_advance_state(p.id)) < 0) then
    raise exception 'TEST FAIL [%]: an advance went negative', p_label;
  end if;
end
$f$;
grant execute on function test_helpers.controls(uuid, text) to public;


-- Helpers are callable while acting as a browser role (declared last so it covers every function above).
grant usage on schema test_helpers to anon, authenticated;
grant execute on all functions in schema test_helpers to anon, authenticated;
