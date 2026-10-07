-- Decision 310: the arrangement of the invoice document. Covers authorization, step-up, the validator (the six
-- blocks carrying numbers, parties, dates and amounts cannot be hidden; unknown blocks, repeats and odd values
-- are refused), the stored result, putting the standard back, and the audit trail. Synthetic data; the whole
-- file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e1 uuid;
  v_owner uuid := 'e3100000-0000-0000-0000-000000000001';
  v_admin uuid := 'e3100000-0000-0000-0000-000000000002';
  v_ids text[] := array['logo','issuer','title','customer','dates','lines','totals','payments','instructions','notes','terms'];
  v_good jsonb;
  v_rev jsonb;
  v_hidden_required jsonb;
  v_hidden_optional jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p17_layout', 'P17 Layout (synthetic)')
  returning id into e1;
  perform test_helpers.mk_user(v_owner, 'p310-owner');
  perform test_helpers.mk_user(v_admin, 'p310-admin');
  perform test_helpers.mk_member(e1, v_owner, 'owner');
  perform test_helpers.mk_member(e1, v_admin, 'finance_admin');

  v_good := jsonb_build_object('v', 1, 'logo_size', 'lg', 'blocks', (
    select jsonb_agg(jsonb_build_object('key', t.id, 'show', true, 'align', 'left', 'width', 'full') order by t.ord)
    from unnest(v_ids) with ordinality as t(id, ord)));
  v_rev := jsonb_set(v_good, '{blocks}', (select jsonb_agg(b order by o desc) from jsonb_array_elements(v_good -> 'blocks') with ordinality as x(b, o)));
  v_hidden_required := jsonb_set(v_good, '{blocks,5,show}', 'false'::jsonb);   -- the item table
  v_hidden_optional := jsonb_set(v_good, '{blocks,9,show}', 'false'::jsonb);   -- the notes

  perform test_helpers.assert(app_private.valid_invoice_layout(v_good) and app_private.valid_invoice_layout(v_rev), '0.1 a complete layout, in any order, is valid');
  perform test_helpers.assert(not app_private.valid_invoice_layout(v_hidden_required), '0.2 the item table cannot be hidden');
  perform test_helpers.assert(not app_private.valid_invoice_layout(jsonb_set(v_good, '{blocks,6,show}', 'false'::jsonb)), '0.3 the totals cannot be hidden');
  perform test_helpers.assert(app_private.valid_invoice_layout(v_hidden_optional), '0.4 the notes can be hidden');
  perform test_helpers.assert(not app_private.valid_invoice_layout(jsonb_set(v_good, '{blocks}', (v_good -> 'blocks') - 10)), '0.5 a block cannot be missing');
  perform test_helpers.assert(not app_private.valid_invoice_layout(jsonb_set(v_good, '{blocks,10,key}', '"notes"'::jsonb)), '0.6 a block cannot repeat');
  perform test_helpers.assert(not app_private.valid_invoice_layout(jsonb_set(v_good, '{blocks,0,key}', '"script"'::jsonb)), '0.7 an unknown block is refused');
  perform test_helpers.assert(not app_private.valid_invoice_layout(jsonb_set(v_good, '{blocks,0,align}', '"justify"'::jsonb)), '0.8 an unknown alignment is refused');
  perform test_helpers.assert(not app_private.valid_invoice_layout(jsonb_set(v_good, '{blocks,0,width}', '"third"'::jsonb)), '0.9 an unknown width is refused');
  perform test_helpers.assert(not app_private.valid_invoice_layout(jsonb_set(v_good, '{logo_size}', '"huge"'::jsonb)), '0.10 an unknown logo size is refused');
  perform test_helpers.assert(not app_private.valid_invoice_layout(v_good || '{"html":"<b>x</b>"}'::jsonb), '0.11 extra keys are refused');
  perform test_helpers.assert(app_private.valid_invoice_layout(jsonb_set(v_good, '{blocks,0,width}', '"fit"'::jsonb)), '0.13 a block can be as wide as its content (the logo beside the company name)');
  perform test_helpers.assert(not app_private.valid_invoice_layout('"text"'::jsonb) and not app_private.valid_invoice_layout('[]'::jsonb), '0.12 only an object is valid');

  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.set_invoice_layout(%L, %L::jsonb)', e1, v_good), 'FORBIDDEN', '1.1 finance_admin lacks system.entity_config');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner, 'aal2', interval '1 hour');
  perform test_helpers.expect_msg(format('select public.set_invoice_layout(%L, %L::jsonb)', e1, v_good), 'STEP_UP_REQUIRED', '1.2 a step-up is required');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.set_invoice_layout(%L, %L::jsonb)', e1, v_hidden_required), 'INVALID', '1.3 hiding a required block is refused');
  perform public.set_invoice_layout(e1, v_rev);
  perform test_helpers.logout();
  perform test_helpers.assert((select invoice_layout = v_rev from public.entity_profiles where entity_id = e1), '2.1 the layout is stored');
  perform test_helpers.assert(exists (select 1 from public.audit_events where entity_id = e1 and action = 'entities.invoice_layout_changed'
    and (after_state ->> 'custom')::boolean and not (before_state ->> 'custom')::boolean), '2.2 the change is audited');

  perform test_helpers.expect_error(format('update public.entity_profiles set invoice_layout = %L::jsonb where entity_id = %L', v_hidden_required, e1), null, '2.3 the table itself refuses an invalid layout');

  perform test_helpers.login(v_owner);
  perform public.set_invoice_layout(e1, null);
  perform test_helpers.logout();
  perform test_helpers.assert((select invoice_layout is null from public.entity_profiles where entity_id = e1), '3.1 the standard arrangement can be put back');
end
$$;

rollback;
