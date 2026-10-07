import { describe, expect, it } from "vitest";
import { snapAxis } from "./invoiceGuides";

const PAGE = [
  { at: 0, label: "Tepi kiri halaman" },
  { at: 50, label: "Tengah halaman" },
  { at: 100, label: "Tepi kanan halaman" },
];

describe("snapAxis (decision 321)", () => {
  it("snaps the middle of a block onto the middle of the page", () => {
    const snap = snapAxis(
      [
        { at: 29, part: "start" },
        { at: 49.6, part: "middle" },
        { at: 70.2, part: "end" },
      ],
      PAGE,
      1,
    );
    expect(snap?.delta).toBeCloseTo(0.4, 5);
    expect(snap?.hits).toEqual([{ at: 50, labels: ["Tengah halaman"] }]);
  });

  it("reports every line the block ends up on", () => {
    const snap = snapAxis(
      [
        { at: 0.3, part: "start" },
        { at: 30, part: "end" },
      ],
      [...PAGE, { at: 0, label: "Tepi kiri Logo" }],
      1,
    );
    expect(snap?.hits).toEqual([{ at: 0, labels: ["Tepi kiri halaman", "Tepi kiri Logo"] }]);
  });

  it("takes the closest target when several are in reach", () => {
    const snap = snapAxis(
      [{ at: 10, part: "start" }],
      [
        { at: 8, label: "a" },
        { at: 11, label: "b" },
      ],
      3,
    );
    expect(snap?.delta).toBe(1);
    expect(snap?.hits).toEqual([{ at: 11, labels: ["b"] }]);
  });

  it("does nothing when nothing is close", () => {
    expect(snapAxis([{ at: 20, part: "start" }], PAGE, 1)).toBeNull();
  });
});
