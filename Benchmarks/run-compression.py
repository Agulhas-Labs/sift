#!/usr/bin/env python3
"""Measures how much `sift run -- <toolchain command>` compresses build and test output, and whether its answer
keeps every failure the raw output carries (recall) and names nothing the raw output does not (precision).

Deterministic and offline: no model calls. Tokens are estimated as bytes / 4 (no offline tokenizer is assumed).

  capture  runs each case in a scratch clone of this repository: applies the case's injected edits, runs
           `sift run -- <command>`, keeps sift's answer and the raw log sift filed under .sift/runs/ for that
           same run, then restores every touched file byte for byte (checked by hash).
  replay   replays a saved xcodebuild log through sift by a shim executable named `xcodebuild` (sift chooses its
           filter by the executable's name), as a failing log and as a green derivative with the error removed.
  report   reads the captured cases and prints the markdown results table.

  python3 Benchmarks/run-compression.py capture --clone <clone> --out <out> [--case NAME ...]
  python3 Benchmarks/run-compression.py replay --log <xcodebuild.log> --cwd <dir> --out <out>
  python3 Benchmarks/run-compression.py report --out <out>
"""
import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import time

# --- injected edits -------------------------------------------------------------------------------------------------

CORE = "Sources/SiftCore/"
KIND, DIAG, ERR, CHANGED, CENSUS, CRASH = (CORE + n for n in (
    "RunCommandKind.swift", "RunDiagnostic.swift", "RunError.swift", "RunChangedFiles.swift",
    "RunFailureCensus.swift", "RunCompilerCrash.swift"))
CLI_HELP = "Sources/SiftCLI/HelpCommand.swift"
TEST_FILE = "Tests/SiftCoreTests/BenchInjectedTests.swift"

# Each compile-error snippet: (file, lines appended at its end).
E_UNDEFINED = (KIND, ["func benchUndefined() { benchMissingSymbol() }"])
E_MISMATCH = (KIND, ['let benchMismatch: Int = "text"'])
E_MISSING_RETURN = (KIND, ["func benchMissingReturn(_ value: Int) -> Int { if value > 0 { return value } }"])
E_AVAILABILITY = (DIAG, ["@available(macOS 99, *) func benchFuture() {}", "func benchCallsFuture() { benchFuture() }"])
E_CONCURRENCY = (DIAG, ["var benchGlobal = 0"])
E_MACRO = (ERR, ['@freestanding(expression) macro benchMacro() -> Int = '
                 '#externalMacro(module: "BenchNoSuchModule", type: "BenchMacro")',
                 "func benchUsesMacro() -> Int { #benchMacro() }"])
E_POUND_ERROR = (ERR, ['#error("bench injected error")'])
E_UNDEFINED_2 = (CHANGED, ["func benchUndefinedTwo() -> Int { benchMissingValue + 1 }"])
E_MEMBER_MISMATCH = (CHANGED, ["extension RunChangedFiles { var benchBad: String { 42 } }"])
E_CONCURRENCY_2 = (CENSUS, ["var benchGlobalNames = [String]()"])
E_UNDEFINED_3 = (CENSUS, ["func benchUndefinedThree() { BenchNoSuchType.run() }"])
E_MISMATCH_2 = (CRASH, ['let benchMismatchTwo: [Int] = ["a"]'])

# Twelve errors the type checker reports together, all in one file: `swift build` stops at the first file whose
# compile fails, and SIL-stage diagnostics (missing return) are not reached once type checking has failed.
E_ONE_FILE_12 = [(KIND, lines) for lines in (
    E_UNDEFINED[1], E_MISMATCH[1], E_AVAILABILITY[1], E_CONCURRENCY[1], E_MACRO[1], E_UNDEFINED_2[1],
    ["extension RunCommandKind { var benchBad: String { 42 } }"], E_CONCURRENCY_2[1], E_UNDEFINED_3[1],
    E_MISMATCH_2[1], ["func benchArgs() -> [Int] { Array(repeating: 1, cnt: 2) }"],
    ['func benchMember() -> Int { "x".noSuchMember }'])]

W_UNUSED = (KIND, ["func benchWarnUnused() { let benchUnused = 1 }"])
W_NEVER_MUTATED = (DIAG, ["func benchWarnVar() -> Int { var benchNeverMutated = 1; return benchNeverMutated }"])
W_DEPRECATED = (CHANGED, ["@available(*, deprecated, message: \"bench\") func benchOld() {}",
                          "func benchUsesOld() { benchOld() }"])
