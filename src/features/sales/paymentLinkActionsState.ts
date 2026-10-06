import type { PaymentLinkActionState, QuickPaymentLinkState } from "./paymentLinkActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idlePaymentLinkActionState: PaymentLinkActionState = { status: "idle" };
export const idleQuickPaymentLinkState: QuickPaymentLinkState = { status: "idle" };
