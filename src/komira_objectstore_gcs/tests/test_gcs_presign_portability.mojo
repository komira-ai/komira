# =============================================================================
# komira_objectstore_gcs/tests/test_gcs_presign_portability.mojo
# =============================================================================
#
# GcsV4Signer as an `ObjectUrlSigner`: the GCS half of the presign
# portability gates. komira_gcp_core's test_v4_sign_conformance already holds
# the algorithm to Google's published vectors; this file holds the CONFORMER
# to the seam's contract, and the composition to the algorithm.
#
# Hermetic: the clock is a parameter (a fixed or a stepping clock, never the
# wall clock), and the key is Google's published inactive dummy service
# account, read from the pinned conformance archive staged at conformance/.
#
#   GATE 1  one generic `_mint[S: ObjectUrlSigner]` mints with the GCS signer;
#           it would not compile if the conformer did not satisfy the seam.
#   GATE 2  each verb is scoped: download is GET, upload is PUT, and the two
#           URLs differ (the verb is inside the signature).
#   GATE 3  GCS requires no client header on either verb.
#   GATE 4  the expiry is the clock's instant plus the TTL, and the clock is
#           read exactly once per mint.
#   GATE 5  the codebase's TTL ceiling binds (below GCS's own 7 days) and
#           refuses rather than clamps; a refused mint reads no clock.
#   GATE 6  a fixed clock gives byte-identical URLs; another instant does not.
#   GATE 7  the signer's URL is exactly komira_gcp_core's gcs_v4_signed_url
#           over the path-style path, with `host` the only signed header.
#   GATE 8  the key path is never normalized (`a//b`, `a/./b`, `a/../b` are
#           three objects), and `&` is encoded while `/` is not.
#   GATE 9  containment: the bucket is the signer's; an empty bucket, a
#           bucket holding `/`, and an empty key are refused.
#   GATE 10 an emulator authority keeps its port in the URL.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_json import parse_json_value

from komira_gcp_core import (
    GCS_V4_DEFAULT_HOST,
    GCS_V4_MAX_EXPIRES_SECONDS,
    GcsV4Header,
    GcsV4QueryParam,
    GcsV4ServiceAccount,
    gcs_v4_canonical_path,
    gcs_v4_signed_url,
    gcs_v4_stamps_from_unix_seconds,
    pkcs8_private_key_der_from_pem,
)
from komira_objectstore import (
    PRESIGN_MAX_TTL_SECONDS,
    ObjectUrlSigner,
    PresignedUrl,
)
from komira_objectstore_gcs import (
    FixedSigningClock,
    GcsSigningClock,
    GcsV4Signer,
)


comptime _ACCOUNT = "conformance/storage/v1/test_service_account.not-a-test.json"
comptime _BUCKET: StaticString = "repo-bucket"
comptime _KEY: StaticString = "alpha.git/lfs/objects/9f/86/9f86d081884c7d65"
comptime _TTL: Int = 300
comptime _FIXED_NOW: Int64 = 1790000000  # 20260921T141320Z


struct SteppingClock(GcsSigningClock):
    """Reports `start`, then `start + 1`, ... one second per read, so the
    instant a mint reports says how many reads came before it."""

    var next: Int64

    def __init__(out self, start: Int64):
        self.next = start

    def now_unix_seconds(mut self) raises -> Int64:
        var t = self.next
        self.next += 1
        return t


def _account() raises -> GcsV4ServiceAccount:
    var text: String
    with open(_ACCOUNT, "r") as f:
        text = f.read()
    var a = parse_json_value(text)
    var der = pkcs8_private_key_der_from_pem(a.get("private_key").as_string())
    return GcsV4ServiceAccount(a.get("client_email").as_string(), der^)


def _gcs() raises -> GcsV4Signer[FixedSigningClock]:
    return GcsV4Signer(
        _account(), String(_BUCKET), FixedSigningClock(_FIXED_NOW)
    )


