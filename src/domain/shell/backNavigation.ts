/**
 * Where "← Kembali ke …" goes (owner, 9 October 2026: "jika saya membuka 1 menu, dan tekan back, harusnya kembali
 * ke menu yang sebelumnya digunakan, bukan menu yang konek dengan menu terbaru yang saya buka").
 *
 * A record page used to link to its own list ("Kembali ke daftar invoice") whatever the person came from: open an
 * invoice from Aktivitas Terbaru, press "Kembali", and the Invoice list opened instead of Aktivitas Terbaru. Now the link
 * takes the person to the page they were on just before, and only falls back to the fixed list when there is no such
 * page (the page was opened directly, from a bookmark, or after a reload) or when the previous page is a form that
 * would only bring them back to the screen they just saved (new / edit).
 */

/** Pages that make no sense to come back to: the form that created or changed this record. */
const FORM_PATH = /\/(new|edit)(\/|$)/;

/** True when "back" should be the browser's own history step instead of the fixed list. */
export function shouldGoBackInHistory(previousPath: string | null, currentPath: string): boolean {
  if (!previousPath) return false;
  if (previousPath === currentPath) return false;
  if (FORM_PATH.test(previousPath)) return false;
  return true;
}

/**
 * The tiny memory of the pages visited in this tab. `visit` is called with every new pathname; the page before the
 * current one is `previous`. Reloading the tab starts a fresh memory, which is exactly when the fixed list is right.
 */
export function createPathMemory() {
  let current: string | null = null;
  let previous: string | null = null;
  return {
    visit(path: string) {
      if (path === current) return;
      previous = current;
      current = path;
    },
    get previous() {
      return previous;
    },
    get current() {
      return current;
    },
  };
}
