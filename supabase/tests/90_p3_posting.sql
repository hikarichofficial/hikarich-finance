-- P3 gate (Step 15 §7, Step 16 G3): trial posting scenarios always balance; a duplicate or retry cannot
-- double-post; posted journals are immutable. Also: decimal-safe money, period controls, opening balances.
-- All data is synthetic. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

-- ================================================================ fixtures (superuser)
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_open uuid;
begin
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000001', 'owner');
  perform app_private.bootstrap_owner('b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000002', 'staff');
  perform test_helpers.mk_member(pt, 'b0000000-0000-0000-0000-000000000002', 'finance_staff');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_member(pt, 'b0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_member(pt, 'b0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000007', 'nobody');

  -- A clean company Entity for the opening-balance workflow.
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p3_open', 'P3 OPEN (synthetic)') returning id into v_open;
  perform app_private.provision_default_coa(v_open);
  perform test_helpers.mk_member(v_open, 'b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_open, 'b0000000-0000-0000-0000-000000000006', 'accountant');
end
$$;

-- ================================================================ 1. money primitives
do $$
declare
  v_parts numeric[];
  v_total numeric;
  v_weights numeric[];
  v_n integer;
  v_i integer;
  v_exact numeric;
  v_sum numeric;
begin
  perform test_helpers.assert(app_private.currency_scale('IDR') = 2, 'IDR has 2 minor-unit digits');
  perform test_helpers.assert(app_private.currency_scale('JPY') = 0, 'JPY has 0 minor-unit digits');

  -- half_up: ties go away from zero
  perform test_helpers.assert(app_private.round_amount(2.5, 0) = 3, 'half_up 2.5');
  perform test_helpers.assert(app_private.round_amount(-2.5, 0) = -3, 'half_up -2.5');
  perform test_helpers.assert(app_private.round_amount(0.125, 2) = 0.13, 'half_up 0.125');
  perform test_helpers.assert(app_private.round_amount(-0.125, 2) = -0.13, 'half_up -0.125');
  perform test_helpers.assert(app_private.round_amount(1.004, 2) = 1.00, 'half_up rounds down below the tie');
  perform test_helpers.assert(app_private.round_amount(1.005, 2) = 1.01, 'half_up is exact decimal, not binary float');
  -- half_even: ties go to the even neighbour
  perform test_helpers.assert(app_private.round_amount(2.5, 0, 'half_even') = 2, 'half_even 2.5');
  perform test_helpers.assert(app_private.round_amount(3.5, 0, 'half_even') = 4, 'half_even 3.5');
  perform test_helpers.assert(app_private.round_amount(-2.5, 0, 'half_even') = -2, 'half_even -2.5');
  perform test_helpers.assert(app_private.round_amount(0.125, 2, 'half_even') = 0.12, 'half_even 0.125');
  perform test_helpers.assert(app_private.round_amount(0.135, 2, 'half_even') = 0.14, 'half_even 0.135');
  perform test_helpers.assert(app_private.round_amount(2.6, 0, 'half_even') = 3, 'half_even above tie');
  -- directed modes
  perform test_helpers.assert(app_private.round_amount(2.999, 2, 'down') = 2.99, 'down truncates');
  perform test_helpers.assert(app_private.round_amount(-2.999, 2, 'down') = -2.99, 'down truncates toward zero');
  perform test_helpers.assert(app_private.round_amount(2.001, 2, 'up') = 2.01, 'up rounds away');
  perform test_helpers.assert(app_private.round_amount(-2.001, 2, 'up') = -2.01, 'up rounds away from zero');
  perform test_helpers.assert(app_private.round_amount(2.00, 2, 'up') = 2.00, 'up keeps exact values');
  perform test_helpers.assert(app_private.round_amount(null, 2) is null, 'null stays null');
  perform test_helpers.expect_msg('select app_private.round_amount(1, 2, ''banana'')', 'INVALID', 'unknown mode');
  perform test_helpers.expect_msg('select app_private.round_amount(1, 11)', 'INVALID', 'scale too large');
  perform test_helpers.expect_msg('select app_private.round_amount(1, -1)', 'INVALID', 'negative scale');

  -- conversion rounds once, with the target currency's own minor unit
  perform test_helpers.assert(app_private.convert_amount(10, 16000.55, 'IDR') = 160005.50, 'convert USD->IDR');
  perform test_helpers.assert(app_private.convert_amount(100, 155.555, 'JPY') = 15556, 'convert to a 0-decimal currency');
  perform test_helpers.expect_msg('select app_private.convert_amount(1, 0, ''IDR'')', 'INVALID', 'zero rate');

  -- allocation: parts always add up to the total
  v_parts := app_private.allocate_amount(100, array[1, 1, 1], 2);
  perform test_helpers.assert(v_parts = array[33.34, 33.33, 33.33], 'allocate 100 in three: earliest gets the extra cent');
  perform test_helpers.assert(app_private.allocate_amount(0.05, array[1, 1, 1], 2) = array[0.02, 0.02, 0.01], 'allocate 0.05 in three');
  perform test_helpers.assert(app_private.allocate_amount(-100, array[1, 1, 1], 2) = array[-33.34, -33.33, -33.33], 'allocate negative total');
  perform test_helpers.assert(app_private.allocate_amount(10, array[0, 1], 2) = array[0, 10]::numeric[], 'zero weight gets nothing');
  perform test_helpers.assert(app_private.allocate_amount(7, array[1], 0) = array[7]::numeric[], 'single weight');
  perform test_helpers.expect_msg('select app_private.allocate_amount(1, array[0, 0], 2)', 'INVALID', 'all-zero weights');
  perform test_helpers.expect_msg('select app_private.allocate_amount(1.001, array[1], 2)', 'INVALID', 'too many decimals');
  perform test_helpers.expect_msg('select app_private.allocate_amount(1, array[-1, 2], 2)', 'INVALID', 'negative weight');
  -- non-finite and NULL inputs are refused instead of looping or returning NULLs
  perform test_helpers.expect_msg('select app_private.allocate_amount(''NaN''::numeric, array[1, 1], 2)', 'INVALID', 'NaN total');
  perform test_helpers.expect_msg('select app_private.allocate_amount(1, array[''Infinity''::numeric, 1], 2)', 'INVALID', 'infinite weight');
  perform test_helpers.expect_msg('select app_private.allocate_amount(1, array[''NaN''::numeric, 1], 2)', 'INVALID', 'NaN weight');
  perform test_helpers.expect_msg('select app_private.allocate_amount(null, array[1, 1], 2)', 'INVALID', 'NULL total');
  perform test_helpers.expect_msg('select app_private.allocate_amount(1, array[1, 1], null)', 'INVALID', 'NULL scale');
  perform test_helpers.expect_msg('select app_private.allocate_amount(1, array[1, 1], 1000000)', 'INVALID', 'absurd scale');
  perform test_helpers.expect_msg('select app_private.round_amount(''NaN''::numeric, 2)', 'INVALID', 'round NaN');
  perform test_helpers.expect_msg('select app_private.round_amount(''Infinity''::numeric, 2)', 'INVALID', 'round Infinity');
  perform test_helpers.expect_msg('select app_private.convert_amount(1, ''NaN''::numeric, ''IDR'')', 'INVALID', 'NaN rate');
  perform test_helpers.expect_msg('select app_private.convert_amount(1, null, ''IDR'')', 'INVALID', 'NULL rate');

  -- property: for 400 random splits the parts sum exactly to the total and stay within one unit of the exact share
  perform setseed(0.4242);
  for v_n in 1..400 loop
    v_total := (floor(random() * 2000000))::numeric / 100;
    v_weights := array[]::numeric[];
    for v_i in 1..(1 + floor(random() * 6))::integer loop
      v_weights := v_weights || (floor(random() * 40))::numeric;
    end loop;
    if (select sum(w) from unnest(v_weights) w) = 0 then
      v_weights[1] := 1;
    end if;
    v_parts := app_private.allocate_amount(v_total, v_weights, 2);
    select sum(p) into v_sum from unnest(v_parts) p;
    perform test_helpers.assert(v_sum = v_total, format('allocation sums to total (%s split %s)', v_total, v_weights));
    for v_i in 1..cardinality(v_weights) loop
      v_exact := v_total * v_weights[v_i] / (select sum(w) from unnest(v_weights) w);
      perform test_helpers.assert(abs(v_parts[v_i] - v_exact) < 0.01 + 1e-9, 'each part is within one unit of its exact share');
      perform test_helpers.assert(v_parts[v_i] >= 0, 'parts are non-negative');
    end loop;
  end loop;
end
$$;

-- ================================================================ 2. line validation
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_bank uuid := test_helpers.acct(pt, 'BANK_OPERATING');
  v_exp uuid := test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE');
  v_grp uuid;
  v_inactive uuid;
  v_out jsonb;
begin
  select id into v_grp from public.ledger_accounts where entity_id = pt and is_group limit 1;
  insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance, status)
  values (pt, '6999', 'Retired test account', 'expense', 'debit', 'inactive') returning id into v_inactive;

  -- account_key resolves to the same account as account_id; output is canonical
  v_out := app_private.normalise_lines(pt, jsonb_build_array(
    jsonb_build_object('account_key', 'OFFICE_GENERAL_EXPENSE', 'debit', 100.50),
    jsonb_build_object('account_id', v_bank, 'credit', '100.5')));
  perform test_helpers.assert(v_out -> 0 ->> 'account_id' = v_exp::text and (v_out -> 0 ->> 'line_no') = '1', 'account_key resolves');
  perform test_helpers.assert((v_out -> 1 ->> 'credit')::numeric = 100.5, 'string amounts are accepted');

  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt, '[]'), 'INVALID', 'no lines');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 1))), 'INVALID', 'single line');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 1, 'credit', 1),
                      jsonb_build_object('account_id', v_exp, 'debit', 0, 'credit', 0))), 'INVALID', 'both sides / no side');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', -5),
                      jsonb_build_object('account_id', v_exp, 'credit', -5))), 'INVALID', 'negative amounts');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 10.001),
                      jsonb_build_object('account_id', v_exp, 'credit', 10.001))), 'INVALID', 'more decimals than IDR allows');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 10),
                      jsonb_build_object('account_id', v_exp, 'credit', 9))), 'INVALID', 'unbalanced');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_key', 'NO_SUCH_KEY', 'debit', 10),
                      jsonb_build_object('account_id', v_exp, 'credit', 10))), 'INVALID', 'unknown account key');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_grp, 'debit', 10),
                      jsonb_build_object('account_id', v_exp, 'credit', 10))), 'INVALID', 'group account');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_inactive, 'debit', 10),
                      jsonb_build_object('account_id', v_exp, 'credit', 10))), 'INVALID', 'inactive account');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', test_helpers.acct(pe, 'PERSONAL_BANK'), 'debit', 10),
                      jsonb_build_object('account_id', v_exp, 'credit', 10))), 'INVALID', 'account of another Entity');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb, true)', pt,
    jsonb_build_array(jsonb_build_object('account_key', 'ACCOUNTS_RECEIVABLE', 'debit', 10),
                      jsonb_build_object('account_id', v_exp, 'credit', 10))), 'INVALID', 'protected account needs override for a manual journal');
  perform test_helpers.assert(app_private.normalise_lines(pt, jsonb_build_array(
      jsonb_build_object('account_key', 'ACCOUNTS_RECEIVABLE', 'debit', 10),
      jsonb_build_object('account_id', v_exp, 'credit', 10)), true, true) is not null, 'override lifts the protected-account check');

  -- malformed input is refused with a readable message, never a raw database error
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 'NaN'), jsonb_build_object('account_id', v_exp, 'credit', 'NaN'))),
    'INVALID', 'NaN amount');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 'Infinity'), jsonb_build_object('account_id', v_exp, 'credit', 'Infinity'))),
    'INVALID', 'infinite amount');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', '1e30'), jsonb_build_object('account_id', v_exp, 'credit', '1e30'))),
    'INVALID', 'amount beyond the money range');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 'abc'), jsonb_build_object('account_id', v_exp, 'credit', 'abc'))),
    'INVALID', 'non-numeric amount');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', 'not-a-uuid', 'debit', 1), jsonb_build_object('account_id', v_exp, 'credit', 1))),
    'INVALID', 'malformed account identifier');

  -- original currency: all-or-none, and original x rate must reproduce the base amount
  v_out := app_private.normalise_lines(pt, jsonb_build_array(
    jsonb_build_object('account_id', v_bank, 'debit', 160005.50, 'original_currency', 'USD', 'original_amount', 10, 'exchange_rate', 16000.55),
    jsonb_build_object('account_id', v_exp, 'credit', 160005.50)));
  perform test_helpers.assert(v_out -> 0 ->> 'original_currency' = 'USD', 'fx snapshot is preserved');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 160005, 'original_currency', 'USD', 'original_amount', 10, 'exchange_rate', 16000.55),
                      jsonb_build_object('account_id', v_exp, 'credit', 160005))), 'INVALID', 'fx base amount must equal original x rate');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 10, 'original_currency', 'USD'),
                      jsonb_build_object('account_id', v_exp, 'credit', 10))), 'INVALID', 'fx fields go together');
  -- the stored snapshot has 4 (amount) and 10 (rate) decimals: finer input would be altered silently
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 1000.06, 'original_currency', 'USD', 'original_amount', 1.00005, 'exchange_rate', 1000.01),
                      jsonb_build_object('account_id', v_exp, 'credit', 1000.06))), 'INVALID', 'original amount finer than 4 decimals');
  perform test_helpers.expect_msg(format('select app_private.normalise_lines(%L, %L::jsonb)', pt,
    jsonb_build_array(jsonb_build_object('account_id', v_bank, 'debit', 10, 'original_currency', 'USD', 'original_amount', 1, 'exchange_rate', 10.00000000001),
                      jsonb_build_object('account_id', v_exp, 'credit', 10))), 'INVALID', 'rate finer than 10 decimals');
