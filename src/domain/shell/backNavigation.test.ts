import { describe, expect, it } from "vitest";
import { createPathMemory, shouldGoBackInHistory } from "./backNavigation";

describe("shouldGoBackInHistory", () => {
  it("goes back to the page the person came from", () => {
    expect(shouldGoBackInHistory("/activity", "/sales/invoices/abc")).toBe(true);
    expect(shouldGoBackInHistory("/dashboard", "/sales/invoices/abc")).toBe(true);
  });

  it("falls back to the fixed list when there is no previous page", () => {
    expect(shouldGoBackInHistory(null, "/sales/invoices/abc")).toBe(false);
  });

  it("does not return to the form that was just saved", () => {
    expect(shouldGoBackInHistory("/sales/invoices/new", "/sales/invoices/abc")).toBe(false);
    expect(shouldGoBackInHistory("/purchases/expenses/abc/edit", "/purchases/expenses/abc")).toBe(
      false,
    );
  });

  it("does not go back to the very same page", () => {
    expect(shouldGoBackInHistory("/sales/invoices/abc", "/sales/invoices/abc")).toBe(false);
  });
});

describe("createPathMemory", () => {
  it("remembers the page before the current one", () => {
    const memory = createPathMemory();
    memory.visit("/activity");
    expect(memory.previous).toBeNull();
    memory.visit("/sales/invoices/abc");
    expect(memory.previous).toBe("/activity");
    expect(memory.current).toBe("/sales/invoices/abc");
  });

  it("ignores a repeated visit of the same page", () => {
    const memory = createPathMemory();
    memory.visit("/activity");
    memory.visit("/sales/invoices/abc");
    memory.visit("/sales/invoices/abc");
    expect(memory.previous).toBe("/activity");
  });
});
