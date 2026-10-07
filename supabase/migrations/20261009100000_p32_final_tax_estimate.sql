-- P32 (decision 342, owner request): the running month's PPh Final UMKM is shown as an ESTIMATE.
--   The final tax of a month is still computed, recorded and posted only after the month has ended (unchanged: the
--   computation, the journal and the tax ledger are not touched). What is new is a read-only evaluation of the
--   month in progress: the same rule, profile checks, exempt band, annual ceiling and marketplace handling, applied
--   to the invoices issued so far. It is recomputed from the invoices on every read, so it follows each new sale
--   and each void. `tax_final_evaluate(entity, period)` keeps its meaning (estimate = false); a three-argument form
--   adds the flag. The three-argument form is built from the function as it stands today (earlier migrations
--   patched it), by exact text replacements: if the old text is not found the migration fails.

do $$
declare
  v_def text;
  v_patch text[][] := array[
    array['CREATE OR REPLACE FUNCTION app_private.tax_final_evaluate(p_entity uuid, p_period date)',
          'CREATE OR REPLACE FUNCTION app_private.tax_final_evaluate(p_entity uuid, p_period date, p_estimate boolean)'],
    array[$o$'engine', case when v_eng is null then 'inactive' else 'active' end);$o$,
          $n$'engine', case when v_eng is null then 'inactive' else 'active' end,
                              'estimate', (v_end >= v_today));$n$],
    array[$o$  if v_end >= v_today then
$o$,
          $n$  -- An estimate is allowed for the running month only; every other unfinished month waits until it has ended.
  if v_end >= v_today and not (p_estimate and p_period <= v_today) then
$n$],
    array[$o$    'consequence', 'The final income tax of the month is a tax expense and a liability to pay by the deadline of the following month');$o$,
          $n$    'consequence', case when v_end >= v_today
      then 'An estimate from the invoices issued so far this month; nothing is recorded. It becomes the final tax once the month has ended and is computed'
      else 'The final income tax of the month is a tax expense and a liability to pay by the deadline of the following month' end);$n$]
  ];
  i integer;
begin
  v_def := pg_catalog.pg_get_functiondef('app_private.tax_final_evaluate(uuid, date)'::regprocedure);
  for i in 1 .. array_length(v_patch, 1) loop
    if position(v_patch[i][1] in v_def) = 0 then
      raise exception 'p32 patch % not found in tax_final_evaluate', i;
    end if;
    v_def := replace(v_def, v_patch[i][1], v_patch[i][2]);
  end loop;
  execute v_def;
end
$$;

create or replace function app_private.tax_final_evaluate(p_entity uuid, p_period date) returns jsonb
language sql stable set search_path = pg_catalog, public as $$
  select app_private.tax_final_evaluate(p_entity, p_period, false)
$$;

create function public.tax_final_estimate(p_entity uuid, p_period date) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  return app_private.tax_final_evaluate(p_entity, p_period, true);
end
$$;

revoke all on function app_private.tax_final_evaluate(uuid, date, boolean) from public;
revoke all on function public.tax_final_estimate(uuid, date) from public, anon;
grant execute on function public.tax_final_estimate(uuid, date) to authenticated;