end
$$;

-- ================================================================ 3. the system posting service
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_bank uuid := test_helpers.acct(pt, 'BANK_OPERATING');
  v_rev uuid := test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE');
  v_src uuid := gen_random_uuid();
  v_lines jsonb;
  v_id uuid;
  v_id2 uuid;
  v_j public.journal_entries%rowtype;
  v_before bigint;
begin
  v_lines := jsonb_build_array(
    jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 1500000),
    jsonb_build_object('account_key', 'OTHER_OPERATING_REVENUE', 'credit', 1500000));

  v_id := app_private.post_system_journal(pt, 'test_event', v_src, 'test.rule', 'v1', date '2026-09-10', 'System journal', v_lines);
  select * into v_j from public.journal_entries where id = v_id;
  perform test_helpers.assert(v_j.status = 'posted' and v_j.entry_type = 'system', 'posted system journal');
  perform test_helpers.assert(v_j.journal_number ~ '^JV' and v_j.posted_at is not null, 'journal number allocated at posting');
  perform test_helpers.assert(v_j.source_type = 'test_event' and v_j.source_id = v_src and v_j.posting_rule_version = 'v1',
    'source linkage and rule version recorded');
  perform test_helpers.assert(v_j.posting_key = 'test_event:' || v_src::text || ':test.rule', 'posting key = source + rule');

  -- retry: same event -> same journal, nothing new
  select count(*) into v_before from public.journal_entries where entity_id = pt;
  v_id2 := app_private.post_system_journal(pt, 'test_event', v_src, 'test.rule', 'v1', date '2026-09-10', 'System journal', v_lines);
  perform test_helpers.assert(v_id2 = v_id, 'retry returns the original journal');
  perform test_helpers.assert((select count(*) from public.journal_entries where entity_id = pt) = v_before, 'retry creates no journal');
  -- a hundred retries still leave exactly one journal and one number
  for i in 1..100 loop
    perform app_private.post_system_journal(pt, 'test_event', v_src, 'test.rule', 'v1', date '2026-09-10', 'System journal', v_lines);
  end loop;
  perform test_helpers.assert((select count(*) from public.journal_entries where entity_id = pt and source_id = v_src) = 1, '100 retries -> one journal');

  -- a retry with different content is refused, never silently accepted
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''test_event'', %L, ''test.rule'', ''v1'', date ''2026-09-10'', ''x'', %L::jsonb)',
    pt, v_src, jsonb_build_array(jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 1),
                                  jsonb_build_object('account_key', 'OTHER_OPERATING_REVENUE', 'credit', 1))),
    'CONFLICT', 'same key, different amounts');
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''test_event'', %L, ''test.rule'', ''v1'', date ''2026-09-11'', ''x'', %L::jsonb)',
    pt, v_src, v_lines), 'CONFLICT', 'same key, different date');
  -- another rule on the same event is a different posting identity
  perform test_helpers.assert(app_private.post_system_journal(pt, 'test_event', v_src, 'test.other_rule', 'v1', date '2026-09-10', 'Other rule', v_lines) <> v_id,
    'a different rule on the same event posts separately');

  -- guard rails on the service itself
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''test_event'', %L, ''r'', ''v1'', date ''2026-09-10'', ''x'', %L::jsonb, ''manual'')', pt, gen_random_uuid(), v_lines),
    'INVALID', 'service does not create manual journals');
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''Bad Type'', %L, ''r'', ''v1'', date ''2026-09-10'', ''x'', %L::jsonb)', pt, gen_random_uuid(), v_lines),
    'INVALID', 'source type shape');
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''test_event'', %L, ''r'', ''v1'', date ''2026-09-10'', ''x'', %L::jsonb)', pt, gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 5), jsonb_build_object('account_key', 'OTHER_OPERATING_REVENUE', 'credit', 4))),
    'INVALID', 'unbalanced system journal is refused before anything is written');
  perform test_helpers.assert((select count(*) from public.journal_entries where entity_id = pt and status = 'draft') = 0,
    'a failed posting leaves no draft behind');
  -- a system journal cannot hit an Entity's period that is not open
  perform app_private.ensure_accounting_period(pt, date '2026-06-15');
  update public.accounting_periods set status = 'closing_review' where entity_id = pt and period_start = date '2026-06-01';
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''test_event'', %L, ''r'', ''v1'', date ''2026-06-15'', ''x'', %L::jsonb)', pt, gen_random_uuid(), v_lines),
    'CONFLICT', 'posting into a period under closing review');
  update public.accounting_periods set status = 'open' where entity_id = pt and period_start = date '2026-06-01';

  -- numbering is enforced by the database itself: even a bare status update leaves the draft state numbered
  v_id2 := test_helpers.simple_journal(pt, date '2026-09-11', v_bank, v_rev, 5, 'system', true);
  perform test_helpers.assert((select journal_number from public.journal_entries where id = v_id2) ~ '^JV', 'the database numbers every posted journal');
  -- dates outside the accepted range are refused before any period can be created
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''test_event'', %L, ''r'', ''v1'', date ''2999-12-31'', ''x'', %L::jsonb)', pt, gen_random_uuid(), v_lines),
    'INVALID', 'far-future date');
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''test_event'', %L, ''r'', ''v1'', date ''1999-12-31'', ''x'', %L::jsonb)', pt, gen_random_uuid(), v_lines),
    'INVALID', 'pre-2000 date');
  perform test_helpers.assert(not exists (select 1 from public.accounting_periods where entity_id = pt and period_start = date '2999-12-01'), 'no period was created for the refused date');

  -- Entity isolation of the service: an account of another Entity is refused
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''test_event'', %L, ''r'', ''v1'', date ''2026-09-10'', ''x'', %L::jsonb)', pt, gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('account_id', test_helpers.acct(pe, 'PERSONAL_BANK'), 'debit', 5), jsonb_build_object('account_key', 'OTHER_OPERATING_REVENUE', 'credit', 5))),
    'INVALID', 'cross-Entity account');

  -- posted journals are immutable, at every level
  perform test_helpers.expect_error(format('update public.journal_entries set description = ''hack'' where id = %L', v_id), '23000', 'posted journal update');
  perform test_helpers.expect_error(format('delete from public.journal_entries where id = %L', v_id), '23000', 'posted journal delete');
  perform test_helpers.expect_error(format('update public.journal_lines set debit = 1 where journal_id = %L and debit > 0', v_id), '23000', 'posted line update');
  perform test_helpers.expect_error(format('delete from public.journal_lines where journal_id = %L', v_id), '23000', 'posted line delete');
  perform test_helpers.expect_error(format('insert into public.journal_lines (entity_id, journal_id, line_no, ledger_account_id, debit) values (%L, %L, 9, %L, 1)', pt, v_id, v_bank),
    '23000', 'line added to a posted journal');
  perform test_helpers.expect_error(format('update public.journal_entries set status = ''draft'' where id = %L', v_id), '23000', 'un-posting');
