export interface ImportActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

export const idleImportActionState: ImportActionState = { status: "idle" };
