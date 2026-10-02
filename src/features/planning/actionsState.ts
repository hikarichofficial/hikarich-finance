import type { PlanningActionState, RunDueActionState } from "./actions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idlePlanningActionState: PlanningActionState = { status: "idle" };
export const idleRunDueActionState: RunDueActionState = { status: "idle" };
