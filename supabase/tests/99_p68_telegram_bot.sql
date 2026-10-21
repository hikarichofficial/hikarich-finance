-- Decision 422: the Telegram bot. A pairing code made by a signed-in owner (MFA + fresh step-up) pairs one Telegram
-- account; the bot's server then creates and confirms expenses, undoes its own entries and reads summaries ONLY through
-- service_role functions that run the existing rules unchanged. One transaction, rolled back. Synthetic data.
begin;
set local client_min_messages = warning;

create table test_helpers.p68 (k text primary key, v text not null);
grant all on test_helpers.p68 to public;
create function test_helpers.put68(p_k text, p_v text) returns text
language sql as $f$ insert into test_helpers.p68 values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g68(p_k text) returns text
language sql stable as $f$ select v from test_helpers.p68 where k = p_k $f$;
grant execute on function test_helpers.put68(text, text), test_helpers.g68(text) to public;

do $$
declare
  pt uuid;
  pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p68_pt', 'PT P68 (synthetic)') returning id into pt;
  perform app_private.provision_default_coa(pt);
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p68_pe', 'P68 Pribadi (synthetic)') returning id into pe;
  perform app_private.provision_default_coa(pe);
  perform test_helpers.mk_user('e6800000-0000-0000-0000-000000000001', 'p68_owner');
  perform test_helpers.mk_user('e6800000-0000-0000-0000-000000000002', 'p68_staff');
  perform test_helpers.mk_user('e6800000-0000-0000-0000-000000000003', 'p68_viewer');
  perform test_helpers.mk_user('e6800000-0000-0000-0000-000000000004', 'p68_other');
  perform test_helpers.mk_member(pt, 'e6800000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(pe, 'e6800000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(pt, 'e6800000-0000-0000-0000-000000000002', 'finance_staff');
  perform test_helpers.mk_member(pt, 'e6800000-0000-0000-0000-000000000003', 'viewer_auditor');
  perform test_helpers.mk_member(pt, 'e6800000-0000-0000-0000-000000000004', 'owner');
end
$$;

-- ================================================================ 1. master data used by the bot
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  pe uuid := test_helpers.entity('p68_pe');
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
  v_cat uuid;
begin
  insert into public.categories (entity_id, name, kind) values (pt, 'Makan & Minum', 'expense') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, debit_ledger_account_id, effective_from)
  values (pt, v_cat, 'purchases', test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE'), date '2000-01-01');
  perform test_helpers.put68('cat_food', v_cat::text);
  insert into public.categories (entity_id, name, kind) values (pt, 'Transportasi', 'expense') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, debit_ledger_account_id, effective_from)
  values (pt, v_cat, 'purchases', test_helpers.acct(pt, 'OFFICE_GENERAL_EXPENSE'), date '2000-01-01');
  perform test_helpers.put68('cat_move', v_cat::text);
  insert into public.categories (entity_id, name, kind) values (pe, 'Makan Pribadi', 'expense') returning id into v_cat;
  perform test_helpers.put68('cat_pe', v_cat::text);
  insert into public.categories (entity_id, name, kind, is_active) values (pt, 'Lama', 'expense', false);

  perform test_helpers.login(v_owner);
  perform test_helpers.put68('cash', public.create_financial_account(pt, 'key-p68-fa-01', 'cash', 'Kas Kecil', 'IDR', test_helpers.acct(pt, 'CASH'))::text);
  perform test_helpers.put68('usd', public.create_financial_account(pt, 'key-p68-fa-02', 'bank', 'USD Bank', 'USD')::text);
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. the pairing code
do $$
declare
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
  v_staff uuid := 'e6800000-0000-0000-0000-000000000002';
  v_viewer uuid := 'e6800000-0000-0000-0000-000000000003';
  r jsonb;
begin
  -- a fresh step-up is needed, and MFA
  perform test_helpers.login(v_owner, 'aal2', interval '1 hour');
  perform test_helpers.expect_msg('select public.create_telegram_link_code()', 'STEP_UP_REQUIRED', '2.1 a stale sign-in cannot make a pairing code');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner, 'aal1');
  perform test_helpers.expect_msg('select public.create_telegram_link_code()', 'FORBIDDEN', '2.2 a session without MFA cannot make a pairing code');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg('select public.create_telegram_link_code()', 'FORBIDDEN', '2.3 a viewer cannot make a pairing code (bills.create is needed)');
  perform test_helpers.logout();
  perform test_helpers.as_anon();
  perform test_helpers.expect_error('select public.create_telegram_link_code()', '42501', '2.4 anon cannot call it at all');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  r := public.create_telegram_link_code();
  perform test_helpers.assert(r ->> 'code' ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$', '2.5 the code has 8 characters without look-alikes');
  perform test_helpers.assert((r ->> 'expires_at')::timestamptz > now() + interval '9 minutes'
    and (r ->> 'expires_at')::timestamptz <= now() + interval '10 minutes', '2.6 the code lives 10 minutes');
  perform test_helpers.put68('code1', r ->> 'code');
  perform test_helpers.logout();
  -- only a hash is stored
  perform test_helpers.assert(not exists (select 1 from public.telegram_link_codes where code_hash = test_helpers.g68('code1')), '2.7 the code itself is not stored');
  perform test_helpers.assert(exists (select 1 from public.telegram_link_codes
    where code_hash = encode(extensions.digest(test_helpers.g68('code1'), 'sha256'), 'hex')), '2.8 its SHA-256 is stored');
  -- a new code replaces the unused one
  perform test_helpers.login(v_owner);
  r := public.create_telegram_link_code();
  perform test_helpers.put68('code2', r ->> 'code');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.telegram_link_codes where user_id = v_owner and used_at is null) = 1, '2.9 one unused code per user');
  perform test_helpers.login(v_staff);
  perform test_helpers.put68('code_staff', (public.create_telegram_link_code()) ->> 'code');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. browser roles can never call the bot's functions
