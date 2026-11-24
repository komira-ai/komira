"""The Zig tools an action runs are built for the platform the action runs on (release/darwin_analysis.bxl).

A rule takes a tool it runs as an `attrs.exec_dep`, so buck2 configures the tool
for the execution platform of the rule's actions. A `zig_exe` states the triple
it is built for (`ZigExeInfo`). When that triple is not the execution platform's,
the action fails on the worker ("cannot execute binary file", exit 126) after
its inputs were sent: a Linux tool on a macOS worker. `exec_tool_refusal`
compares the two at analysis.

`exec_tool_cases` checks the function's answers: release/BUCK calls it, so loading the
release package (which darwin_analysis.bxl does) fails on a wrong answer.
"""

load("@komira//tools/build/platforms:table.bzl", "PLATFORMS")

_PLATFORMS = "komira//tools/build/platforms:"

def exec_tool_refusal(label, triple):
    """Why the exec dep `label`, built for the zig `triple`, cannot run where it is configured to run, or None.

    `label` is a configured label as buck2 prints it,
    `<target> (komira//tools/build/platforms:<row>#<hash>)`; the platform of its
    configuration is the execution platform of the action that runs it. The
    triple's cpu and os (`x86_64-linux-musl`, `aarch64-macos.11.0`) must be the
    row's `host` arch and os. A label configured for no row of the platform
    table is refused, since the check would compare it with nothing.
    """
    at = label.find(" (")
    cfg = label[at + 2:] if at >= 0 else ""
    hash_at = cfg.find("#")
    if not cfg.startswith(_PLATFORMS) or hash_at < 0:
        return "{} is configured for no platform of the platform table, so its triple {} cannot be checked".format(label, triple)
    name = cfg[len(_PLATFORMS):hash_at]
    if name not in PLATFORMS:
        return "{} is configured for {}, which is not a row of the platform table ({})".format(label, name, ", ".join(sorted(PLATFORMS)))
    host = PLATFORMS[name]["host"]
    parts = triple.split("-")
    if len(parts) < 2 or parts[0] != host["arch"] or parts[1].split(".")[0] != host["os"]:
        return ("{} is built for {}, but it is an exec dep configured for the {} execution platform ({}-{}): " +
                "the action that runs it fails there with \"cannot execute binary file\". Build it for the " +
                "platform it is configured for (`target = exec_tool_target()`, tools/build/mojo/toolchain.bzl)").format(
            label[:at],
            triple,
            name,
            host["arch"],
            host["os"],
        )
    return None

# ---- Load-time cases ----------------------------------------------------------------------------

_DARWIN = " (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024)"
_LINUX = " (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)"
_LINUX_ARM64 = " (komira//tools/build/platforms:linux-arm64#0123456789abcdef)"
_TOOL = "komira//tools/build/mojo:so_exports"

# (configured label, triple, refused?)
_CASES = [
    # A macOS execution platform runs a macOS arm64 tool, with or without the os floor.
    (_TOOL + _DARWIN, "aarch64-macos.11.0", False),
    (_TOOL + _DARWIN, "aarch64-macos", False),
    # A Linux execution platform runs a Linux tool of its cpu, static or glibc.
    (_TOOL + _LINUX, "x86_64-linux-musl", False),
    (_TOOL + _LINUX, "x86_64-linux-gnu.2.34", False),
    (_TOOL + _LINUX_ARM64, "aarch64-linux-musl", False),
    # The os differs: a Linux tool on a Mac, a macOS tool on Linux, and one of the same cpu.
    (_TOOL + _DARWIN, "x86_64-linux-musl", True),
    (_TOOL + _LINUX, "aarch64-macos.11.0", True),
    (_TOOL + _DARWIN, "aarch64-linux-musl", True),
    # The cpu differs, the os does not.
    (_TOOL + _LINUX_ARM64, "x86_64-linux-musl", True),
    (_TOOL + _LINUX, "aarch64-linux-musl", True),
    # Not a triple.
    (_TOOL + _DARWIN, "macos", True),
    (_TOOL + _DARWIN, "", True),
    # A configuration of no row of the table, or none at all.
    (_TOOL + " (buildrules//platforms:macos_aarch64#8d3315e71174bfd6)", "aarch64-macos", True),
    (_TOOL + " (komira//tools/build/platforms:plan9-sparc#0123456789abcdef)", "x86_64-linux-musl", True),
    (_TOOL + " (komira//tools/build/platforms:darwin-arm64)", "aarch64-macos", True),
    (_TOOL, "x86_64-linux-musl", True),
]

# The refusal for the Linux so_exports configured for darwin-arm64 (the tool the release-macos
# harness step ran on a macOS worker, exit 126), held word for word so the message keeps naming
# the tool, its triple, the platform and the fix.
_SO_EXPORTS_ON_DARWIN = (
    "komira//tools/build/mojo:so_exports is built for x86_64-linux-musl, but it is an exec dep configured for " +
    "the darwin-arm64 execution platform (aarch64-macos): the action that runs it fails there with \"cannot " +
    "execute binary file\". Build it for the platform it is configured for (`target = exec_tool_target()`, " +
    "tools/build/mojo/toolchain.bzl)"
)

def exec_tool_cases():
    """Fails when `exec_tool_refusal` gets a case wrong; the release-macos case word for word."""
    for label, triple, refused in _CASES:
        got = exec_tool_refusal(label, triple)
        if (got != None) != refused:
            fail("exec_tool_refusal({}, {}) is {}, want {}".format(repr(label), repr(triple), repr(got), "a refusal" if refused else "None"))
    got = exec_tool_refusal(_TOOL + _DARWIN, "x86_64-linux-musl")
    if got != _SO_EXPORTS_ON_DARWIN:
        fail("exec_tool_refusal of the Linux so_exports on darwin-arm64 is {}, want {}".format(repr(got), repr(_SO_EXPORTS_ON_DARWIN)))
