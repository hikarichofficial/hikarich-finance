-- Decision 369 (builder, owner asked to stop being asked, 9 October 2026): income tax article 21 on honoraria and fees
-- paid to an INDIVIDUAL who is not an employee ("bukan pegawai": freelancer, expert, performer, writer...).
-- Source: PMK 168/PMK.03/2023 Pasal 12 ayat (3) (the base is 50% of the gross income) and Pasal 16 ayat (3) (the rate is the
-- progressive rate of UU PPh Pasal 17 ayat (1) huruf a applied to that base, every tax period, not accumulated over the
-- year); UU PPh Pasal 21 ayat (5a) (a payee without a tax number: rate 20% higher, i.e. x 1.2; an individual with a valid
-- NIK counts as having one).
-- It runs through the same machinery as PPh 23 / 4(2) / 26 (determination, ledger, payment, filing, reconciliation,
-- calendar): the tax type 'wht_pph21' already exists (payroll), and shares its 15th / 20th deadlines.
-- Rules: the rate layers are NOT repeated here: they are read from PERSONAL_INCOME_TARIFF (one source of truth).
-- Limits (written in the guide and in DECISIONS): the layers are applied to each document, not to the sum of one payee's
-- payments in the same month; the tax office's "tidak berkesinambungan" distinction no longer exists (PMK 168/2023).

-- ------------------------------------------------------------ the object, as a choice on a line or a category
insert into public.tax_treatment_catalog (treatment_key, side, label, description) values
  ('wht_pph21_non_employee', 'purchase_wht', 'Honorarium / fee to an individual (PPh 21, not an employee)',
   'Fee, honorarium, commission or service payment to an individual who is not an employee (freelancer, expert, performer, writer, notary or doctor without an employment relationship).');

-- ------------------------------------------------------------ the rule master
insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
values
  ('personal_income', 'PPH21_NON_EMPLOYEE', 1, date '2024-01-01',
   '{"objects":["wht_pph21_non_employee"],"dpp_ratio":"0.5","non_npwp_multiplier":"1.2","tariff_code":"PERSONAL_INCOME_TARIFF",
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'PMK 168/PMK.03/2023: PPh Pasal 21 on income of a non-employee - base 50% of the gross income, taxed at the Pasal 17 ayat (1) huruf a layers',
   'PMK 168/2023 Pasal 12 ayat (3) and Pasal 16 ayat (3); UU PPh Pasal 21 ayat (5a)',
   'https://jdih.kemenkeu.go.id/api/download/e60a82e0-b218-40f5-9d18-b924aa1e11ce/2023pmkeuangan168.pdf', date '2026-10-09', 'verified', 'published', now(),
   'The layers (5%, 15%, 25%, 30%, 35%) come from PERSONAL_INCOME_TARIFF. No PTKP is deducted by the withholder in this scheme. The tax office''s old rule that accumulated continuing income over the year is not in PMK 168/2023, so every payment is computed on its own. A payee without a tax number: x 1.2 (UU PPh Pasal 21 ayat 5a); an individual with a valid NIK counts as having a tax number. The same payment to a non-resident individual is PPh 26.'),
  -- a non-resident individual paid a fee is PPh 26 on every object (decision 256): the new object joins that rule
  ('pph26', 'PPH26_RATE_20', 2, date '2026-01-02',
   '{"rate":"0.20","objects":["wht_rent_movable","wht_rent_land_building","wht_service_technical","wht_service_management",
                              "wht_service_construction","wht_service_consulting","wht_service_other_listed","wht_royalty",
                              "wht_interest","wht_prize","wht_pph21_non_employee"],
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'DJP guidance: PPh Pasal 26 - 20% of the gross amount paid to a non-resident taxpayer',
   'UU PPh Pasal 26 ayat (1); DJP guidance "Pemotongan Pajak Penghasilan - Pasal 26"',
   'https://www.pajak.go.id/en/node/35012', date '2026-10-09', 'verified', 'published', now(),
   'Version 2 adds the honorarium object so a fee to a non-resident individual is withheld under article 26. Tax-treaty rates stay an override with the DGT form.')
