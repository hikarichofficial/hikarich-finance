import { describe, expect, it } from "vitest";
import { NAVIGATION, activeNavItem, visibleNavigation } from "./navigation";

describe("NAVIGATION labels (decision 254)", () => {
  it("names every menu in Indonesian", () => {
    expect(NAVIGATION.map((g) => g.label)).toEqual([
      "Ringkasan",
      "Penjualan",
      "Pembelian",
      "Kas & Bank",
      "Akuntansi",
      "Pajak",
      "Aset & Pendanaan",
      "Gaji",
      "Perencanaan",
      "Laporan",
      "Dokumen",
      "Administrasi",
    ]);
  });

  it("keeps every route unique within its menu", () => {
    for (const group of NAVIGATION) {
      const hrefs = (group.items ?? []).map((i) => i.href);
      expect(new Set(hrefs).size).toBe(hrefs.length);
    }
  });
});

describe("activeNavItem", () => {
  it("matches the page itself", () => {
    expect(activeNavItem(NAVIGATION, "/planning/forecasts")).toEqual({
      groupKey: "planning",
      href: "/planning/forecasts",
    });
  });

  it("matches a detail page to its list by the longest prefix", () => {
    expect(activeNavItem(NAVIGATION, "/sales/invoices/abc")).toEqual({
      groupKey: "sales",
      href: "/sales/invoices",
    });
    expect(activeNavItem(NAVIGATION, "/assets/loans/1")).toEqual({
      groupKey: "assets-financing",
      href: "/assets/loans",
    });
    expect(activeNavItem(NAVIGATION, "/tax/rules/new")).toEqual({
      groupKey: "tax",
      href: "/tax/rules",
    });
  });

  it("only matches the dashboard on the root path", () => {
    expect(activeNavItem(NAVIGATION, "/")).toEqual({ groupKey: "overview", href: "/" });
    expect(activeNavItem(NAVIGATION, "/unknown")).toBeNull();
  });

  it("prefers a page's home menu when two menus list it", () => {
    expect(activeNavItem(NAVIGATION, "/money/accounts")?.groupKey).toBe("money");
  });

  it("works on the permission-filtered menu", () => {
    const groups = visibleNavigation(["invoices.view"]);
    expect(activeNavItem(groups, "/sales/invoices")?.groupKey).toBe("sales");
    expect(activeNavItem(groups, "/tax/ledger")).toBeNull();
  });
});

describe("visibleNavigation", () => {
  it("hides a menu whose pages the person cannot open", () => {
    const keys = visibleNavigation(["invoices.view"]).map((g) => g.key);
    expect(keys).toEqual(["overview", "sales"]);
  });

  it("shows only the permitted items of a menu", () => {
    const sales = visibleNavigation(["invoices.view"]).find((g) => g.key === "sales");
    expect(sales?.items?.map((i) => i.href)).toEqual(["/sales/invoices", "/sales/payments"]);
  });

  it("shows a menu through one item's own permission", () => {
    const admin = visibleNavigation(["audit.view"]).find((g) => g.key === "administration");
    expect(admin?.items?.map((i) => i.href)).toEqual(["/admin/audit"]);
  });
});
