-- P9 part 2: the payroll rule data - PPh 21 (TER monthly table, annual Pasal 17 reconciliation) and BPJS.
-- Authority: Step 05 §1/§9/§13/§15 (statutory values are effective-dated DATA with a legal source; payroll tax facts are
-- effective-dated; gross/net/gross-up are explicit), Step 01 #25 (BPJS optional, configurable, effective-dated).
--
-- Nothing statutory is written in the payroll code. The engine reads these published versions through the rule
-- lookup of P7, and every payroll line stores which version it used. A new law is a new version, never an edit.
-- The values below are the baseline the system asserts; the owner's tax adviser must confirm them before go-live
-- (DECISIONS: tax baseline review before P15).

alter table public.tax_rule_versions drop constraint tax_rule_versions_family_check;
alter table public.tax_rule_versions add constraint tax_rule_versions_family_check
  check (family in ('ppn', 'pph23', 'pph_final_umkm', 'pph4_2', 'pph26', 'pph21', 'corporate_income', 'personal_income',
                    'deadline', 'fiscal_depreciation', 'bpjs', 'other'));

-- ------------------------------------------------------------ rule shapes: PPh 21 and BPJS
-- Re-emitted from P8 with two more families. A published version is read by every payroll calculation, so its shape
-- is checked like the other families' (the seeded versions satisfy it).
create or replace function app_private.tax_rule_params_problem(p_family text, p_params jsonb) returns text
language plpgsql stable as $$
declare
  v_num numeric;
  v_den numeric;
  v_x jsonb;
  v_key text;
  v_prev numeric;
  v_cur numeric;
  v_i integer;
  v_n integer;
