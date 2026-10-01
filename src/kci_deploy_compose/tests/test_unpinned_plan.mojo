"""test_unpinned_plan — THE PLACEHOLDER MUST BE UNUSABLE AS A PIN, AND EVERY
SUBSTITUTION MUST BE RECORDED.

A plan must never silently succeed with a fake digest: a plan that invents a pin
is worse than a plan that refuses, because it reports a graph nobody can apply.

`--allow-unpinned` buys an operator a review of a machine whose artifacts do not
exist. The two ways that can go wrong are both about the VALUE that stands in for
the missing digest:

  1. IT LOOKS LIKE A PIN. Something downstream — a reader keying on `sha256:`, a
     human copying a line out of a rendered graph into an `image { digest: … }`
     block — treats it as real. §A is the falsifier: the placeholder is asserted
     to be rejected by every prefix test a pinned artifact passes, in BOTH
     classes (OCI `sha256:` and content `content-sha256:`).
  2. IT IS INVISIBLE. A substitution happens and nothing downstream can say so,
     which is the silent fake-digest plan in a different spelling. §B and §C are
     the falsifiers: the sink records the artifact CLASS, the NODE and the REF,
     renders one readable row each, and survives being read from a DIFFERENT
     handle than the one that was written (the writer is several frames below
     the reader on the real path).

§D IS THE NON-VACUITY CONTROL. A sink that recorded everything, or a renderer
that emitted a row for the empty case, would pass §B by refusing nothing. So the
empty accumulator is asserted to render ZERO rows and count ZERO — the state that
makes `--allow-unpinned` a NO-OP on a fully pinned bundle rather than a mode
switch that always reports itself.

Pure leaf: struct construction + pure functions. No store, no cloud, no proto, no
UnsafePointer.
"""

from std.testing import assert_equal, assert_true, assert_false

from kci_deploy_compose.compose_api import FROM_BUILD_DIGEST_MARKER_PREFIX
from kci_deploy_compose.unpinned_plan import (
    UNPINNED_KIND_JOB,
    UNPINNED_KIND_SERVICE,
    UNPINNED_KIND_WEB_CONTENT,
    UNPINNED_PLAN_DIGEST_PREFIX,
    UnpinnedRefAccumulator,
    is_unpinned_plan_digest,
    unpinned_plan_digest,
)


# =============================================================================
# §A — THE PLACEHOLDER IS NOT A PIN, MEASURED AGAINST THE REAL PREFIXES.
# =============================================================================
def test_the_placeholder_is_rejected_by_every_pinned_prefix() raises:
    """THE ONE PROPERTY THE WHOLE MODE RESTS ON.

    The two prefixes a PINNED artifact carries are `sha256:` (an OCI
    image digest) and `content-sha256:` (a built web-content tree). If the
    placeholder started with either, every reader that keys on them would treat a
    hole as a pin — and the plan would be reporting a graph nobody can apply,
    which is the failure the flag exists to avoid rather than to cause."""
    var v = unpinned_plan_digest(String("probe_a"))
    assert_false(
        v.startswith("sha256:"),
        String("the unpinned placeholder is OCI-digest-shaped: ") + v,
    )
    assert_false(
        v.startswith("content-sha256:"),
        String("the unpinned placeholder is content-digest-shaped: ") + v,
    )
    # AND IT MUST NOT BE THE MARKER EITHER. Leaving `from_build:<ref>` in
    # place is what the mapper does on the REFUSING path; a plan that emitted it
    # would be indistinguishable from an unresolved manifest that got through.
    assert_false(
        v.startswith(FROM_BUILD_DIGEST_MARKER_PREFIX),
        String("the placeholder is still the raw from_build marker: ") + v,
    )
    # It says so IN WORDS, for the human who reads a rendered diff and has no
    # prefix table in front of them.
    assert_true(
        v.find(String("NOT-A-DIGEST")) >= 0,
        String("the placeholder does not say it is not a digest: ") + v,
    )


def test_the_placeholder_names_the_ref_it_stands_in_for() raises:
    """THE REF RIDES IN THE VALUE. A placeholder that said only "unpinned"
    would leave an operator unable to tell WHICH of a multi-artifact bundle's
    images is missing without cross-referencing a second output."""
    assert_equal(
        unpinned_plan_digest(String("probe_a")),
        UNPINNED_PLAN_DIGEST_PREFIX + String("probe_a"),
    )
    assert_equal(
        unpinned_plan_digest(String("job_probe_b")),
        UNPINNED_PLAN_DIGEST_PREFIX + String("job_probe_b"),
    )
    # THE INVERSION that separates a derivation from a constant: two refs in,
    # two DIFFERENT values out. A placeholder that ignored its argument would
    # satisfy every assertion above and this one alone catches it.
    assert_true(
        unpinned_plan_digest(String("a")) != unpinned_plan_digest(String("b")),
        "the placeholder is a CONSTANT — it does not depend on the ref",
    )


def test_the_predicate_recognises_only_its_own_placeholders() raises:
    """`is_unpinned_plan_digest` is the ONE predicate a consumer that must refuse
    to act on a placeholder keys off, instead of re-spelling the prefix."""
    assert_true(is_unpinned_plan_digest(unpinned_plan_digest(String("x"))))
    assert_false(is_unpinned_plan_digest(String("sha256:" + "ab" * 32)))
    assert_false(
        is_unpinned_plan_digest(String("content-sha256:deadbeef")),
    )
    assert_false(
        is_unpinned_plan_digest(
            FROM_BUILD_DIGEST_MARKER_PREFIX + String("x")
        ),
    )
    assert_false(is_unpinned_plan_digest(String("")))