W_UNUSED_2 = (CENSUS, ["func benchWarnUnusedTwo() { let benchUnusedTwo = 2 }"])
W_UNREACHABLE = (CRASH, ["func benchWarnUnreachable() -> Int { return 1; print(2) }"])

NO_WARNINGS_AS_ERRORS = ("Package.swift", "    .treatAllWarnings(as: .error),\n", "")

L_UNDEFINED_SYMBOL = (CLI_HELP, ['@_silgen_name("sift_bench_missing_symbol") func benchMissingSymbolDecl()',
                                 "func benchLinker() { benchMissingSymbolDecl() }"])

# Test snippets: (kind, body lines). Each becomes a method of the Swift Testing suite or the XCTestCase.
def st_expect(n):
    return ("st", [f"@Test func expectFails{n}() {{ #expect({n} + 1 == 0) }}"])
def st_require(n):
    return ("st", [f"@Test func requireFails{n}() throws {{ let value: Int? = nil; _ = try #require(value) }}"])
def st_throw(n):
    return ("st", [f"@Test func throwsError{n}() throws {{ throw BenchError.injected({n}) }}"])
def st_multi(n):
    return ("st", [f"@Test func twoIssues{n}() {{ #expect({n} == 0); #expect({n} < 0) }}"])
def st_param(n):
    return ("st", [f"@Test(arguments: [1, 2, 3, 4, 5]) func parameterised{n}(value: Int) {{ #expect(value < 2) }}"])
def st_pass(n):
    return ("st", [f"@Test func passes{n}() {{ #expect({n} == {n}) }}"])
def st_trap(n):
    return ("st", [f"@Test func traps{n}() {{ let value: Int? = nil; _ = value! }}"])
def st_hang(n):
    return ("st", [f"@Test(.timeLimit(.minutes(1))) func hangs{n}() async throws "
                   f"{{ try await Task.sleep(for: .seconds(600)) }}"])
def xct_equal(n):
    return ("xct", [f"func testEqualFails{n}() {{ XCTAssertEqual({n}, {n} + 1) }}"])
def xct_throw(n):
    return ("xct", [f"func testThrowsError{n}() throws {{ throw BenchError.injected({n}) }}"])
def xct_true(n):
    return ("xct", [f'func testTrueFails{n}() {{ XCTAssertTrue(false, "bench {n}") }}'])
def xct_pass(n):
    return ("xct", [f"func testPasses{n}() {{ XCTAssertEqual({n}, {n}) }}"])
def xct_trap(n):
    return ("xct", [f"func testTraps{n}() {{ let values: [Int] = []; _ = values[{n}] }}"])


def test_file(snippets):
    lines = ["import Testing", "import XCTest", "", "enum BenchError: Error { case injected(Int) }", "",
             "@Suite struct BenchInjectedTests {"]
    lines += ["    " + l for kind, body in snippets if kind == "st" for l in body]
    lines += ["}", "", "final class BenchInjectedXCTests: XCTestCase {"]
    lines += ["    " + l for kind, body in snippets if kind == "xct" for l in body]
    lines += ["}", ""]
    return "\n".join(lines)


FILTER = ["swift", "test", "--filter", "BenchInjected"]

