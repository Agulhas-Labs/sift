# Usage-log fixture — where it came from

`usage-log.jsonl` is a **real capture**: every line of a `~/.sift/usage.jsonl` covering one month,
6,678 calls. It is here for the
same reason the run-output captures are: the savings arithmetic is a claim about a distribution — how
many digests compress, how many the floor passes through, how many record nothing at all — and a
hand-written log only ever proves the aggregation matches what its author expected that distribution
to be. This one is what a month of real use actually produced.

**Every field the arithmetic reads is verbatim**: `tool`, `ms`, `ok`, `outBytes`, `srcBytes`, and the
order of the lines. Nothing was added, dropped, reordered or rounded. So are the sizes — how many calls
each root received, and how large each source was — because they are measurements rather than names.

The data is scrubbed of everything that identifies the person who produced it: the three naming fields
are pseudonymised, and the clock is synthetic.

**The three naming fields are pseudonymised**, by the scheme the tool's own `Redactor` uses — a salted
SHA-256 truncated to six hex characters, domain-separated so the same string never links a root row to
a target row — under a random salt that was used once and kept nowhere, so identical strings are
identical tokens and no token can be checked against a guess:

| Field | Becomes | Note |
| --- | --- | --- |
| `root` | `/repos/repo-<6hex>` | kept path-shaped, so `--root` scoping still has paths to resolve |
| `target` | `target-<6hex>` | except `.`, which is a structural token rather than a name and stays as it is |
| `err` | `reason-<6hex>` | identical reasons share a token, so failure *grouping* survives redaction |

That is the same standard `sift usage` and `sift report` apply to their own output by
default, on the same reasoning: what makes a usage log private is which repositories and which symbols
were asked about, and none of the numbers depend on either.

**Every `ts` is synthetic.** The capture's first UTC day is `2000-01-01`, and each later day keeps its
distance from the first, so the log spans 29 days with calls in them over 31 in all, and each day holds
the calls it held. Within a day, its *n* calls are spread evenly in their logged order — the *k*-th
(counting from 0) at `(2k + 1) × 86400 / 2n` seconds past midnight, rounded down — so the time of day
carries no rhythm and no time zone. What the tests read off `ts` is the day it names — the onset
the report prints is the first day a measured call falls on, `2000-01-22` — and nothing they read
depends on the interval between two calls.

## What it measures

These are the figures `UsageSavingsFixtureTests` pins. They were derived from the raw log before any of
the splitting code was written — which is the point of recording them here, since an aggregation tuned
until its own output looked right would prove nothing.

| | calls | source | served | outcome |
| --- | ---: | ---: | ---: | --- |
| compressed | 756 | 11,388,058 | 2,563,367 | 8,824,691 saved (77.49%) |
| served source | 237 | 516,898 | 603,401 | 86,503 **more** than the source itself (116.7%) |
| measured | 993 | 11,904,956 | 3,166,768 | 8,738,188 saved (73.40%) |

Alongside them: 4,230 `digest` calls in all, of which **3,237 recorded no bytes** (45 of those
failed); 2,448 calls to `where`, `search`, `strings` and `exemplar`, of which **none** recorded what it
served — the capture predates that field reaching them, which is exactly the compatibility case
the fixture is here to hold still.

# Codex shell payloads — where they came from

`codex-shell-payloads.json` holds two **real** `PostToolUse` payloads Codex CLI 0.159.2 handed a hook for a
shell call, captured by a hook that wrote its stdin to a file: `codex exec -s workspace-write
--dangerously-bypass-hook-trust` under a scratch `CODEX_HOME`, with the model replaced by a local stand-in for
the Responses API that answered with one `exec_command` call. Codex, its sandbox, its shell and its hook payload
are the real ones; only the model's choice of command was scripted, which is why `tool_use_id` reads
`call_probe_1` (a real model's id format is unconfirmed, so nothing reads it as more than an opaque key).

- `lookup`: `sift digest Sources/App/Depot.swift` in a repository whose `Depot.swift` is the six-line struct
  the test writes. The CLI's own line for the same call, run where it could write its log, recorded
  `outBytes` 641 and `srcBytes` 93, which is what the test holds the hook to.
- `truncated`: `sift search kind:func` over 300 placeholder functions, whose output Codex cut under its
  `Warning: truncated output` header.

**What was changed:** `cwd` became `/Users/someone/project` and the home in `transcript_path`
`/Users/someone/.codex`, as in the Cursor fixture; the command named the branch's built binary by its path,
which became `sift`; and each `tool_response` is stored as its lines, which the test joins with `\n` back into
the one string Codex sent, so the name gate reads the output rather than JSON's newline escapes. Every other
field and every byte of each output is as captured.
