#!/usr/bin/env python3
"""The paired benchmark's runner and analysis. Benchmarks/README.md is the method; run.sh and analyse.sh
are the entry points.

Every path the harness writes outside Benchmarks/results/ is under the worktree's gitignored
.build/bench/ or, for the corpus and the template it is cloned from, under this checkout's own directory in
~/Library/Caches/sift-bench-run/; the run deletes both when it ends, whichever way it ends."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BENCH = Path(__file__).resolve().parent
REPO = BENCH.parent
WORK = REPO / ".build" / "bench"
# The corpus sits outside every directory sift's hook treats as build output (.build, DerivedData, checkouts,
# /tmp), or the hook judges every file in it outside the sources and arm B runs with it inert. One fixed
# directory per checkout, so two checkouts can run at once and an index store built at the run path is used
# from the same path. The template sits beside it: the rename that makes it and the clone that copies it
# both need the corpus's volume.
RUN_HOME = (Path.home() / "Library" / "Caches" / "sift-bench-run"
            / hashlib.sha1(str(REPO).encode()).hexdigest()[:8])
RUN = RUN_HOME / "corpus"
TEMPLATE = RUN_HOME / "template"
# The corpus's index store, where a tasks file asks for one (`corpus.index_build`): built once at the run path,
# kept here, beside the run's corpus rather than in it, and shared read-only by every arm B run.
DERIVED = WORK / "derived"
STORE = WORK / "index-store"
SCRATCH_HOME = WORK / "home"
WRAPPER_DIR = WORK / "bin"
WRAPPER = WRAPPER_DIR / "sift"
RESULTS = BENCH / "results"
# Claude Code keeps per-project state (an auto-memory directory) under the real configuration directory
# even without session persistence. It is the run path's, so it is deleted after every run: one run
# cannot leave memory for the next, and nothing is left behind.
PROJECT_STATE = Path.home() / ".claude" / "projects" / re.sub(r"[/.]", "-", str(RUN))

# Ignored in every run's corpus (.git/info/exclude): arm B's settings, rule and index, and build products.
TOOL_DEBRIS = [".claude/", ".sift/", ".sift.json", ".build/", ".swiftpm/", "DerivedData/", "xcuserdata/"]

MODEL = "claude-sonnet-5-5"
TOOLS = "Bash,Read,Edit,Write,Grep,Glob"
ARMS = ("A", "B")

# List-price multiples of the base input price.
WEIGHT_UNCACHED = 1.0
WEIGHT_WRITE_5M = 1.25
WEIGHT_WRITE_1H = 2.0
WEIGHT_READ = 0.1
WEIGHT_OUTPUT = 5.0

# The pgid of the child running now, so an interrupt can stop it and everything it started.
CURRENT_GROUP = None


class Halt(Exception):
    """A fault in the harness or the machine, never in an arm: it stops the run."""


# Environment

def stripped_path(path: str) -> str:
    """PATH with every directory that holds a sift executable removed."""
    kept = []
    for entry in path.split(os.pathsep):
        if entry and not os.access(os.path.join(entry, "sift"), os.X_OK):
            kept.append(entry)
    return os.pathsep.join(kept)


def clean_env(path: str) -> dict:
    """The only variables a run inherits: none of the calling session's Claude Code or sift state."""
    env = {"PATH": path}
    for name in ("HOME", "USER", "LOGNAME", "SHELL", "LANG", "TERM", "TMPDIR"):
        if name in os.environ:
            env[name] = os.environ[name]
    return env


def limited(command, seconds, cwd, env, stdin=None, stdout=None, stderr=None):
    """Runs `command` in its own process group under a wall-clock alarm (macOS has no `timeout`), then
    kills whatever of the group is left, so nothing a run started outlives it into the next one at the
    same path. Returns (exit code, timed out)."""
    global CURRENT_GROUP
    wrapped = ["perl", "-e", "setpgrp(0,0); alarm shift; exec @ARGV", str(seconds)] + [str(c) for c in command]
    process = subprocess.Popen(wrapped, cwd=str(cwd), env=env, stdin=stdin, stdout=stdout, stderr=stderr)
    CURRENT_GROUP = process.pid
    try:
        code = process.wait()
    finally:
        kill_group(process.pid)
        CURRENT_GROUP = None
    return code, code == -signal.SIGALRM


def kill_group(group):
    try:
        os.killpg(group, signal.SIGKILL)
    except Exception:  # the group is already gone
        pass


