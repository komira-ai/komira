"""The main-red alert: the script of .github/workflows/main_red.yml (docs/ci.md,
"main_red.yml").

  python3 release/ci/main_red.py --repo <owner/name> --run-id <id> [--dry-run]

It runs when a run of the release workflow (kci.yml) completes, and reads
that run back from the GitHub API with the `gh` CLI (GH_TOKEN in the
environment). Only a run started by a PUSH to main counts: a manual run may
build another revision, and a run of any other branch is not main.

  failure, timed_out or startup_failure: main is red.
    1. The last green: of the successful push runs of kci on main (newest
       first), the first whose commit is an ancestor of (or is) the red
       head. If one is a DESCENDANT of the red head first, main is already
       green past this commit (a re-run of an old run failed): nothing is
       written.
    2. The culprits: the pull requests merged into main between the last
       green and the head: the first-parent commits of main in that range,
       newest first, each one's pull request from the API (a merged pull
       request into main) or from its subject (`Merge pull request #N` or a
       squash's trailing `(#N)`). No last green, or no number found:
       `Culprits: unknown`.
    3. The failing targets: the `Action failed: <target>`, `GATED TEST
       FAILED: <target>` and ``Validation for `<target>` failed`` lines of
       the failed jobs' logs, the first MAX_TARGETS, each without its
       configuration; with none, the failed job and step; with no failed
       job (a job could not start), the workflow.
    4. If an issue labelled `main-red` is open, a comment on the oldest one;
       otherwise a new issue `main red: <first failing>` with that label
       (created if missing). The body, and the comment, are the contract an
       outside reader parses (issue_body): one `Key: value` line each, in
       this order, nothing else:
         Run: <run url>
         Head: <full commit id>
         Last green: <full commit id, or none>
         Culprits: #N, #M          (or `Culprits: unknown`)
         Failing: <target>         (one line per target)
         Log: <key log line>       (none, one or two lines)
       After creating an issue it lists the open ones again: if two runs
       raced, every issue but the oldest is closed as its duplicate, its
       body posted on the oldest.
  success: every open `main-red` issue is closed, with the comment
    `Fixed: main is green at <sha> (run <url>)`, unless it records a head
    the green commit does not contain (a re-run of an older commit went
    green): then it stays open. The recorded heads are the `Head:` lines
    of the issue's body and of the comments WORKFLOW_LOGIN wrote; anyone
    can comment on a public issue, so no other comment counts. A head the
    compare API does not know (404) or places off main's line (diverged)
    is logged and skipped.
  cancelled, skipped, anything else: nothing.

The pure parts (log lines, the range, the issue text, the decisions) are
functions the cases in release/ci/tests/test_main_red.py hold; run() is the
only part that talks to the API, through the object it is given. Exit 0
when it wrote what the run calls for (or nothing was called for), non-zero
on any API failure, so the workflow's run is red and visible.
"""

import argparse
import json
import re
import subprocess
import sys
import time

LABEL = "main-red"
LABEL_COLOR = "b60205"
LABEL_DESCRIPTION = "main's release build failed (docs/ci.md, main_red.yml)"
# The login the workflow's GITHUB_TOKEN writes as: only its comments record
# heads (anyone can comment on a public issue).
WORKFLOW_LOGIN = "github-actions[bot]"
WORKFLOW_FILE = "kci.yml"
MAIN = "main"
MAX_TARGETS = 5
MAX_LOG_LINES = 2
MAX_VALUE = 300
RED = ("failure", "timed_out", "startup_failure")

