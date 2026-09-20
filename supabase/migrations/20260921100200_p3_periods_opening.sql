-- P3 (Step 15 §7): accounting period controls and the opening-balance workflow.
-- Authority: Step 04 §12 (period closing), Step 03 §9 (opening/closing/earnings), Step 08 §14 (period and
-- date integrity), Step 15 §24 (data migration / opening strategy), Step 06 §8 (step-up for Reopen).
--
-- Period lifecycle (guarded by tg_period_guard from P1):
--   open -> closing_review -> closed -> reopened -> closing_review | closed;   closing_review -> open
-- Postings are accepted only while a period is open or reopened, so entering review already stops new
-- postings and a Close can never miss a journal that was on its way (finalize_post share-locks the period).

-- ------------------------------------------------------------ closing validation
-- Blockers prevent Close; warnings are shown but do not. Later phases (reconciliation, sub-ledgers, tax)
-- register their own checks here by extending this function - the Close command itself does not change.
create function app_private.period_blockers(p_period uuid)
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
end
$$;

-- ------------------------------------------------------------ period commands
create function public.period_close_checks(p_period uuid)
returns table (code text, severity text, message text, item_count bigint)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select entity_id into v_entity from public.accounting_periods where id = p_period;
  if v_entity is null or not app_authz.has_permission(v_entity, 'accounting.view') then
    raise exception 'FORBIDDEN: missing accounting.view' using errcode = 'insufficient_privilege';
  end if;
  return query select * from app_private.period_blockers(p_period);
end
$$;

-- Locks and returns a period the caller may close (periods.close) in its own Entity.
create function app_private.lock_period_for(p_period uuid, p_permission text)
returns public.accounting_periods
language plpgsql as $$
declare
  v_p public.accounting_periods%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_p from public.accounting_periods where id = p_period;
  -- Same answer for "unknown" and "not allowed": no existence leak across Entities.
  if not found or not app_authz.has_permission(v_p.entity_id, p_permission) then
    raise exception 'FORBIDDEN: missing %', p_permission using errcode = 'insufficient_privilege';
  end if;
  -- Lock only after the caller is known to be entitled to this period.
  select * into v_p from public.accounting_periods where id = p_period for update;
  return v_p;
end
$$;

create function public.begin_period_close(p_period uuid) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_p public.accounting_periods%rowtype := app_private.lock_period_for(p_period, 'periods.close');
begin
  if v_p.status not in ('open', 'reopened') then
    raise exception 'CONFLICT: only an open or reopened period can enter closing review (now %)', v_p.status
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.accounting_periods set status = 'closing_review' where id = p_period;
  return 'closing_review';
end
$$;

create function public.cancel_period_close(p_period uuid) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_p public.accounting_periods%rowtype := app_private.lock_period_for(p_period, 'periods.close');
begin
  if v_p.status <> 'closing_review' then
    raise exception 'CONFLICT: the period is not in closing review (now %)', v_p.status
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.accounting_periods set status = 'open' where id = p_period;
  return 'open';
end
$$;

create function public.close_period(p_period uuid) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_p public.accounting_periods%rowtype := app_private.lock_period_for(p_period, 'periods.close');
  v_blockers text;
begin
  if v_p.status <> 'closing_review' then
    raise exception 'CONFLICT: the period must be in closing review before it can be closed (now %)', v_p.status
      using errcode = 'integrity_constraint_violation';
  end if;
  select string_agg(format('%s (%s)', b.code, b.item_count), ', ') into v_blockers
  from app_private.period_blockers(p_period) b where b.severity = 'blocker';
  if v_blockers is not null then
    raise exception 'CONFLICT: closing is blocked: %', v_blockers using errcode = 'integrity_constraint_violation';
  end if;
  update public.accounting_periods set status = 'closed' where id = p_period;
  return 'closed';
end
$$;