def _query_value(url: String, name: String) -> String:
    """The raw value of query parameter `name` in `url`, or "" if absent."""
    var q = url.find("?")
    if q < 0:
        return String()
    var query = String(url[byte = q + 1 :])
    for part in query.split("&"):
        var p = String(part)
        var eq = p.find("=")
        if eq >= 0 and String(p[byte=:eq]) == name:
            return String(p[byte = eq + 1 :])
    return String()


def _url_path(url: String) -> String:
    """The path of `scheme://authority/path?query`."""
    var start = url.find("://")
    var slash = url.find("/", start + 3)
    var q = url.find("?")
    if q < 0:
        q = url.byte_length()
    return String(url[byte=slash:q])


# -----------------------------------------------------------------------------
# GATE 1 + 2 + 3: one generic mint.
# -----------------------------------------------------------------------------


def _mint[
    S: ObjectUrlSigner
](mut signer: S, key: String, ttl: Int) raises -> Tuple[
    PresignedUrl, PresignedUrl
]:
    """Names no cloud: it compiles against any conformer of the seam."""
    return Tuple[PresignedUrl, PresignedUrl](
        signer.presign_download(key, ttl), signer.presign_upload(key, ttl)
    )


def test_gate1_2_3_generic_mint_scopes_each_verb() raises:
    var gcs = _gcs()
    var g = _mint(gcs, String(_KEY), _TTL)

    # GATE 2: verb scoping, and the verb changes the signature.
    assert_equal(g[0].method, String("GET"))
    assert_equal(g[1].method, String("PUT"))
    assert_true(g[0].url != g[1].url)
    assert_true(
        _query_value(g[0].url, "X-Goog-Signature")
        != _query_value(g[1].url, "X-Goog-Signature")
    )

    # The URL points at GCS and carries GCS's signature parameter.
    assert_true(
        g[0].url.startswith(
            String("https://") + String(GCS_V4_DEFAULT_HOST) + "/"
        )
    )
    assert_equal(
        _query_value(g[0].url, "X-Goog-Algorithm"), String("GOOG4-RSA-SHA256")
    )
    # Hex RSA-2048 signature: 256 bytes, 512 hex digits.
    assert_equal(
        len(_query_value(g[0].url, "X-Goog-Signature").as_bytes()), 512
    )
    assert_equal(gcs.signer_cloud(), String("gcs"))

    # GATE 3: GCS requires no client header, on either verb.
    assert_equal(len(g[0].required_headers), 0)
    assert_equal(len(g[1].required_headers), 0)


# -----------------------------------------------------------------------------
# GATE 4: the expiry comes from the one clock reading of the mint.
# -----------------------------------------------------------------------------


def test_gate4_expiry_is_the_signing_instant_plus_ttl() raises:
    var gcs = _gcs()
    var u = gcs.presign_download(String(_KEY), _TTL)
    assert_equal(u.expires_unix_seconds, _FIXED_NOW + Int64(_TTL))
    assert_equal(
        _query_value(u.url, "X-Goog-Date"), String("20260921T141320Z")
    )
    assert_equal(_query_value(u.url, "X-Goog-Expires"), String(_TTL))
    assert_true(
        _query_value(u.url, "X-Goog-Credential").find("%2F20260921%2Fauto%2F")
        > 0
    )

    # One read per mint: the second mint signs one second later.
    var stepping = GcsV4Signer(
        _account(), String(_BUCKET), SteppingClock(_FIXED_NOW)
    )
    var first = stepping.presign_download(String(_KEY), _TTL)
    var second = stepping.presign_upload(String(_KEY), _TTL)
    assert_equal(first.expires_unix_seconds, _FIXED_NOW + Int64(_TTL))
    assert_equal(second.expires_unix_seconds, _FIXED_NOW + 1 + Int64(_TTL))
    assert_equal(
        _query_value(second.url, "X-Goog-Date"), String("20260921T141321Z")
    )