# A runner's timestamp, then buck2's own bracketed one, then colour codes.
_RUNNER_TS = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ")
_BUCK_TS = re.compile(r"^\[\d{4}-\d\d-\d\dT[^\]]*\] ?")
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_ACTION = re.compile(r"^Action failed: (\S+)")
_GATED = re.compile(r"^GATED TEST FAILED: (\S+)")
_VALIDATION = re.compile(r"^Validation for `?([^`\s]+)[^`]*`? failed")
# What kci and the runner print when a stage fails without a target line.
_KEY = (re.compile(r"^FAILED -- "), re.compile(r"^kci: FAILED"), re.compile(r"^BUILD FAILED"), re.compile(r"^##\[error\]"))
_MERGE_SUBJECT = re.compile(r"^Merge pull request #(\d+) ")
_SQUASH_SUBJECT = re.compile(r"\(#(\d+)\)$")
_HEAD_LINE = re.compile(r"^Head: ([0-9a-f]{40})$")


class NotFound(Exception):
    """An API path answered 404."""


class AlreadyExists(Exception):
    """A create answered 422 `already_exists` (another run made it first)."""


# ---- log lines ---------------------------------------------------------------


def strip_log_line(line):
    """`line` without the runner's timestamp, buck2's bracketed timestamp,
    colour codes and surrounding blanks."""
    line = _RUNNER_TS.sub("", line.rstrip("\r\n"))
    line = _ANSI.sub("", line)
    line = _BUCK_TS.sub("", line)
    return line.strip()


def _target_of(line):
    for pattern in (_ACTION, _GATED, _VALIDATION):
        m = pattern.match(line)
        if m:
            return m.group(1)
    return None


def failing_targets(log, limit=MAX_TARGETS):
    """The failing targets a job log names, in order of first appearance,
    each once, at most `limit`."""
    out = []
    for raw in log.splitlines():
        target = _target_of(strip_log_line(raw))
        if target and target not in out:
            out.append(target)
            if len(out) == limit:
                break
    return out


def key_log_lines(log, limit=MAX_LOG_LINES):
    """The lines that say why: the target lines when the log has any, else
    kci's and the runner's failure lines (`FAILED -- `, `kci: FAILED`,
    `BUILD FAILED`, `##[error]`), in that preference; each once, at most
    `limit`."""
    lines = [strip_log_line(raw) for raw in log.splitlines()]
    out = []
    for line in lines:
        if _target_of(line) and line not in out:
            out.append(line)
            if len(out) == limit:
                return out
    if out:
        return out
    for pattern in _KEY:
        for line in lines:
            if pattern.match(line) and line not in out:
                out.append(line)
                if len(out) == limit:
                    return out
    return out


def failed_jobs(jobs):
    """The jobs that failed, then those cancelled (a job past its
    `timeout-minutes` is cancelled while the run fails)."""
    return [j for j in jobs if j.get("conclusion") in ("failure", "timed_out")] + [
        j for j in jobs if j.get("conclusion") == "cancelled"
    ]


def job_label(job):
    """`job <name>, step <failed step>`, or `job <name> (<conclusion>)`."""
    for step in job.get("steps") or []:
        if step.get("conclusion") == "failure":
            return "job %s, step %s" % (job["name"], step["name"])
    return "job %s (%s)" % (job["name"], job.get("conclusion"))


# ---- the range -----------------------------------------------------------------


def last_green(head, success_runs, relation):
    """("found", sha) for the last green commit of `head`, ("stale", sha) when
    a green commit already contains `head`, ("none", None) without one.
    `success_runs` newest first; `relation(sha)` is the status of `head`
    against `sha` as the compare API says it (`ahead`: sha is an ancestor;
    `identical`; `behind`: sha descends from head; `diverged`)."""
    for run in success_runs:
        sha = run["head_sha"]
        if sha == head:
            return ("found", sha)
        status = relation(sha)
        if status in ("ahead", "identical"):
            return ("found", sha)
        if status == "behind":
            return ("stale", sha)
    return ("none", None)


def first_parent_chain(commits, head, base):
    """The commits of main from `head` back to (not including) `base`,
    following first parents: the commits that landed on main, newest first.
    `commits` is the compare API's list."""
    by_sha = {c["sha"]: c for c in commits}
    chain = []
    sha = head
    while sha in by_sha and sha != base:
        chain.append(sha)
        parents = by_sha[sha].get("parents") or []
        if not parents:
            break
        sha = parents[0]["sha"]
    return chain


