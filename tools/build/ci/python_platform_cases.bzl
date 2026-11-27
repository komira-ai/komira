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

A real test has exec dependencies (the interpreter's tzdata), and configuring it for darwin-arm64
resolves them on a darwin-arm64 execution platform. The check registers that platform only in its
macOS build step (pr.yml's `darwin-config-file`), so `cases.bxl:run` runs without it. There a real
case's darwin answer is the compatibility the macro wrote on the target, the answer configuring
gives: compatible exactly when every constraint of its `target_compatible_with` is one of
darwin-arm64's. With the platform registered (a machine whose buckconfig names the macOS workers),
the real case is configured for darwin-arm64 like a fixture.
"""

load("@komira//tools/build/platforms:defs.bzl", "DARWIN_ARM64")

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

def stated_compatible(target_compatible_with, constraints):
    """Whether a platform of `constraints` satisfies a `target_compatible_with` list (labels or strings)."""
    have = [str(c) for c in constraints]
    return all([str(c) in have for c in target_compatible_with])

# (target_compatible_with, constraints of the platform, compatible, what it proves)
_STATED_CASES = [
    ([], ["prelude//os/constraints:macos"], True, "no stated compatibility is compatible everywhere"),
    (["prelude//os/constraints:linux", "prelude//cpu/constraints:x86_64"], ["prelude//os/constraints:macos", "prelude//cpu/constraints:arm64"], False, "linux x86_64 is not darwin arm64"),
    (["prelude//os/constraints:linux", "prelude//cpu/constraints:x86_64"], ["prelude//os/constraints:linux", "prelude//cpu/constraints:arm64"], False, "one constraint the platform lacks is enough to refuse"),
    (["prelude//os/constraints:macos"], ["prelude//os/constraints:macos", "prelude//cpu/constraints:arm64"], True, "a subset of the platform's constraints is compatible"),
]

def _stated_cases():
    out = []
    for stated, constraints, want, proves in _STATED_CASES:
        if stated_compatible(stated, constraints) != want:
            out.append("python platform: stated {} on {} is {}, wanted {} ({})".format(stated, constraints, _word(not want), _word(want), proves))
    return out

def _darwin_registered(ctx):
    platforms = ctx.analysis(ctx.configured_targets("komira//tools/build/platforms/default:default")).providers()[ExecutionPlatformRegistrationInfo].platforms
    return _DARWIN in [str(p.label) for p in platforms]

def python_platform_cases(ctx):
    out = _stated_cases()
    darwin_exec = _darwin_registered(ctx)
    for target, proves, darwin, linux in PYTHON_PLATFORM_CASES:
        for platform, want in [(_DARWIN, darwin), (_LINUX, linux)]:
            if platform == _DARWIN and not darwin_exec and not target.startswith(_FIXTURE):
                got = stated_compatible(ctx.unconfigured_targets(target).get_attr("target_compatible_with"), DARWIN_ARM64)
            else:
                got = ctx.configured_targets(target, target_platform = platform) != None
            if got != want:
                out.append("python platform: {} on {} is {}, wanted {} ({})".format(target, platform, _word(got), _word(want), proves))
    return out
