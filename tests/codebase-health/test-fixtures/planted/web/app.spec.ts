// Render widget spec. PLANTS TF9, TF10 live here.
import { render } from "./app";

describe("render", () => {
  // PLANT TF9 (test-health T1, setTimeout-as-sync in a .spec.ts): render is
  // PLANT TF9: synchronous, but the assertion waits a fixed 250ms for it -
  // PLANT TF9: pure scheduler roulette under CI load, and 250ms of dead time
  // PLANT TF9: on every green run. Remedy: assert synchronously, or use fake
  // PLANT TF9: timers when a real delay is ever introduced.
  it("renders the ready markup", (done) => {
    const el = document.createElement("div");
    render(el);
    setTimeout(() => {
      expect(el.innerHTML).toContain("ok");
      done();
    }, 250);
  });

  // PLANT TF10 (test-health T3, Math.random input): a fresh random widget id
  // PLANT TF10: on every run means every run exercises a different input, so
  // PLANT TF10: a failing id can never be replayed. Remedy: a fixed table of
  // PLANT TF10: representative ids, or a seeded generator.
  it("accepts any widget id", () => {
    const id = Math.floor(Math.random() * 100000);
    const el = document.createElement("div");
    el.id = `widget-${id}`;
    render(el);
    expect(el.id).toBe(`widget-${id}`);
    expect(el.innerHTML).toContain("ok");
  });
});
