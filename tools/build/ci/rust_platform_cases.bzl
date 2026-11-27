"""The rust macros' platform default (tools/build/rust/defs.bzl, `_welded` and `_linux_only`),
held by komira//tools/build/ci/cases.bxl.

The Rust toolchain is the linux-x86_64 one (limit rust-toolchain-x86-64), so each macro
(`rust_binary`, `rust_library`, `rust_test`, `rust_weld_check`) configures its target for linux
x86_64 only: a darwin-arm64 build skips it as incompatible instead of failing to resolve a Rust
toolchain for that platform.

Each case configures a real target of the macro, one that states no compatibility of its own, for
each platform and compares the answer (compatible or not) with the expected one. A target
incompatible with darwin-arm64 is refused before any execution platform is resolved, so the cases
need no macOS worker and no darwin-arm64 execution platform.
"""

_DARWIN = "komira//tools/build/platforms:darwin-arm64"
_LINUX = "komira//tools/build/platforms:linux-x86_64"
_EXT = "komira//tools/build/examples/rust/ext:"

# (target, the macro it was made by, compatible with darwin-arm64, compatible with linux-x86_64)
RUST_PLATFORM_CASES = [
    (_EXT + "ext_consumer", "rust_binary", False, True),
    (_EXT + "ext", "rust_library", False, True),
    (_EXT + "ext_unit", "rust_test", False, True),
    (_EXT + "ext_markers", "rust_weld_check", False, True),
]

def _word(compatible):
    return "compatible" if compatible else "incompatible"

def rust_platform_cases(ctx):
    out = []
    for target, macro, darwin, linux in RUST_PLATFORM_CASES:
        node = ctx.unconfigured_targets(target)
        rule = str(node.rule_type)
        if not rule.endswith(":" + macro + "_rule"):
            out.append("rust platform: {} is a {}, not made by {}, so it does not hold that macro's default".format(target, rule, macro))
            continue
        for platform, want in [(_DARWIN, darwin), (_LINUX, linux)]:
            got = ctx.configured_targets(target, target_platform = platform) != None
            if got != want:
                out.append("rust platform: {} ({}) on {} is {}, wanted {}".format(target, macro, platform, _word(got), _word(want)))
    return out
