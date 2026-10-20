-- p68 (decision 422): a Telegram bot that records expenses and reports summaries.
--
-- The OWNER asked for a Telegram bot (and an optional group) that works like a personal assistant: it understands a
-- chat message or a receipt photo, walks the owner through a numbered confirmation roadmap, records the expense in the
-- books, and reports a daily, weekly and monthly summary or whenever asked.
--
-- How it fits the existing security model (Step 06) -- read this before changing anything below:
--
--   * Telegram has no web session. The bot is a DELEGATE of one signed-in user, set up while that user is signed in
--     with MFA and a fresh step-up (create_telegram_link_code), then paired from the Telegram account by sending the
--     one-time code to the bot. Pairing is revocable at any time (revoke_telegram_link) and is refused the moment the
--     user or the membership is disabled.
--   * The delegate can do exactly three things for the paired user: create an expense draft and confirm it (the SAME
--     public.create_expense_draft / public.confirm_expense every screen uses, so permission, period, duplicate, tax and
--     maker-checker rules all run unchanged), cancel or reverse an expense the bot itself created, and read expense
--     summaries. Nothing else is reachable: there is no generic "act as" entry point.
--   * An entry above the paired limit (max_entry_amount) is never confirmed by the bot: it stays a draft for the
--     website. The limit can only be RAISED with a fresh step-up.
--   * Every function the bot's server calls is granted to service_role only. Browser roles never see them. The
--     server verifies Telegram's secret header and the paired Telegram user before it calls any of them.
--   * While a bot function acts for the user it presents the user's identity to the existing rules with the claims
--     of a session that passed MFA (aal2) and WITHOUT any authentication timestamp, so the 10-minute step-up window
--     never opens for it. The claims live only in the transaction (set_config is_local) and are restored before the
--     function returns. This is the one place where MFA is vouched for by the pairing instead of by a fresh code:
--     it is recorded in decision 422 and is the thing the OWNER should know about.
--   * The AI model that understands free text never receives books data: the server sends it only the chat message or
--     the photo, and matches the answer to categories and accounts itself. Nothing in this migration returns data to
--     a model.
--
-- Audit: every row written by the bot is written by the existing functions under the user's identity with the reason
-- "Dicatat lewat Telegram"; the expense carries an internal note starting with "Telegram" so the website can show
-- where it came from and the bot can find its own entries.

-- ------------------------------------------------------------ tables
create table public.telegram_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete restrict,
  telegram_user_id bigint not null,
  telegram_chat_id bigint not null,
  telegram_username text check (telegram_username is null or length(telegram_username) <= 64),
  status text not null default 'active' check (status in ('active', 'revoked')),
  default_entity_id uuid references public.entities (id) on delete restrict,
  max_entry_amount numeric(20, 4) not null default 5000000 check (max_entry_amount > 0 and max_entry_amount < 10::numeric ^ 13),
  report_daily boolean not null default true,
  report_weekly boolean not null default true,
  report_monthly boolean not null default true,
  linked_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  constraint telegram_links_revoked_consistency check ((status = 'revoked') = (revoked_at is not null))
);
create unique index telegram_links_one_active_per_user on public.telegram_links (user_id) where status = 'active';
create unique index telegram_links_one_active_per_telegram on public.telegram_links (telegram_user_id) where status = 'active';
call app_private.apply_standard_triggers('public.telegram_links', false);
call app_private.secure_table('public.telegram_links');
create trigger tg_audit after insert or update or delete on public.telegram_links
  for each row execute function app_private.tg_audit('');

