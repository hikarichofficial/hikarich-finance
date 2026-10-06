-- Decision 303 (OWNER, 6 October 2026, task 99): the TER category of two PTKP statuses was wrong in the seeded
-- rule PPH21_TER version 1. PMK 168/2023 (and the DJP guidance): category A = TK/0, TK/1, K/0; category B =
-- TK/2, TK/3, K/1, K/2; category C = K/3. Version 1 had K/0 in B and K/2 in C, so a K/0 or K/2 employee would
-- have been taxed with the next category's table. A published version is never changed (Step 05 §15), so the
-- fix is a NEW published version 2 with the same tables and the corrected mapping. Both versions share the
-- effective date 2024-01-01 in substance; the unique index (code, effective_from) needs a different date, so
-- version 2 starts on 2024-01-02, and a payroll period is looked up by its end date, so every real month
-- (January 2024 ends on the 31st) uses version 2. No payroll run exists that used version 1.
insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
select v.family, v.code, 2, date '2024-01-02',
       jsonb_set(v.params, '{category_of_ptkp}',
         '{"TK/0":"A","TK/1":"A","K/0":"A","TK/2":"B","TK/3":"B","K/1":"B","K/2":"B","K/3":"C"}'::jsonb),
       v.source_title, v.source_ref, v.source_url, date '2026-10-06', 'verified', 'published', now(),
       'Koreksi versi 1: kategori A = TK/0, TK/1, K/0; kategori B = TK/2, TK/3, K/1, K/2; kategori C = K/3 '
       || '(PMK 168/2023, panduan DJP). Tabel tarif sama dengan versi 1. Dipakai untuk masa pajak Januari sampai '
       || 'November; hasil dibulatkan ke bawah ke rupiah penuh.'
from public.tax_rule_versions v
where v.code = 'PPH21_TER' and v.rule_version = 1 and v.status = 'published'
  and not exists (select 1 from public.tax_rule_versions x where x.code = 'PPH21_TER' and x.rule_version = 2);
