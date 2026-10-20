import {
  escapeHtml,
  formatSummary,
  joinSummaries,
  periodForReport,
  type ReportKind,
} from "@/domain/telegram/report";
import { todayInBusinessZone } from "@/lib/time";
import type { BotApi } from "./bot";
import type { TelegramStore } from "./store";

/**
 * Scheduled reports (decision 422): for each paired user who switched the kind on, one message per Entity they may
 * view, sent to their PRIVATE chat only (never a group). A Telegram private chat id equals the user's own id, which is
 * how the report finds the user's identity without a session.
 */

export interface ReportRun {
  kind: ReportKind;
  targets: number;
  sent: number;
  failed: number;
}

export async function sendScheduledReports(
  kind: ReportKind,
  deps: { store: TelegramStore; api: Pick<BotApi, "sendMessage">; now: () => Date },
): Promise<ReportRun> {
  const run: ReportRun = { kind, targets: 0, sent: 0, failed: 0 };
  const targets = await deps.store.reportTargets(kind);
  run.targets = targets.length;
  const today = todayInBusinessZone(deps.now());
  const period = periodForReport(kind, today);

  for (const target of targets) {
    try {
      const who = await deps.store.identify(target.chatId, target.chatId, 0);
      if (!who) {
        run.failed += 1;
        continue;
      }
      const parts: string[] = [];
      for (const m of who.memberships.filter((x) => x.canView)) {
        const current = await deps.store.summary(who.linkId, m.entityId, period.from, period.to);
        const previous = await deps.store.summary(
          who.linkId,
          m.entityId,
          period.prevFrom,
          period.prevTo,
        );
        parts.push(formatSummary(kind, period, current, previous.total));
      }
      if (parts.length === 0) continue;
      let ok = true;
      for (const text of joinSummaries(parts)) {
        const result = await deps.api.sendMessage(target.chatId, text);
        if (!result.ok) ok = false;
      }
      if (ok) run.sent += 1;
      else run.failed += 1;
    } catch (error) {
      run.failed += 1;
      console.error(
        "telegram report failed",
        kind,
        error instanceof Error ? escapeHtml(error.message).slice(0, 200) : "unknown",
      );
    }
  }
  return run;
}