-- One-time pairing codes. Only a hash is stored; the code itself is shown once on the website.
create table public.telegram_link_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete restrict,
  code_hash text not null unique check (code_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
call app_private.secure_table('public.telegram_link_codes');

-- Groups the paired user registered (from inside the group). A group only works for the user who registered it.
create table public.telegram_chats (
  chat_id bigint primary key,
  link_id uuid not null references public.telegram_links (id) on delete restrict,
  kind text not null check (kind in ('group', 'supergroup')),
  title text check (title is null or length(title) <= 200),
  default_entity_id uuid references public.entities (id) on delete restrict,
  registered_at timestamptz not null default now()
);
call app_private.secure_table('public.telegram_chats');

-- A topic (forum thread) of a registered group can be tied to one Entity, so a message sent in the "PT" topic is
-- recorded in the PT book without saying so. thread_id 0 stands for the group's general thread.
create table public.telegram_chat_topics (
  chat_id bigint not null references public.telegram_chats (chat_id) on delete cascade,
  thread_id bigint not null check (thread_id >= 0),
  entity_id uuid not null references public.entities (id) on delete restrict,
  primary key (chat_id, thread_id)
);
call app_private.secure_table('public.telegram_chat_topics');

-- The conversation in progress (the roadmap's state). One per chat and thread; it expires on its own.
create table public.telegram_sessions (
  id uuid primary key default gen_random_uuid(),
  link_id uuid not null references public.telegram_links (id) on delete restrict,
  chat_id bigint not null,
  thread_id bigint not null default 0,
  state jsonb not null check (jsonb_typeof(state) = 'object' and pg_column_size(state) < 65536),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (chat_id, thread_id)
);
call app_private.secure_table('public.telegram_sessions');

-- What the bot learned from a correction: "indomaret" is Makan & Kebutuhan Harian, paid from this account.
create table public.telegram_learned_rules (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  keyword text not null check (length(keyword) between 2 and 80 and keyword = lower(btrim(keyword))),
  category_id uuid,
  account_id uuid,
  payee_name text check (payee_name is null or length(payee_name) <= 200),
  hits integer not null default 1 check (hits > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entity_id, id),
  unique (entity_id, keyword),
  foreign key (entity_id, category_id) references public.categories (entity_id, id) on delete restrict,
  foreign key (entity_id, account_id) references public.financial_accounts (entity_id, id) on delete restrict
);
call app_private.secure_table('public.telegram_learned_rules');

-- An Entity-scoped row never moves to another Entity (the repository-wide rule checked by 10_structure.sql).
create trigger tg_lock_entity before update on public.telegram_chat_topics
  for each row execute function app_private.tg_lock_entity();
create trigger tg_lock_entity before update on public.telegram_learned_rules
  for each row execute function app_private.tg_lock_entity();

-- Telegram repeats an update until the webhook answers 200: each update is handled once.
create table public.telegram_updates (
  update_id bigint primary key,
  received_at timestamptz not null default now()
);
call app_private.secure_table('public.telegram_updates');

-- ------------------------------------------------------------ internal helpers
-- Presents the paired user to the existing rules (see the header) and returns the user id. Restores nothing by
-- itself: callers run in one transaction and call telegram_restore_claims() before returning.
create function app_private.telegram_act_as(p_link uuid) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare
  l public.telegram_links%rowtype;
begin
  select * into l from public.telegram_links where id = p_link and status = 'active';
  if not found then
    raise exception 'FORBIDDEN: the Telegram link is not active' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.profiles p where p.id = l.user_id and p.is_active) then
    raise exception 'FORBIDDEN: the user of this Telegram link is disabled' using errcode = 'insufficient_privilege';
  end if;
  -- No `amr`: the step-up window (recent_step_up) never opens for the bot.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', l.user_id, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  perform set_config('request.jwt.claim.sub', l.user_id::text, true);
  perform set_config('app.audit_reason', 'Dicatat lewat Telegram', true);
  return l.user_id;
end
$$;

create function app_private.telegram_restore_claims(p_claims text, p_sub text) returns void
language plpgsql set search_path = pg_catalog, public as $$
begin
  perform set_config('request.jwt.claims', coalesce(p_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub, ''), true);
  perform set_config('app.audit_reason', '', true);
end
$$;

-- True when the membership list (from my_access) grants the permission in the Entity.
create function app_private.telegram_has(p_access jsonb, p_entity uuid, p_key text) returns boolean
language sql immutable set search_path = pg_catalog, public as $$
  select exists (
    select 1 from jsonb_array_elements(coalesce(p_access -> 'memberships', '[]'::jsonb)) m
    where (m ->> 'entity_id')::uuid = p_entity and (m -> 'permissions') ? p_key)
$$;

-- ------------------------------------------------------------ browser functions (the signed-in owner)
-- A pairing code: 8 characters without look-alikes, valid for 10 minutes, shown once. Needs MFA and a fresh step-up.
create function public.create_telegram_link_code() returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_code text := '';
  v_expires timestamptz := now() + interval '10 minutes';
  i integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_active) then
    raise exception 'FORBIDDEN: this user is disabled' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.has_any_permission('bills.create') then
    raise exception 'FORBIDDEN: missing bills.create' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.aal2() then
    raise exception 'FORBIDDEN: multi-factor authentication is required' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;

  v_bytes := extensions.gen_random_bytes(8);
  for i in 0 .. 7 loop
    v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
  end loop;

  delete from public.telegram_link_codes where user_id = auth.uid() and used_at is null;
  insert into public.telegram_link_codes (user_id, code_hash, expires_at)
  values (auth.uid(), encode(extensions.digest(v_code, 'sha256'), 'hex'), v_expires);
  return jsonb_build_object('code', v_code, 'expires_at', v_expires);
end
$$;

-- The caller's own pairing, groups and settings, for the Pengaturan screen. Never returns another user's row.
create function public.my_telegram_link() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  l public.telegram_links%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.telegram_links where user_id = auth.uid() and status = 'active';
  if not found then
    return jsonb_build_object('linked', false);
  end if;
  return jsonb_build_object(
    'linked', true,
    'telegram_username', l.telegram_username,
    'linked_at', l.linked_at,
    'max_entry_amount', l.max_entry_amount::text,
    'report_daily', l.report_daily,
    'report_weekly', l.report_weekly,
    'report_monthly', l.report_monthly,
    'default_entity_id', l.default_entity_id,
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object('chat_id', c.chat_id::text, 'title', c.title, 'kind', c.kind,
                                          'registered_at', c.registered_at) order by c.registered_at)
      from public.telegram_chats c where c.link_id = l.id), '[]'::jsonb));
