import { describe, expect, it } from "vitest";
import { smoothPath } from "./smooth";

describe("smoothPath", () => {
  it("passes through every point and never produces NaN", () => {
    const d = smoothPath([
      { x: 10, y: 50 },
      { x: 30, y: 20 },
      { x: 50, y: 20 },
      { x: 70, y: 80 },
      { x: 90, y: 60 },
    ]);
    expect(d).not.toContain("NaN");
    expect(d.startsWith("M 10 50")).toBe(true);
    expect(d.endsWith("90 60")).toBe(true);
  });
  it("handles zero and one point", () => {
    expect(smoothPath([])).toBe("");
    expect(smoothPath([{ x: 1, y: 2 }])).toBe("M 1 2");
  });
});
