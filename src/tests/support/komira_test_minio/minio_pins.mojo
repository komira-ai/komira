# =============================================================================
# komira_test_minio/minio_pins.mojo -- the MinIO server binaries
# `start_embedded_minio` will run, pinned by sha256, one per platform.
# =============================================================================
#
# A release digest is a public fact about an upstream artifact, not a fact
# about any deployment. `start_embedded_minio` hashes the binary it was
# given and refuses (raises: a FAIL, never a SKIP) when the digest is not this
# platform's pin, so a test never runs against a server nobody chose.
#
# Both digests belong to ONE upstream MinIO server release (the linux-amd64
# and darwin-arm64 builds of it). Moving to another release replaces both
# rows together.
# =============================================================================

from std.sys.info import CompilationTarget

from ._private_files import _sha256_file_hex


struct MinioPin(Copyable, Movable):
    """One platform's pinned server binary."""

    var platform: String
    var sha256: String

    def __init__(out self, var platform: String, var sha256: String):
        self.platform = platform^
        self.sha256 = sha256^


comptime PLATFORM_LINUX_AMD64: String = "linux-amd64"
comptime PLATFORM_DARWIN_ARM64: String = "darwin-arm64"


def minio_server_pins() -> List[MinioPin]:
    var pins = List[MinioPin]()
    pins.append(
        MinioPin(
            String(PLATFORM_LINUX_AMD64),
            String("7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f"),
        )
    )
    pins.append(
        MinioPin(
            String(PLATFORM_DARWIN_ARM64),
            String("7c3b3039b76e55a1b80935848ed83998d5e8d317374f87851f46a019ff5c0aa4"),
        )
    )
    return pins^


def current_minio_platform() -> String:
    """This build's platform in the pins' spelling, or "unsupported"."""
    comptime if CompilationTarget.is_linux() and CompilationTarget.is_x86():
        return String(PLATFORM_LINUX_AMD64)
    elif CompilationTarget.is_macos() and CompilationTarget.is_apple_silicon():
        return String(PLATFORM_DARWIN_ARM64)
    else:
        return String("unsupported")


def pinned_sha256_for(pins: List[MinioPin], platform: String) -> String:
    """The pinned digest for `platform`, or "" when there is none."""
    for p in pins:
        if p.platform == platform:
            return p.sha256
    return String("")


def binary_sha256(path: String) raises -> String:
    """The lowercase hex sha256 of the file at `path`: the digest
    `start_embedded_minio` compares with the pin. A test that pins a fixture
    file builds its `MinioPin` from this."""
    return _sha256_file_hex(path, "the file to hash")
