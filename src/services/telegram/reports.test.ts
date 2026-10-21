import { describe, expect, it } from "vitest";
import { sendScheduledReports } from "./reports";
import type { TelegramStore } from "./store";

const summary = (total: number) => ({
  entityName: "PT Hikarich",
  entityType: "company",
  from: "",
  to: "",
  total,
  count: total > 0 ? 1 : 0,
  byCategory: total > 0 ? [{ name: "Makan", total, count: 1 }] : [],
  top: [],
  entries: [],
  drafts: 0,
  assetsToRegister: 0,
});

describe("sendScheduledReports", () => {
  it("sends one message per user to the private chat only, with the comparison", async () => {
    const sent: Array<{ chat: number; text: string }> = [];
    const asked: Array<[string, string]> = [];
    const store = {
      reportTargets: async () => [
        { linkId: "l1", chatId: 111 },
        { linkId: "l2", chatId: 222 },
      ],
      identify: async (u: number) =>
        u === 111
          ? {
              linkId: "l1",
              memberships: [
                { entityId: "pt", canView: true },
                { entityId: "x", canView: false },
              ],
            }
          : null,
      summary: async (_l: string, _e: string, from: string, to: string) => (
        asked.push([from, to]),
        summary(asked.length % 2 === 1 ? 90_000 : 60_000)
      ),
    } as unknown as TelegramStore;
    const run = await sendScheduledReports("weekly", {
      store,
      api: {
        sendMessage: async (chat: number, text: string) => (
          sent.push({ chat, text }),
          { ok: true }
        ),
      },
      now: () => new Date("2026-10-26T00:30:00Z"),
    });
    expect(run).toMatchObject({ targets: 2, sent: 1, failed: 1 });
    expect(sent).toHaveLength(1);
    expect(sent[0]?.chat).toBe(111);
    expect(sent[0]?.text).toContain("Laporan mingguan");
    expect(sent[0]?.text).toContain("naik");
    expect(asked[0]).toEqual(["2026-10-19", "2026-10-25"]);
    expect(asked[1]).toEqual(["2026-10-12", "2026-10-18"]);
  });
});