do $$
declare
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_error($q$select public.telegram_identify(1, 1, null)$q$, '42501', '3.1 a signed-in user cannot call telegram_identify');
  perform test_helpers.expect_error($q$select public.telegram_redeem_code(repeat('a', 64), 1, 1, 'x')$q$, '42501', '3.2 a signed-in user cannot redeem a code through the bot function');
  perform test_helpers.expect_error($q$select public.telegram_summary(gen_random_uuid(), gen_random_uuid(), current_date, current_date)$q$, '42501', '3.3 nor read a summary');
  perform test_helpers.expect_error($q$select public.telegram_cleanup()$q$, '42501', '3.4 nor clean up');
  perform test_helpers.expect_error('select count(*) from public.telegram_links', '42501', '3.5 the tables are closed to browser roles');
  perform test_helpers.logout();
  perform test_helpers.as_anon();
  perform test_helpers.expect_error($q$select public.telegram_claim_update(1)$q$, '42501', '3.6 anon cannot call the bot functions either');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 4. redeeming the code (the bot's server, service_role)
do $$
declare
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
  v_staff uuid := 'e6800000-0000-0000-0000-000000000002';
  r jsonb;
  v_link uuid;
begin
  perform test_helpers.as_service_role();
  perform test_helpers.assert(public.telegram_claim_update(900001) is true, '4.1 an update is handled the first time');
  perform test_helpers.assert(public.telegram_claim_update(900001) is false, '4.2 and only once');
  perform test_helpers.expect_msg(format($q$select public.telegram_redeem_code(%L, 111, 111, 'owner_tg')$q$, encode(extensions.digest(test_helpers.g68('code1'), 'sha256'), 'hex')),
    'INVALID', '4.3 the replaced code no longer works');
  perform test_helpers.expect_msg($q$select public.telegram_redeem_code(repeat('0', 64), 111, 111, 'owner_tg')$q$, 'INVALID', '4.4 an unknown code is refused');
  r := public.telegram_redeem_code(encode(extensions.digest(test_helpers.g68('code2'), 'sha256'), 'hex'), 111, 111, 'owner_tg');
  v_link := (r ->> 'link_id')::uuid;
  perform test_helpers.put68('link_owner', v_link::text);
  perform test_helpers.assert(r ->> 'display_name' = 'p68_owner', '4.5 the code pairs the user who made it');
  perform test_helpers.expect_msg(format($q$select public.telegram_redeem_code(%L, 111, 111, 'owner_tg')$q$, encode(extensions.digest(test_helpers.g68('code2'), 'sha256'), 'hex')),
    'INVALID', '4.6 a code works once');
  r := public.telegram_redeem_code(encode(extensions.digest(test_helpers.g68('code_staff'), 'sha256'), 'hex'), 222, 222, 'staff_tg');
  perform test_helpers.put68('link_staff', r ->> 'link_id');
  perform test_helpers.logout();
  perform test_helpers.assert((select max_entry_amount from public.telegram_links where id = v_link) = 5000000, '4.7 the default limit per entry is 5,000,000');
  perform test_helpers.assert((select default_entity_id from public.telegram_links where id = v_link) is not null, '4.8 a default Entity is chosen');
  -- an expired code is refused
  perform test_helpers.login(v_owner);
  perform test_helpers.put68('code3', (public.create_telegram_link_code()) ->> 'code');
  perform test_helpers.logout();
  update public.telegram_link_codes set expires_at = now() - interval '1 minute' where user_id = v_owner and used_at is null;
  perform test_helpers.as_service_role();
  perform test_helpers.expect_msg(format($q$select public.telegram_redeem_code(%L, 111, 111, 'owner_tg')$q$, encode(extensions.digest(test_helpers.g68('code3'), 'sha256'), 'hex')),
    'INVALID', '4.9 an expired code is refused');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.audit_events where target_table = 'telegram_links' and target_id = v_link) >= 1, '4.10 the pairing is in the audit trail');
end
$$;

-- ================================================================ 5. who is writing
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  r jsonb;
  v_before text;
begin
  perform test_helpers.as_service_role();
  v_before := current_setting('request.jwt.claims', true);
  perform test_helpers.assert(public.telegram_identify(999, 999, null) is null, '5.1 a stranger is not identified');
  r := public.telegram_identify(111, 111, null);
  perform test_helpers.assert(r ->> 'link_id' = v_link::text and (r ->> 'is_private')::boolean, '5.2 the paired user is identified in the private chat');
  perform test_helpers.assert(jsonb_array_length(r -> 'memberships') = 2, '5.3 both books are listed');
  perform test_helpers.assert((select bool_and((m ->> 'can_create')::boolean and (m ->> 'can_confirm')::boolean) from jsonb_array_elements(r -> 'memberships') m), '5.4 the owner may create and confirm in both');
  perform test_helpers.assert(current_setting('request.jwt.claims', true) = v_before, '5.5 the caller''s claims are restored afterwards');
  perform test_helpers.assert(auth.uid() is null, '5.6 and nobody stays impersonated');
  perform test_helpers.assert(public.telegram_identify(111, -100123, null) is null, '5.7 an unregistered group is not identified');
  perform test_helpers.expect_msg(format($q$select public.telegram_register_chat(%L, 5, 'group', 'x')$q$, v_link), 'INVALID', '5.8 only a group (negative id) can be registered');
  perform public.telegram_register_chat(v_link, -100123, 'supergroup', 'Catatan Hikarich');
  perform test_helpers.assert((public.telegram_identify(111, -100123, 7) ->> 'is_private')::boolean is false, '5.9 a registered group works for its owner');
  perform test_helpers.assert(public.telegram_identify(222, -100123, null) ->> 'link_id' = test_helpers.g68('link_staff')::text and not (public.telegram_identify(222, -100123, null) ->> 'is_private')::boolean, '5.10 another paired member of the group acts with their OWN link, not the owner''s');
  perform test_helpers.assert(public.telegram_identify(999, -100123, null) ->> 'link_id' = v_link::text and not (public.telegram_identify(999, -100123, null) ->> 'is_private')::boolean, '5.10b a member who is not linked acts as the link that registered the group (decision 423)');
  perform test_helpers.assert(public.telegram_identify(999, 999, null) is null, '5.10c ... but still has nothing in a private chat of their own');
  perform test_helpers.expect_msg(format($q$select public.telegram_register_chat(%L, -100123, 'group', 'x')$q$, test_helpers.g68('link_staff')), 'CONFLICT', '5.11 a group cannot be taken over');
  perform public.telegram_set_topic_entity(v_link, -100123, 7, pt);
  perform test_helpers.assert((public.telegram_identify(111, -100123, 7) ->> 'chat_entity_id') = pt::text, '5.12 a topic is tied to an Entity');
  perform test_helpers.assert((public.telegram_identify(111, -100123, 8) ->> 'chat_entity_id') is null, '5.13 other topics are not');
  perform test_helpers.expect_msg(format($q$select public.telegram_set_topic_entity(%L, -100123, 7, %L)$q$, test_helpers.g68('link_staff'), pt), 'FORBIDDEN', '5.14 only the group''s owner sets topics');
  perform public.telegram_unregister_chat(v_link, -100123);
  perform test_helpers.assert(public.telegram_identify(111, -100123, 7) is null, '5.15 an unregistered group stops working');
  perform test_helpers.assert(public.telegram_identify(999, -100123, null) is null, '5.16 and then nobody is served there');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. context for matching (names only)
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  r jsonb;
  c jsonb;