def checked(command, **kwargs):
    result = subprocess.run([str(c) for c in command], capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise Halt("failed: %s\n%s%s" % (" ".join(map(str, command)), result.stdout, result.stderr))
    return result.stdout


# Tasks and the corpus

DEFAULT_TASKS = BENCH / "tasks.json"
# The v1 corpus build: a tasks file that names no `warm` key gets it, so tasks.json runs as it always did.
DEFAULT_WARM = ["swift", "build", "--build-tests"]


def sha256(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def load_tasks(path=None) -> dict:
    """A tasks file: tasks.json (the v1 corpus, this repository) or one passed with --tasks. A file
    describing a private corpus lives outside the repository, so that the names it uses never enter this
    tree, and its task ids are generic: they are all that a published table shows."""
    path = Path(path or DEFAULT_TASKS).expanduser().resolve()
    with open(path) as handle:
        tasks = json.load(handle)
    tasks["_path"] = path
    for task in tasks["tasks"]:
        if not re.match(r"^[a-z0-9-]+$", task["id"]):
            raise Halt("task id %r is not a generic lower-case slug" % task["id"])
    return tasks


def corpus_source(tasks: dict, override=None):
    """(repository, full commit, paths) for the corpus: `--corpus <path>@<commit>` over the tasks file's
    own `corpus`, whose repository "this repository" (or none) is this one."""
    spec = tasks["corpus"]
    if override:
        repository, _, commit = override.rpartition("@")
        if not repository or not commit:
            raise Halt("--corpus takes <path>@<commit>")
    else:
        repository = spec.get("repository") or "this repository"
        commit = spec["commit"]
    repository = REPO if repository == "this repository" else Path(repository).expanduser().resolve()
    full = checked(["git", "-C", repository, "rev-parse", "--verify", commit + "^{commit}"]).strip()
    return repository, full, list(spec.get("paths") or [])


def write_corpus(repository: Path, commit: str, paths: list, destination: Path):
    destination.mkdir(parents=True)
    archive = subprocess.Popen(["git", "-C", str(repository), "archive", "--format=tar", commit] + paths,
                               stdout=subprocess.PIPE)
    untar = subprocess.run(["tar", "-x", "-C", str(destination)], stdin=archive.stdout)
    archive.stdout.close()
    if archive.wait() != 0 or untar.returncode != 0:
        raise Halt("could not write the corpus at %s" % commit)


def write_tree(tasks: dict, source):
    """The archived corpus at the run path, with the extra files the tasks file names (`add_files`,
    relative to the tasks file) copied in."""
    repository, commit, paths = source
    write_corpus(repository, commit, paths, RUN)
    for destination, origin in (tasks["corpus"].get("add_files") or {}).items():
        target = RUN / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(tasks["_path"]).parent / origin, target)


def build_index_store(command: list, tasks: dict, source, env: dict, log: Path) -> dict:
    """The corpus's index store, built at the fixed run path (a store records absolute source paths) with
    its DerivedData outside the corpus, at BENCH_DERIVED_DATA. Only the store is kept, at STORE; the rest of
    the DerivedData goes, and the corpus is written afresh from the archive, so nothing the build generated
    or touched in the tree reaches either arm. The archive's files carry the commit's time, older than every
    unit, so the store reads as fresh."""
    print("building the corpus's index store (%s); log: %s" % (" ".join(command), log), flush=True)
    started = time.time()
    with open(log, "w") as out:
        code, timed_out = limited(command, 3600, RUN, dict(env, BENCH_DERIVED_DATA=str(DERIVED)), stdout=out,
                                  stderr=subprocess.STDOUT)
    store = DERIVED / "Index.noindex" / "DataStore"
    if code != 0 or not store.is_dir():
        raise Halt("the index build failed (exit %s%s); see %s" % (code, ", timed out" if timed_out else "", log))
    store.rename(STORE)
    shutil.rmtree(DERIVED)
    shutil.rmtree(RUN)
    write_tree(tasks, source)
    size = sum(f.stat().st_size for f in STORE.rglob("*") if f.is_file())
    return {"index_store_bytes": size, "index_build_seconds": round(time.time() - started, 1)}


def materialise(tasks: dict, source, env: dict, log: Path) -> dict:
    """The corpus once, indexed and built warm at the fixed run path (where the tasks file asks) and then
    moved aside as the template every run is cloned from, so the build's absolute paths hold in every
    clone. Returns what the session records about the index store."""
    write_tree(tasks, source)
    indexed = {"corpus_indexed": False}
    index_build = tasks["corpus"].get("index_build")
    if index_build:
        indexed = dict(corpus_indexed=True, **build_index_store(index_build, tasks, source, env,
                                                                 log.with_name("index.log")))
    warm = tasks["corpus"].get("warm", DEFAULT_WARM)
    if warm:
        print("warming the corpus build (%s); log: %s" % (" ".join(warm), log), flush=True)
        with open(log, "w") as out:
            code, timed_out = limited(warm, 3600, RUN, env, stdout=out, stderr=subprocess.STDOUT)
        if code != 0:
            raise Halt("the warm build failed (exit %s%s); see %s" % (code, ", timed out" if timed_out else "", log))
    RUN.rename(TEMPLATE)
    return indexed


def inject(task: dict):
    spec = task.get("inject")
    if not spec:
        return
    path = RUN / spec["file"]
    text = path.read_text()
    found = text.count(spec["find"])
    if found != 1:
        raise Halt("%s: the injection's find text matches %d times in %s, not once" % (task["id"], found, spec["file"]))
    path.write_text(text.replace(spec["find"], spec["replace"]))


def commit_corpus(env: dict):
    """A fresh one-commit repository, so no history hints at the injection. No hooks, signing or template.
    The dates are fixed, so every run's commit — which Claude Code puts in its context — is the same."""
    git = ["git", "-C", str(RUN)]
    fixed = dict(env, GIT_AUTHOR_DATE="2026-01-01T00:00:00Z", GIT_COMMITTER_DATE="2026-01-01T00:00:00Z")
    checked(git + ["init", "-q", "--template="], env=env)
    # What arm B's install and index, or a build either arm tries, leave in the tree is not a change to the
    # corpus: a corpus archived without its own .gitignore would otherwise fail every "no other file changed"
    # check in arm B alone.
    (RUN / ".git" / "info").mkdir(parents=True, exist_ok=True)
    (RUN / ".git" / "info" / "exclude").write_text("\n".join(TOOL_DEBRIS) + "\n")
    checked(git + ["add", "-A"], env=env)
    checked(git + ["-c", "user.name=bench", "-c", "user.email=bench@example.invalid", "-c", "commit.gpgsign=false",
                   "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "corpus"], env=fixed)


def write_wrapper(sift_binary: str):
    """The arm B sift: the real binary with its home redirected, so its logs, ledgers and roots registry
    never touch the user's own."""
    WRAPPER_DIR.mkdir(parents=True, exist_ok=True)
    lines = ["#!/bin/sh",
             "CFFIXED_USER_HOME=" + shlex.quote(str(SCRATCH_HOME)),
             "export CFFIXED_USER_HOME",
             "exec %s \"$@\"" % shlex.quote(sift_binary)]
    WRAPPER.write_text("\n".join(lines) + "\n")
    WRAPPER.chmod(0o755)


def install_sift(env: dict, sift_binary: str, rule: Path):
    """sift at project scope inside the corpus, as `sift install-hook` writes it, plus `rule` as the rule:
    arm B's install, and arm A's too when --rule-a is given.

    install-hook's --command repoints only the primer: every other hook and the status line name the
    binary the install ran as, which the wrapper's exec makes the real one. Those are repointed at the
    wrapper here, and every command is then asserted to be the wrapper's, so no hook can run with the
    user's own home."""
    SCRATCH_HOME.mkdir(parents=True)
    settings = RUN / ".claude" / "settings.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    checked([WRAPPER, "install-hook", "--settings", settings, "--command", "%s session-start" % WRAPPER,
             "--no-allow-run"], env=env, cwd=str(RUN), stdin=subprocess.DEVNULL)
    registered = json.loads(settings.read_text())
    commands = []

    def repoint(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "command" and isinstance(value, str):
                    word, _, rest = value.partition(" ")
                    if word.strip("'\"") == sift_binary:
                        value = "%s %s" % (WRAPPER, rest) if rest else str(WRAPPER)
                    node[key] = value
                    commands.append(value)
                else:
                    repoint(value)
        elif isinstance(node, list):
            for item in node:
                repoint(item)

    repoint(registered)
    strays = [c for c in commands if not c.startswith(str(WRAPPER) + " ")]
    if not commands or strays:
        raise Halt("arm B's settings register commands that are not the wrapper's: %s" % strays)
    settings.write_text(json.dumps(registered, indent=2) + "\n")
    rules = RUN / ".claude" / "rules"
    rules.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(rule, rules / "sift.md")


def rule_source(sift_binary: str) -> Path:
    """The Sift.md arm B installs: the one shipped beside the binary under test, where `sift install`
    finds it (beside it, or ../share/sift/), else this checkout's. Not the corpus's: a corpus other than
    sift's own has none."""
    directory = Path(sift_binary).resolve().parent
    for candidate in (directory / "Sift.md", directory.parent / "share" / "sift" / "Sift.md", REPO / "Sift.md"):
        if candidate.is_file():
            return candidate
    raise Halt("no Sift.md beside %s or in %s" % (sift_binary, REPO))


def rule_file(path: str) -> Path:
    resolved = Path(path).expanduser().resolve()
    if not resolved.is_file():
        raise Halt("no rule file at %s" % path)
    return resolved


def rule_record(rule_a, rule_b: Path) -> dict:
    """The session's record of the rules: arm B's alone, or with --rule-a, both arms' (a rule-vs-rule
    session, which is how every reader of the session tells the mode)."""
    if rule_a is None:
        return {"rule_file": str(rule_b), "rule_sha256": sha256(rule_b)}
    return {"rule_a_file": str(rule_a), "rule_a_sha256": sha256(rule_a),
            "rule_b_file": str(rule_b), "rule_b_sha256": sha256(rule_b)}


def session_record(directory: Path) -> dict:
    session = directory / "session.json"
    return json.loads(session.read_text()) if session.exists() else {}


def sift_on_a(record: dict) -> bool:
    """Whether a session's arm A runs sift: a rule-vs-rule or a mod-vs-no-mod session."""
    return "rule_a_sha256" in record or "mod_name" in record


def mod_dir(path: str) -> Path:
    resolved = Path(path).expanduser().resolve()
    if not (resolved / ".claude-plugin" / "plugin.json").is_file():
        raise Halt("no Claude Code plugin at %s: no .claude-plugin/plugin.json" % path)
    return resolved


def mod_generated(relative: str) -> bool:
    """What Claude Code writes into a --plugin-dir folder each time it loads it, so not part of the mod."""
    return relative == "tsconfig.json" or relative.startswith(".claude-plugin/types/")


def mod_variable(entry: str) -> tuple:
    """One --mod-env entry, NAME=VALUE, as the pair arm B's environment takes."""
    name, sep, value = entry.partition("=")
    if not sep or not name or not name.replace("_", "").isalnum():
        raise Halt("--mod-env takes NAME=VALUE, got %r" % entry)
    return name, value


def mod_record(directory: Path) -> dict:
    """The session's record of the mod arm B loads (a mod-vs-no-mod session): the name the init event's plugin
    list carries, the commit of the repository tracking it (none if untracked), a sha256 over its files (each
    relative path, length and content, in path order), and the SIFT_MOD each arm runs with."""
    try:
        name = json.loads((directory / ".claude-plugin" / "plugin.json").read_text()).get("name")
    except Exception as error:  # not JSON
        raise Halt("%s/.claude-plugin/plugin.json: %s" % (directory, error))
    if not name:
        raise Halt("%s/.claude-plugin/plugin.json names no plugin" % directory)
    digest = hashlib.sha256()
    for path in sorted(p for p in directory.rglob("*") if p.is_file()):
        relative = path.relative_to(directory).as_posix()
        if not mod_generated(relative):
            content = path.read_bytes()
            digest.update(b"%s\0%d\0" % (relative.encode(), len(content)) + content)
    git = ["git", "-C", str(directory)]
    tracked = subprocess.run(git + ["ls-files", "--error-unmatch", ".claude-plugin/plugin.json"], capture_output=True)
    commit = checked(git + ["rev-parse", "HEAD"]).strip() if tracked.returncode == 0 else None
    return {"mode": "mod", "mod_dir": str(directory), "mod_name": name, "mod_commit": commit,
            "mod_files_sha256": digest.hexdigest(), "sift_mod_env": {"A": "off", "B": None}}


def memory_excludes() -> list:
    """Every agent-instruction file Claude Code could load: the user's, every ancestor's of the run
    directory, and the corpus's own (which describe sift). The corpus's .claude/rules is not excluded:
    the corpus tracks none, so the only rule there is the one arm B installs."""
    patterns = [str(Path.home() / ".claude") + "/**"]
    for ancestor in RUN.parents:
        base = str(ancestor).rstrip("/")
        for name in ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".claude/CLAUDE.md", ".claude/rules/**"):
            patterns.append(base + "/" + name)
    corpus = str(RUN)
    for name in ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".claude/CLAUDE.md", "**/CLAUDE.md",
                 "**/CLAUDE.local.md", "**/AGENTS.md"):
        patterns.append(corpus + "/" + name)
    return patterns


