# =============================================================================
# test_L5_routing.mojo — (google.api.routing) x-goog-request-params matcher
# =============================================================================
#
# komira_grpc/routing.mojo coverage.
#
# The routing matcher extracts the `x-goog-request-params` header value from a
# request field by matching the field's string value against the proto
# `(google.api.routing)` path template. These tests exercise the two common
# shapes (Cloud Run `{location=*}` single-segment capture + GCS `{bucket=**}`
# whole-value capture), the multi-parameter join, the no-match (send-nothing)
# case, the whole-field fallback, and the percent-encoding.
#
# Coverage:
#   T1   GCS `{bucket=**}` — captures the WHOLE value.
#   T2   Cloud Run `projects/*/locations/{location=*}/**` — single segment.
#   T3   Cloud Run prefix-capture `projects/*/locations/{location=*}` (no /**).
#   T4   No-match — value does not fit the template → None (send nothing).
#   T5   Whole-field fallback — empty template returns the whole value.
#   T6   build_routing_params — single pair, percent-encodes the `/`.
#   T7   build_routing_params — multi pair joins with `&`.
#   T8   build_routing_params — empty pairs → empty string.
#   T9   `{project=projects/*}/**` — prefix capture leaves the tail off.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import build_routing_params, match_path_template


def test_t1_gcs_bucket_whole_value() raises:
    """T1 — GCS `{bucket=**}` captures the whole field value."""
    var v = String("projects/_/buckets/my-bucket")
    var m = match_path_template(v, String("{bucket=**}"))
    assert_true(m.__bool__(), "must match")
    assert_equal(
        m.value(),
        String("projects/_/buckets/my-bucket"),
        "{bucket=**} captures the whole value",
    )


def test_t2_cloudrun_location_segment() raises:
    """T2 — Cloud Run `projects/*/locations/{location=*}/**` captures the
    single location segment after `locations/`."""
    var v = String("projects/p1/locations/us-south1/services/svc-a")
    var m = match_path_template(
        v, String("projects/*/locations/{location=*}/**")
    )
    assert_true(m.__bool__(), "must match")
    assert_equal(m.value(), String("us-south1"), "captures the location segment")


def test_t3_cloudrun_location_no_trailing() raises:
    """T3 — `projects/*/locations/{location=*}` (parent form, no trailing
    `/**`) captures the location when the value ends exactly there."""
    var v = String("projects/proj-foo/locations/europe-west4")
    var m = match_path_template(
        v, String("projects/*/locations/{location=*}")
    )
    assert_true(m.__bool__(), "must match")
    assert_equal(m.value(), String("europe-west4"), "captures the location")


def test_t4_no_match_returns_none() raises:
    """T4 — a value that does not fit the template returns None (the spec
    mandates sending nothing rather than garbage that pollutes routing)."""
    # `{location=*}` requires exactly one segment after `locations/`, but the
    # value has the wrong shape entirely (no `locations/` segment).
    var v = String("organizations/123/foo/bar")
    var m = match_path_template(
        v, String("projects/*/locations/{location=*}/**")
    )
    assert_false(m.__bool__(), "no match → None")


def test_t5_whole_field_fallback() raises:
    """T5 — an EMPTY template is the whole-field fallback: the whole value is
    returned unconditionally (the key is the field name, set by the emitter)."""
    var v = String("source-bucket-name")
    var m = match_path_template(v, String(""))
    assert_true(m.__bool__(), "fallback always matches")
    assert_equal(m.value(), String("source-bucket-name"), "whole value")


def test_t6_build_params_single_percent_encodes() raises:
    """T6 — build_routing_params percent-encodes the value's `/` to `%2F`."""
    var pairs = List[Tuple[StaticString, String]]()
    pairs.append((StaticString("bucket"), String("projects/_/buckets/b")))
    var hdr = build_routing_params(pairs)
    assert_equal(
        hdr,
        String("bucket=projects%2F_%2Fbuckets%2Fb"),
        "the `/` is percent-encoded; the key is unreserved",
    )