CASES = {
    # name: (family, command, compile snippets, test snippets or None, expected injected failures)
    "build-noop": ("build-green", ["swift", "build"], [], None),
    # The package sets .treatAllWarnings(as: .error) in its manifest (a -Xswiftc flag does not override it), so the
    # warnings-only case takes that line out of the manifest for its one run.
    "build-warnings-5": ("build-warnings", ["swift", "build"],
                         [NO_WARNINGS_AS_ERRORS, W_UNUSED, W_NEVER_MUTATED, W_DEPRECATED, W_UNUSED_2, W_UNREACHABLE],
                         None),
    "build-warnings-as-errors-5": ("build-errors", ["swift", "build"],
                                   [W_UNUSED, W_NEVER_MUTATED, W_DEPRECATED, W_UNUSED_2, W_UNREACHABLE], None),
    "build-errors-1": ("build-errors", ["swift", "build"], [E_UNDEFINED], None),
    "build-errors-1-missing-return": ("build-errors", ["swift", "build"], [E_MISSING_RETURN], None),
    "build-errors-3": ("build-errors", ["swift", "build"], [E_UNDEFINED, E_MISMATCH, (KIND, E_AVAILABILITY[1])],
                       None),
    "build-errors-12": ("build-errors", ["swift", "build"], E_ONE_FILE_12, None),
    "build-errors-12-spread": ("build-errors", ["swift", "build"],
                        [E_UNDEFINED, E_MISMATCH, E_MISSING_RETURN, E_AVAILABILITY, E_CONCURRENCY, E_MACRO,
                         E_POUND_ERROR, E_UNDEFINED_2, E_MEMBER_MISMATCH, E_CONCURRENCY_2, E_UNDEFINED_3,
                         E_MISMATCH_2], None),
    "build-linker": ("build-errors", ["swift", "build"], [L_UNDEFINED_SYMBOL], None),
    "test-narrow-green": ("test-green", ["swift", "test", "--filter", "RunCommandKindTests"], [], None),
    "test-fail-1": ("test-failures", FILTER, [], [st_expect(1), st_pass(1), xct_pass(1)]),
    "test-fail-5": ("test-failures", FILTER, [],
                    [st_expect(1), st_require(1), st_throw(1), xct_equal(1), xct_throw(1), st_pass(1), xct_pass(1)]),
    "test-fail-20": ("test-failures", FILTER, [],
                     [st_expect(n) for n in range(1, 7)] + [st_require(1), st_require(2)]
                     + [st_throw(n) for n in range(1, 4)] + [st_multi(1), st_param(1)]
                     + [xct_equal(n) for n in range(1, 5)] + [xct_throw(1), xct_throw(2), xct_true(1)]
                     + [st_pass(1), st_pass(2), xct_pass(1)]),
    "test-crash-swift-testing": ("test-crash", FILTER, [], [st_expect(1), st_trap(1), st_pass(1), xct_pass(1)]),
    "test-crash-xctest": ("test-crash", FILTER, [], [xct_equal(1), xct_trap(1), xct_pass(1), st_pass(1)]),
    "test-timeout": ("test-failures", FILTER, [], [st_hang(1), st_pass(1)]),
}


def sha(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return None


def apply_case(clone, snippets, tests):
    """Applies the edits, returns {relative path: original bytes or None} for restore."""
    originals, appended = {}, {}
    for edit in snippets:
        if len(edit) == 3:  # (path, old, new): a replacement, applied once
            path, old, new = edit
            full = os.path.join(clone, path)
            with open(full, "rb") as f:
                originals[path] = f.read()
            text = originals[path].decode()
            assert text.count(old) == 1, f"replacement not unique in {path}"
            with open(full, "w") as f:
                f.write(text.replace(old, new))
            continue
        path, lines = edit
        appended.setdefault(path, []).extend(lines)
    for path, lines in appended.items():
        full = os.path.join(clone, path)
        with open(full, "rb") as f:
            originals[path] = f.read()
        text = originals[path].decode()
        if not text.endswith("\n"):
            text += "\n"
        with open(full, "w") as f:
            f.write(text + "\n".join(lines) + "\n")
    if tests is not None:
        full = os.path.join(clone, TEST_FILE)
        originals[TEST_FILE] = open(full, "rb").read() if os.path.exists(full) else None
        with open(full, "w") as f:
            f.write(test_file(tests))
    return originals


def restore(clone, originals, hashes):
    for path, data in originals.items():
        full = os.path.join(clone, path)
        if data is None:
            os.remove(full)
        else:
            with open(full, "wb") as f:
                f.write(data)
    for path, digest in hashes.items():
        assert sha(os.path.join(clone, path)) == digest, f"restore mismatch: {path}"


def run_sift(argv, cwd, env=None):
    started = time.time()
    proc = subprocess.run(["sift", "run", "--", *argv], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          env=env)
    answer = proc.stdout.decode(errors="replace")
    match = re.search(r"^raw: (\S+)", answer, re.M)
    raw_path = os.path.join(cwd, match.group(1)) if match else None
    return answer, raw_path, proc.returncode, time.time() - started


def save(out, name, family, command, answer, raw_path, code, seconds, extra=None):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, name + ".sift"), "w") as f:
        f.write(answer)
    raw = open(raw_path, errors="replace").read() if raw_path else ""
    with open(os.path.join(out, name + ".raw"), "w") as f:
        f.write(raw)
    meta = {"family": family, "command": " ".join(command), "exit": code, "seconds": round(seconds, 1),
            "raw_log_found": raw_path is not None}
    meta.update(extra or {})
    with open(os.path.join(out, name + ".json"), "w") as f:
        json.dump(meta, f, indent=1)