def mcp_config(sift_on: bool) -> dict:
    if not sift_on:
        return {"mcpServers": {}}
    return {"mcpServers": {"sift": {"type": "stdio", "command": str(WRAPPER), "args": ["mcp"], "env": {}}}}


# Reading a run's stream

def read_stream(path: Path) -> list:
    messages = []
    with open(path, errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                messages.append(json.loads(line))
            except Exception:  # not JSON
                continue
    return messages


COMMAND_PREFIXES = {"env", "exec", "command", "time", "nohup", "sudo", "xargs"}
COMMAND_SEPARATORS = r"\|\||&&|[;|&\n(`]|\$\("
GREP_COMMANDS = {"grep", "egrep", "fgrep", "rg", "ugrep", "ag", "ack"}


def invokes_sift(command: str) -> bool:
    """Whether a shell command runs sift as a command word: `sift`, a path ending /sift, or `swift run
    sift`. A word `sift` anywhere else (an argument to grep, say) is not an invocation."""
    for segment in re.split(COMMAND_SEPARATORS, command):
        try:
            words = shlex.split(segment)
        except Exception:  # unbalanced quotes once the segment is cut out
            words = segment.split()
        while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] in COMMAND_PREFIXES):
            words = words[1:]
        if not words:
            continue
        if os.path.basename(words[0]) == "sift":
            return True
        if os.path.basename(words[0]) == "swift" and "run" in words[1:2] and "sift" in words:
            return True
    return False


def native_swift_lookup(block: dict) -> bool:
    """A Swift lookup made with a built-in tool rather than sift: a Read of a .swift file, a Grep whose path,
    glob or type names swift, or a grep-family command in Bash whose segment names swift. A search that
    covers Swift files without naming swift is not counted, so this undercounts."""
    name, args = block.get("name"), block.get("input") or {}
    if name == "Read":
        return str(args.get("file_path", "")).endswith(".swift")
    if name == "Grep":
        return any("swift" in str(args.get(key, "")).lower() for key in ("path", "glob", "type"))
    if name == "Bash":
        for segment in re.split(COMMAND_SEPARATORS, str(args.get("command", ""))):
            words = segment.split()
            grep = words[:1] and os.path.basename(words[0]) in GREP_COMMANDS or words[:2] == ["git", "grep"]
            if grep and "swift" in segment.lower():
                return True
    return False


# The events install-hook registers. The stream names a hook's event, never its command, so a hook is
# attributed to sift by its event: arm B's only hook source is the project settings, whose every command
# install_sift asserts is the wrapper's, and arm A, run under the same sources, must fire none at all
# (unless it runs sift too, with --rule-a).
SIFT_HOOK_EVENTS = {"SessionStart", "SubagentStart", "PreToolUse", "PostToolUse", "Stop", "SubagentStop"}


def hook_events(messages: list) -> list:
    """One entry per hook that ran: its start, or for a stream with no starts, any hook message."""
    hooks = [m for m in messages if m.get("type") == "system" and "hook" in str(m.get("subtype", ""))]
    started = [m for m in hooks if m.get("subtype") == "hook_started"]
    return started or hooks


def hook_event_name(message: dict) -> str:
    for key in ("hook_event", "hook_event_name", "event"):
        if message.get(key):
            return str(message[key])
    return "unknown"


def session_price(context_series: list, output_tokens: int):
    """Input-token equivalents for one fresh session; no cache carried in from other runs. Everything is
    written once at the 5-minute write price, re-read on later turns at the read price, output at five times
    input. None for a run with no context series."""
    if not context_series:
        return None
    price = WEIGHT_WRITE_5M * context_series[0]
    for before, after in zip(context_series, context_series[1:]):
        price += WEIGHT_READ * before + WEIGHT_WRITE_5M * max(after - before, 0)
    return price + WEIGHT_OUTPUT * (output_tokens or 0)


def parse(stream: Path, arm: str, sift_on: bool = False, mod_name=None) -> dict:
    """Tokens, turns, sift use and the arm's validity, from one run's stream-json. Re-runnable on a kept
    stream without another model call. Arm B, and arm A when `sift_on` (a rule-vs-rule or mod-vs-no-mod
    session), is held to the sift-on checks; arm A otherwise to the sift-off ones. With `mod_name` (a
    mod-vs-no-mod session), arm B's init event must list that plugin and arm A's must not, and the sift use
    counts the Swift lookups made with built-in tools."""
    messages = read_stream(stream)
    init = next((m for m in messages if m.get("type") == "system" and m.get("subtype") == "init"), {})
    result = next((m for m in reversed(messages) if m.get("type") == "result"), {})

    usage_by_message = {}
    tool_uses = {}
    # The context each main-model API call carried (uncached + cache read + cache write), in order. The
    # first is the fixed start — system prompt, tools, rules, hook output and the task prompt — so its
    # B minus A is sift's fixed overhead; the series shows what every later turn re-sends.
    context_series = []
    seen_calls = set()
    for message in messages:
        if message.get("type") != "assistant":
            continue
        body = message.get("message", {})
        ident = body.get("id") or id(message)
        usage = body.get("usage") or {}
        if body.get("model") == MODEL and ident not in seen_calls and usage:
            seen_calls.add(ident)
            context_series.append((usage.get("input_tokens", 0) or 0) + (usage.get("cache_read_input_tokens", 0) or 0)
                                  + (usage.get("cache_creation_input_tokens", 0) or 0))
        creation = usage.get("cache_creation") or {}
        seen = usage_by_message.setdefault(ident, {"w5": 0, "w1": 0})
        seen["w5"] = max(seen["w5"], creation.get("ephemeral_5m_input_tokens", 0) or 0)
        seen["w1"] = max(seen["w1"], creation.get("ephemeral_1h_input_tokens", 0) or 0)
        for block in body.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tool_uses[block.get("id") or len(tool_uses)] = block

    totals = {"uncached": 0, "cache_read": 0, "cache_write": 0, "output": 0, "cost_usd": 0.0}
    models = []
    for model, usage in (result.get("modelUsage") or {}).items():
        models.append(model)
        totals["uncached"] += usage.get("inputTokens", 0) or 0
        totals["cache_read"] += usage.get("cacheReadInputTokens", 0) or 0
        totals["cache_write"] += usage.get("cacheCreationInputTokens", 0) or 0
        totals["output"] += usage.get("outputTokens", 0) or 0
        totals["cost_usd"] += usage.get("costUSD", 0.0) or 0.0
    write_5m = sum(v["w5"] for v in usage_by_message.values())
    write_1h = sum(v["w1"] for v in usage_by_message.values())
    # Cache writes the stream does not split (another model's, or a message the stream left out) are
    # weighted as 5-minute writes, and counted so the table can say how many there were.
    unsplit = max(totals["cache_write"] - write_5m - write_1h, 0)
    weighted = (totals["uncached"] * WEIGHT_UNCACHED + (write_5m + unsplit) * WEIGHT_WRITE_5M
                + write_1h * WEIGHT_WRITE_1H + totals["cache_read"] * WEIGHT_READ)

    servers = init.get("mcp_servers") or []
    sift_servers = [s for s in servers if "sift" in str(s.get("name", "")).lower()]
    tools = [str(t) for t in init.get("tools") or []]
    sift_tools = [t for t in tools if "sift" in t.lower()]
    hooks = hook_events(messages)
    hook_counts = {}
    for event in hooks:
        name = hook_event_name(event)
        hook_counts[name] = hook_counts.get(name, 0) + 1
    foreign_hooks = [name for name in hook_counts if name not in SIFT_HOOK_EVENTS]
    mcp_calls = sum(1 for b in tool_uses.values() if "sift" in str(b.get("name", "")).lower())
    bash_sift = sum(1 for b in tool_uses.values()
                    if b.get("name") == "Bash" and invokes_sift(str((b.get("input") or {}).get("command", ""))))

    reasons = []
    if not init:
        reasons.append("no init message")
    if not result:
        reasons.append("no result message")
    if arm == "A" and not sift_on:
        if servers:
            reasons.append("arm A lists MCP servers: %s" % ", ".join(str(s.get("name")) for s in servers))
        if sift_tools:
            reasons.append("arm A lists sift tools")
        if hooks:
            reasons.append("arm A fired hook events: %s" % ", ".join(sorted(hook_counts)))
        if mcp_calls or bash_sift:
            reasons.append("arm A invoked sift (%d MCP, %d Bash)" % (mcp_calls, bash_sift))
    else:
        if not any(s.get("status") == "connected" for s in sift_servers):
            reasons.append("arm %s's sift server is not connected: %s" % (arm, json.dumps(sift_servers)))
        if not sift_tools:
            reasons.append("arm %s lists no sift tools" % arm)
        if not any(name.startswith("SessionStart") for name in hook_counts):
            reasons.append("arm %s fired no SessionStart hook" % arm)
        if foreign_hooks:
            reasons.append("arm %s fired hooks that are not sift's: %s" % (arm, ", ".join(sorted(set(foreign_hooks)))))
    if mod_name:
        loaded = any(isinstance(p, dict) and p.get("name") == mod_name for p in init.get("plugins") or [])
        if arm == "B" and not loaded:
            reasons.append("mod not loaded: the init event lists no plugin %s" % mod_name)
        if arm == "A" and loaded:
            reasons.append("arm A loaded the mod %s" % mod_name)
    if any(t not in TOOLS.split(",") and not t.startswith("mcp__sift__") for t in tools):
        reasons.append("tools outside the allowed set: %s" % ", ".join(t for t in tools if t not in TOOLS.split(",")))

    sift_use = {
        "servers": [{"name": s.get("name"), "status": s.get("status")} for s in servers],
        "tools_listed": len(sift_tools),
        "mcp_calls": mcp_calls,
        "bash_invocations": bash_sift,
        "hook_events": hook_counts,
    }
    if mod_name:
        sift_use["native_swift_lookups"] = sum(1 for b in tool_uses.values() if native_swift_lookup(b))
    return {
        "valid": not reasons,
        "invalid_reasons": reasons,
        "models": models,
        "claude_code_version": init.get("claude_code_version"),
        "tokens": {
            "uncached": totals["uncached"],
            "cache_read": totals["cache_read"],
            "cache_write": totals["cache_write"],
            "cache_write_5m": write_5m,
            "cache_write_1h": write_1h,
            "cache_write_unsplit": unsplit,
            "input_raw": totals["uncached"] + totals["cache_read"] + totals["cache_write"],
            "input_weighted": round(weighted, 1),
            "output": totals["output"],
            "session_price": session_price(context_series, totals["output"]),
            "first_context": context_series[0] if context_series else None,
            "peak_context": max(context_series) if context_series else None,
        },
        "context_series": context_series,
        "cost_usd": result.get("total_cost_usd", totals["cost_usd"]),
        "turns": result.get("num_turns"),
        "duration_ms": result.get("duration_ms"),
        "result_subtype": result.get("subtype"),
        "is_error": result.get("is_error"),
        "final_text": result.get("result") or "",
        "sift_use": sift_use,
        "tool_calls": len(tool_uses),
    }