begin
  if jsonb_typeof(p_params) is distinct from 'object' then
    return 'the parameters must be a JSON object';
  end if;
  if p_family in ('ppn', 'pph23', 'pph_final_umkm') then
    if jsonb_typeof(p_params -> 'rounding') is distinct from 'object'
       or coalesce(p_params -> 'rounding' ->> 'mode', '') not in ('half_up', 'half_even', 'down', 'up')
       or coalesce(p_params -> 'rounding' ->> 'scale', '') !~ '^[0-4]$' then
      return 'rounding needs a mode (half_up, half_even, down, up) and a scale from 0 to 4';
    end if;
    if coalesce(p_params ->> 'rate', '') !~ '^0\.[0-9]{1,6}$' or (p_params ->> 'rate')::numeric <= 0 then
      return 'rate must be a decimal string between 0 and 1, for example "0.12"';
    end if;
  end if;
  if p_family = 'ppn' then
    if coalesce(p_params ->> 'dpp_numerator', '') !~ '^[1-9][0-9]{0,3}$'
       or coalesce(p_params ->> 'dpp_denominator', '') !~ '^[1-9][0-9]{0,3}$' then
      return 'dpp_numerator and dpp_denominator must be positive whole numbers';
    end if;
    v_num := (p_params ->> 'dpp_numerator')::numeric;
    v_den := (p_params ->> 'dpp_denominator')::numeric;
    if v_num > v_den then
      return 'the DPP factor cannot exceed 1';
    end if;
  elsif p_family = 'pph23' then
    if coalesce(p_params ->> 'non_npwp_multiplier', '') !~ '^[1-9](\.[0-9]{1,2})?$' then
      return 'non_npwp_multiplier must be a decimal string of at least 1, for example "2"';
    end if;
    if jsonb_typeof(p_params -> 'objects') is distinct from 'array' or jsonb_array_length(p_params -> 'objects') = 0 then
      return 'objects must list the withholding objects this rule covers';
    end if;
    for v_x in select * from jsonb_array_elements(p_params -> 'objects') loop
      v_key := case when jsonb_typeof(v_x) = 'string' then v_x #>> '{}' end;
      if v_key is null or not exists (select 1 from public.tax_treatment_catalog c
                                      where c.treatment_key = v_key and c.side = 'purchase_wht')
         or v_key in ('wht_none', 'wht_review') then
        return format('unknown or non-taxable withholding object %s', coalesce(v_key, v_x::text));
      end if;
    end loop;
  elsif p_family = 'pph_final_umkm' then
    if coalesce(p_params ->> 'annual_ceiling', '') !~ '^[1-9][0-9]{0,15}$' then
      return 'annual_ceiling must be a whole-number string';
    end if;
    if jsonb_typeof(p_params -> 'eligible_kinds') is distinct from 'array'
       or jsonb_array_length(p_params -> 'eligible_kinds') = 0 then
      return 'eligible_kinds must list the taxpayer kinds the regime covers';
    end if;
    for v_x in select * from jsonb_array_elements(p_params -> 'eligible_kinds') loop
      if jsonb_typeof(v_x) <> 'string'
         or (v_x #>> '{}') not in ('individual', 'perseroan_perorangan', 'company', 'cooperative', 'other') then
        return format('unknown taxpayer kind %s in eligible_kinds', v_x::text);
      end if;
    end loop;
    if jsonb_typeof(p_params -> 'exempt_band') is distinct from 'object' then
      return 'exempt_band must be an object (taxpayer kind -> whole-number amount), possibly empty';
    end if;
    for v_key in select k from jsonb_object_keys(p_params -> 'exempt_band') as k loop
      if v_key not in ('individual', 'perseroan_perorangan', 'company', 'cooperative', 'other')
         or coalesce(p_params -> 'exempt_band' ->> v_key, '') !~ '^[1-9][0-9]{0,15}$' then
        return format('invalid exempt band for %s', v_key);
      end if;
    end loop;
  elsif p_family = 'deadline' then
    for v_key in select unnest(array['payment', 'filing']) loop
      v_x := p_params -> v_key;
      if jsonb_typeof(v_x) is distinct from 'object' then
        return format('%s must describe the deadline', v_key);
      end if;
      if coalesce(v_x ->> 'month_offset', '') !~ '^[0-3]$' then
        return format('%s.month_offset must be 0 to 3 months after the tax period', v_key);
      end if;
      if not ((coalesce(v_x ->> 'eom', '') = 'true')
              or coalesce(v_x ->> 'day', '') ~ '^([1-9]|[12][0-9]|3[01])$') then
        return format('%s needs a day of the month (1 to 31) or "eom": true', v_key);
      end if;
    end loop;
  elsif p_family = 'pph21' then
    if coalesce(p_params ->> 'kind', '') = 'ter' then
      if jsonb_typeof(p_params -> 'rounding') is distinct from 'object'
         or coalesce(p_params -> 'rounding' ->> 'mode', '') not in ('half_up', 'half_even', 'down', 'up')
         or coalesce(p_params -> 'rounding' ->> 'scale', '') !~ '^[0-4]$' then
        return 'rounding needs a mode (half_up, half_even, down, up) and a scale from 0 to 4';
      end if;
      if jsonb_typeof(p_params -> 'category_of_ptkp') is distinct from 'object'
         or (select count(*) from jsonb_object_keys(p_params -> 'category_of_ptkp')) <> 8 then
        return 'category_of_ptkp must map each of the eight PTKP statuses to a TER category';
      end if;
      for v_key in select k from jsonb_object_keys(p_params -> 'category_of_ptkp') as k loop
        if v_key not in ('TK/0', 'TK/1', 'TK/2', 'TK/3', 'K/0', 'K/1', 'K/2', 'K/3')
           or coalesce(p_params -> 'category_of_ptkp' ->> v_key, '') not in ('A', 'B', 'C') then
          return format('invalid TER category for %s', v_key);
        end if;
      end loop;
      if coalesce(p_params ->> 'no_tax_id_multiplier', '') !~ '^[1-9](\.[0-9]{1,2})?$' then
        return 'no_tax_id_multiplier must be a decimal string of at least 1, for example "1.2"';
      end if;
      for v_key in select unnest(array['A', 'B', 'C']) loop
        v_x := p_params -> 'tables' -> v_key;
        if jsonb_typeof(v_x) is distinct from 'array' or jsonb_array_length(v_x) not between 2 and 200 then
          return format('the TER table %s must list its brackets', v_key);
        end if;
        v_n := jsonb_array_length(v_x);
        v_prev := -1;
        v_num := -1;
        for v_i in 0 .. v_n - 1 loop
          if jsonb_typeof(v_x -> v_i) is distinct from 'object'
             or coalesce(v_x -> v_i ->> 'rate', '') !~ '^(0|0\.[0-9]{1,6})$'
             or (v_i < v_n - 1 and coalesce(v_x -> v_i ->> 'up_to', '') !~ '^[1-9][0-9]{0,15}$')
             or (v_i = v_n - 1 and jsonb_typeof(v_x -> v_i -> 'up_to') is distinct from 'null') then
            return format('bracket %s of TER table %s needs a rate and an upper bound (the last one has none)', v_i + 1, v_key);
          end if;
          if v_i < v_n - 1 then
            v_cur := (v_x -> v_i ->> 'up_to')::numeric;
            if v_cur <= v_prev then
              return format('the upper bounds of TER table %s must ascend', v_key);
            end if;
            v_prev := v_cur;
          end if;
          if (v_x -> v_i ->> 'rate')::numeric < v_num then
            return format('the rates of TER table %s must not fall', v_key);
          end if;
          v_num := (v_x -> v_i ->> 'rate')::numeric;
        end loop;
      end loop;
    elsif coalesce(p_params ->> 'kind', '') = 'annual' then
      if jsonb_typeof(p_params -> 'rounding') is distinct from 'object'
         or coalesce(p_params -> 'rounding' ->> 'mode', '') not in ('half_up', 'half_even', 'down', 'up')
         or coalesce(p_params -> 'rounding' ->> 'scale', '') !~ '^[0-4]$' then
        return 'rounding needs a mode (half_up, half_even, down, up) and a scale from 0 to 4';
      end if;
      if jsonb_typeof(p_params -> 'ptkp') is distinct from 'object' or (select count(*) from jsonb_object_keys(p_params -> 'ptkp')) <> 8 then
        return 'ptkp must give the annual amount of each of the eight PTKP statuses';
      end if;
      for v_key in select k from jsonb_object_keys(p_params -> 'ptkp') as k loop
        if v_key not in ('TK/0', 'TK/1', 'TK/2', 'TK/3', 'K/0', 'K/1', 'K/2', 'K/3')
           or coalesce(p_params -> 'ptkp' ->> v_key, '') !~ '^[1-9][0-9]{0,15}$' then
          return format('invalid PTKP amount for %s', v_key);
        end if;
      end loop;
      if coalesce(p_params ->> 'ptkp_proration', '') not in ('months_worked', 'full_year') then
        return 'ptkp_proration must be months_worked or full_year';
      end if;
      if coalesce(p_params -> 'occupational_cost' ->> 'rate', '') !~ '^0\.[0-9]{1,6}$'
         or coalesce(p_params -> 'occupational_cost' ->> 'monthly_cap', '') !~ '^[1-9][0-9]{0,15}$' then
        return 'occupational_cost needs a rate and a monthly cap';
      end if;
      if coalesce(p_params ->> 'pkp_round_down_to', '') !~ '^[1-9][0-9]{0,6}$' then
        return 'pkp_round_down_to must be a whole number';
      end if;
      if coalesce(p_params ->> 'no_tax_id_multiplier', '') !~ '^[1-9](\.[0-9]{1,2})?$' then
        return 'no_tax_id_multiplier must be a decimal string of at least 1, for example "1.2"';
      end if;
      v_x := p_params -> 'brackets';
      if jsonb_typeof(v_x) is distinct from 'array' or jsonb_array_length(v_x) not between 1 and 20 then
        return 'brackets must list the progressive rate bands';
      end if;
      v_n := jsonb_array_length(v_x);
      v_prev := 0;
      for v_i in 0 .. v_n - 1 loop
        if jsonb_typeof(v_x -> v_i) is distinct from 'object'
           or coalesce(v_x -> v_i ->> 'rate', '') !~ '^0\.[0-9]{1,6}$'
           or (v_i < v_n - 1 and coalesce(v_x -> v_i ->> 'up_to', '') !~ '^[1-9][0-9]{0,15}$')
           or (v_i = v_n - 1 and jsonb_typeof(v_x -> v_i -> 'up_to') is distinct from 'null') then
          return format('band %s needs a rate and an upper bound (the last one has none)', v_i + 1);
        end if;
        if v_i < v_n - 1 then
          v_cur := (v_x -> v_i ->> 'up_to')::numeric;
          if v_cur <= v_prev then
            return 'the upper bounds of the bands must ascend';
          end if;
          v_prev := v_cur;
        end if;
      end loop;
    else
      return 'kind must be ter or annual';
    end if;
  elsif p_family = 'bpjs' then
    if coalesce(p_params ->> 'component', '') not in ('bpjs_kes', 'bpjs_jht', 'bpjs_jp', 'bpjs_jkk', 'bpjs_jkm') then
      return 'component must be one of bpjs_kes, bpjs_jht, bpjs_jp, bpjs_jkk, bpjs_jkm';
    end if;
    if jsonb_typeof(p_params -> 'rounding') is distinct from 'object'
       or coalesce(p_params -> 'rounding' ->> 'mode', '') not in ('half_up', 'half_even', 'down', 'up')
       or coalesce(p_params -> 'rounding' ->> 'scale', '') !~ '^[0-4]$' then
      return 'rounding needs a mode (half_up, half_even, down, up) and a scale from 0 to 4';
    end if;
    if coalesce(p_params ->> 'employee_rate', '') !~ '^(0|0\.[0-9]{1,6})$' then
      return 'employee_rate must be a decimal string from 0 to 1';
    end if;
    if jsonb_typeof(p_params -> 'employer_rate_options') = 'object' then
      if (select count(*) from jsonb_object_keys(p_params -> 'employer_rate_options')) = 0 then
        return 'employer_rate_options must list the options';
      end if;
      for v_key in select k from jsonb_object_keys(p_params -> 'employer_rate_options') as k loop
        if v_key !~ '^[a-z][a-z0-9_]{1,30}$' or coalesce(p_params -> 'employer_rate_options' ->> v_key, '') !~ '^(0|0\.[0-9]{1,6})$' then
          return format('invalid employer rate option %s', v_key);
        end if;
      end loop;
    elsif coalesce(p_params ->> 'employer_rate', '') !~ '^(0|0\.[0-9]{1,6})$' then
      return 'employer_rate must be a decimal string from 0 to 1 (or give employer_rate_options)';
    end if;
    if jsonb_typeof(p_params -> 'wage_cap') is distinct from 'null'
       and coalesce(p_params ->> 'wage_cap', '') !~ '^[1-9][0-9]{0,15}$' then
      return 'wage_cap must be a whole-number string or null';
    end if;
    if jsonb_typeof(p_params -> 'employer_taxable_benefit') is distinct from 'boolean'
       or jsonb_typeof(p_params -> 'employee_pension_deductible') is distinct from 'boolean' then
      return 'employer_taxable_benefit and employee_pension_deductible must be true or false';
    end if;
  elsif p_family = 'fiscal_depreciation' then
    -- The statutory groups of Art. 11 UU PPh (P8): what asset registration and the fiscal schedule read.
    if coalesce(p_params ->> 'first_year', '') <> 'prorate_months_from_acquisition_month' then
      return 'first_year must be "prorate_months_from_acquisition_month"';
    end if;
    if jsonb_typeof(p_params -> 'classes') is distinct from 'array' or jsonb_array_length(p_params -> 'classes') not between 1 and 30 then
      return 'classes must list the depreciation groups';
    end if;
    for v_x in select * from jsonb_array_elements(p_params -> 'classes') loop
      if jsonb_typeof(v_x) is distinct from 'object' or coalesce(v_x ->> 'key', '') !~ '^[a-z][a-z0-9_]{1,40}$'
         or length(btrim(coalesce(v_x ->> 'name', ''))) not between 1 and 100
         or jsonb_typeof(v_x -> 'building') is distinct from 'boolean' or jsonb_typeof(v_x -> 'depreciable') is distinct from 'boolean' then
        return 'each group needs a key, a name, and building and depreciable flags';
      end if;
      if (v_x ->> 'depreciable')::boolean then
        if coalesce(v_x ->> 'life_years', '') !~ '^[1-9][0-9]{0,2}$'
           or coalesce(v_x ->> 'sl_rate', '') !~ '^0\.[0-9]{1,6}$' or (v_x ->> 'sl_rate')::numeric <= 0
           or (jsonb_typeof(v_x -> 'db_rate') is distinct from 'null'
               and (coalesce(v_x ->> 'db_rate', '') !~ '^0\.[0-9]{1,6}$' or (v_x ->> 'db_rate')::numeric <= 0)) then
          return format('the group %s needs a life in years, a straight-line rate and a declining-balance rate (or null)', v_x ->> 'key');
        end if;
        if (v_x ->> 'building')::boolean and jsonb_typeof(v_x -> 'db_rate') is distinct from 'null' then
          return format('the building group %s allows straight-line only', v_x ->> 'key');
        end if;
      end if;
    end loop;
    if (select count(distinct c ->> 'key') from jsonb_array_elements(p_params -> 'classes') c) <> jsonb_array_length(p_params -> 'classes') then
      return 'the group keys must be unique';
    end if;
  end if;
  return null;
end
$$;


-- ------------------------------------------------------------ baseline rule versions
insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
values
  ('pph21', 'PPH21_TER', 1, date '2024-01-01',
   '{"kind":"ter","rounding":{"mode":"down","scale":0},"no_tax_id_multiplier":"1.2","category_of_ptkp":{"TK/0":"A","TK/1":"A","K/0":"B","TK/2":"B","TK/3":"B","K/1":"B","K/2":"C","K/3":"C"},"tables":{"A":[{"up_to":"5400000","rate":"0"},{"up_to":"5650000","rate":"0.0025"},{"up_to":"5950000","rate":"0.005"},{"up_to":"6300000","rate":"0.0075"},{"up_to":"6750000","rate":"0.01"},{"up_to":"7500000","rate":"0.0125"},{"up_to":"8550000","rate":"0.015"},{"up_to":"9650000","rate":"0.0175"},{"up_to":"10050000","rate":"0.02"},{"up_to":"10350000","rate":"0.0225"},{"up_to":"10700000","rate":"0.025"},{"up_to":"11050000","rate":"0.03"},{"up_to":"11600000","rate":"0.035"},{"up_to":"12500000","rate":"0.04"},{"up_to":"13750000","rate":"0.05"},{"up_to":"15100000","rate":"0.06"},{"up_to":"16950000","rate":"0.07"},{"up_to":"19750000","rate":"0.08"},{"up_to":"24150000","rate":"0.09"},{"up_to":"26450000","rate":"0.1"},{"up_to":"28000000","rate":"0.11"},{"up_to":"30050000","rate":"0.12"},{"up_to":"32400000","rate":"0.13"},{"up_to":"35400000","rate":"0.14"},{"up_to":"39100000","rate":"0.15"},{"up_to":"43850000","rate":"0.16"},{"up_to":"47800000","rate":"0.17"},{"up_to":"51400000","rate":"0.18"},{"up_to":"56300000","rate":"0.19"},{"up_to":"62200000","rate":"0.2"},{"up_to":"68600000","rate":"0.21"},{"up_to":"77500000","rate":"0.22"},{"up_to":"89000000","rate":"0.23"},{"up_to":"103000000","rate":"0.24"},{"up_to":"125000000","rate":"0.25"},{"up_to":"157000000","rate":"0.26"},{"up_to":"206000000","rate":"0.27"},{"up_to":"337000000","rate":"0.28"},{"up_to":"454000000","rate":"0.29"},{"up_to":"550000000","rate":"0.3"},{"up_to":"695000000","rate":"0.31"},{"up_to":"910000000","rate":"0.32"},{"up_to":"1400000000","rate":"0.33"},{"up_to":null,"rate":"0.34"}],"B":[{"up_to":"6200000","rate":"0"},{"up_to":"6500000","rate":"0.0025"},{"up_to":"6850000","rate":"0.005"},{"up_to":"7300000","rate":"0.0075"},{"up_to":"9200000","rate":"0.01"},{"up_to":"10750000","rate":"0.015"},{"up_to":"11250000","rate":"0.02"},{"up_to":"11600000","rate":"0.025"},{"up_to":"12600000","rate":"0.03"},{"up_to":"13600000","rate":"0.04"},{"up_to":"14950000","rate":"0.05"},{"up_to":"16400000","rate":"0.06"},{"up_to":"18450000","rate":"0.07"},{"up_to":"21850000","rate":"0.08"},{"up_to":"26000000","rate":"0.09"},{"up_to":"27700000","rate":"0.1"},{"up_to":"29350000","rate":"0.11"},{"up_to":"31450000","rate":"0.12"},{"up_to":"33950000","rate":"0.13"},{"up_to":"37100000","rate":"0.14"},{"up_to":"41100000","rate":"0.15"},{"up_to":"45800000","rate":"0.16"},{"up_to":"49500000","rate":"0.17"},{"up_to":"53800000","rate":"0.18"},{"up_to":"58500000","rate":"0.19"},{"up_to":"64000000","rate":"0.2"},{"up_to":"71000000","rate":"0.21"},{"up_to":"80000000","rate":"0.22"},{"up_to":"93000000","rate":"0.23"},{"up_to":"109000000","rate":"0.24"},{"up_to":"129000000","rate":"0.25"},{"up_to":"163000000","rate":"0.26"},{"up_to":"211000000","rate":"0.27"},{"up_to":"374000000","rate":"0.28"},{"up_to":"459000000","rate":"0.29"},{"up_to":"555000000","rate":"0.3"},{"up_to":"704000000","rate":"0.31"},{"up_to":"957000000","rate":"0.32"},{"up_to":"1405000000","rate":"0.33"},{"up_to":null,"rate":"0.34"}],"C":[{"up_to":"6600000","rate":"0"},{"up_to":"6950000","rate":"0.0025"},{"up_to":"7350000","rate":"0.005"},{"up_to":"7800000","rate":"0.0075"},{"up_to":"8850000","rate":"0.01"},{"up_to":"9800000","rate":"0.0125"},{"up_to":"10950000","rate":"0.015"},{"up_to":"11200000","rate":"0.0175"},{"up_to":"12050000","rate":"0.02"},{"up_to":"12950000","rate":"0.03"},{"up_to":"14150000","rate":"0.04"},{"up_to":"15550000","rate":"0.05"},{"up_to":"17050000","rate":"0.06"},{"up_to":"19500000","rate":"0.07"},{"up_to":"22700000","rate":"0.08"},{"up_to":"26600000","rate":"0.09"},{"up_to":"28100000","rate":"0.1"},{"up_to":"30100000","rate":"0.11"},{"up_to":"32600000","rate":"0.12"},{"up_to":"35400000","rate":"0.13"},{"up_to":"38900000","rate":"0.14"},{"up_to":"43000000","rate":"0.15"},{"up_to":"47400000","rate":"0.16"},{"up_to":"51200000","rate":"0.17"},{"up_to":"55800000","rate":"0.18"},{"up_to":"60400000","rate":"0.19"},{"up_to":"66700000","rate":"0.2"},{"up_to":"74500000","rate":"0.21"},{"up_to":"83200000","rate":"0.22"},{"up_to":"95600000","rate":"0.23"},{"up_to":"110000000","rate":"0.24"},{"up_to":"134000000","rate":"0.25"},{"up_to":"169000000","rate":"0.26"},{"up_to":"221000000","rate":"0.27"},{"up_to":"390000000","rate":"0.28"},{"up_to":"463000000","rate":"0.29"},{"up_to":"561000000","rate":"0.3"},{"up_to":"709000000","rate":"0.31"},{"up_to":"965000000","rate":"0.32"},{"up_to":"1419000000","rate":"0.33"},{"up_to":null,"rate":"0.34"}]}}'::jsonb,
   'PMK 168 Tahun 2023: PPh Pasal 21 monthly withholding by effective average rate (TER), categories A, B and C',
   'PMK 168/2023 (Lampiran A, B, C); PP 58/2023',
   'https://www.pajak.go.id/en/node/117085', date '2026-09-21', 'verified', 'published', now(),
   'Used for the tax months before the last tax month of the year (January to November): the monthly gross income is multiplied by the rate of its bracket. Category A: TK/0, TK/1. Category B: TK/2, TK/3, K/0, K/1. Category C: K/2, K/3. The final amount is rounded down to whole rupiah (confirm the rounding with the tax adviser before go-live).'),
  ('pph21', 'PPH21_ANNUAL', 1, date '2024-01-01',
   '{"kind":"annual","rounding":{"mode":"down","scale":0},
     "ptkp":{"TK/0":"54000000","TK/1":"58500000","TK/2":"63000000","TK/3":"67500000",
             "K/0":"58500000","K/1":"63000000","K/2":"67500000","K/3":"72000000"},
     "ptkp_proration":"months_worked",
     "occupational_cost":{"rate":"0.05","monthly_cap":"500000"},
     "pkp_round_down_to":"1000",
     "brackets":[{"up_to":"60000000","rate":"0.05"},{"up_to":"250000000","rate":"0.15"},
                 {"up_to":"500000000","rate":"0.25"},{"up_to":"5000000000","rate":"0.30"},{"up_to":null,"rate":"0.35"}],
     "no_tax_id_multiplier":"1.2"}'::jsonb,
   'Article 17 UU PPh (as amended by UU HPP) and PMK 168/2023: PPh 21 of the last tax month - annual computation with PTKP, occupational cost and progressive rates',
   'UU PPh Pasal 17 and Pasal 7; PMK 168/2023 (last tax month / employee leaving)',
   'https://www.pajak.go.id/en/node/117085', date '2026-09-21', 'verified', 'published', now(),
   'Applied in the last tax month of the year (December) and in the month an employee leaves: the tax of the whole period worked is computed on the actual income, less occupational cost (5%, at most Rp500,000 a month), less the employee JHT and JP contributions, less PTKP (in proportion to the months worked); the PKP is rounded down to the thousand; the tax already withheld in the year is deducted. An employee without a tax number pays 20% more (multiplier 1.2). Non-permanent-worker methods are not modelled. Confirm the PTKP proration and the treatment of over-withholding with the tax adviser before go-live.'),
  ('bpjs', 'BPJS_KES', 1, date '2020-07-01',
   '{"component":"bpjs_kes","employer_rate":"0.04","employee_rate":"0.01","wage_cap":"12000000",
     "employer_taxable_benefit":true,"employee_pension_deductible":false,"rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'BPJS Kesehatan: contribution of 5% of wage (4% employer, 1% employee), wage base capped at Rp12,000,000',
   'Perpres 64 Tahun 2020 (amending Perpres 82/2018)',
   'https://www.bpjs-kesehatan.go.id/', date '2026-09-21', 'verified', 'published', now(),
   'The employer share is a taxable benefit of the employee (added to the gross income of the tax computation, PMK 168/2023). Confirm the current cap with BPJS before go-live.'),
  ('bpjs', 'BPJS_JHT', 1, date '2015-07-01',
   '{"component":"bpjs_jht","employer_rate":"0.037","employee_rate":"0.02","wage_cap":null,
     "employer_taxable_benefit":false,"employee_pension_deductible":true,"rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'BPJS Ketenagakerjaan - Jaminan Hari Tua (JHT): 3.7% employer, 2% employee, no wage cap',
   'PP 46 Tahun 2015; PP 36 Tahun 2021 (wage definition)',
   'https://www.bpjsketenagakerjaan.go.id/', date '2026-09-21', 'verified', 'published', now(),
   'The employee share is deductible in the annual PPh 21 computation; the employer share is not part of the employee''s taxable income.'),
  ('bpjs', 'BPJS_JP', 1, date '2025-03-01',
   '{"component":"bpjs_jp","employer_rate":"0.02","employee_rate":"0.01","wage_cap":"10547400",
     "employer_taxable_benefit":false,"employee_pension_deductible":true,"rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'BPJS Ketenagakerjaan - Jaminan Pensiun (JP): 2% employer, 1% employee, wage cap Rp10,547,400 from March 2025',
   'PP 45 Tahun 2015; BPJS Ketenagakerjaan announcement of the yearly JP wage cap',
   'https://www.bpjsketenagakerjaan.go.id/', date '2026-09-21', 'verified', 'published', now(),
   'The wage cap is adjusted each March; the next version carries the new cap.'),
  ('bpjs', 'BPJS_JP', 2, date '2026-03-01',
   '{"component":"bpjs_jp","employer_rate":"0.02","employee_rate":"0.01","wage_cap":"11086300",
     "employer_taxable_benefit":false,"employee_pension_deductible":true,"rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'BPJS Ketenagakerjaan - Jaminan Pensiun (JP): 2% employer, 1% employee, wage cap Rp11,086,300 from March 2026',
   'PP 45 Tahun 2015; BPJS Ketenagakerjaan announcement of the yearly JP wage cap',
   'https://www.bpjsketenagakerjaan.go.id/', date '2026-09-21', 'verified', 'published', now(),
   'Replaces the March 2025 cap. Confirm against the BPJS Ketenagakerjaan announcement before go-live.'),
  ('bpjs', 'BPJS_JKK', 1, date '2015-07-01',
   '{"component":"bpjs_jkk","employer_rate":null,"employee_rate":"0",
     "employer_rate_options":{"grade_1":"0.0024","grade_2":"0.0054","grade_3":"0.0089","grade_4":"0.0127","grade_5":"0.0174"},
     "wage_cap":null,"employer_taxable_benefit":true,"employee_pension_deductible":false,"rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'BPJS Ketenagakerjaan - Jaminan Kecelakaan Kerja (JKK): employer only, 0.24% to 1.74% by risk grade',
   'PP 44 Tahun 2015 (as amended by PP 82/2019)',
   'https://www.bpjsketenagakerjaan.go.id/', date '2026-09-21', 'verified', 'published', now(),
   'The risk grade of the business is chosen on the enrolment of each employee (rate option). The employer share is a taxable benefit of the employee.'),
  ('bpjs', 'BPJS_JKM', 1, date '2015-07-01',
   '{"component":"bpjs_jkm","employer_rate":"0.003","employee_rate":"0","wage_cap":null,
     "employer_taxable_benefit":true,"employee_pension_deductible":false,"rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'BPJS Ketenagakerjaan - Jaminan Kematian (JKM): employer only, 0.30%',
   'PP 44 Tahun 2015',
   'https://www.bpjsketenagakerjaan.go.id/', date '2026-09-21', 'verified', 'published', now(),
   'The employer share is a taxable benefit of the employee.'),
  ('deadline', 'DEADLINE_PPH21', 1, date '2024-01-01',
   '{"payment":{"day":10,"month_offset":1},"filing":{"day":20,"month_offset":1}}'::jsonb,
   'DJP guidance: PPh Pasal 21 is paid by the 10th and reported (SPT Masa) by the 20th of the following month',
   'DJP guidance "Pemotongan Pajak Penghasilan - Pasal 21"; PMK 168/2023',
   'https://www.pajak.go.id/en/node/117085', date '2026-09-21', 'verified', 'published', now(),
   'A due date that falls on a holiday moves to the next business day; holiday data is not part of the system, so the calendar shows the nominal date.');

revoke all on all functions in schema app_private from public;
