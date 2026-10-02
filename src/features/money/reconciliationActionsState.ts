import type { ReconActionState } from "./reconciliationActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleReconActionState: ReconActionState = { status: "idle" };
