import type { PtkpState } from "./personalTaxActions";

/** Initial form state. It lives outside the "use server" file, which may export only async functions. */
export const idlePtkpState: PtkpState = { status: "idle" };