end
$$;

create function public.revoke_telegram_link() returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  perform set_config('app.audit_reason', 'Tautan Telegram diputus oleh pemilik', true);
  update public.telegram_links
  set status = 'revoked', revoked_at = now(), revoked_by = auth.uid()
  where user_id = auth.uid() and status = 'active';
  delete from public.telegram_sessions s
  using public.telegram_links l
  where s.link_id = l.id and l.user_id = auth.uid();
  delete from public.telegram_link_codes where user_id = auth.uid() and used_at is null;
end
$$;

-- Limit, reports and default Entity. Raising the limit needs a fresh step-up; lowering it or switching reports does not.
create function public.update_telegram_settings(
  p_max_entry_amount numeric, p_report_daily boolean, p_report_weekly boolean, p_report_monthly boolean,
  p_default_entity uuid)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.telegram_links%rowtype;
  v_access jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.telegram_links where user_id = auth.uid() and status = 'active' for update;
  if not found then
    raise exception 'CONFLICT: no Telegram account is paired' using errcode = 'integrity_constraint_violation';
  end if;
  if p_max_entry_amount is null or p_max_entry_amount <= 0 or p_max_entry_amount >= 10::numeric ^ 13 then
    raise exception 'INVALID: the limit per entry must be greater than zero' using errcode = 'invalid_parameter_value';
  end if;
  if p_max_entry_amount > l.max_entry_amount and not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if p_default_entity is not null then
    v_access := public.my_access();
    if not app_private.telegram_has(v_access, p_default_entity, 'bills.create') then
      raise exception 'FORBIDDEN: missing bills.create' using errcode = 'insufficient_privilege';
    end if;
  end if;
  update public.telegram_links
  set max_entry_amount = p_max_entry_amount,
      report_daily = coalesce(p_report_daily, report_daily),
      report_weekly = coalesce(p_report_weekly, report_weekly),
      report_monthly = coalesce(p_report_monthly, report_monthly),
      default_entity_id = p_default_entity
  where id = l.id;
end
$$;

-- ------------------------------------------------------------ bot functions (service_role only)
-- Each update from Telegram is handled once: true the first time, false for a repeat.
create function public.telegram_claim_update(p_update_id bigint) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_n integer;
begin
  insert into public.telegram_updates (update_id) values (p_update_id) on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end
$$;

-- Pairs a Telegram account with the user who made the code. The caller passes the SHA-256 hex of the code.
create function public.telegram_redeem_code(p_code_hash text, p_telegram_user bigint, p_chat bigint, p_username text)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  c public.telegram_link_codes%rowtype;
  v_link uuid;
  v_entity uuid;
  v_name text;
begin
  select * into c from public.telegram_link_codes where code_hash = p_code_hash for update;
  if not found or c.used_at is not null or c.expires_at < now() then
    raise exception 'INVALID: the code is unknown, used or expired' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.profiles p where p.id = c.user_id and p.is_active) then
    raise exception 'FORBIDDEN: the user is disabled' using errcode = 'insufficient_privilege';
  end if;
  update public.telegram_link_codes set used_at = now() where id = c.id;

  perform set_config('app.audit_reason', 'Tautan Telegram dibuat dengan kode sekali pakai', true);
  update public.telegram_links
  set status = 'revoked', revoked_at = now(), revoked_by = c.user_id
  where status = 'active' and (user_id = c.user_id or telegram_user_id = p_telegram_user);

  select m.entity_id into v_entity
  from public.entity_memberships m
  join public.entities e on e.id = m.entity_id and e.status = 'active'
  where m.user_id = c.user_id and m.status = 'active'
  order by e.code limit 1;

  insert into public.telegram_links (user_id, telegram_user_id, telegram_chat_id, telegram_username, default_entity_id, created_by)
  values (c.user_id, p_telegram_user, p_chat, left(p_username, 64), v_entity, c.user_id)
  returning id into v_link;
  select display_name into v_name from public.profiles where id = c.user_id;
  return jsonb_build_object('link_id', v_link, 'display_name', v_name);
end
$$;

-- Who is writing? Null for anyone who is not a paired user in a place that user registered.
create function public.telegram_identify(p_telegram_user bigint, p_chat bigint, p_thread bigint default null)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.telegram_links%rowtype;
  c public.telegram_chats%rowtype;
  v_topic uuid;
  v_is_private boolean := false;
  v_access jsonb;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
