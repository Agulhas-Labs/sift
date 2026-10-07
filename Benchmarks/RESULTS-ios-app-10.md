# Results: a private 148k-line iOS app (v2), 10 repeats (2026-10-01)

Hook inert in this run: the corpus sat under a build directory, which the hook never reads, so no Grep or Read was answered in place (found 2026-10-01).

Sonnet 5.5, effort medium, the same 9 tasks as `RESULTS-ios-app.md`, 10 repeats x 2 arms = 180 scored runs; 90/90
correct in both arms. Corpus: a private 148k-line iOS app at a pinned commit, names redacted; its tasks file stays
outside this repository. Differences are B (with sift) minus A (without), per run, in weighted input tokens: input
tokens weighted at list-price multiples of the base input price (uncached 1, 5-minute cache write 1.25, 1-hour write
2, cache read 0.1), as `Benchmarks/README.md` defines them. Intervals are 95% bootstrap confidence intervals of the
mean difference. The build of sift under test and the per-run raw table are not recorded here.

## What it shows

- **No detectable difference overall.** Pooled over all 180 runs, the mean per-run difference was +1.9k weighted
  input tokens, 95% CI [-1.6k, +5.6k]: the interval straddles zero. Median run: 10.8k with sift, 12.7k without.
- **Two tasks used less input with sift**, both where the agent had to take in a lot of source:

  | task | difference per run (B - A) | 95% CI | turns |
  | --- | --- | --- | --- |
  | large-type-signatures (understand a large type) | -7.1k | [-10.5k, -3.6k] | -2 |
  | string-trace (UI text to its code) | -5.2k | [-10.2k, -0.1k] | |
  | callers-cross-module | +1.8k | [+1.1k, +2.7k] | |
  | chain-2 (long open-ended chain) | +21.4k | [-3.9k, +43.8k] | |
  | the other five tasks | interval straddles zero | not recorded here | |

- **One task cost more:** callers-cross-module, +1.8k per run.
- **The long open-ended chains are high-variance:** chain-2's mean was +21.4k, but its interval includes zero, so it
  is not a significant difference either way.
- **Fixed start cost:** sift's primer, rule and tool definitions add about 1,300 tokens to the first call of a run
  (2,452 before the slimmer start the 3-repeat run measured).

## Limits

- One model (`claude-sonnet-5-5`) on one Claude Code version.
- Tasks picked by sift's author.
- Ten repeats per task; the per-task intervals are wide, and a difference smaller than its interval is not evidence.
- The "long" chains ran 4-12 turns, not the 15-30 aimed for; this says nothing about sessions much longer than that.
- The prompt cache carries over between runs (warm-ups mitigate it), so weighted input depends on run order.
- An earlier 60-run benchmark on sift's own repository (`RESULTS.md`, tiny tasks) showed no saving either.

## Reproduce

The harness is `Benchmarks/bench.py`; `Benchmarks/README.md` has the isolation and the commands. A run over a
private corpus passes its tasks file and corpus by path:
`sh Benchmarks/run.sh --tasks <tasks.json> --corpus <repository>@<commit> --repeats 10`, then
`sh Benchmarks/analyse.sh <session>`.
