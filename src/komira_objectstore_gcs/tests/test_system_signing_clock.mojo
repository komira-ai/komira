# =============================================================================
# komira_objectstore_gcs/tests/test_system_signing_clock.mojo
# =============================================================================
#
# SystemSigningClock, the production `GcsSigningClock`: the process wall
# clock in whole seconds.
#
#   1  a read is a plausible current instant: after 2026-09-01T00:00:00Z
#      (a fixed instant before this code existed) and before 2100-01-01.
#   2  a GcsV4Signer mints from its clock: over a FixedSigningClock the URL's
#      X-Goog-Date is the stamp of that instant, the expiry is that instant
#      plus the TTL, and X-Goog-Expires is the TTL, all exact.
#   3  a GcsV4Signer wired to SystemSigningClock mints at a real instant: the
#      expiry minus the TTL lies between the fixed bounds of test 1 and
#      X-Goog-Date is the stamp of that same instant.
#
# The key is Google's published inactive dummy service account, read from the
# pinned conformance archive staged at conformance/.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_json import parse_json_value

from komira_gcp_core import (
    GcsV4ServiceAccount,
    gcs_v4_stamps_from_unix_seconds,
)
from komira_objectstore_gcs import (
    FixedSigningClock,
    GcsV4Signer,
    SystemSigningClock,
)


comptime _ACCOUNT = "conformance/storage/v1/test_service_account.not-a-test.json"
comptime _AFTER: Int = 1788220800  # 2026-09-01T00:00:00Z
comptime _BEFORE: Int = 4102444800  # 2100-01-01T00:00:00Z
comptime _TTL: Int = 300
comptime _FIXED_NOW: Int = 1790000000
comptime _FIXED_STAMP = "20260921T141320Z"


def _account() raises -> GcsV4ServiceAccount:
    var text: String
    with open(_ACCOUNT, "r") as f:
        text = f.read()
    var a = parse_json_value(text)
    var der = rsa_pkcs8_der_from_pem(a.get("private_key").as_string())
    return GcsV4ServiceAccount(a.get("client_email").as_string(), der^)


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


def test_reads_a_plausible_now() raises:
    var clock = SystemSigningClock()
    var now = clock.now_unix_seconds()
    assert_true(
        now > _AFTER, "wall clock reads " + String(now) + ", before 2026-09-01"
    )
    assert_true(
        now < _BEFORE, "wall clock reads " + String(now) + ", after 2100"
    )


def test_signer_mints_from_its_clock() raises:
    var signer = GcsV4Signer(
        _account(), String("repo-bucket"), FixedSigningClock(_FIXED_NOW)
    )
    var url = signer.presign_download(String("a/b"), _TTL)
    assert_equal(url.method, String("GET"))
    assert_equal(Int(url.expires_unix_seconds), _FIXED_NOW + _TTL)
    assert_equal(_query_value(url.url, "X-Goog-Date"), String(_FIXED_STAMP))
    assert_equal(
        _query_value(url.url, "X-Goog-Date"),
        gcs_v4_stamps_from_unix_seconds(Int64(_FIXED_NOW)).datetime_z,
    )
    assert_equal(_query_value(url.url, "X-Goog-Expires"), String(_TTL))


def test_system_clock_signer_mints_at_a_real_instant() raises:
    var signer = GcsV4Signer(
        _account(), String("repo-bucket"), SystemSigningClock()
    )
    var url = signer.presign_download(String("a/b"), _TTL)
    var minted = Int(url.expires_unix_seconds) - _TTL
    assert_true(minted > _AFTER, "minted at " + String(minted) + ", too early")
    assert_true(minted < _BEFORE, "minted at " + String(minted) + ", too late")
    assert_equal(
        _query_value(url.url, "X-Goog-Date"),
        gcs_v4_stamps_from_unix_seconds(Int64(minted)).datetime_z,
    )
    assert_equal(_query_value(url.url, "X-Goog-Expires"), String(_TTL))


def main() raises:
    test_reads_a_plausible_now()
    test_signer_mints_from_its_clock()
    test_system_clock_signer_mints_at_a_real_instant()
    print("OK")