begin
  select * into l from public.telegram_links where telegram_user_id = p_telegram_user and status = 'active';
  if not found then
    return null;
  end if;
  if not exists (select 1 from public.profiles p where p.id = l.user_id and p.is_active) then
    return null;
  end if;
  if p_chat = l.telegram_chat_id then
    v_is_private := true;
  else
    select * into c from public.telegram_chats where chat_id = p_chat and link_id = l.id;
    if not found then
      return null;
    end if;
    select t.entity_id into v_topic from public.telegram_chat_topics t
    where t.chat_id = p_chat and t.thread_id = coalesce(p_thread, 0);
    v_topic := coalesce(v_topic, c.default_entity_id);
  end if;
  perform app_private.telegram_act_as(l.id);
  v_access := public.my_access();
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  if not coalesce((v_access ->> 'active')::boolean, false) then
    return null;
  end if;
  return jsonb_build_object(
    'link_id', l.id,
    'user_id', l.user_id,
    'display_name', v_access ->> 'display_name',
    'username', l.telegram_username,
    'is_private', v_is_private,
    'max_entry_amount', l.max_entry_amount::text,
    'report_daily', l.report_daily,
    'report_weekly', l.report_weekly,
    'report_monthly', l.report_monthly,
    'default_entity_id', l.default_entity_id,
    'chat_entity_id', v_topic,
    'memberships', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entity_id', m ->> 'entity_id', 'entity_code', m ->> 'entity_code', 'entity_type', m ->> 'entity_type',
        'entity_name', m ->> 'entity_name',
        'can_create', (m -> 'permissions') ? 'bills.create',
        'can_confirm', (m -> 'permissions') ? 'bills.pay',
        'can_view', (m -> 'permissions') ? 'bills.view'))
      from jsonb_array_elements(coalesce(v_access -> 'memberships', '[]'::jsonb)) m), '[]'::jsonb));
end
$$;

-- What the server needs to match a message: per Entity (where the user may create expenses) its active expense and
-- asset categories, paying accounts in the Entity's currency, active vendors and learned rules. Names only: no
-- balances, no amounts. This goes to the bot's own matching code, never to the language model.
create function public.telegram_context(p_link uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_access jsonb;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_out jsonb := '[]'::jsonb;
  m jsonb;
  e public.entities%rowtype;
begin
  perform app_private.telegram_act_as(p_link);
  v_access := public.my_access();
  for m in select x from jsonb_array_elements(coalesce(v_access -> 'memberships', '[]'::jsonb)) x loop
    if not ((m -> 'permissions') ? 'bills.create') then
      continue;
    end if;
    select * into e from public.entities where id = (m ->> 'entity_id')::uuid;
    v_out := v_out || jsonb_build_object(
      'entity_id', e.id, 'entity_code', e.code, 'entity_type', e.entity_type, 'entity_name', e.legal_name,
      'currency', e.base_currency, 'today', app_private.entity_today(e.id),
      'can_confirm', (m -> 'permissions') ? 'bills.pay',
      'categories', coalesce((
        select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'kind', c.kind,
          'is_parent', exists (select 1 from public.categories ch where ch.entity_id = c.entity_id and ch.parent_id = c.id))
          order by c.sort_order, c.name)
        from public.categories c where c.entity_id = e.id and c.is_active and c.kind in ('expense', 'asset')), '[]'::jsonb),
      'accounts', coalesce((
        select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind) order by a.name)
        from public.financial_accounts a where a.entity_id = e.id and a.is_active and a.currency = e.base_currency), '[]'::jsonb),
      'vendors', coalesce((
        select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.display_name) order by v.display_name)
        from (select ct.id, ct.display_name from public.contacts ct
              where ct.entity_id = e.id and ct.status = 'active' and ct.kind in ('vendor', 'both')
              order by ct.display_name limit 300) v), '[]'::jsonb),
      'rules', coalesce((
        select jsonb_agg(jsonb_build_object('keyword', r.keyword, 'category_id', r.category_id,
          'account_id', r.account_id, 'payee_name', r.payee_name, 'hits', r.hits) order by r.hits desc)
        from (select * from public.telegram_learned_rules lr where lr.entity_id = e.id
              order by lr.hits desc, lr.updated_at desc limit 300) r), '[]'::jsonb));
  end loop;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return v_out;
end
$$;

-- Records an expense for the paired user. p_lines uses the same shape as create_expense_draft. When p_confirm is true
-- and the total is within the paired limit the expense is confirmed in the same transaction; if the confirmation is
-- refused (duplicate, closed period, ...) the draft is kept and the refusal is returned, never swallowed silently.
-- p_replace names an earlier bot entry to cancel or reverse first (a correction).
create function public.telegram_record_expense(
  p_link uuid, p_key text, p_entity uuid, p_account uuid, p_date date, p_lines jsonb, p_payee_id uuid,
  p_payee_name text, p_notes text, p_confirm boolean, p_replace uuid default null)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.telegram_links%rowtype;
  v_access jsonb;
  v_user uuid;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_id uuid;
  v_total numeric := 0;
  v_status text := 'draft';
  v_reason text;
  v_code text;
  v_number text;
  x public.expenses%rowtype;
  v_old public.expenses%rowtype;
  v_line jsonb;
