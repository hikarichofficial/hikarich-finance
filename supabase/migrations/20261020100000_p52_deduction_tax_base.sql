-- Decision 381 (OWNER, 9 October 2026): a deduction no longer reduces the PPh 21 base just by being a deduction.
-- Until now every "potongan" came off both take-home pay and the taxable base, so a loan or kasbon repayment --
-- which is the employee paying back their own debt out of income they did receive -- understated the month's PPh 21.
-- The component's own `taxable` flag now decides, for deductions as it already did for earnings: true means the
-- deduction really is less income (unpaid absence), false means take-home only (loan instalment, kasbon, koperasi).
-- Gross/net pay and the BPJS wage base are unchanged; only the PPh 21 base is. Same for one-off adjustments.
create or replace function app_private.payroll_compute_line(p_in jsonb) returns jsonb
language plpgsql stable set search_path = pg_catalog, public as $$
declare
  c jsonb;
  b jsonb;
  v_p jsonb;
  v_flags text[] := '{}';
  v_info text[] := '{}';
  v_earn numeric := 0;
  v_red numeric := 0;
  v_tax_red numeric := 0;
  v_tax_earn numeric := 0;
  v_wage numeric := 0;
  v_adj_earn numeric := 0;
  v_adj_tax_earn numeric := 0;
  v_adj_red numeric := 0;
  v_adj_tax_red numeric := 0;
  v_gross numeric;
  v_code text;
  v_short text;
  v_base numeric;
  v_emp numeric;
  v_er numeric;
  v_er_rate numeric;
  v_bp jsonb := '{}'::jsonb;
  v_emp_total numeric := 0;
  v_er_total numeric := 0;
  v_er_tax numeric := 0;
  v_pension numeric := 0;
  v_taxable numeric;
  v_mode text;
  v_method text;
  v_tax numeric := 0;
  v_allow numeric := 0;
  v_a numeric := 0;
  v_next numeric;
  v_due jsonb;
  v_i integer;
  v_calc jsonb := '{}'::jsonb;
  v_net numeric;
  v_ytd jsonb := p_in -> 'ytd';
