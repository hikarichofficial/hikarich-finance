import type { ProductFormState } from "./actions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleProductFormState: ProductFormState = { status: "idle" };