# =============================================================================
# §B — EVERY SUBSTITUTION IS RECORDED, WITH ITS CLASS AND ITS NODE.
# =============================================================================
def test_the_sink_records_class_node_and_ref() raises:
    var sink = UnpinnedRefAccumulator()
    sink.record(
        UNPINNED_KIND_SERVICE,
        String("probe-a-svc"),
        String("probe_a"),
    )
    sink.record(
        UNPINNED_KIND_JOB, String("job-probe-b-job"), String("job_probe_b")
    )
    sink.record(
        UNPINNED_KIND_WEB_CONTENT,
        String("site-a-web"),
        String("web_content"),
    )
    assert_equal(sink.count(), 3)
    var refs = sink.refs()
    assert_equal(len(refs), 3)
    assert_equal(refs[0], String("probe_a"))
    assert_equal(refs[1], String("job_probe_b"))
    assert_equal(refs[2], String("web_content"))

    # A READABLE ROW, NOT A COUNT AND NOT A HASH. Each row has to carry the
    # three things an operator needs to act: which CLASS of artifact, which NODE
    # it is on, and which `build {}` target to go run.
    var rows = sink.rendered_rows()
    assert_equal(len(rows), 3)
    assert_true(
        rows[0].find(String(UNPINNED_KIND_SERVICE)) >= 0
        and rows[0].find(String("probe-a-svc")) >= 0
        and rows[0].find(String("probe_a")) >= 0,
        String("the service row is not readable: ") + rows[0],
    )
    assert_true(
        rows[1].find(String(UNPINNED_KIND_JOB)) >= 0
        and rows[1].find(String("job-probe-b-job")) >= 0,
        String("the job row is not readable: ") + rows[1],
    )
    # THE CONTENT CLASS IS NAMED "content", not "image", deliberately: its pinned
    # form is `content-sha256:`, and an operator told "unpinned image" about a
    # `dist/` tree goes looking for the wrong build.
    assert_true(
        rows[2].find(String("content")) >= 0,
        String("the web row does not name the content class: ") + rows[2],
    )
    # AND THE ROW CARRIES THE RENDERED VALUE, so the graph the operator is
    # reading and the summary they are reading agree byte-for-byte.
    assert_true(
        rows[0].find(unpinned_plan_digest(String("probe_a"))) >= 0,
        String("the row does not show what the graph renders: ") + rows[0],
    )


def test_a_re_record_of_one_node_overwrites_rather_than_inflating() raises:
    """IDEMPOTENT PER (class, node). A node visited twice by a future mapper
    pass must not double the number an operator reads."""
    var sink = UnpinnedRefAccumulator()
    sink.record(UNPINNED_KIND_SERVICE, String("a-svc"), String("one"))
    sink.record(UNPINNED_KIND_SERVICE, String("a-svc"), String("two"))
    assert_equal(sink.count(), 1)
    assert_equal(sink.refs()[0], String("two"))
    # BUT THE KEY IS (class, node), NOT node ALONE. One logical id may carry a
    # served image AND — in a future composition — a content artifact; collapsing
    # them would hide one of the two.
    sink.record(UNPINNED_KIND_WEB_CONTENT, String("a-svc"), String("three"))
    assert_equal(sink.count(), 2)


# =============================================================================
# §C — THE HANDLE SURVIVES THE FRAME THAT WROTE IT.
# =============================================================================
def test_a_shared_handle_reads_what_another_handle_wrote() raises:
    """THIS IS THE REAL PATH'S SHAPE, NOT AN API FLOURISH. On the live path the
    CLI constructs the sink, `share()`s it into the plan driver, and the WRITER
    is `map_manifest_to_graph` several frames down. If a share did not alias the
    interior, every row would be lost on the return and the plan would exit 0
    over a graph full of placeholders — the exact silent success this whole
    mechanism refuses."""
    var reader = UnpinnedRefAccumulator()
    var writer = reader.share()
    assert_equal(reader.count(), 0)
    writer.record(
        UNPINNED_KIND_SERVICE, String("x-svc"), String("x_image")
    )
    assert_equal(
        reader.count(),
        1,
        "a share() did not alias the interior — the caller reads nothing",
    )
    assert_equal(reader.refs()[0], String("x_image"))


# =============================================================================
# §D — THE NON-VACUITY CONTROL. An empty sink reports EMPTY.
# =============================================================================
def test_an_empty_sink_reports_nothing_and_is_the_no_op_case() raises:
    """WITHOUT THIS, EVERY ASSERTION ABOVE COULD PASS ON A SINK THAT RECORDS
    UNCONDITIONALLY. The empty state is also the operationally important one: it
    is what `--allow-unpinned` produces on a bundle whose refs all resolved, and
    it is what makes the flag a NO-OP there — no rows, no unpinned exit code —
    rather than a mode that always announces itself."""
    var sink = UnpinnedRefAccumulator()
    assert_equal(sink.count(), 0)
    assert_equal(len(sink.refs()), 0)
    assert_equal(len(sink.rendered_rows()), 0)


def main() raises:
    test_the_placeholder_is_rejected_by_every_pinned_prefix()
    test_the_placeholder_names_the_ref_it_stands_in_for()
    test_the_predicate_recognises_only_its_own_placeholders()
    test_the_sink_records_class_node_and_ref()
    test_a_re_record_of_one_node_overwrites_rather_than_inflating()
    test_a_shared_handle_reads_what_another_handle_wrote()
    test_an_empty_sink_reports_nothing_and_is_the_no_op_case()
    print("test_unpinned_plan: ALL PASS")
