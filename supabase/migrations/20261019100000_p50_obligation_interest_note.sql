-- Decision 377: ordinary interest on settling a Piutang Lain / Utang Lain needs no note (as for loans, decision 376).
-- Only a fee or penalty still needs a note that explains it. The rest of the function is unchanged.
create or replace function public.obligation_settle(
  p_obligation uuid, p_key text, p_date date, p_account uuid, p_principal text, p_interest text default '0',
  p_fee text default '0', p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  o public.other_obligations%rowtype;
  fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_scale integer;
  v_principal numeric;
  v_interest numeric;
  v_fee numeric;
  v_outstanding numeric;
  v_last date;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_total numeric;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into o from public.other_obligations where id = p_obligation;
  if not found or not app_authz.has_permission(o.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: settling an obligation needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('obligation.settle', o.entity_id, p_key,
    md5(jsonb_build_object('o', p_obligation, 'd', p_date, 'a', p_account, 'p', p_principal, 'i', p_interest,
                           'f', p_fee, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('obligation:' || o.id::text, 0));
  select * into o from public.other_obligations where id = p_obligation for update;
  if o.status <> 'open' then
    raise exception 'CONFLICT: only an open obligation can be settled (now %)', o.status using errcode = 'integrity_constraint_violation';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(o.entity_id));
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(o.entity_id) then
    raise exception 'INVALID: a settlement cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_date < o.obligation_date then
    raise exception 'INVALID: a settlement cannot be dated before the obligation (%)', o.obligation_date
      using errcode = 'invalid_parameter_value';
  end if;
  -- Dated on or after every earlier settlement and reversal, so the outstanding amount is right on every day.
  select greatest(coalesce(max(s.settlement_date), o.obligation_date), coalesce(max(s.reversed_date), o.obligation_date))
    into v_last from public.other_obligation_settlements s where s.obligation_id = o.id;
  if p_date < v_last then
    raise exception 'INVALID: the date cannot be before the last settlement activity on this obligation (%)', v_last
      using errcode = 'invalid_parameter_value';
  end if;
  v_principal := app_private.money_arg(p_principal, 'the principal settled', v_scale);
  v_interest := app_private.money_arg(coalesce(nullif(btrim(p_interest), ''), '0'), 'the interest', v_scale, true);
  v_fee := app_private.money_arg(coalesce(nullif(btrim(p_fee), ''), '0'), 'the fee', v_scale, true);
  v_outstanding := app_private.obligation_outstanding(o.id);
  if v_principal > v_outstanding then
    raise exception 'INVALID: % is outstanding; the principal settled cannot exceed it', trim_scale(v_outstanding)
      using errcode = 'invalid_parameter_value';
  end if;
  if v_fee > 0 and length(coalesce(v_note, '')) < 5 then
    raise exception 'INVALID: a fee or penalty needs a note that explains it' using errcode = 'invalid_parameter_value';
  end if;
  v_total := v_principal + v_interest + v_fee;
  perform app_private.assert_maker_checker(o.entity_id, 'obligations', 'settle', v_total, auth.uid(), 'record this settlement');
  fa := app_private.base_cash_account(o.entity_id, p_account);

  perform app_private.ensure_obligation_numbering(o.entity_id);
  v_number := app_private.allocate_document_number(o.entity_id, 'obligation_settlement', p_date);
  v_desc := format('Settlement %s - %s %s', v_number, o.obligation_number, left(o.counterparty_name, 80));
  if o.kind = 'receivable' then
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', v_total, 'credit', 0, 'description', v_desc);
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_receivable'),
                                             'debit', 0, 'credit', v_principal, 'description', v_desc);
    if v_interest > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'interest_income'),
                                               'debit', 0, 'credit', v_interest, 'description', 'Interest: ' || v_desc);
    end if;
    if v_fee > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_income'),
                                               'debit', 0, 'credit', v_fee, 'description', 'Fee: ' || v_desc);
    end if;
  else
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_payable'),
                                             'debit', v_principal, 'credit', 0, 'description', v_desc);
    if v_interest > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'interest_expense'),
                                               'debit', v_interest, 'credit', 0, 'description', 'Interest: ' || v_desc);
    end if;
    if v_fee > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(o.entity_id, 'other_expense'),
                                               'debit', v_fee, 'credit', 0, 'description', 'Fee: ' || v_desc);
    end if;
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', v_total, 'description', v_desc);
  end if;
  perform 1 from public.financial_accounts where id = p_account and entity_id = o.entity_id for no key update;
  v_journal := app_private.post_system_journal(o.entity_id, 'obligation_settlement', v_id, 'obligation.settle',
    'obligation.v1', p_date, v_desc, v_lines);
  perform app_private.record_movement(o.entity_id, p_account, case o.kind when 'receivable' then 'in' else 'out' end,
    v_total, v_total, null, p_date, 'obligation_settlement', v_id, 'principal', v_journal, v_desc);
  insert into public.other_obligation_settlements
    (id, entity_id, obligation_id, settlement_number, kind, settlement_date, principal, interest, fee, financial_account_id,
     note, tax_status, journal_id, created_by)
  values
    (v_id, o.entity_id, o.id, v_number, 'cash', p_date, v_principal, v_interest, v_fee, p_account, v_note,
     case when v_interest > 0 then 'needs_review' else 'not_applicable' end, v_journal, auth.uid());
  if v_principal = v_outstanding then
    update public.other_obligations set status = 'settled' where id = o.id;
  end if;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (o.entity_id, 'ObligationSettled', 'other_obligation', o.id,
          jsonb_build_object('number', o.obligation_number, 'settlement', v_number));
  perform app_private.idem_complete('obligation.settle', o.entity_id, p_key, 'other_obligation_settlements', v_id);
  return v_id;
end
$$;