def subject_pr(subject):
    """The pull request a commit subject names: `Merge pull request #N ...`
    or a squash's trailing `(#N)`; else None."""
    m = _MERGE_SUBJECT.match(subject) or _SQUASH_SUBJECT.search(subject)
    return int(m.group(1)) if m else None


def culprits(commits, head, base, pulls_of):
    """The pull requests merged into main in base..head, newest first, each
    once. `pulls_of(sha)` is the API's pull requests of a commit; one merged
    into main counts, else the commit's subject is read."""
    by_sha = {c["sha"]: c for c in commits}
    out = []
    for sha in first_parent_chain(commits, head, base):
        numbers = [
            p["number"]
            for p in (pulls_of(sha) or [])
            if p.get("merged_at") and (p.get("base") or {}).get("ref") == MAIN
        ]
        if not numbers:
            n = subject_pr(by_sha[sha]["commit"]["message"].split("\n", 1)[0])
            numbers = [n] if n is not None else []
        for n in numbers:
            if n not in out:
                out.append(n)
    return out


# ---- the issue -------------------------------------------------------------------


def _value(text):
    """One line, at most MAX_VALUE characters: no value can add a line."""
    return " ".join(str(text).split())[:MAX_VALUE]


def issue_title(failing):
    return "main red: " + _value(failing[0])


def issue_body(run_url, head, green, prs, failing, log_lines):
    """The contract (file header): Run, Head, Last green, Culprits, a Failing
    line per target, a Log line per key line."""
    lines = [
        "Run: " + _value(run_url),
        "Head: " + _value(head),
        "Last green: " + (_value(green) if green else "none"),
        "Culprits: " + (", ".join("#%d" % n for n in prs) if prs else "unknown"),
    ]
    lines += ["Failing: " + _value(f) for f in failing]
    lines += ["Log: " + _value(l) for l in log_lines]
    return "\n".join(lines) + "\n"


def heads_in(texts):
    """Every full commit id on a `Head:` line of `texts`, each once."""
    out = []
    for text in texts:
        for line in (text or "").splitlines():
            m = _HEAD_LINE.match(line.strip())
            if m and m.group(1) not in out:
                out.append(m.group(1))
    return out


def fixed_comment(sha, run_url):
    return "Fixed: main is green at %s (run %s)" % (sha, run_url)


# ---- the decisions -------------------------------------------------------------


def classify(run):
    """`red`, `green` or `ignore` for a completed run of kci."""
    if run.get("event") != "push" or run.get("head_branch") != MAIN:
        return "ignore"
    if run.get("conclusion") in RED:
        return "red"
    if run.get("conclusion") == "success":
        return "green"
    return "ignore"


def decide_red(open_issues):
    """("open", None) with no open issue, else ("comment", the oldest)."""
    if not open_issues:
        return ("open", None)
    return ("comment", min(i["number"] for i in open_issues))


def decide_green(heads_by_issue, contains):
    """[(issue, "close" | "keep")], by issue number: close unless the green
    commit is known NOT to contain a recorded head. `contains(head)` is True,
    False, or None for a head it cannot place (unknown to the API, or off
    main's line), which neither blocks nor counts."""
    return [
        (n, "keep" if any(contains(h) is False for h in heads_by_issue[n]) else "close")
        for n in sorted(heads_by_issue)
    ]


def duplicates(open_issues):
    """(the oldest open issue, the others in order) after a race."""
    numbers = sorted(i["number"] for i in open_issues)
    if not numbers:
        return (None, [])
    return (numbers[0], numbers[1:])


# ---- the run ---------------------------------------------------------------------


def _compare(api, repo, base, head, per_page):
    return api.get("repos/%s/compare/%s...%s?per_page=%d&page=1" % (repo, base, head, per_page))


