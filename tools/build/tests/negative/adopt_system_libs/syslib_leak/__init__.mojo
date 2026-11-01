"""syslib_leak: depends on syslib_viatd, whose test_deps (not deps) name the adopted package, and on the codec without its pins."""


def two() -> Int:
    return 2
