-- Decision 405 (OWNER, 11 October 2026): Penyesuaian Lanjutan gets a list of what was recorded, and a way
-- to undo one.
--
-- "harus punya list apa saja yang telah di buat, dan harus punya hapus atau batalkan. karena bisa saja ada
-- kesalahan disitu." The screen was a form and nothing else: an adjustment, once recorded, could not be
-- seen again from there and could not be undone at all. Every other money command in P4 has a reversal
-- (`reverse_transfer`, `reverse_refund`, `reverse_payment`); the balance adjustment was the one that did
-- not, which is the wrong way round -- it is the command most likely to be used by mistake, being the one
-- for correcting mistakes.
--
-- Not a delete. A posted journal is never removed from the books (Step 03 §9); the reversal posts the
-- opposite journal and the opposite movement, and both the original and the reversal stay visible. That is
-- also why the list shows a reversed adjustment rather than hiding it.
--
-- The reversal is dated the ORIGINAL adjustment's date, not today. That is the whole point of this slice:
-- on 11 October 2026 a reversal taken on a 23 September entry landed in October and put a cash outflow in
-- a month where nothing had happened, which is how the OWNER found the gap. If that period is closed the
-- posting engine refuses, as it should, and the message says so -- better than silently moving the money
-- into a month it never left.

-- ------------------------------------------------------------ the list
-- Every adjustment of the Entity, newest first: what it did, why, and whether it still stands.
create function public.balance_adjustment_list(p_entity uuid, p_limit integer default 100)
returns table (
  adjustment_id uuid, movement_date date, account_id uuid, account_name text, direction text,
  amount text, currency text, base_amount text, counter_code text, counter_name text, reason text,
  journal_id uuid, journal_number text, status text, reversed_by_journal_id uuid, created_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'money.view') then
    raise exception 'FORBIDDEN: missing money.view' using errcode = 'insufficient_privilege';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception 'INVALID: the limit must be 1 to 500' using errcode = 'invalid_parameter_value';
  end if;
  return query
  select m.source_id, m.movement_date, m.financial_account_id, fa.name, m.direction,
         trim_scale(m.amount)::text, m.currency::text, trim_scale(m.base_amount)::text,
         c.code, c.name, m.description, m.journal_id, j.journal_number,
         case when r.id is null then 'active' else 'reversed' end,
         r.journal_id, m.created_at
  from public.money_movements m
  join public.financial_accounts fa on fa.id = m.financial_account_id
  join public.journal_entries j on j.id = m.journal_id
  -- The counter account is the other side of the adjustment's own journal: the one line that is not the
  -- cash/bank account itself. An adjustment always posts exactly two lines, so there is exactly one.
  left join lateral (
    select la.code, la.name
    from public.journal_lines jl
    join public.ledger_accounts la on la.id = jl.ledger_account_id
    where jl.journal_id = m.journal_id and jl.ledger_account_id is distinct from fa.ledger_account_id
    limit 1
  ) c on true
  left join public.money_movements r
    on r.entity_id = m.entity_id and r.reverses_movement_id = m.id
  where m.entity_id = p_entity and m.source_type = 'money_adjustment' and m.reverses_movement_id is null
  order by m.movement_date desc, m.created_at desc
  limit p_limit;
end
$$;
revoke all on function public.balance_adjustment_list(uuid, integer) from public, anon;
grant execute on function public.balance_adjustment_list(uuid, integer) to authenticated;

-- ------------------------------------------------------------ the reversal
-- Undoes one adjustment: the opposite journal and the opposite movement, on the original's own date.
create function public.reverse_balance_adjustment(p_adjustment uuid, p_key text, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  m public.money_movements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into m from public.money_movements
  where source_type = 'money_adjustment' and source_id = p_adjustment and reverses_movement_id is null;
  if not found then
    raise exception 'NOT_FOUND: balance adjustment' using errcode = 'no_data_found';
  end if;
  -- Undoing an adjustment needs the right that makes one; seeing it needs only `money.view`.
  if not app_authz.has_permission(m.entity_id, 'money.adjust') then
    raise exception 'FORBIDDEN: missing money.adjust' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 5 then
    raise exception 'INVALID: a reversal needs a reason of at least 5 characters'
      using errcode = 'invalid_parameter_value';
  end if;

  v_replay := app_private.idem_begin('balance_adjustment.reverse', m.entity_id, p_key,
    md5(jsonb_build_object('adjustment', p_adjustment, 'reason', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;

  -- Re-read under the account lock, in the same order a transfer takes it, so the two cannot deadlock.
  perform 1 from public.financial_accounts
  where entity_id = m.entity_id and id = m.financial_account_id for no key update;
  select * into m from public.money_movements where id = m.id;
  if exists (select 1 from public.money_movements r
             where r.entity_id = m.entity_id and r.reverses_movement_id = m.id) then
    raise exception 'CONFLICT: this adjustment has already been reversed'
      using errcode = 'integrity_constraint_violation';
  end if;

  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(m.journal_id, m.movement_date, v_reason);
  perform app_private.record_movement(
    m.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
    m.amount, m.base_amount, m.exchange_rate, m.movement_date, 'money_adjustment', p_adjustment,
    'adjustment', v_rev, 'Reversal: ' || v_reason, m.id);

  perform app_private.idem_complete('balance_adjustment.reverse', m.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;
revoke all on function public.reverse_balance_adjustment(uuid, text, text) from public, anon;
grant execute on function public.reverse_balance_adjustment(uuid, text, text) to authenticated;
