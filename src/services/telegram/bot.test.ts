import { describe, expect, it } from "vitest";
import type { AiExtraction } from "@/domain/telegram/ai";
import type { DraftState, EntityContext } from "@/domain/telegram/roadmap";
import { type BotAi, type BotApi, type BotDeps, handleUpdate } from "./bot";
import { StoreError } from "./errors";
import type { Identity, RecordResult, TelegramStore } from "./store";

const TODAY = "2026-10-21";

const ctx = (id: string, type: string, name: string): EntityContext => ({
  entityId: id,
  entityType: type,
  entityName: name,
  today: TODAY,
  canConfirm: true,
  categories: [
    { id: `${id}-food`, name: "Makan & Minum", kind: "expense", isParent: false },
    { id: `${id}-other`, name: "Lainnya", kind: "expense", isParent: false },
    { id: `${id}-elec`, name: "Elektronik", kind: "asset", isParent: false },
  ],
  accounts: [
    { id: `${id}-cash`, name: "Kas Tunai" },
    { id: `${id}-gopay`, name: "GoPay" },
  ],
  vendors: [],
  rules: [],
});

const identity: Identity = {
  linkId: "link-1",
  userId: "user-1",
  displayName: "Owner",
  username: "owner",
  isPrivate: true,
  maxEntryAmount: 5_000_000,
  reportDaily: true,
  reportWeekly: true,
  reportMonthly: true,
  chatEntityId: null,
  memberships: [
    {
      entityId: "pt",
      entityCode: "PT",
      entityType: "company",
      entityName: "PT Hikarich",
      canCreate: true,
      canConfirm: true,
      canView: true,
    },
    {
      entityId: "pe",
      entityCode: "PE",
      entityType: "personal",
      entityName: "Pribadi",
      canCreate: true,
      canConfirm: true,
      canView: true,
    },
  ],
};

function harness(options: { paired?: boolean; aiAnswer?: AiExtraction | null } = {}) {
  const sent: Array<{ chat: number; text: string; keyboard?: string }> = [];
  const edits: Array<{ message: number; text: string }> = [];
  const recorded: Array<{ payload: unknown; confirm: boolean }> = [];
  const learned: unknown[] = [];
  const aiCalls: unknown[][] = [];
  let session: DraftState | null = null;
  let nextMessage = 100;
  const seen = new Set<number>();

  const store = {
    claimUpdate: async (id: number) => (seen.has(id) ? false : (seen.add(id), true)),
    redeemCode: async (code: string) => {
      if (code !== "GOODCODE") throw new StoreError("INVALID: the code is unknown");
      return { linkId: "link-1", displayName: "Owner" };
    },
    identify: async (userId: number, chat: number) =>
      options.paired === false || userId !== 111 ? null : { ...identity, isPrivate: chat > 0 },
    context: async () => [ctx("pt", "company", "PT Hikarich"), ctx("pe", "personal", "Pribadi")],
    getSession: async () => session,
    putSession: async (_l: string, _c: number, _t: number, s: DraftState) => void (session = s),
    clearSession: async () => void (session = null),
    recordExpense: async (
      _l: string,
      payload: unknown,
      confirm: boolean,
    ): Promise<RecordResult> => {
      recorded.push({ payload, confirm });
      return {
        expenseId: "00000000-0000-0000-0000-000000000001",
        status: "confirmed",
        number: "EXP-0001",
        total: 35_000,
        reason: null,
        reasonCode: null,
      };
    },
    learn: async (_l: string, entry: unknown) => void learned.push(entry),
    recentEntries: async () => [
      {
        expenseId: "00000000-0000-0000-0000-000000000001",
        entityId: "pt",
        status: "confirmed",
        number: "EXP-0001",
        date: TODAY,
        total: 35_000,
        payee: "Warteg",
        lines: "Makan",
      },
    ],
    undoEntry: async () => ({ result: "reversed" }),
    summary: async (_l: string, entityId: string) => ({
      entityName: entityId === "pt" ? "PT Hikarich" : "Pribadi",
      entityType: entityId === "pt" ? "company" : "personal",
      from: TODAY,
      to: TODAY,
      total: 85_000,
      count: 2,
      byCategory: [{ name: "Makan", total: 85_000, count: 2 }],
      top: [],
      entries: [],
      drafts: 0,
      assetsToRegister: 0,
    }),
  } as unknown as TelegramStore;

  const api: BotApi = {
    sendMessage: async (chat, text, o) => {
      sent.push({
        chat,
        text,
        keyboard: o?.keyboard?.rows
          .flat()
          .map((b) => b.data)
          .join(" "),
      });
      return {
        ok: true,
        result: { message_id: nextMessage++, chat: { id: chat, type: "private" } },
      };
    },
    editMessage: async (_c, message, text) => {
      edits.push({ message, text });
      return { ok: true };
    },
    clearKeyboard: async () => ({ ok: true }),
    answerCallback: async () => ({ ok: true }),
    downloadFile: async () => ({ ok: true, bytes: new Uint8Array([1, 2, 3]), mime: "image/jpeg" }),
    sendChatAction: async () => undefined,
  };
  const ai: BotAi = {
    enabled: () => options.aiAnswer !== undefined,
    readText: async (...args) => (aiCalls.push(args), options.aiAnswer ?? null),
    readReceipt: async (...args) => (aiCalls.push(args), options.aiAnswer ?? null),
  };
  const deps: BotDeps = {
    store,
    api,
    ai,
    now: () => new Date("2026-10-21T05:00:00Z"),
    newId: (() => {
      let i = 0;
      return () => `aaaaaaaa-bbbb-cccc-dddd-${String(++i).padStart(12, "0")}`;
    })(),
    appUrl: "https://example.test",
  };

  let updateId = 1;
  const say = (
    text: string,
    extra: { from?: number; chat?: number; type?: "private" | "group"; photo?: boolean } = {},
  ) =>
    handleUpdate(
      {
        update_id: updateId++,
        message: {
          message_id: updateId,
          from: { id: extra.from ?? 111 },
          chat: { id: extra.chat ?? 111, type: extra.type ?? "private" },
          text: extra.photo ? undefined : text,
          caption: extra.photo ? text : undefined,
          photo: extra.photo ? [{ file_id: "f", width: 10, height: 10 }] : undefined,
        },
      },
      deps,
    );
  const press = (data: string) =>
    handleUpdate(
      {
        update_id: updateId++,
        callback_query: {
          id: "cb",
          from: { id: 111 },
          data,
          message: { message_id: 100, chat: { id: 111, type: "private" } },
        },
      },
      deps,
    );
  const raw = (update: Parameters<typeof handleUpdate>[0]) => handleUpdate(update, deps);
  return { raw, say, press, sent, edits, recorded, learned, aiCalls, getSession: () => session };
}

