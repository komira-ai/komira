# =============================================================================
# komira_gcp_core/tests/test_env_source_only.mojo
# =============================================================================
#
# komira_gcp_core may read the environment only where Google's own auth chain
# does, and only in a file named in _allowed() below with its reason. Every
# library source of the package is staged as test data
# (src/komira_gcp_core/*.mojo); the test reads each one and fails if a file
# not in _allowed() names getenv, setenv, `_read_env`, komira_core_ffi or an
# `external_call`. An allowed entry must exist and must actually read the
# environment, so a stale entry fails too.
#
# The one allowed file is sources.mojo, the `EnvSource` seam. `ProcessEnv`,
# the seam's process-environment side, is constructed in exactly one place,
# adc.mojo's production entry, and named nowhere else but sources.mojo and
# the package root's re-export (test_process_env_sites). What is READ through
# the seam is checked too (test_names_are_googles): in every file that takes
# an `EnvSource`, every `.get(` is an `env.get(` of an `ENV_*` constant, and
# every `ENV_*` constant is one of the variables Google's auth libraries
# read (_GOOGLE below). A new variable fails here until it is added to
# _GOOGLE with the library that reads it. That each of the five is actually
# read somewhere is test_adc's check, not this one's.
#
# The scan is not vacuous: it must see the token contract, the V4 signer, the
# chain, and every other source the package has.
# =============================================================================

from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "src/komira_gcp_core"


# (file name, reason). A file here may read the environment; no other may.
def _allowed() -> List[Tuple[String, String]]:
    return [
        (
            String("sources.mojo"),
            String(
                "the chain's EnvSource seam: ProcessEnv reads getenv through"
                " komira_core_ffi's _read_env"
            ),
        ),
    ]


# The environment variables Google's auth libraries read, and the one each
# is read for (google-auth for Python `environment_vars.py` and
# `_cloud_sdk.py`; Go cloud.google.com/go/auth and compute/metadata).
def _google() -> List[String]:
    return [
        String("GOOGLE_APPLICATION_CREDENTIALS"),  # the credentials file
        String("CLOUDSDK_CONFIG"),  # gcloud's configuration directory
        String("HOME"),  # ~/.config/gcloud
        String("APPDATA"),  # %APPDATA%\gcloud on Windows
        String("GCE_METADATA_HOST"),  # the metadata server's host:port
    ]


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def test_scan() raises:
    var allowed = _allowed()
    var allowed_seen = List[Bool]()
    for _ in range(len(allowed)):
        allowed_seen.append(False)
    var names = listdir(String(_DIR))
    var scanned = 0
    var saw_token = False
    var saw_v4 = False
    var banned: List[String] = [
        "getenv",
        "setenv",
        "_read_env",
        "komira_core_ffi",
        "external_call",
    ]
    for i in range(len(names)):
        var name = String(names[i])
        if not name.endswith(".mojo"):
            continue
        var text: String
        with open(String(_DIR) + "/" + name, "r") as f:
            text = f.read()
        scanned += 1
        if name == "token.mojo":
            saw_token = True
            assert_true(
                _count(text, "trait GcpTokenSource") == 1,
                "token.mojo holds no GcpTokenSource?",
            )
        if name == "v4_sign.mojo":
            saw_v4 = True
            assert_true(
                _count(text, "struct GcsV4CanonicalRequest") == 1,
                "v4_sign.mojo holds no GcsV4CanonicalRequest?",
            )
        var hits = 0
        for j in range(len(banned)):
            hits += _count(text, banned[j])
        var exempt = False
        for k in range(len(allowed)):
            if allowed[k][0] == name:
                exempt = True
                allowed_seen[k] = True
                assert_true(
                    hits > 0,
                    name + " is allowed to read the environment but does"
                    " not; drop it from _allowed()",
                )
        if exempt:
            continue
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                name + " names " + banned[j] + "; komira_gcp_core reads the"
                " environment only in Google auth-chain files named in"
                " _allowed()",
            )
    for k in range(len(allowed)):
        assert_true(
            allowed_seen[k],
            allowed[k][0] + " is in _allowed() but was not staged",
        )
    assert_true(saw_token, "token.mojo was not staged")
    assert_true(saw_v4, "v4_sign.mojo was not staged")
    assert_true(scanned >= 12, "only " + String(scanned) + " sources staged")


