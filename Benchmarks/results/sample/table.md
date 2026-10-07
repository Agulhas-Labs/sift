# Paired benchmark: smoke

B minus A per repeat, then the median [min, max] over repeats. Only repeats where both arms ran valid are paired. Input weighted = uncached + 1.25 x 5-minute write + 2 x 1-hour write + 0.1 x read. Cost is Claude Code's list-price equivalent, not money billed.

| task | pairs | success A | success B | invalid | input, weighted | input, raw | cache read | cache write | uncached | output | turns | wall s | cost $ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| callers-claude-settings | 1 | 1/1 | 1/1 | 0 | +14057 | +4932 | -2207 | +7139 | +0 | -272 | +0 | +2 | +0.025 |
| **total** (summed per repeat) | 1 | 1/1 | 1/1 | 0 | +14057 | +4932 | -2207 | +7139 | +0 | -272 | +0 | +2 | +0.025 |

Per-run medians by arm (valid runs):

| arm | runs | input, weighted | input, raw | cache read | cache write | uncached | output | turns | wall s | cost $ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | 1 | 8885 | 15781 | 11933 | 3844 | 4 | 514 | 2 | 6 | 0.023 |
| B | 1 | 22943 | 20713 | 9726 | 10983 | 4 | 242 | 2 | 8 | 0.048 |
