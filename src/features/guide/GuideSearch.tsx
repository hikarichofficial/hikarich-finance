"use client";

import Link from "next/link";
import { useState } from "react";

export interface GuideSearchItem {
  readonly slug: string;
  readonly title: string;
  readonly summary: string;
  readonly group: string;
}

/** Filters the whole guide list as the person types (title, summary and group); empty box shows nothing extra. */
export function GuideSearch({ items }: { items: readonly GuideSearchItem[] }) {
  const [query, setQuery] = useState("");
  const needle = query.trim().toLowerCase();
  const matches =
    needle.length < 2
      ? []
      : items.filter((item) =>
          `${item.title} ${item.summary} ${item.group}`.toLowerCase().includes(needle),
        );
  return (
    <div className="guide-search">
      <label htmlFor="guide-search-input" className="guide-search-label">
        Cari panduan
      </label>
      <input
        id="guide-search-input"
        type="search"
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        placeholder="Ketik, misalnya: pembayaran, rekening, pajak"
        autoComplete="off"
      />
      {needle.length >= 2 ? (
        <ul className="guide-search-results" aria-live="polite">
          {matches.length === 0 ? (
            <li className="guide-search-empty">Tidak ada panduan yang cocok dengan huruf ini.</li>
          ) : (
            matches.map((item) => (
              <li key={item.slug}>
                <Link href={`/guide/${item.slug}`}>{item.title}</Link>
                <span>{item.group}</span>
              </li>
            ))
          )}
        </ul>
      ) : null}
    </div>
  );
}
