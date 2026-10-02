import type { JournalActionState, PeriodActionState } from "./actions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleJournalActionState: JournalActionState = { status: "idle" };
export const idlePeriodActionState: PeriodActionState = { status: "idle" };
