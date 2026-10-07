# Results: a private 148k-line iOS app (v2), run `sg-full1` (2026-10-01)

Hook inert in this run: the corpus sat under a build directory, which the hook never reads, so no Grep or Read was answered in place (found 2026-10-01).

Sonnet 5.5, effort medium, 9 tasks x 3 repeats x 2 arms = 54 runs plus unscored warm-ups, all valid; 27/27 correct in
both arms. Corpus: a private 148k-line iOS app (784 Swift files, 19 over 800 lines) at a pinned commit, names redacted.
Sift under test: the build deployed 2026-10-01 14:03 (sha256 e0ca5eff...), after the day's fixes. Differences are B (with
sift) minus A (without), median [range] over 3 repeats. Cost is list-price equivalent, not money billed.

## What it shows

- **No saving overall.** Summed per repeat, B's weighted input was +41.6k [+31.9k, +59.9k] above A's, cost +$0.081
  [+0.065, +0.116]. Median run: A 13.7k weighted input, B 15.0k; turns 4 and 4.
- **One clear win, the case sift is built for:** understanding the signatures of a large type (large-type-signatures)
  took -12.1k weighted input [-21.9k, -9.9k], -2 turns and -$0.029 with sift, in all three repeats.
- **Everything else was flat to worse** (+0.5k to +6.8k), and the heaviest long-session task (chain-2) was +29.7k
  [+16.3k, +36.0k] worse with sift.
- **Fixed cost:** sift's primer, rule and tool definitions add +2,452 tokens to the first call of every run.
- **Limits:** the "long" chains ran 4-12 turns, not the 15-30 aimed for; one model; author-picked tasks; 3 repeats; the
  prompt cache carries over between runs (warm-ups mitigate it). It cannot speak to sessions much longer than these.

## Table

| task | pairs | success A | success B | invalid | input, weighted | input, raw | cache read | cache write | uncached | output | first-call context | peak context | turns | wall s | cost $ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| large-type-signatures | 3 | 3/3 | 3/3 | 0 | -12085 [-21871, -9937] | -23053 [-32698, -22797] | -19034 [-22906, -17634] | -5159 [-9788, -4015] | -4 [-4, -4] | -423 [-453, -87] | +2452 [+2452, +2452] | -2707 [-6255, -482] | -2 [-3, -2] | -2 [-4, -1] | -0.029 [-0.045, -0.024] |
| callers-cross-module | 3 | 3/3 | 3/3 | 0 | +3776 [+3776, +3776] | +6547 [+6547, +6547] | +4904 [+4904, +4904] | +1643 [+1643, +1643] | +0 [+0, +0] | -45 [-83, +55] | +2452 [+2452, +2452] | +4095 [+4095, +4095] | +1 [+1, +1] | +1 [-1, +1] | +0.007 [+0.007, +0.008] |
| conformers-protocol | 3 | 3/3 | 3/3 | 0 | -745 [-867, +5743] | +19663 [+19602, +19845] | +21089 [+17866, +21089] | -1428 [-1489, +1977] | +2 [+2, +2] | +54 [-210, +316] | +2452 [+2452, +2452] | +4247 [+4186, +4429] | +1 [+1, +2] | +2 [+2, +4] | +0.002 [-0.004, +0.012] |
| rename-sweep | 3 | 3/3 | 3/3 | 0 | +491 [-2428, +496] | +4907 [-4480, +4907] | +4904 [-3437, +4907] | +0 [-1041, +3] | +0 [-2, +0] | -115 [-214, -75] | +2452 [+2452, +2452] | +2455 [+1414, +2455] | +0 [-1, +0] | -2 [-3, -1] | -0.000 [-0.007, +0.000] |
| string-trace | 3 | 3/3 | 3/3 | 0 | +2162 [+1113, +4867] | +9767 [+9703, +9800] | +9143 [+7652, +9730] | +624 [+70, +2051] | +0 [+0, +0] | -33 [-50, +9] | +2452 [+2452, +2452] | +2824 [+2522, +2891] | +0 [+0, +0] | +0 [-0, +1] | +0.004 [+0.002, +0.009] |
| log-triage | 3 | 3/3 | 3/3 | 0 | +6756 [+5560, +12964] | +10366 [+10076, +13514] | +7402 [+7356, +7680] | +3010 [+2396, +6112] | +0 [+0, +0] | +209 [-21, +293] | +2452 [+2452, +2452] | +5462 [+5172, +8564] | +1 [+1, +2] | +1 [-1, +1] | +0.013 [+0.013, +0.029] |
| fix-restored | 3 | 3/3 | 3/3 | 0 | +6699 [-20866, +6776] | +33026 [-84062, +34085] | +31197 [-77500, +32352] | +1731 [-6554, +1827] | +2 [-8, +2] | +30 [-927, +321] | +2452 [+2452, +2452] | +4183 [-4102, +4279] | +2 [-3, +2] | +2 [-5, +14] | +0.014 [-0.051, +0.017] |
| chain-1 | 3 | 3/3 | 3/3 | 0 | +2784 [-68, +52460] | +36239 [+22087, +80650] | +38181 [+21784, +57284] | +303 [-1944, +23366] | +0 [+0, +2] | +73 [-427, +652] | +2452 [+2452, +2452] | +5400 [+3153, +25818] | -2 [-4, +1] | +1 [-1, +6] | +0.012 [-0.004, +0.106] |
| chain-2 | 3 | 3/3 | 3/3 | 0 | +29743 [+16255, +35989] | +97767 [-8147, +139300] | +83969 [-24230, +138073] | +13794 [+1221, +16083] | +4 [+0, +6] | +560 [-450, +613] | +2452 [+2452, +2452] | +3673 [-2185, +7520] | +4 [-4, +4] | +6 [-1, +7] | +0.055 [+0.039, +0.078] |
| **total** (summed per repeat) | 3 | 27/27 | 27/27 | 0 | +41592 [+31872, +59857] | +167704 [+65712, +186292] | +145029 [+47281, +179319] | +18433 [+6967, +22679] | -2 [-4, +6] | -226 [-358, +156] | +22068 [+22068, +22068] | +27400 [+25054, +44747] | -1 [-1, +5] | +5 [-7, +30] | +0.081 [+0.065, +0.116] |

Per-run medians by arm (valid runs):

| arm | runs | input, weighted | input, raw | cache read | cache write | uncached | output | first-call context | peak context | turns | wall s | cost $ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | 27 | 13720 | 36917 | 31635 | 5274 | 8 | 825 | 7322 | 12760 | 4 | 9 | 0.033 |
| B | 27 | 15001 | 36764 | 35663 | 5612 | 6 | 820 | 9774 | 15581 | 4 | 9 | 0.035 |

