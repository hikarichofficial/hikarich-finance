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
