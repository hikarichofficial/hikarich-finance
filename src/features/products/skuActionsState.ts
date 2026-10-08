import type { SkuActionState } from "./skuActions";

/** Initial form state. It lives outside the "use server" file, which may export only async functions. */
export const idleSkuActionState: SkuActionState = { status: "idle" };

/** The state of the add-on-the-spot panel for a brand, product type or variant: it hands the new row back. */
export interface QuickCreateSkuMasterState {
  status: "idle" | "ok" | "error";
  message?: string;
  item?: { id: string; name: string; code: string };
}

export const idleQuickCreateSkuMasterState: QuickCreateSkuMasterState = { status: "idle" };
