import { describe, expect, it } from "vitest";
import { decodeProblems, describeProblems, encodeProblems, locateProblems } from "./problemTargets";

describe("locateProblems", () => {
  it("finds the line and column of a withholding refusal", () => {
    expect(
      locateProblems(
        'INVALID: the tax determination of this expense needs review before it can be confirmed: Line 2 has no withholding classification: choose "not a withholding object" or the object on the line, or map its category.',
      ),
    ).toEqual([{ scope: "line", line: 2, field: "wht" }]);
  });

  it("finds several problems at once, lines in order", () => {
    const targets = locateProblems(
      "Line 3 carries VAT but no tax-invoice reference; Line 1 has no withholding classification",
    );
    expect(describeProblems(targets)).toEqual([
      "Baris 1 · Kena PPh?",
      "Baris 3 · No. Faktur Pajak",
    ]);
  });

  it("finds the amount, category, description and payee problems", () => {
    expect(locateProblems("INVALID: line 1 amount must be greater than zero")).toEqual([
      { scope: "line", line: 1, field: "amount" },
    ]);
    expect(
      locateProblems("INVALID: line 2 category must be an active expense category of this Entity"),
    ).toEqual([{ scope: "line", line: 2, field: "category" }]);
    expect(locateProblems("INVALID: line 1 needs a description of up to 500 characters")).toEqual([
      { scope: "line", line: 1, field: "description" },
    ]);
    expect(locateProblems("INVALID: name the vendor or the payee")).toEqual([
      { scope: "form", field: "payee" },
    ]);
  });

  it("marks nothing for a reason it does not know", () => {
    expect(locateProblems("INVALID: something else entirely")).toEqual([]);
  });

  it("round-trips through the short link text and ignores junk", () => {
    const targets = locateProblems(
      "Line 2 has no withholding classification; name a vendor or a payee",
    );
    expect(decodeProblems(encodeProblems(targets))).toEqual(targets);
    expect(decodeProblems("l1.nonsense,zz,f.payee")).toEqual([{ scope: "form", field: "payee" }]);
    expect(decodeProblems(undefined)).toEqual([]);
  });
});
