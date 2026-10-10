-- Decision 394 (OWNER, 10 October 2026, after checking the regulation): the seeded rule PPH21_ANNUAL version 1
-- set "ptkp_proration":"months_worked", so an employee who started or left mid-year was given only a fraction
-- of their PTKP -- a joiner from October got 3/12 of it. That is not the rule.
--
-- PER-16/PJ/2016 Lampiran, example I.6.1.1 (Suwondo, a permanent employee who starts work on 1 September):
-- the income counted is only September to December, but the PTKP applied is the FULL annual amount
-- (Rp 58,500,000 for K/0), not four twelfths of it. The same holds under PMK 168/2023, which changed how the
-- monthly withholding is worked out (TER) but not the December recalculation: income actually received, biaya
-- jabatan capped per month of work, and the whole year's PTKP. Prorating the PTKP makes the taxable income
-- too large and the tax too high -- the employer withholds more from the employee than the law asks for.
--
-- Worked through on this Entity's own figures: an employee joining in October on Rp 8,463,320 a month would
-- have been taxed Rp 531,000 for 2026 where the correct answer is Rp 0.
--
-- A published version is never edited (Step 05 §15), so this is a NEW published version 2, identical except
-- for that one key. The unique index on (code, effective_from) needs a different date, and a payroll period is
-- looked up by its end date, so version 2 starts on 2024-01-02 and every real month from January 2024 on uses
-- it -- the same device decision 303 used for the TER category fix. No posted payroll run used version 1.
insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
select v.family, v.code, 2, date '2024-01-02',
       jsonb_set(v.params, '{ptkp_proration}', '"full_year"'::jsonb),
       v.source_title, v.source_ref, v.source_url, date '2026-10-10', 'verified', 'published', now(),
       'Koreksi versi 1: PTKP dipakai setahun penuh, tidak diprorata menurut masa kerja. Pegawai tetap dalam '
       || 'negeri yang mulai bekerja atau berhenti di tengah tahun tetap mendapat PTKP setahun; yang diprorata '
       || 'per bulan kerja hanya biaya jabatan (PER-16/PJ/2016 Lampiran contoh I.6.1.1; PMK 168/2023). Tarif, '
       || 'PTKP dan biaya jabatan sama dengan versi 1.'
from public.tax_rule_versions v
where v.code = 'PPH21_ANNUAL' and v.rule_version = 1 and v.status = 'published'
  and not exists (select 1 from public.tax_rule_versions x where x.code = 'PPH21_ANNUAL' and x.rule_version = 2);
