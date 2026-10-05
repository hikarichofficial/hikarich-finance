import { describe, expect, it } from "vitest";
import {
  canonicalFromTyping,
  caretAfterFormatting,
  formatMoneyTyping,
  plainMoneyText,
} from "@/domain/money/typing";

describe("canonicalFromTyping", () => {
  it("keeps digits only and ignores the dots the field inserts itself", () => {
    expect(canonicalFromTyping("100000000")).toBe("100000000");
    expect(canonicalFromTyping("100.000.000")).toBe("100000000");
    expect(canonicalFromTyping("1.0005")).toBe("10005");
  });
  it("starts the decimals at the comma", () => {
    expect(canonicalFromTyping("1.500,5")).toBe("1500.5");
    expect(canonicalFromTyping("1500,")).toBe("1500.");
    expect(canonicalFromTyping(",5")).toBe("0.5");
    expect(canonicalFromTyping("1,2,3")).toBe("1.23");
  });
  it("drops letters, leading zeros, and caps the decimals", () => {
    expect(canonicalFromTyping("Rp 12abc")).toBe("12");
    expect(canonicalFromTyping("007")).toBe("7");
    expect(canonicalFromTyping("0")).toBe("0");
    expect(canonicalFromTyping("1,123456")).toBe("1.1234");
    expect(canonicalFromTyping("")).toBe("");
  });
});

describe("formatMoneyTyping / plainMoneyText", () => {
  it("shows separators and a comma before decimals", () => {
    expect(formatMoneyTyping("100000000")).toBe("100.000.000");
    expect(formatMoneyTyping("999")).toBe("999");
    expect(formatMoneyTyping("1500.5")).toBe("1.500,5");
    expect(formatMoneyTyping("1500.")).toBe("1.500,");
    expect(formatMoneyTyping("")).toBe("");
  });
  it("submits without a dangling decimal mark", () => {
    expect(plainMoneyText("1500.")).toBe("1500");
    expect(plainMoneyText("1500.5")).toBe("1500.5");
  });
});

describe("caretAfterFormatting", () => {
  it("keeps the caret after the same digits when a separator appears", () => {
    // typed "1000" -> display "1.000"; caret after the 4th digit is at index 5
    expect(caretAfterFormatting("1.0005", "10.005")).toBe(6);
    expect(caretAfterFormatting("1.00", "100")).toBe(3);
    expect(caretAfterFormatting("", "100")).toBe(0);
  });
});
