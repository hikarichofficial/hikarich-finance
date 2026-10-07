import type { SkuActionState } from "./skuActions";

/** Initial form state. It lives outside the "use server" file, which may export only async functions. */
export const idleSkuActionState: SkuActionState = { status: "idle" };
