import "server-only";
import { getServerEnv } from "@/lib/env";
import { createTelegramBotClient } from "@/lib/supabase/bot";
import * as telegram from "./api";
import type { BotAi, BotApi, BotDeps } from "./bot";
import * as gemini from "./gemini";
import { createStore } from "./store";

/** Wires the bot to the real Telegram API, Gemini and the database. Null when the bot is not configured. */
export function createBotDeps(): BotDeps | null {
  const client = createTelegramBotClient();
  if (!client || !telegram.telegramConfigured()) return null;
  const api: BotApi = {
    sendMessage: telegram.sendMessage,
    editMessage: telegram.editMessage,
    clearKeyboard: telegram.clearKeyboard,
    answerCallback: telegram.answerCallback,
    downloadFile: telegram.downloadFile,
    sendChatAction: (chatId, action, threadId) => telegram.sendChatAction(chatId, action, threadId),
  };
  const ai: BotAi = {
    enabled: gemini.aiEnabled,
    readText: gemini.readText,
    readReceipt: gemini.readReceipt,
  };
  return {
    store: createStore(client),
    api,
    ai,
    now: () => new Date(),
    newId: () => crypto.randomUUID(),
    appUrl: getServerEnv().APP_URL.replace(/\/$/, ""),
  };
}