end
$$;

-- ================================================================ 4. property: random postings always balance
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  v_keys text[] := array['BANK_OPERATING', 'CASH', 'OFFICE_GENERAL_EXPENSE', 'MARKETING_EXPENSE', 'SOFTWARE_SUBSCRIPTION_EXPENSE',
                         'OTHER_OPERATING_REVENUE', 'DIGITAL_PRODUCT_REVENUE', 'ACCOUNTS_PAYABLE', 'OTHER_PAYABLE'];
  v_n integer;
  v_k integer;
  v_lines jsonb;
  v_total numeric;
  v_part numeric;
  v_debit_side boolean;
  v_id uuid;
  v_numbers integer;
  v_distinct integer;
  v_max integer;
  v_d numeric;
  v_c numeric;
begin
  perform setseed(0.777);
  for v_n in 1..250 loop
    v_total := (1 + floor(random() * 5000000))::numeric / 100;
    v_k := 1 + floor(random() * 4)::integer;             -- 1..4 lines on the split side
    v_debit_side := random() < 0.5;
    v_lines := '[]'::jsonb;
    -- split side: allocation keeps the parts exact; the other side is the single counter-line
    declare
      v_alloc numeric[] := app_private.allocate_amount(v_total, array_fill(1::numeric, array[v_k]), 2);
      v_i integer;
    begin
      for v_i in 1..v_k loop
        continue when v_alloc[v_i] = 0;
        v_lines := v_lines || jsonb_build_object('account_key', v_keys[1 + floor(random() * 9)::integer],
          case when v_debit_side then 'debit' else 'credit' end, v_alloc[v_i]);
      end loop;
    end;
    v_lines := v_lines || jsonb_build_object('account_key', v_keys[1 + floor(random() * 9)::integer],
      case when v_debit_side then 'credit' else 'debit' end, v_total);
    v_id := app_private.post_system_journal(pt, 'prop_event', gen_random_uuid(), 'prop.rule', 'v1',
      date '2026-09-01' + (floor(random() * 28))::integer, 'Random scenario ' || v_n, v_lines);
  end loop;

  select sum(l.debit), sum(l.credit) into v_d, v_c
  from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
  where j.entity_id = pt and j.status = 'posted';
  perform test_helpers.assert(v_d = v_c and v_d > 0, 'ledger of posted lines balances after 250 random scenarios');
  perform test_helpers.assert(not exists (
      select 1 from public.journal_entries j join public.journal_lines l on l.journal_id = j.id
      where j.entity_id = pt and j.status = 'posted' group by j.id having sum(l.debit) <> sum(l.credit)),
    'every posted journal balances on its own');
  perform test_helpers.assert(not exists (select 1 from public.journal_lines where debit = 0 and credit = 0), 'no zero-value lines');

  -- gapless, unique journal numbers
  select count(*), count(distinct journal_number) into v_numbers, v_distinct
  from public.journal_entries where entity_id = pt and status = 'posted';
  select max(sequence_value) into v_max from public.issued_document_numbers where entity_id = pt and scope = 'journal';
  perform test_helpers.assert(v_numbers = v_distinct and v_numbers = v_max, 'journal numbers are unique and gapless');
