"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useState } from "react";
import { hasDetailedQuantity } from "@/domain/purchases/expenseAmount";
import { AmountModeToggle } from "./AmountModeToggle";
import { useActionState } from "@/features/feedback/useActionState";
import type { CategoryRow } from "@/schemas/categories";
import type { LineSuggestion } from "@/domain/sales/lineSuggestions";
import type { ContactRow } from "@/schemas/contacts";
import {
  buildInitialRecurringLines,
  buildRecurringLinesJson,
  newRecurringLineRow,
  RecurringLinesEditor,
  type RecurringLineRow,
} from "@/features/planning/RecurringLinesEditor";
import { ContactPicker } from "@/features/contacts/ContactPicker";
import { QuickAddContactDrawer } from "@/features/contacts/QuickAddContactDrawer";
import { ProblemNotice } from "@/features/feedback/ProblemNotice";
import { ProblemField, useAnswerSerial } from "@/features/feedback/ProblemField";
import { FORM_FIELD_HINTS, type ProblemTarget } from "@/domain/forms/problemTargets";
import { createBillAction } from "./actions";
import { idleBillActionState } from "./actionsState";

/**
 * Record Bill (Step 09 §12, decision 257): the vendor's invoice as a draft through `create_bill_draft`.
 * Submitting and approving (which posts it and recognises its tax) stay on the Bill Detail page, so a
 * mistyped amount never reaches the ledger in the same click. Lines reuse `RecurringLinesEditor` with
 * kind `bill` and its tax fields: the withholding object, the VAT the vendor charged and the tax-invoice
 * number are facts the P7 engine reads from the line; the engine, not this form, decides the tax.
 */
export function BillForm({
  vendors,
  categories,
  whtAgent,
  suggestions = [],
  entity,
  today,
  initial,
  initialProblems = [],
}: {
  vendors: readonly ContactRow[];
  categories: readonly CategoryRow[];
  /** The Entity withholds tax: a line whose category does not settle it must be answered. */
  whtAgent?: boolean;
  /** Descriptions used before, for the popup above each line's description (OWNER, 5 October 2026). */
  suggestions?: readonly LineSuggestion[];
  entity: string | undefined;
  today: string;
  /** Fields to paint red when the form opens from a refused submit on the Detail page. */
  initialProblems?: readonly ProblemTarget[];
  /** Present when editing an existing draft (decision 261): the same form saves through `update_bill_draft`. */
  initial?: {
    id: string;
    version: number;
    vendor_id: string;
    vendor_reference: string | null;
    bill_date: string;
    due_date: string;
    notes: string | null;
    lines: readonly Record<string, unknown>[];
  };
}) {
  const [state, action, pending] = useActionState(createBillAction, idleBillActionState);
  const actionForm = usePreservingForm(action, state);
  const serial = useAnswerSerial(state);
  const [attempted, setAttempted] = useState(false);
  const problems: readonly ProblemTarget[] =
    state.status === "error" ? (state.targets ?? []) : initialProblems;
  const formProblem = (field: "date" | "due" | "payee" | "receipt" | "lines") =>
    problems.some((t) => t.scope === "form" && t.field === field);
  // Local copy so a vendor added on the spot is picked straight away without reloading the form.
  // One amount per line unless the person asks for the detail (decision 353); a draft with a quantity other than
  // 1 opens in the detailed mode.
  const [detailed, setDetailed] = useState(initial ? hasDetailedQuantity(initial.lines) : false);
  const [vendorList, setVendorList] = useState<{ id: string; display_name: string }[]>(
    vendors.map((v) => ({ id: v.id, display_name: v.display_name })),
  );
  const [vendorId, setVendorId] = useState(initial?.vendor_id ?? "");
  const [addingVendor, setAddingVendor] = useState(false);
  const [newVendorName, setNewVendorName] = useState("");
  const [rows, setRows] = useState<RecurringLineRow[]>(
    initial && initial.lines.length > 0
      ? buildInitialRecurringLines(initial.lines)
      : [newRecurringLineRow(1)],
  );

  return (
    <>
      <form {...actionForm} className="record-form record-form-wide">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="lines" value={buildRecurringLinesJson(rows, "bill")} />
        {initial ? (
          <>
            <input type="hidden" name="bill_id" value={initial.id} />
            <input type="hidden" name="version" value={initial.version} />
          </>
        ) : null}

        <ProblemField active={formProblem("payee")} hint={FORM_FIELD_HINTS.payee} serial={serial}>
          <ContactPicker
            label="Vendor"
            name="vendor_id"
            noun="vendor"
            contacts={vendorList}
            value={vendorId}
            onChange={setVendorId}
            onAddNew={(typedName) => {
              setNewVendorName(typedName);
              setAddingVendor(true);
            }}
          />
        </ProblemField>
        <ProblemField
          active={formProblem("receipt")}
          hint={FORM_FIELD_HINTS.receipt}
          serial={serial}
        >
          <label>
            Nomor Invoice dari Vendor (opsional)
            <input
              name="vendor_reference"
              maxLength={100}
              defaultValue={initial?.vendor_reference ?? ""}
            />
          </label>
        </ProblemField>
        <ProblemField active={formProblem("date")} hint={FORM_FIELD_HINTS.date} serial={serial}>
          <label>
            Tanggal Tagihan
            <input
              type="date"
              name="bill_date"
              required
              defaultValue={initial?.bill_date ?? today}
            />
          </label>
        </ProblemField>
        <ProblemField active={formProblem("due")} hint={FORM_FIELD_HINTS.due} serial={serial}>
          <label>
            Jatuh Tempo
            <input type="date" name="due_date" required defaultValue={initial?.due_date ?? today} />
          </label>
        </ProblemField>

        <AmountModeToggle
          detailed={detailed}
          onDetailedChange={setDetailed}
          onRows={setRows}
          noun="tagihan"
        />
        <RecurringLinesEditor
          amountOnly={!detailed}
          kind="bill"
          categories={categories}
          whtAgent={whtAgent}
          entity={entity}
          suggestions={suggestions}
          rows={rows}
          onChange={setRows}
          taxFields
          problems={problems}
          problemSerial={serial}
          attempted={attempted}
        />
        {formProblem("lines") ? (
          <p className="field-problem-hint">{FORM_FIELD_HINTS.lines}</p>
        ) : null}
        <p className="hint">
          Potongan PPh dan PPN dihitung otomatis dari isian pajak tiap baris dan data pajak vendor.
          Hasilnya terlihat di halaman tagihan sebelum disetujui.
        </p>

        <label>
          Catatan (opsional)
          <textarea name="notes" maxLength={2000} defaultValue={initial?.notes ?? ""} />
        </label>

        {state.status === "error" ? (
          <ProblemNotice message={state.message} targets={state.targets} />
        ) : null}
        <button
          type="submit"
          className="btn-primary"
          disabled={pending}
          onClick={() => setAttempted(true)}
        >
          {pending ? "Menyimpan…" : initial ? "Simpan Perubahan" : "Simpan sebagai Draf"}
        </button>
      </form>
      {/* Outside the form: a form inside a form is invalid HTML (see InvoiceForm). */}
      <QuickAddContactDrawer
        contactKind="vendor"
        entity={entity}
        initialName={newVendorName}
        open={addingVendor}
        onClose={() => setAddingVendor(false)}
        onCreated={(contact) => {
          setVendorList((list) => [...list, contact]);
          setVendorId(contact.id);
          setAddingVendor(false);
        }}
      />
    </>
  );
}
