-- Document numbering (Step 08 §16-§17): Entity-aware, sequential, never reused.
begin;
set local client_min_messages = warning;

do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  n text;
  v_id uuid;
begin
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'invoice', date '2026-09-01') = 'DMO-2026-0001', 'first number');
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'invoice', date '2026-09-02') = 'DMO-2026-0002', 'second number');
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'invoice', date '2027-01-01') = 'DMO-2027-0001', 'yearly reset');
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'invoice', date '2026-12-31') = 'DMO-2026-0003', 'old year continues');
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'payment_receipt', date '2026-09-01') = 'DMR-2026-0001', 'scopes are independent');

  -- A rolled-back issue rolls back its allocation (no gap, no reuse).
  begin
    perform app_private.allocate_document_number(pt, 'invoice', date '2026-09-03');
    raise exception 'simulated failure after allocation';
  exception when raise_exception then
    null;
  end;
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'invoice', date '2026-09-03') = 'DMO-2026-0004', 'rolled-back allocation is not consumed');

  -- Personal Entity has its own numbering space.
  insert into public.numbering_sequences (entity_id, scope, prefix) values (pe, 'invoice', 'PRS');
  perform test_helpers.assert(app_private.allocate_document_number(pe, 'invoice', date '2026-09-01') = 'PRS-2026-0001', 'Entity-aware numbering');

  -- Prefix/format changes affect future numbers only.
  update public.numbering_sequences set prefix = 'NEW' where entity_id = pt and scope = 'invoice';
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'invoice', date '2026-09-04') = 'NEW-2026-0005', 'format change is prospective');
  perform test_helpers.assert(exists (select 1 from public.issued_document_numbers where full_number = 'DMO-2026-0001'), 'old numbers preserved');

  -- Never-reset, no-year, custom separator.
  insert into public.numbering_sequences (entity_id, scope, prefix, separator, include_year, padding, reset_policy)
  values (pt, 'other', 'OTH', '', false, 3, 'never');
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'other', date '2026-09-01') = 'OTH001', 'compact format');
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'other', date '2030-09-01') = 'OTH002', 'no reset');

  perform test_helpers.expect_error(
    format('select app_private.allocate_document_number(%L, %L, %L)', pt, 'bill', date '2026-09-01'), 'P0002', 'missing sequence');
  update public.numbering_sequences set is_active = false where entity_id = pt and scope = 'payment_receipt';
  perform test_helpers.expect_error(
    format('select app_private.allocate_document_number(%L, %L, %L)', pt, 'payment_receipt', date '2026-09-01'), 'P0002', 'inactive sequence');
  perform test_helpers.expect_error(
    format('insert into public.numbering_sequences (entity_id, scope, prefix) values (%L,%L,%L)', pt, 'invoice', 'DUP'), '23505', 'one sequence per scope');
  perform test_helpers.expect_error(
    format('insert into public.numbering_sequences (entity_id, scope, prefix) values (%L,%L,%L)', pt, 'bill', 'bad prefix'), '23514', 'prefix format');

  -- Issued numbers are immutable, undeletable and only voidable.
  select id into v_id from public.issued_document_numbers where full_number = 'DMO-2026-0001';
  perform test_helpers.expect_error(format('update public.issued_document_numbers set full_number = %L where id = %L', 'X', v_id), '23000', 'number text immutable');
  perform test_helpers.expect_error(format('update public.issued_document_numbers set sequence_value = 99 where id = %L', v_id), '23000', 'sequence value immutable');
  perform test_helpers.expect_error(format('delete from public.issued_document_numbers where id = %L', v_id), '23000', 'issued numbers are never deleted');
  perform test_helpers.expect_error('truncate public.issued_document_numbers', '23000', 'no truncate');
  update public.issued_document_numbers set status = 'voided' where id = v_id;
  perform test_helpers.expect_error(format('update public.issued_document_numbers set status = %L where id = %L', 'issued', v_id), '23000', 'voided numbers stay voided');
  -- A voided number is still reserved: the counter continues.
  perform test_helpers.assert(app_private.allocate_document_number(pt, 'invoice', date '2026-09-05') = 'NEW-2026-0006', 'void does not free the number');
  perform test_helpers.assert(
    (select count(distinct full_number) from public.issued_document_numbers where entity_id = pt) = (select count(*) from public.issued_document_numbers where entity_id = pt),
    'all issued numbers are distinct');
end
$$;

rollback;
