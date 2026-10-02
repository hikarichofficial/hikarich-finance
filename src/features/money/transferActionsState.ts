import type { TransferActionState, TransferFormState } from "./transferActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleTransferFormState: TransferFormState = { status: "idle" };
export const idleTransferActionState: TransferActionState = { status: "idle" };
