import type { ComputeFinalTaxFormState } from "./taxFinalActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleComputeFinalTaxFormState: ComputeFinalTaxFormState = { status: "idle" };
