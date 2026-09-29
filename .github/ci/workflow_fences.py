#!/usr/bin/env python3
"""workflow_fences.py -- the secret and upload fences of the CI workflows.

usage: python3 .github/ci/workflow_fences.py .github/workflows/*.yml

Fails (exit 1), naming the line, when:
  * anything outside a job reads `secrets.` (a workflow-level `env:` would
    hand the secret to every job);
  * a job reads `secrets.` but names no `environment:`. The secrets live in
    GitHub Environments whose branch and reviewer rules GitHub enforces
    before the job starts; a job with no environment gets no environment
    secret, and a repository secret would reach any branch's workflow;
  * a step uses actions/upload-artifact without an `if:` that requires
    `steps.redact.outcome == 'success'`, or the job has no step `id: redact`.
    Artifacts of a public repository can be downloaded by anyone and are not
    log-masked, so nothing is uploaded unless redaction succeeded.
It also fails if it found no job at all, so it cannot pass by reading
nothing. Line-based on purpose: the workflows are written in block style, and
this needs nothing but python3 on the runner.
"""
import re
import sys

REDACT_OK = "steps.redact.outcome == 'success'"


SECRET = re.compile(r"\bsecrets\.[A-Za-z_]")


def code(line):
    if line.lstrip().startswith("#"):
        return ""
    return line.split(" #", 1)[0]


def check(path, bad):
    lines = open(path).read().splitlines()
    blocks, job, in_jobs = {}, None, False
    for n, line in enumerate(lines, 1):
        if not code(line).strip():
            continue  # blank or comment-only: ends no block
        if re.match(r"^jobs:\s*$", line):
            in_jobs, job = True, None
            continue
        if re.match(r"^\S", line):
            in_jobs, job = False, None
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line) if in_jobs else None
        if m:
            job = m.group(1)
            blocks[job] = []
            continue
        if job is None:
            if SECRET.search(code(line)):
                bad.append("%s:%d reads a secret outside any job" % (path, n))
            continue
        blocks[job].append((n, line))

    for job, body in blocks.items():
        has_env = any(re.match(r"^    environment:", l) for _, l in body)
        for n, l in body:
            if SECRET.search(code(l)) and not has_env:
                bad.append("%s:%d job %s reads a secret but names no environment" % (path, n, job))
        steps, cur = [], None
        for n, l in body:
            if re.match(r"^      - ", l):
                cur = [(n, l)]
                steps.append(cur)
            elif cur is not None and re.match(r"^        ", l):
                cur.append((n, l))
            else:
                cur = None
        has_redact = any(re.search(r"\bid:\s*redact\s*$", code(l)) for st in steps for _, l in st)
        for st in steps:
            if not any("actions/upload-artifact@" in code(l) for _, l in st):
                continue
            gated = any(re.search(r"\bif:", l) and REDACT_OK in code(l) for _, l in st)
            if not (has_redact and gated):
                bad.append("%s:%d job %s uploads an artifact without requiring a successful `redact` step"
                           % (path, st[0][0], job))
    return len(blocks)


def main(paths):
    bad, jobs = [], 0
    for p in paths:
        jobs += check(p, bad)
    for b in bad:
        print(b)
    if jobs == 0:
        print("found no jobs, so checked nothing")
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
