import type { OpeningActionState } from "./openingBalanceActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleOpeningActionState: OpeningActionState = { status: "idle" };
