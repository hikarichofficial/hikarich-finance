import { describe, expect, it } from "vitest";
import { parseExpenseText } from "./message";
import {
  apply,
  type EntityContext,
  type Env,
  learnEntries,
  parseCallbackData,
  render,
  startDraft,
  toRecordPayload,
} from "./roadmap";

const TODAY = "2026-10-21";

function ctx(id: string, type: string, name: string, accounts = 2): EntityContext {
  return {
    entityId: id,
    entityType: type,
    entityName: name,
    today: TODAY,
    canConfirm: true,
    categories: [
      { id: `${id}-food`, name: "Makan & Minum", kind: "expense", isParent: false },
      { id: `${id}-trans`, name: "Transportasi", kind: "expense", isParent: false },
      { id: `${id}-other`, name: "Lainnya", kind: "expense", isParent: false },
      { id: `${id}-elec`, name: "Elektronik", kind: "asset", isParent: false },
    ],
    accounts: [
      { id: `${id}-cash`, name: "Kas Tunai" },
      { id: `${id}-gopay`, name: "GoPay" },
    ].slice(0, accounts),
    vendors: [],
    rules: [],
  };
}

const both: Env = {
  contexts: [ctx("pt", "company", "PT Hikarich"), ctx("pe", "personal", "Pribadi")],
  maxEntry: 5_000_000,
};
const opts = {
  nonce: "n1",
  key: "key-12345678",
  source: "text" as const,
  topicEntityId: null as string | null,
  today: TODAY,
};
const draft = (text: string, env: Env = both, o = opts) => {
  const parsed = parseExpenseText(text, TODAY);
  if (!parsed) throw new Error("no expense");
  return startDraft(parsed, env, o);
};
const press = (s: ReturnType<typeof draft>, action: string, arg = "", env: Env = both) =>
  apply(s, env, { type: "callback", action, arg }).state;

describe("Entity is never guessed", () => {
  it("asks which Entity when the message does not say", () => {
    const s = draft("kopi 25rb pakai gopay");
    expect(s.step).toBe("entity");
    expect(s.entityId).toBeNull();
    const view = render(s, both);
    expect(view.text).toContain("entitas yang mana");
    expect(
      view.keyboard.rows
        .flat()
        .map((b) => b.text)
        .join(" "),
    ).toContain("PT");
    expect(
      view.keyboard.rows
        .flat()
        .map((b) => b.text)
        .join(" "),
    ).toContain("Pribadi");
  });
  it("reads 'pt' and 'pribadi' from the message", () => {
    expect(draft("kopi 25rb pakai gopay untuk pt").entityId).toBe("pt");
    expect(draft("kopi 25rb pakai gopay pribadi").entityId).toBe("pe");
  });
  it("uses a mapped group topic", () => {
    expect(draft("kopi 25rb pakai gopay", both, { ...opts, topicEntityId: "pe" }).entityId).toBe(
      "pe",
    );
  });
  it("only skips the question when the owner has one Entity", () => {
    const one: Env = { ...both, contexts: [ctx("pt", "company", "PT Hikarich")] };
    expect(draft("kopi 25rb pakai gopay", one).entityId).toBe("pt");
  });
  it("shows the chosen Entity in the final summary", () => {
    let s = draft("makan siang 35rb pakai gopay pribadi");
    expect(s.step).toBe("kategori");
    s = press(s, "cat", "0");
    expect(s.step).toBe("ringkasan");
    expect(render(s, both).text).toContain("Pribadi");
  });
});

