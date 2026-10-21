import { NextResponse, type NextRequest } from "next/server";
import { isoWeekday } from "@/domain/telegram/dates";
import { todayInBusinessZone } from "@/lib/time";
import { cronAuthorized, cronRefusal } from "@/services/telegram/cron";
import { sendScheduledReports } from "@/services/telegram/reports";
import { createBotDeps } from "@/services/telegram/runtime";

/**
 * 08.00 WITA job (Vercel Hobby allows two daily crons and fires within the hour): the weekly report on Mondays
 * (previous Monday-Sunday) and the monthly report on the 1st (previous month). Decision 422.
 */
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function GET(request: NextRequest) {
  const auth = cronAuthorized(request.headers.get("authorization"));
  if (auth !== "ok") return cronRefusal(auth);
  const deps = createBotDeps();
  if (!deps) return NextResponse.json({ ok: false, error: "not configured" }, { status: 503 });

  const today = todayInBusinessZone(deps.now());
  const runs = [];
  if (isoWeekday(today) === 1) runs.push(await sendScheduledReports("weekly", deps));
  if (today.endsWith("-01")) runs.push(await sendScheduledReports("monthly", deps));
  return NextResponse.json({ ok: true, today, runs });
}