# -----------------------------------------------------------------------------
# GATE 5: the TTL ceiling is ours, and it refuses.
# -----------------------------------------------------------------------------


def _refuses_ttl(ttl: Int, upload: Bool) raises -> Bool:
    var gcs = _gcs()
    try:
        if upload:
            _ = gcs.presign_upload(String(_KEY), ttl)
        else:
            _ = gcs.presign_download(String(_KEY), ttl)
    except:
        return True
    return False


def test_gate5_policy_ceiling_refuses_rather_than_clamps() raises:
    assert_equal(PRESIGN_MAX_TTL_SECONDS, 3600)
    assert_true(PRESIGN_MAX_TTL_SECONDS < GCS_V4_MAX_EXPIRES_SECONDS)

    assert_true(_refuses_ttl(PRESIGN_MAX_TTL_SECONDS + 1, False))
    assert_true(_refuses_ttl(PRESIGN_MAX_TTL_SECONDS + 1, True))
    # Below GCS's own maximum and still refused: the ceiling is ours.
    assert_true(_refuses_ttl(GCS_V4_MAX_EXPIRES_SECONDS, False))
    # A zero or negative TTL is a bug, not an already-expired URL.
    assert_true(_refuses_ttl(0, False))
    assert_true(_refuses_ttl(-1, True))

    # The ceiling itself is allowed, and is what the URL carries.
    var gcs = _gcs()
    var u = gcs.presign_download(String(_KEY), PRESIGN_MAX_TTL_SECONDS)
    assert_equal(
        _query_value(u.url, "X-Goog-Expires"), String(PRESIGN_MAX_TTL_SECONDS)
    )

    # A refused mint reads no clock: the next mint still signs at `start`.
    var stepping = GcsV4Signer(
        _account(), String(_BUCKET), SteppingClock(_FIXED_NOW)
    )
    var refused = False
    try:
        _ = stepping.presign_download(String(_KEY), PRESIGN_MAX_TTL_SECONDS + 1)
    except:
        refused = True
    assert_true(refused)
    var after = stepping.presign_download(String(_KEY), _TTL)
    assert_equal(after.expires_unix_seconds, _FIXED_NOW + Int64(_TTL))


# -----------------------------------------------------------------------------
# GATE 6: deterministic for a fixed clock.
# -----------------------------------------------------------------------------


def test_gate6_fixed_clock_mints_are_byte_identical() raises:
    var a = _gcs()
    var b = _gcs()
    var ua = a.presign_download(String(_KEY), _TTL)
    var ub = b.presign_download(String(_KEY), _TTL)
    assert_equal(ua.url, ub.url)
    # The same signer twice, too: nothing in it drifts between mints.
    var ua2 = a.presign_download(String(_KEY), _TTL)
    assert_equal(ua.url, ua2.url)

    var later = GcsV4Signer(
        _account(), String(_BUCKET), FixedSigningClock(_FIXED_NOW + 1)
    )
    var ul = later.presign_download(String(_KEY), _TTL)
    assert_true(ul.url != ua.url)
    assert_true(
        _query_value(ul.url, "X-Goog-Signature")
        != _query_value(ua.url, "X-Goog-Signature")
    )


# -----------------------------------------------------------------------------
# GATE 7: the signer is gcs_v4_signed_url over the path-style path.
# -----------------------------------------------------------------------------


def test_gate7_signer_url_is_the_core_signed_url() raises:
    var gcs = _gcs()
    var got = gcs.presign_upload(String(_KEY), _TTL)
    var want = gcs_v4_signed_url(
        String("https"),
        String("PUT"),
        String(GCS_V4_DEFAULT_HOST),
        String("/") + String(_BUCKET) + "/" + String(_KEY),
        List[GcsV4Header](),
        List[GcsV4QueryParam](),
        _account(),
        String("auto"),
        gcs_v4_stamps_from_unix_seconds(_FIXED_NOW),
        _TTL,
    )
    assert_equal(got.url, want)
    assert_equal(_query_value(got.url, "X-Goog-SignedHeaders"), String("host"))
    assert_equal(
        _url_path(got.url), String("/") + String(_BUCKET) + "/" + String(_KEY)
    )