begin
  if p_key is null or length(btrim(p_key)) < 8 or length(p_key) > 100 then
    raise exception 'INVALID: an idempotency key of 8 to 100 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  select * into l from public.telegram_links where id = p_link and status = 'active';
  v_user := app_private.telegram_act_as(p_link);
  v_access := public.my_access();
  if not app_private.telegram_has(v_access, p_entity, 'bills.create') then
    raise exception 'FORBIDDEN: missing bills.create' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'INVALID: lines must be a non-empty list' using errcode = 'invalid_parameter_value';
  end if;
  for v_line in select e2 from jsonb_array_elements(p_lines) e2 loop
    v_total := v_total + coalesce((v_line ->> 'quantity')::numeric, 1) * coalesce((v_line ->> 'unit_price')::numeric, 0);
  end loop;

  if p_replace is not null then
    select * into v_old from public.expenses where id = p_replace and entity_id = p_entity;
    if not found or v_old.created_by is distinct from v_user or left(coalesce(v_old.internal_note, ''), 8) <> 'Telegram' then
      raise exception 'FORBIDDEN: only an entry made by this bot can be replaced here' using errcode = 'insufficient_privilege';
    end if;
    if v_old.status = 'confirmed' then
      perform public.reverse_expense(p_replace, p_key || ':rev', 'Dikoreksi lewat Telegram', null);
    elsif v_old.status in ('draft', 'submitted') then
      perform public.cancel_expense(p_replace, p_key || ':can', 'Dikoreksi lewat Telegram');
    else
      raise exception 'CONFLICT: the earlier entry is already %', v_old.status using errcode = 'integrity_constraint_violation';
    end if;
  end if;

  v_id := public.create_expense_draft(
    p_entity, p_key, p_account, p_date, p_lines, p_payee_id, p_payee_name, null, null, p_notes,
    left('Telegram' || coalesce(' @' || l.telegram_username, ''), 200));

  if p_confirm then
    if not app_private.telegram_has(v_access, p_entity, 'bills.pay') then
      v_reason := 'Hak "bills.pay" tidak dimiliki';
      v_code := 'FORBIDDEN';
    elsif v_total > l.max_entry_amount then
      v_reason := 'Di atas batas per catatan Telegram';
      v_code := 'ABOVE_LIMIT';
    else
      begin
        perform public.confirm_expense(v_id, p_key || ':ok', null);
        v_status := 'confirmed';
      exception when others then
        v_reason := sqlerrm;
        v_code := case when sqlerrm like 'CONFLICT%' then 'CONFLICT' when sqlerrm like 'INVALID%' then 'INVALID'
                       when sqlerrm like 'FORBIDDEN%' then 'FORBIDDEN' else 'ERROR' end;
      end;
    end if;
  end if;

  select * into x from public.expenses where id = v_id;
  v_number := x.expense_number;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return jsonb_build_object('expense_id', v_id, 'status', x.status, 'number', v_number, 'total', x.total::text,
                            'reason', v_reason, 'reason_code', v_code);
end
$$;

-- Latest entries the bot made for this user (newest first), to pick one for "batal" or a correction.
create function public.telegram_recent_entries(p_link uuid, p_limit integer default 5) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_user uuid;
  v_access jsonb;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_out jsonb;
begin
  v_user := app_private.telegram_act_as(p_link);
  v_access := public.my_access();
  select coalesce(jsonb_agg(row_to_json(q)::jsonb), '[]'::jsonb) into v_out
  from (
    select x.id as expense_id, x.entity_id, x.status, x.expense_number as number, x.expense_date, x.total::text as total,
           coalesce(x.payee_name, (select co.display_name from public.contacts co where co.id = x.payee_id)) as payee,
           (select string_agg(l.description, ', ' order by l.line_no) from public.expense_lines l where l.expense_id = x.id) as lines
    from public.expenses x
    where x.created_by = v_user and left(coalesce(x.internal_note, ''), 8) = 'Telegram'
      and x.status in ('draft', 'submitted', 'confirmed')
      and app_private.telegram_has(v_access, x.entity_id, 'bills.view')
    order by x.created_at desc
    limit greatest(1, least(coalesce(p_limit, 5), 20))
  ) q;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return v_out;
end
$$;

