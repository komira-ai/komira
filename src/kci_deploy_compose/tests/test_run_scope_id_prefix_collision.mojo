# =============================================================================
# kci_deploy_compose/tests/test_run_scope_id_prefix_collision.mojo —
#   ONE RUN ID MAY BE A PROPER PREFIX OF ANOTHER. An unanchored substring test
#   in `carries()` would make run `abc1`'s teardown guard report run `abc12`'s
#   graph as ENTIRELY ITS OWN, and `kci delete --run-id abc1` would delete it.
# =============================================================================
#
# ── WHY THIS FILE IS SEPARATE FROM `test_run_scope.mojo` ─────────────────────
# An isolation assertion over unrelated ids, e.g.
#
#     var s = RunScope.of(String("conf7x9q"))
#     assert_false(s.carries(String("canary-run-other1")),
#                  "does not carry another run's")
#
# IS VACUOUS FOR THE CASE THAT MATTERS: `other1` is not a prefix-extension of
# `conf7x9q`, so the fixture could never collide under ANY substring
# implementation. The assertion is satisfied by the string being unrelated, not
# by the predicate being correct — the fixture is chosen so that the dangerous
# relation is absent.
#
# ── THE MECHANISM, EXACTLY ──────────────────────────────────────────────────
#   `RunScope.token()`   -> `"-run-" + run_id`
#   `validate_run_id`     -> lowercase [a-z0-9], length 4..12    VARIABLE-LENGTH
#
# Variable length is what makes the collision REACHABLE rather than theoretical:
# `abc1` (4) and `abc12` (5) are both valid run ids, and
#
#     "canary-run-abc12-svc".__contains__("-run-abc1")   ==   True
#
# so an unanchored predicate lets run `abc1` claim run `abc12`'s service.
# Nothing in `validate_run_id` — nor anywhere else — refuses a run id that
# extends a live one, and nothing could: the ids are minted by callers (a shell
# `mint_run_id`, a CI job id) that cannot see each other.
#
# ── THE BLAST RADIUS IS THE TEARDOWN GUARD, NOT A COSMETIC PREDICATE ─────────
# `run_scope_violations` is the ONLY thing standing between `kci delete --run-id`
# and a delete, and its own docstring states the contract:
#
#     "EMPTY means the graph is entirely this run's, and therefore that reaping
#      it in reverse cannot touch anything else."
#
# Under the collision it would return EMPTY for a graph that is another run's —
# a teardown reaching a NON-run-scoped resource, through the guard rather than
# around it.
#
# THE LEAK-DETECTOR RECIPE IN `run_scope`'s HEADER IS ANCHORED
# (`--filter="name~-run-<id>$"`), hence collision-free; the in-tool predicate
# that gates the actual delete must agree with it.
#
# ── WHAT EACH SECTION PINS ──────────────────────────────────────────────────
#   §1 THE PREDICATE  — `carries()` with a POSITIVE CONTROL beside every
#      negative, so "does not carry" cannot pass by rejecting everything.
#   §2 THE GUARD      — `run_scope_violations` over a foreign graph, plus the
#      NO-OP CONTROL (the same graph under its OWN scope must be violation-free,
#      which is what proves the fixture is a legal graph and not merely broken).
#   §3 EXACT SETS     — three runs in one manifest; the violation set for run A
#      is compared as a SET to the exact expected names, never by substring
#      presence.
#
# Pure value transforms — no store, no cloud, no UnsafePointer.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_deploy_compose.run_scope import (
    RunScope,
    validate_run_id,
    run_scope_violations,
)

from kci_manifest_proto.full_manifest import (
    FullManifest,
    ResourceNode,
    ResourceKind,
    Retention,
    IamRoleSpec,
)


# The two run ids the whole file turns on. `EXT` extends `BASE` by one byte, and
# both are valid — asserted in §1 rather than assumed, because if a future
# `validate_run_id` ever refuses one of them the collision becomes
# unconstructible and every assertion below would pass VACUOUSLY.
comptime BASE: String = "abc1"
comptime EXT: String = "abc12"


