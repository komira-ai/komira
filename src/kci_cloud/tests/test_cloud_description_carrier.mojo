# =============================================================================
# kci_cloud/tests/test_cloud_description_carrier.mojo
# =============================================================================
#
# A DESCRIPTION CARRIER (an object with a description and no labels: a GCP
# service account, a Scheduler job) holds every label kci writes as lines
# of its description (labels.mojo). What each test proves:
#   * the lines a create writes are the identity, the retention mark and the
#     run-id label, in that order, and read back as labels the standard rule
#     accepts, decoding to the stamp, its retention and its run;
#   * an adoption's lines carry the adoption mark in place of a run id;
#   * EVERY line is read: the retention and the run id come from the second
#     and third lines (a reader of the first line alone fails here);
#   * the description is kci's whole: any other line, an empty line, a mark
#     given twice, a first line that is not an identity, or a value outside
#     the rule reads as not stamped;
#   * a release drops kci's lines and keeps every other;
#   * the length validate checks counts the run-id line of a create and the
#     mark line of an adoption.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from kci_reconciler import Label, OwnerStamp, RETAIN_DELETE, RETAIN_KEEP
from kci_cloud import (
    adopted_by,
    adoption_labels,
    create_labels,
    description_carrier_bytes,
    description_labels,
    description_lines,
    label_problems,
    released_description,
    retain_labels,
    retained_by,
    standard_identity_of,
    standard_label_rule,
    validation_run_of,
)


comptime _RUN = "kit-run-5e0b71"
comptime _IDENTITY = "kci:v1 owner=shop/staging/peer/identity"


def _stamp(run: Optional[String] = None) -> OwnerStamp:
    return OwnerStamp(
        String("shop"), String("staging"), String("peer"), String("identity"), validation_run_id=run
    )


def _adopted_labels(retention: Int) raises -> List[Label]:
    var labels = standard_label_rule(_stamp(String(_RUN)))
    labels.extend(retain_labels(retention))
    labels.extend(adoption_labels(True))
    return labels^


def test_a_create_writes_three_lines_in_order() raises:
    var text = description_lines(create_labels(_stamp(String(_RUN)), RETAIN_DELETE))
    assert_equal(text, String(_IDENTITY) + "\nkci-retention=delete\nkci-run-id=kit-run-5e0b71")
    var none = description_lines(create_labels(_stamp(), RETAIN_KEEP))
    assert_equal(none, String(_IDENTITY) + "\nkci-retention=retain")


def test_every_line_reads_back() raises:
    var labels = description_labels(description_lines(create_labels(_stamp(String(_RUN)), RETAIN_KEEP)))
    assert_equal(len(label_problems(labels)), 0, "the standard rule accepts what a description reads as")
    assert_equal(standard_identity_of(labels), _stamp().identity())
    # The second and third lines: a reader of the first line alone sees
    # neither the retention nor the run.
    assert_true(retained_by(labels), "the retention line is read")
    var run = validation_run_of(labels)
    assert_true(Bool(run), "the run-id line is read")
    assert_equal(run.value(), _RUN)
    assert_false(adopted_by(labels))


def test_an_adoption_carries_the_mark_and_no_run() raises:
    var text = description_lines(_adopted_labels(RETAIN_DELETE))
    assert_equal(text, String(_IDENTITY) + "\nkci-retention=delete\nkci_adopted=true")
    var labels = description_labels(text)
    assert_true(adopted_by(labels), "the mark line is read")
    assert_false(Bool(validation_run_of(labels)), "an adoption writes no run id")
    assert_equal(standard_identity_of(labels), _stamp().identity())


def test_a_nested_resource_reads_back_to_the_same_identity() raises:
    var st = OwnerStamp(String("shop"), String("staging"), String("web/api"), String("identity"))
    var labels = description_labels(description_lines(create_labels(st, RETAIN_DELETE)))
    assert_equal(standard_identity_of(labels), st.identity())
    assert_equal(len(label_problems(labels)), 0)


def test_anything_else_in_the_description_is_not_stamped() raises:
    var good = String(_IDENTITY) + "\nkci-retention=delete"
    assert_true(len(description_labels(good)) > 0)
    assert_equal(len(description_labels(String(""))), 0, "an empty description")
    assert_equal(len(description_labels(good + "\nruns the nightly jobs")), 0, "a line a human wrote")
    assert_equal(len(description_labels(String("runs the nightly jobs\n") + good)), 0, "a first line that is not an identity")
    assert_equal(len(description_labels(good + "\n")), 0, "an empty line")
    assert_equal(len(description_labels(good + "\nkci-retention=retain")), 0, "a mark given twice")
    assert_equal(len(description_labels(good + "\nkci-run-id=Not_Legal")), 0, "a value outside the rule")
    assert_equal(len(description_labels(good + "\nkci_other=true")), 0, "a key that is not one of kci's marks")
    assert_equal(len(description_labels(String("kci:vx owner=shop/staging/peer/identity"))), 0, "a scheme that is not a number")
    assert_equal(len(description_labels(String("kci:v1 owner=shop/staging"))), 0, "an owner with no resource")
    assert_equal(len(description_labels(String("kci:v1 owner=shop/staging/peer_x/identity"))), 0, "a segment holding _")


def test_writing_refuses_what_a_description_cannot_hold() raises:
    var author = create_labels(_stamp(), RETAIN_DELETE)
    author.append(Label(String("team"), String("data")))
    var refused = String("")
    try:
        _ = description_lines(author)
    except e:
        refused = String(e)
    assert_true(refused.find("is not kci's") >= 0, refused)
    var no_mark = standard_label_rule(_stamp())
    refused = String("")
    try:
        _ = description_lines(no_mark)
    except e:
        refused = String(e)
    assert_true(refused.find("no retention mark") >= 0, refused)
    refused = String("")
    try:
        _ = description_lines(retain_labels(RETAIN_DELETE))
    except e:
        refused = String(e)
    assert_true(refused.find("no complete kci identity") >= 0, refused)


def test_a_release_drops_kci_lines_only() raises:
    assert_equal(released_description(description_lines(_adopted_labels(RETAIN_KEEP))), "")
    assert_equal(
        released_description(String(_IDENTITY) + "\nkci-retention=delete\nowned by the data team\nkci_adopted=true"),
        "owned by the data team",
    )
    assert_equal(released_description(String("two\nlines")), "two\nlines")


def test_the_length_validate_checks() raises:
    # 39 + 1 + 20 + 1 + 25: a create under a run writes the run-id line.
    assert_equal(description_carrier_bytes(_stamp(String(_RUN)), RETAIN_DELETE, False), 86)
    # 39 + 1 + 20 + 1 + 16: an adoption writes the mark line, never the run.
    assert_equal(description_carrier_bytes(_stamp(String(_RUN)), RETAIN_DELETE, True), 77)
    # 39 + 1 + 20: a create outside a run.
    assert_equal(description_carrier_bytes(_stamp(), RETAIN_DELETE, False), 60)


def main() raises:
    test_a_create_writes_three_lines_in_order()
    test_every_line_reads_back()
    test_an_adoption_carries_the_mark_and_no_run()
    test_a_nested_resource_reads_back_to_the_same_identity()
    test_anything_else_in_the_description_is_not_stamped()
    test_writing_refuses_what_a_description_cannot_hold()
    test_a_release_drops_kci_lines_only()
    test_the_length_validate_checks()
    print("OK")
