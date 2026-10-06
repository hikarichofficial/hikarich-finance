import { describe, expect, it } from "vitest";
import { AuthzError, describeAuthzError } from "./errors";
import translations from "./reasonTranslations.json";
import { translateReason, translateStoredError } from "./translateReason";

describe("translateReason", () => {
  it("translates a fixed reason", () => {
    expect(translateReason("a payment cannot be dated in the future")).toMatch(/masa depan/i);
  });

  it("puts the database's values into the Indonesian text", () => {
    const text = translateReason("4 of the 4 periods in fiscal year 2026 are not closed yet");
    expect(text).toContain("2026");
    expect(text).toContain("4");
    expect(text).not.toMatch(/periods|fiscal year/);
  });

  it("returns null for a reason it does not know", () => {
    expect(translateReason("something nobody wrote a template for")).toBeNull();
  });

  it("keeps every placeholder of every template", () => {
    for (const [english, indonesian] of translations as [string, string][]) {
      const values = english.replace(/%%/g, "").split("%").length - 1;
      const used = new Set(indonesian.match(/\{\d+\}/g) ?? []);
      expect(used.size, english).toBe(values);
    }
  });
});

describe("describeAuthzError", () => {
  it("shows the Indonesian reason alone when it is known", () => {
    const error = new AuthzError("INVALID", "INVALID: a payment cannot be dated in the future");
    expect(describeAuthzError(error)).not.toMatch(/cannot/);
    expect(describeAuthzError(error)).toMatch(/masa depan/i);
  });

  it("falls back to the generic text with the original reason", () => {
    const error = new AuthzError("CONFLICT", "CONFLICT: something nobody wrote a template for");
    expect(describeAuthzError(error)).toContain("(something nobody wrote a template for)");
  });

  it("explains the approval rule instead of a missing permission", () => {
    const error = new AuthzError(
      "FORBIDDEN",
      "FORBIDDEN: an approval rule requires a different person to approve this bill",
    );
    expect(describeAuthzError(error)).toMatch(/orang lain/);
    expect(describeAuthzError(error)).not.toMatch(/approve/);
  });

  it("keeps any other FORBIDDEN reason generic", () => {
    const error = new AuthzError("FORBIDDEN", "FORBIDDEN: missing invoices.view");
    expect(describeAuthzError(error)).toBe("Anda tidak memiliki izin untuk tindakan ini.");
  });

  it("never shows a reason for other codes", () => {
    expect(describeAuthzError(new AuthzError("FORBIDDEN", "FORBIDDEN: missing tax.view"))).toBe(
      "Anda tidak memiliki izin untuk tindakan ini.",
    );
  });
});

describe("translateStoredError", () => {
  it("translates a stored INVALID reason and leaves other text as it is", () => {
    expect(translateStoredError("INVALID: a payment cannot be dated in the future")).toMatch(
      /masa depan/i,
    );
    expect(translateStoredError("division by zero")).toBe("division by zero");
  });
});

describe("tax determination sentences", () => {
  it("translates the reasons and consequences shown on invoice and bill pages", () => {
    expect(
      translateReason(
        'Line 1 has no withholding classification: choose "not a withholding object" or the object on the line, or map its category.',
      ),
    ).toContain("Baris 1 belum punya klasifikasi pemotongan");
    expect(
      translateReason(
        "No output VAT: the invoice total is unchanged and no tax liability is created.",
      ),
    ).toBe(
      "Tidak ada PPN keluaran: total invoice tidak berubah dan tidak ada kewajiban pajak yang timbul.",
    );
    expect(translateReason("Nothing is withheld: the vendor is owed the full amount.")).toContain(
      "Tidak ada yang dipotong",
    );
  });

  it("puts the amounts and the period into the sentence", () => {
    expect(
      translateReason(
        "Output VAT of 55000 is added to the invoice total and credited to Tax Payables; it accrues in the VAT ledger for 2026-10.",
      ),
    ).toContain("PPN keluaran 55000");
    expect(
      translateReason(
        "50000 is debited to Tax Assets as creditable input VAT and accrues in the VAT ledger for 2026-10; 5000 stays in the cost.",
      ),
    ).toContain("5000 tetap menjadi biaya");
    expect(
      translateReason(
        "30000 is withheld from the payee: the vendor is owed that much less, and it is credited to Tax Payables and accrues in the PPh 23 ledger for 2026-10. The gross expense is unchanged.",
      ),
    ).toContain("buku PPh 23 untuk masa 2026-10");
  });
});
