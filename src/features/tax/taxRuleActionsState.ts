import type { RuleActionState } from "./taxRuleActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleRuleActionState: RuleActionState = { status: "idle" };