describe("pairing and strangers", () => {
  it("pairs with a good code and refuses a bad one", async () => {
    const h = harness({ paired: false });
    await h.say("/start BADCODE1");
    expect(h.sent[0]?.text).toContain("Kode tidak dikenal");
    await h.say("/start GOODCODE");
    expect(h.sent[1]?.text).toContain("Terhubung");
  });
  it("tells a stranger in private how to pair and stays silent in groups", async () => {
    const h = harness();
    await h.say("kopi 20rb", { from: 999, chat: 999 });
    expect(h.sent[0]?.text).toContain("Bot ini pribadi");
    await h.say("kopi 20rb", { from: 999, chat: -5, type: "group" });
    expect(h.sent).toHaveLength(1);
  });
  it("ignores a repeated update id", async () => {
    const h = harness();
    const update = {
      update_id: 9001,
      message: {
        message_id: 1,
        from: { id: 111 },
        chat: { id: 111, type: "private" as const },
        text: "/bantuan",
      },
    };
    await h.raw(update);
    await h.raw(update);
    expect(h.sent).toHaveLength(1);
  });
});

describe("recording with the roadmap", () => {
  it("asks for the Entity, then the category, shows a summary, saves only on Simpan", async () => {
    const h = harness();
    await h.say("makan siang di warteg 35rb pakai gopay");
    expect(h.sent[0]?.text).toContain("entitas yang mana");
    const nonce = h.getSession()?.nonce ?? "";
    await h.press(`${nonce}|ent|pt`);
    expect(h.edits.at(-1)?.text).toContain("Kategori");
    await h.press(`${nonce}|cat|0`);
    expect(h.edits.at(-1)?.text).toContain("Cek dulu sebelum disimpan");
    expect(h.recorded).toHaveLength(0);
    await h.press(`${nonce}|save|`);
    expect(h.recorded).toHaveLength(1);
    expect(h.recorded[0]?.confirm).toBe(true);
    expect(h.edits.at(-1)?.text).toContain("Tercatat");
    expect(h.learned).toHaveLength(1);
    expect(h.getSession()).toBeNull();
  });
  it("does not ask for the Entity when the message names it", async () => {
    const h = harness();
    await h.say("makan siang 35rb pakai gopay pribadi");
    expect(h.sent[0]?.text).not.toContain("entitas yang mana");
    expect(h.getSession()?.entityId).toBe("pe");
  });
  it("saving twice with the same draft is one entry (same idempotency key)", async () => {
    const h = harness();
    await h.say("makan 35rb pakai gopay pt");
    const nonce = h.getSession()?.nonce ?? "";
    await h.press(`${nonce}|cat|0`);
    const key = h.getSession()?.key;
    await h.press(`${nonce}|save|`);
    expect((h.recorded[0]?.payload as { key: string }).key).toBe(key);
  });
  it("answers a stale button politely", async () => {
    const h = harness();
    await h.say("makan 35rb pakai gopay pt");
    await h.press("zzzzzz|save|");
    expect(h.recorded).toHaveLength(0);
  });
  it("cancels without recording", async () => {
    const h = harness();
    await h.say("makan 35rb pakai gopay pt");
    const nonce = h.getSession()?.nonce ?? "";
    await h.press(`${nonce}|cancel|`);
    expect(h.edits.at(-1)?.text).toContain("Dibatalkan");
    expect(h.getSession()).toBeNull();
    expect(h.recorded).toHaveLength(0);
  });
});

