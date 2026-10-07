# The installed-environment run test's program (native_run.sh R1 and B1,
# BUCK :installed_crypto_run_test): komira_crypto as its conda package
# installs it, whose aws-lc calls reach libkomira_native.so.1 alone. Known
# answers: SHA-256 of "abc" (FIPS 180-4) and HMAC-SHA256 test case 2 of
# RFC 4231.
from komira_crypto import hmac_sha256_string, sha256_string
from native_util import hex_of, report


def _list(d: Array[UInt8, 32]) -> List[UInt8]:
    var out = List[UInt8](capacity=32)
    for i in range(32):
        out.append(d[i])
    return out^


def main() raises:
    var digest = hex_of(_list(sha256_string("abc")))
    var ok = report(
        "komira_crypto_sha256",
        digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        digest,
    )
    var key = List[UInt8]()
    var jefe = String("Jefe")
    var jb = jefe.as_bytes()
    for i in range(len(jb)):
        key.append(jb[i])
    var mac = hex_of(_list(hmac_sha256_string(key, "what do ya want for nothing?")))
    ok = report(
        "komira_crypto_hmac_sha256",
        mac == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        mac,
    ) and ok
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
