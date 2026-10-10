-- Decision 397 (OWNER, 10 October 2026): the annual withholding certificate, Bukti Potong 1721-A1.
--
-- A payslip is a record of a month's pay. The 1721-A1 is a different document with a different job: once a
-- year (or when someone leaves), the employer hands each permanent employee a statement of the year's gross,
-- its deductions, the PTKP applied and the PPh 21 withheld, and the employee files their own SPT Tahunan
-- from it before 31 March. Keeping the tax detail on the payslip (the OWNER's choice) does not replace it.
--
-- Everything the certificate states is already computed: this reads the posted payroll lines and any opening
-- figures for the year, and runs them through the same `pph21_annual` the December payroll itself uses, so
-- the certificate and the last payslip cannot disagree. Over-withholding handed back in December
-- (decision 396) is subtracted from what was withheld, so the certificate states what the employee actually
-- bore -- which is the figure their own return needs.
--
-- The full NPWP/NIK is on the certificate, because the form is not usable without it. That is the one piece
-- behind a recent step-up, exactly as `employee_tax_identifier` already requires (Step 06 §8); every other
-- figure needs only `payroll.tax_view`.

create function public.payroll_withholding_certificate(p_entity uuid, p_year integer, p_employee uuid default null)
returns table (employee_id uuid, employee_code text, employee_name text, tax_id text, ptkp_status text,
               position_title text, months_worked integer, first_month integer, last_month integer,
               gross_income text, occupational_cost text, pension_deduction text, net_income text,
               ptkp text, pkp text, annual_tax text, withheld text, refunded text, borne_by_employee text,
               status text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  t public.employee_tax_profiles%rowtype;
  v_rule jsonb;
  v_gross numeric;
  v_pension numeric;
  v_withheld numeric;
  v_refund numeric;
  v_months integer;
  v_first integer;
  v_last integer;
  v_a jsonb;
  o public.employee_tax_openings%rowtype;
  v_step_up boolean;
  v_end date := make_date(p_year, 12, 31);
begin
  perform app_private.payroll_read_authorize(p_entity, 'the annual withholding certificates');
  if not app_authz.has_permission(p_entity, 'payroll.tax_view') then
    raise exception 'FORBIDDEN: the withholding certificate needs payroll.tax_view' using errcode = 'insufficient_privilege';
  end if;
  if p_year is null or p_year not between 2000 and 2100 then
    raise exception 'INVALID: a tax year is required' using errcode = 'invalid_parameter_value';
  end if;
  -- The identifier is the only part that needs the step-up; without it the certificate still lists, so the
  -- screen can show who is ready to issue before asking anyone to verify again.
  v_step_up := app_authz.recent_step_up();
  select params into v_rule from public.tax_rule_versions where id = (app_private.tax_rule_at('PPH21_ANNUAL', v_end)).id;

  for e in select x.* from public.employees x
           where x.entity_id = p_entity and x.join_date <= v_end
             and (x.exit_date is null or x.exit_date >= make_date(p_year, 1, 1))
             and (p_employee is null or x.id = p_employee)
           order by x.employee_code loop
    employee_id := e.id; employee_code := e.employee_code; employee_name := e.full_name;

    -- The same two sources, combined the same way, as the December payroll's own year-to-date (Step 09 1.3): the
    -- opening figures stand for the months they cover, and the posted lines for the months after them. A month that
    -- has both would otherwise be counted twice.
    select * into o from public.employee_tax_openings x
    where x.entity_id = p_entity and x.employee_id = e.id and x.tax_year = p_year
    order by x.revision desc limit 1;

    select coalesce(sum(l.tax_base + l.tax_allowance), 0), coalesce(sum(l.pension_deduction), 0),
           coalesce(sum(l.pph21), 0), coalesce(sum(l.tax_refund), 0)
      into v_gross, v_pension, v_withheld, v_refund
    from public.payroll_run_lines l
    join public.payroll_runs pr on pr.id = l.run_id and pr.entity_id = l.entity_id
    where l.entity_id = p_entity and l.employee_id = e.id
      and pr.period_start >= make_date(p_year, 1, 1) and pr.period_start <= v_end
      and pr.status in ('posted', 'partially_paid', 'paid', 'closed')
      and (o.id is null or extract(month from pr.period_start) > o.through_month);
    if o.id is not null then
      v_gross := v_gross + o.taxable_gross;
      v_pension := v_pension + o.pension_deduction;
      v_withheld := v_withheld + o.pph21_withheld;
    end if;

    v_first := case when extract(year from e.join_date) = p_year then extract(month from e.join_date)::integer else 1 end;
    v_last := case when e.exit_date is not null and extract(year from e.exit_date) = p_year
                   then extract(month from e.exit_date)::integer else 12 end;
    v_months := v_last - v_first + 1;
    first_month := v_first; last_month := v_last; months_worked := v_months;

    t := app_private.employee_tax_at(e.id, least(v_end, coalesce(e.exit_date, v_end)));
    tax_id := case when v_step_up then t.tax_id end;
    ptkp_status := t.ptkp_status;
    position_title := (select h.position_title from public.employee_employments h
                       where h.employee_id = e.id and h.effective_from <= v_end
                       order by h.effective_from desc limit 1);
    gross_income := trim_scale(v_gross)::text;
    pension_deduction := trim_scale(v_pension)::text;
    withheld := trim_scale(v_withheld)::text;
    refunded := trim_scale(v_refund)::text;
    borne_by_employee := trim_scale(v_withheld - v_refund)::text;

    if v_rule is null or t.id is null or t.ptkp_status = 'unknown' or t.tax_id_status = 'unknown' then
      occupational_cost := null; net_income := null; ptkp := null; pkp := null; annual_tax := null;
      status := 'incomplete';
    else
      v_a := app_private.pph21_annual(v_rule, t.ptkp_status, t.tax_id_status = 'no_tax_id', v_gross, v_pension, v_months);
      occupational_cost := v_a ->> 'occupational_cost';
      net_income := v_a ->> 'net_income';
      ptkp := v_a ->> 'ptkp';
      pkp := v_a ->> 'pkp';
      annual_tax := v_a ->> 'annual_tax';
      status := case when (v_a ->> 'annual_tax')::numeric = v_withheld - v_refund then 'reconciled'
                     when (v_a ->> 'annual_tax')::numeric > v_withheld - v_refund then 'under_withheld'
                     else 'over_withheld' end;
    end if;
    return next;
  end loop;
end
$$;

revoke all on function public.payroll_withholding_certificate(uuid, integer, uuid) from public, anon;
grant execute on function public.payroll_withholding_certificate(uuid, integer, uuid) to authenticated;
