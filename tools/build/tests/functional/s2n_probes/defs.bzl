load("@komira//third_party/s2n-tls:srcs.bzl", "PROBE_GLOBAL_FLAGS")

def s2n_probe(name, flags):
    """One s2n-tls feature probe, tests/features/<name>.c, compiled as s2n-tls's
    CMake feature_probe compiles it: with GLOBAL.flags, the probe's own
    <name>.flags and the Release flags, against aws-lc's headers. Building
    `:probe_<name>` succeeds exactly when the probe passes. (CMake's try_compile
    also links the probe; these compile it, which is what every probe here
    tests: a header, a declaration, a builtin or a flag.)

    Returns the arguments of the package's `cxx_library` call, which stays in
    the BUCK file: the rule there is the one the cell's `includes` wraps (a
    `native.cxx_library` from a .bzl is not, and the package then has no
    `doc_tree`).
    """
    return dict(
        name = "probe_" + name,
        srcs = ["komira//third_party/s2n-tls:src[tests/features/{}.c]".format(name)],
        compiler_flags = ["-O3", "-DNDEBUG"] + PROBE_GLOBAL_FLAGS.split(" ") + [f for f in flags.split(" ") if f],
        deps = ["komira//third_party/aws-lc:crypto"],
    )