-- Cancels (draft) or reverses (confirmed) one entry the bot made for this user.
create function public.telegram_undo_entry(p_link uuid, p_key text, p_expense uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_user uuid;
  v_access jsonb;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  x public.expenses%rowtype;
  v_result text;
begin
  if p_key is null or length(btrim(p_key)) < 8 or length(p_key) > 100 then
    raise exception 'INVALID: an idempotency key of 8 to 100 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  v_user := app_private.telegram_act_as(p_link);
  v_access := public.my_access();
  select * into x from public.expenses where id = p_expense;
  if not found or x.created_by is distinct from v_user or left(coalesce(x.internal_note, ''), 8) <> 'Telegram'
     or not app_private.telegram_has(v_access, x.entity_id, 'bills.view') then
    raise exception 'FORBIDDEN: only an entry made by this bot can be undone here' using errcode = 'insufficient_privilege';
  end if;
  if x.status = 'confirmed' then
    perform public.reverse_expense(p_expense, p_key, 'Dibatalkan lewat Telegram', null);
    v_result := 'reversed';
  elsif x.status in ('draft', 'submitted') then
    perform public.cancel_expense(p_expense, p_key, 'Dibatalkan lewat Telegram');
    v_result := 'cancelled';
  else
    raise exception 'CONFLICT: the entry is already %', x.status using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return jsonb_build_object('expense_id', p_expense, 'result', v_result);
end
$$;

-- Confirmed expenses of one Entity between two dates, for the daily, weekly and monthly reports and for questions.
-- Reads only; amounts are the books' base amounts. Needs bills.view in the Entity.
create function public.telegram_summary(p_link uuid, p_entity uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_access jsonb;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  e public.entities%rowtype;
  v_total numeric;
  v_count integer;
  v_by_cat jsonb;
  v_top jsonb;
  v_entries jsonb;
  v_drafts integer;
  v_pending integer;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then
    raise exception 'INVALID: choose a period of at most 400 days' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.telegram_act_as(p_link);
  v_access := public.my_access();
  if not app_private.telegram_has(v_access, p_entity, 'bills.view') then
    raise exception 'FORBIDDEN: missing bills.view' using errcode = 'insufficient_privilege';
  end if;
  select * into e from public.entities where id = p_entity;

  select coalesce(sum(l.base_amount), 0), count(distinct x.id) into v_total, v_count
  from public.expenses x join public.expense_lines l on l.expense_id = x.id
  where x.entity_id = p_entity and x.status = 'confirmed' and x.expense_date between p_from and p_to;

  select coalesce(jsonb_agg(jsonb_build_object('name', q.name, 'total', q.total::text, 'count', q.n) order by q.total desc), '[]'::jsonb)
  into v_by_cat
  from (select coalesce(c.name, 'Tanpa kategori') as name, sum(l.base_amount) as total, count(*) as n
        from public.expenses x join public.expense_lines l on l.expense_id = x.id
        left join public.categories c on c.id = l.category_id
        where x.entity_id = p_entity and x.status = 'confirmed' and x.expense_date between p_from and p_to
        group by 1) q;

  select coalesce(jsonb_agg(jsonb_build_object('date', q.expense_date, 'description', q.description, 'amount', q.base_amount::text,
                                               'payee', q.payee) order by q.base_amount desc), '[]'::jsonb)
  into v_top
  from (select x.expense_date, l.description, l.base_amount,
               coalesce(x.payee_name, (select co.display_name from public.contacts co where co.id = x.payee_id)) as payee
        from public.expenses x join public.expense_lines l on l.expense_id = x.id
        where x.entity_id = p_entity and x.status = 'confirmed' and x.expense_date between p_from and p_to
        order by l.base_amount desc limit 5) q;

  select coalesce(jsonb_agg(jsonb_build_object('date', q.expense_date, 'description', q.description, 'amount', q.base_amount::text,
                                               'account', q.account) order by q.expense_date, q.created_at), '[]'::jsonb)
  into v_entries
  from (select x.expense_date, x.created_at, l.description, l.base_amount, fa.name as account
        from public.expenses x join public.expense_lines l on l.expense_id = x.id
        join public.financial_accounts fa on fa.id = x.financial_account_id
        where x.entity_id = p_entity and x.status = 'confirmed' and x.expense_date between p_from and p_to
        order by x.expense_date, x.created_at, l.line_no limit 40) q;

  select count(*) into v_drafts from public.expenses x
  where x.entity_id = p_entity and x.status in ('draft', 'submitted') and x.expense_date between p_from and p_to;
  select count(distinct x.id) into v_pending
  from public.expenses x join public.expense_lines l on l.expense_id = x.id
  where x.entity_id = p_entity and x.status = 'confirmed' and l.asset_link_status = 'pending'
    and x.expense_date between p_from and p_to;

  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return jsonb_build_object(
    'entity_id', e.id, 'entity_code', e.code, 'entity_type', e.entity_type, 'entity_name', e.legal_name,
    'currency', e.base_currency, 'from', p_from, 'to', p_to,
    'total', v_total::text, 'count', v_count, 'by_category', v_by_cat, 'top', v_top, 'entries', v_entries,
    'drafts', v_drafts, 'assets_to_register', v_pending);
end
$$;

-- The conversation in progress.
create function public.telegram_session_get(p_link uuid, p_chat bigint, p_thread bigint default 0) returns jsonb
language sql stable security definer set search_path = pg_catalog, public as $$
  select s.state from public.telegram_sessions s
  where s.link_id = p_link and s.chat_id = p_chat and s.thread_id = coalesce(p_thread, 0) and s.expires_at > now()
$$;

create function public.telegram_session_put(
  p_link uuid, p_chat bigint, p_thread bigint, p_state jsonb, p_ttl_minutes integer default 60)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if not exists (select 1 from public.telegram_links where id = p_link and status = 'active') then
    raise exception 'FORBIDDEN: the Telegram link is not active' using errcode = 'insufficient_privilege';
  end if;
  insert into public.telegram_sessions (link_id, chat_id, thread_id, state, expires_at)
  values (p_link, p_chat, coalesce(p_thread, 0), p_state, now() + make_interval(mins => greatest(1, least(coalesce(p_ttl_minutes, 60), 1440))))
  on conflict (chat_id, thread_id) do update
  set link_id = excluded.link_id, state = excluded.state, expires_at = excluded.expires_at, updated_at = now();
end
$$;

create function public.telegram_session_clear(p_link uuid, p_chat bigint, p_thread bigint default 0) returns void
language sql security definer set search_path = pg_catalog, public as $$
  delete from public.telegram_sessions where link_id = p_link and chat_id = p_chat and thread_id = coalesce(p_thread, 0)
$$;

-- What a correction teaches the bot. The keyword is the lower-cased merchant or item word.
create function public.telegram_learn(
  p_link uuid, p_entity uuid, p_keyword text, p_category uuid, p_account uuid, p_payee text)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_access jsonb;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_kw text := lower(btrim(coalesce(p_keyword, '')));
begin
  perform app_private.telegram_act_as(p_link);
  v_access := public.my_access();
  if not app_private.telegram_has(v_access, p_entity, 'bills.create') then
    raise exception 'FORBIDDEN: missing bills.create' using errcode = 'insufficient_privilege';
  end if;
  if length(v_kw) < 2 or length(v_kw) > 80 then
    raise exception 'INVALID: the keyword needs 2 to 80 characters' using errcode = 'invalid_parameter_value';
  end if;
  insert into public.telegram_learned_rules (entity_id, keyword, category_id, account_id, payee_name)
  values (p_entity, v_kw, p_category, p_account, nullif(left(btrim(coalesce(p_payee, '')), 200), ''))
  on conflict (entity_id, keyword) do update
  set category_id = coalesce(excluded.category_id, public.telegram_learned_rules.category_id),
      account_id = coalesce(excluded.account_id, public.telegram_learned_rules.account_id),
      payee_name = coalesce(excluded.payee_name, public.telegram_learned_rules.payee_name),
      hits = public.telegram_learned_rules.hits + 1, updated_at = now();
  perform app_private.telegram_restore_claims(v_claims, v_sub);
end
$$;

-- Settings changed from the chat (reports on or off, default Entity).
create function public.telegram_set_prefs(
  p_link uuid, p_daily boolean, p_weekly boolean, p_monthly boolean, p_default_entity uuid)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_access jsonb;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
begin
  perform app_private.telegram_act_as(p_link);
  if p_default_entity is not null then
    v_access := public.my_access();
    if not app_private.telegram_has(v_access, p_default_entity, 'bills.create') then
      raise exception 'FORBIDDEN: missing bills.create' using errcode = 'insufficient_privilege';
    end if;
  end if;
  update public.telegram_links
  set report_daily = coalesce(p_daily, report_daily),
      report_weekly = coalesce(p_weekly, report_weekly),
      report_monthly = coalesce(p_monthly, report_monthly),
      default_entity_id = coalesce(p_default_entity, default_entity_id)
  where id = p_link;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
end
$$;

-- Groups: the paired user registers a group from inside it and may tie each topic to an Entity.
create function public.telegram_register_chat(p_link uuid, p_chat bigint, p_kind text, p_title text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if p_chat >= 0 then
    raise exception 'INVALID: only a group can be registered' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.telegram_links where id = p_link and status = 'active') then
    raise exception 'FORBIDDEN: the Telegram link is not active' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from public.telegram_chats where chat_id = p_chat and link_id <> p_link) then
    raise exception 'CONFLICT: this group is registered by someone else' using errcode = 'integrity_constraint_violation';
  end if;
  insert into public.telegram_chats (chat_id, link_id, kind, title)
  values (p_chat, p_link, p_kind, left(p_title, 200))
  on conflict (chat_id) do update set title = excluded.title, kind = excluded.kind;
end
$$;

create function public.telegram_unregister_chat(p_link uuid, p_chat bigint) returns void
language sql security definer set search_path = pg_catalog, public as $$
  with gone as (delete from public.telegram_chats where chat_id = p_chat and link_id = p_link returning chat_id)
  delete from public.telegram_sessions s using gone where s.chat_id = gone.chat_id
$$;

create function public.telegram_set_topic_entity(p_link uuid, p_chat bigint, p_thread bigint, p_entity uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_access jsonb;
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
begin
  if not exists (select 1 from public.telegram_chats where chat_id = p_chat and link_id = p_link) then
    raise exception 'FORBIDDEN: this group is not registered by you' using errcode = 'insufficient_privilege';
  end if;
  perform app_private.telegram_act_as(p_link);
  v_access := public.my_access();
  if not app_private.telegram_has(v_access, p_entity, 'bills.create') then
    raise exception 'FORBIDDEN: missing bills.create' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_thread, 0) = 0 then
    update public.telegram_chats set default_entity_id = p_entity where chat_id = p_chat;
  else
    insert into public.telegram_chat_topics (chat_id, thread_id, entity_id) values (p_chat, p_thread, p_entity)
    on conflict (chat_id, thread_id) do update set entity_id = excluded.entity_id;
  end if;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
end
$$;

-- Who gets a scheduled report. kind: daily | weekly | monthly.
create function public.telegram_report_targets(p_kind text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if p_kind not in ('daily', 'weekly', 'monthly') then
    raise exception 'INVALID: unknown report kind' using errcode = 'invalid_parameter_value';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('link_id', l.id, 'chat_id', l.telegram_chat_id::text, 'user_id', l.user_id))
    from public.telegram_links l
    where l.status = 'active'
      and case p_kind when 'daily' then l.report_daily when 'weekly' then l.report_weekly else l.report_monthly end
      and exists (select 1 from public.profiles p where p.id = l.user_id and p.is_active)), '[]'::jsonb);
