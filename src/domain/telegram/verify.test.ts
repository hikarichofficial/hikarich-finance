import { describe, expect, it } from "vitest";
import {
  answer,
  CODE_TTL_MS,
  currentStep,
  needsTyping,
  saysNo,
  saysYes,
  startVerification,
  stepPrompt,
  type Verification,
  type VerifyContext,
} from "./verify";

const ctx = (over: Partial<VerifyContext> = {}): VerifyContext => ({
  total: 2_500_000,
  now: 1_000_000,
  newCode: () => "4821",
  ...over,
});

function unwrap(o: ReturnType<typeof answer>): Verification {
  if (o.kind !== "next" && o.kind !== "again") throw new Error(`unexpected ${o.kind}`);
  return o.v;
}

describe("typed yes and no", () => {
  it("reads short agreeing and refusing words", () => {
    expect(saysYes("ya")).toBe(true);
    expect(saysYes("Oke lanjut")).toBe(true);
    expect(saysYes("yes")).toBe(true);
    expect(saysYes("ya tapi ganti jumlahnya jadi 3 juta")).toBe(false);
    expect(saysNo("batal")).toBe(true);
    expect(saysNo("tidak")).toBe(true);
    expect(saysNo("ya")).toBe(false);
  });
});

describe("money verification: review, retype the amount, one-time code", () => {
  it("walks all three steps and only then is done", () => {
    let v = startVerification("money");
    expect(currentStep(v)).toBe("review");
    v = unwrap(answer(v, { type: "button", action: "go" }, ctx()));
    expect(currentStep(v)).toBe("amount");
    expect(needsTyping(v)).toBe(true);
    v = unwrap(answer(v, { type: "text", text: "Rp 2.500.000" }, ctx()));
    expect(currentStep(v)).toBe("code");
    expect(v.code).toBe("4821");
    expect(v.codeUntil).toBe(1_000_000 + CODE_TTL_MS);
    expect(answer(v, { type: "text", text: "kodenya 4821" }, ctx()).kind).toBe("done");
  });

  it("accepts a typed yes for the review and the amount in short form", () => {
    let v = startVerification("money");
    v = unwrap(answer(v, { type: "text", text: "ya" }, ctx()));
    v = unwrap(answer(v, { type: "text", text: "2,5jt" }, ctx()));
    expect(currentStep(v)).toBe("code");
  });

  it("does not accept a button for the amount or the code", () => {
    let v = startVerification("money");
    v = unwrap(answer(v, { type: "button", action: "go" }, ctx()));
    const out = answer(v, { type: "button", action: "go" }, ctx());
    expect(out.kind).toBe("again");
    expect(currentStep(unwrap(out))).toBe("amount");
  });

  it("repeats on a wrong amount and cancels after three wrong answers", () => {
    let v = startVerification("money");
    v = unwrap(answer(v, { type: "button", action: "go" }, ctx()));
    v = unwrap(answer(v, { type: "text", text: "2jt" }, ctx()));
    expect(v.wrong).toBe(1);
    v = unwrap(answer(v, { type: "text", text: "banyak" }, ctx()));
    expect(v.wrong).toBe(2);
    expect(answer(v, { type: "text", text: "3jt" }, ctx())).toEqual({
      kind: "cancel",
      reason: "too_many",
    });
  });

  it("an amount message with two figures is not accepted", () => {
    let v = startVerification("money");
    v = unwrap(answer(v, { type: "button", action: "go" }, ctx()));
    expect(answer(v, { type: "text", text: "2,5jt atau 3jt" }, ctx()).kind).toBe("again");
  });

  it("a wrong code repeats, an expired code is replaced by a fresh one", () => {
    let v = startVerification("money");
    v = unwrap(answer(v, { type: "button", action: "go" }, ctx()));
    v = unwrap(answer(v, { type: "text", text: "2500000" }, ctx()));
    const wrong = answer(v, { type: "text", text: "0000" }, ctx());
    expect(wrong.kind).toBe("again");
    const late = answer(
      v,
      { type: "text", text: "4821" },
      ctx({ now: 1_000_000 + CODE_TTL_MS + 1, newCode: () => "9090" }),
    );
    expect(late.kind).toBe("again");
    const fresh = unwrap(late);
    expect(fresh.code).toBe("9090");
    expect(fresh.codeUntil).toBe(1_000_000 + CODE_TTL_MS + 1 + CODE_TTL_MS);
  });

  it("saying no or pressing Batal cancels at any step", () => {
    const v = startVerification("money");
    expect(answer(v, { type: "button", action: "no" }, ctx())).toEqual({
      kind: "cancel",
      reason: "said_no",
    });
    expect(answer(v, { type: "text", text: "batal" }, ctx())).toEqual({
      kind: "cancel",
      reason: "said_no",
    });
  });
});

describe("master and tax levels", () => {
  it("master needs a review and a final yes", () => {
    let v = startVerification("master");
    v = unwrap(answer(v, { type: "button", action: "go" }, ctx()));
    expect(currentStep(v)).toBe("final");
    expect(answer(v, { type: "text", text: "ya" }, ctx()).kind).toBe("done");
  });

  it("tax has four steps: review, amount, recap, code", () => {
    let v = startVerification("tax");
    v = unwrap(answer(v, { type: "button", action: "go" }, ctx()));
    v = unwrap(answer(v, { type: "text", text: "2500000" }, ctx()));
    expect(currentStep(v)).toBe("recap");
    v = unwrap(answer(v, { type: "text", text: "ya" }, ctx()));
    expect(currentStep(v)).toBe("code");
    expect(answer(v, { type: "text", text: "4821" }, ctx()).kind).toBe("done");
  });
});

describe("prompts", () => {
  it("name the step, the amount and the code", () => {
    let v = startVerification("money");
    expect(stepPrompt(v, "Rp 2.500.000", "id")).toContain("1/3");
    v = unwrap(answer(v, { type: "button", action: "go" }, ctx()));
    expect(stepPrompt(v, "Rp 2.500.000", "id")).toContain("Rp 2.500.000");
    v = unwrap(answer(v, { type: "text", text: "2500000" }, ctx()));
    expect(stepPrompt(v, "Rp 2.500.000", "en")).toContain("4821");
    expect(stepPrompt(v, "Rp 2.500.000", "en")).toContain("Verification 3/3");
  });
});
