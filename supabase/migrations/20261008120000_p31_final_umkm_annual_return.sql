-- P31 (decision 341, OWNER request of 7 October 2026): the PPh Final UMKM deadlines, corrected against the law.
--
-- What was wrong. The tax calendar asked for a monthly return ("Lapor", the 20th of the following month) for the
-- final tax of small businesses. Under PP 55/2022 and PMK 164/2023 Art. 7(5), a taxpayer who pays the final tax
-- with a billing code and an NTPN is DEEMED to have filed the monthly return (SPT Masa PPh Unifikasi), so there is
-- no separate monthly return to file; the income is reported once a year in the annual return (SPT Tahunan: 31
-- March for an individual, 30 April for any other taxpayer, UU KUP Art. 3(3)). The payment deadline, the 15th of
-- the following month, was right and stays.
--
-- Also corrected: the withholding PPh Pasal 23 deadline. PMK 81/2024 Art. 94(2), in force since 1 January 2025,
-- sets the 15th of the following month; version 1 (10th) was published for 2026 and version 2 only from October
-- 2026, so the September 2026 period (the first the engine covers) showed the 10th. Version 3 takes effect on 2
-- January 2026 (two published versions of a rule cannot share an effective date; every period end of 2026 is after it); the later version 2 (from October 2026) still wins for later periods and says the same.
--
-- Published rule versions are never edited, so each correction is a new version. `tax_rule_at` picks the latest
-- effective date, then the highest version.
insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
values
  ('deadline', 'DEADLINE_PPH_FINAL_UMKM', 3, date '2026-01-02',
   '{"payment":{"day":15,"month_offset":1},"filing":{"day":20,"month_offset":1},"monthly_return":false,
     "annual_filing":{"individual":{"month":3,"day":31},"other":{"month":4,"day":30}}}'::jsonb,
   'PPh Final UMKM is paid by the 15th of the following month; paying it is deemed the monthly return; the income is reported once a year in the SPT Tahunan (31 March individual, 30 April other taxpayers)',
   'PMK 164/2023 Art. 7(5) (payment with NTPN deemed the SPT Masa); PMK 81/2024 Art. 94(2) (payment by the 15th); UU KUP Art. 3(3) (SPT Tahunan)',
   'https://news.ddtc.co.id/berita/nasional/1800437/pph-final-sudah-disetor-wajib-pajak-umkm-tak-wajib-lapor-spt-masa',
   date '2026-10-07', 'verified', 'published', now(),
   'Koreksi: tidak ada lapor bulanan untuk PPh Final UMKM yang disetor sendiri; penyetoran dengan kode billing dan NTPN dianggap SPT Masa. Pelaporan lewat SPT Tahunan. "filing" tetap tercatat hanya karena bentuk aturan mewajibkannya; "monthly_return": false berarti tidak ada langkah lapor bulanan. Tenggat yang jatuh pada hari libur bergeser ke hari kerja berikutnya; kalender menampilkan tanggal nominal. Sumber sekunder (DDTC, pajak.go.id/en/node/84547 untuk SPT Tahunan); konfirmasikan dengan penasihat pajak.'),
  ('deadline', 'DEADLINE_PPH23', 3, date '2026-01-02',
   '{"payment":{"day":15,"month_offset":1},"filing":{"day":20,"month_offset":1}}'::jsonb,
   'PMK 81 Tahun 2024 Pasal 94: PPh Pasal 23 (Unifikasi) disetor paling lambat tanggal 15 dan dilaporkan paling lambat tanggal 20 bulan berikutnya',
   'PMK 81/2024 Pasal 94 ayat (2)',
   'https://ortax.org/batas-waktu-setor-dan-lapor-pph-unifikasi', date '2026-10-07', 'verified', 'published', now(),
   'Koreksi tenggat setor untuk seluruh 2026 (versi 1 mencatat tanggal 10, aturan sebelum PMK 81/2024 yang berlaku sejak 1 Januari 2025). Jatuh tempo pada hari libur bergeser ke hari kerja berikutnya; kalender menampilkan tanggal nominal.')
