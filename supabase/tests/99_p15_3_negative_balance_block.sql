-- P15 decision 55 (OWNER answer 4 October 2026): which account kinds (bank/cash/ewallet) may never go
-- negative, settable from Settings through `set_negative_balance_block`. `record_movement`'s own reading
-- of `entity_settings.money.block_negative_balance` is already covered directly in 91_p4_money.sql; this
-- file covers the new write RPC itself -- authorization, step-up, validation, the saved value, dedup, an
-- empty list unblocking everything, the audit record -- and that a write through the RPC actually changes
-- what `record_movement` enforces end to end. Synthetic data; the whole file runs in one transaction that
-- is rolled back.
begin;
set local client_min_messages = warning;

-- Test-only window on the ledger control rows that works whichever role the test currently acts as (same
-- local helper as 91_p4_money.sql defines for itself -- each test file's transaction is rolled back on its
-- own, so nothing persists from one file to the next).
create function test_helpers.mc(p_entity uuid, p_as_of date default null)
returns table (financial_account_id uuid, name text, kind text, currency text, is_active boolean,
               movement_balance numeric, movement_base_balance numeric, ledger_balance numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.money_control_rows(p_entity, p_as_of) $f$;
grant execute on function test_helpers.mc(uuid, date) to anon, authenticated;

do $$
declare
  e1 uuid;
  v_owner uuid := 'e0550000-0000-0000-0000-000000000001';
  v_admin uuid := 'e0550000-0000-0000-0000-000000000002';
  v_bank uuid;
  v_cash uuid;
  v_result text[];
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p15_nb1', 'P15 Negative Balance (synthetic)')
  returning id into e1;
  perform app_private.provision_default_coa(e1);
  perform test_helpers.mk_user(v_owner, 'p55-owner');
  perform test_helpers.mk_user(v_admin, 'p55-admin');
  perform test_helpers.mk_member(e1, v_owner, 'owner');
  perform test_helpers.mk_member(e1, v_admin, 'finance_admin');

  -- 1. authorization, step-up, validation
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.set_negative_balance_block(%L, array[%L])', e1, 'bank'),
    'FORBIDDEN', '1.1 finance_admin lacks system.entity_config');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner, 'aal2', interval '1 hour');
  perform test_helpers.expect_msg(format('select public.set_negative_balance_block(%L, array[%L])', e1, 'bank'),
    'STEP_UP_REQUIRED', '1.2 a step-up is required');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.set_negative_balance_block(%L, array[%L])', e1, 'crypto'),
    'INVALID', '1.3 an unknown account kind is refused');
  perform test_helpers.expect_msg(format('select public.set_negative_balance_block(%L, null)', e1),
    'INVALID', '1.4 a null list is refused');

  -- 2. a valid change: block bank only (the OWNER's own answer), deduplicated and sorted
  execute format('select public.set_negative_balance_block(%L, array[%L, %L])', e1, 'bank', 'bank') into v_result;
  perform test_helpers.assert(v_result = array['bank'], '2.1 the saved list is returned, deduplicated');
  perform test_helpers.assert((select setting_value from public.entity_settings
    where entity_id = e1 and setting_key = 'money.block_negative_balance') = '["bank"]'::jsonb,
    '2.2 stored as a jsonb array');
  perform test_helpers.assert(exists (select 1 from public.audit_events where entity_id = e1
    and action = 'entity_settings.block_negative_balance_changed'
    and after_state -> 'kinds' = '["bank"]'::jsonb), '2.3 audited with the new value');

  -- 3. changing it again updates the same row (no duplicate entity_settings row) and advances its version
  execute format('select public.set_negative_balance_block(%L, array[%L, %L])', e1, 'bank', 'cash') into v_result;
  perform test_helpers.assert(v_result = array['bank', 'cash'], '3.1 both kinds saved, sorted');
  perform test_helpers.assert((select count(*) from public.entity_settings
    where entity_id = e1 and setting_key = 'money.block_negative_balance') = 1, '3.2 still one row');
  perform test_helpers.assert((select version from public.entity_settings
    where entity_id = e1 and setting_key = 'money.block_negative_balance') = 2, '3.3 version advanced');

  -- 4. an empty list unblocks everything again
  execute format('select public.set_negative_balance_block(%L, array[]::text[])', e1) into v_result;
  perform test_helpers.assert(v_result = array[]::text[], '4.1 an empty list is accepted and returned empty');
  perform test_helpers.logout();

  -- 5. end to end: the RPC's write is really what record_movement enforces (not just stored and ignored)
  perform test_helpers.login(v_owner);
  v_bank := public.create_financial_account(e1, 'key-nb-a-1', 'bank', 'NB Bank', 'IDR');
  v_cash := public.create_financial_account(e1, 'key-nb-a-2', 'cash', 'NB Cash', 'IDR');
  perform public.record_balance_adjustment(e1, 'key-nb-f-1', v_bank, 'in', 100000, null, date '2026-09-05',
    test_helpers.acct(e1, 'INTEREST_INCOME'), 'Synthetic starting funds');
  -- unblocked: an overdraft is allowed (only a soft warning elsewhere, not enforced here)
  perform public.create_transfer(e1, 'key-nb-t-1', v_bank, v_cash, date '2026-09-06', 150000, null, 0, null, null,
    'Overdraw while unblocked', null, true);
  perform test_helpers.assert((select movement_balance from test_helpers.mc(e1) where financial_account_id = v_bank) = -50000,
    '5.1 unblocked: the bank account went negative');

  perform public.set_negative_balance_block(e1, array['bank']);
  perform test_helpers.expect_msg(format('select public.create_transfer(%L, ''key-nb-t-2'', %L, %L, date ''2026-09-07'', 1, null, 0, null, null, %L, null, true)',
    e1, v_bank, v_cash, 'Blocked by the RPC''s own write'), 'CONFLICT', '5.2 blocked: any further overdraft of bank is refused');
  -- cash is not in the blocked list, so the same kind of overdraft there still goes through
  perform public.create_transfer(e1, 'key-nb-t-3', v_cash, v_bank, date '2026-09-07', 1000000, null, 0, null, null,
    'Cash still unblocked', null, true);
  perform test_helpers.assert((select movement_balance from test_helpers.mc(e1) where financial_account_id = v_cash) < 0,
    '5.3 unblocked kind: cash can still go negative');
  perform test_helpers.logout();
end
$$;

rollback;
