"""The cases of release/ci/main_red.py (the main-red alert, docs/ci.md,
"main_red.yml"), run by the py_test //release/ci/tests:test_main_red as a
build action: building the target is running them.

Each group pins one part, and names the defect it would catch:

- log lines: the failing targets read from real job logs of this
  repository's kci runs (fixtures/*.log, excerpts kept byte for byte except
  one line per failure that named a build-cache address, removed), the
  key lines when no target line exists, and timestamps, buck2 prefixes and
  colour codes stripped. A reader that keeps the timestamp, the
  configuration or a duplicate, or reads `Waiting on` as a failure, is red.
- the range: which successful run is the last green (an ancestor of the red
  head), which one makes the red stale (a descendant), and the culprits
  (the first-parent commits of main after the last green, newest first, a
  pull request's number from the API or from the commit's subject).
- the issue: its title and the body contract an outside reader parses,
  line for line.
- the decision: open, comment or nothing on a red; close or keep on a green;
  nothing on a cancelled or skipped run, a manual run or another branch.
- the whole run against a fake API: what is written, in order.
"""

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import main_red  # noqa: E402  (staged next to this file by the py_test)

FIXTURES = os.path.join(HERE, "fixtures")


def fixture(name):
    with open(os.path.join(FIXTURES, name), "rb") as f:
        return f.read().decode("utf-8", "replace")


HEAD = "a" * 40
G1 = "1" * 40
G2 = "2" * 40
C1 = "c1" + "0" * 38
C2 = "c2" + "0" * 38
C3 = "c3" + "0" * 38
RUN_URL = "https://github.com/komira-ai/komira/actions/runs/7"


class LogLines(unittest.TestCase):
    def test_action_failed_from_a_real_build_log(self):
        # kci run 37307156898, job build: the pin download that timed out.
        log = fixture("build_action_failed.log")
        self.assertEqual(main_red.failing_targets(log), ["komira//tools/build/toolchains:busybox"])

    def test_gated_test_from_a_real_log_in_order_without_duplicates(self):
        log = fixture("pr_gated_test_failed.log")
        self.assertEqual(
            main_red.failing_targets(log),
            [
                "komira//src/kci_resource_proto:kci_resource_proto",
                "komira//src/kci_resource_proto:kci_resource_proto:tests/test_held_numbers_are_unused.mojo",
            ],
        )

    def test_validation_with_and_without_backticks(self):
        log = (
            "2026-10-05T22:38:08.9126771Z [2026-10-05T22:38:08.903+00:00] Validation for `komira//:docs "
            "(komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)` failed:\n"
            "Validation for komira//:public_boundary (cfg#1) failed:\n"
        )
        self.assertEqual(main_red.failing_targets(log), ["komira//:docs", "komira//:public_boundary"])

    def test_at_most_limit_targets(self):
        log = "".join("Action failed: //t:%d (cfg)\n" % i for i in range(9))
        self.assertEqual(main_red.failing_targets(log, limit=3), ["//t:0", "//t:1", "//t:2"])

    def test_waiting_on_is_not_a_failure(self):
        log = "Waiting on komira//a:b (cfg) -- mojo_build\nBUILD FAILED\n"
        self.assertEqual(main_red.failing_targets(log), [])

    def test_key_lines_of_a_target_log_are_the_target_lines(self):
        log = fixture("build_action_failed.log")
        self.assertEqual(
            main_red.key_log_lines(log),
            [
                "Action failed: komira//tools/build/toolchains:busybox "
                "(komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (download_file busybox)",
            ],
        )

    def test_key_lines_without_a_target_from_a_real_prod_log(self):
        # kci run 37382578734, job prod: no build target failed; kci's own lines say why.
        log = fixture("prod_no_target.log")
        self.assertEqual(main_red.failing_targets(log), [])
        self.assertEqual(
            main_red.key_log_lines(log),
            [
                "FAILED -- the channel's credential: GithubOidcCredential: the ID-token request faulted: "
                "TcpStream.connect: connect timed out after 5000000us",
                "kci: FAILED (exit 4) stage prod",
            ],
        )

    def test_strip_removes_timestamp_prefix_and_colour(self):
        line = "2026-10-05T12:05:53.4100353Z [2026-10-05T12:05:53.408+00:00] \x1b[33m WARN\x1b[0m x"
        self.assertEqual(main_red.strip_log_line(line), "WARN x")

    def test_failing_jobs_name_job_and_step(self):
        jobs = [
            {"name": "build", "conclusion": "success", "steps": []},
            {"name": "prod", "conclusion": "failure", "steps": [
                {"name": "the revision", "conclusion": "success"},
                {"name": "kci run --stage prod", "conclusion": "failure"},
            ]},
            {"name": "validate", "conclusion": "skipped", "steps": []},
            {"name": "gamma", "conclusion": "cancelled", "steps": []},
        ]
        self.assertEqual(
            [main_red.job_label(j) for j in main_red.failed_jobs(jobs)],
            ["job prod, step kci run --stage prod", "job gamma (cancelled)"],
        )