# Success checks

def answer_value(text: str):
    """The last line starting ANSWER:, emphasis and backticks stripped."""
    value = None
    for line in text.splitlines():
        line = line.replace("*", "").replace("`", "").strip()
        if line.startswith("ANSWER:"):
            value = line[len("ANSWER:"):].strip()
    return value


def unchanged(paths: list, env: dict) -> list:
    if not paths:
        return []
    status = checked(["git", "-C", RUN, "status", "--porcelain", "--untracked-files=all", "--"] + paths, env=env)
    return [line for line in status.splitlines() if line.strip()]


def with_reply_lines(parsed: dict) -> dict:
    """The parse with the final reply as a list of lines, which reads better in a summary than one string
    of escaped newlines."""
    kept = {k: v for k, v in parsed.items() if k != "final_text"}
    kept["final_reply"] = parsed["final_text"].splitlines()
    return kept


def check(task: dict, final_text: str, env: dict, log: Path) -> dict:
    spec = task["check"]
    kind = spec["type"]
    answer = answer_value(final_text)
    changed = unchanged(spec.get("unchanged", []), env)
    outcome = {"answer": answer, "changed": changed, "controls": spec.get("controls", "n/a")}
    if kind == "restored":
        # A fix checked without a build: the injected text is gone, and the file holds the original line
        # or one of the listed equivalent fixes; no file but the injected one changed.
        injected = task["inject"]
        text = (RUN / injected["file"]).read_text()
        fixed = text.count(injected["find"]) == 1 or any(re.search(p, text) for p in spec.get("alternatives", []))
        others = [line for line in unchanged(["."], env) if not line.endswith(injected["file"])]
        ok = fixed and injected["replace"] not in text and not others
        outcome.update(changed=changed + others, success=ok and not changed,
                       detail="restored" if ok else "fixed=%s, injected text %s, other files changed: %s" % (
                           fixed, "still present" if injected["replace"] in text else "gone", others))
        return outcome
    if kind == "tests":
        with open(log, "w") as out:
            code, timed_out = limited(["swift", "test", "--filter", spec["filter"]], 1800, RUN, env,
                                      stdout=out, stderr=subprocess.STDOUT)
        outcome.update(success=code == 0 and not changed, detail="swift test --filter %s: exit %s%s%s" % (
            spec["filter"], code, ", timed out" if timed_out else "", ", files changed" if changed else ""))
        return outcome
    if answer is None:
        outcome.update(success=False, detail="no ANSWER line")
        return outcome
    if kind == "answer_all":
        missing = [p for p in spec["patterns"] if not re.search(p, answer)]
        outcome.update(success=not missing and not changed, detail="missing: %s" % missing if missing else "all patterns")
        return outcome
    if kind == "answer_parts":
        # One answer per sub-question, ` | `-separated, each part checked against its own patterns.
        parts = [p.strip() for p in answer.split("|")]
        right = [i < len(parts) and all(re.search(p, parts[i]) for p in patterns)
                 for i, patterns in enumerate(spec["parts"])]
        outcome.update(success=all(right) and not changed, parts_right=sum(right), parts_total=len(right),
                       detail="parts %d/%d%s" % (sum(right), len(right), ", wrong: %s" % [
                           i + 1 for i, ok in enumerate(right) if not ok] if not all(right) else ""))
        return outcome
    if kind == "answer_set":
        if not isinstance(spec["expected"], list):
            outcome.update(success=None, detail="expected set pending")
            return outcome
        if spec.get("match") == "path":
            # Repository-relative paths, for a corpus whose file names repeat across directories.
            items = {re.sub(r"^(\./|%s/)" % re.escape(str(RUN)), "", i.strip().rstrip(".").strip())
                     for i in re.split(r"[,\n]", answer) if i.strip()}
        else:
            items = {os.path.basename(i.strip().rstrip(".").strip()) for i in re.split(r"[,\n]", answer) if i.strip()}
        got = items - set(spec.get("ignore", []))
        want = set(spec["expected"])
        outcome.update(success=got == want and not changed,
                       detail="exact set" if got == want else "extra %s, missing %s" % (sorted(got - want), sorted(want - got)))
        return outcome
    raise Halt("unknown check type %s" % kind)


# One run

def sanitise(value):
    """Machine paths out of a result: the repository becomes <repo>, the home directory ~."""
    if isinstance(value, str):
        return value.replace(str(REPO), "<repo>").replace(str(Path.home()), "~")
    if isinstance(value, list):
        return [sanitise(v) for v in value]
    if isinstance(value, dict):
        return {k: sanitise(v) for k, v in value.items()}
    return value


def prompt_text(tasks: dict, task: dict) -> str:
    preamble = tasks.get("preamble")
    return (preamble + "\n\n" if preamble else "") + task["prompt"] + "\n\n" + tasks["answer_rule"] + "\n"


