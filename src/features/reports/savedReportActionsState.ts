import type { SavedReportState } from "./savedReportActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleSavedReportState: SavedReportState = { status: "idle" };