class Range(unittest.TestCase):
    def test_last_green_is_the_first_ancestor_success(self):
        runs = [{"head_sha": G2}, {"head_sha": G1}]
        rel = {G2: "diverged", G1: "ahead"}
        self.assertEqual(main_red.last_green(HEAD, runs, rel.get), ("found", G1))

    def test_a_newer_green_descendant_makes_the_red_stale(self):
        runs = [{"head_sha": G2}, {"head_sha": G1}]
        rel = {G2: "behind", G1: "ahead"}
        self.assertEqual(main_red.last_green(HEAD, runs, rel.get), ("stale", G2))

    def test_the_same_commit_green_before_is_the_last_green(self):
        runs = [{"head_sha": HEAD}]
        self.assertEqual(main_red.last_green(HEAD, runs, lambda s: "identical"), ("found", HEAD))

    def test_no_success_at_all(self):
        self.assertEqual(main_red.last_green(HEAD, [], lambda s: "ahead"), ("none", None))

    def _commit(self, sha, parents, subject):
        return {"sha": sha, "parents": [{"sha": p} for p in parents], "commit": {"message": subject + "\n\nbody"}}

    def test_culprits_walk_first_parents_newest_first(self):
        # main: G1 <- C1 (merge of PR 11, second parent B1) <- C2 (squash, PR 12) <- C3 (merge of PR 13)
        b1 = "b1" + "0" * 38
        commits = [
            self._commit(b1, [G1], "a commit on the pull request's branch (#99)"),
            self._commit(C1, [G1, b1], "Merge pull request #11 from komira-ai/x"),
            self._commit(C2, [C1], "lib: a squashed change (#12)"),
            self._commit(C3, [C2, "f" * 40], "Merge pull request #13 from komira-ai/y"),
        ]
        chain = main_red.first_parent_chain(commits, HEAD_OF(commits), G1)
        self.assertEqual(chain, [C3, C2, C1])
        self.assertEqual(main_red.culprits(commits, C3, G1, lambda sha: []), [13, 12, 11])

    def test_culprits_prefer_the_api_and_dedupe(self):
        commits = [
            self._commit(C1, [G1], "no number here"),
            self._commit(C2, [C1], "Merge pull request #12 from komira-ai/x"),
        ]
        api = {C1: [{"number": 12, "merged_at": "x", "base": {"ref": "main"}}], C2: []}
        self.assertEqual(main_red.culprits(commits, C2, G1, api.get), [12])

    def test_a_pull_request_into_another_branch_is_not_a_culprit(self):
        commits = [self._commit(C1, [G1], "direct push")]
        api = {C1: [{"number": 5, "merged_at": "x", "base": {"ref": "other"}},
                    {"number": 6, "merged_at": None, "base": {"ref": "main"}}]}
        self.assertEqual(main_red.culprits(commits, C1, G1, api.get), [])

    def test_the_subject_number_is_read_only_from_merge_and_squash_forms(self):
        self.assertEqual(main_red.subject_pr("Merge pull request #42 from a/b"), 42)
        self.assertEqual(main_red.subject_pr("x: y (#43)"), 43)
        self.assertIsNone(main_red.subject_pr("refs #44 somewhere in the middle"))


def HEAD_OF(commits):
    return commits[-1]["sha"]


