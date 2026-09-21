-- P8 part 3c (Step 12 §11, Step 09 §16): the Loan Register readers - list, detail, schedule, what is due, and the loan
-- summary. Every amount is exact decimal text. All of them need loans.view.

create function public.loan_list(
  p_entity uuid, p_direction text default null, p_status text default null, p_limit integer default 100)
returns table (loan_id uuid, loan_number text, direction text, status text, counterparty_name text, purpose text,
               principal text, outstanding text, rate text, maturity_date date, next_due_date date, next_due_amount text,
               overdue_amount text, overdue boolean, term_class text, asset_id uuid, related_entity_id uuid, source_type text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'loans.view') then
    raise exception 'FORBIDDEN: missing loans.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select l.id, l.loan_number, l.direction, l.status, l.counterparty_name, l.purpose, l.principal::text,
         app_private.loan_outstanding(l.id)::text, v.rate::text, v.maturity_date,
         nx.due_date, nx.remaining::text, coalesce(od.remaining, 0)::text, coalesce(od.remaining, 0) > 0,
         l.term_class, l.asset_id, l.related_entity_id, l.source_type
  from public.loans l
  left join public.loan_schedule_versions v on v.loan_id = l.id and v.status = 'active'
  left join lateral (
    select i.due_date, (i.principal_due - i.paid_principal + i.interest_due - i.paid_interest + i.fee_due - i.paid_fee) as remaining
    from app_private.loan_items(l.id) i where i.state <> 'paid' order by i.seq limit 1) nx on l.status = 'active'
  left join lateral (
    select sum(i.principal_due - i.paid_principal + i.interest_due - i.paid_interest + i.fee_due - i.paid_fee) as remaining
    from app_private.loan_items(l.id) i where i.overdue) od on l.status = 'active'
  where l.entity_id = p_entity and (p_direction is null or l.direction = p_direction) and (p_status is null or l.status = p_status)
  order by l.agreement_date desc, l.loan_number desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end
$$;

create function public.loan_schedule(p_loan uuid, p_version integer default null)
returns table (version_no integer, seq integer, due_date date, principal_due text, interest_due text, fee_due text,
               paid_principal text, paid_interest text, paid_fee text, outstanding text, state text, overdue boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  v public.loan_schedule_versions%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.view') then
    raise exception 'FORBIDDEN: missing loans.view' using errcode = 'insufficient_privilege';
  end if;
  select * into v from public.loan_schedule_versions x
  where x.loan_id = l.id and ((p_version is null and x.status in ('active', 'draft')) or x.version_no = p_version)
  order by x.version_no desc limit 1;
  if not found then
    return;
  end if;
  return query
  select v.version_no, i.seq, i.due_date, i.principal_due::text, i.interest_due::text, i.fee_due::text, i.paid_principal::text,
         i.paid_interest::text, i.paid_fee::text,
         (i.principal_due - i.paid_principal + i.interest_due - i.paid_interest + i.fee_due - i.paid_fee)::text, i.state, i.overdue
  from app_private.loan_items(l.id, v.id, null) i
  order by i.seq;
end
$$;

create function public.loan_detail(p_loan uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.view') then
    raise exception 'FORBIDDEN: missing loans.view' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'id', l.id, 'number', l.loan_number, 'direction', l.direction, 'status', l.status,
    'counterparty', l.counterparty_name, 'contact_id', l.contact_id, 'purpose', l.purpose,
    'principal', l.principal::text, 'funded_principal', l.funded_principal::text,
    'outstanding', app_private.loan_outstanding(l.id)::text, 'source_type', l.source_type,
    'agreement_date', l.agreement_date, 'effective_date', l.effective_date, 'closed_date', l.closed_date,
    'term_class', l.term_class, 'principal_account_id', l.principal_account_id,
    'financial_account_id', l.financial_account_id, 'proceeds_journal_id', l.proceeds_journal_id,
    'asset_id', l.asset_id, 'related_entity_id', l.related_entity_id, 'relationship_basis', l.relationship_basis,
    'cancel_reason', l.cancel_reason,
    'versions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id, 'version_no', v.version_no, 'status', v.status, 'method', v.method, 'rate', v.rate::text,
        'installments', v.installments, 'step_months', v.step_months, 'effective_from', v.effective_from,
        'principal_basis', v.principal_basis::text, 'maturity_date', v.maturity_date, 'reason', v.reason)
        order by v.version_no) from public.loan_schedule_versions v where v.loan_id = l.id), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'number', p.payment_number, 'kind', p.kind, 'status', p.status, 'date', p.payment_date,
        'principal', p.principal::text, 'interest', p.interest::text, 'fee', p.fee::text, 'tax_status', p.tax_status,
        'journal_id', p.journal_id, 'reversal_journal_id', p.reversal_journal_id, 'note', p.note,
        'schedule_version_id', p.schedule_version_id,
        'allocations', coalesce((
          select jsonb_agg(jsonb_build_object('item_id', a.item_id, 'seq', i.seq, 'principal', a.principal::text,
                                              'interest', a.interest::text, 'fee', a.fee::text) order by i.seq nulls last)
          from public.loan_payment_allocations a
          left join public.loan_schedule_items i on i.id = a.item_id and i.entity_id = a.entity_id
          where a.payment_id = p.id), '[]'::jsonb))
        order by p.payment_date, p.payment_number)
      from public.loan_payments p where p.loan_id = l.id), '[]'::jsonb));