def _contains(names: List[String], s: String) -> Bool:
    for i in range(len(names)):
        if names[i] == s:
            return True
    return False


def _ident_at(text: String, at: Int) -> String:
    """The identifier starting at byte `at`."""
    var b = text.as_bytes()
    var end = at
    while end < len(b):
        var c = b[end]
        var ok = (
            (c >= UInt8(0x41) and c <= UInt8(0x5A))
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x5F)
        )
        if not ok:
            break
        end += 1
    return String(StringSlice(unsafe_from_utf8=b[at:end]))


def _quoted_after(text: String, at: Int) raises -> String:
    """The first double-quoted string at or after byte `at`, on its line."""
    var q = text.find("\"", at)
    var nl = text.find("\n", at)
    if q < 0 or (nl >= 0 and nl < q):
        return String("")
    var close = text.find("\"", q + 1)
    assert_true(close >= 0, "an unterminated string after byte " + String(at))
    var b = text.as_bytes()
    return String(StringSlice(unsafe_from_utf8=b[q + 1 : close]))


def test_names_are_googles() raises:
    var google = _google()
    var names = listdir(String(_DIR))
    var declared = List[String]()
    var reads = 0
    # Pass 1: every `comptime ENV_<X>: StaticString = "<name>"` names one of
    # Google's variables.
    for i in range(len(names)):
        var name = String(names[i])
        if not name.endswith(".mojo"):
            continue
        var text: String
        with open(String(_DIR) + "/" + name, "r") as f:
            text = f.read()
        var at = text.find("comptime ENV_")
        while at >= 0:
            var ident = _ident_at(text, at + 9)
            var value = _quoted_after(text, at)
            assert_true(
                _contains(google, value),
                name + " declares " + ident + " = \"" + value + "\", which is"
                " not a variable Google's auth libraries read",
            )
            declared.append(ident)
            at = text.find("comptime ENV_", at + 1)
    # Pass 2: every `env.get(` takes one of those constants; and in a file
    # that takes an `EnvSource` (sources.mojo, which defines it, aside),
    # every `.get(` is such an `env.get(`, so a read through another name
    # (`e.get("X")`) is not missed.
    for i in range(len(names)):
        var name = String(names[i])
        if not name.endswith(".mojo"):
            continue
        var text: String
        with open(String(_DIR) + "/" + name, "r") as f:
            text = f.read()
        if name != "sources.mojo" and _count(text, "EnvSource") > 0:
            assert_equal(
                _count(text, ".get("),
                _count(text, "env.get(ENV_"),
                name + " takes an EnvSource and calls a .get( that is not"
                " env.get(ENV_...)",
            )
        var at = text.find("env.get(")
        while at >= 0:
            var ident = _ident_at(text, at + 8)
            assert_true(
                _contains(declared, ident),
                name + " reads the environment variable named by `" + ident
                + "`, which is not an ENV_* constant of a Google variable",
            )
            reads += 1
            at = text.find("env.get(", at + 1)
    assert_equal(len(declared), len(google), "an ENV_* constant per variable")
    assert_true(reads >= len(google), "only " + String(reads) + " env.get( reads seen")


def test_process_env_sites() raises:
    # ProcessEnv reads the real environment: one construction, in adc.mojo's
    # production entry, and no other file but sources.mojo (which defines
    # it) and the root's re-export may name it.
    var names = listdir(String(_DIR))
    var constructions = 0
    for i in range(len(names)):
        var name = String(names[i])
        if not name.endswith(".mojo"):
            continue
        var text: String
        with open(String(_DIR) + "/" + name, "r") as f:
            text = f.read()
        if name == "sources.mojo":
            continue
        var built = _count(text, "ProcessEnv(")
        if name == "adc.mojo":
            constructions += built
            continue
        assert_equal(built, 0, name + " constructs a ProcessEnv")
        if name == "__init__.mojo":
            continue
        assert_equal(
            _count(text, "ProcessEnv"),
            0,
            name + " names ProcessEnv; only adc.mojo's production entry may"
            " use the process environment",
        )
    assert_equal(constructions, 1, "adc.mojo constructs ProcessEnv once")


def main() raises:
    test_scan()
    test_names_are_googles()
    test_process_env_sites()
    print("OK")
