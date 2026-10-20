import { timingSafeEqual } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { getServerEnv } from "@/lib/env";
import type { TgUpdate } from "@/services/telegram/api";
import { handleUpdate } from "@/services/telegram/bot";
import { createBotDeps } from "@/services/telegram/runtime";

/**
 * Telegram webhook (decision 422). Telegram sends the secret chosen at `setWebhook` in
 * `X-Telegram-Bot-Api-Secret-Token`; anything without it is rejected before the body is even read. Answers 200 for
 * every authenticated update (the bot reports its own problems in the chat), so Telegram never retry-storms.
 */
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 30;

function sameSecret(given: string | null, expected: string): boolean {
  if (!given) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export async function POST(request: NextRequest) {
  const secret = getServerEnv().TELEGRAM_WEBHOOK_SECRET;
  if (!secret) return NextResponse.json({ ok: false, error: "not configured" }, { status: 503 });
  if (!sameSecret(request.headers.get("x-telegram-bot-api-secret-token"), secret)) {
    return NextResponse.json({ ok: false }, { status: 401 });
  }
  const deps = createBotDeps();
  if (!deps) return NextResponse.json({ ok: false, error: "not configured" }, { status: 503 });

  const raw = await request.text();
  if (raw.length > 200_000) return NextResponse.json({ ok: true });
  let update: TgUpdate;
  try {
    update = JSON.parse(raw) as TgUpdate;
  } catch {
    return NextResponse.json({ ok: false }, { status: 400 });
  }
  if (typeof update?.update_id !== "number")
    return NextResponse.json({ ok: false }, { status: 400 });

  await handleUpdate(update, deps);
  return NextResponse.json({ ok: true });
}
