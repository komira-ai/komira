"""The python macros' platform default (tools/build/python/defs.bzl, `_pinned_python`), held by
komira//tools/build/ci/cases.bxl.

A `python` given as a plain label names one pinned interpreter, and each but `:cpython_macos` is
a linux x86_64 build, so the macro configures the target for linux x86_64 only: a darwin-arm64
build skips it instead of running a linux interpreter. A `select`, no `python`, or a
compatibility the target already states gets no default.

Each case configures a target for each platform and compares the answer (compatible or not) with
the expected one. The fixtures (tests//negative/python_platform) run on linux x86_64, so no case
needs a macOS worker. The real cases are the Python package's own tests: `load_test_py311` takes
the 3.11 interpreter's label from python/pythons.bzl, and `load_test` names no `python`.

A real test runs where its interpreter does, so configuring one that is compatible with
darwin-arm64 (`load_test`) resolves its exec dependencies on a darwin-arm64 execution platform.
pr / check registers that platform only in its macOS build step (pr.yml's `darwin-config-file`),
so `cases.bxl:run` runs without it, and there that one case is not configured: it prints that it
was skipped and why. No `python` takes the macro's non-string branch, the one the fixture
`select_label` holds on both platforms (a fixture with no `python` would take the real macOS
interpreter, which needs that execution platform too). A target incompatible with a platform is
refused before any execution platform is resolved, so every other case runs in both
configurations.
"""

_DARWIN = "komira//tools/build/platforms:darwin-arm64"
_LINUX = "komira//tools/build/platforms:linux-x86_64"
_FIXTURE = "tests//negative/python_platform:"

# (target, what it proves, compatible with darwin-arm64, compatible with linux-x86_64)
PYTHON_PLATFORM_CASES = [
    (_FIXTURE + "linux_label", "a linux interpreter's plain label is linux x86_64 only", False, True),
    (_FIXTURE + "macos_label", "`:cpython_macos` gets no linux default", True, True),
    (_FIXTURE + "select_label", "a `select` of interpreters gets no default", True, True),
    (_FIXTURE + "linux_label_given", "a compatibility the target states is kept, not replaced by the default", True, False),
    ("komira//python/tests:load_test_py311", "a real test on the 3.11 interpreter is skipped on macOS", False, True),
    ("komira//python/tests:load_test", "a real test with no `python` builds on both", True, True),
]

def _word(compatible):
    return "compatible" if compatible else "incompatible"

def _needs_darwin_exec(target, platform, want):
    """Whether configuring `target` for `platform` resolves a darwin-arm64 execution platform: a real (not fixture) target expected compatible with darwin-arm64."""
    return platform == _DARWIN and want and not target.startswith(_FIXTURE)

def _darwin_registered(ctx):
    platforms = ctx.analysis(ctx.configured_targets("komira//tools/build/platforms/default:default")).providers()[ExecutionPlatformRegistrationInfo].platforms
    return _DARWIN in [str(p.label) for p in platforms]

def python_platform_cases(ctx):
    out = []
    darwin_exec = _darwin_registered(ctx)
    for target, proves, darwin, linux in PYTHON_PLATFORM_CASES:
        for platform, want in [(_DARWIN, darwin), (_LINUX, linux)]:
            if _needs_darwin_exec(target, platform, want) and not darwin_exec:
                print("python platform: {} on {} skipped: {} is not a registered execution platform here, which configuring it needs ({}; the fixture select_label holds the same branch)".format(target, platform, _DARWIN, proves))
                continue
            got = ctx.configured_targets(target, target_platform = platform) != None
            if got != want:
                out.append("python platform: {} on {} is {}, wanted {} ({})".format(target, platform, _word(got), _word(want), proves))
    return out
