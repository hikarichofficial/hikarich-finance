-- P7 (Step 15 §11) part 1: tax facts and the effective-dated tax rule master.
-- Authority: Step 05 (tax architecture: §1 governing principles, §4 taxpayer profile, §13 rule updates, §14 review
-- states, §15 safety rules), Step 06 §3/§6/§8 (tax capabilities, sensitive fields, step-up), Step 08 §10 (tax
-- integrity), Step 02 (Tax domain), Step 13 §25 (money and rounding), Step 01 #41.
--
-- What this part delivers
--   * The RULE MASTER: statutory values are DATA, not code. A rule version is effective-dated, carries its legal
--     source and verification, is drafted, then published by an authorised person after a recent step-up, and is
--     immutable once published. A new law is a new version (or a repeal version); nothing is ever overwritten
--     (Step 05 §1, §13, §15). Which version applies to a date is a pure lookup: the latest published version whose
--     effective date is on or before that date.
--   * The TAXPAYER FACTS: the Entity's effective-dated tax profile (kind of taxpayer, income-tax regime, VAT
--     status, withholding role, exclusions, aggregation), the effective-dated tax facts of a counterparty
--     (residency, tax-number status, VAT status, withholding exemption) and yearly aggregation facts. Facts are
--     recorded, never overwritten. Unknown stays UNKNOWN: nothing is guessed (Step 05 §4 "no assumption policy").
--   * The ENGINE SWITCH: an Entity's tax engine is activated once, from a date, after its profile is complete.
--     Documents dated before that stay explicitly "not configured"; from then on every document is determined.
--   * The classification vocabulary ("Perlakuan Pajak", Step 01 #17): the treatment keys a document line may carry.
--
-- The determination itself, the tax ledger, payments and filing follow in the next parts.

-- ------------------------------------------------------------ idempotency of Entity-less operations
-- The rule master is global (no Entity). The idempotency helpers of P3 compared the Entity with "=", which is never
-- true for NULL, so a global operation could not be replayed. They now compare "is not distinct from"; behaviour
-- for Entity-scoped keys is unchanged.
create or replace function app_private.idem_begin(p_scope text, p_entity uuid, p_key text, p_fingerprint text)
returns uuid   -- null = new request; otherwise the recorded result id (replay)
language plpgsql as $$
declare
  v_new uuid;
  v_row public.idempotency_keys%rowtype;
begin
  if p_key is null or length(p_key) not between 8 and 200 then
    raise exception 'INVALID: idempotency key must be 8-200 characters' using errcode = 'invalid_parameter_value';
  end if;
  insert into public.idempotency_keys (scope, entity_id, key, actor_id, request_fingerprint)
  values (p_scope, p_entity, p_key, auth.uid(), p_fingerprint)
  on conflict (scope, entity_id, key) do nothing
  returning id into v_new;
  if v_new is not null then
    return null;
  end if;

  select * into v_row from public.idempotency_keys
  where scope = p_scope and entity_id is not distinct from p_entity and key = p_key;
  if v_row.request_fingerprint is distinct from p_fingerprint then
    raise exception 'INVALID: idempotency key was already used for a different request'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_row.status <> 'succeeded' then
    raise exception 'CONFLICT: this request is still in progress' using errcode = 'integrity_constraint_violation';
  end if;
  return v_row.result_id;
end
$$;

create or replace function app_private.idem_complete(
  p_scope text, p_entity uuid, p_key text, p_result_table text, p_result_id uuid)
returns void
language sql as $$
  update public.idempotency_keys
  set status = 'succeeded', result_table = p_result_table, result_id = p_result_id, completed_at = now()
  where scope = p_scope and entity_id is not distinct from p_entity and key = p_key
$$;

-- ------------------------------------------------------------ classification vocabulary (reference data)
create table public.tax_treatment_catalog (
  treatment_key text primary key check (treatment_key ~ '^[a-z][a-z0-9_]{2,60}$'),
  side text not null check (side in ('sales_vat', 'purchase_wht')),
  label text not null,
  description text not null,
  created_at timestamptz not null default now()
);
create trigger tg_forbid_update before update on public.tax_treatment_catalog
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.tax_treatment_catalog
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_treatment_catalog
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.tax_treatment_catalog');

insert into public.tax_treatment_catalog (treatment_key, side, label, description) values
  ('vat_taxable', 'sales_vat', 'Taxable supply (standard DPP)',
   'Taxable goods or services; VAT is computed on the DPP formula of the rule in force.'),
  ('vat_taxable_full_dpp', 'sales_vat', 'Taxable supply (full DPP)',
   'Taxable supply that uses the full selling price as DPP (for example luxury goods) under the rule in force.'),
  ('vat_exempt', 'sales_vat', 'VAT exempt / not collected',
   'A supply the law exempts or does not collect VAT on; no output VAT is created.'),
  ('vat_not_object', 'sales_vat', 'Not a VAT object',
   'Not subject to VAT at all; no output VAT is created.'),
  ('vat_special', 'sales_vat', 'Special VAT formula (needs review)',
   'A special DPP or "besaran tertentu" formula; the engine does not guess it and asks for review.'),
  ('vat_digital_pmse', 'sales_vat', 'Digital / PMSE (needs review)',
   'Cross-border digital transaction with its own VAT mechanics; the engine asks for review.'),
  ('wht_none', 'purchase_wht', 'Not a withholding object',
   'The payment is not an object of income-tax withholding; the decision is recorded on the line.'),
  ('wht_rent_movable', 'purchase_wht', 'Rent (movable property)',
   'Rent of assets other than land and buildings.'),
  ('wht_service_technical', 'purchase_wht', 'Technical service',
   'Technical service (jasa teknik).'),
  ('wht_service_management', 'purchase_wht', 'Management service',
   'Management service (jasa manajemen).'),
  ('wht_service_construction', 'purchase_wht', 'Construction service',
   'Construction-related service (jasa konstruksi) that falls under the withholding rules of this rule family.'),
  ('wht_service_consulting', 'purchase_wht', 'Consulting service',
   'Consulting service (jasa konsultan).'),
  ('wht_service_other_listed', 'purchase_wht', 'Other listed service',
   'Another service the regulation lists as a withholding object; the user asserts the classification.'),
  ('wht_royalty', 'purchase_wht', 'Royalty', 'Royalty payment.'),
  ('wht_interest', 'purchase_wht', 'Interest', 'Interest payment.'),
  ('wht_prize', 'purchase_wht', 'Prize / award', 'Prize, award or bonus payment to a recipient that is not an individual.'),
  ('wht_review', 'purchase_wht', 'Not sure (needs review)',
   'The classification is not known yet; the document waits for a tax review.');

-- ------------------------------------------------------------ the rule master (global statutory data)
create table public.tax_rule_versions (
  id uuid primary key default gen_random_uuid(),
  family text not null check (family in
    ('ppn', 'pph23', 'pph_final_umkm', 'pph4_2', 'pph26', 'pph21', 'corporate_income', 'personal_income',
     'deadline', 'other')),
  code text not null check (code ~ '^[A-Z][A-Z0-9_]{2,60}$'),
  rule_version integer not null check (rule_version > 0),
  effective_from date not null,
  -- A repeal version ends the rule from its date: nothing applies afterwards until a later version is published.
  is_repeal boolean not null default false,
  params jsonb not null default '{}'::jsonb,
  source_title text not null check (length(btrim(source_title)) between 3 and 300),
  source_ref text not null check (length(btrim(source_ref)) between 1 and 300),
  source_url text check (source_url is null or (length(source_url) <= 500 and source_url ~ '^https://')),
  verified_on date not null,
  verification_status text not null default 'verified' check (verification_status in ('verified', 'needs_review')),
  status text not null default 'draft' check (status in ('draft', 'published', 'discarded')),
  notes text check (notes is null or length(notes) <= 2000),
  published_at timestamptz,
  published_by uuid,
  discarded_at timestamptz,
  discarded_by uuid,
  discard_reason text check (discard_reason is null or length(discard_reason) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (code, rule_version),
  constraint tax_rule_params_object check (jsonb_typeof(params) = 'object'),
  constraint tax_rule_published_verified check (status <> 'published' or verification_status = 'verified'),
  constraint tax_rule_state_shape check (
    case status
      when 'draft' then published_at is null and discarded_at is null
      when 'published' then published_at is not null and discarded_at is null
      else discarded_at is not null and discard_reason is not null and published_at is null
    end)
);
-- One published version per code and effective date: the lookup is then deterministic.
create unique index tax_rule_versions_published_uq on public.tax_rule_versions (code, effective_from)
  where status = 'published';
create index tax_rule_versions_lookup_idx on public.tax_rule_versions (code, effective_from desc)
  where status = 'published';

-- Shape of the parameters per rule family. Returns the first problem found, or null when the shape is valid.
-- Numbers that are decimals are written as strings so nothing ever passes through floating point.
create function app_private.tax_rule_params_problem(p_family text, p_params jsonb) returns text
language plpgsql stable as $$
declare
  v_num numeric;
  v_den numeric;
  v_x jsonb;
  v_key text;
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
  end if;
  return null;
end
$$;

-- Published versions are immutable. A draft may be edited (until published or discarded); publishing needs the
-- publish function's checks. The guard is on the row so no caller can bypass it.
create function app_private.tg_tax_rule_versions_guard() returns trigger
language plpgsql as $$
declare
  v_problem text;
  v_publish constant text[] := array['status', 'published_at', 'published_by', 'updated_at', 'updated_by', 'version'];
  v_discard constant text[] := array['status', 'discarded_at', 'discarded_by', 'discard_reason', 'updated_at',
                                      'updated_by', 'version'];
begin
  if tg_op = 'INSERT' then
    if new.status = 'discarded' then
      raise exception 'A rule version cannot start as discarded' using errcode = 'integrity_constraint_violation';
    end if;
  else
    if old.status in ('published', 'discarded') then
      raise exception 'A % rule version cannot change any more (Step 05 §15: never overwrite historical rule versions)',
        old.status using errcode = 'integrity_constraint_violation';
    end if;
    -- draft -> published / discarded may change only the state columns; a draft stays editable otherwise.
    if new.status = 'published' and (to_jsonb(new) - v_publish) is distinct from (to_jsonb(old) - v_publish) then
      raise exception 'Publishing must not change the rule content' using errcode = 'integrity_constraint_violation';
    end if;
    if new.status = 'discarded' and (to_jsonb(new) - v_discard) is distinct from (to_jsonb(old) - v_discard) then
      raise exception 'Discarding must not change the rule content' using errcode = 'integrity_constraint_violation';
    end if;
    if new.status = 'draft' and (new.code is distinct from old.code or new.rule_version is distinct from old.rule_version) then
      raise exception 'The code and version of a rule draft cannot change' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  if new.status = 'published' and not new.is_repeal then
    v_problem := app_private.tax_rule_params_problem(new.family, new.params);
    if v_problem is not null then
      raise exception 'INVALID: rule parameters: %', v_problem using errcode = 'invalid_parameter_value';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.tax_rule_versions
  for each row execute function app_private.tg_tax_rule_versions_guard();
create trigger tg_forbid_delete before delete on public.tax_rule_versions
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_rule_versions
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_rule_versions', false);
call app_private.secure_table('public.tax_rule_versions');
create trigger tg_audit after insert or update or delete on public.tax_rule_versions
  for each row execute function app_private.tg_audit('');

-- The version of a rule in force on a date: the latest published version whose effective date is on or before
-- it. A repeal version means "no rule": the caller receives an empty row.
create function app_private.tax_rule_at(p_code text, p_date date) returns public.tax_rule_versions
language plpgsql stable as $$
declare
  r public.tax_rule_versions%rowtype;
begin
  select * into r from public.tax_rule_versions v
  where v.code = p_code and v.status = 'published' and v.effective_from <= p_date
  order by v.effective_from desc, v.rule_version desc
  limit 1;
  if not found or r.is_repeal then
    return null;
  end if;
  return r;
end
$$;

-- ------------------------------------------------------------ rule master workflow (Step 05 §13)
-- Research -> source verification -> DRAFT -> test/regression -> OWNER/Admin PUBLISH -> effective date.
create function public.tax_rule_draft_save(
  p_key text, p_rule uuid, p_family text, p_code text, p_effective_from date, p_is_repeal boolean, p_params jsonb,
  p_source_title text, p_source_ref text, p_source_url text, p_verified_on date, p_verification_status text,
  p_notes text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
  v_problem text;
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_next integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_any_permission('tax.manage_rules') then
    raise exception 'FORBIDDEN: missing tax.manage_rules' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.rule_draft', null, p_key,
    md5(jsonb_build_object('r', p_rule, 'f', p_family, 'c', v_code, 'e', p_effective_from, 'x', p_is_repeal,
                           'p', p_params, 'st', p_source_title, 'sr', p_source_ref, 'su', p_source_url,
                           'v', p_verified_on, 'vs', p_verification_status, 'n', p_notes)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p_effective_from is null or p_verified_on is null then
    raise exception 'INVALID: a rule needs an effective date and the date it was verified'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_verified_on > current_date + 1 then
    raise exception 'INVALID: the verification date cannot be in the future' using errcode = 'invalid_parameter_value';
  end if;
  if coalesce(p_verification_status, 'verified') not in ('verified', 'needs_review') then
    raise exception 'INVALID: verification status is verified or needs_review' using errcode = 'invalid_parameter_value';
  end if;
  v_problem := app_private.tax_rule_params_problem(p_family, coalesce(p_params, '{}'::jsonb));
  if v_problem is not null and not coalesce(p_is_repeal, false) then
    raise exception 'INVALID: rule parameters: %', v_problem using errcode = 'invalid_parameter_value';
  end if;

  if p_rule is null then
    -- The next version number of the code; concurrent drafts of the same code serialise on the code.
    perform pg_advisory_xact_lock(hashtextextended('tax_rule:' || v_code, 0));
    select coalesce(max(v.rule_version), 0) + 1 into v_next from public.tax_rule_versions v where v.code = v_code;
    if exists (select 1 from public.tax_rule_versions v where v.code = v_code and v.family <> p_family) then
      raise exception 'INVALID: the code % belongs to another rule family', v_code using errcode = 'invalid_parameter_value';
    end if;
    begin
      insert into public.tax_rule_versions
        (family, code, rule_version, effective_from, is_repeal, params, source_title, source_ref, source_url,
         verified_on, verification_status, notes)
      values (p_family, v_code, v_next, p_effective_from, coalesce(p_is_repeal, false), coalesce(p_params, '{}'::jsonb),
              btrim(coalesce(p_source_title, '')), btrim(coalesce(p_source_ref, '')), nullif(btrim(coalesce(p_source_url, '')), ''),
              p_verified_on, coalesce(p_verification_status, 'verified'), nullif(btrim(coalesce(p_notes, '')), ''))
      returning id into v_id;
    exception when check_violation then
      raise exception 'INVALID: the rule needs a family, a code, a source title and reference, an https source link and notes up to 2000 characters'
        using errcode = 'invalid_parameter_value';
    end;
  else
    select v.id into v_id from public.tax_rule_versions v where v.id = p_rule for update;
    if v_id is null then
      raise exception 'INVALID: unknown rule version' using errcode = 'invalid_parameter_value';
    end if;
    if not exists (select 1 from public.tax_rule_versions v where v.id = p_rule and v.status = 'draft') then
      raise exception 'CONFLICT: only a draft can be edited; a published rule is never changed, publish a new version'
        using errcode = 'integrity_constraint_violation';
    end if;
    begin
      update public.tax_rule_versions
      set family = p_family, effective_from = p_effective_from, is_repeal = coalesce(p_is_repeal, false),
          params = coalesce(p_params, '{}'::jsonb), source_title = btrim(coalesce(p_source_title, '')),
          source_ref = btrim(coalesce(p_source_ref, '')), source_url = nullif(btrim(coalesce(p_source_url, '')), ''),
          verified_on = p_verified_on, verification_status = coalesce(p_verification_status, 'verified'),
          notes = nullif(btrim(coalesce(p_notes, '')), '')
      where id = p_rule;
    exception when check_violation then
      raise exception 'INVALID: the rule needs a family, a code, a source title and reference, an https source link and notes up to 2000 characters'
        using errcode = 'invalid_parameter_value';
    end;
  end if;
  perform app_private.idem_complete('tax.rule_draft', null, p_key, 'tax_rule_versions', v_id);
  return v_id;
end
$$;

-- Publishing is a material act: authority, a recent step-up, a verified source, no clash with a published version.
create function public.tax_rule_publish(p_rule uuid, p_key text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.tax_rule_versions%rowtype;
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_any_permission('tax.manage_rules') then
    raise exception 'FORBIDDEN: missing tax.manage_rules' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.rule_publish', null, p_key, md5(coalesce(p_rule::text, '')));
  if v_replay is not null then
    return v_replay;
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  select * into r from public.tax_rule_versions where id = p_rule for update;
  if not found then
    raise exception 'INVALID: unknown rule version' using errcode = 'invalid_parameter_value';
  end if;
  if r.status <> 'draft' then
    raise exception 'CONFLICT: only a draft can be published (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  if r.verification_status <> 'verified' then
    raise exception 'CONFLICT: statutory values are published only after they are verified against the official source'
      using errcode = 'integrity_constraint_violation';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('tax_rule:' || r.code, 0));
  if exists (select 1 from public.tax_rule_versions v
             where v.code = r.code and v.status = 'published' and v.effective_from = r.effective_from) then
    raise exception 'CONFLICT: a version of % is already published for %; choose a later effective date', r.code, r.effective_from
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.tax_rule_versions
  set status = 'published', published_at = now(), published_by = auth.uid()
  where id = p_rule;
  perform app_private.idem_complete('tax.rule_publish', null, p_key, 'tax_rule_versions', p_rule);
  return p_rule;
end
$$;

create function public.tax_rule_discard(p_rule uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_any_permission('tax.manage_rules') then
    raise exception 'FORBIDDEN: missing tax.manage_rules' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 5 or length(v_reason) > 500 then
    raise exception 'INVALID: give a reason of 5 to 500 characters' using errcode = 'invalid_parameter_value';
  end if;
  perform 1 from public.tax_rule_versions where id = p_rule for update;
  if not found then
    raise exception 'INVALID: unknown rule version' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.tax_rule_versions where id = p_rule and status = 'draft') then
    raise exception 'CONFLICT: only a draft can be discarded' using errcode = 'integrity_constraint_violation';
  end if;
  update public.tax_rule_versions
  set status = 'discarded', discarded_at = now(), discarded_by = auth.uid(), discard_reason = v_reason
  where id = p_rule;
end
$$;

-- The rule in force for a code on a date, for screens and for the trace ("which version applied").
create function public.tax_rule_in_force(p_code text, p_date date)
returns table (rule_id uuid, family text, code text, rule_version integer, effective_from date, params jsonb,
               source_title text, source_ref text, source_url text, verified_on date)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  r public.tax_rule_versions%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_any_permission('tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  r := app_private.tax_rule_at(upper(btrim(coalesce(p_code, ''))), p_date);
  if r.id is null then
    return;
  end if;
  return query select r.id, r.family, r.code, r.rule_version, r.effective_from, r.params, r.source_title, r.source_ref,
                      r.source_url, r.verified_on;
end
$$;

-- ------------------------------------------------------------ verified baseline (21 September 2026)
-- Every value below was checked against the DJP / Ministry of Finance publications named in its source columns on
-- the verification date. "effective_from" is the earliest date from which THIS SYSTEM asserts the value; earlier
-- dates have no rule and are sent to review rather than guessed (Step 05 §2, §15). The baseline is re-verified
-- before production go-live (DECISIONS 7).
insert into public.tax_rule_versions
  (family, code, rule_version, effective_from, params, source_title, source_ref, source_url, verified_on,
   verification_status, status, published_at, notes)
values
  ('ppn', 'PPN_STANDARD', 1, date '2025-01-01',
   '{"rate":"0.12","dpp_numerator":11,"dpp_denominator":12,"full_dpp_treatments":["vat_taxable_full_dpp"],
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'PMK 131 Tahun 2024: PPN rate 12% with DPP Nilai Lain 11/12 for non-luxury supplies',
   'PMK 131/2024; Pasal 8A and 16G UU PPN as amended by UU HPP; rounding PER-11/PJ/2025 Art. 129',
   'https://www.pajak.go.id/en/node/113453', date '2026-09-21', 'verified', 'published', now(),
   'Statutory rate 12%; the DPP is 11/12 of the selling price for non-luxury supplies, so the effective burden is 11%. Luxury goods use the full DPP (treatment vat_taxable_full_dpp). Whole-rupiah rounding, 0.50 rounds up, follows PER-11/PJ/2025 (consultant summaries; confirm against the DJP text before go-live).'),
  ('pph23', 'PPH23_RATE_2', 1, date '2026-01-01',
   '{"rate":"0.02","non_npwp_multiplier":"2",
     "objects":["wht_rent_movable","wht_service_technical","wht_service_management","wht_service_construction",
                "wht_service_consulting","wht_service_other_listed"],
     "individual_review_objects":["wht_service_technical","wht_service_management","wht_service_construction",
                                  "wht_service_consulting","wht_service_other_listed"],
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'DJP guidance: PPh Pasal 23 - 2% of the gross amount for rent (excluding land and buildings) and specified services',
   'UU PPh Pasal 23; DJP guidance "Pemotongan Pajak Penghasilan - Pasal 23"',
   'https://www.pajak.go.id/en/node/35004', date '2026-09-21', 'verified', 'published', now(),
   'Base is the gross amount (excluding VAT). The rate is 100% higher when the recipient has no NPWP. Which services qualify is the legal list of the regulation; the user asserts the classification on the line.'),
  ('pph23', 'PPH23_RATE_15', 1, date '2026-01-01',
   '{"rate":"0.15","non_npwp_multiplier":"2",
     "objects":["wht_royalty","wht_interest","wht_prize"],
     "individual_review_objects":["wht_prize"],
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'DJP guidance: PPh Pasal 23 - 15% of the gross amount for royalties, interest and prizes',
   'UU PPh Pasal 23; DJP guidance "Pemotongan Pajak Penghasilan - Pasal 23"',
   'https://www.pajak.go.id/en/node/35004', date '2026-09-21', 'verified', 'published', now(),
   'Dividends are handled with the equity workflows and are not part of this rule yet: a dividend line goes to review. Interest paid to banks and other statutory exclusions are not withholding objects.'),
  ('pph_final_umkm', 'PPH_FINAL_UMKM', 1, date '2026-04-22',
   '{"rate":"0.005","annual_ceiling":"4800000000",
     "eligible_kinds":["individual","perseroan_perorangan","cooperative"],
     "exempt_band":{"individual":"500000000"},
     "rounding":{"mode":"half_up","scale":0}}'::jsonb,
   'PP 20 Tahun 2026: PPh Final UMKM 0.5%, gross turnover up to Rp4.8 billion per tax year; eligible: individuals, Perseroan Perorangan, cooperatives',
   'PP 20/2026 (effective 22 April 2026, amends PP 55/2022)',
   'https://www.pajak.go.id/en/node/119950', date '2026-09-21', 'verified', 'published', now(),
   'The first Rp500 million of gross turnover is not taxed for INDIVIDUAL taxpayers only; it is never applied to a Perseroan Perorangan. Ordinary PT, CV and firma do not qualify. Individuals and Perseroan Perorangan keep the regime while they meet the criteria; cooperatives are limited to four years (not modelled here). Professional services and other exclusions are facts recorded on the taxpayer profile.'),
  ('deadline', 'DEADLINE_PPH23', 1, date '2026-01-01',
   '{"payment":{"day":10,"month_offset":1},"filing":{"day":20,"month_offset":1}}'::jsonb,
   'DJP guidance: PPh Pasal 23 is paid by the 10th and reported (SPT Masa) by the 20th of the following month',
   'DJP guidance "Pemotongan Pajak Penghasilan - Pasal 23"',
   'https://www.pajak.go.id/en/node/35004', date '2026-09-21', 'verified', 'published', now(),
   'A due date that falls on a holiday moves to the next business day; holiday data is not part of the system, so the calendar shows the nominal date.'),
  ('deadline', 'DEADLINE_PPH_FINAL_UMKM', 1, date '2026-01-01',
   '{"payment":{"day":15,"month_offset":1},"filing":{"day":20,"month_offset":1}}'::jsonb,
   'Self-paid PPh Final UMKM is paid by the 15th of the following month; SPT Masa is due by the 20th',
   'PP 55/2022 Art. 62; PMK 164/2023 Art. 7(3)',
   'https://news.ddtc.co.id/berita/nasional/1805549/kapan-paling-lambat-bayar-pph-final-umkm-05-yang-disetor-sendiri',
   date '2026-09-21', 'verified', 'published', now(),
   'Secondary source (DDTC) quoting the regulations; PP 20/2026 did not change the dates in the material reviewed. Confirm against the DJP text before go-live. A due date on a holiday moves to the next business day.'),
  ('deadline', 'DEADLINE_PPN', 1, date '2026-01-01',
   '{"payment":{"eom":true,"month_offset":1},"filing":{"eom":true,"month_offset":1}}'::jsonb,
   'VAT is paid and the SPT Masa PPN is filed by the end of the month after the tax period',
   'UU KUP and implementing rules for SPT Masa PPN',
   'https://pajakku.com/artikel/batas-waktu-penyetoran-dan-pelaporan-spt-masa-ppn-tahun-2026',
   date '2026-09-21', 'verified', 'published', now(),
   'Secondary source (Pajakku); confirm against the DJP text before go-live.');

-- ------------------------------------------------------------ taxpayer facts
-- The Entity's tax profile is effective-dated and append-only: a change is a new row (or a correction of the same
-- effective date, which supersedes the earlier row); the history stays visible (Step 05 §3, §4).
create table public.tax_entity_profiles (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  effective_from date not null,
  taxpayer_kind text not null check (taxpayer_kind in
    ('individual', 'perseroan_perorangan', 'company', 'cooperative', 'other', 'unknown')),
  residency text not null default 'unknown' check (residency in ('resident', 'non_resident', 'unknown')),
  income_regime text not null default 'unknown' check (income_regime in ('final_umkm', 'general', 'unknown')),
  -- Exclusions of the final regime (for example professional services): a fact, never inferred.
  umkm_exclusion text not null default 'unknown' check (umkm_exclusion in ('none', 'excluded', 'unknown')),
  -- Whether spouse / minor-child / individual-company turnover must be added (Step 05 §3).
  aggregation_status text not null default 'unknown' check (aggregation_status in ('none', 'applies', 'unknown')),
  vat_status text not null default 'unknown' check (vat_status in ('pkp', 'non_pkp', 'unknown')),
  withholding_agent text not null default 'unknown' check (withholding_agent in ('yes', 'no', 'unknown')),
  -- Sensitive (Step 06 §6): never copied into the audit trail and not readable through the table.
  tax_identifier text check (tax_identifier is null or length(tax_identifier) between 5 and 40),
  evidence_note text check (evidence_note is null or length(evidence_note) <= 1000),
  superseded_at timestamptz,
  superseded_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  constraint tax_profile_supersede_shape check ((superseded_at is null) = (superseded_by is null))
);
create unique index tax_entity_profiles_active_uq on public.tax_entity_profiles (entity_id, effective_from)
  where superseded_at is null;
create index tax_entity_profiles_lookup_idx on public.tax_entity_profiles (entity_id, effective_from desc)
  where superseded_at is null;

create function app_private.tg_tax_facts_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['superseded_at', 'superseded_by', 'updated_at', 'updated_by', 'version'];
begin
  if tg_op = 'UPDATE' then
    if old.superseded_at is not null then
      raise exception 'A superseded tax fact cannot change any more' using errcode = 'integrity_constraint_violation';
    end if;
    if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
      raise exception 'Tax facts are never edited; record a new fact (Step 05 §3)' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.tax_entity_profiles
  for each row execute function app_private.tg_tax_facts_guard();
create trigger tg_forbid_delete before delete on public.tax_entity_profiles
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_entity_profiles
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_entity_profiles');
call app_private.secure_table('public.tax_entity_profiles');
create trigger tg_audit after insert or update or delete on public.tax_entity_profiles
  for each row execute function app_private.tg_audit('entity_id', 'tax_identifier');

-- Tax facts of a counterparty (customer or vendor), effective-dated and append-only like the Entity profile.
create table public.tax_contact_facts (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  contact_id uuid not null,
  effective_from date not null,
  party_kind text not null default 'unknown' check (party_kind in ('individual', 'company', 'government', 'unknown')),
  residency text not null default 'unknown' check (residency in ('resident', 'non_resident', 'unknown')),
  -- Whether the counterparty has a tax number; the number itself stays on the contact (contacts.view_sensitive).
  tax_id_status text not null default 'unknown' check (tax_id_status in ('has_npwp', 'no_npwp', 'unknown')),
  pkp_status text not null default 'unknown' check (pkp_status in ('pkp', 'non_pkp', 'unknown')),
  -- A withholding exemption certificate (for example an SKB) or a final-regime declaration held on file.
  wht_exemption text not null default 'unknown' check (wht_exemption in ('none', 'certificate', 'unknown')),
  evidence_note text check (evidence_note is null or length(evidence_note) <= 1000),
  superseded_at timestamptz,
  superseded_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, contact_id) references public.contacts (entity_id, id) on delete restrict,
  constraint tax_contact_facts_supersede_shape check ((superseded_at is null) = (superseded_by is null))
);
create unique index tax_contact_facts_active_uq on public.tax_contact_facts (entity_id, contact_id, effective_from)
  where superseded_at is null;
create index tax_contact_facts_lookup_idx on public.tax_contact_facts (entity_id, contact_id, effective_from desc)
  where superseded_at is null;
create trigger tg_guard before update on public.tax_contact_facts
  for each row execute function app_private.tg_tax_facts_guard();
create trigger tg_forbid_delete before delete on public.tax_contact_facts
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_contact_facts
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_contact_facts');
call app_private.secure_table('public.tax_contact_facts');
create trigger tg_audit after insert or update or delete on public.tax_contact_facts
  for each row execute function app_private.tg_audit('entity_id');

-- Turnover of other taxpayers that the final regime must add (spouse, minor children, individual companies): a
-- yearly, evidenced fact entered by the OWNER's tax role; the engine never derives it (Step 05 §3).
create table public.tax_aggregation_facts (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  tax_year integer not null check (tax_year between 2000 and 2100),
  amount public.money_amount not null check (amount >= 0),
  description text not null check (length(btrim(description)) between 3 and 300),
  evidence_note text check (evidence_note is null or length(evidence_note) <= 1000),
  superseded_at timestamptz,
  superseded_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  constraint tax_aggregation_supersede_shape check ((superseded_at is null) = (superseded_by is null))
);
create index tax_aggregation_facts_year_idx on public.tax_aggregation_facts (entity_id, tax_year)
  where superseded_at is null;
create trigger tg_guard before update on public.tax_aggregation_facts
  for each row execute function app_private.tg_tax_facts_guard();
create trigger tg_forbid_delete before delete on public.tax_aggregation_facts
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_aggregation_facts
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_aggregation_facts');
call app_private.secure_table('public.tax_aggregation_facts');
create trigger tg_audit after insert or update or delete on public.tax_aggregation_facts
  for each row execute function app_private.tg_audit('entity_id');

-- The engine switch of an Entity: set once, from a date. Documents dated on or after it are determined.
create table public.tax_settings (
  entity_id uuid primary key references public.entities (id) on delete restrict,
  engine_active_from date,
  activated_at timestamptz,
  activated_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  constraint tax_settings_shape check ((engine_active_from is null) = (activated_at is null))
);
create function app_private.tg_tax_settings_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.engine_active_from is not null then
    raise exception 'The tax engine of an Entity is activated once; its start date never changes (Step 05 §15)'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.tax_settings
  for each row execute function app_private.tg_tax_settings_guard();
create trigger tg_forbid_delete before delete on public.tax_settings
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_settings
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_settings');
call app_private.secure_table('public.tax_settings');
create trigger tg_audit after insert or update or delete on public.tax_settings
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ fact lookups (used by the engine)
create function app_private.tax_profile_at(p_entity uuid, p_date date) returns public.tax_entity_profiles
language plpgsql stable as $$
declare
  r public.tax_entity_profiles%rowtype;
begin
  select * into r from public.tax_entity_profiles p
  where p.entity_id = p_entity and p.superseded_at is null and p.effective_from <= p_date
  order by p.effective_from desc limit 1;
  if not found then
    return null;
  end if;
  return r;
end
$$;

create function app_private.tax_contact_facts_at(p_entity uuid, p_contact uuid, p_date date)
returns public.tax_contact_facts
language plpgsql stable as $$
declare
  r public.tax_contact_facts%rowtype;
begin
  select * into r from public.tax_contact_facts f
  where f.entity_id = p_entity and f.contact_id = p_contact and f.superseded_at is null and f.effective_from <= p_date
  order by f.effective_from desc limit 1;
  if not found then
    return null;
  end if;
  return r;
end
$$;

-- The date from which an Entity's engine is active; null while it is not configured.
create function app_private.tax_engine_from(p_entity uuid) returns date
language sql stable as $$
  select s.engine_active_from from public.tax_settings s where s.entity_id = p_entity
$$;

-- ------------------------------------------------------------ recording facts (Step 06 §3: tax.confirm_facts)
create function public.tax_record_entity_profile(
  p_entity uuid, p_key text, p_effective_from date, p_taxpayer_kind text, p_residency text, p_income_regime text,
  p_umkm_exclusion text, p_aggregation_status text, p_vat_status text, p_withholding_agent text,
  p_tax_identifier text, p_evidence_note text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
  v_old uuid;
  v_ident text := nullif(btrim(coalesce(p_tax_identifier, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.confirm_facts') then
    raise exception 'FORBIDDEN: missing tax.confirm_facts' using errcode = 'insufficient_privilege';
  end if;
  -- Entity tax profile and tax identifiers: OWNER plus an explicit tax permission (Step 06 §6).
  if v_ident is not null and not (app_authz.is_owner(p_entity) or app_authz.has_permission(p_entity, 'tax.confirm_facts')) then
    raise exception 'FORBIDDEN: the tax identifier needs tax.confirm_facts' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.entity_profile', p_entity, p_key,
    md5(jsonb_build_object('d', p_effective_from, 'k', p_taxpayer_kind, 'r', p_residency, 'i', p_income_regime,
                           'x', p_umkm_exclusion, 'a', p_aggregation_status, 'v', p_vat_status,
                           'w', p_withholding_agent, 't', v_ident, 'e', p_evidence_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_effective_from is null then
    raise exception 'INVALID: the profile needs an effective date' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_effective_from);
  -- Serialise concurrent changes of the same Entity's profile.
  perform pg_advisory_xact_lock(hashtextextended('tax_profile:' || p_entity::text, 0));
  select p.id into v_old from public.tax_entity_profiles p
  where p.entity_id = p_entity and p.effective_from = p_effective_from and p.superseded_at is null;
  v_id := gen_random_uuid();
  -- The earlier fact of the same date is superseded first (one active fact per date), by the id the new one takes.
  if v_old is not null then
    update public.tax_entity_profiles set superseded_at = now(), superseded_by = v_id where id = v_old;
  end if;
  begin
    insert into public.tax_entity_profiles
      (id, entity_id, effective_from, taxpayer_kind, residency, income_regime, umkm_exclusion, aggregation_status,
       vat_status, withholding_agent, tax_identifier, evidence_note)
    values
      (v_id, p_entity, p_effective_from, coalesce(p_taxpayer_kind, 'unknown'), coalesce(p_residency, 'unknown'),
       coalesce(p_income_regime, 'unknown'), coalesce(p_umkm_exclusion, 'unknown'),
       coalesce(p_aggregation_status, 'unknown'), coalesce(p_vat_status, 'unknown'),
       coalesce(p_withholding_agent, 'unknown'), v_ident, nullif(btrim(coalesce(p_evidence_note, '')), ''));
  exception
    when check_violation then
      raise exception 'INVALID: a profile value is not one of the allowed choices, the tax identifier is 5 to 40 characters and the note up to 1000'
        using errcode = 'invalid_parameter_value';
    when unique_violation then
      raise exception 'CONFLICT: the profile changed at the same time; reload and try again'
        using errcode = 'integrity_constraint_violation';
  end;
  perform app_private.idem_complete('tax.entity_profile', p_entity, p_key, 'tax_entity_profiles', v_id);
  return v_id;
end
$$;

-- The identifier is sensitive: only the OWNER or a tax specialist may read the current one.
create function public.tax_profile_identifier(p_entity uuid, p_date date default null) returns text
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  r public.tax_entity_profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not (app_authz.is_owner(p_entity) or app_authz.has_permission(p_entity, 'tax.confirm_facts')) then
    raise exception 'FORBIDDEN: the tax identifier needs the owner or tax.confirm_facts' using errcode = 'insufficient_privilege';
  end if;
  r := app_private.tax_profile_at(p_entity, coalesce(p_date, app_private.entity_today(p_entity)));
  return r.tax_identifier;
end
$$;

create function public.tax_record_contact_facts(
  p_contact uuid, p_key text, p_effective_from date, p_party_kind text, p_residency text, p_tax_id_status text,
  p_pkp_status text, p_wht_exemption text, p_evidence_note text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  c public.contacts%rowtype;
  v_replay uuid;
  v_id uuid;
  v_old uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into c from public.contacts where id = p_contact;
  if not found or not app_authz.has_permission(c.entity_id, 'tax.confirm_facts') then
    raise exception 'FORBIDDEN: missing tax.confirm_facts' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.contact_facts', c.entity_id, p_key,
    md5(jsonb_build_object('c', p_contact, 'd', p_effective_from, 'k', p_party_kind, 'r', p_residency,
                           't', p_tax_id_status, 'p', p_pkp_status, 'w', p_wht_exemption, 'e', p_evidence_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p_effective_from is null then
    raise exception 'INVALID: the tax facts need an effective date' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_effective_from);
  perform pg_advisory_xact_lock(hashtextextended('tax_contact:' || p_contact::text, 0));
  select f.id into v_old from public.tax_contact_facts f
  where f.entity_id = c.entity_id and f.contact_id = c.id and f.effective_from = p_effective_from
    and f.superseded_at is null;
  v_id := gen_random_uuid();
  if v_old is not null then
    update public.tax_contact_facts set superseded_at = now(), superseded_by = v_id where id = v_old;
  end if;
  begin
    insert into public.tax_contact_facts
      (id, entity_id, contact_id, effective_from, party_kind, residency, tax_id_status, pkp_status, wht_exemption,
       evidence_note)
    values
      (v_id, c.entity_id, c.id, p_effective_from, coalesce(p_party_kind, 'unknown'), coalesce(p_residency, 'unknown'),
       coalesce(p_tax_id_status, 'unknown'), coalesce(p_pkp_status, 'unknown'), coalesce(p_wht_exemption, 'unknown'),
       nullif(btrim(coalesce(p_evidence_note, '')), ''));
  exception
    when check_violation then
      raise exception 'INVALID: a tax fact is not one of the allowed choices, or the note is longer than 1000 characters'
        using errcode = 'invalid_parameter_value';
    when unique_violation then
      raise exception 'CONFLICT: the tax facts changed at the same time; reload and try again'
        using errcode = 'integrity_constraint_violation';
  end;
  perform app_private.idem_complete('tax.contact_facts', c.entity_id, p_key, 'tax_contact_facts', v_id);
  return v_id;
end
$$;

create function public.tax_record_aggregation_fact(
  p_entity uuid, p_key text, p_tax_year integer, p_amount text, p_description text, p_evidence_note text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
  v_amount numeric;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.confirm_facts') then
    raise exception 'FORBIDDEN: missing tax.confirm_facts' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.aggregation_fact', p_entity, p_key,
    md5(jsonb_build_object('y', p_tax_year, 'a', p_amount, 'd', p_description, 'e', p_evidence_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_amount := app_private.parse_amount(p_amount, 'the turnover amount');
  perform pg_advisory_xact_lock(hashtextextended('tax_aggregation:' || p_entity::text || ':' || coalesce(p_tax_year::text, ''), 0));
  begin
    insert into public.tax_aggregation_facts (entity_id, tax_year, amount, description, evidence_note)
    values (p_entity, p_tax_year, v_amount, btrim(coalesce(p_description, '')), nullif(btrim(coalesce(p_evidence_note, '')), ''))
    returning id into v_id;
  exception when check_violation then
    raise exception 'INVALID: the tax year, a non-negative amount and a description of 3 to 300 characters are required'
      using errcode = 'invalid_parameter_value';
  end;
  -- The newest fact of the year replaces the earlier ones for the calculation; the earlier ones stay visible.
  update public.tax_aggregation_facts
  set superseded_at = now(), superseded_by = v_id
  where entity_id = p_entity and tax_year = p_tax_year and superseded_at is null and id <> v_id;
  perform app_private.idem_complete('tax.aggregation_fact', p_entity, p_key, 'tax_aggregation_facts', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ activating the engine (OWNER, once)
-- From the chosen date every invoice, bill and expense of the Entity gets a tax determination. It needs a complete
-- profile on that date and no document already recognised on or after it, so history is never half-determined.
create function public.tax_engine_activate(p_entity uuid, p_key text, p_from date) returns date
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  p public.tax_entity_profiles%rowtype;
  v_missing text[] := array[]::text[];
  v_clash text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.is_owner(p_entity) or not app_authz.has_permission(p_entity, 'tax.confirm_facts') then
    raise exception 'FORBIDDEN: only the OWNER activates the tax engine' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.engine_activate', p_entity, p_key, md5(coalesce(p_from::text, '')));
  if v_replay is not null then
    return p_from;
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null then
    raise exception 'INVALID: choose the date the tax engine starts' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_from);
  perform pg_advisory_xact_lock(hashtextextended('tax_profile:' || p_entity::text, 0));
  if app_private.tax_engine_from(p_entity) is not null then
    raise exception 'CONFLICT: the tax engine of this Entity is already active' using errcode = 'integrity_constraint_violation';
  end if;
  p := app_private.tax_profile_at(p_entity, p_from);
  if p.id is null then
    raise exception 'INVALID: record the taxpayer profile effective on or before % first', p_from
      using errcode = 'invalid_parameter_value';
  end if;
  if p.taxpayer_kind = 'unknown' then v_missing := array_append(v_missing, 'taxpayer kind'::text); end if;
  if p.income_regime = 'unknown' then v_missing := array_append(v_missing, 'income-tax regime'::text); end if;
  if p.vat_status = 'unknown' then v_missing := array_append(v_missing, 'VAT (PKP) status'::text); end if;
  if p.withholding_agent = 'unknown' then v_missing := array_append(v_missing, 'withholding role'::text); end if;
  if cardinality(v_missing) > 0 then
    raise exception 'INVALID: the taxpayer profile is incomplete: %', array_to_string(v_missing, ', ')
      using errcode = 'invalid_parameter_value';
  end if;
  select x.k into v_clash from (
    select 'invoice ' || coalesce(i.invoice_number, i.id::text) as k from public.invoices i
      where i.entity_id = p_entity and i.status in ('issued', 'void') and i.issue_date >= p_from
    union all
    select 'bill ' || coalesce(b.bill_number, b.id::text) from public.bills b
      where b.entity_id = p_entity and b.status in ('approved', 'void') and b.bill_date >= p_from
    union all
    select 'expense ' || coalesce(e.expense_number, e.id::text) from public.expenses e
      where e.entity_id = p_entity and e.status in ('confirmed', 'reversed') and e.expense_date >= p_from
  ) x limit 1;
  if v_clash is not null then
    raise exception 'CONFLICT: % is already recognised on or after that date; choose a later start date', v_clash
      using errcode = 'integrity_constraint_violation';
  end if;
  insert into public.tax_settings (entity_id, engine_active_from, activated_at, activated_by)
  values (p_entity, p_from, now(), auth.uid())
  on conflict (entity_id) do update
    set engine_active_from = excluded.engine_active_from, activated_at = excluded.activated_at,
        activated_by = excluded.activated_by;
  perform app_private.idem_complete('tax.engine_activate', p_entity, p_key, 'tax_settings', p_entity);
  return p_from;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.tax_treatment_catalog');
create policy tax_treatment_catalog_select on public.tax_treatment_catalog for select to authenticated
  using (app_authz.is_active_user());
call app_private.expose_select('public.tax_rule_versions');
create policy tax_rule_versions_select on public.tax_rule_versions for select to authenticated
  using (app_authz.has_any_permission('tax.view'));
call app_private.expose_select('public.tax_entity_profiles', array['tax_identifier']);
create policy tax_entity_profiles_select on public.tax_entity_profiles for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));
call app_private.expose_select('public.tax_contact_facts');
create policy tax_contact_facts_select on public.tax_contact_facts for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));
call app_private.expose_select('public.tax_aggregation_facts');
create policy tax_aggregation_facts_select on public.tax_aggregation_facts for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));
call app_private.expose_select('public.tax_settings');
create policy tax_settings_select on public.tax_settings for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));

revoke all on function app_private.tax_rule_params_problem(text, jsonb) from public;
revoke all on function app_private.tg_tax_rule_versions_guard() from public;
revoke all on function app_private.tg_tax_facts_guard() from public;
revoke all on function app_private.tg_tax_settings_guard() from public;
revoke all on function app_private.tax_rule_at(text, date) from public;
revoke all on function app_private.tax_profile_at(uuid, date) from public;
revoke all on function app_private.tax_contact_facts_at(uuid, uuid, date) from public;
revoke all on function app_private.tax_engine_from(uuid) from public;

revoke all on function public.tax_rule_draft_save(text, uuid, text, text, date, boolean, jsonb, text, text, text, date, text, text) from public, anon;
revoke all on function public.tax_rule_publish(uuid, text) from public, anon;
revoke all on function public.tax_rule_discard(uuid, text) from public, anon;
revoke all on function public.tax_rule_in_force(text, date) from public, anon;
revoke all on function public.tax_record_entity_profile(uuid, text, date, text, text, text, text, text, text, text, text, text) from public, anon;
revoke all on function public.tax_profile_identifier(uuid, date) from public, anon;
revoke all on function public.tax_record_contact_facts(uuid, text, date, text, text, text, text, text, text) from public, anon;
revoke all on function public.tax_record_aggregation_fact(uuid, text, integer, text, text, text) from public, anon;
revoke all on function public.tax_engine_activate(uuid, text, date) from public, anon;

grant execute on function public.tax_rule_draft_save(text, uuid, text, text, date, boolean, jsonb, text, text, text, date, text, text) to authenticated;
grant execute on function public.tax_rule_publish(uuid, text) to authenticated;
grant execute on function public.tax_rule_discard(uuid, text) to authenticated;
grant execute on function public.tax_rule_in_force(text, date) to authenticated;
grant execute on function public.tax_record_entity_profile(uuid, text, date, text, text, text, text, text, text, text, text, text) to authenticated;
grant execute on function public.tax_profile_identifier(uuid, date) to authenticated;
grant execute on function public.tax_record_contact_facts(uuid, text, date, text, text, text, text, text, text) to authenticated;
grant execute on function public.tax_record_aggregation_fact(uuid, text, integer, text, text, text) to authenticated;
grant execute on function public.tax_engine_activate(uuid, text, date) to authenticated;