class Issue(unittest.TestCase):
    def test_title_is_the_first_failing_target(self):
        self.assertEqual(main_red.issue_title(["//a:b", "//c:d"]), "main red: //a:b")

    def test_body_contract_line_for_line(self):
        body = main_red.issue_body(
            RUN_URL, HEAD, G1, [13, 12], ["//a:b", "//c:d"], ["Action failed: //a:b (cfg)", "kci: FAILED"]
        )
        self.assertEqual(
            body,
            "Run: %s\nHead: %s\nLast green: %s\nCulprits: #13, #12\nFailing: //a:b\nFailing: //c:d\n"
            "Log: Action failed: //a:b (cfg)\nLog: kci: FAILED\n" % (RUN_URL, HEAD, G1),
        )

    def test_body_unknowns(self):
        body = main_red.issue_body(RUN_URL, HEAD, None, None, ["job x"], [])
        self.assertEqual(
            body,
            "Run: %s\nHead: %s\nLast green: none\nCulprits: unknown\nFailing: job x\n" % (RUN_URL, HEAD),
        )

    def test_body_values_are_one_line_and_bounded(self):
        body = main_red.issue_body(RUN_URL, HEAD, G1, [], ["//a:b\nFailing: forged"], ["x" * 1000])
        lines = body.splitlines()
        self.assertEqual([l.split(":", 1)[0] for l in lines], ["Run", "Head", "Last green", "Culprits", "Failing", "Log"])
        self.assertEqual(lines[3], "Culprits: unknown")
        self.assertLessEqual(len(lines[5]), len("Log: ") + main_red.MAX_VALUE)

    def test_heads_are_read_back_from_bodies_and_comments(self):
        texts = [main_red.issue_body(RUN_URL, HEAD, None, None, ["x"], []), "Head: " + G2 + "\n", "Head: short"]
        self.assertEqual(main_red.heads_in(texts), [HEAD, G2])

    def test_a_head_mid_line_is_not_read(self):
        # A target or log line quoting `Head: <sha>` (any value of the
        # contract) must not record a head: only a line that IS `Head: <sha>`.
        body = main_red.issue_body(RUN_URL, HEAD, None, None, ["//a:b Head: " + G1], ["x Head: " + G2])
        self.assertEqual(main_red.heads_in([body]), [HEAD])
        self.assertEqual(main_red.heads_in(["Log: Head: " + G1, "  Head: " + G2]), [G2])

    def test_fixed_comment(self):
        self.assertEqual(main_red.fixed_comment(G1, RUN_URL), "Fixed: main is green at %s (run %s)" % (G1, RUN_URL))


class Decision(unittest.TestCase):
    def run_of(self, conclusion, event="push", branch="main"):
        return {"conclusion": conclusion, "event": event, "head_branch": branch}

    def test_classify(self):
        self.assertEqual(main_red.classify(self.run_of("failure")), "red")
        self.assertEqual(main_red.classify(self.run_of("timed_out")), "red")
        self.assertEqual(main_red.classify(self.run_of("startup_failure")), "red")
        self.assertEqual(main_red.classify(self.run_of("success")), "green")
        self.assertEqual(main_red.classify(self.run_of("cancelled")), "ignore")
        self.assertEqual(main_red.classify(self.run_of("skipped")), "ignore")
        self.assertEqual(main_red.classify(self.run_of("failure", event="workflow_dispatch")), "ignore")
        self.assertEqual(main_red.classify(self.run_of("success", event="workflow_dispatch")), "ignore")
        self.assertEqual(main_red.classify(self.run_of("failure", branch="other")), "ignore")

    def test_red_opens_when_none_is_open_else_comments_on_the_oldest(self):
        self.assertEqual(main_red.decide_red([]), ("open", None))
        self.assertEqual(main_red.decide_red([{"number": 9}, {"number": 4}]), ("comment", 4))

    def test_green_closes_only_issues_whose_every_head_it_contains(self):
        issues = {3: [G1], 4: [G1, G2], 5: []}
        contains = {G1: True, G2: False}
        self.assertEqual(main_red.decide_green(issues, contains.get), [(3, "close"), (4, "keep"), (5, "close")])

    def test_green_skips_a_head_it_cannot_place(self):
        # None: the compare API does not know the head (404) or it is not on
        # main's line (diverged); it neither blocks nor counts.
        self.assertEqual(main_red.decide_green({3: [G1, G2]}, {G1: True, G2: None}.get), [(3, "close")])
        self.assertEqual(main_red.decide_green({3: [G1, G2]}, {G1: False, G2: None}.get), [(3, "keep")])

    def test_duplicates_after_a_race_close_all_but_the_oldest(self):
        self.assertEqual(main_red.duplicates([{"number": 8}, {"number": 3}, {"number": 5}]), (3, [5, 8]))
        self.assertEqual(main_red.duplicates([{"number": 3}]), (3, []))


