"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { ContactPicker } from "@/features/contacts/ContactPicker";
import { QuickAddContactDrawer } from "@/features/contacts/QuickAddContactDrawer";
import { SuggestTextInput } from "@/features/shared/SuggestTextInput";
import type { CategoryRow } from "@/schemas/categories";
import type { LineSuggestion } from "@/domain/sales/lineSuggestions";
import type { ContactRow } from "@/schemas/contacts";
import type { MoneyControlRow } from "@/schemas/money";
import {
  buildInitialRecurringLines,
  buildRecurringLinesJson,
  newRecurringLineRow,
  RecurringLinesEditor,
  type RecurringLineRow,
} from "@/features/planning/RecurringLinesEditor";
import { hasDetailedQuantity } from "@/domain/purchases/expenseAmount";
import { AmountModeToggle } from "./AmountModeToggle";
import { ProblemNotice } from "@/features/feedback/ProblemNotice";
import { ProblemField, useAnswerSerial } from "@/features/feedback/ProblemField";
import { FORM_FIELD_HINTS, type ProblemTarget } from "@/domain/forms/problemTargets";
import { createExpenseAction } from "./expenseActions";
import { idleExpenseActionState } from "./expenseActionsState";

/**
 * Record Expense (Step 09 §12/§22: "Amount → payee/category/account → receipt → confirm", decision 245).
 * Creates a draft through `create_expense_draft`; confirming (posting) is the next step on its Detail page,
 * so a mistyped amount never reaches the ledger in the same click. Lines reuse `RecurringLinesEditor` with
 * kind `expense`, whose category/treatment pairing is exactly what `purchase_prepare_lines` validates.
 *
 * Fields that repeat from one expense to the next are type-and-pick fields (OWNER, 6 October 2026), the same
 * system as the customer on an invoice: the vendor (`ContactPicker`, with "+ Tambah vendor baru"), the recipient's
 * name (`SuggestTextInput`) and each line's description (`LineDescriptionInput`). The popup opens when typing starts.
 */
export function ExpenseForm({
  accounts,
  vendors,
  categories,
  whtAgent,
  suggestions = [],
  payeeSuggestions = [],
  entity,
  today,
  initial,
  initialProblems = [],
}: {
  accounts: readonly MoneyControlRow[];
  vendors: readonly ContactRow[];
  categories: readonly CategoryRow[];
  /** The Entity withholds tax: a line whose category does not settle it must be answered. */
  whtAgent?: boolean;
  /** Descriptions used before, for the popup above each line's description (OWNER, 5 October 2026). */
  suggestions?: readonly LineSuggestion[];
  /** Recipient names typed on earlier expenses, for the popup under "Nama Penerima" (OWNER, 6 October 2026). */
  payeeSuggestions?: readonly string[];
  entity: string | undefined;
  today: string;
  /** Fields to paint red when the form opens from a refused submit on the Detail page. */
  initialProblems?: readonly ProblemTarget[];
  /** Present when editing an existing draft: the same form saves through `update_expense_draft`. */
  initial?: {
    id: string;
    version: number;
    payee_id: string | null;
    payee_name: string | null;
    account_id: string;
    expense_date: string;
    receipt_reference: string | null;
    notes: string | null;
    lines: readonly Record<string, unknown>[];
  };
}) {
  const [state, action, pending] = useActionState(createExpenseAction, idleExpenseActionState);
  const actionForm = usePreservingForm(action, state);
  const serial = useAnswerSerial(state);
  const [attempted, setAttempted] = useState(false);
  const problems: readonly ProblemTarget[] =
    state.status === "error" ? (state.targets ?? []) : initialProblems;
  const formProblem = (field: "account" | "date" | "payee" | "receipt" | "lines") =>
    problems.some((t) => t.scope === "form" && t.field === field);
  const [rows, setRows] = useState<RecurringLineRow[]>(
    initial && initial.lines.length > 0
      ? buildInitialRecurringLines(initial.lines)
      : [newRecurringLineRow(1)],
  );
  // One amount per line, as on the receipt (OWNER, 8 October 2026); a draft that has a quantity other than 1 opens
  // in the detailed mode so nothing it holds is hidden.
  const [detailed, setDetailed] = useState(initial ? hasDetailedQuantity(initial.lines) : false);
  const [payeeId, setPayeeId] = useState(initial?.payee_id ?? "");
  // Local copy so a vendor added on the spot is picked straight away without reloading the form.
  const [vendorList, setVendorList] = useState<{ id: string; display_name: string }[]>(
    vendors.map((v) => ({ id: v.id, display_name: v.display_name })),
  );
  const [addingVendor, setAddingVendor] = useState(false);
  const [newVendorName, setNewVendorName] = useState("");

  return (
    <>
      <form {...actionForm} className="record-form record-form-wide">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="lines" value={buildRecurringLinesJson(rows, "expense")} />
        {initial ? (
          <>
            <input type="hidden" name="expense_id" value={initial.id} />
            <input type="hidden" name="version" value={initial.version} />
          </>
        ) : null}

        <ProblemField
          active={formProblem("account")}
          hint={FORM_FIELD_HINTS.account}
          serial={serial}
        >
          <label>
            Dibayar dari Rekening
            <select name="account_id" required defaultValue={initial?.account_id ?? ""}>
              <option value="" disabled>
                Pilih rekening kas/bank
              </option>
              {accounts.map((account) => (
                <option key={account.financial_account_id} value={account.financial_account_id}>
                  {account.name} ({account.currency})
                </option>
              ))}
            </select>
          </label>
        </ProblemField>
        <ProblemField active={formProblem("date")} hint={FORM_FIELD_HINTS.date} serial={serial}>
          <label>
            Tanggal
            <input
              type="date"
              name="expense_date"
              required
              defaultValue={initial?.expense_date ?? today}
            />
          </label>
        </ProblemField>
        <ProblemField active={formProblem("payee")} hint={FORM_FIELD_HINTS.payee} serial={serial}>
          <ContactPicker
            label="Vendor (opsional)"
            name="payee_id"
            noun="vendor"
            contacts={vendorList}
            value={payeeId}
            optional
            onChange={setPayeeId}
            onAddNew={(typedName) => {
              setNewVendorName(typedName);
              setAddingVendor(true);
            }}
          />
          {payeeId === "" ? (
            <SuggestTextInput
              label="Nama Penerima"
              name="payee_name"
              noun="penerima"
              suggestions={payeeSuggestions}
              required
              maxLength={200}
              placeholder="mis. Toko Bangunan Jaya"
              defaultValue={initial?.payee_name ?? ""}
            />
          ) : null}
        </ProblemField>
        <ProblemField
          active={formProblem("receipt")}
          hint={FORM_FIELD_HINTS.receipt}
          serial={serial}
        >
          <label>
            Nomor Struk / Nota (opsional)
            <input
              name="receipt_reference"
              maxLength={100}
              defaultValue={initial?.receipt_reference ?? ""}
            />
          </label>
        </ProblemField>

        <AmountModeToggle
          detailed={detailed}
          onDetailedChange={setDetailed}
          onRows={setRows}
          noun="struk"
        />
        <RecurringLinesEditor
          amountOnly={!detailed}
          kind="expense"
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
          setPayeeId(contact.id);
          setAddingVendor(false);
        }}
      />
    </>
  );
}
