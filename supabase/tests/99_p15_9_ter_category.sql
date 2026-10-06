-- P15 decision 303 (OWNER, 6 October 2026): the TER category of every PTKP status follows PMK 168/2023:
-- A = TK/0, TK/1, K/0; B = TK/2, TK/3, K/1, K/2; C = K/3. Version 1 had K/0 in B and K/2 in C and stays as
-- published history; version 2 is the one in force. Synthetic; the file runs in one rolled-back transaction.
begin;
set local client_min_messages = warning;

do $$
declare
  r public.tax_rule_versions%rowtype;
  v_map jsonb;
  k text;
  expected jsonb := '{"TK/0":"A","TK/1":"A","K/0":"A","TK/2":"B","TK/3":"B","K/1":"B","K/2":"B","K/3":"C"}';
begin
  -- 1. the rule in force for a normal payroll month is version 2 with the corrected mapping
  r := app_private.tax_rule_at('PPH21_TER', date '2026-09-30');
  perform test_helpers.assert(r.rule_version = 2, '1.1 version 2 is in force for September 2026');
  v_map := r.params -> 'category_of_ptkp';
  for k in select jsonb_object_keys(expected) loop
    perform test_helpers.assert(v_map ->> k = expected ->> k, '1.2 status ' || k || ' is category ' || (expected ->> k));
  end loop;

  -- 2. January 2024 (the first TER month) also uses version 2
  perform test_helpers.assert((app_private.tax_rule_at('PPH21_TER', date '2024-01-31')).rule_version = 2,
    '2.1 January 2024 uses version 2');

  -- 3. version 1 is untouched history, and the rate tables of both versions are identical
  perform test_helpers.assert((select params -> 'category_of_ptkp' ->> 'K/0' from public.tax_rule_versions
    where code = 'PPH21_TER' and rule_version = 1) = 'B', '3.1 version 1 is kept as published');
  perform test_helpers.assert((select params -> 'tables' from public.tax_rule_versions where code = 'PPH21_TER' and rule_version = 1)
    = (select params -> 'tables' from public.tax_rule_versions where code = 'PPH21_TER' and rule_version = 2),
    '3.2 the rate tables are the same in both versions');
end
$$;

rollback;
