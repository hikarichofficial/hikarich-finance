import { describe, expect, it } from "vitest";
import {
  DEFAULT_DOCUMENT_NAME_STYLE,
  documentNameStyle,
  documentNames,
} from "./documentNames";

const LEGAL = "PT Hikarich Group Indonesia";
const BRAND = "Hikarich";

describe("documentNameStyle", () => {
  it("keeps a known style and falls back for anything else", () => {
    expect(documentNameStyle("legal")).toBe("legal");
    expect(documentNameStyle("brand")).toBe("brand");
    expect(documentNameStyle("both")).toBe("both");
    expect(documentNameStyle(null)).toBe(DEFAULT_DOCUMENT_NAME_STYLE);
    expect(documentNameStyle("nama_lain")).toBe(DEFAULT_DOCUMENT_NAME_STYLE);
    expect(documentNameStyle(7)).toBe(DEFAULT_DOCUMENT_NAME_STYLE);
  });
});

describe("documentNames", () => {
  it("puts the legal name over the brand when both are asked for", () => {
    expect(documentNames(LEGAL, BRAND, "both")).toEqual({ primary: LEGAL, secondary: BRAND });
  });

  it("shows one name alone when that is what was chosen", () => {
    expect(documentNames(LEGAL, BRAND, "legal")).toEqual({ primary: LEGAL, secondary: null });
    expect(documentNames(LEGAL, BRAND, "brand")).toEqual({ primary: BRAND, secondary: null });
  });

  it("never leaves a document without a name", () => {
    expect(documentNames(LEGAL, null, "brand")).toEqual({ primary: LEGAL, secondary: null });
    expect(documentNames(null, BRAND, "legal")).toEqual({ primary: BRAND, secondary: null });
    expect(documentNames(null, null, "both")).toEqual({ primary: "", secondary: null });
  });

  it("does not print the same name twice", () => {
    expect(documentNames(LEGAL, LEGAL, "both")).toEqual({ primary: LEGAL, secondary: null });
    expect(documentNames("  ", BRAND, "both")).toEqual({ primary: BRAND, secondary: null });
  });
});
