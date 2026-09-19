-- P1 (Step 15 §5): audit metadata infrastructure, idempotency records and the transactional outbox.
-- Authority: Step 02 §4 (Documents/Notifications/Audit), Step 06 §13, Step 08 §3/§17,
-- Step 13 §9 (idempotency), §14 (outbox), §19 (audit vs logs).

-- ------------------------------------------------------------ audit trail (append-only)
create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  entity_id uuid references public.entities (id) on delete restrict,
  actor_type text not null default 'user' check (actor_type in ('user', 'system', 'public_token')),
  actor_id uuid,
  action text not null check (length(action) > 0),
  target_table text not null,
  target_id uuid,
  before_state jsonb,
  after_state jsonb,
  reason text,
  correlation_id text,
  ip_address inet,
  user_agent text
);
create index audit_events_entity_time_idx on public.audit_events (entity_id, occurred_at desc);
create index audit_events_target_idx on public.audit_events (target_table, target_id);
create trigger tg_forbid_update before update on public.audit_events
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.audit_events
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.audit_events
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.audit_events');

-- ------------------------------------------------------------ idempotency records (Step 13 §9)
-- One namespace per operation scope (never a single global key space). A retry with the same
-- (scope, entity, key) finds the existing row and returns its recorded result.
create table public.idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope ~ '^[a-z][a-z0-9_.]{2,80}$'),
  entity_id uuid references public.entities (id) on delete restrict,
  key text not null check (length(key) between 8 and 200),
  actor_id uuid,
  request_fingerprint text,
  status text not null default 'in_progress' check (status in ('in_progress', 'succeeded', 'failed')),
  result_table text,
  result_id uuid,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  expires_at timestamptz,
  constraint idempotency_result_consistency check (
    status <> 'succeeded'
    or (result_id is not null and result_table is not null and completed_at is not null)
  ),
  unique nulls not distinct (scope, entity_id, key)
);
create trigger tg_lock_entity before update on public.idempotency_keys
  for each row execute function app_private.tg_lock_entity();
call app_private.secure_table('public.idempotency_keys');

-- ------------------------------------------------------------ transactional outbox (Step 13 §14)
create table public.outbox_events (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid references public.entities (id) on delete restrict,
  event_type text not null check (event_type ~ '^[A-Za-z][A-Za-z0-9_.]{2,80}$'),
  aggregate_type text,
  aggregate_id uuid,
  payload jsonb not null default '{}'::jsonb,
  correlation_id text,
  status text not null default 'pending' check (status in ('pending', 'processing', 'processed', 'failed', 'dead')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  constraint outbox_processed_consistency check ((status = 'processed') = (processed_at is not null))
);
create index outbox_events_due_idx on public.outbox_events (next_attempt_at) where status in ('pending', 'failed');
create trigger tg_lock_entity before update on public.outbox_events
  for each row execute function app_private.tg_lock_entity();
call app_private.secure_table('public.outbox_events');

-- ------------------------------------------------------------ audit triggers on P1 tables so far
create trigger tg_audit after insert or update or delete on public.entities
  for each row execute function app_private.tg_audit('id');
create trigger tg_audit after insert or update or delete on public.entity_profiles
  for each row execute function app_private.tg_audit('entity_id');
create trigger tg_audit after insert or update or delete on public.entity_settings
  for each row execute function app_private.tg_audit('entity_id');
create trigger tg_audit after insert or update or delete on public.profiles
  for each row execute function app_private.tg_audit('');
create trigger tg_audit after insert or update or delete on public.roles
  for each row execute function app_private.tg_audit('');
create trigger tg_audit after insert or update or delete on public.role_permissions
  for each row execute function app_private.tg_audit('');
create trigger tg_audit after insert or update or delete on public.entity_memberships
  for each row execute function app_private.tg_audit('entity_id');
create trigger tg_audit after insert or update or delete on public.membership_permission_overrides
  for each row execute function app_private.tg_audit('');
create trigger tg_audit after insert or update or delete on public.approval_rules
  for each row execute function app_private.tg_audit('entity_id');
-- Device fingerprints are never copied into the audit trail.
create trigger tg_audit after insert or update or delete on public.trusted_devices
  for each row execute function app_private.tg_audit('', 'fingerprint_hash');
