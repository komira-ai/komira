# =============================================================================
# tests/test_boot_bundle_location.mojo — the falsifiers for WHERE the boot
#   bundle lives (bucket / key / URL).
# =============================================================================
#
# ⛔ WHAT FAILS IF THIS FILE IS WRONG, AND WHY IT IS NOT A CRASH. Three programs
# have to agree on one string and none of them links against the others: an
# operator publish step WRITES an object, a placement conformer RENDERS a boot
# script that FETCHES it, and a VM runs that script. Every disagreement in this
# file produces the same observable: a VM that boots, 404s on the loader fetch,
# runs nothing, heartbeats nothing, and bills by the hour — the failure the whole
# `komira_pod_boot` package exists to make unspellable.
#
# The assertions are about the DERIVATION, not behaviour:
#   §1 the bucket carries the PLACEMENT REGION and cannot be named without one
#      (a bucket name with no region cannot disagree with the region a VM is
#      placed in, so the VM silently fetches cross-region);
#   §2 the key is a pure function of the CONTENT DIGEST, and refuses anything
#      that is not one — a non-content-addressed key publishes and fetches fine
#      and silently lets two bundles share one address;
#   §3 the URL is one of exactly the two schemes the two renderers dispatch on;
#   §4 the joint property: the derived URL is a value BOTH renderers accept and
#      embed verbatim. This is the assertion no single-side test can make.
#
# FARM lane: pure String in / String out. No socket, no process, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_pod_boot.boot_bundle_location import (
    BOOT_BUNDLE_SCHEME_GS,
    BOOT_BUNDLE_SCHEME_S3,
    BOOT_BUNDLE_BUCKET_INFIX,
    BOOT_BUNDLE_KEY_PREFIX,
    BOOT_BUNDLE_BASENAME,
    PUBLISHED_BOOT_BUNDLE_URL_PREFIX,
    boot_bundle_bucket,
    boot_bundle_key,
    boot_bundle_url,
)

comptime _D1: String = (
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
)
comptime _D2: String = (
    "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
)


# =============================================================================
# §1 — THE BUCKET CARRIES THE PLACEMENT REGION.
# =============================================================================
def test_the_bucket_name_CARRIES_the_placement_region() raises:
    """Mutant: `the region is dropped from the bucket name` -> RED here.

    Two different placement regions must produce two DIFFERENT buckets. A
    derivation that ignores its `region` argument compiles, returns a real bucket
    name, and reintroduces the cross-region boot fetch it was written to remove
    — with nothing to see, because the name it returns is a name that works."""
    var central = boot_bundle_bucket(String("example-project"), String("us-central1"))
    var south = boot_bundle_bucket(String("example-project"), String("us-south1"))
    assert_true(
        central.find(String("us-central1")) >= 0,
        "the bucket name states the region it serves",
    )
    assert_true(
        central != south,
        "two placement regions must not resolve to ONE boot-artifact bucket —"
        " that is the cross-region fetch this derivation removes",
    )
    assert_equal(
        central,
        String("example-project-") + BOOT_BUNDLE_BUCKET_INFIX + String("-us-central1"),
    )


def test_an_EMPTY_region_is_REFUSED_and_never_defaulted() raises:
    """Mutant: `an empty region falls back to a default/home region` -> RED.

    ★ THIS IS THE DEFECT. A bucket whose name says nothing about a region lets
    a placement in another region read its loader cross-region, and nothing
    anywhere can notice. A default would restore exactly that: a name that
    works and serves the wrong region."""
    var raised = False
    try:
        _ = boot_bundle_bucket(String("example-project"), String(""))
    except e:
        raised = True
        assert_true(
            String(e).find(String("REGION")) >= 0,
            "the refusal NAMES the missing region",
        )
    assert_true(raised, "an unregioned boot-artifact bucket is REFUSED")


def test_an_EMPTY_account_is_REFUSED() raises:
    """Mutant: `an empty account_ref yields a bare `-pod-loader-<region>``
    -> RED.

    Without the account segment every environment's boot artifact collapses onto
    one globally-unique bucket name, so two environments would publish over
    each other's loader.

    ⚠ THE MESSAGE IS ASSERTED, NOT JUST THE RAISE. With the account guard
    deleted, an empty account still raises — because `_is_bucket_safe("")` is
    False and the ALPHABET check fires. Asserting only the raise would prove a
    refusal that a DIFFERENT guard produces, and that refusal says the name has
    illegal characters rather than that the account is missing."""
    var raised = False
    try:
        _ = boot_bundle_bucket(String(""), String("us-central1"))
    except e:
        raised = True
        assert_true(
            String(e).find(String("account reference")) >= 0,
            "the refusal NAMES the missing account, not a character-class"
            " complaint from a downstream guard",
        )
    assert_true(raised, "a boot-artifact bucket with no account is REFUSED")