end
$$;

-- ================================================================ 5. public journal RPCs (as browser roles)
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  v_staff uuid := 'b0000000-0000-0000-0000-000000000002';
  v_viewer uuid := 'b0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'b0000000-0000-0000-0000-000000000007';
  v_lines jsonb := jsonb_build_array(
    jsonb_build_object('account_key', 'OFFICE_GENERAL_EXPENSE', 'debit', 250000),
    jsonb_build_object('account_key', 'MARKETING_EXPENSE', 'credit', 250000));
  v_prot jsonb := jsonb_build_array(
    jsonb_build_object('account_key', 'ACCOUNTS_RECEIVABLE', 'debit', 90000),
    jsonb_build_object('account_key', 'DIGITAL_PRODUCT_REVENUE', 'credit', 90000));
  v_d uuid;
  v_d2 uuid;
  v_p uuid;
  v_r uuid;
  v_r2 uuid;
  v_ver integer;
  v_pe_draft uuid;
  v_status text;
  v_acct_tmp uuid;
begin
  -- ---------------- who may do what
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-viewer-1'', ''manual'', date ''2026-09-12'', ''x'', %L::jsonb)', pt, v_lines),
    'FORBIDDEN', 'viewer cannot create journals');
  perform test_helpers.assert((select count(*) from public.trial_balance(pt)) > 0, 'viewer can read the trial balance');
  perform test_helpers.logout();

  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-staff-01'', ''manual'', date ''2026-09-12'', ''x'', %L::jsonb)', pt, v_lines),
    'FORBIDDEN', 'staff cannot create journals');
  perform test_helpers.expect_msg(format('select public.trial_balance(%L)', pt), 'FORBIDDEN', 'staff cannot read the trial balance');
  perform test_helpers.logout();

  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-nobody-1'', ''manual'', date ''2026-09-12'', ''x'', %L::jsonb)', pt, v_lines),
    'FORBIDDEN', 'a user without membership cannot create journals');
  perform test_helpers.logout();

  perform test_helpers.as_anon();
  perform test_helpers.expect_error(format('select public.create_journal_draft(%L, ''key-anon-001'', ''manual'', date ''2026-09-12'', ''x'', %L::jsonb)', pt, v_lines), '42501', 'anon create');
  perform test_helpers.expect_error(format('select public.trial_balance(%L)', pt), '42501', 'anon trial balance');
  perform test_helpers.expect_error('select public.post_journal(gen_random_uuid(), ''key-anon-002'')', '42501', 'anon post');
  perform test_helpers.expect_error('select public.close_period(gen_random_uuid())', '42501', 'anon close');
  perform test_helpers.expect_error('select public.post_opening_balances(gen_random_uuid(), ''key-anon-003'', current_date, ''[]''::jsonb)', '42501', 'anon opening');
  perform test_helpers.logout();

  -- ---------------- accountant: draft -> post
  perform test_helpers.login(v_acct);
  v_d := public.create_journal_draft(pt, 'key-draft-001', 'manual', date '2026-09-12', 'Office supplies correction', v_lines);
  perform test_helpers.assert((select status from public.journal_entries where id = v_d) = 'draft', 'draft created');
  perform test_helpers.assert(public.create_journal_draft(pt, 'key-draft-001', 'manual', date '2026-09-12', 'Office supplies correction', v_lines) = v_d,
    'same key + same request replays the draft');
  perform test_helpers.assert((select count(*) from public.journal_entries where entity_id = pt and description = 'Office supplies correction') = 1,
    'replay creates nothing new');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-001'', ''manual'', date ''2026-09-12'', ''Different text'', %L::jsonb)', pt, v_lines),
    'INVALID', 'same key with a different request is refused');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''short'', ''manual'', date ''2026-09-12'', ''x'', %L::jsonb)', pt, v_lines),
    'INVALID', 'idempotency key length');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-002'', ''system'', date ''2026-09-12'', ''x'', %L::jsonb)', pt, v_lines),
    'INVALID', 'a user cannot create system journals');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-003'', ''adjusting'', date ''2026-09-12'', ''short'', %L::jsonb)', pt, v_lines),
    'INVALID', 'adjusting journals need a real explanation');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-004'', ''manual'', date ''2026-09-12'', ''Protected'', %L::jsonb)', pt, v_prot),
    'INVALID', 'protected account without override');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-005'', ''manual'', date ''2026-09-12'', ''Protected'', %L::jsonb, ''Correcting subledger drift'')', pt, v_prot),
    'FORBIDDEN', 'accountant lacks protected_manage');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-006'', ''manual'', date ''2026-09-12'', ''x'', %L::jsonb)', pe, v_lines),
    'FORBIDDEN', 'PT accountant cannot create a Personal journal');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-008'', null, date ''2026-09-12'', ''x'', %L::jsonb)', pt, v_lines),
    'INVALID', 'NULL entry type');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-009'', ''manual'', date ''2999-12-31'', ''x'', %L::jsonb)', pt, v_lines),
    'INVALID', 'far-future date on a manual journal');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-010'', ''manual'', date ''1999-01-01'', ''x'', %L::jsonb)', pt, v_lines),
    'INVALID', 'pre-2000 date on a manual journal');

  select version into v_ver from public.journal_entries where id = v_d;
  perform test_helpers.expect_msg(format('select public.post_journal(%L, ''key-post-001'', %s)', v_d, v_ver + 5), 'CONFLICT', 'stale draft version');
  perform test_helpers.assert(public.post_journal(v_d, 'key-post-002', v_ver) = v_d, 'post the draft');
  perform test_helpers.assert((select status from public.journal_entries where id = v_d) = 'posted'
    and (select journal_number from public.journal_entries where id = v_d) ~ '^JV', 'posted with a number');
  perform test_helpers.assert(public.post_journal(v_d, 'key-post-002', v_ver) = v_d, 'retry of the same post is a no-op replay');
  perform test_helpers.expect_msg(format('select public.post_journal(%L, ''key-post-003'')', v_d), 'CONFLICT', 'a second post with a new key is refused');
  perform test_helpers.expect_msg(format('select public.discard_journal_draft(%L)', v_d), 'CONFLICT', 'a posted journal cannot be discarded');

  -- system journals are not posted by hand
  perform test_helpers.expect_msg(format('select public.post_journal(%L, ''key-post-004'')',
    (select id from public.journal_entries where entity_id = pt and entry_type = 'system' limit 1)), 'FORBIDDEN', 'system journal via post_journal');

  -- discard a draft; retrying the same key afterwards says so instead of returning a dead identifier
  v_d2 := public.create_journal_draft(pt, 'key-draft-007', 'manual', date '2026-09-13', 'Will be discarded', v_lines);
  perform public.discard_journal_draft(v_d2);
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where id = v_d2), 'draft discarded');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-draft-007'', ''manual'', date ''2026-09-13'', ''Will be discarded'', %L::jsonb)', pt, v_lines),
    'CONFLICT', 'replay of a discarded draft');
  perform test_helpers.logout();

  -- an account deactivated after the draft was written: posting is refused with a readable CONFLICT
  insert into public.ledger_accounts (entity_id, code, name, account_class, normal_balance, allows_manual_posting)
  values (pt, '6998', 'Temporary test expense', 'expense', 'debit', true) returning id into v_acct_tmp;
  perform test_helpers.login(v_acct);
  v_d2 := public.create_journal_draft(pt, 'key-tmp-0001', 'manual', date '2026-09-13', 'Uses a soon inactive account',
    jsonb_build_array(jsonb_build_object('account_id', upper(v_acct_tmp::text), 'debit', 10),
                      jsonb_build_object('account_key', 'MARKETING_EXPENSE', 'credit', 10)));
  perform test_helpers.logout();
  update public.ledger_accounts set status = 'inactive' where id = v_acct_tmp;
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.post_journal(%L, ''key-tmp-0002'')', v_d2), 'CONFLICT', 'post with an account that became inactive');
  perform public.discard_journal_draft(v_d2);
  perform test_helpers.logout();

  -- another Entity's draft is invisible and untouchable to a PT accountant
  select test_helpers.draft_journal(pe, date '2026-09-14', 'manual') into v_pe_draft;
  perform test_helpers.add_line(v_pe_draft, test_helpers.acct(pe, 'PERSONAL_BANK'), 10, 0);
  perform test_helpers.add_line(v_pe_draft, test_helpers.acct(pe, 'SALARY_INCOME'), 0, 10);
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.post_journal(%L, ''key-post-005'')', v_pe_draft), 'FORBIDDEN', 'cross-Entity post');
  perform test_helpers.expect_msg(format('select public.discard_journal_draft(%L)', v_pe_draft), 'FORBIDDEN', 'cross-Entity discard');
  perform test_helpers.expect_msg(format('select public.reverse_journal(%L, ''key-rev-000'', date ''2026-09-20'', ''testing'')', v_pe_draft), 'FORBIDDEN', 'cross-Entity reverse');
  perform test_helpers.expect_msg(format('select public.trial_balance(%L)', pe), 'FORBIDDEN', 'cross-Entity trial balance');
  perform test_helpers.logout();

  -- ---------------- protected accounts: override needs protected_manage, at creation and at posting
  perform test_helpers.login(v_owner);
  v_d := public.create_journal_draft(pt, 'key-prot-001', 'adjusting', date '2026-09-15', 'Correcting subledger drift on receivables', v_prot,
                                     'Sub-ledger reconciliation adjustment approved by owner');
  perform test_helpers.logout();
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.post_journal(%L, ''key-prot-002'')', v_d), 'FORBIDDEN', 'accountant cannot post an overridden journal');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.post_journal(v_d, 'key-prot-003') = v_d, 'owner posts the overridden journal');
  perform test_helpers.logout();
  -- undoing an override journal is as sensitive as posting it
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.reverse_journal(%L, ''key-prot-004'', date ''2026-09-20'', ''Trying to undo an override'')', v_d),
    'FORBIDDEN', 'accountant cannot reverse an override journal');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.reverse_journal(v_d, 'key-prot-005', date '2026-09-20', 'Owner undoes the override') is not null, 'owner can reverse it');
  perform test_helpers.logout();

  -- ---------------- reversal
  perform test_helpers.login(v_acct);
  v_d := public.create_journal_draft(pt, 'key-rev-src-1', 'manual', date '2026-09-16', 'To be reversed', v_lines);
  perform public.post_journal(v_d, 'key-rev-src-2');
  perform test_helpers.expect_msg(format('select public.reverse_journal(%L, ''key-rev-001'', date ''2026-09-15'', ''dated before original'')', v_d),
    'INVALID', 'reversal before the original date');
  perform test_helpers.expect_msg(format('select public.reverse_journal(%L, ''key-rev-002'', date ''2026-09-17'', ''x'')', v_d),
    'INVALID', 'reversal needs a reason');
  v_r := public.reverse_journal(v_d, 'key-rev-003', date '2026-09-17', 'Posted in error');
  perform test_helpers.assert(public.reverse_journal(v_d, 'key-rev-003', date '2026-09-17', 'Posted in error') = v_r, 'reversal retry replays');
  perform test_helpers.expect_msg(format('select public.reverse_journal(%L, ''key-rev-004'', date ''2026-09-18'', ''Second attempt'')', v_d),
    'CONFLICT', 'a journal is reversed at most once');
  perform test_helpers.logout();
  perform test_helpers.assert((select entry_type from public.journal_entries where id = v_r) = 'reversal'
    and (select reverses_journal_id from public.journal_entries where id = v_r) = v_d
    and (select status from public.journal_entries where id = v_r) = 'posted', 'reversal is a posted, linked journal');
  perform test_helpers.assert(
    (select sum(debit) - sum(credit) from public.journal_lines where journal_id in (v_d, v_r)) = 0
    and not exists (select ledger_account_id from public.journal_lines where journal_id in (v_d, v_r)
                    group by ledger_account_id having sum(debit) <> sum(credit)),
    'original + reversal net to zero on every account');
  perform test_helpers.assert(exists (select 1 from public.journal_entries where id = v_d and status = 'posted'), 'the original is never deleted or changed');

  -- system journals are corrected through their source module, not by hand
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.reverse_journal(%L, ''key-rev-005'', date ''2026-09-20'', ''Trying to undo a system journal'')',
    (select id from public.journal_entries where entity_id = pt and entry_type = 'system' limit 1)), 'FORBIDDEN', 'system journal via reverse_journal');

  -- ---------------- trial balance
  perform test_helpers.assert((select sum(debit::numeric) - sum(credit::numeric) from public.trial_balance(pt)) = 0, 'trial balance balances');
  perform test_helpers.assert(
    (select sum(debit::numeric) from public.trial_balance(pt, date '2026-09-05')) < (select sum(debit::numeric) from public.trial_balance(pt)),
    'trial balance can be cut at a date');
  perform test_helpers.assert((select sum(debit::numeric) - sum(credit::numeric) from public.trial_balance(pt, date '2026-09-10')) = 0, 'trial balance balances at any cut date');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. period controls
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  v_viewer uuid := 'b0000000-0000-0000-0000-000000000004';
  v_lines jsonb := jsonb_build_array(
    jsonb_build_object('account_key', 'OFFICE_GENERAL_EXPENSE', 'debit', 1000),
    jsonb_build_object('account_key', 'MARKETING_EXPENSE', 'credit', 1000));
  v_d uuid;
  v_tmp uuid;
  v_period uuid;
  v_n integer;
