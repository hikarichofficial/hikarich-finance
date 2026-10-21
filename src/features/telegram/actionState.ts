import type { TelegramActionState } from "./actions";

/** Initial form state. It lives outside the "use server" file, which may export only async functions. */
export const idleTelegramState: TelegramActionState = { status: "idle" };