def run_one(tasks: dict, task: dict, arm: str, repeat: int, position: int, options, base_path: str, out_dir: Path,
            warmup: bool = False):
    """One run. A warm-up is the same arm and prompt cut to one turn and never scored: it puts the arm's
    fixed prefix in the prompt cache before the task's block, so neither arm's first scored run pays a
    cache write the other's later runs do not."""
    stem = "%s-%s-%s" % (task["id"], arm, "warmup" if warmup else "r%d" % repeat)
    print("[%s] %s" % (datetime.now().strftime("%H:%M:%S"), stem), flush=True)
    env_base = clean_env(base_path)
    shutil.rmtree(RUN, ignore_errors=True)
    shutil.rmtree(SCRATCH_HOME, ignore_errors=True)
    try:
        checked(["cp", "-c", "-Rp", TEMPLATE, RUN])
        inject(task)
        commit_corpus(env_base)
        sift_on = arm == "B" or options.sift_on_a
        arm_path = str(WRAPPER_DIR) + os.pathsep + base_path if sift_on else base_path
        arm_env = clean_env(arm_path)
        if options.mod_b:
            # The mod's off switches are SIFT_MOD=off and a mod-off file in sift's home, which the mod finds
            # through SIFT_HOME, else $HOME/.sift: the user's own. Both arms name the scratch home the wrapper
            # gives sift, fresh each run; only arm A is switched off.
            arm_env["SIFT_HOME"] = str(SCRATCH_HOME / ".sift")
            if arm == "A":
                arm_env["SIFT_MOD"] = "off"
            else:
                arm_env.update(options.mod_env)
        if sift_on:
            install_sift(arm_env, options.sift_binary,
                         options.rule_b if arm == "B" or options.rule_a is None else options.rule_a)
            if STORE.exists():
                (RUN / ".sift.json").write_text(json.dumps({"indexStorePath": str(STORE)}) + "\n")
                # The copy above gives every corpus file a ctime after the build, and sift counts the later
                # of mtime and ctime as a file's change (#464), so the store would read stale. The store was
                # built from this same archive, so its units are moved past the copy.
                for unit in (STORE / "v5" / "units").iterdir():
                    os.utime(unit)
        settings = WORK / "settings.json"
        settings.write_text(json.dumps({"claudeMdExcludes": memory_excludes()}, indent=1))
        mcp = WORK / ("mcp-%s.json" % arm)
        mcp.write_text(json.dumps(mcp_config(sift_on), indent=1))
        prompt = WORK / "prompt.txt"
        prompt.write_text(prompt_text(tasks, task))
        command = [options.claude, "-p", "--model", MODEL, "--output-format", "stream-json", "--verbose",
                   "--include-hook-events", "--setting-sources", "project,local", "--strict-mcp-config",
                   "--mcp-config", mcp, "--settings", settings, "--disable-slash-commands",
                   "--no-session-persistence", "--tools", TOOLS, "--effort", options.effort,
                   "--permission-mode", "bypassPermissions", "--max-budget-usd", str(options.budget)]
        if options.mod_b and arm == "B":
            command += ["--plugin-dir", options.mod_b]
        if warmup:
            command += ["--max-turns", "1"]
        stream = out_dir / (stem + ".stream.jsonl")
        errors = out_dir / (stem + ".stderr.txt")
        started = time.time()
        with open(prompt) as stdin, open(stream, "w") as stdout, open(errors, "w") as stderr:
            code, timed_out = limited(command, options.timeout, RUN, arm_env, stdin=stdin, stdout=stdout, stderr=stderr)
        wall = time.time() - started
        parsed = parse(stream, arm, sift_on, options.mod["mod_name"] if options.mod_b else None)
        if timed_out:
            parsed["valid"] = False
            parsed["invalid_reasons"].append("timed out after %ds" % options.timeout)
        if warmup:
            outcome = {"success": None, "detail": "warm-up, not scored", "answer": None, "changed": [],
                       "controls": "n/a"}
        else:
            outcome = check(task, parsed["final_text"], env_base, out_dir / (stem + ".check.txt"))
    finally:
        shutil.rmtree(RUN, ignore_errors=True)
        shutil.rmtree(SCRATCH_HOME, ignore_errors=True)
        shutil.rmtree(PROJECT_STATE, ignore_errors=True)
    summary = {
        "task": task["id"], "kind": task["kind"], "arm": arm, "repeat": repeat, "position": position,
        "model": MODEL, "effort": options.effort, "sift_version": options.sift_version,
        "started_at": datetime.fromtimestamp(started, timezone.utc).isoformat(),
        "wall_seconds": round(wall, 1), "exit_code": code, "timed_out": timed_out,
        "success": outcome["success"], "check_detail": outcome["detail"], "answer": outcome["answer"],
        "changed_files": outcome["changed"], "controls": outcome["controls"], "warmup": warmup,
    }
    if "parts_right" in outcome:
        summary.update(parts_right=outcome["parts_right"], parts_total=outcome["parts_total"])
    summary.update(with_reply_lines(parsed))
    (out_dir / (stem + ".json")).write_text(json.dumps(sanitise(summary), indent=1) + "\n")
    print("  %s: valid=%s success=%s input_weighted=%s output=%s turns=%s cost=$%.3f wall=%.0fs%s" % (
        stem, summary["valid"], summary["success"], summary["tokens"]["input_weighted"], summary["tokens"]["output"],
        summary["turns"], summary["cost_usd"] or 0, wall,
        "" if summary["valid"] else " (" + "; ".join(summary["invalid_reasons"]) + ")"), flush=True)


def estimate(text) -> dict:
    """Characters and a chars/4 token estimate (an estimate, not a count)."""
    if text is None:
        return None
    return {"chars": len(text), "tokens_est": round(len(text) / 4)}


def fixed_overhead(env: dict, rule: Path) -> dict:
    """Estimates of the fixed start arm B adds, gathered through the wrapper on a clone of the template:
    the MCP tool definitions (tools/list), the session-start primer's output, and the rule. Each is
    chars/4; the measured figure is the B minus A of each run's first-call context. The clone is a run's
    corpus, at the run path and committed, with the store setting arm B adds: sift indexes only inside a git
    repository, so a bare clone would leave the primer silent and the index failing (and a clone inside this
    checkout would measure the checkout)."""
    probe = RUN
    SCRATCH_HOME.mkdir(parents=True, exist_ok=True)
    estimates = {}
    try:
        checked(["cp", "-c", "-Rp", TEMPLATE, probe])
        commit_corpus(env)
        if STORE.exists():
            (probe / ".sift.json").write_text(json.dumps({"indexStorePath": str(STORE)}) + "\n")
        requests = "\n".join(json.dumps(r) for r in [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "bench", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}]) + "\n"
        listed = subprocess.run([WRAPPER, "mcp"], input=requests, capture_output=True, text=True, cwd=str(probe),
                                env=env, timeout=60)
        tools = None
        for line in listed.stdout.splitlines():
            try:
                reply = json.loads(line)
            except Exception:  # not JSON
                continue
            if reply.get("id") == 2:
                tools = json.dumps(reply.get("result", {}).get("tools", []))
        estimates["mcp_tools"] = estimate(tools)
        hook_input = json.dumps({"session_id": "bench-probe", "hook_event_name": "SessionStart", "source": "startup",
                                 "cwd": str(probe)})
        primer = subprocess.run([WRAPPER, "session-start"], input=hook_input, capture_output=True, text=True,
                                cwd=str(probe), env=env, timeout=60)
        estimates["session_start_output"] = estimate(primer.stdout)
        estimates["rule"] = estimate(rule.read_text())
        started = time.time()
        indexed = subprocess.run([WRAPPER, "index"], capture_output=True, text=True, cwd=str(probe), env=env,
                                 timeout=1800)
        estimates["cold_index_seconds"] = round(time.time() - started, 1) if indexed.returncode == 0 else None
    except Exception as error:  # an estimate that cannot be taken is recorded as missing, not fatal
        estimates["error"] = str(error)
    finally:
        shutil.rmtree(probe, ignore_errors=True)
        shutil.rmtree(SCRATCH_HOME, ignore_errors=True)
    return estimates


def probe_hook(base_path: str, sift_binary: str, rule: Path) -> dict:
    """Proof that arm B's hook is live, before any model call: arm B installed in a clone of the template at
    the run path, exactly as a run installs it, and the hook, through the wrapper and its scratch home, fed one
    whole-file Read of the corpus's largest tracked Swift file. The verdict must be an answer in place; any
    other (a corpus the hook judges outside the sources, say) halts the session. The clone, the scratch home
    and the replay's state are gone when it returns."""
    state = WORK / "hook-probe"
    arm_env = clean_env(str(WRAPPER_DIR) + os.pathsep + base_path)
    shutil.rmtree(RUN, ignore_errors=True)
    shutil.rmtree(SCRATCH_HOME, ignore_errors=True)
    try:
        checked(["cp", "-c", "-Rp", TEMPLATE, RUN])
        commit_corpus(clean_env(base_path))
        install_sift(arm_env, sift_binary, rule)
        if STORE.exists():
            (RUN / ".sift.json").write_text(json.dumps({"indexStorePath": str(STORE)}) + "\n")
        tracked = checked(["git", "-C", RUN, "ls-files", "-z", "--", "*.swift"], env=arm_env).split("\0")
        files = [RUN / name for name in tracked if name]
        if not files:
            raise Halt("the hook probe found no tracked Swift file in the corpus")
        largest = max(files, key=lambda f: f.stat().st_size)
        state.mkdir(parents=True)
        payload = json.dumps({"session_id": "bench-hook-probe", "hook_event_name": "PreToolUse", "tool_name": "Read",
                              "tool_input": {"file_path": str(largest)}, "cwd": str(RUN)})
        replay = subprocess.run([str(WRAPPER), "replay-hook", "--state", str(state), "--cwd", str(RUN), "--show"],
                                input=payload, capture_output=True, text=True, cwd=str(RUN), env=arm_env,
                                timeout=600)
        first, _, answer = replay.stdout.partition("\n")
        try:
            verdict = json.loads(first)
        except Exception:  # not JSON: the replay failed
            verdict = {}
        if replay.returncode != 0 or verdict.get("token") != "in-place":
            raise Halt("arm B's hook is inert: a whole-file Read of the corpus's largest Swift file came back "
                       "verdict %s, rule %s, not an answer in place (exit %s)\n%s%s" % (
                           verdict.get("token"), verdict.get("rule"), replay.returncode, first, replay.stderr))
        answer = answer.partition("--- answer ---\n")[2]
        return {"hook_live": True, "hook_live_rule": verdict.get("rule"),
                "hook_probe_read_chars": len(largest.read_text(errors="replace")), "hook_probe_answer_chars": len(answer)}
    finally:
        shutil.rmtree(RUN, ignore_errors=True)
        shutil.rmtree(SCRATCH_HOME, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)


