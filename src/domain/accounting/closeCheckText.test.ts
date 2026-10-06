import { describe, expect, it } from "vitest";
import { CLOSE_CHECK_CODES, closeCheckText } from "./closeCheckText";

describe("closeCheckText", () => {
  it("gives Indonesian text for a known check", () => {
    expect(closeCheckText("draft_journals", "Draft journals exist")).toMatch(/jurnal draf/);
  });

  it("shows the database's sentence for a code it does not know", () => {
    expect(closeCheckText("something_new", "Something new")).toBe("Something new");
  });

  it("covers the thirty-one checks the database can raise", () => {
    expect(CLOSE_CHECK_CODES.length).toBe(31);
  });
});
