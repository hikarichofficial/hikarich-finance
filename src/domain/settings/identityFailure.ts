/** A refusal of the identity save that the person can fix, with the reason in plain Indonesian (decision 317):
 * "the Entity changed" (reload), "the email is not valid", "too long", "legal name missing", or `other`. */
export type IdentityFailureKind = "conflict" | "email" | "too_long" | "legal_name" | "other";

export class IdentityError extends Error {
  constructor(
    readonly kind: IdentityFailureKind,
    readonly detail: string,
  ) {
    super(`Profil tidak dapat disimpan (${kind}).`);
    this.name = "IdentityError";
  }
}

/** Tells the refusals of `update_entity_identity` apart by the text the database raises. */
export function identityFailure(message: string): IdentityFailureKind {
  if (message.includes("CONFLICT")) return "conflict";
  if (message.includes("email address is not valid")) return "email";
  if (message.includes("too long")) return "too_long";
  if (message.includes("legal name")) return "legal_name";
  return "other";
}