def _range_commits(api, repo, base, head):
    """The compare API's commits of base...head, every page."""
    first = _compare(api, repo, base, head, 100)
    commits = list(first.get("commits") or [])
    total = first.get("total_commits", len(commits))
    page = 2
    while len(commits) < total and page <= 20:
        more = api.get("repos/%s/compare/%s...%s?per_page=100&page=%d" % (repo, base, head, page)).get("commits") or []
        if not more:
            break
        commits += more
        page += 1
    return first, commits


def _red(api, repo, run, out):
    head = run["head_sha"]
    successes = api.get(
        "repos/%s/actions/workflows/%s/runs?branch=%s&event=push&status=success&per_page=30" % (repo, WORKFLOW_FILE, MAIN)
    ).get("workflow_runs") or []
    statuses = {}
    ranges = {}

    # A candidate's compare is also the range when it is the last green:
    # read it once, with every page.
    def relation(sha):
        if sha not in statuses:
            first, commits = _range_commits(api, repo, sha, head)
            statuses[sha] = first.get("status")
            ranges[sha] = commits
        return statuses[sha]

    verdict, green = last_green(head, successes, relation)
    if verdict == "stale":
        out.write("main_red: %s is red, but main is green at %s, which contains it: nothing to do\n" % (head, green))
        return
    prs = None
    if verdict == "found" and green != head:
        prs = culprits(ranges.get(green, []), head, green, lambda sha: _pulls(api, repo, sha)) or None

    jobs = api.get("repos/%s/actions/runs/%d/attempts/%d/jobs?per_page=100" % (repo, run["id"], run.get("run_attempt", 1))).get("jobs") or []
    failing, log_lines = [], []
    for job in failed_jobs(jobs):
        try:
            log = api.text("repos/%s/actions/jobs/%d/logs" % (repo, job["id"]))
        except NotFound:
            log = ""
        for t in failing_targets(log):
            if t not in failing and len(failing) < MAX_TARGETS:
                failing.append(t)
        if not log_lines:
            log_lines = key_log_lines(log)
    if not failing:
        failing = [job_label(j) for j in failed_jobs(jobs)][:MAX_TARGETS]
    if not failing:
        failing = ["workflow %s (no job failed: a job could not start)" % run.get("name", "kci")]

    body = issue_body(run["html_url"], head, green, prs, failing, log_lines)
    open_issues = _open_issues(api, repo)
    action, number = decide_red(open_issues)
    if action == "comment":
        api.write("POST", "repos/%s/issues/%d/comments" % (repo, number), {"body": body})
        out.write("main_red: commented on #%d\n" % number)
        return
    _ensure_label(api, repo)
    created = api.write("POST", "repos/%s/issues" % repo, {"title": issue_title(failing), "body": body, "labels": [LABEL]})
    out.write("main_red: opened #%s\n" % created.get("number"))
    oldest, others = duplicates(_open_issues(api, repo))
    if created.get("number") in others:
        api.write("POST", "repos/%s/issues/%d/comments" % (repo, oldest), {"body": body})
        api.write("POST", "repos/%s/issues/%d/comments" % (repo, created["number"]), {"body": "Duplicate of #%d" % oldest})
        api.write("PATCH", "repos/%s/issues/%d" % (repo, created["number"]), {"state": "closed", "state_reason": "not_planned"})
        out.write("main_red: #%d raced #%d; closed as its duplicate\n" % (created["number"], oldest))


def _green(api, repo, run, out):
    sha = run["head_sha"]
    heads_by_issue = {}
    for issue in _open_issues(api, repo):
        comments = api.get("repos/%s/issues/%d/comments?per_page=100" % (repo, issue["number"])) or []
        # The body, and the workflow's own comments: no one else's.
        mine = [c.get("body") for c in comments if (c.get("user") or {}).get("login") == WORKFLOW_LOGIN]
        heads_by_issue[issue["number"]] = heads_in([issue.get("body")] + mine)

    def contains(head):
        if head == sha:
            return True
        try:
            status = _compare(api, repo, head, sha, 1).get("status")
        except NotFound:
            status = "unknown"
        if status in ("ahead", "identical"):
            return True
        if status == "behind":
            return False
        out.write("main_red: recorded head %s is %s against %s; skipped\n" % (head, status, sha))
        return None

    for number, action in decide_green(heads_by_issue, contains):
        if action == "close":
            api.write("POST", "repos/%s/issues/%d/comments" % (repo, number), {"body": fixed_comment(sha, run["html_url"])})
            api.write("PATCH", "repos/%s/issues/%d" % (repo, number), {"state": "closed", "state_reason": "completed"})
            out.write("main_red: closed #%d\n" % number)
        else:
            out.write("main_red: #%d records a head %s does not contain; left open\n" % (number, sha))