begin
  -- pay
  for c in select value from jsonb_array_elements(p_in -> 'components') loop
    if c ->> 'kind' = 'earning' then
      v_earn := v_earn + (c ->> 'amount')::numeric;
      if (c ->> 'taxable')::boolean then
        v_tax_earn := v_tax_earn + (c ->> 'amount')::numeric;
      end if;
      if (c ->> 'bpjs_base')::boolean then
        v_wage := v_wage + (c ->> 'amount')::numeric;
      end if;
    else
      v_red := v_red + (c ->> 'amount')::numeric;
      -- Only a deduction marked taxable is less income; the rest come off take-home pay alone (decision 381).
      if (c ->> 'taxable')::boolean then
        v_tax_red := v_tax_red + (c ->> 'amount')::numeric;
      end if;
    end if;
  end loop;
  for c in select value from jsonb_array_elements(p_in -> 'adjustments') loop
    if c ->> 'kind' = 'earning' then
      v_adj_earn := v_adj_earn + (c ->> 'amount')::numeric;
      if (c ->> 'taxable')::boolean then
        v_adj_tax_earn := v_adj_tax_earn + (c ->> 'amount')::numeric;
      end if;
    else
      v_adj_red := v_adj_red + (c ->> 'amount')::numeric;
      if (c ->> 'taxable')::boolean then
        v_adj_tax_red := v_adj_tax_red + (c ->> 'amount')::numeric;
      end if;
    end if;
  end loop;
  if jsonb_array_length(p_in -> 'components') = 0 then
    v_flags := v_flags || 'no_compensation'::text;
  end if;
  v_gross := v_earn + v_adj_earn - v_red - v_adj_red;
  if v_gross < 0 then
    v_flags := v_flags || 'negative_gross_pay'::text;
  end if;
  if (p_in ->> 'joined_in_period')::boolean then
    v_info := v_info || 'joined_during_month'::text;
  end if;
  if (p_in ->> 'exited_in_period')::boolean then
    v_info := v_info || 'left_during_month'::text;
  end if;

  -- BPJS
  for b in select value from jsonb_array_elements(p_in -> 'bpjs') loop
    v_code := b ->> 'component';
    if b ->> 'rule' is null then
      v_flags := v_flags || ('no_bpjs_rule:' || v_code);
      continue;
    end if;
    select params into v_p from public.tax_rule_versions where id = (b ->> 'rule')::uuid;
    if jsonb_typeof(v_p -> 'employer_rate_options') = 'object' then
      v_er_rate := (v_p -> 'employer_rate_options' ->> coalesce(b ->> 'rate_key', ''))::numeric;
      if v_er_rate is null then
        v_flags := v_flags || ('bpjs_rate_option_missing:' || v_code);
        continue;
      end if;
    else
      v_er_rate := (v_p ->> 'employer_rate')::numeric;
    end if;
    v_base := case when jsonb_typeof(v_p -> 'wage_cap') = 'null' then v_wage else least(v_wage, (v_p ->> 'wage_cap')::numeric) end;
    v_emp := app_private.tax_round(v_p, v_base * (v_p ->> 'employee_rate')::numeric);
    v_er := app_private.tax_round(v_p, v_base * v_er_rate);
    v_short := substr(v_code, 6);
    v_bp := v_bp || jsonb_build_object(v_short, jsonb_build_object('emp', v_emp, 'er', v_er));
    v_emp_total := v_emp_total + v_emp;
    v_er_total := v_er_total + v_er;
    if (v_p ->> 'employer_taxable_benefit')::boolean then
      v_er_tax := v_er_tax + v_er;
    end if;
    if (v_p ->> 'employee_pension_deductible')::boolean then
      v_pension := v_pension + v_emp;
    end if;
  end loop;

  -- PPh 21
  v_taxable := greatest(0, v_tax_earn + v_adj_tax_earn - v_tax_red - v_adj_tax_red) + v_er_tax;
  v_mode := case when (p_in ->> 'last_tax_month')::boolean then 'annual' else 'ter' end;
  v_method := p_in -> 'tax' ->> 'method';
  if coalesce(jsonb_typeof(p_in -> 'tax'), 'null') = 'null' or p_in -> 'tax' ->> 'ptkp' = 'unknown' or p_in -> 'tax' ->> 'id_status' = 'unknown' then
    v_flags := v_flags || 'tax_facts_missing'::text;
    v_mode := null;
    v_method := null;
  elsif v_mode = 'ter' and p_in ->> 'ter_rule' is null then
    v_flags := v_flags || 'no_ter_rule'::text;
  elsif v_mode = 'annual' and p_in ->> 'annual_rule' is null then
    v_flags := v_flags || 'no_annual_rule'::text;
  else
    if v_mode = 'annual' then
      if (v_ytd ->> 'missing_months')::integer > 0 then
        v_flags := v_flags || 'ytd_incomplete'::text;
      end if;
      if (v_ytd ->> 'pending_runs')::integer > 0 then
        v_flags := v_flags || 'earlier_run_not_posted'::text;
      end if;
    end if;
    v_due := app_private.payroll_tax_due(p_in, v_taxable, v_pension);
    if v_method = 'gross_up' then
      -- The employer pays the tax as an allowance, which is itself income: solve tax = f(income + tax).
      v_a := 0;
      for v_i in 1 .. 100 loop
        v_due := app_private.payroll_tax_due(p_in, v_taxable + v_a, v_pension);
        v_next := (v_due ->> 'tax')::numeric;
        exit when v_next = v_a;
        v_a := v_next;
        if v_i = 100 then
          v_flags := v_flags || 'gross_up_not_converged'::text;
        end if;
      end loop;
      v_allow := v_a;
      v_tax := v_a;
    else
      v_tax := (v_due ->> 'tax')::numeric;
    end if;
    if (v_due ->> 'overwithheld')::numeric > 0 then
      v_info := v_info || ('tax_overwithheld:' || trim_scale((v_due ->> 'overwithheld')::numeric)::text);
    end if;
    v_calc := jsonb_build_object('mode', v_mode, 'method', v_method,
      'rule', case when v_mode = 'ter' then p_in ->> 'ter_rule' else p_in ->> 'annual_rule' end,
      'base', app_private.tax_money(v_taxable + v_allow)) || (v_due -> 'detail');
  end if;

  v_net := v_gross - v_emp_total - (v_tax - v_allow);
  if v_net < 0 then
    v_flags := v_flags || 'negative_net_pay'::text;
  end if;
  return jsonb_build_object(
    'review_flags', to_jsonb(v_flags), 'info_flags', to_jsonb(v_info),
    'earnings_total', v_earn, 'reductions_total', v_red, 'adjustment_earnings', v_adj_earn, 'adjustment_deductions', v_adj_red,
    'gross_pay', v_gross, 'bpjs_wage_base', v_wage,
    'kes_emp', coalesce((v_bp -> 'kes' ->> 'emp')::numeric, 0), 'jht_emp', coalesce((v_bp -> 'jht' ->> 'emp')::numeric, 0),
    'jp_emp', coalesce((v_bp -> 'jp' ->> 'emp')::numeric, 0),
    'kes_er', coalesce((v_bp -> 'kes' ->> 'er')::numeric, 0), 'jht_er', coalesce((v_bp -> 'jht' ->> 'er')::numeric, 0),
    'jp_er', coalesce((v_bp -> 'jp' ->> 'er')::numeric, 0), 'jkk_er', coalesce((v_bp -> 'jkk' ->> 'er')::numeric, 0),
    'jkm_er', coalesce((v_bp -> 'jkm' ->> 'er')::numeric, 0),
    'employer_taxable_benefits', v_er_tax, 'pension_deduction', v_pension,
    'tax_base', v_taxable, 'tax_mode', v_mode, 'tax_method', v_method, 'pph21', v_tax, 'tax_allowance', v_allow,
    'net_pay', v_net, 'tax_calc', v_calc);
end
$$;