def capture(args):
    clone = os.path.abspath(args.clone)
    for name in args.case or list(CASES):
        family, command, snippets, tests = CASES[name]
        touched = {e[0] for e in snippets} | ({TEST_FILE} if tests is not None else set())
        hashes = {p: sha(os.path.join(clone, p)) for p in touched}
        originals = apply_case(clone, snippets, tests)
        try:
            answer, raw_path, code, seconds = run_sift(command, clone)
        finally:
            restore(clone, originals, hashes)
        save(args.out, name, family, command, answer, raw_path, code, seconds,
             {"injected": sum(len(e[1]) for e in snippets if len(e) == 2),
              "injected_tests": len([t for t in tests or [] if "pass" not in t[1][0]])})
        print(f"{name}: exit {code}, {seconds:.0f}s, raw {'found' if raw_path else 'MISSING'}")


def replay(args):
    """Replays a saved xcodebuild log, failing and green, through an `xcodebuild` shim."""
    shim_dir = os.path.join(os.path.abspath(args.out), "shim")
    os.makedirs(shim_dir, exist_ok=True)
    shim = os.path.join(shim_dir, "xcodebuild")
    with open(shim, "w") as f:
        f.write('#!/bin/sh\ncat "$BENCH_LOG"\nexit "$BENCH_EXIT"\n')
    os.chmod(shim, 0o755)
    lines = open(args.log, errors="replace").read().splitlines()
    error_at = [i for i, l in enumerate(lines) if ": error: " in l]
    assert len(error_at) == 1, "expected exactly one spliced error"
    i = error_at[0]
    # The error line, its excerpt, caret and note were spliced in; the last four lines are the failure summary.
    green = lines[:i] + lines[i + 4:-4]
    green = [("** BUILD SUCCEEDED **" if l.strip() == "** BUILD FAILED **" else l) for l in green]
    green_log = os.path.join(shim_dir, "green.log")
    with open(green_log, "w") as f:
        f.write("\n".join(green) + "\n")
    for name, log, code in (("xcodebuild-app-error-1", args.log, 65), ("xcodebuild-app-green", green_log, 0)):
        env = dict(os.environ, BENCH_LOG=log, BENCH_EXIT=str(code))
        answer, raw_path, exit_code, seconds = run_sift([shim, "-scheme", "App", "build"], args.cwd, env)
        family = "xcodebuild-green" if code == 0 else "xcodebuild-errors"
        save(args.out, name, family, ["xcodebuild", "-scheme", "App", "build", "(replayed log)"], answer,
             raw_path, exit_code, seconds)
        print(f"{name}: exit {exit_code}, raw {'found' if raw_path else 'MISSING'}")


# --- scoring --------------------------------------------------------------------------------------------------------

LOC = r"(?P<path>[^\s:]+\.swift):(?P<line>\d+)"
COMPILE = re.compile(r"^" + LOC + r":\d+: (?P<sev>error|warning): (?P<msg>.+)$", re.M)
XCT = re.compile(r"^" + LOC + r": error: -\[\S+ (?P<test>\w+)\] : (?P<msg>.+)$", re.M)
ST = re.compile(r"✘ Test (?P<test>\w+)\([^)]*\) recorded an issue(?: with \d+ arguments? (?P<args>.+?))?"
                r" at " + LOC + r":\d+: (?P<msg>.+)$", re.M)
ST_NOLOC = re.compile(r"✘ Test (?P<test>\w+)\([^)]*\) recorded an issue(?: with \d+ arguments? (?P<args>.+?))?: "
                      r"(?P<msg>.+)$", re.M)
LINK = re.compile(r'^\s*"(?P<sym>_\w+)", referenced from:', re.M)
FATAL = re.compile(r"^" + LOC + r": Fatal error: (?P<msg>.+)$", re.M)
SIGNAL = re.compile(r"exited with unexpected signal code (?P<sig>\d+)", re.M)
ST_STARTED = re.compile(r"^◇ Test (?P<test>\w+)\([^)]*\) started\.$", re.M)
XCT_STARTED = re.compile(r"^Test Case '-\[\S+ (?P<test>\w+)\]' started\.$", re.M)


# The driver's own form, for an error it reports before any frontend job runs (`#error`).
DRIVER = re.compile(r"^(?P<sev>error|warning): " + LOC + r":\d+ (?P<msg>.+)$", re.M)
ANSI = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;;[^\x1b]*\x1b\\")


def norm(text):
    return ANSI.sub("", text).replace("‘", "'").replace("’", "'").replace("`", "'")


