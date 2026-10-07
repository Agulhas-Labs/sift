# Results: hook live, compiler index, run `sg-live10` (2026-10-01)

Main at b663ae84, the hook live (unlike the earlier runs, whose corpus sat under a build directory the hook never
reads), and a compiler index, so `where` answered callers from the index store. 9 tasks, 10 repeats x 2 arms = 180
runs, all valid; correct 89/90 without sift and 90/90 with, on a private corpus.

## What it shows

Session price (defined in `Benchmarks/README.md`): input-token equivalents for one fresh session with no cache carried in
from other runs. Differences are with sift against without, mean per run.

| task | session price, with sift against without |
| --- | --- |
| trace UI text to its code | -41% |
| find callers across modules | -19% |
| understand a large type | -18% |
| a long open-ended chain | -13% |
| locate and fix a bug | +11% (interval straddles zero) |
| log triage | +16% |
| chained questions on one type | +23% |
| rename sweep | +28% |
| find conformers | +46% |
| pooled over the 180 runs | 0.0% [-5.5k, +5.6k] |

Four tasks cost less with sift and five cost more; the pooled interval straddles zero.

## Follow-up runs, one change each

Each re-ran a single task on a build carrying one change (the last two, one pair of changes), same corpus and
method:

- **Locate and fix, with `search name:` reading `a|b` and `/regex/`:** -1% (from +11%). The agent's first `search`
  had been an alternation or a regex in 9 runs of 10, each refused; refusals fell from 0.8 to 0.1 a run.
- **Rename sweep, with a file-name-only search let through by the hook:** +3% (from +28%), an interval straddling
  zero. The hook had denied that search and answered with a larger `where` in 10 runs of 10, and the agent re-ran
  it in the shell.
- **Conformers, with one conformers list and source text on store rows:** +7% (from +46%); greps after `where` fell
  from 1.9 to 0.3 a run.
- **Callers, with the same two changes:** -9% (from -19%). The added text costs where a resolved answer was already
  trusted.

## All nine again, on the build that folds the changes in (`sg-live10b`, 2026-10-02)

Main at 172d7fd3: the three changes above, plus the two a review asked for. Same nine tasks, corpus and method; 180
runs, all valid; correct 90/90 without sift and 89/90 with (the one miss reached the right answer and left out the
answer line the check reads).

| task | session price, with sift against without | 95% interval of the difference |
| --- | --- | --- |
| trace UI text to its code | -37% | [-9.4k, -7.1k] |
| locate and fix a bug | -18% | [-16.0k, -1.0k] |
| a long open-ended chain | -16% | [-21.0k, -3.6k] |
| find callers across modules | -9% | [-2.0k, -1.3k] |
| find conformers | -2% | [-0.6k, -0.1k] |
| understand a large type | -5% | [-3.7k, +1.9k], no detectable difference |
| rename sweep | +7% | [-0.2k, +2.5k], no detectable difference |
| chained questions on one type | +8% | [-0.2k, +5.7k], no detectable difference |
| log triage | +27% | [+3.2k, +6.4k] |
| pooled over the 180 runs | -8.3% | [-7.8k, +2.7k], no detectable difference |

Five tasks cost less with sift, one costs more, three show no detectable difference. The pooled mean moved from
level to 8% under the arm without sift, and its interval still straddles zero: the tasks differ too much in size for
180 runs to settle a pooled figure. Understanding a large type was -18% in `sg-live10` and is -5% here, inside its
interval both times; the run-to-run spread on that task is that wide.

What still costs, read from the transcripts: log triage asks for the function a line is in, and the answer returns
the whole function (about 3.8k characters); on the chained questions the hook answered a read or a search in place
and the agent re-ran it about once a run.

## Limits

One model on one Claude Code version; tasks picked by sift's author; a private corpus nobody else can re-run. Ten
repeats leave per-task intervals wide, and the two nine-task runs were hours apart on different builds, compared
through their arm without sift.
