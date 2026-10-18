import type { NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/proxy";

export async function proxy(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  // Everything except Next internals, static image assets and the app manifest (the browser fetches it
  // without a login, so a redirect to the login page would break "Add to Home Screen").
  matcher: [
    "/((?!_next/static|_next/image|icon.png|favicon.ico|manifest.webmanifest|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
