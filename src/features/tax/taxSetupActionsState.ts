import type { TaxSetupState } from "./taxSetupActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleTaxSetupState: TaxSetupState = { status: "idle" };
