import { describe, expect, it } from "vitest";
import type { AiExtraction } from "@/domain/telegram/ai";
import type { DraftState, EntityContext } from "@/domain/telegram/roadmap";
import { type BotAi, type BotApi, type BotDeps, handleUpdate } from "./bot";
import { StoreError } from "./errors";
import type { SalesOp } from "@/domain/telegram/sales";
import type {
  FoundCustomer,
  FoundInvoice,
  Identity,
  RecordResult,
  SalesContext,
  TelegramStore,
} from "./store";

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
  lang: "id",
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

const LOAN = "11111111-2222-3333-4444-555555555555";
const ASSET = "99999999-2222-3333-4444-555555555555";

function harness(
  options: {
    paired?: boolean;
    lang?: "id" | "en";
    canAttach?: boolean;
    customers?: FoundCustomer[];
    channels?: SalesContext["channels"];
    accounts?: SalesContext["accounts"];
    invoices?: Partial<FoundInvoice>[];
    aiAnswer?: AiExtraction | null;
    assets?: Array<{
      assetId: string;
      code: string;
      name: string;
      cost: number;
      entityType: "company" | "personal";
      canManage: boolean;
    }>;
  } = {},
) {
  const sent: Array<{ chat: number; text: string; keyboard?: string }> = [];
  const edits: Array<{ message: number; text: string }> = [];
  const recorded: Array<{ payload: unknown; confirm: boolean }> = [];
  const learned: unknown[] = [];
  const paid: Array<{ key: string; loanId: string; accountId: string }> = [];
  const activated: Array<{ assetId: string; months: number | null }> = [];
  const attached: Array<{ entityId: string; expenseId: string; size: number }> = [];
  const aiCalls: unknown[][] = [];
  let language: "id" | "en" = options.lang ?? "id";
  let session: DraftState | SalesOp | null = null;
  const customersCreated: Array<{ key: string; name: string; allowSimilar: boolean }> = [];
  const invoicesIssued: Array<{
    key: string;
    customerId: string;
    amount: number;
    channelId: string | null;
    dueDate: string;
    description: string;
  }> = [];
  const paymentsRecorded: Array<{
    key: string;
    invoiceId: string;
    accountId: string;
    amount: number;
  }> = [];
  let nextMessage = 100;
  const seen = new Set<number>();

  const store = {
    claimUpdate: async (id: number) => (seen.has(id) ? false : (seen.add(id), true)),
    redeemCode: async (code: string) => {
      if (code !== "GOODCODE") throw new StoreError("INVALID: the code is unknown");
      return { linkId: "link-1", displayName: "Owner" };
    },
    identify: async (userId: number, chat: number) =>
      options.paired === false || userId !== 111
        ? null
        : { ...identity, lang: language, isPrivate: chat > 0 },
    setLanguage: async (_l: string, next: "id" | "en") => void (language = next),
    context: async () => [ctx("pt", "company", "PT Hikarich"), ctx("pe", "personal", "Pribadi")],
    getSession: async () => (session && session.v === 1 ? session : null),
    putSession: async (_l: string, _c: number, _t: number, s: DraftState) => void (session = s),
    getOpSession: async () => (session && session.v === 2 ? session : null),
    putOpSession: async (_l: string, _c: number, _t: number, s: SalesOp) => void (session = s),
    clearSession: async () => void (session = null),
    salesContext: async (): Promise<SalesContext> => ({
      today: TODAY,
      currency: "IDR",
      accounts: options.accounts ?? [
        { id: "acc-bca", name: "BCA Operasional", currency: "IDR" },
        { id: "acc-kas", name: "Kas Kecil", currency: "IDR" },
      ],
      channels: options.channels ?? [],
    }),
    salesCustomers: async () => options.customers ?? [],
    salesCreateCustomer: async (
      _l: string,
      _e: string,
      key: string,
      c: { name: string; allowSimilar: boolean },
    ) => (customersCreated.push({ key, name: c.name, allowSimilar: c.allowSimilar }), "cust-new"),
    salesIssueInvoice: async (
      _l: string,
      _e: string,
      key: string,
      i: {
        customerId: string;
        amount: number;
        channelId: string | null;
        dueDate: string;
        description: string;
      },
    ) => (
      invoicesIssued.push({ key, ...i }),
      {
        invoiceId: "inv-1",
        number: "HKD-2026-0001",
        status: "issued",
        total: i.amount,
        currency: "IDR",
        dueDate: i.dueDate,
        token: "tok123",
      }
    ),
    salesFindInvoice: async (_l: string, number: string): Promise<FoundInvoice[]> =>
      number === "HKD-2026-0001" || number === "HKD-2026-0002"
        ? (options.invoices ?? [{}]).map((o, n) => ({
            invoiceId: `inv-${n + 1}`,
            entityId: n === 0 ? "pt" : "pe",
            entityName: n === 0 ? "PT Hikarich" : "Pribadi",
            entityType: n === 0 ? "company" : "personal",
            number,
            status: "issued",
            customerId: "cust-1",
            customer: "Budi Santoso",
            currency: "IDR",
            total: 2_500_000,
            settled: 0,
            outstanding: 2_500_000,
            settlement: "unpaid",
            dueDate: "2026-11-04",
            overdue: false,
            canRecordPayment: true,
            token: "tok123",
            receipts: [],
            ...o,
          }))
        : [],
    salesRecordPayment: async (
      _l: string,
      key: string,
      p: { invoiceId: string; accountId: string; amount: number },
    ) => (
      paymentsRecorded.push({ key, ...p }),
      {
        paymentId: "pay-1",
        receiptNumber: "PAY-2026-0001",
        invoiceNumber: "HKD-2026-0001",
        settled: p.amount,
        outstanding: 2_500_000 - p.amount,
        settlement: p.amount >= 2_500_000 ? "paid" : "partial",
        token: "tok123",
      }
    ),
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
    openLoans: async () => [
      {
        loanId: LOAN,
        entityId: "pt",
        entityName: "PT Hikarich",
        loanNumber: "LN-0001",
        counterparty: "Bank Uji",
        seq: 3,
        dueDate: TODAY,
        amount: 1_200_000,
        overdue: false,
        accounts: [{ id: "acc11111-0000-0000-0000-000000000000", name: "BCA" }],
      },
    ],
    payLoan: async (_l: string, key: string, loanId: string, accountId: string) => (
      paid.push({ key, loanId, accountId }),
      "pay-1"
    ),
    expenseAssets: async () => options.assets ?? [],
    activateAsset: async (_l: string, _k: string, assetId: string, months: number | null) => (
      activated.push({ assetId, months }),
      months ?? 0
    ),
    findExpense: async (_l: string, number: string) =>
      number === "EXP-001-0003"
        ? [
            {
              expenseId: "55555555-0000-0000-0000-000000000003",
              entityId: "pt",
              entityName: "PT Hikarich",
              entityType: "company",
              number,
              status: "confirmed",
              date: "2026-10-21",
              total: 35000,
              currency: "IDR",
              payee: "Warteg",
              canAttach: options.canAttach !== false,
            },
          ]
        : [],
    attachReceipt: async (
      _l: string,
      entityId: string,
      expenseId: string,
      file: { bytes: Uint8Array },
    ) => (attached.push({ entityId, expenseId, size: file.bytes.byteLength }), true),
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
  return {
    raw,
    say,
    press,
    sent,
    edits,
    recorded,
    learned,
    attached,
    paid,
    activated,
    aiCalls,
    customersCreated,
    invoicesIssued,
    paymentsRecorded,
    getSession: () => (session && session.v === 1 ? session : null),
    getRaw: () => session,
  };
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

describe("English", () => {
  it("runs the whole roadmap in English, with the same safety", async () => {
    const h = harness({ lang: "en" });
    await h.say("lunch at warteg 35k with gopay");
    expect(h.sent[0]?.text).toContain("should this expense be recorded");
    const nonce = h.getSession()?.nonce ?? "";
    await h.press(`${nonce}|ent|pt`);
    expect(h.edits.at(-1)?.text).toContain("Category");
    await h.press(`${nonce}|cat|0`);
    expect(h.edits.at(-1)?.text).toContain("Check before saving");
    expect(h.recorded).toHaveLength(0);
    await h.press(`${nonce}|save|`);
    expect(h.recorded).toHaveLength(1);
    expect(h.edits.at(-1)?.text).toContain("Recorded");
  });
  it("understands English dates and entity words", async () => {
    const h = harness({ lang: "en" });
    await h.say("coffee 25k yesterday personal");
    expect(h.sent[0]?.text).not.toContain("should this expense be recorded");
  });
  it("switches language with /language and /bahasa", async () => {
    const h = harness();
    await h.say("/language en");
    expect(h.sent.at(-1)?.text).toContain("Language set to English");
    await h.say("/bahasa id");
    expect(h.sent.at(-1)?.text).toContain("Bahasa diatur");
    await h.say("/language");
    expect(h.sent.at(-1)?.text).toContain("Bahasa sekarang");
  });
  it("pays a loan instalment in English", async () => {
    const h = harness({ lang: "en" });
    await h.say("pay my loan installment Rp 1.200.000 with gopay");
    expect(h.sent[0]?.text).toContain("Which instalment");
    await h.press(`l|p|${LOAN}`);
    await h.press(`l|a|${LOAN}:acc11111`);
    expect(h.edits.at(-1)?.text).toContain("Check before paying");
    await h.press(`l|go|${LOAN}:acc11111`);
    expect(h.edits.at(-1)?.text).toContain("paid");
  });
});

describe("loan instalments", () => {
  it("never become an expense: the bot offers the loan flow and pays only after the last button", async () => {
    const h = harness();
    await h.say("bayar cicilan motor 1,2jt pakai gopay pt");
    expect(h.sent[0]?.text).toContain("Cicilan mana");
    expect(h.sent[0]?.text).toContain("Bank Uji");
    expect(h.getSession()).toBeNull();
    expect(h.recorded).toHaveLength(0);
    await h.press(`l|p|${LOAN}`);
    expect(h.edits.at(-1)?.text).toContain("rekening mana");
    await h.press(`l|a|${LOAN}:acc11111`);
    expect(h.edits.at(-1)?.text).toContain("Cek dulu sebelum dibayar");
    expect(h.edits.at(-1)?.text).toContain("Rp 1.200.000");
    expect(h.paid).toHaveLength(0);
    await h.press(`l|go|${LOAN}:acc11111`);
    expect(h.paid).toEqual([
      { key: `tg-loan-${LOAN}-3`, loanId: LOAN, accountId: "acc11111-0000-0000-0000-000000000000" },
    ]);
    expect(h.edits.at(-1)?.text).toContain("dibayar");
    expect(h.recorded).toHaveLength(0);
  });
  it("can be cancelled at any step", async () => {
    const h = harness();
    await h.say("/cicilan");
    await h.press("l|no|");
    expect(h.edits.at(-1)?.text).toContain("Tidak ada cicilan yang dicatat");
    expect(h.paid).toHaveLength(0);
  });
});

describe("fixed assets", () => {
  const asset = {
    assetId: ASSET,
    code: "AST-0001",
    name: "iPhone 15",
    cost: 15_000_000,
    entityType: "company" as const,
    canManage: true,
  };
  const buy = async (h: ReturnType<typeof harness>) => {
    await h.say("beli iPhone 15 untuk usaha 4jt pakai gopay pt");
    const nonce = h.getSession()?.nonce ?? "";
    await h.press(`${nonce}|acc|0`);
    await h.press(`${nonce}|as|a`);
    await h.press(`${nonce}|cat|0`);
    await h.press(`${nonce}|save|`);
  };
  it("asks how long a durable purchase is depreciated and activates only on the answer", async () => {
    const h = harness({ assets: [asset] });
    await buy(h);
    expect(h.sent.at(-1)?.text).toContain("Berapa lama masa manfaatnya");
    expect(h.sent.at(-1)?.keyboard).toContain(`a|96|${ASSET}`);
    expect(h.activated).toHaveLength(0);
    await h.press(`a|96|${ASSET}`);
    expect(h.activated).toEqual([{ assetId: ASSET, months: 96 }]);
    expect(h.edits.at(-1)?.text).toContain("8 tahun");
  });
  it("can be postponed to the website", async () => {
    const h = harness({ assets: [asset] });
    await buy(h);
    await h.press(`a|no|${ASSET}`);
    expect(h.activated).toHaveLength(0);
    expect(h.edits.at(-1)?.text).toContain("draf");
  });
  it("keeps a personal asset at cost, without a life", async () => {
    const h = harness({ assets: [{ ...asset, entityType: "personal" }] });
    await buy(h);
    expect(h.sent.at(-1)?.text).toContain("tidak disusutkan");
    await h.press(`a|0|${ASSET}`);
    expect(h.activated).toEqual([{ assetId: ASSET, months: null }]);
  });
  it("sends a user without asset rights to the website", async () => {
    const h = harness({ assets: [{ ...asset, canManage: false }] });
    await buy(h);
    expect(h.sent.at(-1)?.text).toContain("belum boleh mengelola aset");
    expect(h.sent.at(-1)?.keyboard).toBeUndefined();
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
  it("attaches the receipt photo to the saved entry, after the owner confirmed", async () => {
    const h = harness({ aiAnswer: answer });
    await h.say("pt gopay", { photo: true });
    const nonce = h.getSession()?.nonce ?? "";
    expect(h.getSession()?.photoFileId).toBe("f");
    expect(h.getSession()?.entityId).toBe("pt");
    await h.press(`${nonce}|ok|`);
    await h.press(`${nonce}|acc|0`);
    await h.press(`${nonce}|cat|0`);
    expect(h.attached).toHaveLength(0);
    await h.press(`${nonce}|save|`);
    expect(h.recorded).toHaveLength(1);
    expect(h.attached).toEqual([
      { entityId: "pt", expenseId: "00000000-0000-0000-0000-000000000001", size: 3 },
    ]);
    expect(h.edits.at(-1)?.text).toContain("Foto struk terlampir");
  });
  it("uses a caption that states the amount as the entry and only attaches the photo", async () => {
    const h = harness({ aiAnswer: answer });
    await h.say("makan siang di warteg 35rb pakai gopay pt", { photo: true });
    expect(h.aiCalls).toHaveLength(0);
    expect(h.getSession()?.photoFileId).toBe("f");
    expect(h.getSession()?.entityId).toBe("pt");
    const nonce = h.getSession()?.nonce ?? "";
    expect(h.sent[0]?.text).not.toContain("Nominal");
    await h.press(`${nonce}|cat|0`);
    await h.press(`${nonce}|save|`);
    expect(h.recorded).toHaveLength(1);
    expect(h.attached).toHaveLength(1);
  });
  it("works from the caption even without a Gemini key", async () => {
    const h = harness();
    await h.say("makan siang 35rb pakai gopay pt", { photo: true });
    expect(h.getSession()?.photoFileId).toBe("f");
  });
  it("attaches the photo to an entry already on the website, found by its transaction number", async () => {
    const h = harness({ aiAnswer: answer });
    await h.say("lampirkan EXP-001-0003", { photo: true });
    expect(h.aiCalls).toHaveLength(0);
    expect(h.recorded).toHaveLength(0);
    expect(h.attached).toEqual([
      { entityId: "pt", expenseId: "55555555-0000-0000-0000-000000000003", size: 3 },
    ]);
    expect(h.sent[0]?.text).toContain("EXP-001-0003");
    expect(h.getSession()).toBeNull();
  });
  it("asks for the number when the caption only says lampirkan, then attaches", async () => {
    const h = harness({ aiAnswer: answer });
    await h.say("lampirkan", { photo: true });
    expect(h.sent[0]?.text).toContain("transaksi yang mana");
    expect(h.attached).toHaveLength(0);
    await h.say("exp-001-0003");
    expect(h.attached).toHaveLength(1);
    expect(h.getSession()).toBeNull();
  });
  it("keeps waiting when the number is not found, and can be cancelled", async () => {
    const h = harness();
    await h.say("lampirkan", { photo: true });
    await h.say("EXP-009-0009");
    expect(h.sent.at(-1)?.text).toContain("tidak ditemukan");
    expect(h.getSession()?.awaiting).toBe("attach_code");
    await h.say("batal");
    expect(h.getSession()).toBeNull();
    expect(h.attached).toHaveLength(0);
  });
  it("drops the waiting photo when a new entry is typed instead", async () => {
    const h = harness();
    await h.say("lampirkan", { photo: true });
    await h.say("makan siang 35rb pakai gopay pt");
    expect(h.getSession()?.awaiting).toBeNull();
    expect(h.attached).toHaveLength(0);
  });
  it("refuses when the account may not attach documents there", async () => {
    const h = harness({ canAttach: false });
    await h.say("lampirkan EXP-001-0003", { photo: true });
    expect(h.attached).toHaveLength(0);
    expect(h.sent[0]?.text).toContain("belum boleh melampirkan");
  });
  it("does not attach anything to a text entry", async () => {
    const h = harness();
    await h.say("makan siang 35rb pakai gopay pt");
    const nonce = h.getSession()?.nonce ?? "";
    await h.press(`${nonce}|cat|0`);
    await h.press(`${nonce}|save|`);
    expect(h.attached).toHaveLength(0);
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

// ---- sales through the bot (decision 425) ---------------------------------------------------------------------

const codeIn = (text: string | undefined): string =>
  /<code>(\d{4})<\/code>/.exec(text ?? "")?.[1] ?? "";
const lastText = (h: { sent: Array<{ text: string }> }): string => h.sent.at(-1)?.text ?? "";
const nonceOf = (h: { getRaw: () => { nonce: string } | null }): string => h.getRaw()?.nonce ?? "";

describe("sales: an invoice with layered verification", () => {
  it("records nothing until the third verification step, then issues it and gives the link", async () => {
    const h = harness();
    await h.say("invoice Budi Santoso 2,5jt jasa konsultasi PT");
    expect(lastText(h)).toContain("Invoice baru");
    expect(lastText(h)).toContain("pelanggan baru");
    expect(lastText(h)).toContain("Verifikasi 1/3");
    await h.press(`o|go|${nonceOf(h)}`);
    expect(h.edits.at(-1)?.text).toContain("Verifikasi 2/3");
    // a button cannot answer the amount step, typing the figure does
    await h.say("2jt");
    expect(lastText(h)).toContain("belum cocok");
    await h.say("Rp 2.500.000");
    expect(lastText(h)).toContain("Verifikasi 3/3");
    expect(h.invoicesIssued).toHaveLength(0);
    await h.say("0000x");
    expect(h.invoicesIssued).toHaveLength(0);
    await h.say(`kode ${codeIn(h.sent.find((m) => m.text.includes("Verifikasi 3/3"))?.text)}`);
    expect(h.customersCreated).toEqual([
      expect.objectContaining({ name: "Budi Santoso", allowSimilar: false }),
    ]);
    expect(h.invoicesIssued).toHaveLength(1);
    expect(h.invoicesIssued[0]).toMatchObject({
      customerId: "cust-new",
      amount: 2_500_000,
      dueDate: TODAY,
      description: "jasa konsultasi",
    });
    const done = lastText(h);
    expect(done).toContain("HKD-2026-0001");
    expect(done).toContain("https://example.test/i/tok123");
    expect(done).toContain("Diterbitkan");
    expect(h.getRaw()).toBeNull();
  });

  it("cancels after three wrong answers and records nothing", async () => {
    const h = harness();
    await h.say("invoice Budi 1jt desain PT");
    await h.press(`o|go|${nonceOf(h)}`);
    await h.say("2jt");
    await h.say("5jt");
    await h.say("6jt");
    expect(lastText(h)).toContain("Dibatalkan");
    expect(h.invoicesIssued).toHaveLength(0);
    expect(h.getRaw()).toBeNull();
  });

  it("asks for what is missing: entity, amount, then the item", async () => {
    const h = harness();
    await h.say("invoice Budi");
    expect(lastText(h)).toContain("entitas yang mana");
    await h.say("pt");
    expect(lastText(h)).toContain("Berapa total");
    await h.say("750rb");
    expect(lastText(h)).toContain("untuk apa");
    await h.say("Jasa desain logo");
    expect(lastText(h)).toContain("Rp 750.000");
    expect(lastText(h)).toContain("Verifikasi 1/3");
  });

  it("offers the payment links of the entity and puts the chosen one on the invoice", async () => {
    const h = harness({
      channels: [
        { id: "ch1", name: "Midtrans", kind: "payment_link", hasUrl: true, accountId: null },
      ],
    });
    await h.say("invoice Budi 1jt desain PT");
    expect(lastText(h)).toContain("tautan pembayaran");
    await h.press(`o|chan|${nonceOf(h)}:0`);
    expect(h.edits.at(-1)?.text).toContain("Midtrans");
    await h.press(`o|go|${nonceOf(h)}`);
    await h.say("1jt");
    await h.say(codeIn(h.sent.at(-1)?.text));
    expect(h.invoicesIssued[0]?.channelId).toBe("ch1");
  });

  it("a due date written in the message is used", async () => {
    const h = harness();
    await h.say("invoice Budi 1jt desain PT tempo 14 hari");
    expect(lastText(h)).toContain("4 Nov 2026");
  });
});

describe("sales: a customer who may already exist", () => {
  const existing = [
    { id: "c1", name: "Budi Santoso", email: "budi@example.test", severity: "same_name" as const },
  ];

  it("asks, and a typed 'pakai yang lama' uses the registered customer", async () => {
    const h = harness({ customers: existing });
    await h.say("invoice Budi Santoso 1jt desain PT");
    expect(lastText(h)).toContain("sudah terdaftar");
    expect(lastText(h)).toContain("budi@example.test");
    await h.say("pakai yang lama");
    expect(lastText(h)).toContain("terdaftar)");
    await h.press(`o|go|${nonceOf(h)}`);
    await h.say("1jt");
    await h.say(codeIn(h.sent.at(-1)?.text));
    expect(h.customersCreated).toHaveLength(0);
    expect(h.invoicesIssued[0]?.customerId).toBe("c1");
  });

  it("a typed 'buat baru' creates a second customer with the same name, on the owner's word", async () => {
    const h = harness({ customers: existing });
    await h.say("invoice Budi Santoso 1jt desain PT");
    await h.say("buat baru");
    await h.press(`o|go|${nonceOf(h)}`);
    await h.say("1jt");
    await h.say(codeIn(h.sent.at(-1)?.text));
    expect(h.customersCreated).toEqual([expect.objectContaining({ allowSimilar: true })]);
  });

  it("the buttons answer too, and an unclear reply asks again", async () => {
    const h = harness({ customers: existing });
    await h.say("invoice Budi Santoso 1jt desain PT");
    await h.say("hmm");
    expect(lastText(h)).toContain("pakai yang lama");
    await h.press(`o|use|${nonceOf(h)}:0`);
    expect(h.edits.at(-1)?.text).toContain("Verifikasi 1/3");
  });

  it("a new-customer command that matches a registered name asks first and can stop there", async () => {
    const h = harness({ customers: existing });
    await h.say("pelanggan baru Budi Santoso PT");
    expect(lastText(h)).toContain("sudah terdaftar");
    await h.say("pakai yang lama");
    expect(lastText(h)).toContain("tidak membuat pelanggan baru");
    expect(h.customersCreated).toHaveLength(0);
  });
});

describe("sales: a new customer, a payment and a lookup", () => {
  it("creates a customer after two verification steps", async () => {
    const h = harness();
    await h.say("pelanggan baru Siti Aminah siti@example.test PT");
    expect(lastText(h)).toContain("Verifikasi 1/2");
    await h.press(`o|go|${nonceOf(h)}`);
    expect(h.edits.at(-1)?.text).toContain("Verifikasi 2/2");
    expect(h.customersCreated).toHaveLength(0);
    await h.say("ya");
    expect(h.customersCreated).toEqual([expect.objectContaining({ name: "Siti Aminah" })]);
    expect(lastText(h)).toContain("dibuat");
  });

  it("records a payment on an invoice and shows the status change with the receipt link", async () => {
    const h = harness();
    await h.say("terima HKD-2026-0001 1jt bca");
    expect(lastText(h)).toContain("Dibayar sebagian");
    expect(lastText(h)).toContain("BCA Operasional");
    await h.press(`o|go|${nonceOf(h)}`);
    await h.say("1.000.000");
    expect(h.paymentsRecorded).toHaveLength(0);
    await h.say(codeIn(h.sent.at(-1)?.text));
    expect(h.paymentsRecorded).toEqual([
      expect.objectContaining({ amount: 1_000_000, accountId: "acc-bca" }),
    ]);
    const done = lastText(h);
    expect(done).toContain("Belum dibayar → <b>Dibayar sebagian</b>");
    expect(done).toContain("https://example.test/i/tok123/receipt?no=PAY-2026-0001");
  });

  it("without an amount the whole remaining amount is paid and the status becomes Lunas", async () => {
    const h = harness();
    await h.say("lunas HKD-2026-0001 kas kecil");
    expect(lastText(h)).toContain("Rp 2.500.000");
    await h.press(`o|go|${nonceOf(h)}`);
    await h.say("2,5jt");
    await h.say(codeIn(h.sent.at(-1)?.text));
    expect(lastText(h)).toContain("Lunas");
  });

  it("asks for the account when it is not named, and refuses an amount above what is outstanding", async () => {
    const h = harness();
    await h.say("terima HKD-2026-0001 1jt");
    expect(lastText(h)).toContain("rekening mana");
    await h.press(`o|acc|${nonceOf(h)}:1`);
    expect(h.edits.at(-1)?.text).toContain("Kas Kecil");
    const h2 = harness();
    await h2.say("terima HKD-2026-0001 9jt bca");
    expect(lastText(h2)).toContain("melebihi sisa");
    expect(h2.getRaw()).toBeNull();
  });

  it("refuses an invoice that is already paid, one that cannot be found and one the account may not pay", async () => {
    const paid = harness({ invoices: [{ outstanding: 0, settlement: "paid" }] });
    await paid.say("terima HKD-2026-0001 1jt bca");
    expect(lastText(paid)).toContain("sudah lunas");
    const none = harness();
    await none.say("terima HKD-2026-0009 1jt bca");
    expect(lastText(none)).toContain("tidak ditemukan");
    const denied = harness({ invoices: [{ canRecordPayment: false }] });
    await denied.say("terima HKD-2026-0001 1jt bca");
    expect(lastText(denied)).toContain("tidak boleh mencatat pembayaran");
  });

  it("asks which entity when the same number exists in two", async () => {
    const h = harness({ invoices: [{}, {}] });
    await h.say("terima HKD-2026-0001 1jt bca");
    expect(lastText(h)).toContain("lebih dari satu entitas");
    await h.press(`o|inv|${nonceOf(h)}:1`);
    expect(h.edits.at(-1)?.text).toContain("Pribadi");
  });

  it("answers a status question with the status, the link and the receipts", async () => {
    const h = harness({
      invoices: [
        {
          settlement: "partial",
          settled: 1_000_000,
          outstanding: 1_500_000,
          receipts: [{ number: "PAY-2026-0001", date: TODAY, amount: 1_000_000 }],
        },
      ],
    });
    await h.say("status HKD-2026-0001");
    const text = lastText(h);
    expect(text).toContain("Dibayar sebagian");
    expect(text).toContain("https://example.test/i/tok123");
    expect(text).toContain("receipt?no=PAY-2026-0001");
  });
});

describe("sales: leaving a conversation", () => {
  it("/batal ends it and nothing is recorded", async () => {
    const h = harness();
    await h.say("invoice Budi 1jt desain PT");
    await h.say("/batal");
    expect(lastText(h)).toContain("Dibatalkan");
    expect(h.getRaw()).toBeNull();
    expect(h.invoicesIssued).toHaveLength(0);
  });
  it("a button from an old conversation is refused", async () => {
    const h = harness();
    await h.say("invoice Budi 1jt desain PT");
    await h.press("o|go|zzzzzz");
    expect(h.invoicesIssued).toHaveLength(0);
    expect(h.getRaw()).not.toBeNull();
  });
  it("speaks English when the owner chose it", async () => {
    const h = harness({ lang: "en" });
    await h.say("invoice Budi 1jt design PT");
    expect(lastText(h)).toContain("New invoice");
    expect(lastText(h)).toContain("Verification 1/3");
  });
  it("ordinary expenses are not mistaken for sales", async () => {
    const h = harness();
    await h.say("traktir pelanggan 200rb pt");
    expect(h.getRaw()?.v).toBe(1);
  });
});
