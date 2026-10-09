-- Decision 385 (OWNER, 9 October 2026): record the employee's NIK alongside their NPWP.
-- The tax profile held one identifier, `tax_id`, which is right for PPh 21: what is reported is the NPWP when
-- there is one and the NIK when there is not. But an employer needs both on file -- the NIK is what BPJS
-- registration asks for, and someone who registered an NPWP before the 2024 NIK integration has two different
-- numbers -- so asking for both and keeping only one silently threw away what the person typed.
-- `national_id` is therefore stored beside `tax_id`. It is identity, never arithmetic: nothing in the payroll
-- engine, the PPh 21 computation or any report reads it, and `tax_id` alone still decides the tax identifier.
-- It is masked on read exactly as `tax_id` is; the full number stays behind `employee_tax_identifier`'s step-up.

alter table public.employee_tax_profiles
  add column national_id text check (national_id is null or national_id ~ '^[0-9]{16}$');

comment on column public.employee_tax_profiles.national_id is
  'NIK (16 digits), identity only: BPJS registration and HR records. The PPh 21 identifier is tax_id.';

-- The audit trail redacts the tax number; the NIK is the same kind of thing and joins the redaction list, or
-- the number the screens take care to mask would sit in plain sight in `audit_events` (the P9 invariant test
-- catches exactly this).
drop trigger tg_audit on public.employee_tax_profiles;
create trigger tg_audit after insert on public.employee_tax_profiles
  for each row execute function app_private.tg_audit('entity_id', 'tax_id', 'national_id', 'ptkp_status', 'tax_id_status', 'note');

-- The writer takes one more optional argument; the old eight-argument form goes, so there is no overload to
-- resolve against. Body otherwise unchanged.
drop function public.employee_set_tax_profile(uuid, text, date, text, text, text, text, text);

create function public.employee_set_tax_profile(
  p_employee uuid, p_key text, p_effective_from date, p_tax_id_status text, p_tax_id text, p_ptkp_status text,
  p_tax_method text default 'employee_borne', p_note text default null, p_national_id text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  v_replay uuid;
  v_id uuid := gen_random_uuid();
  v_tax_id text := nullif(regexp_replace(coalesce(p_tax_id, ''), '[^0-9]', '', 'g'), '');
  v_nik text := nullif(regexp_replace(coalesce(p_national_id, ''), '[^0-9]', '', 'g'), '');
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.employee_edit', 'recording employee tax facts');
  if not app_authz.has_permission(e.entity_id, 'payroll.tax_view') then
    raise exception 'FORBIDDEN: recording employee tax facts needs payroll.tax_view' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('employee.set_tax_profile', e.entity_id, p_key,
    md5(jsonb_build_object('e', p_employee, 'd', p_effective_from, 's', p_tax_id_status, 'i', v_tax_id, 'p', p_ptkp_status,
                           'm', p_tax_method, 'n', p_note, 'k', v_nik)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p_effective_from is null or p_effective_from < e.join_date or p_tax_id_status not in ('has_tax_id', 'no_tax_id', 'unknown')
     or p_ptkp_status not in ('TK/0', 'TK/1', 'TK/2', 'TK/3', 'K/0', 'K/1', 'K/2', 'K/3', 'unknown')
     or p_tax_method not in ('employee_borne', 'gross_up') then
    raise exception 'INVALID: tax facts need a date (not before the join date), a tax-number status, a PTKP status and a method'
      using errcode = 'invalid_parameter_value';
  end if;
  if (p_tax_id_status = 'has_tax_id') <> (v_tax_id is not null) or (v_tax_id is not null and v_tax_id !~ '^[0-9]{15,16}$') then
    raise exception 'INVALID: give a 15 or 16 digit tax number exactly when the status is has_tax_id' using errcode = 'invalid_parameter_value';
  end if;
  if v_nik is not null and v_nik !~ '^[0-9]{16}$' then
    raise exception 'INVALID: a NIK is 16 digits' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.employee_tax_profiles t where t.employee_id = e.id and t.effective_from = p_effective_from) then
    raise exception 'CONFLICT: tax facts from % are already recorded; record the change from a later date', p_effective_from
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(p_effective_from);
  insert into public.employee_tax_profiles
    (id, entity_id, employee_id, effective_from, tax_id_status, tax_id, ptkp_status, tax_method, note, national_id)
  values (v_id, e.entity_id, e.id, p_effective_from, p_tax_id_status, v_tax_id, p_ptkp_status, p_tax_method,
          nullif(btrim(coalesce(p_note, '')), ''), v_nik);
  perform app_private.idem_complete('employee.set_tax_profile', e.entity_id, p_key, 'employee_tax_profiles', v_id);
  return v_id;
end
$$;

-- The reader gains the NIK, masked the same way the tax number already is.
create or replace function public.employee_tax_profile_get(p_employee uuid, p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  t public.employee_tax_profiles%rowtype;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.tax_view', 'the employee tax profile');
  t := app_private.employee_tax_at(e.id, coalesce(p_date, app_private.entity_today(e.entity_id)));
  if t.id is null then
    return jsonb_build_object('recorded', false);
  end if;
  return jsonb_build_object('recorded', true, 'effective_from', t.effective_from, 'tax_id_status', t.tax_id_status,
    'tax_id_masked', case when t.tax_id is null then null else repeat('*', length(t.tax_id) - 4) || right(t.tax_id, 4) end,
    'national_id_masked', case when t.national_id is null then null else repeat('*', length(t.national_id) - 4) || right(t.national_id, 4) end,
    'ptkp_status', t.ptkp_status, 'tax_method', t.tax_method, 'note', t.note);
end
$$;

revoke all on function public.employee_set_tax_profile(uuid, text, date, text, text, text, text, text, text) from public, anon;
grant execute on function public.employee_set_tax_profile(uuid, text, date, text, text, text, text, text, text) to authenticated;
