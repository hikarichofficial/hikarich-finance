import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";
import { getSupabasePublicConfig } from "./config";

/** Paths reachable without a session. Everything else needs one (optimistic check only). */
export const PUBLIC_PATHS = ["/login", "/i"] as const;

export function isPublicPath(pathname: string): boolean {
  return PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`));
}

/** Paths that are never Entity-scoped (no `?entity=` to carry), even for a signed-in visitor. */
const ENTITY_LESS_PATHS = ["/auth/mfa", "/auth/step-up"] as const;

function isEntityLessPath(pathname: string): boolean {
  return (
    isPublicPath(pathname) ||
    ENTITY_LESS_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`))
  );
}

/** Remembers the last Entity explicitly chosen (via `?entity=`, Step 09 §5's switcher), so a link that
 * forgets to carry it forward -- a sidebar item, a back-button, a breadcrumb -- lands on that Entity
 * again instead of silently falling back to the person's first membership (PT and Personal must never
 * appear to merge just because a link omitted the param). Not a source of truth: every page's own
 * `requireAccess`/`requirePermission` still resolves and validates the Entity itself (Step 06, RLS is
 * the real authority) -- this cookie only decides what `?entity=` value a bare link is redirected to. */
export const ACTIVE_ENTITY_COOKIE = "hikarich-active-entity";

export type EntityCookieDecision =
  { kind: "none" } | { kind: "remember"; value: string } | { kind: "redirect"; value: string };

/**
 * Pure decision for the Entity-memory behaviour above, split out from `updateSession` so it can be unit
 * tested without a Supabase client or a real `NextRequest`/`NextResponse` pair.
 */
export function decideEntityCookie(input: {
  pathname: string;
  method: string;
  signedIn: boolean;
  entityParam: string | null;
  remembered: string | null;
}): EntityCookieDecision {
  if (!input.signedIn || input.method !== "GET" || isEntityLessPath(input.pathname)) {
    return { kind: "none" };
  }
  if (input.entityParam) return { kind: "remember", value: input.entityParam };
  if (input.remembered) return { kind: "redirect", value: input.remembered };
  return { kind: "none" };
}

/**
 * Refreshes the Supabase session cookies and redirects visitors without a valid session to /login.
 *
 * This is an OPTIMISTIC check (Next.js guidance: proxy is not an authorization layer). Real
 * authorization happens in server code (`requireAccess`) and, finally, in the database via RLS.
 */
export async function updateSession(request: NextRequest): Promise<NextResponse> {
  let response = NextResponse.next({ request });
  const { url, publishableKey } = getSupabasePublicConfig();

  const supabase = createServerClient(url, publishableKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        for (const { name, value } of cookiesToSet) request.cookies.set(name, value);
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) {
          response.cookies.set(name, value, options);
        }
      },
    },
  });

  // getClaims validates the JWT signature and refreshes expired sessions.
  const { data } = await supabase.auth.getClaims();
  const signedIn = Boolean(data?.claims?.sub);
  const { pathname, search } = request.nextUrl;

  if (!signedIn && !isPublicPath(pathname)) {
    const login = request.nextUrl.clone();
    login.pathname = "/login";
    login.search = "";
    if (pathname !== "/") login.searchParams.set("next", `${pathname}${search}`);
    const redirect = NextResponse.redirect(login);
    for (const cookie of response.cookies.getAll()) redirect.cookies.set(cookie);
    return redirect;
  }

  // Remember (or restore) the active Entity. A POST is a form submission or a Server Action, which
  // already carries its own Entity in the request body (a hidden field or FormData entry), never the
  // URL, so redirecting it here would turn a submission into a lost navigation -- `decideEntityCookie`
  // leaves those (and entity-less paths) alone.
  const entityDecision = decideEntityCookie({
    pathname,
    method: request.method,
    signedIn,
    entityParam: request.nextUrl.searchParams.get("entity"),
    remembered: request.cookies.get(ACTIVE_ENTITY_COOKIE)?.value ?? null,
  });
  if (entityDecision.kind === "remember") {
    response.cookies.set(ACTIVE_ENTITY_COOKIE, entityDecision.value, {
      httpOnly: true,
      sameSite: "lax",
      path: "/",
      maxAge: 60 * 60 * 24 * 180,
    });
  } else if (entityDecision.kind === "redirect") {
    const target = request.nextUrl.clone();
    target.searchParams.set("entity", entityDecision.value);
    const redirect = NextResponse.redirect(target);
    for (const cookie of response.cookies.getAll()) redirect.cookies.set(cookie);
    return redirect;
  }

  response.headers.set("Cache-Control", "private, no-store");
  if (pathname === "/i" || pathname.startsWith("/i/")) {
    // The customer page carries a secret token in its address: keep it out of referrers, caches and search.
    response.headers.set("Referrer-Policy", "no-referrer");
    response.headers.set("X-Robots-Tag", "noindex, nofollow, noarchive");
  }
  return response;
}