begin
  perform test_helpers.as_service_role();
  r := public.telegram_context(v_link);
  perform test_helpers.assert(jsonb_array_length(r) = 2, '6.1 one block per Entity where the user may create expenses');
  select x into c from jsonb_array_elements(r) x where x ->> 'entity_code' = 'p68_pt';
  perform test_helpers.assert(exists (select 1 from jsonb_array_elements(c -> 'categories') k where k ->> 'name' = 'Makan & Minum'), '6.2 active expense categories are listed');
  perform test_helpers.assert(not exists (select 1 from jsonb_array_elements(c -> 'categories') k where k ->> 'name' = 'Lama'), '6.3 inactive ones are not');
  perform test_helpers.assert(exists (select 1 from jsonb_array_elements(c -> 'accounts') k where k ->> 'name' = 'Kas Kecil'), '6.4 paying accounts in the Entity currency are listed');
  perform test_helpers.assert(not exists (select 1 from jsonb_array_elements(c -> 'accounts') k where k ->> 'name' = 'USD Bank'), '6.5 a foreign-currency account is not');
  perform test_helpers.assert(not (c::text ~* 'balance|saldo'), '6.6 no balance leaves the database');
  perform test_helpers.assert((c ->> 'today')::date = test_helpers.today(pt), '6.7 the Entity''s own today is given');
  -- the staff link sees only the Entity it belongs to, and may create but not confirm there
  r := public.telegram_context(test_helpers.g68('link_staff')::uuid);
  perform test_helpers.assert(jsonb_array_length(r) = 1 and r -> 0 ->> 'entity_id' = pt::text, '6.8 the staff link sees only its own Entity');
  perform test_helpers.assert((r -> 0 ->> 'can_confirm')::boolean is false, '6.9 and may not confirm there');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 7. recording an expense for the paired user
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  pe uuid := test_helpers.entity('p68_pe');
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  v_slink uuid := test_helpers.g68('link_staff')::uuid;
  v_cash uuid := test_helpers.g68('cash')::uuid;
  v_usd uuid := test_helpers.g68('usd')::uuid;
  v_food uuid := test_helpers.g68('cat_food')::uuid;
  v_today date := test_helpers.today(pt);
  v_lines jsonb;
  r jsonb;
  r2 jsonb;
  x public.expenses%rowtype;
  v_before text;
