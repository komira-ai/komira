"""Per-target compile defines and assert level, and the memory cap of a test
run, for the Mojo rules (defs.bzl).

An unset attribute writes nothing: a target that sets none of them has the
same commands, and so the same action keys, as before the attributes existed.

    attribute (mojo_library)   attribute (mojo_test, mojo_binary)   effect
    test_assert_level          assert_level                         `-D ASSERT=<level>`
    test_defines               defines                              `-D <define>` each
    test_memory_cap_mib        memory_cap_mib (mojo_test only)      the run under mem_cap.sh

The mojo_library attributes reach each `test_srcs` build and run, and the
defines its coverage build; not the package's `mojo precompile`, the README's
examples, or a coverage run under kcov (which is not capped). A `-D` given to `mojo build` also reaches the code of every package
compiled into the program: a `.mojoc` holds no machine code, so its
compile-time parameters (`debug_assert`'s `ASSERT` among them) are settled in
the `mojo build` that generates the code.
"""

# Mojo's `debug_assert` reads the define ASSERT: `none` turns every
# debug_assert off; `safe`, the compiler's default, keeps the ones declared
# `assert_mode="safe"`; `all` turns every one on; `warn` turns every one on and
# prints a failure instead of aborting.
ASSERT_LEVELS = ["none", "warn", "safe", "all"]

# The memory cap, in MiB of resident memory (mem_cap.sh), of a test compiled
# at ASSERT=none that names no cap. Such a test is a hostile-input test: with
# its bounds checks off, a length read from corrupt input can drive an
# allocation with no bound, and the cap kills the test instead of letting it
# exhaust the worker.
HOSTILE_INPUT_MEMORY_CAP_MIB = 4096

def define_args(where, level_attr, assert_level, defines_attr, defines):
    """The `-D` arguments of a `mojo build`: the assert level first, then each
    define in the order declared. `where` and the attribute names are for the
    messages."""
    args = []
    if assert_level != None:
        if assert_level not in ASSERT_LEVELS:
            fail("{}: {} `{}` is not one of {}".format(where, level_attr, assert_level, ", ".join(ASSERT_LEVELS)))
        args += ["-D", "ASSERT=" + assert_level]
    seen = {}
    for d in defines:
        name = d.split("=", 1)[0]
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
            fail("{}: {} entry {} is not NAME or NAME=VALUE with NAME an identifier".format(where, defines_attr, repr(d)))
        if name == "ASSERT":
            fail("{}: {} sets ASSERT; set `{}` instead".format(where, defines_attr, level_attr))
        if name in seen:
            fail("{}: {} sets {} twice".format(where, defines_attr, name))
        seen[name] = True
        args += ["-D", d]
    return args

def memory_cap(where, cap_attr, cap, assert_level):
    """The cap in MiB, or None for an uncapped run. Unset: the hostile-input
    cap at ASSERT=none, else none; 0: none."""
    if cap == None:
        return HOSTILE_INPUT_MEMORY_CAP_MIB if assert_level == "none" else None
    if cap < 0:
        fail("{}: {} is {}; it must be a number of MiB, or 0 for no cap".format(where, cap_attr, cap))
    return cap if cap > 0 else None

def capped_prefix(tc, script, label, cap):
    """The words that run a test command under mem_cap.sh, or [] without a cap."""
    if cap == None:
        return []
    return [tc.busybox, "sh", script, tc.busybox, str(cap), label, "--"]

def mem_cap_script(ctx):
    return ctx.attrs._mem_cap[DefaultInfo].default_outputs[0]

_MEM_CAP_ATTR = {
    "_mem_cap": attrs.dep(default = "komira//tools/build/mojo:mem_cap.sh"),
}

LIBRARY_DEFINE_ATTRS = {
    # See this file's docstring and ASSERT_LEVELS.
    "test_assert_level": attrs.option(attrs.string(), default = None),
    "test_defines": attrs.list(attrs.string(), default = []),
    "test_memory_cap_mib": attrs.option(attrs.int(), default = None),
} | _MEM_CAP_ATTR

BINARY_DEFINE_ATTRS = {
    "assert_level": attrs.option(attrs.string(), default = None),
    "defines": attrs.list(attrs.string(), default = []),
}

TEST_DEFINE_ATTRS = BINARY_DEFINE_ATTRS | {
    "memory_cap_mib": attrs.option(attrs.int(), default = None),
} | _MEM_CAP_ATTR
