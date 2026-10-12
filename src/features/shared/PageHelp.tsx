"use client";

import { usePathname } from "next/navigation";
import { PAGE_HELP, SECTION_HELP, pageHelpKey, type HelpEntry } from "@/content/pageHelp";

function HelpText({ entry }: { entry: HelpEntry }) {
  return (
    <div className="page-help">
      <p>{entry.summary}</p>
      {entry.more ? (
        <details>
          <summary>Selengkapnya</summary>
          <p>{entry.more}</p>
        </details>
      ) : null}
    </div>
  );
}

/**
 * Satu kalimat tentang fungsi halaman dan dampaknya, tepat di bawah judul halaman (decision 410). Teksnya ada di
 * `src/content/pageHelp.ts`; halaman yang tidak ada di sana tidak menampilkan apa-apa.
 */
export function PageHelp() {
  const pathname = usePathname();
  const entry = PAGE_HELP[pageHelpKey(pathname ?? "")];
  return entry ? <HelpText entry={entry} /> : null;
}

/** Penjelasan singkat di bawah judul sebuah bagian atau isian (kunci di `SECTION_HELP`). */
export function SectionHelp({ id }: { id: keyof typeof SECTION_HELP | (string & {}) }) {
  const entry = SECTION_HELP[id];
  return entry ? <HelpText entry={entry} /> : null;
}