def _iam_node(var logical_id: String) raises -> ResourceNode:
    """An IAM_ROLE node with a caller-chosen logical id — the smallest node
    `run_scope_violations` will check a name on."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_IAM_ROLE),
        List[String](),
        Retention(Retention.RETENTION_DELETE),
        8,
        None, None, None, None, None, None, None,
        Optional[IamRoleSpec](IamRoleSpec()),
        None, None, None, None, None, None, None, None, None, None, None,
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


# =============================================================================
# §1 — THE PREDICATE. Every negative has a positive control beside it.
# =============================================================================
def test_both_run_ids_are_valid_so_the_collision_is_constructible() raises:
    """THE ANTI-VACUITY GUARD FOR THIS WHOLE FILE. If either id stopped being
    a legal run id, the collision could not be built and every assertion below
    would pass for the wrong reason."""
    assert_equal(
        validate_run_id(BASE),
        String(""),
        "the base run id must be valid — else §2/§3 are vacuous",
    )
    assert_equal(
        validate_run_id(EXT),
        String(""),
        "the extending run id must be valid — else the collision is fiction",
    )
    # And the relation that makes this file necessary: one is a proper prefix of
    # the other. Asserted, so a future rename of the constants cannot silently
    # destroy the property the file is about.
    assert_true(
        EXT.find(BASE) == 0 and EXT.byte_length() > BASE.byte_length(),
        "EXT must be a PROPER prefix-extension of BASE",
    )


def test_carries_accepts_its_own_names() raises:
    """THE POSITIVE CONTROL. Without it, a `carries()` that returned False
    unconditionally would satisfy every other assertion in this file."""
    var a = RunScope.of(BASE)
    assert_true(
        a.carries(String("canary-run-abc1")),
        "carries its own bare scoped name",
    )
    assert_true(
        a.carries(String("canary-run-abc1-svc")),
        "carries its own name under a compose_api suffix (-svc)",
    )
    assert_true(
        a.carries(String("canary-run-abc1-role")),
        "carries its own name under a compose_api suffix (-role)",
    )


def test_carries_rejects_a_run_id_that_EXTENDS_it() raises:
    """THE BUG CLASS. `-run-abc1` is a substring of `-run-abc12`, so an unanchored
    `__contains__` claims run `abc12`'s every resource for run `abc1`."""
    var a = RunScope.of(BASE)
    assert_false(
        a.carries(String("canary-run-abc12")),
        "run abc1 must NOT claim run abc12's bare scoped name",
    )
    assert_false(
        a.carries(String("canary-run-abc12-svc")),
        "run abc1 must NOT claim run abc12's service",
    )
    assert_false(
        a.carries(String("canary-run-abc12-role")),
        "run abc1 must NOT claim run abc12's service account",
    )


def test_carries_rejects_in_the_other_direction_too() raises:
    """The symmetric half. This direction holds even under `__contains__` (a
    longer token cannot sit inside a shorter name), and it is asserted so a fix
    that merely swaps the comparison operands cannot pass §1."""
    var b = RunScope.of(EXT)
    assert_false(
        b.carries(String("canary-run-abc1-svc")),
        "run abc12 must not claim run abc1's service",
    )
    assert_true(
        b.carries(String("canary-run-abc12-svc")),
        "positive control for the extending run's own name",
    )


def test_carries_still_rejects_an_unscoped_name() raises:
    """Part of the predicate contract — a standing, unscoped resource belongs to
    no run."""
    var a = RunScope.of(BASE)
    assert_false(a.carries(String("canary")), "an unscoped name is nobody's")
    assert_false(
        a.carries(String("app-b-role")),
        "a standing identity is nobody's",
    )


# =============================================================================
# §2 — THE GUARD. The predicate is only interesting because this uses it.
# =============================================================================
def test_violations_reports_the_extending_runs_graph_as_foreign() raises:
    """THE ONE THAT MATTERS. `run_scope_violations` is what `kci delete
    --run-id` consults before deleting anything, and EMPTY means 'reaping this
    graph cannot touch anything else'. Run `abc12`'s graph must NOT read empty
    under run `abc1`'s scope."""
    var a = RunScope.of(BASE)
    var nodes = List[ResourceNode]()
    nodes.append(_iam_node(String("canary-run-abc12-role")))
    var m = FullManifest(String("env-a"), String(""), nodes^)

    var v = run_scope_violations(m, a)
    assert_equal(
        len(v),
        1,
        "run abc12's node must be reported foreign to run abc1 — an EMPTY"
        " result here is the delete going ahead",
    )
    assert_true(
        v[0].__contains__(String("canary-run-abc12-role")),
        "the violation must NAME the resource that would have been deleted",
    )


def test_the_NOOP_CONTROL_that_same_graph_under_its_own_scope() raises:
    """THE NO-OP CONTROL. The §2 fixture must be a LEGAL graph, not merely a
    malformed one — otherwise the violation above would prove nothing about the
    prefix relation. Under its OWN run's scope the identical manifest must be
    violation-free."""
    var b = RunScope.of(EXT)
    var nodes = List[ResourceNode]()
    nodes.append(_iam_node(String("canary-run-abc12-role")))
    var m = FullManifest(String("env-a"), String(""), nodes^)

    assert_equal(
        len(run_scope_violations(m, b)),
        0,
        "the SAME graph is clean under its own scope — so §2's violation is"
        " about the prefix relation and not about a broken fixture",
    )


