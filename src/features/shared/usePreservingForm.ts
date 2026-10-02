"use client";

import { startTransition, useEffect, useRef, type FormEvent } from "react";

/**
 * Keeps what the person typed when a form's server action answers with an error.
 *
 * React clears an uncontrolled form as soon as its `action` finishes, whatever the outcome, so a refused
 * save used to wipe every field. Spreading this hook's result on the `<form>` submits the same action
 * through `onSubmit` instead (inside a transition, so `useActionState`'s pending flag still works), which
 * leaves the fields alone; they are cleared only after the action reports `status: "ok"`. `action` stays
 * on the element so the form still works before the page's scripts have loaded.
 */
export function usePreservingForm(action: (formData: FormData) => void, state: { status: string }) {
  const ref = useRef<HTMLFormElement>(null);

  useEffect(() => {
    if (state.status === "ok") ref.current?.reset();
  }, [state]);

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const submitter = (event.nativeEvent as SubmitEvent).submitter;
    const formData = new FormData(event.currentTarget, submitter);
    startTransition(() => action(formData));
  }

  return { ref, action, onSubmit };
}
