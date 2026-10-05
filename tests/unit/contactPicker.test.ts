import { describe, expect, it } from "vitest";
import { matchContacts } from "@/features/contacts/ContactPicker";

const contacts = [
  { id: "1", display_name: "Tirto Budi Santoso" },
  { id: "2", display_name: "PT Budi Jaya" },
  { id: "3", display_name: "Andi Wijaya" },
  { id: "4", display_name: "Budi Hartono" },
];

describe("matchContacts", () => {
  it("lists the first names when nothing is typed", () => {
    expect(matchContacts("", contacts, 2).map((c) => c.id)).toEqual(["1", "2"]);
  });

  it("narrows to names matching the letters, names starting with them first", () => {
    expect(matchContacts("bud", contacts).map((c) => c.id)).toEqual(["4", "1", "2"]);
  });

  it("ignores case and extra spaces", () => {
    expect(matchContacts("  ANDI   wij ", contacts).map((c) => c.id)).toEqual(["3"]);
  });

  it("returns nothing for a name that is not on file", () => {
    expect(matchContacts("xyz", contacts)).toEqual([]);
  });
});