begin
  v_lines := jsonb_build_array(jsonb_build_object('description', 'Kopi susu', 'quantity', 1, 'unit_price', 85000, 'category_id', v_food));
  perform test_helpers.as_service_role();
  v_before := current_setting('request.jwt.claims', true);
  r := public.telegram_record_expense(v_link, 'key-p68-rec-001', pt, v_cash, v_today, v_lines, null, 'Kopi Kenangan', 'Dari struk', true);
  perform test_helpers.put68('e1', r ->> 'expense_id');
  perform test_helpers.assert(r ->> 'status' = 'confirmed' and r ->> 'number' is not null and (r ->> 'total')::numeric = 85000, '7.1 within the limit the expense is confirmed and numbered');
  perform test_helpers.assert(current_setting('request.jwt.claims', true) = v_before and auth.uid() is null, '7.2 the bot leaves no identity behind');
  r2 := public.telegram_record_expense(v_link, 'key-p68-rec-001', pt, v_cash, v_today, v_lines, null, 'Kopi Kenangan', 'Dari struk', true);
  perform test_helpers.assert(r2 ->> 'expense_id' = r ->> 'expense_id' and r2 ->> 'status' = 'confirmed', '7.3 the same key replays the same expense');
  perform test_helpers.logout();
  select * into x from public.expenses where id = (r ->> 'expense_id')::uuid;
  perform test_helpers.assert(x.created_by = v_owner and x.entity_id = pt and left(x.internal_note, 8) = 'Telegram' and x.internal_note like '%owner_tg%', '7.4 it is the owner''s entry, marked as made through Telegram');
  perform test_helpers.assert(x.journal_id is not null and x.financial_account_id = v_cash and x.payee_name = 'Kopi Kenangan', '7.5 it is posted to the books');
  perform test_helpers.assert((select count(*) from public.audit_events where target_table = 'expenses' and target_id = x.id and actor_id = v_owner) >= 1, '7.6 the audit trail names the owner');
  perform test_helpers.assert((select count(*) from public.expenses where entity_id = pt) = 1, '7.7 the replay created nothing new');

  -- the limit
  perform test_helpers.login(v_owner);
  perform public.update_telegram_settings(50000, true, true, true, null);
  perform test_helpers.logout();
  perform test_helpers.as_service_role();
  r := public.telegram_record_expense(v_link, 'key-p68-rec-002', pt, v_cash, v_today, v_lines, null, 'Kopi Kenangan', null, true);
  perform test_helpers.put68('e_limit', r ->> 'expense_id');
  perform test_helpers.assert(r ->> 'status' = 'draft' and r ->> 'reason_code' = 'ABOVE_LIMIT', '7.8 above the limit the entry stays a draft');
  perform test_helpers.logout();
  perform test_helpers.assert((select journal_id is null and expense_number is null from public.expenses where id = (r ->> 'expense_id')::uuid), '7.9 and posts nothing');
  -- raising the limit needs a fresh step-up, lowering does not
  perform test_helpers.login(v_owner, 'aal2', interval '1 hour');
  perform test_helpers.expect_msg('select public.update_telegram_settings(9000000, true, true, true, null)', 'STEP_UP_REQUIRED', '7.10 a higher limit needs a fresh step-up');
  perform public.update_telegram_settings(40000, true, true, true, null);
  perform test_helpers.expect_msg('select public.update_telegram_settings(0, true, true, true, null)', 'INVALID', '7.11 the limit must be positive');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform public.update_telegram_settings(5000000, true, true, true, pt);
  perform test_helpers.assert((public.my_telegram_link() ->> 'max_entry_amount')::numeric = 5000000, '7.12 with a fresh step-up the limit is raised');
  perform test_helpers.logout();

  -- a refused confirmation keeps the draft and says why
  perform test_helpers.as_service_role();
  r := public.telegram_record_expense(v_link, 'key-p68-rec-003', pt, v_cash, v_today + 5, v_lines, null, 'Kopi Kenangan', null, true);
  perform test_helpers.assert(r ->> 'status' = 'draft' and r ->> 'reason_code' = 'INVALID' and r ->> 'reason' like 'INVALID%', '7.13 a refused confirmation keeps a draft and returns the refusal');
  -- the staff link: may create, may not confirm, only in its own Entity
  r := public.telegram_record_expense(v_slink, 'key-p68-rec-004', pt, v_cash, v_today, v_lines, null, 'Warung', null, true);
  perform test_helpers.put68('e_staff', r ->> 'expense_id');
  perform test_helpers.assert(r ->> 'status' = 'draft' and r ->> 'reason_code' = 'FORBIDDEN', '7.14 without bills.pay the staff''s entry stays a draft');
  perform test_helpers.expect_msg(format($q$select public.telegram_record_expense(%L, 'key-p68-rec-005', %L, %L, %L, %L::jsonb, null, 'Warung', null, true)$q$,
    v_slink, pe, v_cash, v_today, v_lines::text), 'FORBIDDEN', '7.15 an Entity the user does not belong to is refused');
  perform test_helpers.expect_msg(format($q$select public.telegram_record_expense(%L, 'key-p68-rec-006', %L, %L, %L, %L::jsonb, null, 'Warung', null, true)$q$,
    v_link, pt, v_usd, v_today, v_lines::text), 'INVALID', '7.16 a foreign-currency account is refused (needs a rate)');
  perform test_helpers.expect_msg(format($q$select public.telegram_record_expense(%L, 'key-p68-rec-007', %L, %L, %L, '[]'::jsonb, null, 'Warung', null, true)$q$,
    v_link, pt, v_cash, v_today), 'INVALID', '7.17 no lines is refused');
  perform test_helpers.expect_msg(format($q$select public.telegram_record_expense(%L, 'short', %L, %L, %L, %L::jsonb, null, 'Warung', null, true)$q$,
    v_link, pt, v_cash, v_today, v_lines::text), 'INVALID', '7.18 a short idempotency key is refused');
  perform test_helpers.expect_msg(format($q$select public.telegram_record_expense(%L, 'key-p68-rec-008', %L, %L, %L, %L::jsonb, null, '', null, true)$q$,
    v_link, pt, v_cash, v_today, v_lines::text), 'INVALID', '7.19 a payee is still required by the books');
  perform test_helpers.expect_msg(format($q$select public.telegram_record_expense(%L, 'key-p68-rec-009', %L, %L, %L, %L::jsonb, null, 'Warung', null, false)$q$,
    gen_random_uuid(), pt, v_cash, v_today, v_lines::text), 'FORBIDDEN', '7.20 an unknown link is refused');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 7b. a receipt photo becomes an attachment of the entry
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  v_slink uuid := test_helpers.g68('link_staff')::uuid;
  v_exp uuid := test_helpers.g68('e1')::uuid;
  v_sha text := encode(extensions.digest('struk-p68-synthetic', 'sha256'), 'hex');
  r jsonb;
  v_doc uuid;
  v_l1 uuid;
  v_l2 uuid;
begin
  perform test_helpers.as_service_role();
  r := public.telegram_register_receipt(v_link, pt, 'key-p68-doc-001', 'struk-telegram.jpg', 'image/jpeg', 120000, v_sha);
  v_doc := (r ->> 'document_id')::uuid;
  perform test_helpers.assert(v_doc is not null and (r ->> 'stored')::boolean is false, '7b.1 the photo is registered as a document, bytes not stored yet');
  perform test_helpers.assert(public.telegram_register_receipt(v_link, pt, 'key-p68-doc-001', 'struk-telegram.jpg', 'image/jpeg', 120000, v_sha) ->> 'document_id' = v_doc::text, '7b.2 a retry returns the same document');
  v_l1 := public.telegram_attach_receipt(v_link, v_doc, pt::text || '/' || v_doc::text, v_exp);
  perform test_helpers.assert(v_l1 is not null, '7b.3 the document is linked to the entry');
  perform test_helpers.logout();
  perform test_helpers.assert(exists (select 1 from public.documents where id = v_doc and storage_path = pt::text || '/' || v_doc::text), '7b.4 the storage path is recorded once');
  perform test_helpers.assert((select purpose from public.document_links where id = v_l1) = 'receipt' and (select target_type from public.document_links where id = v_l1) = 'expense', '7b.5 as a receipt of an expense');
  perform test_helpers.as_service_role();
  v_l2 := public.telegram_attach_receipt(v_link, v_doc, pt::text || '/' || v_doc::text, v_exp);
  perform test_helpers.assert(v_l2 = v_l1, '7b.6 attaching again changes nothing');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.document_links where document_id = v_doc) = 1, '7b.7 still a single link');
  perform test_helpers.as_service_role();
  perform test_helpers.expect_msg(format($q$select public.telegram_attach_receipt(%L, %L, 'x/y', %L)$q$, v_slink, v_doc, v_exp), 'FORBIDDEN', '7b.8 another user cannot attach to an entry that is not theirs');
  perform test_helpers.expect_msg(format($q$select public.telegram_register_receipt(%L, %L, 'key-p68-doc-002', 'a.exe', 'application/x-msdownload', 10, %L)$q$, v_link, pt, encode(extensions.digest('exe-p68', 'sha256'), 'hex')), 'INVALID', '7b.9 an unaccepted file type is refused');
  perform test_helpers.logout();
