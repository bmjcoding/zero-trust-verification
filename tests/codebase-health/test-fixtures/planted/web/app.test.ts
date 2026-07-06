// Tests for web/app.ts. PLANTS TQ3, TQ7, TQ8 live here.
import { render } from "./app";

describe("render", () => {
  // PLANT TQ3 (literal tautology): the expectation compares a constant to
  // PLANT TQ3: itself — render's output is never inspected, so the test
  // PLANT TQ3: passes no matter what render does. Expected: deterministic via
  // PLANT TQ3: TEST_VACUOUS_RE, test-health/T9.
  test("renders without throwing", () => {
    const el = document.createElement("div");
    render(el);
    expect(true).toBe(true);
  });

  // PLANT TQ7 (skipped test): the one assertion that would catch app.ts's
  // PLANT TQ7: innerHtml property typo (the real innerHTML stays empty, so
  // PLANT TQ7: "ok" never appears) — disabled at the runner. Expected:
  // PLANT TQ7: deterministic via TEST_SKIP_RE, test-health/T12.
  it.skip("shows the ok badge after render", () => {
    const el = document.createElement("div");
    render(el);
    expect(el.innerHTML).toContain("ok");
  });

  // PLANT TQ8 (snapshot rubber-stamp): the committed snapshot in
  // PLANT TQ8: web/__snapshots__/app.test.ts.snap is an EMPTY div — it
  // PLANT TQ8: blesses the same innerHtml typo TQ7 would have caught (render
  // PLANT TQ8: sets a nonexistent property, so nothing lands in the DOM) and
  // PLANT TQ8: stays green exactly as long as the bug does. Expected: agent
  // PLANT TQ8: finding, test-health/T11 (cross-file judgment: the score is
  // PLANT TQ8: that the stamped content is itself wrong).
  it("matches the render snapshot", () => {
    const el = document.createElement("div");
    render(el);
    expect(el.outerHTML).toMatchSnapshot();
  });
});