# -----------------------------------------------------------------------------
# GATE 8: the key path is never normalized.
# -----------------------------------------------------------------------------


def test_gate8_object_key_paths_are_never_normalized() raises:
    assert_equal(gcs_v4_canonical_path(String("/b//x")), String("/b//x"))
    assert_equal(gcs_v4_canonical_path(String("/b/./x")), String("/b/./x"))
    assert_equal(
        gcs_v4_canonical_path(String("/b/a/../x")), String("/b/a/../x")
    )
    assert_equal(gcs_v4_canonical_path(String("/b/a&c")), String("/b/a%26c"))

    # Through the signer: the bucket prefix plus the key, byte for byte.
    var gcs = _gcs()
    assert_equal(
        _url_path(gcs.presign_download(String("a//b"), _TTL).url),
        String("/repo-bucket/a//b"),
    )
    assert_equal(
        _url_path(gcs.presign_download(String("a/./b"), _TTL).url),
        String("/repo-bucket/a/./b"),
    )
    assert_equal(
        _url_path(gcs.presign_download(String("a/../b"), _TTL).url),
        String("/repo-bucket/a/../b"),
    )
    assert_equal(
        _url_path(gcs.presign_download(String("a&c d"), _TTL).url),
        String("/repo-bucket/a%26c%20d"),
    )
    # Three keys, three signatures.
    assert_true(
        gcs.presign_download(String("a//b"), _TTL).url
        != gcs.presign_download(String("a/b"), _TTL).url
    )


# -----------------------------------------------------------------------------
# GATE 9: containment.
# -----------------------------------------------------------------------------


def _refuses_bucket(bucket: String) raises -> Bool:
    try:
        _ = GcsV4Signer(_account(), bucket, FixedSigningClock(_FIXED_NOW))
    except:
        return True
    return False


def test_gate9_bucket_is_the_signers_and_empty_names_are_refused() raises:
    assert_true(_refuses_bucket(String("")))
    assert_true(_refuses_bucket(String("repo-bucket/other")))
    assert_true(_refuses_bucket(String("/repo-bucket")))

    var gcs = _gcs()
    assert_equal(gcs.bucket(), String(_BUCKET))
    var refused = False
    try:
        _ = gcs.presign_upload(String(""), _TTL)
    except:
        refused = True
    assert_true(refused)


# -----------------------------------------------------------------------------
# GATE 10: an emulator authority keeps its port.
# -----------------------------------------------------------------------------


def test_gate10_emulator_authority_keeps_its_port() raises:
    var emu = GcsV4Signer(
        _account(),
        String(_BUCKET),
        FixedSigningClock(_FIXED_NOW),
        host=String("localhost:4443"),
        scheme=String("http"),
    )
    var u = emu.presign_download(String(_KEY), _TTL)
    assert_true(
        u.url.startswith(String("http://localhost:4443/repo-bucket/"))
    )
    assert_false(u.url.startswith(String("https://")))


def main() raises:
    test_gate1_2_3_generic_mint_scopes_each_verb()
    test_gate4_expiry_is_the_signing_instant_plus_ttl()
    test_gate5_policy_ceiling_refuses_rather_than_clamps()
    test_gate6_fixed_clock_mints_are_byte_identical()
    test_gate7_signer_url_is_the_core_signed_url()
    test_gate8_object_key_paths_are_never_normalized()
    test_gate9_bucket_is_the_signers_and_empty_names_are_refused()
    test_gate10_emulator_authority_keeps_its_port()
    print("PASS test_gcs_presign_portability")