end
$$;


-- ================================================================ 8. undo, correction, recent entries
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  v_slink uuid := test_helpers.g68('link_staff')::uuid;
  v_cash uuid := test_helpers.g68('cash')::uuid;
  v_food uuid := test_helpers.g68('cat_food')::uuid;
  v_move uuid := test_helpers.g68('cat_move')::uuid;
  v_today date := test_helpers.today(pt);
  v_e1 uuid := test_helpers.g68('e1')::uuid;
  v_web uuid;
  r jsonb;
  v_new uuid;
begin
  -- an entry made on the website is not the bot's to undo
  perform test_helpers.login(v_owner);
  v_web := public.create_expense_draft(pt, 'key-p68-web-01', v_cash, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Beli ATK', 'unit_price', 10000, 'category_id', v_food)), null, 'Toko ATK');
  perform test_helpers.logout();

  perform test_helpers.as_service_role();
  r := public.telegram_recent_entries(v_link, 10);
  perform test_helpers.assert(r -> 0 ->> 'expense_id' is not null and not exists (select 1 from jsonb_array_elements(r) e where e ->> 'expense_id' = v_web::text),
    '8.1 recent entries list the bot''s own entries only');
  perform test_helpers.assert(exists (select 1 from jsonb_array_elements(r) e where e ->> 'expense_id' = v_e1::text and e ->> 'status' = 'confirmed' and e ->> 'payee' = 'Kopi Kenangan'),
    '8.2 with status and payee');
  perform test_helpers.assert(not exists (select 1 from jsonb_array_elements(public.telegram_recent_entries(v_slink, 10)) e where e ->> 'expense_id' = v_e1::text),
    '8.3 another paired user never sees them');
  perform test_helpers.expect_msg(format($q$select public.telegram_undo_entry(%L, 'key-p68-undo-01', %L)$q$, v_link, v_web), 'FORBIDDEN', '8.4 a website entry cannot be undone by the bot');
  perform test_helpers.expect_msg(format($q$select public.telegram_undo_entry(%L, 'key-p68-undo-02', %L)$q$, v_slink, v_e1), 'FORBIDDEN', '8.5 nor someone else''s entry');
  perform test_helpers.expect_msg(format($q$select public.telegram_undo_entry(%L, 'short', %L)$q$, v_link, v_e1), 'INVALID', '8.6 a short key is refused');

  -- a correction replaces the earlier entry: reverse the old, record the new, in one step
  r := public.telegram_record_expense(v_link, 'key-p68-rep-001', pt, v_cash, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Kopi susu', 'quantity', 1, 'unit_price', 90000, 'category_id', v_food)),
    null, 'Kopi Kenangan', 'Dikoreksi', true, v_e1);
  v_new := (r ->> 'expense_id')::uuid;
  perform test_helpers.put68('e2', v_new::text);
  perform test_helpers.assert(r ->> 'status' = 'confirmed' and (r ->> 'total')::numeric = 90000, '8.7 the corrected entry is confirmed');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.expenses where id = v_e1) = 'reversed', '8.8 the earlier entry is reversed');
  perform test_helpers.as_service_role();
  perform test_helpers.expect_msg(format($q$select public.telegram_record_expense(%L, 'key-p68-rep-002', %L, %L, %L, %L::jsonb, null, 'X', null, true, %L)$q$,
    v_link, pt, v_cash, v_today, jsonb_build_array(jsonb_build_object('description', 'x', 'unit_price', 1))::text, v_web), 'FORBIDDEN', '8.9 a website entry cannot be replaced by the bot');
  perform test_helpers.expect_msg(format($q$select public.telegram_record_expense(%L, 'key-p68-rep-003', %L, %L, %L, %L::jsonb, null, 'X', null, true, %L)$q$,
    v_link, pt, v_cash, v_today, jsonb_build_array(jsonb_build_object('description', 'x', 'unit_price', 1))::text, v_e1), 'CONFLICT', '8.10 an entry already reversed cannot be replaced again');

  -- undo: confirmed -> reversed, draft -> cancelled
  r := public.telegram_record_expense(v_link, 'key-p68-rec-010', pt, v_cash, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Parkir', 'unit_price', 30000, 'category_id', v_move)), null, 'Parkir Mall', null, true);
  perform test_helpers.put68('e3', r ->> 'expense_id');
  r := public.telegram_undo_entry(v_link, 'key-p68-undo-03', (r ->> 'expense_id')::uuid);
  perform test_helpers.assert(r ->> 'result' = 'reversed', '8.11 undoing a confirmed entry reverses it');
  perform test_helpers.expect_msg(format($q$select public.telegram_undo_entry(%L, 'key-p68-undo-04', %L)$q$, v_link, test_helpers.g68('e3')::uuid), 'CONFLICT', '8.12 it can be undone only once');
  r := public.telegram_undo_entry(v_link, 'key-p68-undo-05', test_helpers.g68('e_limit')::uuid);
  perform test_helpers.assert(r ->> 'result' = 'cancelled', '8.13 undoing a draft cancels it');
  perform test_helpers.logout();
  perform test_helpers.assert((select status from public.expenses where id = test_helpers.g68('e_limit')::uuid) = 'cancelled', '8.14 the draft is cancelled');
end
$$;

-- ================================================================ 9. summaries
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  pe uuid := test_helpers.entity('p68_pe');
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  v_slink uuid := test_helpers.g68('link_staff')::uuid;
  v_cash uuid := test_helpers.g68('cash')::uuid;
  v_move uuid := test_helpers.g68('cat_move')::uuid;
  v_today date := test_helpers.today(pt);
  r jsonb;
begin
  perform test_helpers.as_service_role();
  perform public.telegram_record_expense(v_link, 'key-p68-rec-011', pt, v_cash, v_today,
    jsonb_build_array(jsonb_build_object('description', 'Grab ke klien', 'unit_price', 20000, 'category_id', v_move)), null, 'Grab', null, true);
  r := public.telegram_summary(v_link, pt, v_today - 1, v_today);
  perform test_helpers.assert((r ->> 'total')::numeric = 110000 and (r ->> 'count')::int = 2, '9.1 only confirmed, not-reversed expenses count (90,000 + 20,000)');
  perform test_helpers.assert(r -> 'by_category' -> 0 ->> 'name' = 'Makan & Minum' and (r -> 'by_category' -> 0 ->> 'total')::numeric = 90000
    and r -> 'by_category' -> 1 ->> 'name' = 'Transportasi', '9.2 grouped by category, biggest first');
  perform test_helpers.assert((r -> 'top' -> 0 ->> 'amount')::numeric = 90000 and r -> 'top' -> 0 ->> 'payee' = 'Kopi Kenangan', '9.3 the biggest item comes first');
  perform test_helpers.assert(jsonb_array_length(r -> 'entries') = 2, '9.4 the entries of the period are listed');
  perform test_helpers.assert((r ->> 'drafts')::int >= 1, '9.5 drafts waiting on the website are counted');
  perform test_helpers.assert(r ->> 'entity_code' = 'p68_pt' and r ->> 'currency' = 'IDR', '9.6 the answer says which book it is');
  perform test_helpers.assert((public.telegram_summary(v_link, pt, v_today - 30, v_today - 20) ->> 'total')::numeric = 0, '9.7 an empty period totals zero');
  perform test_helpers.assert((public.telegram_summary(v_link, pe, v_today - 1, v_today) ->> 'total')::numeric = 0, '9.8 the Pribadi book is separate from the PT');
  perform test_helpers.expect_msg(format($q$select public.telegram_summary(%L, %L, %L, %L)$q$, v_link, pt, v_today, v_today - 1), 'INVALID', '9.9 the period must not run backwards');
  perform test_helpers.expect_msg(format($q$select public.telegram_summary(%L, %L, %L, %L)$q$, v_link, pt, v_today - 500, v_today), 'INVALID', '9.10 nor exceed 400 days');
  perform test_helpers.expect_msg(format($q$select public.telegram_summary(%L, %L, %L, %L)$q$, v_slink, pe, v_today - 1, v_today), 'FORBIDDEN', '9.11 a user cannot read a book they do not belong to');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 7c. a purchase on an asset category: activate the draft asset
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  v_slink uuid := test_helpers.g68('link_staff')::uuid;
  v_cash uuid := test_helpers.g68('cash')::uuid;
  v_today date := test_helpers.today(pt);
  v_cat uuid;
  r jsonb;
  v_assets jsonb;
  v_asset uuid;
  v_n integer;
begin
  select id into v_cat from public.categories where entity_id = pt and name = 'Smartphone & Gadget' and kind = 'asset';
  perform test_helpers.as_service_role();
  r := public.telegram_record_expense(v_link, 'key-p68-ast-001', pt, v_cash, v_today,
    jsonb_build_array(jsonb_build_object('description', 'iPhone kantor', 'quantity', 1, 'unit_price', 3000000, 'category_id', v_cat, 'treatment', 'asset')),
    null, 'Toko HP', null, true);
  perform test_helpers.assert(r ->> 'status' = 'confirmed', '7c.1 the purchase is confirmed');
  v_assets := public.telegram_expense_assets(v_link, (r ->> 'expense_id')::uuid);
  perform test_helpers.assert(jsonb_array_length(v_assets) = 1 and v_assets -> 0 ->> 'name' = 'iPhone kantor'
    and (v_assets -> 0 ->> 'can_manage')::boolean, '7c.2 one draft asset was opened by the website rule');
  v_asset := (v_assets -> 0 ->> 'asset_id')::uuid;
  perform test_helpers.expect_msg(format($q$select public.telegram_activate_asset(%L, 'key-p68-act-000', %L, 48)$q$, v_slink, v_asset), 'FORBIDDEN', '7c.3 another user cannot activate it');
  v_n := public.telegram_activate_asset(v_link, 'key-p68-act-001', v_asset, 48);
  perform test_helpers.assert(v_n = 48, '7c.4 the straight-line schedule has 48 monthly lines');
  perform test_helpers.assert(public.telegram_activate_asset(v_link, 'key-p68-act-001', v_asset, 48) = 48, '7c.5 a repeated tap changes nothing');
  perform test_helpers.assert(jsonb_array_length(public.telegram_expense_assets(v_link, (r ->> 'expense_id')::uuid)) = 0, '7c.6 nothing is left to activate');
  perform test_helpers.logout();
  perform test_helpers.assert((select status = 'active' and depreciation_method = 'straight_line' and useful_life_months = 48 and in_service_date = acquisition_date
                               from public.fixed_assets where id = v_asset), '7c.7 active, straight line, in service on the purchase date');
end
$$;

-- ================================================================ 7d. paying the next instalment of a debt
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  v_slink uuid := test_helpers.g68('link_staff')::uuid;
  v_cash uuid := test_helpers.g68('cash')::uuid;
  v_today date := test_helpers.today(pt);
  v_loan uuid;
  v_open jsonb;
  v_pay uuid;
begin
  perform test_helpers.login(v_owner);
  v_loan := public.loan_create(pt, 'k-p68-loan-1', 'borrowed', 'Bank Uji', null, 'Pinjaman uji', '12000000', v_today - 40, 'short', '12', 'annuity', 12, 1, v_today - 10);
  perform public.loan_activate(v_loan, 'k-p68-loan-2', v_today - 35, v_cash);
  perform test_helpers.logout();
  perform test_helpers.as_service_role();
  v_open := public.telegram_loans_open(v_link);
  perform test_helpers.assert(jsonb_array_length(v_open) = 1 and v_open -> 0 ->> 'loan_id' = v_loan::text and (v_open -> 0 ->> 'seq')::int = 1
    and (v_open -> 0 ->> 'amount')::numeric > 1000000 and (v_open -> 0 ->> 'overdue')::boolean, '7d.1 the debt and its next instalment are listed');
  perform test_helpers.assert(exists (select 1 from jsonb_array_elements(v_open -> 0 -> 'accounts') a where a ->> 'id' = v_cash::text), '7d.2 with the accounts it can be paid from');
  perform test_helpers.assert(jsonb_array_length(public.telegram_loans_open(v_slink)) = 0, '7d.3 a user without loans.manage sees no debts');
  perform test_helpers.expect_msg(format($q$select public.telegram_pay_loan(%L, 'key-p68-pay-000', %L, %L)$q$, v_slink, v_loan, v_cash), 'FORBIDDEN', '7d.4 and cannot pay one');
  v_pay := public.telegram_pay_loan(v_link, 'key-p68-pay-001', v_loan, v_cash);
  perform test_helpers.assert(v_pay is not null, '7d.5 the instalment is paid as the schedule says');
  perform test_helpers.assert(public.telegram_pay_loan(v_link, 'key-p68-pay-001', v_loan, v_cash) = v_pay, '7d.6 a repeated tap is one payment');
  perform test_helpers.assert((public.telegram_loans_open(v_link) -> 0 ->> 'seq')::int = 2, '7d.7 the next instalment moves on');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 9b. the language of the bot's own words
do $$
declare
  v_link uuid := test_helpers.g68('link_owner')::uuid;
begin
  perform test_helpers.as_service_role();
  perform test_helpers.assert(public.telegram_identify(111, 111, null) ->> 'language' = 'id', '9b.1 Indonesian is the default');
  perform public.telegram_set_language(v_link, 'en');
  perform test_helpers.assert(public.telegram_identify(111, 111, null) ->> 'language' = 'en', '9b.2 English can be chosen');
  perform test_helpers.assert(exists (select 1 from jsonb_array_elements(public.telegram_report_targets('weekly')) t where t ->> 'language' = 'en'), '9b.3 reports follow the choice');
  perform test_helpers.expect_msg(format($q$select public.telegram_set_language(%L, 'fr')$q$, v_link), 'INVALID', '9b.4 other languages are refused');
  perform public.telegram_set_language(v_link, 'id');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 10. conversation, learning and preferences
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  pe uuid := test_helpers.entity('p68_pe');
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  v_slink uuid := test_helpers.g68('link_staff')::uuid;
  v_food uuid := test_helpers.g68('cat_food')::uuid;
  v_cash uuid := test_helpers.g68('cash')::uuid;
  v_pe_cat uuid := test_helpers.g68('cat_pe')::uuid;
  r jsonb;
begin
  perform test_helpers.as_service_role();
  perform test_helpers.assert(public.telegram_session_get(v_link, 111, 0) is null, '10.1 no conversation at first');
  perform public.telegram_session_put(v_link, 111, 0, '{"step":"kategori","n":1}'::jsonb, 60);
  perform test_helpers.assert(public.telegram_session_get(v_link, 111, 0) ->> 'step' = 'kategori', '10.2 the conversation is kept');
  perform public.telegram_session_put(v_link, 111, 0, '{"step":"rekening","n":2}'::jsonb, 60);
  perform test_helpers.assert(public.telegram_session_get(v_link, 111, 0) ->> 'step' = 'rekening', '10.3 the conversation is updated in place');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.telegram_sessions where link_id = v_link) = 1, '10.3b one conversation per chat');
  perform test_helpers.as_service_role();
  perform test_helpers.assert(public.telegram_session_get(v_link, 111, 5) is null, '10.4 threads do not share a conversation');
  perform test_helpers.logout();
  update public.telegram_sessions set expires_at = now() - interval '1 second';
  perform test_helpers.as_service_role();
  perform test_helpers.assert(public.telegram_session_get(v_link, 111, 0) is null, '10.5 an expired conversation is gone');
  perform public.telegram_session_put(v_link, 111, 0, '{"step":"x"}'::jsonb, 60);
  perform public.telegram_session_clear(v_link, 111, 0);
  perform test_helpers.assert(public.telegram_session_get(v_link, 111, 0) is null, '10.6 and can be cleared');
  perform test_helpers.expect_error(format($q$select public.telegram_session_put(%L, 1, 0, '[]'::jsonb, 60)$q$, v_link), '23514', '10.7 the state must be an object');

  -- learning from a correction
  perform public.telegram_learn(v_link, pt, '  Indomaret ', v_food, v_cash, 'Indomaret');
  perform public.telegram_learn(v_link, pt, 'indomaret', v_food, null, null);
  perform test_helpers.logout();
  perform test_helpers.assert((select hits = 2 and keyword = 'indomaret' and account_id = v_cash and payee_name = 'Indomaret'
    from public.telegram_learned_rules where entity_id = pt), '10.8 a correction is kept once per keyword, counted, and a blank never erases what was known');
  perform test_helpers.as_service_role();
  r := public.telegram_context(v_link);
  perform test_helpers.assert(exists (select 1 from jsonb_array_elements(r) x, jsonb_array_elements(x -> 'rules') k
    where x ->> 'entity_code' = 'p68_pt' and k ->> 'keyword' = 'indomaret' and k ->> 'category_id' = v_food::text), '10.9 the context carries the learned rule');
  perform test_helpers.expect_msg(format($q$select public.telegram_learn(%L, %L, 'a', %L, null, null)$q$, v_link, pt, v_food), 'INVALID', '10.10 a one-letter keyword is refused');
  perform test_helpers.expect_error(format($q$select public.telegram_learn(%L, %L, 'warung', %L, null, null)$q$, v_link, pt, v_pe_cat), '23503', '10.11 a category of another book is refused');
  perform test_helpers.expect_msg(format($q$select public.telegram_learn(%L, %L, 'warung', %L, null, null)$q$, v_slink, pe, v_pe_cat), 'FORBIDDEN', '10.12 a user cannot teach a book they do not belong to');

  -- preferences and who gets a report
  perform public.telegram_set_prefs(v_link, false, null, true, null);
  perform test_helpers.assert(not exists (select 1 from jsonb_array_elements(public.telegram_report_targets('daily')) t where t ->> 'link_id' = v_link::text), '10.13 a user who turned the daily report off is skipped');
  perform test_helpers.assert(exists (select 1 from jsonb_array_elements(public.telegram_report_targets('weekly')) t where t ->> 'link_id' = v_link::text and t ->> 'chat_id' = '111'), '10.14 but still gets the weekly one, at the chat they paired');
  perform test_helpers.assert(exists (select 1 from jsonb_array_elements(public.telegram_report_targets('monthly')) t where t ->> 'link_id' = v_link::text), '10.15 and the monthly one');
  perform test_helpers.expect_msg($q$select public.telegram_report_targets('hourly')$q$, 'INVALID', '10.16 an unknown report kind is refused');
  perform test_helpers.expect_msg(format($q$select public.telegram_set_prefs(%L, null, null, null, %L)$q$, v_slink, pe), 'FORBIDDEN', '10.17 a default Entity must be one the user may record in');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 11. the owner's own screen