def test_a_bucket_name_ILLEGAL_ON_EITHER_CLOUD_is_REFUSED() raises:
    """Mutant: `the bucket alphabet check is removed` -> RED here.

    The SAME derivation names the bucket on GCS and on S3, so it must produce a
    name legal on both. An uppercase or dotted segment is accepted by neither
    (and a dotted S3 name additionally breaks virtual-hosted-style TLS) — caught
    here it is a derivation error, caught live it is a failed create inside a
    deploy."""
    var raised_upper = False
    try:
        _ = boot_bundle_bucket(String("Example-Project"), String("us-central1"))
    except:
        raised_upper = True
    assert_true(raised_upper, "an uppercase account segment is REFUSED")

    var raised_dot = False
    try:
        _ = boot_bundle_bucket(String("example.project"), String("us-central1"))
    except:
        raised_dot = True
    assert_true(raised_dot, "a dotted account segment is REFUSED")


# =============================================================================
# §2 — THE KEY IS THE CONTENT DIGEST.
# =============================================================================
def test_the_key_is_a_PURE_FUNCTION_of_the_content_digest() raises:
    """Mutant: `the digest is dropped from the key` -> RED here.

    Two different bundles must never share a key. A key that omits the digest
    (say `pod-loader/bootstrap_bundle.tar.gz`) publishes, fetches, and quietly
    makes every publish overwrite the last one — so a VM placed with a pinned URL
    can boot code that is not the code that URL was pinned to."""
    var k1 = boot_bundle_key(_D1)
    var k2 = boot_bundle_key(_D2)
    assert_true(k1 != k2, "different content -> different key")
    assert_true(k1.find(_D1) >= 0, "the key CONTAINS its content digest")
    assert_equal(
        k1,
        BOOT_BUNDLE_KEY_PREFIX + String("/") + _D1 + String("/")
        + BOOT_BUNDLE_BASENAME,
    )
    # Determinism: the SAME digest twice is the SAME key (what makes a
    # republication a no-op rather than a second object).
    assert_equal(k1, boot_bundle_key(_D1))


def test_the_key_ENDS_in_a_real_tarball_name() raises:
    """Mutant: `the basename becomes an opaque content-hash leaf` -> RED.

    The boot script saves the fetched object to a file and runs `tar -xzf` on
    it, and an operator reading a bucket listing has to be able to tell what the
    object is. This is also why the boot bundle is not stored through the generic
    `ContentAddressedBlobStore`, whose keys end `.blob`."""
    assert_true(
        boot_bundle_key(_D1).endswith(String(".tar.gz")),
        "the published object is named for what it is",
    )


def test_a_NON_DIGEST_key_input_is_REFUSED() raises:
    """Mutant: `the digest shape check is removed` -> RED here.

    A short, uppercase or non-hex 'digest' still yields a syntactically valid
    key; the object publishes and fetches. What is lost is silent — the key is
    no longer the content, so republishing DIFFERENT bytes can reuse it."""
    var cases = List[String]()
    cases.append(String(""))
    cases.append(String("deadbeef"))  # too short
    cases.append(_D1.upper())  # uppercase hex: a second rendering recipe
    cases.append(String("z") + String(_D1[byte=1:]))  # 64 chars, not hex
    for i in range(len(cases)):
        var raised = False
        try:
            _ = boot_bundle_key(cases[i])
        except:
            raised = True
        assert_true(
            raised,
            String("a non-SHA256 boot-bundle key input is REFUSED: '")
            + cases[i]
            + String("'"),
        )


# =============================================================================
# §3 — THE URL IS ONE OF THE TWO SCHEMES THE RENDERERS DISPATCH ON.
# =============================================================================
def test_the_url_renders_both_cloud_schemes() raises:
    assert_equal(
        boot_bundle_url(
            BOOT_BUNDLE_SCHEME_GS, String("b"), String("pod-loader/x")
        ),
        String("gs://b/pod-loader/x"),
    )
    assert_equal(
        boot_bundle_url(
            BOOT_BUNDLE_SCHEME_S3, String("b"), String("pod-loader/x")
        ),
        String("s3://b/pod-loader/x"),
    )
    assert_true(
        BOOT_BUNDLE_SCHEME_GS != BOOT_BUNDLE_SCHEME_S3,
        "the two schemes are distinct",
    )


