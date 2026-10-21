import "server-only";
import { getServerEnv } from "@/lib/env";
import type { Keyboard } from "@/domain/telegram/roadmap";

/**
 * Telegram Bot API over plain `fetch` (decision 422; same "no dependency for a few HTTP calls" pattern as the Resend
 * client). Every function returns a result instead of throwing, so one failed message never breaks a webhook run.
 */

export interface TgUser {
  id: number;
  is_bot?: boolean;
  first_name?: string;
  username?: string;
}
export interface TgChat {
  id: number;
  type: "private" | "group" | "supergroup" | "channel";
  title?: string;
}
export interface TgPhotoSize {
  file_id: string;
  file_size?: number;
  width: number;
  height: number;
}
export interface TgMessage {
  message_id: number;
  message_thread_id?: number;
  from?: TgUser;
  chat: TgChat;
  text?: string;
  caption?: string;
  photo?: TgPhotoSize[];
  document?: { file_id: string; mime_type?: string; file_size?: number };
}
export interface TgCallbackQuery {
  id: string;
  from: TgUser;
  message?: TgMessage;
  data?: string;
}
export interface TgUpdate {
  update_id: number;
  message?: TgMessage;
  callback_query?: TgCallbackQuery;
}

export interface TgResult<T> {
  ok: boolean;
  result?: T;
  error?: string;
}

function token(): string | null {
  return getServerEnv().TELEGRAM_BOT_TOKEN ?? null;
}

export function telegramConfigured(): boolean {
  return token() !== null;
}

async function call<T>(method: string, body: Record<string, unknown>): Promise<TgResult<T>> {
  const t = token();
  if (!t) return { ok: false, error: "not_configured" };
  try {
    const response = await fetch(`https://api.telegram.org/bot${t}/${method}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10_000),
    });
    const json = (await response.json().catch(() => null)) as {
      ok?: boolean;
      result?: T;
      description?: string;
    } | null;
    if (!response.ok || !json?.ok)
      return { ok: false, error: (json?.description ?? `HTTP ${response.status}`).slice(0, 300) };
    return { ok: true, result: json.result as T };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : "unknown error" };
  }
}

function markup(keyboard: Keyboard | undefined) {
  if (!keyboard || keyboard.rows.length === 0) return undefined;
  return {
    inline_keyboard: keyboard.rows.map((row) =>
      row.map((b) => ({ text: b.text, callback_data: b.data })),
    ),
  };
}

export interface SendOptions {
  threadId?: number | null;
  keyboard?: Keyboard;
  replyTo?: number;
}

export function sendMessage(
  chatId: number,
  text: string,
  options: SendOptions = {},
): Promise<TgResult<TgMessage>> {
  return call<TgMessage>("sendMessage", {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    link_preview_options: { is_disabled: true },
    ...(options.threadId ? { message_thread_id: options.threadId } : {}),
    ...(options.replyTo
      ? { reply_parameters: { message_id: options.replyTo, allow_sending_without_reply: true } }
      : {}),
    ...(markup(options.keyboard) ? { reply_markup: markup(options.keyboard) } : {}),
  });
}

export function editMessage(
  chatId: number,
  messageId: number,
  text: string,
  keyboard?: Keyboard,
): Promise<TgResult<TgMessage>> {
  return call<TgMessage>("editMessageText", {
    chat_id: chatId,
    message_id: messageId,
    text,
    parse_mode: "HTML",
    link_preview_options: { is_disabled: true },
    reply_markup: markup(keyboard) ?? { inline_keyboard: [] },
  });
}

export function clearKeyboard(chatId: number, messageId: number): Promise<TgResult<unknown>> {
  return call("editMessageReplyMarkup", {
    chat_id: chatId,
    message_id: messageId,
    reply_markup: { inline_keyboard: [] },
  });
}

export function answerCallback(id: string, text?: string): Promise<TgResult<boolean>> {
  return call<boolean>("answerCallbackQuery", {
    callback_query_id: id,
    ...(text ? { text: text.slice(0, 190) } : {}),
  });
}

export function sendChatAction(
  chatId: number,
  action: "typing" | "upload_photo",
  threadId?: number | null,
) {
  return call<boolean>("sendChatAction", {
    chat_id: chatId,
    action,
    ...(threadId ? { message_thread_id: threadId } : {}),
  });
}

export function setWebhook(url: string, secret: string): Promise<TgResult<boolean>> {
  return call<boolean>("setWebhook", {
    url,
    secret_token: secret,
    allowed_updates: ["message", "callback_query"],
    drop_pending_updates: true,
    max_connections: 4,
  });
}

export function deleteWebhook(): Promise<TgResult<boolean>> {
  return call<boolean>("deleteWebhook", { drop_pending_updates: true });
}

export function getMe(): Promise<TgResult<TgUser>> {
  return call<TgUser>("getMe", {});
}

export function getWebhookInfo(): Promise<
  TgResult<{ url: string; pending_update_count: number; last_error_message?: string }>
> {
  return call("getWebhookInfo", {});
}

/** Downloads a file Telegram holds (a receipt photo). Capped at 8 MB. */
export async function downloadFile(
  fileId: string,
): Promise<{ ok: true; bytes: Uint8Array; mime: string } | { ok: false; error: string }> {
  const t = token();
  if (!t) return { ok: false, error: "not_configured" };
  const info = await call<{ file_path?: string; file_size?: number }>("getFile", {
    file_id: fileId,
  });
  if (!info.ok || !info.result?.file_path)
    return { ok: false, error: info.error ?? "no file path" };
  if ((info.result.file_size ?? 0) > 8 * 1024 * 1024) return { ok: false, error: "too_large" };
  try {
    const response = await fetch(`https://api.telegram.org/file/bot${t}/${info.result.file_path}`, {
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) return { ok: false, error: `HTTP ${response.status}` };
    const buffer = new Uint8Array(await response.arrayBuffer());
    if (buffer.byteLength > 8 * 1024 * 1024) return { ok: false, error: "too_large" };
    const path = info.result.file_path.toLowerCase();
    const mime = path.endsWith(".png")
      ? "image/png"
      : path.endsWith(".webp")
        ? "image/webp"
        : "image/jpeg";
    return { ok: true, bytes: buffer, mime };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : "unknown error" };
  }
}