do $$
declare
  pe uuid := test_helpers.entity('p68_pe');
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
  v_staff uuid := 'e6800000-0000-0000-0000-000000000002';
  v_other uuid := 'e6800000-0000-0000-0000-000000000004';
  r jsonb;
begin
  perform test_helpers.login(v_owner);
  r := public.my_telegram_link();
  perform test_helpers.assert((r ->> 'linked')::boolean and r ->> 'telegram_username' = 'owner_tg' and (r ->> 'report_daily')::boolean is false
    and (r ->> 'report_weekly')::boolean, '11.1 the owner sees their own pairing and settings');
  perform test_helpers.logout();
  perform test_helpers.login(v_other);
  perform test_helpers.assert((public.my_telegram_link() ->> 'linked')::boolean is false, '11.2 another user sees nothing of it');
  perform test_helpers.expect_msg('select public.update_telegram_settings(1000, true, true, true, null)', 'CONFLICT', '11.3 settings need a pairing');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format($q$select public.update_telegram_settings(1000, true, true, true, %L)$q$, pe), 'FORBIDDEN', '11.4 a default Entity must be one the user may record in');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 12. ending the pairing
do $$
declare
  pt uuid := test_helpers.entity('p68_pt');
  v_owner uuid := 'e6800000-0000-0000-0000-000000000001';
  v_link uuid := test_helpers.g68('link_owner')::uuid;
  v_slink uuid := test_helpers.g68('link_staff')::uuid;
  v_cash uuid := test_helpers.g68('cash')::uuid;
  v_today date := test_helpers.today(pt);
  r jsonb;