def truth(raw, family):
    """The failures (or, for a warnings build, warnings) the raw output names, deduplicated."""
    raw = ANSI.sub("", raw)
    items = {}
    sev = "warning" if family == "build-warnings" else "error"
    for m in list(COMPILE.finditer(raw)) + list(DRIVER.finditer(raw)):
        if m.group("sev") == sev and not m.group("msg").startswith("-["):
            key = (os.path.basename(m.group("path")), m.group("line"), m.group("msg"))
            items[key] = {"kind": "diagnostic", "loc": f"{key[0]}:{key[1]}", "msg": m.group("msg")}
    for m in XCT.finditer(raw):
        key = ("xct", m.group("test"), m.group("line"))
        items[key] = {"kind": "xctest", "loc": f"{os.path.basename(m.group('path'))}:{m.group('line')}",
                      "test": m.group("test"), "msg": m.group("msg")}
    for m in ST.finditer(raw):
        key = ("st", m.group("test"), m.group("args"), m.group("line"), m.group("msg"))
        items[key] = {"kind": "swift-testing", "loc": f"{os.path.basename(m.group('path'))}:{m.group('line')}",
                      "test": m.group("test"), "args": m.group("args"), "msg": m.group("msg")}
    for m in ST_NOLOC.finditer(raw):
        if re.search(r" at [^\s:]+\.swift:\d+:\d+: ", m.group(0)):  # has a location: ST already took it
            continue
        key = ("st", m.group("test"), m.group("args"), m.group("msg"))
        items[key] = {"kind": "swift-testing", "loc": None, "test": m.group("test"), "args": m.group("args"),
                      "msg": m.group("msg")}
    for m in LINK.finditer(raw):
        items[("link", m.group("sym"))] = {"kind": "link", "loc": None, "msg": m.group("sym")}
    for m in FATAL.finditer(raw):
        items[("fatal", m.group("line"))] = {"kind": "crash", "loc": f"{os.path.basename(m.group('path'))}:"
                                                                     f"{m.group('line')}", "msg": m.group("msg")}
    for m in SIGNAL.finditer(raw):
        items[("signal", m.group("sig"))] = {"kind": "crash", "loc": None, "msg": f"signal code {m.group('sig')}"}
    if any(k[0] in ("fatal", "signal") for k in items):
        # The test that was running when the process died: started, and never passed or failed.
        for m in ST_STARTED.finditer(raw):
            if not re.search(r"^[✔✘] Test " + m.group("test") + r"\(", raw, re.M):
                items[("running", m.group("test"))] = {"kind": "crashed test", "loc": None, "test": m.group("test"),
                                                       "msg": m.group("test")}
        for m in XCT_STARTED.finditer(raw):
            if not re.search(r"^Test Case '-\[\S+ " + m.group("test") + r"\]' (passed|failed)", raw, re.M):
                items[("running", m.group("test"))] = {"kind": "crashed test", "loc": None, "test": m.group("test"),
                                                       "msg": m.group("test")}
    return list(items.values())


def essential(msg):
    """The part of a message an answer must keep: its first 40 characters, quotes normalised."""
    return norm(msg).strip()[:40]


def found(item, answer):
    """'full' when the answer names the location (and test, arguments) and the message essentials;
    'located' when it names where but not what; '' when it names neither."""
    text = norm(answer)
    where = item["loc"] is None or item["loc"] in text
    who = "test" not in item or item["test"] in text
    args = not item.get("args") or norm(item["args"]) in text
    what = essential(item["msg"]) in text
    if where and who and args and what:
        return "full"
    if where and who and args:
        return "located"
    return ""


SIFT_WORDS = {"swift", "build", "test", "xcodebuild", "sift", "run"}


def invented(answer, raw):
    """Locations and called names in the answer that the raw output never mentions."""
    raw_n = norm(raw)
    body = "\n".join(l for l in answer.splitlines() if not l.startswith("raw: "))
    out = []
    for m in re.finditer(LOC, body):
        loc = f"{os.path.basename(m.group('path'))}:{m.group('line')}"
        if loc not in raw_n:
            out.append(loc)
    for m in re.finditer(r"\b([A-Za-z_]\w{3,})\(", norm(body)):
        if m.group(1) not in raw_n and m.group(1) not in SIFT_WORDS:
            out.append(m.group(1) + "(")
    return sorted(set(out))


def size(text):
    return len(text.encode()), len(text.splitlines())