begin
  perform test_helpers.login(v_acct);
  v_d := public.create_journal_draft(pt, 'key-per-001', 'manual', date '2026-10-05', 'October journal', v_lines);
  perform test_helpers.logout();
  select id into v_period from public.accounting_periods where entity_id = pt and period_start = date '2026-10-01';

  -- read-only viewer sees the checks but cannot act
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert((select count(*) from public.period_close_checks(v_period) where code = 'draft_journals' and severity = 'blocker') = 1,
    'viewer sees the draft-journal blocker');
  perform test_helpers.expect_msg(format('select public.begin_period_close(%L)', v_period), 'FORBIDDEN', 'viewer cannot start closing');
  perform test_helpers.logout();

  perform test_helpers.login(v_acct);
  -- a phantom period id reads as forbidden, exactly like a foreign one
  perform test_helpers.expect_msg('select public.begin_period_close(gen_random_uuid())', 'FORBIDDEN', 'unknown period');
  perform test_helpers.expect_msg(format('select public.close_period(%L)', v_period), 'CONFLICT', 'close requires closing review first');
  perform test_helpers.assert(public.begin_period_close(v_period) = 'closing_review', 'period enters closing review');
  perform test_helpers.expect_msg(format('select public.begin_period_close(%L)', v_period), 'CONFLICT', 'cannot enter review twice');
  -- postings are already blocked while under review
  perform test_helpers.expect_msg(format('select public.post_journal(%L, ''key-per-002'')', v_d), 'CONFLICT', 'cannot post during closing review');
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-per-003'', ''manual'', date ''2026-10-06'', ''x'', %L::jsonb)', pt, v_lines),
    'CONFLICT', 'cannot create drafts during closing review');
  perform test_helpers.expect_msg(format('select public.close_period(%L)', v_period), 'CONFLICT', 'a draft journal blocks the close');
  perform public.discard_journal_draft(v_d);
  perform test_helpers.assert(public.cancel_period_close(v_period) = 'open', 'review can be cancelled');
  perform test_helpers.assert(public.create_journal_draft(pt, 'key-per-004', 'manual', date '2026-10-07', 'October journal 2', v_lines) is not null, 'posting resumes after cancel');
  perform public.post_journal((select id from public.journal_entries where entity_id = pt and description = 'October journal 2'), 'key-per-005');
  perform test_helpers.assert(public.begin_period_close(v_period) = 'closing_review', 'review again');
  perform test_helpers.assert(public.close_period(v_period) = 'closed', 'period closed');
  perform test_helpers.assert((select closed_by from public.accounting_periods where id = v_period) = v_acct, 'closed_by stamped');
  perform test_helpers.logout();

  -- closed periods block every path
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-per-006'', ''manual'', date ''2026-10-08'', ''x'', %L::jsonb)', pt, v_lines),
    'CONFLICT', 'no new draft in a closed period');
  perform test_helpers.expect_msg(format('select public.reverse_journal(%L, ''key-per-007'', date ''2026-10-20'', ''late reversal'')',
    (select id from public.journal_entries where entity_id = pt and description = 'October journal 2')), 'CONFLICT', 'no reversal into a closed period');
  perform test_helpers.expect_msg(format('select public.cancel_period_close(%L)', v_period), 'CONFLICT', 'a closed period cannot leave via cancel');
  -- the accountant cannot reopen
  perform test_helpers.expect_msg(format('select public.reopen_period(%L, ''Correction of a misposted invoice'')', v_period), 'FORBIDDEN', 'accountant cannot reopen');
  perform test_helpers.logout();
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''late_event'', %L, ''r'', ''v1'', date ''2026-10-09'', ''late'', %L::jsonb)', pt, gen_random_uuid(), v_lines),
    'CONFLICT', 'system posting into a closed period is blocked');
  -- closing a period seals earlier months too: a month without a period row cannot be created behind it
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.create_journal_draft(%L, ''key-per-010'', ''manual'', date ''2025-03-10'', ''Backdated into the past'', %L::jsonb)', pt, v_lines),
    'CONFLICT', 'no backdating into an uncreated month behind a closed period');
  perform test_helpers.logout();
  perform test_helpers.expect_msg(format('select app_private.post_system_journal(%L, ''late_event'', %L, ''r'', ''v1'', date ''2025-03-10'', ''late'', %L::jsonb)', pt, gen_random_uuid(), v_lines),
    'CONFLICT', 'system posting cannot backdate behind a closed period either');
  perform test_helpers.assert(not exists (select 1 from public.accounting_periods where entity_id = pt and period_start = date '2025-03-01'), 'no period was created behind the closed one');
  -- ... and the trigger-level gate still holds if a path ever bypasses the service
  v_tmp := test_helpers.draft_journal(pt, date '2026-10-09', 'system');
  perform test_helpers.add_line(v_tmp, test_helpers.acct(pt, 'BANK_OPERATING'), 1, 0);
  perform test_helpers.add_line(v_tmp, test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE'), 0, 1);
  perform test_helpers.expect_error(format('update public.journal_entries set status = ''posted'' where id = %L', v_tmp),
    '23514', 'the database trigger blocks posting into a closed period');
  delete from public.journal_entries where id = v_tmp;
  perform test_helpers.expect_error(format('update public.accounting_periods set status = ''open'' where id = %L', v_period), '23000', 'a closed period cannot be flipped open directly');

  -- reopen: owner, step-up, reason
  perform test_helpers.login(v_owner, 'aal2', interval '45 minutes');
  perform test_helpers.expect_msg(format('select public.reopen_period(%L, ''Correction of a misposted invoice'')', v_period), 'STEP_UP_REQUIRED', 'reopen needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.reopen_period(%L, ''short'')', v_period), 'INVALID', 'reopen needs a real reason');
  perform test_helpers.assert(public.reopen_period(v_period, 'Correction of a misposted invoice') = 'reopened', 'owner reopens with step-up and a reason');
  perform test_helpers.expect_msg(format('select public.reopen_period(%L, ''Correction of a misposted invoice'')', v_period), 'CONFLICT', 'cannot reopen twice');
  perform test_helpers.logout();
  perform test_helpers.assert((select reopen_reason from public.accounting_periods where id = v_period) = 'Correction of a misposted invoice'
    and (select reopened_by from public.accounting_periods where id = v_period) = v_owner, 'reopen is recorded');
  perform test_helpers.assert(exists (select 1 from public.audit_events
    where target_table = 'accounting_periods' and target_id = v_period and reason = 'Correction of a misposted invoice'
      and after_state ->> 'status' = 'reopened' and before_state ->> 'status' = 'closed'), 'reopen is audited with its reason');

  -- corrections are allowed again, then the period is re-closed
  perform test_helpers.login(v_acct);
  v_d := public.create_journal_draft(pt, 'key-per-008', 'adjusting', date '2026-10-10', 'Correction after reopening the period', v_lines);
  perform public.post_journal(v_d, 'key-per-009');
  perform test_helpers.assert(public.begin_period_close(v_period) = 'closing_review', 'reopened -> closing review');
  perform test_helpers.assert(public.close_period(v_period) = 'closed', 're-closed');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.audit_events where target_table = 'accounting_periods' and target_id = v_period and action = 'accounting_periods.update') >= 4,
    'every period transition is audited');

  -- the boundary of an old period cannot be moved once it holds journals
  perform test_helpers.expect_error(format('update public.accounting_periods set period_end = %L where id = %L', date '2026-10-15', v_period), '23000', 'period boundary frozen');
