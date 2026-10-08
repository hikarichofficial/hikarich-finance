import Link from "next/link";
import {
  describeProblems,
  encodeProblems,
  type ProblemTarget,
} from "@/domain/forms/problemTargets";

/**
 * The red message under a refused save/submit (OWNER, 8 October 2026): what the database said, in Indonesian, and
 * -- when it could tell -- exactly which line and column (or field) to change. The same fields are painted red in
 * the form itself (`field-problem`); on a Detail page, `fixHref` leads to the form with them already marked.
 */
export function ProblemNotice({
  message,
  targets,
  editHref,
  fixHint,
}: {
  message: string | undefined;
  targets?: readonly ProblemTarget[];
  /** The edit form of the same draft; it opens with the problem fields marked (`?problems=`). */
  editHref?: string;
  /** Shown instead of the link when the record cannot be edited as it is (e.g. recall it to a draft first). */
  fixHint?: string;
}) {
  const where = describeProblems(targets ?? []);
  const fixHref = editHref
    ? `${editHref}${editHref.includes("?") ? "&" : "?"}problems=${encodeURIComponent(encodeProblems(targets ?? []))}`
    : undefined;
  return (
    <div role="alert" className="error problem-notice">
      <p>{message}</p>
      {where.length > 0 ? (
        <p className="problem-notice-where">
          <strong>Yang perlu diubah:</strong> {where.join("; ")}
        </p>
      ) : null}
      {where.length > 0 && fixHref ? (
        <p>
          <Link href={fixHref} className="btn-secondary">
            Buka formulir, bagian yang salah ditandai merah
          </Link>
        </p>
      ) : null}
      {where.length > 0 && !fixHref && fixHint ? <p className="hint">{fixHint}</p> : null}
    </div>
  );
}