def test_a_THIRD_scheme_is_REFUSED() raises:
    """Mutant: `the scheme allow-list is removed` -> RED here.

    `Ec2VmPodManager.build_vm_bootstrap` dispatches `s3://*` to `aws s3 cp` and
    EVERYTHING ELSE to `curl`; the GCE startup-script renderer does the same for
    `gs://`.
    So an `https://`-or-other URL is not a download that fails loudly — it is a
    `curl` of a string on a machine that then has nothing to run."""
    var cases = List[String]()
    cases.append(String("https"))
    cases.append(String("file"))
    cases.append(String("GS"))
    cases.append(String(""))
    for i in range(len(cases)):
        var raised = False
        try:
            _ = boot_bundle_url(cases[i], String("b"), String("k"))
        except:
            raised = True
        assert_true(
            raised,
            String("scheme '") + cases[i] + String("' is REFUSED"),
        )


def test_an_EMPTY_bucket_or_key_is_REFUSED() raises:
    """Mutant: `the empty bucket/key guard is removed` -> RED here. `gs:///k` and
    `gs://b/` are both well-formed strings and both are a guaranteed 404 at
    boot."""
    var raised_b = False
    try:
        _ = boot_bundle_url(BOOT_BUNDLE_SCHEME_GS, String(""), String("k"))
    except:
        raised_b = True
    assert_true(raised_b, "an empty bucket is REFUSED")
    var raised_k = False
    try:
        _ = boot_bundle_url(BOOT_BUNDLE_SCHEME_GS, String("b"), String(""))
    except:
        raised_k = True
    assert_true(raised_k, "an empty key is REFUSED")


def test_the_published_url_marker_is_a_PREFIX_SAFE_contract_line() raises:
    """The publish step prints exactly one machine-parsed line. It must end in
    `=` so a reader can split on the first `=` and take the remainder verbatim,
    and it must not be a prefix of some other marker."""
    assert_true(
        PUBLISHED_BOOT_BUNDLE_URL_PREFIX.endswith(String("=")),
        "the marker ends in '=' so the value is the rest of the line",
    )
    assert_true(
        PUBLISHED_BOOT_BUNDLE_URL_PREFIX.find(String(" ")) < 0,
        "the marker carries no whitespace",
    )


# =============================================================================
# §4 — THE JOINT PROPERTY. A derived URL is a value a boot script can carry.
# =============================================================================
def test_the_derived_url_is_SHELL_SAFE_and_fetchable_by_scheme_dispatch() raises:
    """Mutant: `the bucket/key alphabets are widened to allow a space or a
    quote` -> RED here.

    Both renderers embed this value into a shell script via `sh_quote`. The
    derivation must not be able to produce a value carrying a byte that makes
    the fetch ambiguous, and — the property the renderers actually branch on —
    the URL must START with its scheme marker so `case "$URL" in s3://*)` and
    the gs:// arm select the right transport."""
    var bucket = boot_bundle_bucket(String("example-project"), String("us-central1"))
    var url = boot_bundle_url(
        BOOT_BUNDLE_SCHEME_GS, bucket, boot_bundle_key(_D1)
    )
    assert_true(
        url.startswith(BOOT_BUNDLE_SCHEME_GS + String("://")),
        "the renderer's scheme dispatch matches on the URL prefix",
    )
    var b = url.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        assert_true(
            c > UInt8(0x20) and c < UInt8(0x7F),
            "a derived boot-bundle URL is printable ASCII with no whitespace",
        )
        assert_false(
            c == UInt8(0x27) or c == UInt8(0x22) or c == UInt8(0x24),
            "a derived boot-bundle URL carries no quote or $ metacharacter",
        )


def main() raises:
    print("=== test_boot_bundle_location ===")
    test_the_bucket_name_CARRIES_the_placement_region()
    test_an_EMPTY_region_is_REFUSED_and_never_defaulted()
    test_an_EMPTY_account_is_REFUSED()
    test_a_bucket_name_ILLEGAL_ON_EITHER_CLOUD_is_REFUSED()
    test_the_key_is_a_PURE_FUNCTION_of_the_content_digest()
    test_the_key_ENDS_in_a_real_tarball_name()
    test_a_NON_DIGEST_key_input_is_REFUSED()
    test_the_url_renders_both_cloud_schemes()
    test_a_THIRD_scheme_is_REFUSED()
    test_an_EMPTY_bucket_or_key_is_REFUSED()
    test_the_published_url_marker_is_a_PREFIX_SAFE_contract_line()
    test_the_derived_url_is_SHELL_SAFE_and_fetchable_by_scheme_dispatch()
    print(
        "PASS test_boot_bundle_location: the bucket carries the PLACEMENT"
        " region (and refuses to be named without one), the key is the content"
        " digest (and refuses anything that is not one), the URL is one of the"
        " two schemes both renderers dispatch on, and a derived URL is"
        " shell-safe end to end"
    )
