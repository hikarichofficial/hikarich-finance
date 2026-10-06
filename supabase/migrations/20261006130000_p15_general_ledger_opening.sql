-- P15 decision 303 (finding #102): the General Ledger running balance carries the balance forward.
-- With a start date the running balance used to restart from zero at that date, so an account with history showed a
-- balance that was not the account's balance. The balance is now summed over every posted line up to the end date and
-- only then are the lines before the start date left out of the list: the first line of the range shows the real
-- balance, and the last line is the real closing balance. The columns, the order and the permission are unchanged.
create or replace function public.general_ledger(p_entity uuid, p_account uuid default null, p_start date default null, p_end date default null)
returns table (account_id uuid, code text, name text, entry_date date, journal_id uuid, journal_number text,
               entry_type text, description text, source_type text, source_id uuid,
               debit text, credit text, running_balance text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'reports.view') then
    raise exception 'FORBIDDEN: missing reports.view' using errcode = 'insufficient_privilege';
  end if;
  if p_account is not null and not exists (
    select 1 from public.ledger_accounts where id = p_account and entity_id = p_entity) then
    raise exception 'NOT_FOUND: unknown account of this Entity' using errcode = 'no_data_found';
  end if;

  return query
  with lines as (
    select a.id as acc_id, a.code as acc_code, a.name as acc_name, j.entry_date as j_date, j.created_at as j_created,
           l.line_no as j_line, j.id as j_id, j.journal_number as j_number, j.entry_type as j_type,
           j.description as j_desc, j.source_type as j_source_type, j.source_id as j_source_id,
           l.debit as l_debit, l.credit as l_credit,
           sum(case when a.normal_balance = 'debit' then l.debit - l.credit else l.credit - l.debit end)
             over (partition by a.id order by j.entry_date, j.created_at, l.line_no) as running
    from public.journal_lines l
    join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
    join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
    where l.entity_id = p_entity and j.status = 'posted'
      and (p_account is null or a.id = p_account)
      and (p_end is null or j.entry_date <= p_end)
  )
  select x.acc_id, x.acc_code, x.acc_name, x.j_date, x.j_id, x.j_number, x.j_type, x.j_desc,
         x.j_source_type, x.j_source_id, x.l_debit::text, x.l_credit::text, x.running::text
  from lines x
  where p_start is null or x.j_date >= p_start
  order by x.acc_code, x.j_date, x.j_created, x.j_line;
end
$$;