def pct(saved, total):
    return f"{100 * (1 - saved / total):.0f}%" if total else "n/a"


def redact(text, pairs):
    for pair in pairs or []:
        old, new = pair.split("=", 1)
        text = re.sub(re.escape(old), new, text, flags=re.I)
    return text


def report(args):
    rows = []
    for name in sorted(f[:-5] for f in os.listdir(args.out) if f.endswith(".json")):
        meta = json.load(open(os.path.join(args.out, name + ".json")))
        raw = open(os.path.join(args.out, name + ".raw"), errors="replace").read()
        answer = open(os.path.join(args.out, name + ".sift"), errors="replace").read()
        tail = "\n".join(raw.splitlines()[-50:]) + "\n"
        grep = "".join(l + "\n" for l in raw.splitlines() if "error:" in l)
        items = truth(raw, meta["family"])
        def recall(text):
            got = [found(i, text) for i in items]
            return got.count("full"), got.count("located"), len(items)
        rows.append({"name": name, "meta": meta, "raw": size(raw), "sift": size(answer), "tail": size(tail),
                     "grep": size(grep), "recall": recall(answer), "tail_recall": recall(tail),
                     "grep_recall": recall(grep), "invented": invented(answer, raw),
                     "missed": [i for i in items if found(i, answer) != "full"], "answer": answer})
    if args.json:
        json.dump(rows, sys.stdout, indent=1, default=str)
        return
    print("| case | family | exit | raw lines / bytes / ~tok | sift lines / bytes / ~tok | byte reduction "
          "| sift recall (full+located/n) | invented | tail -50 bytes, recall | grep error: bytes, recall |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        (rb, rl), (sb, sl), (tb, _), (gb, _) = r["raw"], r["sift"], r["tail"], r["grep"]
        rec = lambda c: f"{c[0]}+{c[1]}/{c[2]}" if c[2] else "-"
        print(redact(f"| {r['name']} | {r['meta']['family']} | {r['meta']['exit']} | {rl} / {rb} / {rb // 4} "
              f"| {sl} / {sb} / {sb // 4} | {pct(sb, rb)} | {rec(r['recall'])} "
              f"| {', '.join(r['invented']) or 'none'} | {tb}, {rec(r['tail_recall'])} | {gb}, {rec(r['grep_recall'])} |",
                     args.redact))
    print()
    for r in rows:
        for m in r["missed"]:
            print(redact(f"- {r['name']}: not fully named ({found(m, r['answer']) or 'missing'}): {m}", args.redact))
    print()
    print("| green case | sift bytes | the raw output's own summary lines, bytes | those lines |")
    print("|---|---|---|---|")
    for r in rows:
        if r["meta"]["exit"] != 0:
            continue
        raw = ANSI.sub("", open(os.path.join(args.out, r["name"] + ".raw"), errors="replace").read()).splitlines()
        own = [l for l in raw if re.match(r"^[✔✘━] Test run with|^Build complete!|^\*\* BUILD \w+ \*\*", l)]
        executed = [l.strip() for l in raw if re.match(r"^\s+Executed \d+ tests?, with", l)]
        own += executed[-1:]
        shown = " / ".join(re.sub(r"[\d.]+ seconds", "N seconds", l) for l in own)
        print(f"| {r['name']} | {r['sift'][0]} | {sum(len(l.encode()) + 1 for l in own)} | {shown} |")
    families = {}
    for r in rows:
        families.setdefault(r["meta"]["family"], []).append(1 - r["sift"][0] / r["raw"][0] if r["raw"][0] else 0)
    print()
    print("| family | cases | median byte (= ~token) reduction | range |")
    print("|---|---|---|---|")
    for fam, red in sorted(families.items()):
        print(f"| {fam} | {len(red)} | {100 * statistics.median(red):.0f}% "
              f"| {100 * min(red):.0f}% to {100 * max(red):.0f}% |")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--clone", required=True)
    c.add_argument("--out", required=True)
    c.add_argument("--case", action="append")
    r = sub.add_parser("replay")
    r.add_argument("--log", required=True)
    r.add_argument("--cwd", required=True)
    r.add_argument("--out", required=True)
    s = sub.add_parser("report")
    s.add_argument("--out", required=True)
    s.add_argument("--json", action="store_true")
    s.add_argument("--redact", action="append", help="OLD=NEW, applied case-insensitively to printed rows")
    a = p.parse_args()
    {"capture": capture, "replay": replay, "report": report}[a.cmd](a)


if __name__ == "__main__":
    main()