begin
  -- a disabled user stops working at once
  update public.profiles set is_active = false, disabled_at = now() where id = 'e6800000-0000-0000-0000-000000000002';
  perform test_helpers.as_service_role();
  perform test_helpers.assert(public.telegram_identify(222, 222, null) is null, '12.1 a disabled user is no longer identified');
  perform test_helpers.expect_msg(format($q$select public.telegram_context(%L)$q$, v_slink), 'FORBIDDEN', '12.2 nor served');
  perform test_helpers.assert(not exists (select 1 from jsonb_array_elements(public.telegram_report_targets('weekly')) t where t ->> 'link_id' = v_slink::text), '12.3 nor sent a report');
  perform public.telegram_session_put(v_link, 111, 0, '{"step":"x"}'::jsonb, 60);
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform public.revoke_telegram_link();
  perform test_helpers.assert((public.my_telegram_link() ->> 'linked')::boolean is false, '12.4 the owner ends the pairing');
  perform test_helpers.logout();
  perform test_helpers.assert(not exists (select 1 from public.telegram_sessions where link_id = v_link), '12.5 the open conversation goes with it');
  perform test_helpers.as_service_role();
  perform test_helpers.assert(public.telegram_identify(111, 111, null) is null, '12.6 the Telegram account is no longer identified');
  perform test_helpers.expect_msg(format($q$select public.telegram_record_expense(%L, 'key-p68-rec-020', %L, %L, %L, '[{"description":"x","unit_price":1}]'::jsonb, null, 'X', null, true)$q$,
    v_link, pt, v_cash, v_today), 'FORBIDDEN', '12.7 a revoked link records nothing');
  perform test_helpers.expect_msg(format($q$select public.telegram_summary(%L, %L, %L, %L)$q$, v_link, pt, v_today, v_today), 'FORBIDDEN', '12.8 nor reads');
  perform test_helpers.logout();
  perform test_helpers.assert((select status = 'revoked' and revoked_by = v_owner and revoked_at is not null from public.telegram_links where id = v_link), '12.9 the row keeps who ended it and when');

  -- housekeeping
  insert into public.telegram_updates (update_id, received_at) values (1, now() - interval '8 days'), (2, now());
  insert into public.telegram_sessions (link_id, chat_id, thread_id, state, expires_at)
  select v_slink, 222, 0, '{}'::jsonb, now() - interval '1 hour';
  perform test_helpers.as_service_role();
  r := public.telegram_cleanup();
  perform test_helpers.logout();
  perform test_helpers.assert((r ->> 'updates')::int = 1 and (r ->> 'sessions')::int >= 1, '12.10 old updates and expired conversations are cleaned');
  perform test_helpers.assert(exists (select 1 from public.telegram_updates where update_id = 2), '12.11 recent updates are kept');

  -- the pairing can be made again afterwards
  perform test_helpers.login(v_owner);
  perform test_helpers.put68('code4', (public.create_telegram_link_code()) ->> 'code');
  perform test_helpers.logout();
  perform test_helpers.as_service_role();
  r := public.telegram_redeem_code(encode(extensions.digest(test_helpers.g68('code4'), 'sha256'), 'hex'), 333, 333, 'new_tg');
  perform test_helpers.assert(public.telegram_identify(333, 333, null) ->> 'link_id' = r ->> 'link_id', '12.12 a new pairing works after the old one ended');
  perform test_helpers.logout();
end
$$;

rollback;
