/** The state of the add-a-category-on-the-spot form. Kept outside the "use server" file, which may export only
 * async functions (the same reason `contactActionsState.ts` exists). */
export interface QuickCreateCategoryState {
  status: "idle" | "ok" | "error";
  message?: string;
  category?: { id: string; name: string; kind: string; personal_tax_role?: string | null };
}

export const idleQuickCreateCategoryState: QuickCreateCategoryState = { status: "idle" };
