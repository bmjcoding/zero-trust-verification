# The Grill Contract (shared by S2 and S5 — ADR 0026)

> The question-style contract for every human-facing question this skill asks.
> S2 (the front-door grill) and S5 (the residue grill) both load this file and
> hold every question to it. Hard Contract 4 is the anchor: questions are
> one-at-a-time with a recommendation. The field failure this contract kills:
> a 50-minute silent runtime before the first question, then questions so long
> the human loses focus halfway ("certification-exam style" — ADR 0026).

## The discipline (imported from the grilling pattern)

Interview the human relentlessly about the intent until you reach shared
understanding. Walk down each branch of the decision tree, resolving
dependencies between decisions one by one. For each question, provide your
recommended answer. Do not build until the human confirms shared
understanding.

## Hard rules — every question, no exceptions

1. **One decision per question.** Never bundle; asking multiple questions at
   once is bewildering. If an answer forks the tree, the fork is the NEXT
   question.
2. **≤3 sentences of setup.** State only what the human needs to decide this
   one thing. Context they already gave you is not repeated back.
3. **Recommendation in one line.** A concrete proposed answer the human can
   accept with "yes" — a bare question hands them a blank; a proposal invites
   scrutiny.
4. **Dissent and trade-off detail only on request.** The counter-argument is
   recorded in `interrogation.log`, WRITTEN, never read aloud. If the human
   asks "why" or "what's the downside", THEN present it.
5. **FACTS are looked up, never asked.** Anything findable in the codebase,
   `CONTEXT.md`, the manifest, the glossary, or org-memory is your job.
   DECISIONS — values/risk appetite, unobservable external facts,
   irreversible commitments (the ADR 0002 classes) — are the human's: ask and
   **WAIT**. A question you answer yourself is self-interviewing.
6. **NO background work while a question is pending.** Record the answer; the
   next question follows immediately. No dispatches, no re-validation runs,
   no log-writing between the answer and the next question.
7. **Bookkeeping batches at checkpoints.** `interrogation.log` entries,
   `CONTEXT.md` edits, draft ADRs, and session-branch commits (HC5) land at
   step boundaries or natural pauses the HUMAN takes — never mid-exchange.

## Question shape

```text
Q<n>. <the single decision, ≤3 sentences of setup>
   Recommend: <one-line recommended answer>
```

Answer recorded → next question. That is the whole loop.
