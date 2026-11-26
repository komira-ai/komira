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

def python_platform_cases(ctx):
    out = []
    for target, proves, darwin, linux in PYTHON_PLATFORM_CASES:
        for platform, want in [(_DARWIN, darwin), (_LINUX, linux)]:
            got = ctx.configured_targets(target, target_platform = platform) != None
            if got != want:
                out.append("python platform: {} on {} is {}, wanted {} ({})".format(target, platform, _word(got), _word(want), proves))
    return out