# =============================================================================
# §3 — EXACT SETS. Never substring presence.
# =============================================================================
def test_three_runs_exact_violation_set() raises:
    """Three runs' nodes in one manifest, checked under run A. The expected
    violations are compared as an EXACT SET — a substring/count check would be
    satisfied by a checker that reported the right NUMBER of wrong names."""
    var a = RunScope.of(BASE)
    var nodes = List[ResourceNode]()
    # run A's own — must NOT be reported.
    nodes.append(_iam_node(String("canary-run-abc1-role")))
    nodes.append(_iam_node(String("canary-run-abc1-svc")))
    # run B's (the prefix-extension) — must BOTH be reported.
    nodes.append(_iam_node(String("canary-run-abc12-role")))
    nodes.append(_iam_node(String("canary-run-abc12-svc")))
    # a third, unrelated run — must be reported (the ordinary case).
    nodes.append(_iam_node(String("canary-run-zzz9-role")))
    var m = FullManifest(String("env-a"), String(""), nodes^)

    var v = run_scope_violations(m, a)

    # EXACT: every expected name appears exactly once, and nothing else does.
    var expected = List[String]()
    expected.append(String("canary-run-abc12-role"))
    expected.append(String("canary-run-abc12-svc"))
    expected.append(String("canary-run-zzz9-role"))

    assert_equal(
        len(v),
        len(expected),
        "the violation set must be exactly the three foreign nodes — no more"
        " (run A's own leaking in) and no fewer (a foreign node going unseen)",
    )
    for i in range(len(expected)):
        var found = 0
        for j in range(len(v)):
            if v[j].__contains__(expected[i]):
                found += 1
        assert_equal(
            found,
            1,
            String("expected exactly one violation naming ") + expected[i],
        )
    # And the other direction of the set equality: run A's OWN names must not
    # appear in ANY violation string. Without this the assertion above is one
    # half of a set comparison.
    for j in range(len(v)):
        assert_false(
            v[j].__contains__(String("canary-run-abc1-role")),
            "run A's own role must never be reported foreign to itself",
        )
        assert_false(
            v[j].__contains__(String("canary-run-abc1-svc")),
            "run A's own service must never be reported foreign to itself",
        )


# =============================================================================
# §4 — THE SECOND CONSEQUENCE. `scoped()` consults `carries()`, so an anchoring
#      defect would make one run ADOPT another run's name instead of scoping it.
# =============================================================================
def test_scoped_does_not_adopt_an_extending_runs_name() raises:
    """`scoped()` returns `name` UNCHANGED when `carries(name)` is true — that is
    its idempotence rule. Under an unanchored predicate, run `abc1` asked to
    scope a name already carrying run `abc12`'s token would judge it "already
    mine" and return it VERBATIM. `scope_bundle` would then hand run abc1 an
    intent naming run abc12's resources, and every downstream check would agree
    it is fine because the SAME predicate answers all of them.

    ASSERTED SEPARATELY BECAUSE THE CONSEQUENCE DIFFERS FROM §2's: §2 is a
    teardown DELETING a foreign resource; this is a compose ADOPTING a foreign
    name."""
    var a = RunScope.of(BASE)
    var foreign = String("canary-run-abc12")
    var got = a.scoped(foreign)
    assert_true(
        got != foreign,
        "run abc1 must not return run abc12's name unchanged as 'already mine'",
    )
    assert_true(
        a.carries(got),
        "and whatever it returns must genuinely be run abc1's",
    )
    # THE IDEMPOTENCE CONTROL. The anchoring must not break the property
    # property `scoped` exists for — scoping run A's OWN name twice is a no-op.
    var mine = a.scoped(String("canary"))
    assert_equal(mine, String("canary-run-abc1"), "scoped once")
    assert_equal(a.scoped(mine), mine, "scoping is still idempotent")


def main() raises:
    test_both_run_ids_are_valid_so_the_collision_is_constructible()
    test_carries_accepts_its_own_names()
    test_carries_rejects_a_run_id_that_EXTENDS_it()
    test_carries_rejects_in_the_other_direction_too()
    test_carries_still_rejects_an_unscoped_name()
    test_violations_reports_the_extending_runs_graph_as_foreign()
    test_the_NOOP_CONTROL_that_same_graph_under_its_own_scope()
    test_three_runs_exact_violation_set()
    test_scoped_does_not_adopt_an_extending_runs_name()
    print("test_run_scope_id_prefix_collision: ALL PASS")