class FakeApi:
    """The GitHub API as main_red.run() calls it: GET answers from `gets`
    (path -> JSON value or text), every write recorded in `writes`."""

    def __init__(self, gets):
        self.gets = gets
        self.writes = []

    def get(self, path):
        if path not in self.gets:
            raise main_red.NotFound(path)
        value = self.gets[path]
        if isinstance(value, Answers):
            return value.answers.pop(0)
        return value

    def text(self, path):
        return self.get(path)

    fail_label = False

    def write(self, method, path, fields):
        if self.fail_label and path.endswith("/labels"):
            raise main_red.AlreadyExists(path)
        self.writes.append((method, path, fields))
        if method == "POST" and path.endswith("/issues"):
            return {"number": 21}
        return {}


class Answers:
    """A path that answers differently on each GET, in order."""

    def __init__(self, *answers):
        self.answers = list(answers)


R = "repos/o/r"
BOT = "github-actions[bot]"


def red_gets(open_issues, label=True):
    gets = {
        R + "/actions/runs/7": {
            "id": 7, "conclusion": "failure", "event": "push", "head_branch": "main",
            "head_sha": HEAD, "html_url": RUN_URL, "run_attempt": 1, "name": "kci",
            "path": ".github/workflows/kci.yml",
        },
        R + "/actions/runs/7/attempts/1/jobs?per_page=100": {"jobs": [
            {"id": 70, "name": "build", "conclusion": "failure", "steps": [{"name": "kci run --stage build", "conclusion": "failure"}]},
        ]},
        R + "/actions/jobs/70/logs": fixture("build_action_failed.log"),
        R + "/actions/workflows/kci.yml/runs?branch=main&event=push&status=success&per_page=30": {
            "workflow_runs": [{"head_sha": G1}]},
        R + "/compare/%s...%s?per_page=100&page=1" % (G1, HEAD): {
            "status": "ahead", "total_commits": 1,
            "commits": [{"sha": HEAD, "parents": [{"sha": G1}], "commit": {"message": "Merge pull request #13 from x/y"}}]},
        R + "/commits/%s/pulls" % HEAD: [],
        R + "/issues?labels=main-red&state=open&per_page=100": open_issues,
    }
    if label:
        gets[R + "/labels/main-red"] = {"name": "main-red"}
    return gets


EXPECTED_BODY = (
    "Run: %s\nHead: %s\nLast green: %s\nCulprits: #13\nFailing: komira//tools/build/toolchains:busybox\n"
    "Log: Action failed: komira//tools/build/toolchains:busybox "
    "(komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (download_file busybox)\n" % (RUN_URL, HEAD, G1)
)