-- Reopen is OWNER-level (periods.reopen), needs a recent step-up and a written reason (Step 04 §12, Step 06 §8).
create function public.reopen_period(p_period uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_p public.accounting_periods%rowtype := app_private.lock_period_for(p_period, 'periods.reopen');
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 10 then
    raise exception 'INVALID: a reopen reason of at least 10 characters is mandatory' using errcode = 'invalid_parameter_value';
  end if;
  if v_p.status <> 'closed' then
    raise exception 'CONFLICT: only a closed period can be reopened (now %)', v_p.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.accounting_periods set status = 'reopened', reopen_reason = v_reason where id = p_period;
  return 'reopened';
end
$$;

-- ------------------------------------------------------------ opening-balance workflow (Step 03 §9)
-- A batch is one controlled opening journal dated on the cutover date. Supplied lines may only touch balance
-- sheet accounts - opening balances never appear as current-period revenue or expense. Whatever the lines do
-- not balance is posted against the Opening Balance / Migration Clearing account (OPENING_BALANCE_CLEARING),
-- so an incomplete migration is visible as a non-zero clearing balance. Completing the migration requires
-- that balance to be zero, or a written migration adjustment note; after completion no further opening
-- batch is accepted (later corrections go through ordinary adjusting journals).
create table public.opening_balance_batches (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  cutover_date date not null,
  status text not null default 'posted' check (status in ('posted', 'completed')),
  note text,
  clearing_residual numeric(20, 4),
  completion_note text,
  completed_at timestamptz,
  completed_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  constraint opening_batch_completion_consistent check (
    (status = 'completed') = (completed_at is not null and clearing_residual is not null))
);
create index opening_balance_batches_entity_idx on public.opening_balance_batches (entity_id, cutover_date);
create trigger tg_forbid_delete before delete on public.opening_balance_batches
  for each row execute function app_private.tg_forbid_delete();
call app_private.apply_standard_triggers('public.opening_balance_batches');
call app_private.secure_table('public.opening_balance_batches');
create trigger tg_audit after insert or update or delete on public.opening_balance_batches
  for each row execute function app_private.tg_audit('entity_id');
call app_private.expose_select('public.opening_balance_batches');
create policy opening_balance_batches_select on public.opening_balance_batches for select to authenticated
  using (app_authz.has_permission(entity_id, 'accounting.view'));

-- Balance of the clearing account over posted journals (debit minus credit).
create function app_private.clearing_balance(p_entity uuid) returns numeric
language sql stable as $$
  select coalesce(sum(l.debit - l.credit), 0)
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and j.status = 'posted' and a.system_key = 'OPENING_BALANCE_CLEARING'
$$;

create function public.post_opening_balances(
  p_entity uuid, p_key text, p_cutover date, p_lines jsonb, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_replay uuid;
  v_diff numeric;
  v_lines jsonb;
  v_batch uuid := gen_random_uuid();
  v_bad text;
  v_clearing_lines integer;
  v_expected_clearing integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'system.import') then
    raise exception 'FORBIDDEN: missing system.import' using errcode = 'insufficient_privilege';
  end if;
  perform app_private.assert_business_date(p_cutover);
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) < 1 then
    raise exception 'INVALID: opening lines are required' using errcode = 'invalid_parameter_value';
  end if;

  v_replay := app_private.idem_begin('opening.post', p_entity, p_key,
    md5(jsonb_build_object('cutover', p_cutover, 'lines', p_lines, 'note', v_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;

  -- Opening postings and completion of one Entity never run at the same time.
  perform pg_advisory_xact_lock(hashtextextended('opening:' || p_entity::text, 0));
  if exists (select 1 from public.opening_balance_batches where entity_id = p_entity and status = 'completed') then
    raise exception 'CONFLICT: the opening balances of this Entity are already completed' using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_period_postable(p_entity, p_cutover);

  begin
    select coalesce(sum(coalesce(nullif(l ->> 'debit', '')::numeric, 0) - coalesce(nullif(l ->> 'credit', '')::numeric, 0)), 0)
      into v_diff
    from jsonb_array_elements(p_lines) l;
  exception when invalid_text_representation or numeric_value_out_of_range or invalid_parameter_value then
    raise exception 'INVALID: opening line amounts must be plain numbers' using errcode = 'invalid_parameter_value';
  end;

  v_lines := p_lines;
  if v_diff <> 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_key', 'OPENING_BALANCE_CLEARING',
      'debit', case when v_diff < 0 then -v_diff else 0 end,
      'credit', case when v_diff > 0 then v_diff else 0 end,
      'description', 'Opening balance clearing'));
  end if;
  v_lines := app_private.normalise_lines(p_entity, v_lines);

  -- Only balance-sheet accounts (and the clearing account we add ourselves) may carry opening balances.
  select string_agg(distinct a.code, ', ') into v_bad
  from jsonb_array_elements(v_lines) l
  join public.ledger_accounts a on a.id = (l ->> 'account_id')::uuid
  where a.account_class not in ('asset', 'contra_asset', 'liability', 'equity')
    and a.system_key is distinct from 'OPENING_BALANCE_CLEARING';
  if v_bad is not null then
    raise exception 'INVALID: opening balances may only use balance-sheet accounts (not %)', v_bad
      using errcode = 'invalid_parameter_value';
  end if;
  -- The clearing account is maintained by the workflow. Judged on the normalised lines, so no spelling of an
  -- identifier (case, braces, ...) can smuggle it in: it may appear exactly once, and only as our own line.
  select count(*) into v_clearing_lines
  from jsonb_array_elements(v_lines) l
  join public.ledger_accounts a on a.id = (l ->> 'account_id')::uuid
  where a.system_key = 'OPENING_BALANCE_CLEARING';
  v_expected_clearing := case when v_diff <> 0 then 1 else 0 end;
  if v_clearing_lines <> v_expected_clearing then
    raise exception 'INVALID: the clearing account is maintained by the workflow and cannot be entered directly'
      using errcode = 'invalid_parameter_value';
  end if;

  insert into public.opening_balance_batches (id, entity_id, cutover_date, note)
  values (v_batch, p_entity, p_cutover, v_note);

  perform app_private.post_system_journal(
    p_entity, 'opening_balance', v_batch, 'opening.v1', 'opening.v1', p_cutover,
    coalesce(v_note, 'Opening balances at ' || p_cutover::text), v_lines, 'opening');

  perform app_private.idem_complete('opening.post', p_entity, p_key, 'opening_balance_batches', v_batch);
  return v_batch;
end
$$;

create function public.complete_opening_balances(p_entity uuid, p_note text default null) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_residual numeric;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'system.import') then
    raise exception 'FORBIDDEN: missing system.import' using errcode = 'insufficient_privilege';
  end if;
  -- Serialise with concurrent opening postings for the same Entity.
  perform pg_advisory_xact_lock(hashtextextended('opening:' || p_entity::text, 0));
  if not exists (select 1 from public.opening_balance_batches where entity_id = p_entity and status = 'posted') then
    raise exception 'CONFLICT: there are no opening balances waiting to be completed' using errcode = 'integrity_constraint_violation';
  end if;

  v_residual := app_private.clearing_balance(p_entity);
  if v_residual <> 0 and (v_note is null or length(v_note) < 10) then
    raise exception 'INVALID: the clearing account is not zero (%); reconcile it or document the migration adjustment (at least 10 characters)', v_residual
      using errcode = 'invalid_parameter_value';
  end if;

  perform set_config('app.audit_reason', coalesce(v_note, 'Opening balances completed with zero clearing balance'), true);
  update public.opening_balance_batches
  set status = 'completed', clearing_residual = v_residual, completion_note = v_note,
      completed_at = now(), completed_by = auth.uid()
  where entity_id = p_entity and status = 'posted';
  return v_residual::text;   -- exact decimal text (Step 13 §25)
end
$$;

-- ------------------------------------------------------------ privileges
revoke all on function app_private.period_blockers(uuid) from public;
revoke all on function app_private.lock_period_for(uuid, text) from public;
revoke all on function app_private.clearing_balance(uuid) from public;

revoke all on function public.period_close_checks(uuid) from public, anon;
revoke all on function public.begin_period_close(uuid) from public, anon;
revoke all on function public.cancel_period_close(uuid) from public, anon;
revoke all on function public.close_period(uuid) from public, anon;
revoke all on function public.reopen_period(uuid, text) from public, anon;
revoke all on function public.post_opening_balances(uuid, text, date, jsonb, text) from public, anon;
revoke all on function public.complete_opening_balances(uuid, text) from public, anon;
grant execute on function public.period_close_checks(uuid) to authenticated;
grant execute on function public.begin_period_close(uuid) to authenticated;
grant execute on function public.cancel_period_close(uuid) to authenticated;
grant execute on function public.close_period(uuid) to authenticated;
grant execute on function public.reopen_period(uuid, text) to authenticated;
grant execute on function public.post_opening_balances(uuid, text, date, jsonb, text) to authenticated;
grant execute on function public.complete_opening_balances(uuid, text) to authenticated;