on conflict (code, rule_version) do nothing;

create or replace function public.tax_calendar(p_entity uuid, p_from date default null, p_to date default null)
returns table (tax_type text, tax_period date, step text, due_date date, state text, outstanding text, rule_code text,
               rule_version integer, detail text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_today date;
  v_from date;
  v_to date;
  v_m date;
  t text;
  v_code text;
  r public.tax_rule_versions%rowtype;
  v_eng date;
  v_end date;
  v_relevant boolean;
  v_pay date;
  v_file date;
  a record;
  f public.tax_filings%rowtype;
  p public.tax_entity_profiles%rowtype;
  v_calc boolean;
  v_out numeric;
  v_py integer;
  v_dec date;
  v_kind text;
  v_ann jsonb;
  v_due date;
  v_annual_filed boolean;
  r2 public.tax_rule_versions%rowtype;
  p2 public.tax_entity_profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  v_today := app_private.entity_today(p_entity);
  v_eng := app_private.tax_engine_from(p_entity);
  v_from := date_trunc('month', coalesce(p_from, (v_today - interval '3 months')::date))::date;
  v_to := date_trunc('month', coalesce(p_to, v_today))::date;
  if v_to < v_from or v_to > v_from + interval '36 months' then
    raise exception 'INVALID: the calendar covers at most 36 months' using errcode = 'invalid_parameter_value';
  end if;
  v_m := v_from;
  while v_m <= v_to loop
    v_end := (v_m + interval '1 month' - interval '1 day')::date;
    foreach t in array array['vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm'] loop
      v_code := case t when 'vat' then 'DEADLINE_PPN' when 'wht_pph23' then 'DEADLINE_PPH23' when 'wht_pph21' then 'DEADLINE_PPH21' when 'wht_pph4_2' then 'DEADLINE_PPH4_2' when 'wht_pph26' then 'DEADLINE_PPH26' else 'DEADLINE_PPH_FINAL_UMKM' end;
      p := app_private.tax_profile_at(p_entity, v_end);
      select * into a from app_private.tax_period_amounts(p_entity, t, v_m, v_today);
      select * into f from public.tax_filings ff where ff.entity_id = p_entity and ff.tax_type = t and ff.tax_period = v_m and ff.status = 'filed';
      v_relevant := a.accrued_payable <> 0 or a.accrued_asset <> 0 or a.paid_payable <> 0 or f.id is not null
        or (v_eng is not null and v_eng <= v_m and p.id is not null
            and ((t = 'vat' and p.vat_status = 'pkp') or (t = 'final_umkm' and p.income_regime = 'final_umkm')));
      if not v_relevant then
        continue;
      end if;
      r := app_private.tax_rule_at(v_code, v_end);
      if r.id is null then
        tax_type := t; tax_period := v_m; step := 'pay'; due_date := null; state := 'no_rule'; outstanding := null;
        rule_code := v_code; rule_version := null; detail := 'No deadline rule is in force for this period';
        return next;
        continue;
      end if;
      v_pay := app_private.tax_due_date(r.params, 'payment', v_m);
      v_file := app_private.tax_due_date(r.params, 'filing', v_m);
      v_out := a.accrued_payable - a.paid_payable;
      rule_code := r.code; rule_version := r.rule_version; tax_type := t; tax_period := v_m;

      if t = 'final_umkm' then
        v_calc := exists (select 1 from public.tax_determinations d where d.entity_id = p_entity and d.tax_kind = 'final_umkm'
                          and d.tax_period = v_m and d.source_type = 'period' and d.superseded_at is null);
        step := 'calculate'; due_date := v_end + 1; outstanding := null;
        state := case when v_calc then 'done' when v_today > v_end then 'due' else 'upcoming' end;
        detail := case when v_calc then 'The final tax of the month is computed' else 'Compute the final tax once the month has ended' end;
        return next;
      end if;

      step := 'pay'; due_date := v_pay; outstanding := trim_scale(greatest(v_out, 0))::text;
      if a.accrued_payable = 0 and t = 'final_umkm' then
        state := 'not_applicable'; detail := 'Nothing is recognised yet for this period';
      elsif v_out <= 0 and a.accrued_payable > 0 then
        state := 'done'; detail := 'Paid';
      elsif a.accrued_payable = 0 then
        state := 'not_applicable'; detail := 'No tax was recognised for this period';
      else
        state := case when v_today > v_pay then 'overdue' when v_pay - v_today <= 10 then 'due' else 'upcoming' end;
        detail := case when v_out > 0 then trim_scale(v_out)::text || ' to pay by the deadline' else 'Settled' end;
      end if;
      return next;

      -- The final tax has no monthly return (decision 341): paying with a billing code and NTPN is deemed to be
      -- the monthly return (PMK 164/2023 Art. 7(5)), and the income is reported once a year in the SPT Tahunan,
      -- shown below. A rule version without `"monthly_return": false` keeps the monthly step as before.
      if not (t = 'final_umkm' and coalesce(r.params ->> 'monthly_return', 'true') = 'false') then
        step := 'file'; due_date := v_file; outstanding := null;
        if f.id is not null then
          state := 'done'; detail := 'Filed ' || f.filed_date::text || ' (' || f.reference || ')';
        else
          state := case when v_today > v_file then 'overdue' when v_file - v_today <= 10 then 'due' when v_end >= v_today then 'upcoming' else 'upcoming' end;
          detail := 'The return of the period is not recorded as filed';
        end if;
        return next;
      end if;

      if f.id is not null and not exists (select 1 from public.document_links l
                                          where l.entity_id = p_entity and l.target_type = 'tax_filing' and l.target_id = f.id and l.status = 'active') then
        step := 'evidence'; due_date := f.filed_date; outstanding := null; state := 'due';
        detail := 'Attach the filing receipt as evidence';
        return next;
      end if;
    end loop;

    -- The yearly return that reports the final-tax income (SPT Tahunan): shown in its due month (March for an
    -- individual, April for any other taxpayer), for the year before, when the regime was in force on 31 December.
    if extract(month from v_m) in (3, 4) then
      v_py := extract(year from v_m)::integer - 1;
      v_dec := make_date(v_py, 12, 1);
      p2 := app_private.tax_profile_at(p_entity, make_date(v_py, 12, 31));
      r2 := app_private.tax_rule_at('DEADLINE_PPH_FINAL_UMKM', make_date(v_py, 12, 31));
      if v_eng is not null and v_eng <= make_date(v_py, 12, 31) and p2.id is not null and p2.income_regime = 'final_umkm'
         and r2.id is not null and jsonb_typeof(r2.params -> 'annual_filing') = 'object' then
        v_kind := case when p2.taxpayer_kind = 'individual' then 'individual' else 'other' end;
        v_ann := r2.params -> 'annual_filing' -> v_kind;
        if v_ann is not null and (v_ann ->> 'month')::integer = extract(month from v_m)::integer then
          v_due := make_date(extract(year from v_m)::integer, (v_ann ->> 'month')::integer, (v_ann ->> 'day')::integer);
          select exists (select 1 from public.tax_filings ff where ff.entity_id = p_entity and ff.tax_type = 'final_umkm'
                         and ff.tax_period = v_dec and ff.status = 'filed') into v_annual_filed;
          tax_type := 'final_umkm'; tax_period := v_dec; step := 'file'; due_date := v_due; outstanding := null;
          rule_code := r2.code; rule_version := r2.rule_version;
          if v_annual_filed then
            state := 'done'; detail := 'Reported in the annual income tax return of ' || v_py::text;
          else
            state := case when v_today > v_due then 'overdue' when v_due - v_today <= 30 then 'due' else 'upcoming' end;
            detail := 'To be reported in the annual income tax return (SPT Tahunan) of ' || v_py::text;
          end if;
          return next;
        end if;
      end if;
    end if;
    v_m := (v_m + interval '1 month')::date;
  end loop;
end
$$;
