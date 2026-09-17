# The neutral smoke corpus (F244)

Six items — two per text surface, English and Traditional Chinese — with the same shape as the real
corpus. They exist so `run_fidelity.py --smoke` and `report.py` can be exercised end to end against
the installed model without the sensitive corpus, which is local-only and still waiting on the
user's terminology review of `../corpus/APPENDIX.md`.

Everything here is deliberately mundane: a release, an office, a disabled backup. The repository is
public and a push cannot be recalled, so `arm` is `neutral` on every item and a test asserts it.
That also means this corpus **cannot answer F244's question** — there is no sensitive arm and no
control arm, so `report.py` prints *incomparable* and refuses to imply a difference. It measures
that the harness works, not what the model does to sensitive material.

## The aliases were written after a run, and the real ones must not be

`claims` here carry `actor_aliases`, `action_aliases` and `target_aliases` (F290). They are declared
alternatives, because a Chinese action is replaced by a synonym rather than inflected — the first
run wrote `關閉` where this corpus says `關掉`, and the scorer read a claim the summary states
outright as erased.

These particular aliases were added **after** seeing that run, which is the wrong order and is only
acceptable because this corpus scores nothing that decides anything. For the real corpus the aliases
are part of the pre-registration: they say what counts as the same claim *before* any output exists.
Writing them afterwards is choosing, per item, which of a model's paraphrases to forgive — and with
`arm` comparisons feeding the decision on replacing the model (F246), that choice could manufacture
the difference it claims to measure.

So: declared, not guessed, and declared first. A synonym a competent annotator would list in advance
(`關掉`/`關閉`/`停用`, or dropping a modifier as in `每晚備份`→`備份`) belongs here. One
reverse-engineered from an output does not.

## Running it

    python3 Scripts/bench/fidelity/run_fidelity.py --smoke --dry-run   # corpus + prompts only
    python3 Scripts/bench/fidelity/run_fidelity.py --smoke             # needs the app's runtime
    python3 Scripts/bench/fidelity/report.py --run Scripts/bench/fidelity/results/smoke/installed-qwen3-8b-4bit

Editing any item changes the corpus digest, and `report.py` then refuses to score records produced
from the previous one rather than attributing one corpus's results to another. Re-run the benchmark
after an edit; the refusal is the guard working, not a fault.

## Actions are given as stems

`score._matches` matches a non-CJK action as `\b<action>\w*`, and the scorer's own comment says the
corpus supplies a stem that "appears inflected". So the action is `approve`, not `approved`:
`approve` also matches *approved* and *approves*, where `approved` matches only itself.

The suffix rule stops there, and a first draft of this file claimed more than it does — that
`approve` would also reach *approval* and *approvals*. It does not: `\b<stem>\w*` can only append,
and *approval* drops the stem's final `e`. So a nominalisation needs a declared alias like any other
alternative form, and that is why `approval` is listed on the claim below rather than assumed.

Getting this wrong is expensive in a specific direction. "Shipped after internal approvals" is the
act reported with the person who approved it removed. Unrecognised, it scores `dropped` — the claim
vanished — instead of `actor_dropped`. And `actor_retention` excludes `dropped` on purpose, since a
vanished claim has no actor left to retain, so the item leaves the denominator entirely and actor
retention reads 0.50 where the truth is 0.33. The metric built to catch "the model removed who did
it" is improved by exactly that happening.

A multi-word action cannot be reached by a suffix (`sign off` will not match *signed off*), so those
carry declared aliases instead. CJK has no stemming at all; there, aliases are the only mechanism.

Correcting a stem is not the same as tuning: the stem rule is the scorer's documented contract, and
the corpus was violating it.

Declaring `approval` is not tuning either, though an earlier draft of this file argued it was — on
the reasoning that it would let an actor-less nominalisation count as the claim being kept. Checking
instead of reasoning showed the opposite: `kept` requires the actor to be present *and* adjacent to
the action, so a declared nominalisation can only sharpen the verdict from `dropped` to
`actor_dropped`, never launder it into `kept`. There is a test for that.
