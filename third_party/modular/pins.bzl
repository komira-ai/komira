"""Modular's published wheels of the Mojo compiler, from PyPI, by Mojo version.

Read by this package's BUCK, which declares the downloads of the wheels the
tests take at the toolchain's Mojo (`USED`), and by python/BUCK, whose
`beside_modular` install tests take the pair at the toolchain's Mojo and the
compiler wheel of the newest other version. Each version has the compiler
wheel (manylinux_2_34 x86_64), whose `modular/lib/` holds the three Mojo
runtime libraries, and the wheel it requires
(`mojo-compiler-mojo-libs==<version>`). `sha256` and `size` are what PyPI
publishes for the file (https://pypi.org/pypi/<name>/<version>/json); the
target name is the URL's file name.

A toolchain pin at a version with no row here fails the load of this
package and of python/BUCK with the dictionary's missing key: add the
version's pair here in the same commit.
"""

load("@komira//tools/build/platforms:table.bzl", "asset")

MODULAR_WHEELS = {
    "1.0.0": {
        "compiler": {
            "url": "https://files.pythonhosted.org/packages/f0/5f/f38fefe327d1c81e28def69c4a52ae4f75e389cb6e613a2c04ca8d68d582/mojo_compiler-1.0.0-py3-none-manylinux_2_34_x86_64.whl",
            "sha256": "e9e60f9638e69ca0f4be7292468523fc98a143f58dbf9024f60ed68b874a867e",
            "size": 79142588,
        },
        "libs": {
            "url": "https://files.pythonhosted.org/packages/54/99/ea401ff1db56a4af8607283b95627e01b986fc67f510715b07f100118105/mojo_compiler_mojo_libs-1.0.0-py3-none-any.whl",
            "sha256": "20a92e37ecbd19e2dbb1a525612a8de4c9f266f5536def55c5e2b0786320e8b3",
            "size": 3187048,
        },
    },
    "1.1.0": {
        "compiler": {
            "url": "https://files.pythonhosted.org/packages/e8/5e/31522e5336d63ab0fad18980cccf6c5cc2085c1a041ea3723eb916a17c08/mojo_compiler-1.1.0-py3-none-manylinux_2_34_x86_64.whl",
            "sha256": "b47442278eb39705075f23d058b38a364bd68bdaa542ad514c187cee633beab7",
            "size": 80657416,
        },
        "libs": {
            "url": "https://files.pythonhosted.org/packages/83/8d/4fb2147d140b6ea688f6d256b3119d6554a3d50095d802f01bf24234bd7d/mojo_compiler_mojo_libs-1.1.0-py3-none-any.whl",
            "sha256": "dd8c5382e27fe5c1ffe0834d267f549abbffee35bf1a8d605cf24252ff95a2e6",
            "size": 3216162,
        },
    },
    "1.2.0": {
        "compiler": {
            "url": "https://files.pythonhosted.org/packages/54/8b/2758e8a2207793613d386f41e36f2bfd28837b157a659518c7b7474f7eb3/mojo_compiler-1.2.0-py3-none-manylinux_2_34_x86_64.whl",
            "sha256": "3ee34a3b26c6cccaa9523a0e8db8f67bea954497d782d97c9e61c3c4ecbdac7b",
            "size": 81774875,
        },
        "libs": {
            "url": "https://files.pythonhosted.org/packages/3d/bb/9602cbee467102584721c700dda8033af67c3888c6c8edb6f66275c1df74/mojo_compiler_mojo_libs-1.2.0-py3-none-any.whl",
            "sha256": "3d631f7e798c11d0029c4a892ebae1f5742751fac0c526af74b45a8ae07c3acb",
            "size": 3507893,
        },
    },
}

# The Mojo of the toolchain: the version of its linux-x86_64 conda pin
# (`mojo_compiler_<version>_<subdir>.conda`), the platform of the wheel and of
# these tests.
TOOLCHAIN_MOJO = asset("linux-x86_64", "mojo_compiler")["name"].split("_")[2]

def _key(version):
    return [int(p) for p in version.split(".")]

def modular_wheel(version, kind):
    """The target of Modular's `kind` wheel ("compiler" or "libs") at `version`."""
    return "komira//third_party/modular:" + MODULAR_WHEELS[version][kind]["url"].split("/")[-1]

def other_mojo(version):
    """The newest version of the table other than `version`: the Mojo of the
    install tests whose runtime is not the toolchain's."""
    others = sorted([v for v in MODULAR_WHEELS if v != version], key = _key)
    return others[-1]

def is_newer(version, than):
    """Whether Mojo `version` is a later release than `than`."""
    return _key(version) > _key(than)

# The Mojo of the tests whose runtime is not the toolchain's.
OTHER_MOJO = other_mojo(TOOLCHAIN_MOJO)

# The wheels the tests take at this toolchain, by version: the pair at its
# Mojo and the compiler wheel at OTHER_MOJO. Only these are declared, so the
# other rows cost nothing until a pin moves to them.
USED = {
    TOOLCHAIN_MOJO: ["compiler", "libs"],
    OTHER_MOJO: ["compiler"],
}
