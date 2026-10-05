import type { ContactActionState } from "./contactActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleContactActionState: ContactActionState = { status: "idle" };

/**
 * The state of the quick-add contact form. It lives here, not in `contactActions.ts`: a "use server" file may
 * export only async functions, and exporting this constant from there made the whole file fail to load in
 * production (every Add Customer / Add Vendor / quick-add save returned an error).
 */
export interface QuickCreateContactState {
  status: "idle" | "ok" | "error";
  message?: string;
  contact?: { id: string; display_name: string };
}

export const idleQuickCreateContactState: QuickCreateContactState = { status: "idle" };