def command_run(options):
    if options.mod_b and options.rule_a:
        raise Halt("--mod-b and --rule-a each change arm A; give one, so the arms differ in one thing")
    options.mod_b = mod_dir(options.mod_b) if options.mod_b else None
    options.mod = mod_record(options.mod_b) if options.mod_b else {}
    if options.mod_env and not options.mod_b:
        raise Halt("--mod-env sets arm B's environment for the mod; it needs --mod-b")
    options.mod_env = dict(mod_variable(entry) for entry in options.mod_env)
    if options.mod_b:
        options.mod["sift_mod_env"]["B_extra"] = options.mod_env
    options.sift_on_a = options.rule_a is not None or options.mod_b is not None
    tasks = load_tasks(options.tasks)
    source = corpus_source(tasks, options.corpus)
    selected = [t for t in tasks["tasks"] if not options.task or t["id"] in options.task]
    unknown = set(options.task or []) - {t["id"] for t in tasks["tasks"]}
    if unknown or not selected:
        raise Halt("unknown task: %s" % ", ".join(sorted(unknown)))
    for leftover in (WORK, RUN_HOME, PROJECT_STATE):
        if leftover.exists():
            raise Halt("%s exists: another run is using it, or one was killed; remove it by hand" % leftover)

    sift_binary = options.sift or shutil.which("sift")
    if not sift_binary:
        raise Halt("no sift binary on PATH; pass --sift")
    sift_binary = options.sift_binary = os.path.abspath(sift_binary)
    options.rule_b = rule_file(options.rule_b) if options.rule_b else rule_source(sift_binary)
    options.rule_a = rule_file(options.rule_a) if options.rule_a else None
    options.claude = options.claude or shutil.which("claude")
    if not options.claude:
        raise Halt("no claude binary on PATH; pass --claude")
    base_path = stripped_path(os.environ.get("PATH", ""))
    env = clean_env(base_path)

    status = subprocess.run([options.claude, "auth", "status", "--json"], env=env, capture_output=True, text=True)
    try:
        logged_in = json.loads(status.stdout).get("loggedIn") is True
    except Exception:  # not JSON
        logged_in = False
    if not logged_in:
        raise Halt("claude is not logged in under the run environment:\n%s%s" % (status.stdout, status.stderr))
    options.sift_version = subprocess.run([sift_binary, "--version"], capture_output=True, text=True).stdout.strip()
    claude_version = subprocess.run([options.claude, "--version"], env=env, capture_output=True, text=True).stdout.strip()

    session = options.session or datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = RESULTS / session
    out_dir.mkdir(parents=True, exist_ok=True)
    record = {
        "session": session, "model": MODEL, "effort": options.effort, "repeats": options.repeats,
        "warmups": not options.no_warmup,
        "tasks": [t["id"] for t in selected],
        "tasks_file": str(tasks["_path"]), "tasks_file_sha256": sha256(tasks["_path"]),
        "corpus_label": tasks["corpus"].get("label", "sift"), "corpus_commit": source[1],
        "corpus_paths": source[2],
        "sift_version": options.sift_version, "sift_binary": sift_binary, "sift_binary_sha256": sha256(sift_binary),
        "sift_binary_mtime": datetime.fromtimestamp(os.path.getmtime(sift_binary), timezone.utc).isoformat(),
        **rule_record(options.rule_a, options.rule_b), **options.mod,
        "claude_code_version": claude_version, "timeout_seconds": options.timeout, "budget_usd": options.budget,
    }

    def write_record():
        (out_dir / "session.json").write_text(json.dumps(sanitise(record), indent=1) + "\n")

    write_record()
    try:
        WORK.mkdir(parents=True)
        write_wrapper(sift_binary)
        record.update(materialise(tasks, source, env, WORK / "warm.log"))
        record.update(probe_hook(base_path, sift_binary, options.rule_b))
        write_record()
        record["fixed_overhead_estimates"] = fixed_overhead(clean_env(str(WRAPPER_DIR) + os.pathsep + base_path),
                                                            options.rule_b)
        if options.rule_a:
            record["fixed_overhead_estimates"]["rule_a"] = estimate(options.rule_a.read_text())
        write_record()
        position = 0
        for task in selected:
            index = tasks["tasks"].index(task)
            if not options.no_warmup:
                for arm in (ARMS if index % 2 == 0 else tuple(reversed(ARMS))):
                    run_one(tasks, task, arm, 0, 0, options, base_path, out_dir, warmup=True)
            for repeat in range(1, options.repeats + 1):
                order = ARMS if (index + repeat) % 2 == 0 else tuple(reversed(ARMS))
                for arm in order:
                    position += 1
                    run_one(tasks, task, arm, repeat, position, options, base_path, out_dir)
    finally:
        if CURRENT_GROUP:
            kill_group(CURRENT_GROUP)
        shutil.rmtree(WORK, ignore_errors=True)
        shutil.rmtree(RUN_HOME, ignore_errors=True)
        shutil.rmtree(PROJECT_STATE, ignore_errors=True)
    print()
    print(analyse(out_dir))


# Analysis

DELTA_METRICS = [
    ("session_price", "session price"),
    ("input_weighted", "input, weighted"),
    ("input_raw", "input, raw"),
    ("cache_read", "cache read"),
    ("cache_write", "cache write"),
    ("uncached", "uncached"),
    ("output", "output"),
    ("first_context", "first-call context"),
    ("peak_context", "peak context"),
    ("turns", "turns"),
    ("wall_seconds", "wall s"),
    ("cost_usd", "cost $"),
]


def metric(summary: dict, key: str):
    if key == "session_price":
        return session_price(summary.get("context_series") or [], summary.get("tokens", {}).get("output", 0))
    if key in summary.get("tokens", {}):
        return summary["tokens"][key]
    return summary.get(key)


def spread(values: list, money: bool = False) -> str:
    if not values:
        return "–"
    form = (lambda v: "%+.3f" % v) if money else (lambda v: "%+.0f" % v)
    if len(values) == 1:
        return form(values[0])
    return "%s [%s, %s]" % (form(statistics.median(values)), form(min(values)), form(max(values)))


def plain(values: list, money: bool = False) -> str:
    if not values:
        return "–"
    form = (lambda v: "%.3f" % v) if money else (lambda v: "%.0f" % v)
    return form(statistics.median(values))


BOOTSTRAP_RESAMPLES = 4000


def bootstrap_difference(a: list, b: list) -> tuple:
    """95% interval of mean(b) - mean(a), resampling each arm's runs with replacement (seed 1)."""
    rng = random.Random(1)
    diffs = []
    for _ in range(BOOTSTRAP_RESAMPLES):
        mean_a = sum(rng.choices(a, k=len(a))) / len(a)
        mean_b = sum(rng.choices(b, k=len(b))) / len(b)
        diffs.append(mean_b - mean_a)
    diffs.sort()
    return diffs[int(0.025 * BOOTSTRAP_RESAMPLES)], diffs[int(0.975 * BOOTSTRAP_RESAMPLES) - 1]


