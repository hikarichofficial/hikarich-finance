import type { AccountActionState } from "./accountActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleAccountActionState: AccountActionState = { status: "idle" };
