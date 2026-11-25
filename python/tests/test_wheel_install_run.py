"""The wheel tags the install driver (wheel_install_run.py) installs, as pip
would: `supported(tag, minor, machine, glibc, system, macos)` for the tags of
the wheels the install tests install, and for the ones they must refuse.

- an exact tag: `py3-none` on any minor, `cp3<m>-cp3<m>` on that minor alone;
- the stable ABI: `cp3<k>-abi3` on CPython 3.<k> and every later minor, never
  on an earlier one, and `abi3` with a Python tag that is not `cp3<k>` refused;
- the platform: `manylinux2014` and `manylinux_2_<n>` up to the C library's
  version, the machine, and on macOS `macosx_<v>_<machine>` or `universal2`
  up to the macOS version, never a Linux tag there or a macOS tag on Linux.

    test_wheel_install_run.py
"""

from wheel_install_run import supported

GLIBC = (2, 35)
LINUX_X86 = dict(machine="x86_64", glibc=GLIBC)
MAC = dict(machine="arm64", glibc=(0, 0), system="darwin", macos=(14, 0))


def test_an_exact_tag_installs_on_its_own_minor_alone():
    assert supported("py3-none-manylinux_2_35_x86_64", 11, **LINUX_X86)
    assert supported("cp313-cp313-manylinux_2_28_x86_64", 13, **LINUX_X86)
    assert not supported("cp312-cp312-manylinux_2_28_x86_64", 13, **LINUX_X86)
    assert not supported("cp313-cp313-manylinux_2_28_x86_64", 12, **LINUX_X86)


def test_the_stable_abi_installs_on_its_minor_and_later_ones():
    tag = "cp310-abi3-manylinux2014_x86_64"
    for minor in (10, 11, 12, 13, 14):
        assert supported(tag, minor, **LINUX_X86), minor
    assert not supported(tag, 9, **LINUX_X86)
    assert not supported("cp315-abi3-manylinux2014_x86_64", 14, **LINUX_X86)
    # abi3 is CPython's: a Python tag that is not `cp3<k>` does not make it one.
    assert not supported("py3-abi3-manylinux2014_x86_64", 13, **LINUX_X86)
    assert not supported("cp310-abi4-manylinux2014_x86_64", 13, **LINUX_X86)


def test_the_platform_must_be_this_machine_and_no_newer_c_library():
    assert supported("cp310-abi3-manylinux2014_x86_64", 13, **LINUX_X86)
    assert not supported("cp310-abi3-manylinux2014_aarch64", 13, **LINUX_X86)
    assert not supported("py3-none-manylinux_2_36_x86_64", 13, **LINUX_X86)
    assert not supported("cp310-abi3-macosx_10_9_universal2", 13, **LINUX_X86)


def test_macos_takes_its_machine_and_universal2_up_to_its_version():
    assert supported("cp310-abi3-macosx_10_9_universal2", 13, **MAC)
    assert supported("cp313-cp313-macosx_12_0_arm64", 13, **MAC)
    assert not supported("cp313-cp313-macosx_15_0_arm64", 13, **MAC)
    assert not supported("cp310-abi3-macosx_10_9_x86_64", 13, **MAC)
    assert not supported("cp310-abi3-manylinux2014_x86_64", 13, **MAC)


def test_a_tag_without_three_parts_is_refused():
    assert not supported("cp310-abi3", 13, **LINUX_X86)


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, test in tests:
        test()
    print("wheel_install_run tags: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
