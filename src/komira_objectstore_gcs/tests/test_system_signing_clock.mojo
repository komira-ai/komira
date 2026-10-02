# =============================================================================
# komira_objectstore_gcs/tests/test_system_signing_clock.mojo
# =============================================================================
#
# SystemSigningClock, the production `GcsSigningClock`: the process wall
# clock in whole seconds.
#
#   1  a read is a plausible current instant: after 2026-09-01T00:00:00Z
#      (a fixed instant before this code existed) and before 2100-01-01.
#   2  a GcsV4Signer over it mints at one reading of that clock: the URL's
#      X-Goog-Date is the stamp of the reported expiry minus the TTL, and
#      X-Goog-Expires is the TTL. That instant lies between reads of the
#      same clock taken before and after the mint, within one second either
#      side. The bracket ASSUMES the host clock is not stepped by more than
#      one second during the mint; under a monotonic clock it holds with no
#      slack, since all three reads truncate to whole seconds.
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
from komira_objectstore_gcs import GcsV4Signer, SystemSigningClock


comptime _ACCOUNT = "conformance/storage/v1/test_service_account.not-a-test.json"
comptime _AFTER: Int = 1788220800  # 2026-09-01T00:00:00Z
comptime _BEFORE: Int = 4102444800  # 2100-01-01T00:00:00Z
comptime _TTL: Int = 300


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


def test_signer_signs_at_the_wall_clock() raises:
    var probe = SystemSigningClock()
    var signer = GcsV4Signer(
        _account(), String("repo-bucket"), SystemSigningClock()
    )
    var before = probe.now_unix_seconds()
    var url = signer.presign_download(String("a/b"), _TTL)
    var after = probe.now_unix_seconds()
    assert_equal(url.method, String("GET"))
    var signed_at = Int(url.expires_unix_seconds) - _TTL
    assert_true(
        signed_at >= before - 1 and signed_at <= after + 1,
        "signed at "
        + String(signed_at)
        + ", outside the wall-clock reads "
        + String(before)
        + ".."
        + String(after),
    )
    # The stamps and the expiry come from the same reading.
    assert_equal(
        _query_value(url.url, "X-Goog-Date"),
        gcs_v4_stamps_from_unix_seconds(Int64(signed_at)).datetime_z,
    )
    assert_equal(_query_value(url.url, "X-Goog-Expires"), String(_TTL))


def main() raises:
    test_reads_a_plausible_now()
    test_signer_signs_at_the_wall_clock()
    print("OK")