end
$$;

-- Housekeeping, run by the daily job.
create function public.telegram_cleanup() returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_sessions integer;
  v_updates integer;
  v_codes integer;
begin
  delete from public.telegram_sessions where expires_at < now();
  get diagnostics v_sessions = row_count;
  delete from public.telegram_updates where received_at < now() - interval '7 days';
  get diagnostics v_updates = row_count;
  delete from public.telegram_link_codes where expires_at < now() - interval '1 day';
  get diagnostics v_codes = row_count;
  return jsonb_build_object('sessions', v_sessions, 'updates', v_updates, 'codes', v_codes);
end
$$;

-- ------------------------------------------------------------ privileges
revoke all on function app_private.telegram_act_as(uuid) from public;
revoke all on function app_private.telegram_restore_claims(text, text) from public;
revoke all on function app_private.telegram_has(jsonb, uuid, text) from public;

revoke all on function public.create_telegram_link_code() from public, anon;
revoke all on function public.my_telegram_link() from public, anon;
revoke all on function public.revoke_telegram_link() from public, anon;
revoke all on function public.update_telegram_settings(numeric, boolean, boolean, boolean, uuid) from public, anon;
grant execute on function public.create_telegram_link_code() to authenticated;
grant execute on function public.my_telegram_link() to authenticated;
grant execute on function public.revoke_telegram_link() to authenticated;
grant execute on function public.update_telegram_settings(numeric, boolean, boolean, boolean, uuid) to authenticated;

