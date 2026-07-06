// @ts-nocheck
// PLANT G4: file-level TS suppression on the line above - every type error
// PLANT G4: in this file is hidden. The strongest Category G form on the TS side.
export function render(el) {
  // PLANT LG5 (Category LOG, stdout-as-log-channel): console.log used as the
  // PLANT LG5: render path's log channel. Deterministic: LOGGING_RE, and
  // PLANT LG5: web/app.ts is a non-test path -> stdout_logging.txt.
  console.log("render tick for", el.id);
  el.innerHtml = "<div>ok</div>"; // typo'd property that @ts-nocheck hides
}
