# =============================================================================
# src/kci_contract/platform.mojo -- the platforms kci builds and publishes
#   for, and the conda subdir of each.
# =============================================================================
#
#   platform       conda subdir     kci release
#   linux-x86_64   linux-64         RELEASED
#   darwin-arm64   osx-arm64        reserved: not released yet
#   linux-arm64    linux-aarch64    reserved: not released yet
#   noarch         noarch           a MEMBER's platform only: an artifact
#                                   that runs anywhere (never a release's)
#
# A platform is an (os, cpu) pair. The names are the row names of the
# build's platform table (tools/build/platforms/table.bzl), so the repository
# has one platform vocabulary. A RELEASE (a run of `kci build` or `kci
# publish`) is for exactly one released platform; a member of a release is
# for that platform or `noarch`. A reserved platform is refused with its
# reason, so naming one is a clear "not yet", never "unknown".
#
# Pure functions over owned values; no pointer.
# =============================================================================

comptime PLATFORM_LINUX_X86_64: String = "linux-x86_64"
comptime PLATFORM_DARWIN_ARM64: String = "darwin-arm64"
comptime PLATFORM_LINUX_ARM64: String = "linux-arm64"
comptime PLATFORM_NOARCH: String = "noarch"


struct PlatformRow(Copyable, Movable):
    """One platform. `released` is False for a reserved row, whose `reason`
    says why; `noarch` is a member-only pseudo-platform.

    Layout: owned Strings and a Bool. No pointer field."""

    var name: String
    var conda_subdir: String
    var released: Bool
    var reason: String

    def __init__(out self, var name: String, var conda_subdir: String, released: Bool, var reason: String):
        self.name = name^
        self.conda_subdir = conda_subdir^
        self.released = released
        self.reason = reason^


def platform_table() -> List[PlatformRow]:
    """Every platform, in the order of this file's header."""
    var t = List[PlatformRow]()
    t.append(PlatformRow(String(PLATFORM_LINUX_X86_64), String("linux-64"), True, String("")))
    t.append(
        PlatformRow(
            String(PLATFORM_DARWIN_ARM64),
            String("osx-arm64"),
            False,
            String("kci releases linux-x86_64 only for now; darwin-arm64 is reserved"),
        )
    )
    t.append(
        PlatformRow(
            String(PLATFORM_LINUX_ARM64),
            String("linux-aarch64"),
            False,
            String("kci releases linux-x86_64 only for now; linux-arm64 is reserved"),
        )
    )
    t.append(PlatformRow(String(PLATFORM_NOARCH), String("noarch"), True, String("")))
    return t^


def _names() -> String:
    var t = platform_table()
    var s = String("")
    for i in range(len(t)):
        if i > 0:
            s += String(" ")
        s += t[i].name
    return s^


def platform_row(name: String) raises -> PlatformRow:
    """The row of platform `name`; refuses a name not in the table."""
    var t = platform_table()
    for i in range(len(t)):
        if t[i].name == name:
            return t[i].copy()
    raise Error(String("platform '") + name + String("' is not one of: ") + _names())


def require_release_platform(name: String) raises:
    """Refuse a platform a release cannot be for: unknown, reserved, or
    `noarch`."""
    var row = platform_row(name)
    if name == PLATFORM_NOARCH:
        raise Error(
            String("platform 'noarch' is a member's platform, never a release's: a release")
            + String(" is built and published for one (os, cpu)")
        )
    if not row.released:
        raise Error(String("platform '") + name + String("' is not released: ") + row.reason)


def require_artifact_platform(name: String) raises:
    """Refuse a platform an artifact cannot be for: unknown or reserved.
    `noarch` is allowed."""
    var row = platform_row(name)
    if not row.released:
        raise Error(String("platform '") + name + String("' is not released: ") + row.reason)


def require_member_platform(release_platform: String, member_platform: String) raises:
    """Refuse a member whose platform is neither the release's nor
    `noarch`."""
    require_artifact_platform(member_platform)
    if member_platform != release_platform and member_platform != PLATFORM_NOARCH:
        raise Error(
            String("platform '") + member_platform + String("' is neither the release's '")
            + release_platform + String("' nor 'noarch'")
        )


def conda_subdir_of(platform: String) raises -> String:
    """The conda subdir of `platform` (`noarch` -> `noarch`)."""
    return platform_row(platform).conda_subdir.copy()


def platform_of_conda_subdir(subdir: String) raises -> String:
    """The platform whose conda subdir is `subdir`; refuses an unknown one."""
    var t = platform_table()
    for i in range(len(t)):
        if t[i].conda_subdir == subdir:
            return t[i].name.copy()
    raise Error(String("conda subdir '") + subdir + String("' is not a kci platform's subdir"))
