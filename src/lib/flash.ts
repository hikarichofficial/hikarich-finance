import { cookies } from "next/headers";

/** Name of the short-lived cookie that carries a one-line notice across a redirect (read by the toast host). */
export const FLASH_COOKIE = "hf_flash";

/**
 * Leaves a one-line notice for the next page the person lands on ("Invoice tersimpan."). A server action that
 * redirects after success has no way to hand back a result, so without this the person arrives on the new
 * page with no confirmation that anything happened. The notice sits in a cookie for at most a minute; the
 * toast host in the root layout reads it, shows it once and deletes it. The text is not sensitive: never put
 * amounts, names or anything else private in it.
 */
export async function setFlash(
  message: string,
  kind: "success" | "error" | "info" = "success",
): Promise<void> {
  const jar = await cookies();
  jar.set(FLASH_COOKIE, encodeURIComponent(JSON.stringify({ kind, message })), {
    path: "/",
    maxAge: 60,
    sameSite: "lax",
    httpOnly: false,
    secure: process.env.NODE_ENV === "production",
  });
}
