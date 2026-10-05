import { describe, expect, it } from "vitest";
import { decideEntityCookie, isPublicPath } from "./proxy";

// Entity-memory redirect (owner-reported bug, 4 October 2026): switching to PT then clicking a sidebar
// item that forgot to carry `?entity=` silently fell back to the person's first membership (Personal),
// which looked like PT and Personal were being merged. `decideEntityCookie` is the pure core of the fix
// in `updateSession`: remember an explicit `?entity=`, and redirect a bare GET back to it.
describe("decideEntityCookie", () => {
  it("does nothing for a signed-out visitor", () => {
    expect(
      decideEntityCookie({
        pathname: "/sales/invoices",
        method: "GET",
        signedIn: false,
        entityParam: null,
        remembered: "pt",
      }),
    ).toEqual({ kind: "none" });
  });

  it("remembers an explicit ?entity= on a GET", () => {
    expect(
      decideEntityCookie({
        pathname: "/sales/invoices",
        method: "GET",
        signedIn: true,
        entityParam: "pt",
        remembered: null,
      }),
    ).toEqual({ kind: "remember", value: "pt" });
  });

  it("an explicit ?entity= always wins over what was remembered before (switching Entity)", () => {
    expect(
      decideEntityCookie({
        pathname: "/sales/invoices",
        method: "GET",
        signedIn: true,
        entityParam: "personal",
        remembered: "pt",
      }),
    ).toEqual({ kind: "remember", value: "personal" });
  });

  it("redirects a bare GET to the remembered Entity -- the reported bug", () => {
    expect(
      decideEntityCookie({
        pathname: "/sales/invoices",
        method: "GET",
        signedIn: true,
        entityParam: null,
        remembered: "pt",
      }),
    ).toEqual({ kind: "redirect", value: "pt" });
  });

  it("does nothing when nothing has ever been remembered (first visit ever)", () => {
    expect(
      decideEntityCookie({
        pathname: "/sales/invoices",
        method: "GET",
        signedIn: true,
        entityParam: null,
        remembered: null,
      }),
    ).toEqual({ kind: "none" });
  });

  it("never touches a POST (a form submission / Server Action already carries its own Entity)", () => {
    expect(
      decideEntityCookie({
        pathname: "/sales/invoices/new",
        method: "POST",
        signedIn: true,
        entityParam: null,
        remembered: "pt",
      }),
    ).toEqual({ kind: "none" });
  });

  it("never redirects an Entity-less path (auth/MFA, step-up)", () => {
    expect(
      decideEntityCookie({
        pathname: "/auth/mfa",
        method: "GET",
        signedIn: true,
        entityParam: null,
        remembered: "pt",
      }),
    ).toEqual({ kind: "none" });
    expect(
      decideEntityCookie({
        pathname: "/auth/step-up",
        method: "GET",
        signedIn: true,
        entityParam: null,
        remembered: "pt",
      }),
    ).toEqual({ kind: "none" });
  });

  it("never redirects a public path (login, the customer token page)", () => {
    expect(
      decideEntityCookie({
        pathname: "/login",
        method: "GET",
        signedIn: true,
        entityParam: null,
        remembered: "pt",
      }),
    ).toEqual({ kind: "none" });
    expect(
      decideEntityCookie({
        pathname: "/i/some-token",
        method: "GET",
        signedIn: true,
        entityParam: null,
        remembered: "pt",
      }),
    ).toEqual({ kind: "none" });
  });
});

describe("isPublicPath", () => {
  it("matches /login and /i and their sub-paths, nothing else", () => {
    expect(isPublicPath("/login")).toBe(true);
    expect(isPublicPath("/i")).toBe(true);
    expect(isPublicPath("/i/abc123")).toBe(true);
    expect(isPublicPath("/i/abc123/receipt")).toBe(true);
    expect(isPublicPath("/sales/invoices")).toBe(false);
    expect(isPublicPath("/")).toBe(false);
  });
});
