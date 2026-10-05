import Link from "next/link";
import { parseInline } from "@/domain/guide/guides";

/** One paragraph of guide text: **label** in bold, [teks](slug) as a link to another guide. */
export function GuideText({ text }: { text: string }) {
  return (
    <>
      {parseInline(text).map((token, index) => {
        if (token.kind === "bold") return <strong key={index}>{token.text}</strong>;
        if (token.kind === "link") {
          return (
            <Link key={index} href={`/guide/${token.slug}`}>
              {token.text}
            </Link>
          );
        }
        return <span key={index}>{token.text}</span>;
      })}
    </>
  );
}
