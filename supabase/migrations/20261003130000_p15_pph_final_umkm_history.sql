-- P15 (decision 274, OWNER request): the PPh Final UMKM rule for the years before PP 20/2026.
--
-- The OWNER records turnover of earlier years (the personal business since 2021). Until now the only published
-- version of PPH_FINAL_UMKM took effect on 22 April 2026, so every earlier month went to review ("no rule in
-- force"). These are the earlier versions of the same rule, added as new rows: published versions are never
-- edited (Step 05 §15), and `tax_rule_at` picks the version in force on the last day of each period.
--
-- Not modelled, as in version 1: the time limits of PP 23/2018 and PP 55/2022 (seven tax years for individuals,
-- four for cooperatives, CV and firma, three for a PT). Whether a taxpayer was still inside its limit is a fact
-- the OWNER confirms by choosing the regime on the taxpayer profile.

insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
values
  ('pph_final_umkm', 'PPH_FINAL_UMKM', 2, date '2018-07-01',
   '{"rate":"0.005","annual_ceiling":"4800000000",
     "eligible_kinds":["individual","company","cooperative"],
     "exempt_band":{},
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'PP 23 Tahun 2018: PPh Final 0.5% of gross turnover up to Rp4.8 billion per tax year; eligible: individuals, cooperatives, CV, firma and PT',
   'PP 23/2018 (effective 1 July 2018)',
   'https://peraturan.bpk.go.id/Details/82680/pp-no-23-tahun-2018', date '2026-10-03', 'verified', 'published', now(),
   'No untaxed band in these years: every rupiah of turnover is taxed at 0.5%. Time limits (7 tax years for individuals, 4 for cooperatives, CV and firma, 3 for a PT) are not modelled; the regime on the taxpayer profile states whether the taxpayer was still entitled.'),
  ('pph_final_umkm', 'PPH_FINAL_UMKM', 3, date '2022-01-01',
   '{"rate":"0.005","annual_ceiling":"4800000000",
     "eligible_kinds":["individual","company","cooperative"],
     "exempt_band":{"individual":"500000000"},
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'UU 7 Tahun 2021 (HPP): from tax year 2022 the first Rp500 million of gross turnover of an individual taxpayer is not taxed',
   'UU 7/2021 (UU HPP), UU PPh Art. 7(2a); PP 23/2018 otherwise unchanged',
   'https://peraturan.bpk.go.id/Details/185162/uu-no-7-tahun-2021', date '2026-10-03', 'verified', 'published', now(),
   'The Rp500 million band applies to INDIVIDUAL taxpayers only, per tax year, from tax year 2022. Time limits are not modelled (see version 2).'),
  ('pph_final_umkm', 'PPH_FINAL_UMKM', 4, date '2022-12-20',
   '{"rate":"0.005","annual_ceiling":"4800000000",
     "eligible_kinds":["individual","perseroan_perorangan","company","cooperative"],
     "exempt_band":{"individual":"500000000"},
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'PP 55 Tahun 2022: replaces PP 23/2018; adds Perseroan Perorangan (and BUMDes/BUMDesma) to the eligible taxpayers',
   'PP 55/2022 (effective 20 December 2022), Art. 56-62',
   'https://peraturan.bpk.go.id/Details/233488/pp-no-55-tahun-2022', date '2026-10-03', 'verified', 'published', now(),
   'In force until PP 20/2026 (version 1, 22 April 2026). The Rp500 million band is for individuals only. Time limits (7 / 4 / 3 tax years; Perseroan Perorangan 4) are not modelled.'),
  ('deadline', 'DEADLINE_PPH_FINAL_UMKM', 2, date '2018-07-01',
   '{"payment":{"day":15,"month_offset":1},"filing":{"day":20,"month_offset":1}}'::jsonb,
   'Self-paid PPh Final UMKM is paid by the 15th of the following month (PMK 99/2018; kept by PP 55/2022 and PMK 164/2023)',
   'PMK 99/PMK.03/2018; PP 55/2022 Art. 62; PMK 164/2023 Art. 7(3)',
   'https://peraturan.bpk.go.id/Details/233488/pp-no-55-tahun-2022', date '2026-10-03', 'verified', 'published', now(),
   'Same dates as version 1, for periods before 2026. Late payment of an old period is a matter for the tax office; the calendar only shows the nominal date.');