def test_t7_build_params_multi_join() raises:
    """T7 — multiple pairs join with `&`, each percent-encoded."""
    var pairs = List[Tuple[StaticString, String]]()
    pairs.append((StaticString("project"), String("projects/proj-foo")))
    pairs.append((StaticString("location"), String("us-south1")))
    var hdr = build_routing_params(pairs)
    assert_equal(
        hdr,
        String("project=projects%2Fproj-foo&location=us-south1"),
        "pairs join with `&`",
    )


def test_t8_build_params_empty() raises:
    """T8 — empty pairs → empty string (the emitter then skips the header)."""
    var pairs = List[Tuple[StaticString, String]]()
    var hdr = build_routing_params(pairs)
    assert_equal(hdr, String(""), "no pairs → empty header")


def test_t9_prefix_capture_leaves_tail() raises:
    """T9 — `{project=projects/*}/**` captures only the `projects/<p>` prefix,
    leaving the trailing segments off the captured value."""
    var v = String("projects/proj-foo/instances/inst-bar/tables/t")
    var m = match_path_template(v, String("{project=projects/*}/**"))
    assert_true(m.__bool__(), "must match")
    assert_equal(
        m.value(),
        String("projects/proj-foo"),
        "captures only the projects/<p> prefix",
    )


def test_t10_build_params_duplicate_key_last_wins() raises:
    """T10 (regression) — when two routing_parameters resolve to the SAME key
    (GCS CreateBucket: `parent` and `bucket.project` both key `project`),
    build_routing_params de-duplicates with LAST-match-wins (google.api.routing
    semantics), NOT emitting a duplicate-key header. Emitting both keys triggers a
    grpc:3 'The x-goog-request-params metadata has duplicate entries for the
    key project'. The LAST value (the owning bucket.project) survives."""
    var pairs = List[Tuple[StaticString, String]]()
    # parent="projects/_" first, then bucket.project="projects/proj-foo" (the proto
    # routing order for CreateBucket) — both key `project`.
    pairs.append((StaticString("project"), String("projects/_")))
    pairs.append((StaticString("project"), String("projects/proj-foo")))
    var hdr = build_routing_params(pairs)
    assert_equal(
        hdr,
        String("project=projects%2Fproj-foo"),
        "duplicate key collapses to ONE entry; the LAST value wins",
    )


def test_t11_gcs_bucket_iam_routing_key() raises:
    """T11 (regression) — the GCS bucket IAM-policy routing header. Every IAM-policy
    host routes on `resource=<full-name>` EXCEPT storage.googleapis.com, which is the
    ONE exception that routes on key `bucket` with the FULL `projects/_/buckets/{id}`
    value. GCS rejects grpc:3 unless the
    header bucket matches the request resource — so the key MUST be `bucket` and the
    value the full resource path, percent-encoded."""
    var pairs = List[Tuple[StaticString, String]]()
    pairs.append(
        (StaticString("bucket"), String("projects/_/buckets/my-bkt"))
    )
    var hdr = build_routing_params(pairs)
    assert_equal(
        hdr,
        String("bucket=projects%2F_%2Fbuckets%2Fmy-bkt"),
        "GCS IAM routing key is `bucket`; value is the full percent-encoded path",
    )


def main() raises:
    test_t1_gcs_bucket_whole_value()
    test_t2_cloudrun_location_segment()
    test_t3_cloudrun_location_no_trailing()
    test_t4_no_match_returns_none()
    test_t5_whole_field_fallback()
    test_t6_build_params_single_percent_encodes()
    test_t7_build_params_multi_join()
    test_t8_build_params_empty()
    test_t9_prefix_capture_leaves_tail()
    test_t10_build_params_duplicate_key_last_wins()
    test_t11_gcs_bucket_iam_routing_key()
    print("test_L5_routing: 11/11 PASS")