end
$$;

-- Installments falling due (or overdue) across the active loans, borrowed and lent, up to a date.
create function public.loan_due(p_entity uuid, p_through date default null)
returns table (loan_id uuid, loan_number text, direction text, counterparty_name text, seq integer, due_date date,
               principal_outstanding text, interest_outstanding text, fee_outstanding text, state text, overdue boolean,
               days_overdue integer)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_today date := app_private.entity_today(p_entity);
  v_through date := coalesce(p_through, app_private.entity_today(p_entity) + 30);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'loans.view') then
    raise exception 'FORBIDDEN: missing loans.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select l.id, l.loan_number, l.direction, l.counterparty_name, i.seq, i.due_date,
         greatest(i.principal_due - i.paid_principal, 0)::text, greatest(i.interest_due - i.paid_interest, 0)::text,
         greatest(i.fee_due - i.paid_fee, 0)::text, i.state, i.overdue,
         case when i.overdue then v_today - i.due_date else 0 end
  from public.loans l
  cross join lateral app_private.loan_items(l.id) i
  where l.entity_id = p_entity and l.status = 'active' and i.state <> 'paid' and i.due_date <= v_through
  order by i.due_date, l.loan_number, i.seq;
end
$$;

-- Step 12 §11: opening principal, proceeds, principal repaid, closing principal, interest and fees paid - per loan.
create function public.loan_summary(p_entity uuid, p_from date, p_to date)
returns table (loan_id uuid, loan_number text, direction text, counterparty_name text, opening_principal text, proceeds text,
               principal_repaid text, principal_written_off text, closing_principal text, interest_paid text, fees_paid text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'loans.view') then
    raise exception 'FORBIDDEN: missing loans.view' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID: give a period (from, to)' using errcode = 'invalid_parameter_value';
  end if;
  return query
  select l.id, l.loan_number, l.direction, l.counterparty_name,
         app_private.loan_outstanding(l.id, p_from - 1)::text,
         (case when l.source_type = 'proceeds' and l.effective_date between p_from and p_to then l.funded_principal else 0 end)::text,
         coalesce(x.repaid, 0)::text, coalesce(x.written_off, 0)::text,
         app_private.loan_outstanding(l.id, p_to)::text, coalesce(x.interest, 0)::text, coalesce(x.fees, 0)::text
  from public.loans l
  left join lateral (
    select sum(p.principal) filter (where p.kind = 'repayment') as repaid,
           sum(p.principal) filter (where p.kind = 'write_off') as written_off,
           sum(p.interest) as interest, sum(p.fee) as fees
    from public.loan_payments p
    where p.loan_id = l.id and p.payment_date between p_from and p_to and (p.status = 'active' or p.reversed_date > p_to)) x on true
  where l.entity_id = p_entity and l.status in ('active', 'closed') and l.effective_date <= p_to
  order by l.loan_number;
end
$$;

revoke all on function public.loan_list(uuid, text, text, integer) from public, anon;
revoke all on function public.loan_schedule(uuid, integer) from public, anon;
revoke all on function public.loan_detail(uuid) from public, anon;
revoke all on function public.loan_due(uuid, date) from public, anon;
revoke all on function public.loan_summary(uuid, date, date) from public, anon;
grant execute on function public.loan_list(uuid, text, text, integer) to authenticated;
grant execute on function public.loan_schedule(uuid, integer) to authenticated;
grant execute on function public.loan_detail(uuid) to authenticated;
grant execute on function public.loan_due(uuid, date) to authenticated;
grant execute on function public.loan_summary(uuid, date, date) to authenticated;
