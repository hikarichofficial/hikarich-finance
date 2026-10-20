import "server-only";
import { timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";

/** Vercel Cron calls with `Authorization: Bearer <CRON_SECRET>`; without the secret configured the routes stay closed. */
export function cronAuthorized(header: string | null): "ok" | "closed" | "denied" {
  const secret = getServerEnv().CRON_SECRET;
  if (!secret) return "closed";
  const expected = Buffer.from(`Bearer ${secret}`);
  const given = Buffer.from(header ?? "");
  return given.length === expected.length && timingSafeEqual(given, expected) ? "ok" : "denied";
}

export function cronRefusal(state: "closed" | "denied"): NextResponse {
  return NextResponse.json(
    { ok: false, error: state === "closed" ? "not configured" : "unauthorized" },
    { status: state === "closed" ? 503 : 401 },
  );
}
