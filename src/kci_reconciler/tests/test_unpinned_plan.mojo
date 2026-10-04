"""Unpinned plan: a plan over an image whose build step has not run yet.

`kci run --plan` may reach a service or job whose `Image` is a step output
(`Image.output { step, name }`) of a build step in the same run that has not
run yet. The plan renders a placeholder in place of the digest. Two things can
go wrong with that placeholder, and each section below checks one of them:

  * §A: it passes for a digest. It must not start with `sha256:`, must say
    NOT-A-DIGEST in words, and must name the step output it stands in for.
  * §B: it is silent. Without a caller-owned record there is no placeholder
    at all: the call refuses, naming the node and the step output. With a
    record, every substitution is listed by kind, node and step output.
  * §C: the empty record reports nothing (the control that keeps §B from
    passing on a record that lists everything).
"""

from std.testing import assert_equal, assert_true, assert_false

from kci_reconciler.unpinned_plan import (
    UNPINNED_KIND_JOB,
    UNPINNED_KIND_SERVICE,
    UNPINNED_PLAN_DIGEST_PREFIX,
    UnpinnedImages,
    is_unpinned_plan_digest,
    unpinned_build_ref,
    unpinned_image_digest,
)


def _raised(kind: String, node_id: String, step: String, name: String) -> String:
    """The refusal text of the no-record call, or "" if it did not raise."""
    try:
        _ = unpinned_image_digest(kind, node_id, step, name)
    except e:
        return String(e)
    return String("")


# =============================================================================
# §A: the placeholder cannot pass for a digest.
# =============================================================================
def test_the_placeholder_is_not_digest_shaped() raises:
    var images = UnpinnedImages()
    var v = unpinned_image_digest(
        UNPINNED_KIND_SERVICE, "api", "build", "api_image", images
    )
    assert_false(v.startswith("sha256:"), "placeholder is digest-shaped: " + v)
    assert_true(v.startswith(UNPINNED_PLAN_DIGEST_PREFIX), v)
    assert_true(v.find("NOT-A-DIGEST") >= 0, "placeholder must say so: " + v)
    assert_true(is_unpinned_plan_digest(v), v)


def test_the_placeholder_names_the_step_output() raises:
    var images = UnpinnedImages()
    var a = unpinned_image_digest(
        UNPINNED_KIND_SERVICE, "api", "build", "api_image", images
    )
    var b = unpinned_image_digest(
        UNPINNED_KIND_JOB, "migrate", "build", "migrate_image", images
    )
    assert_equal(a, UNPINNED_PLAN_DIGEST_PREFIX + "build/api_image")
    assert_equal(unpinned_build_ref("build", "api_image"), "build/api_image")
    # Two step outputs in, two different values out: a placeholder that
    # ignored its argument would pass every check above.
    assert_true(a != b, "the placeholder does not depend on the step output")


def test_the_predicate_recognises_only_placeholders() raises:
    assert_false(is_unpinned_plan_digest("sha256:" + "ab" * 32))
    assert_false(is_unpinned_plan_digest("build/api_image"))
    assert_false(is_unpinned_plan_digest(""))


# =============================================================================
# §B: no record, no placeholder; with a record, every one is listed.
# =============================================================================
def test_without_a_record_the_unpinned_image_is_refused() raises:
    var msg = _raised(UNPINNED_KIND_SERVICE, "api", "build", "api_image")
    assert_true(msg.byte_length() > 0, "an unpinned image was tolerated with no record")
    assert_true(msg.find("'api'") >= 0, "refusal does not name the node: " + msg)
    assert_true(
        msg.find("build/api_image") >= 0,
        "refusal does not name the step output: " + msg,
    )
    assert_true(msg.find(UNPINNED_KIND_SERVICE) >= 0, msg)
    # The refusal never carries the placeholder: nothing a caller could copy.
    assert_false(msg.find(UNPINNED_PLAN_DIGEST_PREFIX) >= 0, msg)


def test_the_record_lists_kind_node_and_step_output() raises:
    var images = UnpinnedImages()
    _ = unpinned_image_digest(
        UNPINNED_KIND_SERVICE, "api", "build", "api_image", images
    )
    _ = unpinned_image_digest(
        UNPINNED_KIND_JOB, "migrate", "images", "migrate_image", images
    )
    assert_equal(images.count(), 2)
    var refs = images.build_refs()
    assert_equal(refs[0], "build/api_image")
    assert_equal(refs[1], "images/migrate_image")
    var rows = images.rendered_rows()
    assert_equal(len(rows), 2)
    assert_equal(
        rows[0],
        "service node 'api': image is step output 'build/api_image', not"
        " built yet (rendered as UNPINNED-NOT-A-DIGEST:build/api_image)",
    )
    assert_equal(
        rows[1],
        "job node 'migrate': image is step output 'images/migrate_image', not"
        " built yet (rendered as UNPINNED-NOT-A-DIGEST:images/migrate_image)",
    )


def test_a_re_record_of_one_node_overwrites() raises:
    """Keyed on (kind, node): a node visited twice is counted once, and a job
    and a service of the same name are two entries."""
    var images = UnpinnedImages()
    _ = unpinned_image_digest(UNPINNED_KIND_SERVICE, "a", "build", "one", images)
    _ = unpinned_image_digest(UNPINNED_KIND_SERVICE, "a", "build", "two", images)
    assert_equal(images.count(), 1)
    assert_equal(images.build_refs()[0], "build/two")
    _ = unpinned_image_digest(UNPINNED_KIND_JOB, "a", "build", "three", images)
    assert_equal(images.count(), 2)


def test_only_service_and_job_have_images() raises:
    var images = UnpinnedImages()
    var refused = False
    try:
        _ = unpinned_image_digest("bucket", "b", "build", "x", images)
    except e:
        refused = String(e).find("bucket") >= 0
    assert_true(refused, "a kind with no image was accepted")
    assert_equal(images.count(), 0)


# =============================================================================
# §C: the control. An empty record reports nothing.
# =============================================================================
def test_an_empty_record_reports_nothing() raises:
    var images = UnpinnedImages()
    assert_equal(images.count(), 0)
    assert_equal(len(images.build_refs()), 0)
    assert_equal(len(images.rendered_rows()), 0)


def main() raises:
    test_the_placeholder_is_not_digest_shaped()
    test_the_placeholder_names_the_step_output()
    test_the_predicate_recognises_only_placeholders()
    test_without_a_record_the_unpinned_image_is_refused()
    test_the_record_lists_kind_node_and_step_output()
    test_a_re_record_of_one_node_overwrites()
    test_only_service_and_job_have_images()
    test_an_empty_record_reports_nothing()
    print("test_unpinned_plan: ALL PASS")
