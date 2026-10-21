import { describe, expect, it } from "vitest";
import { extractExpenseCode, wantsAttachment } from "./attach";

describe("extractExpenseCode", () => {
  it("reads a transaction number anywhere in the text, in any case", () => {
    expect(extractExpenseCode("lampirkan EXP-001-0003")).toBe("EXP-001-0003");
    expect(extractExpenseCode("exp-001-0003 ya")).toBe("EXP-001-0003");
    expect(extractExpenseCode("untuk EXP-0042 tolong")).toBe("EXP-0042");
  });
  it("does not mistake an ordinary entry for a number", () => {
    expect(extractExpenseCode("makan siang di warteg 35rb pakai gopay pt")).toBeNull();
    expect(extractExpenseCode("beli kertas 120rb")).toBeNull();
    expect(extractExpenseCode("")).toBeNull();
  });
});

describe("wantsAttachment", () => {
  it("is true for a number or for the word lampirkan", () => {
    expect(wantsAttachment("EXP-001-0003")).toBe(true);
    expect(wantsAttachment("lampirkan")).toBe(true);
    expect(wantsAttachment("Lampiran untuk transaksi tadi")).toBe(true);
    expect(wantsAttachment("attach this")).toBe(true);
  });
  it("is false for an ordinary caption", () => {
    expect(wantsAttachment("")).toBe(false);
    expect(wantsAttachment("makan siang 35rb pt")).toBe(false);
  });
});
