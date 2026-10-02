-- P14 decision 256 (OWNER): two more income-tax withholdings in the tax engine, and the payment deadline
-- correction of PMK 81/2024.
--   1. PPh Pasal 4 ayat (2) on rent of land and/or buildings (final, 10% of the gross rent; PP 34/2017).
--   2. PPh Pasal 26 on payments to a non-resident payee (20% of the gross amount; UU PPh Pasal 26).
--   3. PMK 81/2024 Pasal 94: withheld income tax is paid by the 15th of the following month (was the 10th).
-- Authority: Step 05 §10 (withholding is determined from the legal OBJECT and the COUNTERPARTY), §2 and §15
-- (rates and deadlines live in the versioned rule master, never in code), Step 01 #21-#23.
--
-- Both taxes run through the SAME machinery as PPh 23 (determination, ledger, payment, filing, reconciliation,
-- calendar): they are the tax types 'wht_pph4_2' and 'wht_pph26'. Which one applies is decided by facts:
--   * a non-resident payee -> PPh 26 on every withholding object of the document;
--   * a resident payee     -> PPh 4(2) when the object is covered by a PPh 4(2) rule, otherwise PPh 23.
-- A tax-treaty rate (P3B, with the payee's DGT form) is a legal decision with evidence: it is entered as an
-- override of the PPh 26 result, never guessed.

-- ------------------------------------------------------------ vocabulary
alter table public.tax_overrides drop constraint tax_overrides_tax_kind_check;
alter table public.tax_overrides add constraint tax_overrides_tax_kind_check
  check (tax_kind in ('vat_output', 'vat_input', 'wht_pph23', 'wht_pph4_2', 'wht_pph26'));
alter table public.tax_determinations drop constraint tax_determinations_tax_kind_check;
alter table public.tax_determinations add constraint tax_determinations_tax_kind_check
  check (tax_kind in ('vat_output', 'vat_input', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm'));
alter table public.tax_determinations drop constraint tax_determinations_tax_type_check;
alter table public.tax_determinations add constraint tax_determinations_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm'));
alter table public.tax_ledger_entries drop constraint tax_ledger_entries_tax_kind_check;
alter table public.tax_ledger_entries add constraint tax_ledger_entries_tax_kind_check
  check (tax_kind in ('vat_output', 'vat_input', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm'));
alter table public.tax_ledger_entries drop constraint tax_ledger_entries_tax_type_check;
alter table public.tax_ledger_entries add constraint tax_ledger_entries_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm'));
alter table public.tax_payments drop constraint tax_payments_tax_type_check;
alter table public.tax_payments add constraint tax_payments_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm'));
alter table public.tax_filings drop constraint tax_filings_tax_type_check;
alter table public.tax_filings add constraint tax_filings_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm'));
alter table public.tax_reconciliations drop constraint tax_reconciliations_tax_type_check;
alter table public.tax_reconciliations add constraint tax_reconciliations_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm'));

insert into public.tax_treatment_catalog (treatment_key, side, label, description) values
  ('wht_rent_land_building', 'purchase_wht', 'Rent (land and/or building)',
   'Rent of land, a building or part of one (office, shop, warehouse, room), including service charges billed with it.');

-- What the Entity still owes of one tax type (ledger accruals less confirmed payments).
create function app_private.tax_outstanding(p_entity uuid, p_type text) returns numeric
language sql stable as $$
  select (select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e
          where e.entity_id = p_entity and e.tax_type = p_type and e.direction = 'payable')
       - (select coalesce(sum(x.payable_applied), 0) from public.tax_payments x
          where x.entity_id = p_entity and x.tax_type = p_type and x.status = 'confirmed')
$$;
revoke all on function app_private.tax_outstanding(uuid, text) from public;

-- The withholding rule of one family that covers an object on a date; null when none or more than one does.
create function app_private.tax_wht_rule_for(p_family text, p_object text, p_date date) returns public.tax_rule_versions
language plpgsql stable as $$
declare
  v_code text;
  v_r public.tax_rule_versions;
  v_hit public.tax_rule_versions;
  v_n integer := 0;
begin
  for v_code in select distinct code from public.tax_rule_versions where family = p_family and status = 'published' loop
    v_r := app_private.tax_rule_at(v_code, p_date);
    if v_r.id is not null and (v_r.params -> 'objects') ? p_object then
      v_n := v_n + 1;
      v_hit := v_r;
    end if;
  end loop;
  if v_n <> 1 then
    return null;
  end if;
  return v_hit;
end
$$;
revoke all on function app_private.tax_wht_rule_for(text, text, date) from public;

-- ------------------------------------------------------------ the existing commands learn the two tax types
-- The functions below are long and change in one list or label only, so they are patched in place: the exact old
-- text must be present (the block fails otherwise), and nothing else of the function changes.
do $$
declare
  v_patch text[][] := array[
    -- payment, filing, reconciliation, period position
    array[$o$('vat', 'wht_pph23', 'wht_pph21', 'final_umkm')$o$,
          $n$('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm')$n$, '4'],
    array[$o$INVALID: the tax type is vat, wht_pph23, wht_pph21 or final_umkm$o$,
          $n$INVALID: unknown tax type$n$, '3'],
    array[$o$when 'wht_pph21' then 'PPh 21' else 'PPh Final' end$o$,
          $n$when 'wht_pph21' then 'PPh 21' when 'wht_pph4_2' then 'PPh 4(2)' when 'wht_pph26' then 'PPh 26' else 'PPh Final' end$n$, '1'],
    -- calendar
    array[$o$array['vat', 'wht_pph23', 'wht_pph21', 'final_umkm']$o$,
          $n$array['vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm']$n$, '1'],
    array[$o$when 'wht_pph21' then 'DEADLINE_PPH21' else$o$,
          $n$when 'wht_pph21' then 'DEADLINE_PPH21' when 'wht_pph4_2' then 'DEADLINE_PPH4_2' when 'wht_pph26' then 'DEADLINE_PPH26' else$n$, '1'],
    -- overview
    array[$o$'vat', ((select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e where e.entity_id = p_entity and e.tax_type = 'vat' and e.direction = 'payable')$o$,
          $n$'wht_pph4_2', app_private.tax_outstanding(p_entity, 'wht_pph4_2')::text,
    'wht_pph26', app_private.tax_outstanding(p_entity, 'wht_pph26')::text,
    'vat', ((select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e where e.entity_id = p_entity and e.tax_type = 'vat' and e.direction = 'payable')$n$, '1'],
    -- document evaluation: what is withheld is the sum of every withholding result
    array[$o$coalesce((select x ->> 'tax' from jsonb_array_elements(v_out) x where x ->> 'kind' = 'wht_pph23'), '0')$o$,
          $n$coalesce((select trim_scale(sum((x ->> 'tax')::numeric))::text from jsonb_array_elements(v_out) x where x ->> 'kind' in ('wht_pph23', 'wht_pph4_2', 'wht_pph26')), '0')$n$, '1'],
    -- overrides
    array[$o$p_kind not in ('vat_output', 'vat_input', 'wht_pph23')$o$,
          $n$p_kind not in ('vat_output', 'vat_input', 'wht_pph23', 'wht_pph4_2', 'wht_pph26')$n$, '1'],
    -- journal line of a bill / expense
    array[$o$'PPh 23 withheld: '$o$, $n$'Income tax withheld: '$n$, '2'],
    -- rule master validation
    array[$o$if p_family in ('ppn', 'pph23', 'pph_final_umkm') then$o$,
          $n$if p_family in ('ppn', 'pph23', 'pph4_2', 'pph26', 'pph_final_umkm') then$n$, '1'],
    array[$o$elsif p_family = 'pph23' then
    if coalesce(p_params ->> 'non_npwp_multiplier', '') !~$o$,
          $n$elsif p_family in ('pph23', 'pph4_2', 'pph26') then
    if p_family = 'pph23' and coalesce(p_params ->> 'non_npwp_multiplier', '') !~$n$, '1']
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
      raise exception 'tax patch % expected % function(s), found %', i, v_patch[i][3], v_n;
    end if;
  end loop;
end
$$;

-- ------------------------------------------------------------ evaluator: income-tax withholding
-- Returns one result per withholding tax that applies (an array): PPh 23, PPh 4(2), PPh 26. When something must
-- be reviewed, a single result carries the reasons.
create or replace function app_private.tax_eval_wht(
  p_entity uuid, p_date date, p_currency public.currency_code, p_party uuid, p_lines jsonb)
returns jsonb
language plpgsql stable as $$
declare
  v_base public.currency_code := app_private.entity_base_currency(p_entity);
  v_prof public.tax_entity_profiles;
  v_facts public.tax_contact_facts;
  v_rule public.tax_rule_versions;
  v_reasons text[] := '{}';
  v_trace jsonb := '[]'::jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_taxable jsonb := '[]'::jsonb;
  v_confirmed boolean := false;
  v_needs_party boolean := false;
  v_nonres boolean := false;
  v_ok boolean;
  v_primary text;
  v_fam text;
  v_label text;
  v_has boolean;
  v_out jsonb := '[]'::jsonb;
  v_ftrace jsonb;
  v_frules jsonb;
  v_fcomp jsonb;
  v_fbase numeric;
  v_ftax numeric;
  v_fexempt numeric;
  v_none_base numeric := 0;
  v_mult numeric := 1;
  v_rate numeric;
  v_tax numeric;
  v_key text;
  v_src text;
  v_no integer;
  v_sub numeric;
  l jsonb;
  g record;
begin
  v_prof := app_private.tax_profile_at(p_entity, p_date);
  if v_prof.id is null then
    v_reasons := array_append(v_reasons, format('The Entity has no tax profile in force on %s.', p_date));
  else
    v_trace := app_private.tax_trace_add(v_trace, format('Withholding role of the Entity on %s: %s (profile effective %s).',
      p_date, case v_prof.withholding_agent when 'yes' then 'withholding agent' when 'no' then 'not a withholding agent' else 'not recorded' end,
      v_prof.effective_from));
  end if;
  if p_party is not null then
    v_facts := app_private.tax_contact_facts_at(p_entity, p_party, p_date);
    v_nonres := v_facts.id is not null and v_facts.residency = 'non_resident';
  end if;

  -- Resolve each line's withholding object: the line's own fact first, then the category mapping the user set up.
  for l in select value from jsonb_array_elements(p_lines) loop
    v_no := (l ->> 'line_no')::integer;
    v_sub := (l ->> 'subtotal')::numeric;
    v_key := nullif(l ->> 'wht_object', '');
    v_src := 'line';
    if v_key is null and nullif(l ->> 'category_id', '') is not null then
      v_key := app_private.tax_key_for_category(p_entity, (l ->> 'category_id')::uuid, 'purchase_wht');
      v_src := 'category';
    end if;
    if coalesce((l ->> 'confirmed')::boolean, false) then
      v_confirmed := true;
    end if;
    v_lines := v_lines || jsonb_build_object('line_no', v_no, 'object', v_key, 'source', case when v_key is null then null else v_src end,
                                             'base', app_private.tax_money(v_sub));
    if v_key = 'wht_none' then
      v_none_base := v_none_base + v_sub;
    elsif v_key is null then
      if v_prof.withholding_agent = 'no' then
        v_none_base := v_none_base + v_sub;
      else
        v_reasons := array_append(v_reasons, format(
          'Line %s has no withholding classification: choose "not a withholding object" or the object on the line, or map its category.', v_no));
      end if;
    elsif v_key = 'wht_review' then
      v_reasons := array_append(v_reasons, format('Line %s is marked "not sure" and waits for a tax review.', v_no));
    else
      -- Which tax: the payee's residency first, then the object.
      v_fam := case when v_nonres then 'pph26'
                    when (app_private.tax_wht_rule_for('pph4_2', v_key, p_date)).id is not null then 'pph4_2'
                    else 'pph23' end;
      v_taxable := v_taxable || jsonb_build_object('line_no', v_no, 'object', v_key, 'base', v_sub, 'family', v_fam);
      v_needs_party := true;
    end if;
  end loop;

  if v_prof.id is not null and jsonb_array_length(v_taxable) > 0 then
    if v_prof.withholding_agent = 'unknown' then
      v_reasons := array_append(v_reasons, 'The Entity''s withholding role (whether it must withhold) is not recorded.');
    elsif v_prof.withholding_agent = 'no' then
      v_reasons := array_append(v_reasons,
        'A line carries a withholding object but the Entity is recorded as not being a withholding agent; review the profile or the line.');
    end if;
  end if;

  if v_needs_party and array_length(v_reasons, 1) is null then
    if p_currency <> v_base or v_base::text <> 'IDR' then
      v_reasons := array_append(v_reasons, 'Withholding on a foreign-currency document needs the statutory exchange rate and goes to review.');
    end if;
    if p_party is null then
      v_reasons := array_append(v_reasons, 'The payee is not a contact of the Entity, so its tax facts are unknown; register the payee and record its tax facts.');
    elsif v_facts.id is null then
      v_reasons := array_append(v_reasons, format('No tax facts are recorded for the payee on %s.', p_date));
    elsif v_facts.residency = 'unknown' then
      v_reasons := array_append(v_reasons, 'The payee''s tax residency (resident or non-resident) is not recorded.');
    elsif not v_nonres
          and (v_facts.tax_id_status = 'unknown' or v_facts.party_kind = 'unknown' or v_facts.wht_exemption = 'unknown') then
      v_reasons := array_append(v_reasons, 'The payee''s kind, tax-number status or withholding exemption is not recorded.');
    end if;
  end if;

  if v_needs_party and array_length(v_reasons, 1) is null then
    if v_nonres then
      v_trace := app_private.tax_trace_add(v_trace, format(
        'Payee facts on %s: non-resident taxpayer, so income-tax article 26 applies to every withholding object.', p_date));
    else
      v_trace := app_private.tax_trace_add(v_trace, format('Payee facts on %s: %s, resident, %s, exemption certificate %s.', p_date,
        v_facts.party_kind, case v_facts.tax_id_status when 'has_npwp' then 'has a tax number' else 'no tax number' end,
        case v_facts.wht_exemption when 'certificate' then 'on file' else 'none' end));
    end if;
    for l in select value from jsonb_array_elements(v_taxable) loop
      v_rule := app_private.tax_wht_rule_for(l ->> 'family', l ->> 'object', p_date);
      if v_rule.id is null then
        v_reasons := array_append(v_reasons, format('No single withholding rule covers line %s (%s) on %s.', l ->> 'line_no', l ->> 'object', p_date));
      elsif l ->> 'family' = 'pph23' and v_facts.party_kind = 'individual'
            and (v_rule.params -> 'individual_review_objects') ? (l ->> 'object') then
        v_reasons := array_append(v_reasons, format(
          'Line %s (%s) is paid to an individual; whether income-tax article 23 or 21 applies is a legal classification that needs review.',
          l ->> 'line_no', l ->> 'object'));
      end if;
    end loop;
  end if;

  v_ok := array_length(v_reasons, 1) is null;
  -- The result that carries the reasons (or the "nothing is withheld" explanation) when no tax is computed.
  v_primary := case
    when jsonb_array_length(v_taxable) = 0 then 'pph23'
    when exists (select 1 from jsonb_array_elements(v_taxable) x where x ->> 'family' = 'pph23') then 'pph23'
    when exists (select 1 from jsonb_array_elements(v_taxable) x where x ->> 'family' = 'pph4_2') then 'pph4_2'
    else 'pph26' end;

  foreach v_fam in array array['pph23', 'pph4_2', 'pph26'] loop
    v_has := exists (select 1 from jsonb_array_elements(v_taxable) x where x ->> 'family' = v_fam);
    if v_fam <> v_primary and not (v_ok and v_has) then
      continue;
    end if;
    v_label := case v_fam when 'pph23' then 'PPh 23' when 'pph4_2' then 'PPh 4(2)' else 'PPh 26' end;
    v_ftrace := v_trace;
    v_frules := '[]'::jsonb;
    v_fcomp := '[]'::jsonb;
    v_fbase := 0;
    v_ftax := 0;
    v_fexempt := 0;

    if v_ok and v_has then
      if v_fam = 'pph23' and v_facts.wht_exemption = 'certificate' then
        select coalesce(sum((x ->> 'base')::numeric), 0) into v_fexempt
        from jsonb_array_elements(v_taxable) x where x ->> 'family' = v_fam;
        v_ftrace := app_private.tax_trace_add(v_ftrace, format(
          'The payee holds a withholding exemption certificate, so nothing is withheld on %s (the certificate is evidence to keep).', trim_scale(v_fexempt)));
      else
        if v_fam = 'pph4_2' and v_facts.wht_exemption = 'certificate' then
          v_ftrace := app_private.tax_trace_add(v_ftrace,
            'The payee''s exemption certificate concerns income-tax article 23; it does not cover the final tax on rent of land or buildings, which is still withheld (a separate exemption letter is entered as an override with its evidence).');
        end if;
        for g in
          select t.rule_code, sum(t.base) as base
          from (select (app_private.tax_wht_rule_for(v_fam, x ->> 'object', p_date)).code as rule_code, (x ->> 'base')::numeric as base
                from jsonb_array_elements(v_taxable) x where x ->> 'family' = v_fam) t
          group by t.rule_code order by t.rule_code
        loop
          v_rule := app_private.tax_rule_at(g.rule_code, p_date);
          v_frules := v_frules || app_private.tax_rule_ref(v_rule);
          v_rate := (v_rule.params ->> 'rate')::numeric;
          v_mult := case when v_fam = 'pph23' and v_facts.tax_id_status = 'no_npwp'
                         then (v_rule.params ->> 'non_npwp_multiplier')::numeric else 1 end;
          v_tax := app_private.tax_round(v_rule.params, g.base * v_rate * v_mult);
          v_fbase := v_fbase + g.base;
          v_ftax := v_ftax + v_tax;
          v_fcomp := v_fcomp || jsonb_build_object(
            'label', format('%s v%s: %s of the gross amount%s', v_rule.code, v_rule.rule_version, trim_scale(v_rate * v_mult * 100) || '%',
                            case when v_mult > 1 then ' (payee has no tax number: rate x ' || trim_scale(v_mult) || ')' else '' end),
            'base', app_private.tax_money(g.base), 'rate', trim_scale(v_rate * v_mult)::text, 'tax', app_private.tax_money(v_tax));
          v_ftrace := app_private.tax_trace_add(v_ftrace, format('Withholding on %s at %s = %s (rule %s v%s, rounded).',
            trim_scale(g.base), trim_scale(v_rate * v_mult), trim_scale(v_tax), v_rule.code, v_rule.rule_version));
        end loop;
        if v_fam = 'pph26' then
          v_ftrace := app_private.tax_trace_add(v_ftrace,
            'This is the statutory rate. A lower tax-treaty rate applies only with the payee''s certificate of domicile (DGT form): enter it as an override with that evidence.');
        end if;
      end if;
    elsif v_ok then
      v_ftrace := app_private.tax_trace_add(v_ftrace, format(
        'No line is a withholding object (%s); nothing is withheld.',
        case when v_prof.withholding_agent = 'no' then 'the Entity is not a withholding agent' else 'every line is classified as not a withholding object' end));
    end if;

    v_out := v_out || jsonb_build_object(
      'kind', 'wht_' || v_fam, 'tax_type', 'wht_' || v_fam, 'direction', 'payable',
      'status', case when not v_ok then 'needs_review'
                     when v_confirmed then 'owner_confirmed' else 'auto_determined' end,
      'reasons', case when v_ok then '[]'::jsonb else to_jsonb(v_reasons) end,
      'base', app_private.tax_money(v_fbase + v_fexempt), 'tax', app_private.tax_money(v_ftax),
      'rate', null, 'components', v_fcomp, 'rules', v_frules, 'trace', v_ftrace,
      'facts', jsonb_build_object('profile_id', v_prof.id, 'profile_effective_from', v_prof.effective_from,
                                  'withholding_agent', v_prof.withholding_agent, 'party_id', p_party,
                                  'party_facts_id', v_facts.id, 'residency', v_facts.residency, 'currency', p_currency,
                                  'lines', v_lines),
      'consequence', case when v_ftax > 0
        then format('%s is withheld from the payee: the vendor is owed that much less, and it is credited to Tax Payables and accrues in the %s ledger for %s. The gross expense is unchanged.',
                    trim_scale(v_ftax), v_label, to_char(app_private.tax_period_start(p_date), 'YYYY-MM'))
        else 'Nothing is withheld: the vendor is owed the full amount.' end);
  end loop;
  return v_out;
end
$$;

-- ------------------------------------------------------------ rule master
insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
values
  ('pph4_2', 'PPH4_2_RENT_LAND_BUILDING', 1, date '2026-01-01',
   '{"rate":"0.10","objects":["wht_rent_land_building"],"rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'PP 34 Tahun 2017: PPh Final Pasal 4 ayat (2) - 10% of the gross rent of land and/or buildings',
   'PP 34/2017 Pasal 2 and Pasal 4; UU PPh Pasal 4 ayat (2)',
   'https://ortax.org/pajak-penghasilan-atas-persewaan-tanah-dan-atau-bangunan', date '2026-10-02', 'verified', 'published', now(),
   'Final tax. The base is the gross rent (excluding VAT), including maintenance, security and service charges billed with it. The same rate applies whether or not the lessor has a tax number. The tenant withholds when it is a withholding agent (an entity, or an individual appointed by the tax office); otherwise the lessor pays it.'),
  ('pph26', 'PPH26_RATE_20', 1, date '2026-01-01',
   '{"rate":"0.20","objects":["wht_rent_movable","wht_rent_land_building","wht_service_technical","wht_service_management",
                              "wht_service_construction","wht_service_consulting","wht_service_other_listed","wht_royalty",
                              "wht_interest","wht_prize"],
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'DJP guidance: PPh Pasal 26 - 20% of the gross amount paid to a non-resident taxpayer',
   'UU PPh Pasal 26 ayat (1); DJP guidance "Pemotongan Pajak Penghasilan - Pasal 26"',
   'https://www.pajak.go.id/en/node/35012', date '2026-10-02', 'verified', 'published', now(),
   'Statutory rate for interest, royalties, rent and fees for services paid to a non-resident. A tax treaty (P3B) may lower it when the payee provides a certificate of domicile (DGT form): that is entered as an override with the evidence. Dividends are handled with the equity workflows and are not part of this rule.'),
  ('deadline', 'DEADLINE_PPH4_2', 1, date '2025-01-01',
   '{"payment":{"day":15,"month_offset":1},"filing":{"day":20,"month_offset":1}}'::jsonb,
   'PMK 81 Tahun 2024 Pasal 94: withheld PPh Pasal 4 ayat (2) is paid by the 15th and reported (SPT Masa Unifikasi) by the 20th of the following month',
   'PMK 81/2024 Pasal 94 ayat (2)',
   'https://ortax.org/batas-waktu-setor-dan-lapor-pph-unifikasi', date '2026-10-02', 'verified', 'published', now(),
   'A due date that falls on a holiday moves to the next business day; holiday data is not part of the system, so the calendar shows the nominal date.'),
  ('deadline', 'DEADLINE_PPH26', 1, date '2025-01-01',
   '{"payment":{"day":15,"month_offset":1},"filing":{"day":20,"month_offset":1}}'::jsonb,
   'PMK 81 Tahun 2024 Pasal 94: withheld PPh Pasal 26 is paid by the 15th and reported (SPT Masa Unifikasi) by the 20th of the following month',
   'PMK 81/2024 Pasal 94 ayat (2)',
   'https://ortax.org/batas-waktu-setor-dan-lapor-pph-unifikasi', date '2026-10-02', 'verified', 'published', now(),
   'A due date that falls on a holiday moves to the next business day; holiday data is not part of the system, so the calendar shows the nominal date.'),
  -- The correction: version 1 of both rules recorded the 10th, the rule before PMK 81/2024.
  ('deadline', 'DEADLINE_PPH21', 2, date '2025-01-01',
   '{"payment":{"day":15,"month_offset":1},"filing":{"day":20,"month_offset":1}}'::jsonb,
   'PMK 81 Tahun 2024 Pasal 94: PPh Pasal 21 disetor paling lambat tanggal 15 dan dilaporkan paling lambat tanggal 20 bulan berikutnya',
   'PMK 81/2024 Pasal 94 ayat (2)',
   'https://ortax.org/ketentuan-batas-waktu-setor-dan-lapor-pph-pasal-21', date '2026-10-02', 'verified', 'published', now(),
   'Koreksi tenggat setor: PMK 81/2024 Pasal 94 ayat (2) menetapkan setor paling lambat tanggal 15 bulan berikutnya (sebelumnya tanggal 10). Dikonfirmasi lewat penjelasan resmi DJP (@kring_pajak). Jatuh tempo pada hari libur bergeser ke hari kerja berikutnya; kalender menampilkan tanggal nominal.'),
  ('deadline', 'DEADLINE_PPH23', 2, date '2026-10-01',
   '{"payment":{"day":15,"month_offset":1},"filing":{"day":20,"month_offset":1}}'::jsonb,
   'PMK 81 Tahun 2024 Pasal 94: PPh Pasal 23 (Unifikasi) disetor paling lambat tanggal 15 dan dilaporkan paling lambat tanggal 20 bulan berikutnya',
   'PMK 81/2024 Pasal 94 ayat (2)',
   'https://ortax.org/batas-waktu-setor-dan-lapor-pph-unifikasi', date '2026-10-02', 'verified', 'published', now(),
   'Koreksi tenggat setor: PMK 81/2024 Pasal 94 ayat (2) menetapkan setor paling lambat tanggal 15 bulan berikutnya (sebelumnya tanggal 10). Versi 1 sudah terbit untuk 1 Jan 2026, sehingga koreksi ini berlaku mulai masa Oktober 2026. Jatuh tempo pada hari libur bergeser ke hari kerja berikutnya; kalender menampilkan tanggal nominal.')
on conflict (code, rule_version) do nothing;
