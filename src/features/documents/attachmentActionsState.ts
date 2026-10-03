export interface AttachmentActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

export const idleAttachmentActionState: AttachmentActionState = { status: "idle" };
