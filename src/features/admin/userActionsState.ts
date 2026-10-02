import type { UserActionState } from "./userActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleUserActionState: UserActionState = { status: "idle" };