revoke all on function public.telegram_claim_update(bigint) from public, anon, authenticated;
revoke all on function public.telegram_redeem_code(text, bigint, bigint, text) from public, anon, authenticated;
revoke all on function public.telegram_identify(bigint, bigint, bigint) from public, anon, authenticated;
revoke all on function public.telegram_context(uuid) from public, anon, authenticated;
revoke all on function public.telegram_record_expense(uuid, text, uuid, uuid, date, jsonb, uuid, text, text, boolean, uuid) from public, anon, authenticated;
revoke all on function public.telegram_recent_entries(uuid, integer) from public, anon, authenticated;
revoke all on function public.telegram_undo_entry(uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.telegram_summary(uuid, uuid, date, date) from public, anon, authenticated;
revoke all on function public.telegram_session_get(uuid, bigint, bigint) from public, anon, authenticated;
revoke all on function public.telegram_session_put(uuid, bigint, bigint, jsonb, integer) from public, anon, authenticated;
revoke all on function public.telegram_session_clear(uuid, bigint, bigint) from public, anon, authenticated;
revoke all on function public.telegram_learn(uuid, uuid, text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.telegram_set_prefs(uuid, boolean, boolean, boolean, uuid) from public, anon, authenticated;
revoke all on function public.telegram_register_chat(uuid, bigint, text, text) from public, anon, authenticated;
revoke all on function public.telegram_unregister_chat(uuid, bigint) from public, anon, authenticated;
revoke all on function public.telegram_set_topic_entity(uuid, bigint, bigint, uuid) from public, anon, authenticated;
revoke all on function public.telegram_report_targets(text) from public, anon, authenticated;
revoke all on function public.telegram_cleanup() from public, anon, authenticated;

grant execute on function public.telegram_claim_update(bigint) to service_role;
grant execute on function public.telegram_redeem_code(text, bigint, bigint, text) to service_role;
grant execute on function public.telegram_identify(bigint, bigint, bigint) to service_role;
grant execute on function public.telegram_context(uuid) to service_role;
grant execute on function public.telegram_record_expense(uuid, text, uuid, uuid, date, jsonb, uuid, text, text, boolean, uuid) to service_role;
grant execute on function public.telegram_recent_entries(uuid, integer) to service_role;
grant execute on function public.telegram_undo_entry(uuid, text, uuid) to service_role;
grant execute on function public.telegram_summary(uuid, uuid, date, date) to service_role;
grant execute on function public.telegram_session_get(uuid, bigint, bigint) to service_role;
grant execute on function public.telegram_session_put(uuid, bigint, bigint, jsonb, integer) to service_role;
grant execute on function public.telegram_session_clear(uuid, bigint, bigint) to service_role;
grant execute on function public.telegram_learn(uuid, uuid, text, uuid, uuid, text) to service_role;
grant execute on function public.telegram_set_prefs(uuid, boolean, boolean, boolean, uuid) to service_role;
grant execute on function public.telegram_register_chat(uuid, bigint, text, text) to service_role;
grant execute on function public.telegram_unregister_chat(uuid, bigint) to service_role;
grant execute on function public.telegram_set_topic_entity(uuid, bigint, bigint, uuid) to service_role;
grant execute on function public.telegram_report_targets(text) to service_role;
grant execute on function public.telegram_cleanup() to service_role;