on conflict (code, rule_version) do nothing;

-- ------------------------------------------------------------ the calculation, once
create function app_private.tax_pph21_non_employee(p_gross numeric, p_rule public.tax_rule_versions, p_multiplier numeric, p_date date)
returns numeric
language plpgsql stable set search_path = pg_catalog, public as $$
declare
  v_tariff public.tax_rule_versions;
  v_dpp numeric := p_gross * (p_rule.params ->> 'dpp_ratio')::numeric;
  v_lower numeric := 0;
  v_tax numeric := 0;
  b jsonb;
  v_upper numeric;
begin
  v_tariff := app_private.tax_rule_at(p_rule.params ->> 'tariff_code', p_date);
  if v_tariff.id is null then
    raise exception 'INVALID: the personal tariff rule is missing on %', p_date using errcode = 'invalid_parameter_value';
  end if;
  for b in select value from jsonb_array_elements(v_tariff.params -> 'brackets') loop
    v_upper := nullif(b ->> 'up_to', '')::numeric;
    if v_dpp > v_lower then
      v_tax := v_tax + (least(v_dpp, coalesce(v_upper, v_dpp)) - v_lower) * (b ->> 'rate')::numeric;
    end if;
    exit when v_upper is null or v_dpp <= v_upper;
    v_lower := v_upper;
  end loop;
  return app_private.tax_round(p_rule.params, v_tax * p_multiplier);
end
$$;
revoke all on function app_private.tax_pph21_non_employee(numeric, public.tax_rule_versions, numeric, date) from public;