def price_means_table(summaries: list, task_ids: list) -> list:
    """Mean session price per arm, per task and pooled, with a bootstrap interval of the difference."""
    lines = ["Mean session price by arm (valid runs with a context series):", "",
             "| task | runs A | runs B | mean A | mean B | B minus A | % | 95% interval of the difference |",
             "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    skipped = 0
    pooled = {arm: [] for arm in ARMS}
    for label, tasks in [(t, [t]) for t in task_ids] + [("**pooled**", task_ids)]:
        prices = {arm: [] for arm in ARMS}
        for s in summaries:
            if s["task"] in tasks and s["valid"]:
                price = metric(s, "session_price")
                if price is None:
                    skipped += label == "**pooled**"
                else:
                    prices[s["arm"]].append(price)
        if not (prices["A"] and prices["B"]):
            lines.append("| %s | %d | %d | – | – | – | – | – |" % (label, len(prices["A"]), len(prices["B"])))
            continue
        mean_a, mean_b = (sum(prices[arm]) / len(prices[arm]) for arm in ARMS)
        low, high = bootstrap_difference(prices["A"], prices["B"])
        verdict = "no detectable difference" if low <= 0 <= high else "B %s" % ("cheaper" if high < 0 else "dearer")
        lines.append("| %s | %d | %d | %.0f | %.0f | %+.0f | %+.1f%% | [%+.0f, %+.0f] %s |" % (
            label, len(prices["A"]), len(prices["B"]), mean_a, mean_b, mean_b - mean_a,
            100 * (mean_b - mean_a) / mean_a if mean_a else 0, low, high, verdict))
    lines += ["", "%d valid run(s) with an empty or missing context series left out of the session price." % skipped]
    return lines


def cache_carried_warnings(summaries: list, task_ids: list) -> list:
    warnings = []
    for task in task_ids:
        for arm in ARMS:
            runs = [s for s in summaries if s["task"] == task and s["arm"] == arm and s["valid"]]
            dry = sum(1 for s in runs if not metric(s, "cache_write"))
            if runs and dry * 2 > len(runs):
                warnings.append("cache carried over between repeats in arm %s of %s: read session price, not "
                                "weighted input" % (arm, task))
    return warnings


def load_summaries(directory: Path) -> list:
    summaries = []
    for path in sorted(directory.glob("*.json")):
        data = json.loads(path.read_text())
        if "task" in data and "arm" in data and not data.get("warmup"):
            summaries.append(data)
    return summaries


def task_order(directory: Path) -> dict:
    """The session's own task order, from its session.json; tasks.json's for a session that predates it."""
    session = directory / "session.json"
    if session.exists():
        names = json.loads(session.read_text()).get("tasks")
        if names:
            return {name: i for i, name in enumerate(names)}
    return {t["id"]: i for i, t in enumerate(load_tasks()["tasks"])}


def analyse(directory: Path) -> str:
    summaries = load_summaries(directory)
    by_key = {(s["task"], s["arm"], s["repeat"]): s for s in summaries}
    task_ids = []
    for s in summaries:
        if s["task"] not in task_ids:
            task_ids.append(s["task"])
    order = task_order(directory)
    task_ids.sort(key=lambda t: order.get(t, len(order)))

    lines = ["# Paired benchmark: %s" % directory.name, "",
             "B minus A per repeat, then the median [min, max] over repeats. Only repeats where both arms ran "
             "valid are paired. Input weighted = uncached + 1.25 x 5-minute write + 2 x 1-hour write + 0.1 x "
             "read. Session price = input-token equivalents for one fresh session; no cache carried in from other "
             "runs (the first context at 1.25, each later turn re-reading the last context at 0.1 and writing "
             "its growth at 1.25, output at 5). Cost is Claude Code's list-price equivalent, not money billed.", ""]
    record = session_record(directory)
    rule_vs_rule = "rule_a_sha256" in record
    mod_vs_none = "mod_name" in record
    if rule_vs_rule:
        lines += ["Rule vs rule: both arms run with sift and differ only in the rule. A: %s (sha256 %s). B: %s "
                  "(sha256 %s)." % (record["rule_a_file"], record["rule_a_sha256"], record["rule_b_file"],
                                    record["rule_b_sha256"]), ""]
    if mod_vs_none:
        lines += ["Mod vs no mod: both arms run with sift under one rule, %s (sha256 %s); arm B also loads the "
                  "Claude Code plugin %s from %s (commit %s, files sha256 %s), and arm A runs without it, with "
                  "SIFT_MOD=off." % (record["rule_file"], record["rule_sha256"], record["mod_name"],
                                     record["mod_dir"], record["mod_commit"] or "none, untracked",
                                     record["mod_files_sha256"]), ""]
        extra = (record.get("sift_mod_env") or {}).get("B_extra") or {}
        if extra:
            lines[-2] += " Arm B's environment also sets %s." % ", ".join("%s=%s" % pair for pair in sorted(extra.items()))
    header = "| task | pairs | success A | success B | invalid | " + " | ".join(label for _, label in DELTA_METRICS) + " |"
    lines += [header, "|" + " --- |" * (5 + len(DELTA_METRICS))]
    totals_by_repeat = {}
    arm_values = {arm: {key: [] for key, _ in DELTA_METRICS} for arm in ARMS}
    for task in task_ids:
        runs = [s for s in summaries if s["task"] == task]
        repeats = sorted({s["repeat"] for s in runs})
        invalid = sum(1 for s in runs if not s["valid"])
        success = {}
        for arm in ARMS:
            counted = [s for s in runs if s["arm"] == arm and s["valid"]]
            known = [s for s in counted if s["success"] is not None]
            success[arm] = "%d/%d" % (sum(1 for s in known if s["success"]), len(counted)) if known or not counted else "pending"
            for s in counted:
                for key, _ in DELTA_METRICS:
                    if metric(s, key) is not None:
                        arm_values[arm][key].append(metric(s, key))
        deltas = {key: [] for key, _ in DELTA_METRICS}
        pairs = 0
        for repeat in repeats:
            a, b = by_key.get((task, "A", repeat)), by_key.get((task, "B", repeat))
            if not (a and b and a["valid"] and b["valid"]):
                continue
            pairs += 1
            bucket = totals_by_repeat.setdefault(repeat, {key: 0.0 for key, _ in DELTA_METRICS})
            for key, _ in DELTA_METRICS:
                delta = (metric(b, key) or 0) - (metric(a, key) or 0)
                deltas[key].append(delta)
                bucket[key] += delta
        cells = [spread(deltas[key], key == "cost_usd") for key, _ in DELTA_METRICS]
        lines.append("| %s | %d | %s | %s | %d | %s |" % (task, pairs, success["A"], success["B"], invalid, " | ".join(cells)))
    total_cells = [spread([t[key] for t in totals_by_repeat.values()], key == "cost_usd") for key, _ in DELTA_METRICS]
    all_success = {}
    for arm in ARMS:
        known = [s for s in summaries if s["arm"] == arm and s["valid"] and s["success"] is not None]
        all_success[arm] = "%d/%d" % (sum(1 for s in known if s["success"]), len(known))
    lines.append("| **total** (summed per repeat) | %d | %s | %s | %d | %s |" % (
        len(totals_by_repeat), all_success["A"], all_success["B"], sum(1 for s in summaries if not s["valid"]),
        " | ".join(total_cells)))

    lines += [""] + price_means_table(summaries, task_ids)
    lines += ["", "Per-run medians by arm (valid runs):", "",
              "| arm | runs | " + " | ".join(label for _, label in DELTA_METRICS) + " |",
              "|" + " --- |" * (2 + len(DELTA_METRICS))]
    for arm in ARMS:
        count = sum(1 for s in summaries if s["arm"] == arm and s["valid"])
        lines.append("| %s | %d | %s |" % (arm, count, " | ".join(plain(arm_values[arm][key], key == "cost_usd") for key, _ in DELTA_METRICS)))
    if mod_vs_none:
        lines += ["", "Voluntary use, summed over valid runs: sift calls against Swift lookups made with built-in tools "
                  "(a Read of a .swift file, a Grep or Bash grep that names swift; a search that never names swift is "
                  "not counted):", "", "| arm | sift MCP | sift Bash | built-in Swift lookups | sift share |",
                  "| --- | --- | --- | --- | --- |"]
        for arm in ARMS:
            uses = [s["sift_use"] for s in summaries if s["arm"] == arm and s["valid"]]
            sift = [sum(u["mcp_calls"] for u in uses), sum(u["bash_invocations"] for u in uses)]
            native = sum(u.get("native_swift_lookups", 0) for u in uses)
            share = "%.0f%%" % (100.0 * sum(sift) / (sum(sift) + native)) if sum(sift) + native else "–"
            lines.append("| %s | %d | %d | %d | %s |" % (arm, sift[0], sift[1], native, share))
    lines += [""] * bool(cache_carried_warnings(summaries, task_ids)) + cache_carried_warnings(summaries, task_ids)
    parts = ["- %s-%s-r%d: %d/%d parts" % (s["task"], s["arm"], s["repeat"], s["parts_right"], s["parts_total"])
             for s in summaries if "parts_total" in s]
    if parts:
        lines += ["", "Sub-questions answered right (chained tasks):", ""] + parts
    overhead = record.get("fixed_overhead_estimates")
    if overhead:
        lines += ["", ("Arm B's sift start, estimated at chars/4 (both arms carry it; the first-call context row "
                       "above measures rule B minus rule A): " if rule_vs_rule else
                       "Arm B's sift start, estimated at chars/4 (both arms carry it; the first-call context row "
                       "above measures what the mod adds): " if mod_vs_none else
                       "Arm B's fixed start, estimated at chars/4 (the measured figure is the first-call context row "
                       "above): ") + ", ".join("%s %s" % (k, v["tokens_est"] if isinstance(v, dict) else v)
                                         for k, v in overhead.items())]
    reasons = ["- %s-%s-r%d: %s" % (s["task"], s["arm"], s["repeat"], "; ".join(s["invalid_reasons"])) for s in summaries if not s["valid"]]
    if reasons:
        lines += ["", "Invalid runs (not counted):", ""] + reasons
    return "\n".join(lines) + "\n"


def command_analyse(options):
    directory = Path(options.session) if options.session else None
    if directory is None or not directory.exists():
        sessions = sorted(p for p in RESULTS.iterdir() if p.is_dir()) if RESULTS.exists() else []
        if options.session:
            directory = RESULTS / options.session
        elif sessions:
            directory = sessions[-1]
        else:
            raise Halt("no result sessions under %s" % RESULTS)
    table = analyse(directory)
    (directory / "table.md").write_text(table)
    print(table)


def command_validate(options):
    """Every task's check against its controls, with no model: an answer check must pass on the recorded
    reference answer and fail on a wrong one (the expected set less one item, or the task's own
    `wrong_answer`); a `restored` check must pass on the clean corpus and fail on the injected one; a
    path set must name files the corpus holds; and arm B's hook must answer a whole-file Read in place at the
    run path. Exit 0 only when every control holds."""
    tasks = load_tasks(options.tasks)
    source = corpus_source(tasks, options.corpus)
    for leftover in (WORK, RUN_HOME):
        if leftover.exists():
            raise Halt("%s exists: another run is using it, or one was killed; remove it by hand" % leftover)
    sift_binary = options.sift or shutil.which("sift")
    if not sift_binary:
        raise Halt("no sift binary on PATH; pass --sift")
    sift_binary = os.path.abspath(sift_binary)
    base_path = stripped_path(os.environ.get("PATH", ""))
    env = clean_env(base_path)
    failures = []
    try:
        WORK.mkdir(parents=True)
        write_wrapper(sift_binary)
        materialise(dict(tasks, corpus=dict(tasks["corpus"], warm=None, index_build=None)), source, env,
                    WORK / "warm.log")
        live = probe_hook(base_path, sift_binary, rule_source(sift_binary))
        print("hook: live (%s; a %d-character Read answered in %d characters)" % (
            live["hook_live_rule"], live["hook_probe_read_chars"], live["hook_probe_answer_chars"]))

        def checked_on(task, text, injected):
            shutil.rmtree(RUN, ignore_errors=True)
            checked(["cp", "-c", "-Rp", TEMPLATE, RUN])
            if injected:
                inject(task)
            commit_corpus(env)
            # What an arm B run leaves behind, planted in every control: a clean control must still pass.
            for debris in (".claude/settings.json", ".sift/index.sqlite", ".sift.json", "Nested/.build/debug.yaml"):
                (RUN / debris).parent.mkdir(parents=True, exist_ok=True)
                (RUN / debris).write_text("debris\n")
            try:
                return check(task, text, env, WORK / "check.txt")
            finally:
                shutil.rmtree(RUN, ignore_errors=True)

        # Every task lacking its controls is named at once, not one run at a time.
        uncontrolled = [task["id"] for task in tasks["tasks"] if task["check"]["type"] == "answer_all"
                        and (task["check"].get("reference_answer") is None or task["check"].get("wrong_answer") is None)]
        if uncontrolled:
            raise Halt("no reference_answer or wrong_answer to validate against: %s" % ", ".join(uncontrolled))
        for task in tasks["tasks"]:
            spec = task["check"]
            kind = spec["type"]
            results = []
            for pin in spec.get("pinned_lines", []):
                # A line number the expected answer states is checked against the corpus, so an edit above it fails here.
                lines = (TEMPLATE / pin["file"]).read_text().splitlines() if (TEMPLATE / pin["file"]).exists() else []
                held = len(lines) >= pin["line"] and pin["contains"] in lines[pin["line"] - 1]
                results.append(("pinned %s:%d holds %r" % (pin["file"], pin["line"], pin["contains"]), held))
            if kind == "tests":
                print("%s: tests check, not validated here (controls: %s)" % (task["id"], spec.get("controls")))
                continue
            if kind == "restored":
                results.append(("clean passes", checked_on(task, "", False)["success"] is True))
                results.append(("injected fails", checked_on(task, "", True)["success"] is False))
            else:
                reference = spec.get("reference_answer")
                wrong = spec.get("wrong_answer")
                if kind == "answer_set":
                    reference = reference or ", ".join(spec["expected"])
                    wrong = wrong or ", ".join(spec["expected"][:-1])
                    if spec.get("match") == "path":
                        missing = [p for p in spec["expected"] if not (TEMPLATE / p).exists()]
                        results.append(("expected paths exist%s" % (" (missing %s)" % missing if missing else ""),
                                        not missing))
                    else:
                        names = [os.path.basename(p) for p in spec["expected"]]
                        results.append(("expected basenames unique", len(names) == len(set(names))))
                if reference is None or wrong is None:
                    failures.append("%s: no reference_answer or wrong_answer to validate against" % task["id"])
                    continue
                injected = bool(task.get("inject"))
                results.append(("reference passes", checked_on(task, "ANSWER: " + reference, injected)["success"] is True))
                results.append(("wrong answer fails", checked_on(task, "ANSWER: " + wrong, injected)["success"] is False))
            bad = [name for name, ok in results if not ok]
            failures += ["%s: %s" % (task["id"], name) for name in bad]
            print("%s: %s" % (task["id"], "ok (%s)" % ", ".join(n for n, _ in results) if not bad else "FAILED " + ", ".join(bad)))
    finally:
        shutil.rmtree(WORK, ignore_errors=True)
        shutil.rmtree(RUN_HOME, ignore_errors=True)
    if failures:
        raise Halt("%d control(s) failed" % len(failures))
    print("validate: every control held (%d tasks)" % len(tasks["tasks"]))


def command_reparse(options):
    """Recomputes tokens and validity from the kept streams, keeping each run's check result."""
    directory = Path(options.session) if Path(options.session).exists() else RESULTS / options.session
    record = session_record(directory)
    for path in sorted(directory.glob("*.json")):
        summary = json.loads(path.read_text())
        if "task" not in summary:
            continue
        stream = path.with_name(path.stem + ".stream.jsonl")
        if not stream.exists():
            continue
        parsed = parse(stream, summary["arm"], sift_on_a(record), record.get("mod_name"))
        if summary.get("timed_out"):
            parsed["valid"] = False
            parsed["invalid_reasons"].append("timed out")
        summary.pop("final_text", None)
        summary.update(with_reply_lines(parsed))
        path.write_text(json.dumps(sanitise(summary), indent=1) + "\n")
    print(analyse(directory))


def main(argv):
    parser = argparse.ArgumentParser(description="The paired sift benchmark (see Benchmarks/README.md).")
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="run tasks in both arms")
    run.add_argument("--tasks", help="the tasks file (default: Benchmarks/tasks.json, this repository's corpus)")
    run.add_argument("--corpus", help="<repository path>@<commit>, over the tasks file's own corpus")
    run.add_argument("--no-warmup", action="store_true", help="skip the unscored warm-up run per arm per task")
    run.add_argument("--task", action="append", help="a task id; repeat for several (default: every task)")
    run.add_argument("--repeats", type=int, default=3)
    run.add_argument("--session", help="the results directory name (default: a timestamp)")
    run.add_argument("--effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"])
    run.add_argument("--timeout", type=int, default=1200, help="wall-clock seconds per claude run")
    run.add_argument("--budget", type=float, default=5.0, help="--max-budget-usd per claude run")
    run.add_argument("--sift", help="the sift binary arm B runs (default: the one on PATH)")
    run.add_argument("--claude", help="the claude binary (default: the one on PATH)")
    run.add_argument("--rule-b", help="the rule file arm B installs (default: the Sift.md shipped with --sift)")
    run.add_argument("--rule-a", help="run arm A with sift too, installed with this rule file: rule A vs rule B")
    run.add_argument("--mod-b", help="a Claude Code plugin directory arm B loads with --plugin-dir; arm A runs "
                                     "sift too, under the same rule, without it: mod vs no mod")
    run.add_argument("--mod-env", action="append", default=[], metavar="NAME=VALUE",
                     help="with --mod-b, a variable set in arm B's environment only, such as SIFT_MOD_BASH=on "
                          "(repeatable; recorded in session.json and the table's header)")
    analyse_parser = commands.add_parser("analyse", help="print the paired table for a results session")
    analyse_parser.add_argument("session", nargs="?", help="a session directory or name (default: the latest)")
    reparse = commands.add_parser("reparse", help="recompute a session's summaries from its kept streams")
    reparse.add_argument("session")
    validate = commands.add_parser("validate", help="check every task's check against its controls, no model")
    validate.add_argument("--tasks", help="the tasks file (default: Benchmarks/tasks.json)")
    validate.add_argument("--corpus", help="<repository path>@<commit>, over the tasks file's own corpus")
    validate.add_argument("--sift", help="the sift binary whose hook is probed (default: the one on PATH)")
    commands.add_parser("paths", help="print, as shell assignments, the directories a run writes outside the results")
    options = parser.parse_args(argv)
    if options.command == "paths":
        for name, path in (("WORK", WORK), ("RUN_HOME", RUN_HOME), ("PROJECT_STATE", PROJECT_STATE)):
            print("%s=%s" % (name, shlex.quote(str(path))))
        return 0
    # A TERM (run.sh forwards its own) unwinds like an interrupt, so every cleanup above runs.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        {"run": command_run, "analyse": command_analyse, "reparse": command_reparse,
         "validate": command_validate}[options.command](options)
    except Halt as error:
        print("error: %s" % error, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
