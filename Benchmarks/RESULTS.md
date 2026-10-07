# Results: paired benchmark, run `full2` (2026-10-01)

Hook inert in this run: the corpus sat under a build directory, which the hook never reads, so no Grep or Read was answered in place (found 2026-10-01).

Sonnet 5.5 (`claude-sonnet-5-5`), effort medium, 10 tasks x 3 repeats x 2 arms = 60 runs, all valid (arm checks held:
no sift calls in arm A, some in arm B). Corpus: sift's own repository @27d3aca3. Sift build under test: the deployed
`sift` at that commit (before the 2026-10-01 fixes). Differences are B (with sift) minus A (without), median [range]
over the 3 repeats. Cost is a list-price equivalent, not money billed.

## What it shows

- **On these tasks sift did not reduce input.** Summed per repeat, B's weighted input was +21.6k [+14.2k, +29.6k]
  above A's, raw input +27k [-9k, +32k], cost +$0.034 [+0.020, +0.055]. Success was 27/30 in both arms.
- **It helped on the string-trace and type-lookup tasks** (weighted input -1.5k to -6.3k per run) and **cost more on
  the fix tasks** (+10k to +17k), where the arm adds a primer and the model still reads what it edits.
- **The tasks are small** (median 3 turns, 6-8 s a run): the corpus's files are read in a call or two either way, so
  the benchmark cannot show a saving that comes from large files or long sessions. It cannot support, or refute, a
  claim about those. A benchmark with large-file and long-session tasks is the next step.
- **One task is broken:** `report-shell-word-failures` scored 0/3 in both arms (its expected failing set is not what
  either arm returned), so it carries no information until its check is re-pinned.
- Caveats: one model, author-picked tasks, 3 repeats, prompt cache carried over between runs (weighted input and cost
  depend on run order; raw input does not).

## Table

| task | pairs | success A | success B | invalid | input, weighted | input, raw | cache read | cache write | uncached | output | turns | wall s | cost $ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| def-adds-no-prompt | 3 | 3/3 | 3/3 | 0 | +3429 [+3427, +3972] | +5356 [+5354, +15424] | +3833 [+3832, +14144] | +1522 [+1278, +1523] | +0 [+0, +2] | +64 [-43, +200] | +0 [+0, +1] | +4 [+2, +4] | +0.007 [+0.006, +0.010] |
| refs-token-estimate | 3 | 3/3 | 3/3 | 0 | +2366 [+1261, +2468] | +14808 [+4271, +14856] | +14338 [+3832, +14341] | +465 [+439, +516] | +2 [+0, +2] | +112 [-42, +264] | +1 [+1, +1] | +4 [+1, +6] | +0.006 [+0.002, +0.008] |
| callers-claude-settings | 3 | 3/3 | 3/3 | 0 | +2533 [+2529, +3389] | +4907 [+4903, +5335] | +3832 [+3830, +3832] | +1075 [+1073, +1503] | +0 [+0, +0] | -84 [-171, -78] | +0 [+0, +0] | +0 [+0, +3] | +0.004 [+0.003, +0.006] |
| type-wrapped-run-permission | 3 | 3/3 | 3/3 | 0 | -6258 [-6264, -5595] | -9947 [-9949, -9614] | -7175 [-7176, -7174] | -2769 [-2772, -2438] | -2 [-2, -2] | -219 [-239, -217] | -1 [-1, -1] | -1 [-1, -1] | -0.015 [-0.015, -0.013] |
| behaviour-no-prompt-modes | 3 | 3/3 | 3/3 | 0 | +2622 [-9949, +3164] | +3955 [+3702, +8218] | +2517 [+2498, +13886] | +1185 [-5670, +1457] | +0 [+0, +2] | -19 [-27, +3] | +0 [+0, +0] | +3 [+2, +3] | +0.005 [-0.020, +0.006] |
| string-rerun-costs-nothing | 3 | 3/3 | 3/3 | 0 | -1620 [-1677, -1417] | -4711 [-4740, -4611] | -4106 [-4107, -4105] | -604 [-632, -502] | -2 [-2, -2] | -206 [-210, -148] | -1 [-1, -1] | +0 [-1, +0] | -0.005 [-0.005, -0.005] |
| string-nothing-stored | 3 | 3/3 | 3/3 | 0 | -1507 [-1507, -1501] | -4620 [-4620, -4615] | -4069 [-4069, -4067] | -549 [-549, -546] | -2 [-2, -2] | -151 [-175, -149] | -1 [-1, -1] | +1 [-1, +1] | -0.005 [-0.005, -0.004] |
| fix-token-estimate-thousands | 3 | 3/3 | 3/3 | 0 | +17194 [+14149, +25446] | +32784 [+21734, +45636] | +25459 [+15431, +34644] | +7323 [+6303, +10990] | +2 [+0, +2] | +322 [+232, +362] | +3 [+2, +3] | +2 [+1, +3] | +0.038 [+0.031, +0.054] |
| fix-allow-rule-bare-command | 3 | 3/3 | 3/3 | 0 | +10269 [+1458, +11042] | +10854 [-10993, +17035] | +5615 [-12337, +12527] | +4508 [+1348, +5241] | -2 [-4, +0] | -71 [-367, +121] | +0 [-3, +1] | +1 [-5, +2] | +0.021 [-0.001, +0.022] |
| report-shell-word-failures | 3 | 0/3 | 0/3 | 0 | -3775 [-4477, +233] | -38135 [-39755, -22012] | -38152 [-39488, -23291] | +23 [-261, +1283] | -6 [-6, -4] | -461 [-582, -170] | -3 [-3, -2] | +151 [-8, +188] | -0.012 [-0.015, -0.001] |
| **total** (summed per repeat) | 3 | 27/30 | 27/30 | 0 | +21649 [+14197, +29560] | +27447 [-8972, +32335] | +13338 [-16910, +22647] | +9696 [+7950, +14117] | -8 [-12, -8] | -848 [-939, -362] | -2 [-5, +0] | +163 [+0, +201] | +0.034 [+0.020, +0.055] |

Per-run medians by arm (valid runs):

| arm | runs | input, weighted | input, raw | cache read | cache write | uncached | output | turns | wall s | cost $ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | 30 | 7968 | 24430 | 21750 | 2908 | 6 | 379 | 3 | 6 | 0.020 |
| B | 30 | 8552 | 24100 | 17376 | 3300 | 4 | 366 | 3 | 8 | 0.020 |
