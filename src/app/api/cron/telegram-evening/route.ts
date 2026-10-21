import { NextResponse, type NextRequest } from "next/server";
import { todayInBusinessZone } from "@/lib/time";
import { cronAuthorized, cronRefusal } from "@/services/telegram/cron";
import { sendScheduledReports } from "@/services/telegram/reports";
import { createBotDeps } from "@/services/telegram/runtime";

/**
 * 21.00 WITA job: the daily report, then the bot's housekeeping (expired conversations, old update ids, used
 * pairing codes). Decision 422.
 */
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function GET(request: NextRequest) {
  const auth = cronAuthorized(request.headers.get("authorization"));
  if (auth !== "ok") return cronRefusal(auth);
  const deps = createBotDeps();
  if (!deps) return NextResponse.json({ ok: false, error: "not configured" }, { status: 503 });

  const run = await sendScheduledReports("daily", deps);
  let cleanup: unknown = null;
  try {
    cleanup = await deps.store.cleanup();
  } catch (error) {
    console.error("telegram cleanup failed", error instanceof Error ? error.message : "unknown");
  }
  return NextResponse.json({ ok: true, today: todayInBusinessZone(deps.now()), run, cleanup });
}