-- ------------------------------------------------------------ the evaluators learn the fourth withholding tax
-- Patched in place: the exact old text must be present, and nothing else of the function changes.
do $$
declare
  v_patch text[][] := array[
    -- which tax: a fee to an individual who is not an employee is article 21 (a non-resident payee is still article 26)
    array[$o$when (app_private.tax_wht_rule_for('pph4_2', v_key, p_date)).id is not null then 'pph4_2'$o$,
          $n$when v_key = 'wht_pph21_non_employee' then 'pph21'
                    when (app_private.tax_wht_rule_for('pph4_2', v_key, p_date)).id is not null then 'pph4_2'$n$, '1'],
    -- the rule of the new family is stored under the family "personal_income"
    array[$o$v_rule := app_private.tax_wht_rule_for(l ->> 'family', l ->> 'object', p_date);
      if v_rule.id is null then$o$,
          $n$v_rule := app_private.tax_wht_rule_for(case when l ->> 'family' = 'pph21' then 'personal_income' else l ->> 'family' end, l ->> 'object', p_date);
      if v_rule.id is not null and l ->> 'family' = 'pph21' and v_facts.party_kind <> 'individual' then
        v_reasons := array_append(v_reasons, format(
          'Line %s is classified as a fee to an individual (PPh 21), but the payee is not recorded as an individual; a company is withheld under PPh 23.', l ->> 'line_no'));
      elsif v_rule.id is null then$n$, '1'],
    array[$o$select (app_private.tax_wht_rule_for(v_fam, x ->> 'object', p_date)).code as rule_code$o$,
          $n$select (app_private.tax_wht_rule_for(case when v_fam = 'pph21' then 'personal_income' else v_fam end, x ->> 'object', p_date)).code as rule_code$n$, '1'],
    -- the result that carries the reasons
    array[$o$    when exists (select 1 from jsonb_array_elements(v_taxable) x where x ->> 'family' = 'pph4_2') then 'pph4_2'
    else 'pph26' end;$o$,
          $n$    when exists (select 1 from jsonb_array_elements(v_taxable) x where x ->> 'family' = 'pph4_2') then 'pph4_2'
    when exists (select 1 from jsonb_array_elements(v_taxable) x where x ->> 'family' = 'pph21') then 'pph21'
    else 'pph26' end;$n$, '1'],
    array[$o$foreach v_fam in array array['pph23', 'pph4_2', 'pph26'] loop$o$,
          $n$foreach v_fam in array array['pph23', 'pph4_2', 'pph21', 'pph26'] loop$n$, '1'],
    array[$o$v_label := case v_fam when 'pph23' then 'PPh 23' when 'pph4_2' then 'PPh 4(2)' else 'PPh 26' end;$o$,
          $n$v_label := case v_fam when 'pph23' then 'PPh 23' when 'pph4_2' then 'PPh 4(2)' when 'pph21' then 'PPh 21' else 'PPh 26' end;$n$, '1'],
    -- the calculation itself
    array[$o$v_frules := v_frules || app_private.tax_rule_ref(v_rule);
          v_rate := (v_rule.params ->> 'rate')::numeric;$o$,
          $n$v_frules := v_frules || app_private.tax_rule_ref(v_rule);
          v_rate := case when v_fam = 'pph21' then 0 else (v_rule.params ->> 'rate')::numeric end;$n$, '1'],
    array[$o$v_mult := case when v_fam = 'pph23' and v_facts.tax_id_status = 'no_npwp'$o$,
          $n$v_mult := case when v_fam in ('pph23', 'pph21') and v_facts.tax_id_status = 'no_npwp'$n$, '1'],
    array[$o$v_tax := app_private.tax_round(v_rule.params, g.base * v_rate * v_mult);$o$,
          $n$if v_fam = 'pph21' then
            v_tax := app_private.tax_pph21_non_employee(g.base, v_rule, v_mult, p_date);
            v_rate := case when g.base > 0 and v_mult > 0 then v_tax / g.base / v_mult else 0 end;
          else
            v_tax := app_private.tax_round(v_rule.params, g.base * v_rate * v_mult);
          end if;$n$, '1'],
    array[$o$if v_fam = 'pph26' then
          v_ftrace := app_private.tax_trace_add(v_ftrace,$o$,
          $n$if v_fam = 'pph21' then
          v_ftrace := app_private.tax_trace_add(v_ftrace,
            'Fee to an individual who is not an employee (PMK 168/2023): the base is 50% of the gross amount, taxed at the progressive layers of the personal tariff for this document; no PTKP is deducted. The layers are not added up over the payee''s other payments of the month.');
        end if;
        if v_fam = 'pph26' then
          v_ftrace := app_private.tax_trace_add(v_ftrace,$n$, '1'],
    -- document totals and overrides
    array[$o$x ->> 'kind' in ('wht_pph23', 'wht_pph4_2', 'wht_pph26')$o$,
          $n$x ->> 'kind' in ('wht_pph23', 'wht_pph4_2', 'wht_pph21', 'wht_pph26')$n$, '1'],
    array[$o$p_kind not in ('vat_output', 'vat_input', 'wht_pph23', 'wht_pph4_2', 'wht_pph26')$o$,
          $n$p_kind not in ('vat_output', 'vat_input', 'wht_pph23', 'wht_pph4_2', 'wht_pph21', 'wht_pph26')$n$, '1']
  ];
  i integer;
  f record;
  v_n integer;
begin
  for i in 1 .. array_length(v_patch, 1) loop
    v_n := 0;
    for f in
      select p.oid from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'app_private') and p.prokind = 'f' and position(v_patch[i][1] in p.prosrc) > 0
      order by p.oid
    loop
      execute replace(pg_catalog.pg_get_functiondef(f.oid), v_patch[i][1], v_patch[i][2]);
      v_n := v_n + 1;
    end loop;
    if v_n <> v_patch[i][3]::integer then
      raise exception 'pph21 patch % expected % function(s), found %', i, v_patch[i][3], v_n;
    end if;
  end loop;
end
$$;