end
$$;

-- ================================================================ 7. opening-balance workflow
do $$
declare
  op uuid := test_helpers.entity('p3_open');
  pe uuid := test_helpers.entity('demo_personal');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_acct uuid := 'b0000000-0000-0000-0000-000000000006';
  v_b1 uuid;
  v_b2 uuid;
  v_b3 uuid;
  v_period uuid;
  v_jn integer;
  v_resid numeric;
begin
  -- permission
  perform test_helpers.login(v_acct);
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-000'', date ''2026-09-01'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 100))), 'FORBIDDEN', 'accountant lacks system.import');
  perform test_helpers.expect_msg(format('select public.complete_opening_balances(%L)', op), 'FORBIDDEN', 'accountant cannot complete the migration');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  -- validation
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-001'', date ''2026-09-01'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('account_key', 'DIGITAL_PRODUCT_REVENUE', 'credit', 500))), 'INVALID', 'opening balances cannot use revenue accounts');
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-002'', date ''2026-09-01'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('account_key', 'OFFICE_GENERAL_EXPENSE', 'debit', 500))), 'INVALID', 'opening balances cannot use expense accounts');
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-003'', date ''2026-09-01'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('account_key', 'OPENING_BALANCE_CLEARING', 'debit', 500), jsonb_build_object('account_key', 'BANK_OPERATING', 'credit', 500))),
    'INVALID', 'the clearing account is maintained by the workflow');
  -- no spelling of the clearing account's identifier gets past the guard (case, braces, no hyphens)
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-003b'', date ''2026-09-01'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 500),
                      jsonb_build_object('account_id', upper(test_helpers.acct(op, 'OPENING_BALANCE_CLEARING')::text), 'credit', 500))),
    'INVALID', 'clearing account by upper-case identifier');
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-003c'', date ''2026-09-01'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 700),
                      jsonb_build_object('account_id', '{' || test_helpers.acct(op, 'OPENING_BALANCE_CLEARING')::text || '}', 'credit', 500))),
    'INVALID', 'clearing account in braces while the lines do not balance');
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-003d'', date ''2999-01-01'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 100))), 'INVALID', 'cutover date out of range');
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-004'', date ''2026-09-01'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 'abc'))), 'INVALID', 'non-numeric amount');
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-005'', date ''2026-09-01'', %L::jsonb)', op, '[]'), 'INVALID', 'no lines');
  perform test_helpers.expect_msg(format('select public.complete_opening_balances(%L)', op), 'CONFLICT', 'nothing to complete yet');
  perform test_helpers.assert((select count(*) from public.opening_balance_batches where entity_id = op) = 0, 'failed attempts leave no batch');
  perform test_helpers.assert((select count(*) from public.journal_entries where entity_id = op) = 0, 'failed attempts leave no journal');

  -- first batch: assets and a liability, unbalanced on purpose -> the difference sits in clearing
  v_b1 := public.post_opening_balances(op, 'key-open-010', date '2026-09-01', jsonb_build_array(
    jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 1000000),
    jsonb_build_object('account_key', 'ACCOUNTS_PAYABLE', 'credit', 200000)), 'Opening balances, first load');
  perform test_helpers.assert(public.post_opening_balances(op, 'key-open-010', date '2026-09-01', jsonb_build_array(
    jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 1000000),
    jsonb_build_object('account_key', 'ACCOUNTS_PAYABLE', 'credit', 200000)), 'Opening balances, first load') = v_b1, 'opening post replays on the same key');
  select count(*) into v_jn from public.journal_entries where entity_id = op and source_type = 'opening_balance';
  perform test_helpers.assert(v_jn = 1, 'exactly one opening journal');
  perform test_helpers.assert((select entry_type from public.journal_entries where source_id = v_b1) = 'opening'
    and (select status from public.journal_entries where source_id = v_b1) = 'posted'
    and (select entry_date from public.journal_entries where source_id = v_b1) = date '2026-09-01', 'opening journal is posted on the cutover date');
  perform test_helpers.assert((select count(*) from public.journal_lines l join public.journal_entries j on j.id = l.journal_id where j.source_id = v_b1) = 3,
    'clearing line was added');
  perform test_helpers.assert((select debit::numeric - credit::numeric from public.trial_balance(op) where code = '8900') = -800000, 'clearing holds the unexplained difference');
  perform test_helpers.assert((select status from public.opening_balance_batches where id = v_b1) = 'posted', 'batch waits for completion');

  -- completion is refused while the clearing account is not zero and undocumented
  perform test_helpers.expect_msg(format('select public.complete_opening_balances(%L)', op), 'INVALID', 'clearing not zero, no note');
  perform test_helpers.expect_msg(format('select public.complete_opening_balances(%L, ''short'')', op), 'INVALID', 'clearing not zero, note too short');

  -- the cutover period cannot be closed until the migration is signed off
  select id into v_period from public.accounting_periods where entity_id = op and period_start = date '2026-09-01';
  perform public.begin_period_close(v_period);
  perform test_helpers.expect_msg(format('select public.close_period(%L)', v_period), 'CONFLICT', 'close blocked by an incomplete migration');
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_period) where code = 'opening_not_completed' and severity = 'blocker'), 'blocker is reported');
  perform test_helpers.assert(public.cancel_period_close(v_period) = 'open', 'back to open');

  -- second batch supplies the equity side; clearing returns to zero
  v_b2 := public.post_opening_balances(op, 'key-open-011', date '2026-09-01', jsonb_build_array(
    jsonb_build_object('account_key', 'OWNER_CAPITAL', 'credit', 800000)));
  perform test_helpers.assert((select debit::numeric - credit::numeric from public.trial_balance(op) where code = '8900') = 0, 'clearing reconciles to zero');
  perform test_helpers.assert(public.complete_opening_balances(op)::numeric = 0, 'migration completed with zero clearing');
  perform test_helpers.assert((select count(*) from public.opening_balance_batches where entity_id = op and status = 'completed') = 2
    and (select clearing_residual from public.opening_balance_batches where id = v_b2) = 0, 'all batches completed');
  perform test_helpers.expect_msg(format('select public.complete_opening_balances(%L)', op), 'CONFLICT', 'cannot complete twice');
  perform test_helpers.expect_msg(format('select public.post_opening_balances(%L, ''key-open-012'', date ''2026-09-01'', %L::jsonb)', op,
    jsonb_build_array(jsonb_build_object('account_key', 'CASH', 'debit', 5), jsonb_build_object('account_key', 'OWNER_CAPITAL', 'credit', 5))),
    'CONFLICT', 'no opening batch after completion');
  perform test_helpers.assert(public.post_opening_balances(op, 'key-open-010', date '2026-09-01', jsonb_build_array(
    jsonb_build_object('account_key', 'BANK_OPERATING', 'debit', 1000000),
    jsonb_build_object('account_key', 'ACCOUNTS_PAYABLE', 'credit', 200000)), 'Opening balances, first load') = v_b1, 'a retry after completion still replays');

  -- opening balances are balance-sheet only: revenue/expense totals are untouched
  perform test_helpers.assert(not exists (
    select 1 from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
    join public.ledger_accounts a on a.id = l.ledger_account_id
    where j.entity_id = op and a.account_class in ('revenue', 'contra_revenue', 'expense', 'other_income', 'other_expense')),
    'no opening balance ever lands in income or expense');
  perform test_helpers.assert((select sum(debit::numeric) - sum(credit::numeric) from public.trial_balance(op)) = 0, 'opening trial balance balances');

  -- with the migration signed off the cutover period can be closed
  perform test_helpers.assert(public.begin_period_close(v_period) = 'closing_review', 'review');
  perform test_helpers.assert(public.close_period(v_period) = 'closed', 'cutover period closes');

  -- documented residual: a note lets the migration complete with a non-zero clearing balance
  v_b3 := public.post_opening_balances(pe, 'key-open-020', date '2026-09-02', jsonb_build_array(
    jsonb_build_object('account_key', 'PERSONAL_BANK', 'debit', 5000)));
  perform test_helpers.expect_msg(format('select public.complete_opening_balances(%L)', pe), 'INVALID', 'personal: residual without note');
  v_resid := public.complete_opening_balances(pe, 'Migration adjustment: prior-year opening balance to be documented')::numeric;
  perform test_helpers.assert(v_resid = -5000, 'residual returned');
  perform test_helpers.assert((select clearing_residual from public.opening_balance_batches where id = v_b3) = -5000
    and (select completion_note from public.opening_balance_batches where id = v_b3) like 'Migration adjustment%', 'residual and note are stored');
  perform test_helpers.logout();

  -- opening batches are visible to accounting.view holders of that Entity only
  perform test_helpers.login(v_acct);
  perform test_helpers.assert((select count(*) from public.opening_balance_batches) = 2, 'accountant sees only the batches of their own Entities');
  perform test_helpers.expect_error(format('update public.opening_balance_batches set status = ''posted'' where id = %L', v_b1), '42501', 'no direct write to batches');
  perform test_helpers.logout();
end
$$;

rollback;
