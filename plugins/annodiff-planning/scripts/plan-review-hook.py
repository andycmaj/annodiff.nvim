#!/usr/bin/env python3
"""plan-review-hook.py - PreToolUse hook for ExitPlanMode (annodiff-planning).

Opens the plan Claude is about to present in Neovim (annodiff.nvim) and returns
the user's annotations as plan feedback. Port of revdiff-planning's hook.

Each Claude session gets one plan repo, $TMPDIR/annodiff-plan-<session>/, a git
repo holding plan.md. Its HEAD is the previous revision (an empty file on the
first round) and its worktree the new one, and the review is annodiff's doc mode,
`:Annodiff --doc plan.md HEAD`: the plan in one buffer with its headings as the
tree; the first round marks nothing, later rounds mark what changed inline.
revdiff chains rounds with a marker the agent must copy into its next plan;
here the session id from the hook event keys the chain, so nothing depends on
the agent and no agent-supplied path is ever read.

plan.md is a real, editable file in the review. Edits the user makes to it go
back as a diff next to the annotations.

Responses (as revdiff-planning):
  - "ask"  (JSON on stdout, exit 0): no feedback, or the review could not run;
           Claude Code shows its normal plan confirmation
  - deny   (reason on stderr, exit 2): feedback; Claude revises the plan
"""

from __future__ import annotations

import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SUCCESS_CODES = {0, 10}
PLAN = "plan.md"
GIT_CONFIG = [
    "-c", "user.name=annodiff-planning",
    "-c", "user.email=annodiff-planning@localhost",
    "-c", "commit.gpgsign=false",
    "-c", "core.hooksPath=/dev/null",
    "-c", "init.defaultBranch=main",
]


def make_response(decision: str, reason: str = "") -> None:
    if decision == "deny":
        print(reason, file=sys.stderr)
        sys.exit(2)
    resp: dict = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": decision}}
    if reason:
        resp["hookSpecificOutput"]["permissionDecisionReason"] = reason
    print(json.dumps(resp, indent=2))
    sys.exit(0)


def read_event() -> dict:
    raw = sys.stdin.read()
    try:
        event = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return {}
    return event if isinstance(event, dict) else {}


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *GIT_CONFIG, "-C", str(repo), *args], check=True, capture_output=True, text=True)


def plan_repo(session_id: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_-]", "", session_id)[:80] or "default"
    return Path(os.environ.get("ANNODIFF_PLAN_DIR") or tempfile.gettempdir()) / f"annodiff-plan-{safe}"


def prepare(repo: Path, plan: str) -> None:
    """HEAD = previous revision (or empty), worktree = this revision, no old notes."""
    if not (repo / ".git").is_dir():
        repo.mkdir(parents=True, exist_ok=True)
        git(repo, "init", "-q")
        (repo / PLAN).write_text("")
        git(repo, "add", PLAN)
        git(repo, "commit", "-q", "-m", "empty")
    # the annodiff state of an earlier round (persisted notes, export) must not come back
    shutil.rmtree(repo / ".git" / "annodiff", ignore_errors=True)
    (repo / PLAN).write_text(plan)


def commit_revision(repo: Path, plan: str) -> None:
    """Record the plan as Claude submitted it, so the next round diffs against it."""
    (repo / PLAN).write_text(plan)
    git(repo, "add", PLAN)
    git(repo, "commit", "-q", "--allow-empty", "-m", "revision")


def resolve_launcher(plugin_root: str) -> Path | None:
    resolver = Path(plugin_root) / "scripts" / "resolve-launcher.sh"
    try:
        res = subprocess.run(
            [str(resolver), "launch-plan-review.sh", os.environ.get("CLAUDE_PLUGIN_DATA", "")],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"resolve-launcher.sh failed: {exc}", file=sys.stderr)
        return None
    path = res.stdout.strip()
    return Path(path) if res.returncode == 0 and path else None


def user_edits(plan: str, after: str) -> str:
    if after == plan:
        return ""
    return "".join(difflib.unified_diff(
        plan.splitlines(keepends=True), after.splitlines(keepends=True),
        fromfile="a/plan.md (your plan)", tofile="b/plan.md (user's edit)",
    ))


def main() -> None:
    event = read_event()
    plan = (event.get("tool_input") or {}).get("plan") or ""
    if not plan:
        make_response("ask", "no plan content in hook event")
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    if not plugin_root:
        make_response("ask", "CLAUDE_PLUGIN_ROOT not set")
    if not shutil.which("nvim"):
        make_response("ask", "nvim not installed, skipping plan review")
    launcher = resolve_launcher(plugin_root)
    if launcher is None:
        make_response("ask", "launch-plan-review.sh not found")

    repo = plan_repo(str(event.get("session_id") or ""))
    try:
        prepare(repo, plan)
    except (OSError, subprocess.CalledProcessError) as exc:
        make_response("ask", f"plan review repo failed: {exc}")

    try:
        result = subprocess.run([str(launcher), str(repo)], capture_output=True, text=True, timeout=345600)
    except subprocess.TimeoutExpired:
        make_response("ask", "plan review timed out; plan not reviewed this round")
    except OSError as exc:
        make_response("ask", f"plan review launcher failed to start: {exc}")
    if result.returncode not in SUCCESS_CODES:
        err = (result.stderr or "").strip().splitlines()
        detail = f": {err[-1]}" if err else ""
        make_response("ask", f"plan review launcher exited {result.returncode}{detail}; plan not reviewed this round")

    annotations = result.stdout.strip()
    try:
        edits = user_edits(plan, (repo / PLAN).read_text())
    except OSError:
        edits = ""

    if not annotations and not edits:
        shutil.rmtree(repo, ignore_errors=True)
        make_response("ask", "plan reviewed in annodiff, no annotations")

    try:
        commit_revision(repo, plan)
    except (OSError, subprocess.CalledProcessError):
        pass  # next round then marks no changes; the feedback still goes back

    parts = ["The user reviewed your plan in Neovim (annodiff) and left feedback."]
    if annotations:
        parts.append(
            "Annotations, in revdiff format: `## plan.md:N (+)` or `( )` is line N of the plan you "
            "just submitted, `(-)` a line of your previous revision that you removed, `:N-M` a range, "
            "`(file-level)` the whole plan. A note containing `??` or starting with explain/what/how/why "
            "is a question: answer it in the revised plan or in chat.\n\n" + annotations
        )
    if edits:
        parts.append("The user also edited the plan directly. Keep these edits:\n\n```diff\n" + edits + "```")
    parts.append(
        "Revise the plan to address every point, then call ExitPlanMode again. "
        "The next review marks what changed since this revision."
    )
    make_response("deny", "\n\n".join(parts))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