def _pulls(api, repo, sha):
    try:
        return api.get("repos/%s/commits/%s/pulls" % (repo, sha))
    except NotFound:
        return []


def _open_issues(api, repo):
    issues = api.get("repos/%s/issues?labels=%s&state=open&per_page=100" % (repo, LABEL)) or []
    return [i for i in issues if "pull_request" not in i]


def _ensure_label(api, repo):
    try:
        api.get("repos/%s/labels/%s" % (repo, LABEL))
    except NotFound:
        try:
            api.write("POST", "repos/%s/labels" % repo, {"name": LABEL, "color": LABEL_COLOR, "description": LABEL_DESCRIPTION})
        except AlreadyExists:
            pass


def run(api, repo, run_id, out=sys.stdout):
    """Reads run `run_id` of `repo` and writes what it calls for (file header)."""
    the_run = api.get("repos/%s/actions/runs/%d" % (repo, run_id))
    verdict = classify(the_run)
    out.write("main_red: run %d (%s, %s, %s) at %s: %s\n" % (
        run_id, the_run.get("event"), the_run.get("head_branch"), the_run.get("conclusion"), the_run.get("head_sha"), verdict))
    if verdict == "red":
        _red(api, repo, the_run, out)
    elif verdict == "green":
        _green(api, repo, the_run, out)


class GhApi:
    """The GitHub API through `gh api` (GH_TOKEN in the environment). Each
    call is tried three times; a 404 is NotFound, a 422 `already_exists`
    AlreadyExists, neither retried. With `dry_run`, a write is printed, not
    sent."""

    def __init__(self, dry_run=False, out=sys.stdout, runner=subprocess.run, sleep=time.sleep):
        self.dry_run = dry_run
        self.out = out
        self.runner = runner
        self.sleep = sleep

    def _gh(self, args, stdin=None):
        last = ""
        for attempt in range(3):
            p = self.runner(["gh", "api"] + args, input=stdin, capture_output=True, text=True)
            if p.returncode == 0:
                return p.stdout
            last = (p.stderr or "").strip()
            if "HTTP 404" in last:
                raise NotFound(args[-1])
            if "HTTP 422" in last and "already_exists" in (p.stdout or "") + last:
                raise AlreadyExists(args[-1])
            self.sleep(2 ** attempt)
        raise SystemExit("main_red: gh api %s failed: %s" % (" ".join(args), last))

    def get(self, path):
        text = self._gh([path])
        return json.loads(text) if text.strip() else None

    def text(self, path):
        return self._gh([path])

    def write(self, method, path, fields):
        if self.dry_run:
            self.out.write("main_red: DRY RUN %s %s %s\n" % (method, path, json.dumps(fields, sort_keys=True)))
            return {"number": 0}
        text = self._gh(["--method", method, path, "--input", "-"], stdin=json.dumps(fields))
        return json.loads(text) if text.strip() else {}


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--run-id", required=True, type=int, help="the completed run of kci")
    ap.add_argument("--dry-run", action="store_true", help="read only: print each write instead of sending it")
    args = ap.parse_args(argv)
    if not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", args.repo):
        raise SystemExit("main_red: --repo %r is not owner/name" % args.repo)
    run(GhApi(dry_run=args.dry_run), args.repo, args.run_id)


if __name__ == "__main__":
    main(sys.argv[1:])