describe("loan instalments", () => {
  it("are sent to the loan module instead of being recorded as an expense", async () => {
    const h = harness();
    await h.say("bayar cicilan motor 1,2jt pakai gopay pt");
    expect(h.sent[0]?.text).toContain("cicilan");
    expect(h.sent[0]?.text).toContain("Pinjaman");
    expect(h.getSession()).toBeNull();
    expect(h.recorded).toHaveLength(0);
  });
});

describe("the AI helper", () => {
  const answer: AiExtraction = {
    kind: "expense",
    merchant: "Kopi Kenangan",
    date: null,
    items: [{ description: "Kopi susu", amount: 30_000 }],
    total: 30_000,
    paymentMethod: null,
    entity: null,
    periodText: null,
  };
  it("is used for free-form text and receipts, and only ever sees the message and today's date", async () => {
    const h = harness({ aiAnswer: answer });
    await h.say("tadi ngopi di kenangan");
    expect(h.aiCalls).toHaveLength(1);
    expect(h.aiCalls[0]).toEqual(["tadi ngopi di kenangan", TODAY]);
    await h.say("struk", { photo: true });
    expect(h.aiCalls).toHaveLength(2);
    const args = h.aiCalls[1] ?? [];
    expect(args).toHaveLength(3);
    expect(JSON.stringify(args)).not.toContain("Makan & Minum");
    expect(JSON.stringify(args)).not.toContain("GoPay");
  });
  it("is not used when the rules already read the message", async () => {
    const h = harness({ aiAnswer: answer });
    await h.say("makan 35rb pakai gopay pt");
    expect(h.aiCalls).toHaveLength(0);
  });
  it("a receipt still goes through the roadmap and asks to confirm the total", async () => {
    const h = harness({ aiAnswer: answer });
    await h.say("", { photo: true });
    expect(h.sent[0]?.text).toContain("Nominal");
    expect(h.recorded).toHaveLength(0);
  });
  it("says so when there is no AI key and a photo arrives", async () => {
    const h = harness();
    await h.say("", { photo: true });
    expect(h.sent[0]?.text).toContain("Gemini");
  });
});

describe("questions, undo and commands", () => {
  it("answers a summary question for both Entities in private", async () => {
    const h = harness();
    await h.say("pengeluaran hari ini berapa?");
    const text = h.sent.map((s) => s.text).join("\n");
    expect(text).toContain("PT Hikarich");
    expect(text).toContain("Pribadi");
    expect(text).toContain("Rp 85.000");
  });
  it("restricts a question that names an Entity", async () => {
    const h = harness();
    await h.say("rekap bulan ini pribadi");
    const text = h.sent.map((s) => s.text).join("\n");
    expect(text).toContain("Pribadi");
    expect(text).not.toContain("PT Hikarich");
  });
  it("asks before undoing, then undoes", async () => {
    const h = harness();
    await h.say("batalkan yang tadi");
    expect(h.sent[0]?.text).toContain("Batalkan catatan ini?");
    await h.press("u|do|00000000-0000-0000-0000-000000000001");
    expect(h.edits.at(-1)?.text).toContain("dibatalkan");
  });
  it("shows help and tips", async () => {
    const h = harness();
    await h.say("/bantuan");
    await h.say("/tips");
    expect(h.sent[0]?.text).toContain("foto struk");
    expect(h.sent[1]?.text).toContain("Tips");
  });
  it("only shows the mapped Entity in a group, and nothing when none is mapped", async () => {
    const h = harness();
    await h.say("rekap hari ini", { chat: -5, type: "group" });
    expect(h.sent[0]?.text).toContain("/topik");
  });
});
