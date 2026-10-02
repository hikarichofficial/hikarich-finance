import type { ContactActionState } from "./contactActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleContactActionState: ContactActionState = { status: "idle" };