class Run(unittest.TestCase):
    def test_red_with_no_open_issue_creates_the_label_and_the_issue(self):
        gets = red_gets([], label=False)
        api = FakeApi(gets)
        main_red.run(api, "o/r", 7, out=open(os.devnull, "w"))
        self.assertEqual(api.writes[0][0:2], ("POST", R + "/labels"))
        self.assertEqual(api.writes[0][2]["name"], "main-red")
        self.assertEqual(
            api.writes[1],
            ("POST", R + "/issues", {"title": "main red: komira//tools/build/toolchains:busybox",
                                     "body": EXPECTED_BODY, "labels": ["main-red"]}),
        )

    def test_red_with_an_open_issue_comments_on_it(self):
        api = FakeApi(red_gets([{"number": 4, "body": "Head: " + G1}]))
        main_red.run(api, "o/r", 7, out=open(os.devnull, "w"))
        self.assertEqual(api.writes, [("POST", R + "/issues/4/comments", {"body": EXPECTED_BODY})])

    def test_a_raced_second_issue_is_closed_as_the_duplicate_of_the_oldest(self):
        gets = red_gets([])
        # Empty when this run looks; after it creates #21, another run's #3 is there too.
        gets[R + "/issues?labels=main-red&state=open&per_page=100"] = Answers([], [{"number": 21}, {"number": 3}])
        api = FakeApi(gets)
        main_red.run(api, "o/r", 7, out=open(os.devnull, "w"))
        self.assertEqual(api.writes[0][0:2], ("POST", R + "/issues"))
        self.assertEqual(api.writes[1:], [
            ("POST", R + "/issues/3/comments", {"body": EXPECTED_BODY}),
            ("POST", R + "/issues/21/comments", {"body": "Duplicate of #3"}),
            ("PATCH", R + "/issues/21", {"state": "closed", "state_reason": "not_planned"}),
        ])

    def test_red_already_fixed_by_a_newer_green_writes_nothing(self):
        gets = red_gets([])
        gets[R + "/actions/workflows/kci.yml/runs?branch=main&event=push&status=success&per_page=30"] = {
            "workflow_runs": [{"head_sha": G2}]}
        gets[R + "/compare/%s...%s?per_page=100&page=1" % (G2, HEAD)] = {"status": "behind", "total_commits": 0, "commits": []}
        api = FakeApi(gets)
        main_red.run(api, "o/r", 7, out=open(os.devnull, "w"))
        self.assertEqual(api.writes, [])

    def test_green_closes_with_the_fixed_comment(self):
        gets = {
            R + "/actions/runs/8": {
                "id": 8, "conclusion": "success", "event": "push", "head_branch": "main",
                "head_sha": G2, "html_url": RUN_URL, "run_attempt": 1, "name": "kci",
            },
            R + "/issues?labels=main-red&state=open&per_page=100": [{"number": 4, "body": "Run: x\nHead: " + HEAD + "\n"}],
            R + "/issues/4/comments?per_page=100": [{"user": {"login": BOT}, "body": "Head: " + G1 + "\n"}],
            R + "/compare/%s...%s?per_page=1&page=1" % (HEAD, G2): {"status": "ahead"},
            R + "/compare/%s...%s?per_page=1&page=1" % (G1, G2): {"status": "ahead"},
        }
        api = FakeApi(gets)
        main_red.run(api, "o/r", 8, out=open(os.devnull, "w"))
        self.assertEqual(api.writes, [
            ("POST", R + "/issues/4/comments", {"body": main_red.fixed_comment(G2, RUN_URL)}),
            ("PATCH", R + "/issues/4", {"state": "closed", "state_reason": "completed"}),
        ])

    def test_green_not_containing_a_red_head_keeps_the_issue(self):
        gets = {
            R + "/actions/runs/8": {
                "id": 8, "conclusion": "success", "event": "push", "head_branch": "main",
                "head_sha": G2, "html_url": RUN_URL, "run_attempt": 2, "name": "kci",
            },
            R + "/issues?labels=main-red&state=open&per_page=100": [{"number": 4, "body": "Head: " + HEAD + "\n"}],
            R + "/issues/4/comments?per_page=100": [],
            R + "/compare/%s...%s?per_page=1&page=1" % (HEAD, G2): {"status": "behind"},
        }
        api = FakeApi(gets)
        main_red.run(api, "o/r", 8, out=open(os.devnull, "w"))
        self.assertEqual(api.writes, [])

    def green_gets(self, comments, compares):
        gets = {
            R + "/actions/runs/8": {
                "id": 8, "conclusion": "success", "event": "push", "head_branch": "main",
                "head_sha": G2, "html_url": RUN_URL, "run_attempt": 1, "name": "kci",
            },
            R + "/issues?labels=main-red&state=open&per_page=100": [
                {"number": 4, "user": {"login": BOT}, "body": "Head: " + HEAD + "\n"}],
            R + "/issues/4/comments?per_page=100": comments,
            R + "/compare/%s...%s?per_page=1&page=1" % (HEAD, G2): {"status": "ahead"},
        }
        for base, status in compares.items():
            gets[R + "/compare/%s...%s?per_page=1&page=1" % (base, G2)] = {"status": status}
        return gets

    CLOSED = [
        ("POST", R + "/issues/4/comments", {"body": "Fixed: main is green at %s (run %s)" % (G2, RUN_URL)}),
        ("PATCH", R + "/issues/4", {"state": "closed", "state_reason": "completed"}),
    ]

    def test_green_ignores_heads_in_comments_by_anyone_but_the_workflow(self):
        # A public comment can say anything: a head main does not contain
        # (`behind`) or one no API knows must not keep the issue open.
        fake = "0f" * 20
        comments = [
            {"user": {"login": "someone"}, "body": "Head: " + G1 + "\n"},
            {"user": {"login": "github-actions"}, "body": "Head: " + fake + "\n"},
        ]
        api = FakeApi(self.green_gets(comments, {G1: "behind"}))
        main_red.run(api, "o/r", 8, out=open(os.devnull, "w"))
        self.assertEqual(api.writes, self.CLOSED)

    def test_green_skips_a_recorded_head_the_api_does_not_know(self):
        fake = "0f" * 20
        api = FakeApi(self.green_gets([{"user": {"login": BOT}, "body": "Head: " + fake + "\n"}], {}))
        main_red.run(api, "o/r", 8, out=open(os.devnull, "w"))
        self.assertEqual(api.writes, self.CLOSED)

    def test_green_skips_a_recorded_head_off_mains_line(self):
        api = FakeApi(self.green_gets([{"user": {"login": BOT}, "body": "Head: " + G1 + "\n"}], {G1: "diverged"}))
        main_red.run(api, "o/r", 8, out=open(os.devnull, "w"))
        self.assertEqual(api.writes, self.CLOSED)

    def test_green_keeps_for_a_workflow_head_it_does_not_contain(self):
        api = FakeApi(self.green_gets([{"user": {"login": BOT}, "body": "Head: " + G1 + "\n"}], {G1: "behind"}))
        main_red.run(api, "o/r", 8, out=open(os.devnull, "w"))
        self.assertEqual(api.writes, [])

    def test_a_rerun_reads_its_own_attempts_jobs(self):
        gets = red_gets([])
        gets[R + "/actions/runs/7"] = dict(gets[R + "/actions/runs/7"], run_attempt=2)
        # Attempt 1 failed elsewhere; attempt 2 is the run that just ended.
        gets[R + "/actions/runs/7/attempts/1/jobs?per_page=100"] = {"jobs": [
            {"id": 69, "name": "gamma", "conclusion": "failure", "steps": [{"name": "publish", "conclusion": "failure"}]}]}
        gets[R + "/actions/runs/7/attempts/2/jobs?per_page=100"] = {"jobs": [
            {"id": 70, "name": "build", "conclusion": "failure", "steps": [{"name": "kci run --stage build", "conclusion": "failure"}]}]}
        gets[R + "/actions/jobs/69/logs"] = "Action failed: //wrong:attempt (cfg)\n"
        api = FakeApi(gets)
        main_red.run(api, "o/r", 7, out=open(os.devnull, "w"))
        self.assertEqual(api.writes[-1][2]["title"], "main red: komira//tools/build/toolchains:busybox")

    def test_a_label_another_run_just_created_is_not_an_error(self):
        api = FakeApi(red_gets([], label=False))
        api.fail_label = True
        main_red.run(api, "o/r", 7, out=open(os.devnull, "w"))
        self.assertEqual(api.writes[-1][0:2], ("POST", R + "/issues"))

    def test_gh_reads_422_already_exists_as_already_exists_without_retrying(self):
        calls = []

        class P:
            returncode = 1
            stdout = '{"message":"Validation Failed","errors":[{"resource":"Label","code":"already_exists","field":"name"}]}'
            stderr = "gh: Validation Failed (HTTP 422)\n"

        def runner(*a, **k):
            calls.append(a)
            return P()

        api = main_red.GhApi(runner=runner, sleep=lambda s: None)
        with self.assertRaises(main_red.AlreadyExists):
            api.write("POST", "repos/o/r/labels", {"name": "main-red"})
        self.assertEqual(len(calls), 1)

    def test_cancelled_writes_nothing_and_reads_nothing_else(self):
        gets = {R + "/actions/runs/9": {"id": 9, "conclusion": "cancelled", "event": "push", "head_branch": "main",
                                        "head_sha": HEAD, "html_url": RUN_URL, "run_attempt": 1, "name": "kci"}}
        api = FakeApi(gets)
        main_red.run(api, "o/r", 9, out=open(os.devnull, "w"))
        self.assertEqual(api.writes, [])

    def test_a_red_with_no_failed_job_names_the_workflow(self):
        gets = red_gets([])
        gets[R + "/actions/runs/7/attempts/1/jobs?per_page=100"] = {"jobs": [
            {"id": 71, "name": "build", "conclusion": "success", "steps": []},
            {"id": 72, "name": "prod", "conclusion": "skipped", "steps": []},
        ]}
        api = FakeApi(gets)
        main_red.run(api, "o/r", 7, out=open(os.devnull, "w"))
        title = api.writes[-1][2]["title"]
        self.assertEqual(title, "main red: workflow kci (no job failed: a job could not start)")


if __name__ == "__main__":
    # Not unittest.main(): the verdict is the exit status alone.
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=1).run(
        unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    )
    sys.stderr.write("test_main_red: %d cases, %d failed\n" % (result.testsRun, len(result.failures) + len(result.errors)))
    sys.exit(0 if result.wasSuccessful() else 1)
