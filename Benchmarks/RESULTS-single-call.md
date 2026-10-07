# Results: single-call answers, run `sg-exp1` (2026-10-01)

Hook inert in this run: the corpus sat under a build directory, which the hook never reads, so no Grep or Read was answered in place (found 2026-10-01).

Sonnet 5.5, effort medium, 4 of the 9 tasks of `RESULTS-ios-app-10.md`, 10 repeats x 2 arms = 80 scored runs, all
valid, 40/40 correct in both arms. Same private 148k-line iOS app at the same pinned commit, same tasks file, no
compiler index (the corpus cannot build headlessly). Arm B ran a build of sift with three changes to what an answer
carries:

- every name-matched site `where` lists carries the text of its source line;
- `strings` follows a catalog key no literal spells to its accessor's declaration and use sites, in the same answer;
- a `where` answer with no index store opens with three short lines (386 characters, from about 1,450).

The four tasks are the ones whose arm B called `where` or `strings` in the earlier run; the other five were not re-run.

## What it shows

Raw input is every input token of a run, summed over its turns, whatever the cache did with it. Differences are B (with
sift) minus A (without), mean per run; "before" is the deployed build in `RESULTS-ios-app-10.md`, "after" is this run.
Intervals are 95% bootstrap intervals of the difference of means.

| task | raw input, before | raw input, after | 95% CI, after | tool calls A / B, after |
| --- | --- | --- | --- | --- |
| trace UI text to its code | -0.4k | -21.6k | [-26.4k, -19.0k] | 3.6 / 1.0 |
| find callers across modules | +16.1k | +3.4k | [-2.8k, +9.3k] | 1.3 / 1.8 |
| find conformers | +16.1k | +3.9k | [+3.8k, +3.9k] | 1.0 / 1.0 |
| chained questions on one large type | +18.0k | -1.8k | [-10.5k, +8.9k] | 8.3 / 8.0 |
| pooled over the 80 runs | +12.4k | -4.0k | [-13.5k, +5.5k] | |

- **Tracing a string became one call.** The run that took `strings`, `where` and a read now takes `strings` alone: raw
  input fell by more than half against the arm without sift, turns from 4.6 to 2.0, peak context by 3.6k.
- **The two lookups that cost more with sift no longer do, beyond its fixed start.** Callers and conformers went from
  about +16k raw input to about +3.5k. Finding conformers is one call in either arm, so what is left there is sift's
  start cost on two turns and an answer somewhat larger than the grep's (peak context +2.6k).
- **The agent still checks a name-matched answer about half the time.** In 5 of 10 callers runs it grepped after
  `where`, for a typealias or an unqualified call: the limits the answer itself states. A corpus with a compiler index,
  where callers are resolved, has not been measured.
- **Pooled raw input is not significantly different from the arm without sift**: the interval straddles zero.

## Weighted input, and why it is not the headline here

Weighted input (the metric of the earlier results) was -5.2k per run pooled, 95% CI [-9.7k, -0.6k], and list-price cost
was $1.56 without sift against $1.09 with. Part of that is the prompt cache carrying over between repeats, not the
change: where arm B's whole run was byte-identical from one repeat to the next, repeats 2 to 10 were served from the
cache and wrote nothing (conformers: 8.9k weighted on the first repeat, 2.1k on each of the other nine, against 6.0k
without sift), while arm A wrote its tool result afresh every repeat. The first repeat, which no carry-over helps, was
8.9k against 6.8k on that task. So raw input, turns and peak context are the figures to read.

## Limits

One model on one Claude Code version; four tasks, chosen because the changes touch them; tasks picked by sift's author;
ten repeats; a private corpus nobody else can re-run; "before" and "after" come from two sessions hours apart, compared
through their arm A, whose raw-input means agree within 14% on every task.