describe("the roadmap", () => {
  it("numbers the steps and goes back", () => {
    let s = draft("kopi 25rb");
    expect(render(s, both).text).toContain("Langkah 1 dari 4");
    s = press(s, "ent", "pt");
    expect(s.step).toBe("rekening");
    expect(render(s, both).text).toContain("Langkah 2 dari 4");
    s = press(s, "back");
    expect(s.step).toBe("entity");
    expect(s.entityId).toBe("pt");
  });
  it("changing the Entity resets account and category guesses", () => {
    let s = draft("kopi 25rb pakai gopay pt");
    expect(s.accountId).toBe("pt-gopay");
    s = press(s, "go", "entity");
    s = apply({ ...s, step: "ringkasan" }, both, {
      type: "callback",
      action: "ent",
      arg: "pe",
    }).state;
    expect(s.entityId).toBe("pe");
    expect(s.accountId).toBe("pe-gopay");
  });
  it("asks asset or expense for a big durable purchase and uses an asset category", () => {
    let s = draft("beli iPhone 15 untuk usaha 15jt pakai gopay");
    expect(s.step).toBe("aset");
    s = press(s, "as", "a");
    expect(s.lines[0]?.kind).toBe("asset");
    expect(s.step).toBe("kategori");
    s = press(s, "cat", "0");
    expect(toRecordPayload(s)?.lines[0]?.category_id).toBe("pt-elec");
  });
  it("does not ask about assets for small or ordinary purchases", () => {
    const s = draft("makan 35rb pakai gopay pt");
    expect(render(s, both).text).not.toContain("Aset atau biaya");
  });
  it("warns when the account list is empty", () => {
    const empty: Env = { ...both, contexts: [ctx("pe", "personal", "Pribadi", 0)] };
    const s = draft("kopi 25rb", empty);
    expect(render(s, empty).text).toContain("belum punya rekening");
  });
  it("saves only from the summary, and builds the payload", () => {
    let s = draft("makan siang di warteg 35rb pakai gopay pt");
    expect(apply(s, both, { type: "callback", action: "save", arg: "" }).effect.kind).toBe("stale");
    s = press(s, "cat", "0");
    const saved = apply(s, both, { type: "callback", action: "save", arg: "" });
    expect(saved.effect.kind).toBe("save");
    expect(toRecordPayload(s)).toMatchObject({
      entityId: "pt",
      accountId: "pt-gopay",
      payeeName: "Warteg",
      key: "key-12345678",
    });
  });
  it("edits amount, date and payee by text", () => {
    let s = draft("makan siang 35rb pakai gopay pt");
    s = press(s, "cat", "0");
    s = press(s, "edit", "amount");
    s = apply(s, both, { type: "text", text: "40rb" }).state;
    expect(s.lines[0]?.amount).toBe(40_000);
    s = press(s, "edit", "date");
    s = apply(s, both, { type: "text", text: "kemarin" }).state;
    expect(s.date).toBe("2026-10-20");
    s = press(s, "edit", "payee");
    s = apply(s, both, { type: "text", text: "Warung Bu Sri" }).state;
    expect(toRecordPayload(s)?.payeeName).toBe("Warung Bu Sri");
  });
  it("notes a draft when over the limit or when the user cannot confirm", () => {
    let s = draft("sewa studio 6jt pakai gopay pt");
    s = press(s, "cat", "0");
    expect(render(s, both).text).toContain("draf");
    const staff: Env = {
      ...both,
      contexts: both.contexts.map((c) => ({ ...c, canConfirm: false })),
    };
    s = draft("kopi 20rb pakai gopay pt", staff);
    s = press(s, "cat", "0", staff);
    expect(render(s, staff).text).toContain("tidak berhak mengonfirmasi");
  });
  it("learns what the owner decided", () => {
    let s = draft("makan di warteg 35rb pakai gopay pt");
    s = press(s, "cat", "0");
    expect(learnEntries(s, both)).toEqual([
      {
        entityId: "pt",
        keyword: "warteg",
        categoryId: "pt-food",
        accountId: "pt-gopay",
        payeeName: "Warteg",
      },
    ]);
  });
});

describe("callback data", () => {
  it("fits Telegram's 64 byte limit and parses back", () => {
    const s = draft("kopi 25rb pt");
    for (const b of render(s, both).keyboard.rows.flat()) {
      expect(new TextEncoder().encode(b.data).length).toBeLessThanOrEqual(64);
      expect(parseCallbackData(b.data)?.nonce).toBe("n1");
    }
    expect(parseCallbackData("garbage")).toBeNull();
  });
});
