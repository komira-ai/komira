"""The hermetic Python of the tests: the interpreter and the wheels, each pinned by sha256 and size.

Read by this package's BUCK, which declares the downloads and the installed
targets, except those of PROTOBUF_EDGES, which python/tests/BUCK declares.
Every wheel of WHEELS and PROTOBUF_EDGES is a binary
wheel for CPython 3.13 on manylinux x86_64 (glibc 2.28 or older) or a
pure-Python one, and every wheel of WHEELS_314 one for CPython 3.14 (`cp314`)
or free-threaded 3.14 (`cp314t`), or a pure-Python one; there is no source
distribution. CPython 3.10, 3.11 and 3.12 (PYTHON_310, PYTHON_311,
PYTHON_312) have no closure here; PYARROW_311_312 is their one pinned wheel. `license` is the SPDX expression of the
distribution as recorded in README.md (Licences); `deps` are the
distributions it requires on linux, by `name`.
"""

PYTHON = {
    "name": "cpython",
    "version": "3.13.16",
    "archive": "cpython-3.13.16-20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.13.16%2B20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "sha256": "4595c5589fff7bf0cb158d9a88a797e0d791fa33830770fcb7bf3f4b104feeae",
    "size": 35076205,
    "license": "PSF-2.0",
}

# CPython 3.14 from the same python-build-standalone release, with the GIL
# and free-threaded (`3.14t`, whose interpreter is `bin/python3.14t`), each
# with a closure of its own (WHEELS_314). Test-only, for measurements of
# Python user-defined functions and, with the GIL, for the Python package's
# tests (python/pythons.bzl); the 3.13 pin above stays every other test's
# interpreter.
PYTHON_314 = {
    "abi": "cp314",
    "archive": "cpython-3.14.8-20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "freethreaded": False,
    "license": "PSF-2.0",
    "name": "cpython314",
    "sha256": "d9ec7a6935ade8b671a57ebaf111083d7314eab8dae5071d167054dadd2b97d6",
    "size": 36299485,
    "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.14.8%2B20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "version": "3.14.8",
}

# CPython 3.11 and 3.12 from the same python-build-standalone release, with
# the GIL: the oldest minors the Python package supports
# (python/pythons.bzl), on which its tests and its wheel's install test run.
# Their closures are the wheels those tests install (python/tests/BUCK); no
# wheel here is for them.
PYTHON_311 = {
    "abi": "cp311",
    "archive": "cpython-3.11.17-20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "freethreaded": False,
    "license": "PSF-2.0",
    "name": "cpython311",
    "sha256": "aadcba18994cb8f9ee752aceb31d61e04f75b5d900d76fb575c6fbfabadec434",
    "size": 30785899,
    "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.11.17%2B20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "version": "3.11.17",
}

PYTHON_312 = {
    "abi": "cp312",
    "archive": "cpython-3.12.15-20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "freethreaded": False,
    "license": "PSF-2.0",
    "name": "cpython312",
    "sha256": "731af898886c5f821890dc901eca3c651cca8e51fa7308c159d12a1194aeac91",
    "size": 34285590,
    "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.12.15%2B20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "version": "3.12.15",
}

# CPython 3.10, the minor below the package's Requires-Python: one install
# test (python/BUCK, `refuses_python_outside_requires_python`) runs it to show
# that the wheel is refused there. Nothing else runs it.
PYTHON_310 = {
    "abi": "cp310",
    "archive": "cpython-3.10.22-20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "freethreaded": False,
    "license": "PSF-2.0",
    "name": "cpython310",
    "sha256": "d34d8c8df51eefaf23d1f19ca8b383d5bf6fc91579e370d0b8af7968ad97f8f0",
    "size": 29308448,
    "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.10.22%2B20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "version": "3.10.22",
}

PYTHON_314T = {
    "abi": "cp314t",
    "archive": "cpython-3.14.8-20261003-x86_64-unknown-linux-gnu-freethreaded-install_only_stripped.tar.gz",
    "freethreaded": True,
    "license": "PSF-2.0",
    "name": "cpython314t",
    "sha256": "076b84b988f4dee7ce3a8cb9b230fe5ef8f3c52df43e611edccc649a3433411d",
    "size": 36459200,
    "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.14.8%2B20261003-x86_64-unknown-linux-gnu-freethreaded-install_only_stripped.tar.gz",
    "version": "3.14.8",
}

# CPython 3.13 for macOS arm64 from the same python-build-standalone release as
# the linux archive, with the closure MACOS_WHEELS. The interpreter loads
# only the operating system's libraries, so it needs no `native_libs`.
PYTHON_MACOS = {
    "archive": "cpython-3.13.16-20261003-aarch64-apple-darwin-install_only_stripped.tar.gz",
    "license": "PSF-2.0",
    "name": "cpython_macos",
    "sha256": "9e01f63bbb08576cd9c8bc2d0564d098cb30c8453a0cd4bcf6aef458f6d2a147",
    "size": 25246115,
    "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.13.16%2B20261003-aarch64-apple-darwin-install_only_stripped.tar.gz",
    "version": "3.13.16",
}

def _wheel(name, version, url, sha256, size, license, deps = []):
    return {
        "deps": deps,
        "file": url.rsplit("/", 1)[1],
        "license": license,
        "name": name,
        "sha256": sha256,
        "size": size,
        "url": url,
        "version": version,
    }

WHEELS = [
    _wheel(
        "duckdb",
        "1.5.6",
        "https://files.pythonhosted.org/packages/70/21/61dd2876bbaa69cf77d7b5c620e52e8b25faae7096f4d2e4a812b52095d7/duckdb-1.5.6-cp313-cp313-manylinux_2_26_x86_64.manylinux_2_28_x86_64.whl",
        "644f54ce99b3b61844bc9a3fe80e0aecb1ea4084b1fffc4396d1569db6111679",
        21568700,
        "MIT",
    ),
    _wheel(
        "grpcio",
        "1.84.0",
        "https://files.pythonhosted.org/packages/da/56/548a643decb059ca244499c675ae2c13a15f523ba94592c2774bd80a13c1/grpcio-1.84.0-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.whl",
        "986e9751d416d7a6eaa2fecdac38da63153d63a4b340ba7d624889c490451500",
        7159572,
        "Apache-2.0",
        deps = ["typing-extensions"],
    ),
    _wheel(
        "numpy",
        "2.5.3",
        "https://files.pythonhosted.org/packages/3a/1b/3b16a9bc514a440a7a0883684111dcb1ef1aee960af2ca95da8fc775f124/numpy-2.5.3-cp313-cp313-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
        "a5fa86b80fd24bcd1aff83ad23be44ea323de3f787be8f8b15d4a65621e25321",
        16708577,
        "BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0",
    ),
    _wheel(
        "pandas",
        "3.0.6",
        "https://files.pythonhosted.org/packages/50/fa/96d50e1e6cd0b08b5e2b7c838f65ae644940f75a124063380b5ef73b6866/pandas-3.0.6-cp313-cp313-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl",
        "1e92d9fa834c7d877130027cddc0cad8dcff97c1f6cca26bd6310f847228b658",
        10757657,
        "BSD-3-Clause",
        deps = ["numpy", "python-dateutil"],
    ),
    # polars 1.44.2, the version komira's Python surface implements; polars 2
    # is a later change.
    _wheel(
        "polars",
        "1.44.2",
        "https://files.pythonhosted.org/packages/51/6d/3014112c7f717d1253223faa13b6db3ac3a64ed00ab2a3bc1b942bc9cdd4/polars-1.44.2-py3-none-any.whl",
        "1bb331f17a40d9d931101533dcd33637b66edc61eb377b07020dac16a0f0377b",
        865768,
        "MIT",
        deps = ["polars-runtime-32"],
    ),
    _wheel(
        "polars-runtime-32",
        "1.44.2",
        "https://files.pythonhosted.org/packages/e9/24/ed9982657c446dd5491b089370eea196725673570cfc61f7225a9fdd7ef0/polars_runtime_32-1.44.2-cp310-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl",
        "a1bafb441e99199a62c63bf1bbdc0ea09ee9776dbac2bf31452b5000fb1df2f7",
        49912258,
        "MIT",
    ),
    _wheel(
        "protobuf",
        "7.36.2",
        "https://files.pythonhosted.org/packages/db/f3/3996583dd2906297a637af12114deddf7658af6e683fedb83be061983fb5/protobuf-7.36.2-cp310-abi3-manylinux2014_x86_64.whl",
        "89f23aa53c24553a2416fd4fd1ec06f74fa42b14b546d8883128813f775bbfd2",
        343223,
        "BSD-3-Clause",
    ),
    _wheel(
        "pyarrow",
        "25.0.1",
        "https://files.pythonhosted.org/packages/98/d6/33a411115b61dbfc16ad6ad73e71730f6fea654ee3667673bc53ab0e2fe7/pyarrow-25.0.1-cp313-cp313-manylinux_2_28_x86_64.whl",
        "0befcf816e45a1af33ac775a9970b749e4868a230c7372f0ae5e932bee27039f",
        50104452,
        "Apache-2.0",
    ),
    _wheel(
        "python-dateutil",
        "2.9.0.post0",
        "https://files.pythonhosted.org/packages/ec/57/56b9bcc3c9c6a792fcbaf139543cee77261f3651ca9da0c93f5c1221264b/python_dateutil-2.9.0.post0-py2.py3-none-any.whl",
        "a8b2bc7bffae282281c8140a97d3aa9c14da0b136dfe83f850eea9a5f7470427",
        229892,
        "Apache-2.0 AND BSD-3-Clause",
        deps = ["six"],
    ),
    _wheel(
        "six",
        "1.17.0",
        "https://files.pythonhosted.org/packages/b7/ce/149a00dd41f10bc29e5921b496af8b574d8413afcd5e30dfa0ed46c2cc5e/six-1.17.0-py2.py3-none-any.whl",
        "4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274",
        11050,
        "MIT",
    ),
    _wheel(
        "typing-extensions",
        "4.16.0",
        "https://files.pythonhosted.org/packages/49/d3/b8441a820a491ddfc024b0b0cf0393375b75ea13866d9c66727e54c2fc80/typing_extensions-4.16.0-py3-none-any.whl",
        "481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8",
        45571,
        "PSF-2.0",
    ),
    # The IANA time-zone database (2026e) as a wheel: a py_test's TZDIR and
    # zoneinfo path (tools/build/python/README.md, Time zones).
    _wheel(
        "tzdata",
        "2026.5",
        "https://files.pythonhosted.org/packages/94/21/1e5995a1c920cce14e4bffae20c665ec10e7ed03ab25e006cd741092b718/tzdata-2026.5-py2.py3-none-any.whl",
        "b683bd1b6659ddcd810ff02ad09ba821d4bf1065072805063eb35c49617905ac",
        347996,
        "Apache-2.0",
    ),
]

_PYPI = "https://files.pythonhosted.org/packages/"

# The pure-Python wheels of both 3.14 closures (one file each, installed once
# per interpreter); six, python-dateutil and tzdata are WHEELS' files.
_PURE_314 = [
    _wheel(
        "cloudpickle",
        "3.1.2",
        _PYPI + "88/39/799be3f2f0f38cc727ee3b4f1445fe6d5e4133064ec2e4115069418a5bb6/cloudpickle-3.1.2-py3-none-any.whl",
        "9acb47f6afd73f60dc1df93bb801b472f05ff42fa6c84167d25cb206be1fbf4a",
        22228,
        "BSD-3-Clause",
    ),
    _wheel(
        "joblib",
        "1.6.0",
        _PYPI + "18/53/84099323c2ec4be98d935f63c033ac4151ee83836ca1050ede3b3aadf155/joblib-1.6.0-py3-none-any.whl",
        "3dbbf9f6e4b592a2357b854608e980fe6390d131d7a82f011a377ef2ebef7aba",
        306115,
        "BSD-3-Clause",
        deps = ["cloudpickle"],
    ),
    _wheel(
        "narwhals",
        "2.26.0",
        _PYPI + "40/b5/1b84b2c784db76d69442334bc8b8748c840f13ca53be086f4f250ad4a0bc/narwhals-2.26.0-py3-none-any.whl",
        "29326d74f107c347fd1009bd58e38d9f7c7c5b51e6de97bc93dbc325d9038b54",
        474034,
        "MIT",
    ),
    _wheel(
        "threadpoolctl",
        "3.7.0",
        _PYPI + "43/3f/f88a53f60a472b46f4023f56d204dd7de33d34c5d2acbfa0d70a674e639e/threadpoolctl-3.7.0-py3-none-any.whl",
        "cd8b60b5641b45c67bbf73c64c843235fc2d8a480c87389f52f5dbee893b86be",
        26362,
        "BSD-3-Clause",
    ),
] + [w for w in WHEELS if w["name"] in ("python-dateutil", "six", "tzdata")]

# The binary wheels of numpy, pandas, pyarrow, scipy and scikit-learn for one
# ABI tag, each given as (url path, sha256, size).
def _binary_314(numpy, pandas, pyarrow, scipy, sklearn):
    return [
        _wheel("numpy", "2.5.3", _PYPI + numpy[0], numpy[1], numpy[2], "BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0"),
        _wheel("pandas", "3.0.6", _PYPI + pandas[0], pandas[1], pandas[2], "BSD-3-Clause", deps = ["numpy", "python-dateutil"]),
        _wheel("pyarrow", "25.0.1", _PYPI + pyarrow[0], pyarrow[1], pyarrow[2], "Apache-2.0"),
        _wheel("scipy", "1.18.1", _PYPI + scipy[0], scipy[1], scipy[2], "BSD-3-Clause", deps = ["numpy"]),
        _wheel(
            "scikit-learn",
            "1.9.1",
            _PYPI + sklearn[0],
            sklearn[1],
            sklearn[2],
            "BSD-3-Clause",
            deps = ["joblib", "narwhals", "numpy", "scipy", "threadpoolctl"],
        ),
    ]

# {abi: the closure of that interpreter}: binary wheels for `cp314-cp314`
# (with the GIL) or `cp314-cp314t` (free-threaded), manylinux x86_64, and the
# pure-Python ones. Every distribution pinned for 3.14 has a cp314t wheel.
WHEELS_314 = {
    "cp314": _binary_314(
        ("45/8f/9beacf79ca7c650688ad0baa80931adb988fe6e6e5d5903c23cc3dbd70eb/numpy-2.5.3-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl", "b0521d0f4aebb6e06189451025fa17a913287b13c03d5fe05c017333b654ea5b", 16711928),
        ("ca/ba/ffdcb19be4ff6bfe7d969e7cef2c567c633df5a3a1cc1053394ad053bca8/pandas-3.0.6-cp314-cp314-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl", "62f51d7f651c8054c5e82a69265c98082e795d1442df7ca6edc3a545d61214b1", 10783244),
        ("8d/61/1c5d1229fa21da4cff5365e41e57177aaac57c563c727f35419b8513d1c1/pyarrow-25.0.1-cp314-cp314-manylinux_2_28_x86_64.whl", "9171748cdf796972d85a4b60157c279913e242992e350c90c7450182a9838b2a", 50131616),
        ("6b/89/2a844506d49651e9aa1af6ef95b6bd8031cb1d5a4375edec6155037e04cf/scipy-1.18.1-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl", "ac0333bdf38309aa3dcbe7e3fa7ea29e7a2c37c6ea306a757b700ded8e4596ad", 35329183),
        ("86/4e/0bab75490ca4b85fad8388739c7ebc71d9db553f8c69e39943ee8db0aaae/scikit_learn-1.9.1-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl", "993d332ff80e62efae9e39603b7e872297c418d780f01a01855269a3489c950f", 9152030),
    ) + _PURE_314,
    "cp314t": _binary_314(
        ("59/08/9df04103947b95e3b6b1f2ed1a70521f325647a31b82da6a2aae3a485508/numpy-2.5.3-cp314-cp314t-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl", "93e1f5447e2b1e479d7bd74701e84746b86450cff1fc368b132d195e2b8f8211", 16746748),
        ("04/f5/001e230a7a7803590d9275a1a3f7e1bb605e3a495cfe5e8d3a532090621b/pandas-3.0.6-cp314-cp314t-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl", "db7ec631f26223beee8e5c9e0b8f23c24d8197bbd1d982421d4e3188bea51965", 10655952),
        ("1b/b9/58612e977d28dc58c878448866838369ee8da2f1e7cc8ed2c84b952aafee/pyarrow-25.0.1-cp314-cp314t-manylinux_2_28_x86_64.whl", "6a1fdfc6659b6b19022f2e50627fb5cf7156a66c46bf4299379955cbe742382a", 50079036),
        ("87/53/39d046cc7574ed6acacb6bd5723e220107ece80bff12faaf3efc4ddeede4/scipy-1.18.1-cp314-cp314t-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl", "a1d33a7836f7ddc1993427966a0823468ec41bcbdb1a9f9942d1d7e57f803ba3", 35380876),
        ("1a/5a/4cb6c85160af4a639e87a3b7bf8b1c25cfc3b504c5af710ca416a6dcfc5f/scikit_learn-1.9.1-cp314-cp314t-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl", "748bcb0a4cc04aec470652c9e5ec68450948e867387e7dfade647107ade68d25", 9131227),
    ) + _PURE_314,
}

# The other runtimes of the protobuf range the Python package declares
# (`PROTOBUF_REQUIREMENT`, python/dependencies.bzl), each for the 3.13 pin:
# 5.29.1 is the range's lower edge, the version of the gencode protoc 29.1
# writes and the oldest runtime that loads it; 5.28.3 is the release below it,
# which must refuse that gencode. The upper edge is WHEELS' 7.36.2. They are not
# in WHEELS, whose targets are named by distribution alone: python/tests/BUCK
# declares their downloads and installed targets (`:protobuf-<version>`), for
# the tests there only.
PROTOBUF_EDGES = [
    _wheel(
        "protobuf",
        "5.29.1",
        _PYPI + "04/52/c97c58a33b3d6c89a8138788576d372a90a6556f354799971c6b4d16d871/protobuf-5.29.1-cp38-abi3-manylinux2014_x86_64.whl",
        "8ee1461b3af56145aca2800e6a3e2f928108c749ba8feccc6f5dd0062c410c0d",
        319671,
        "BSD-3-Clause",
    ),
    _wheel(
        "protobuf",
        "5.28.3",
        _PYPI + "5d/ae/3257b09328c0b4e59535e497b0c7537d4954038bdd53a2f0d2f49d15a7c4/protobuf-5.28.3-cp38-abi3-manylinux2014_x86_64.whl",
        "712319fbdddb46f21abb66cd33cb9e491a5763b2febd8f228251add221981135",
        316624,
        "BSD-3-Clause",
    ),
]

# pyarrow 25.0.1, the version of WHEELS and WHEELS_314, for CPython 3.11 and
# 3.12 (`cp311`, `cp312`; manylinux x86_64), by ABI tag: the Python package
# requires pyarrow (`PYARROW_REQUIREMENT`, python/dependencies.bzl), so its
# tests and its wheel's install tests on those minors install it. They are not
# in WHEELS, whose wheels are for 3.13: python/tests/BUCK declares their
# downloads and installed targets (`:pyarrow-cp311`, `:pyarrow-cp312`).
PYARROW_311_312 = {
    "cp311": _wheel(
        "pyarrow",
        "25.0.1",
        _PYPI + "c8/6e/d3fafc41f378b2c65be43b827798c0fae42049a641c8526633ed3eb573e2/pyarrow-25.0.1-cp311-cp311-manylinux_2_28_x86_64.whl",
        "25f8720bf6387d5dc2ebd2622112de630760419e4b66134405dd24110d15f37e",
        50065507,
        "Apache-2.0",
    ),
    "cp312": _wheel(
        "pyarrow",
        "25.0.1",
        _PYPI + "60/c9/711ca85d79f1ec98f29a5eae2b051e25b4ecec5de3e3c0e2d5c5dcb15664/pyarrow-25.0.1-cp312-cp312-manylinux_2_28_x86_64.whl",
        "5389cdf79447ed1515c9e31620e6e1e2302249564d603f2ad727d4f6d313e4c3",
        50102437,
        "Apache-2.0",
    ),
}

# The macOS arm64 file of each WHEELS distribution that has a binary build: the
# same version as the linux wheel, a CPython 3.13 (`cp313`) or abi3 wheel tagged
# `macosx_<floor>_arm64` (`universal2` where no arm64-only wheel is published),
# floor 12.0 at most. A distribution of WHEELS that is not here is a
# pure-Python wheel, the same file on both platforms.
MACOS_WHEELS = {
    "duckdb": {
        "url": "https://files.pythonhosted.org/packages/d4/a0/bf87071170835ee4a34fe764fc11c1c6e7040a0e021b36c1b6f834a4c22f/duckdb-1.5.6-cp313-cp313-macosx_11_0_arm64.whl",
        "sha256": "97dd7a555b8f5298b76bc7d48a11cb2c64336e8de9bfde783cffb86ea9f54807",
        "size": 15533132,
    },
    "grpcio": {
        "url": "https://files.pythonhosted.org/packages/c5/4b/ed8e22a1237e6b2be6ef4f221d074a5b0e0dd8a0da8c944c04aea731f0eb/grpcio-1.84.0-cp313-cp313-macosx_11_0_universal2.whl",
        "sha256": "e41c3993eee896c617dbd8a505085d28b6e84a0445ed9a1f40f95808473cf678",
        "size": 12336549,
    },
    "numpy": {
        "url": "https://files.pythonhosted.org/packages/2f/06/9dc9e48b5e5e941c8b10350c5ff2d721da42a20517d911d15544246775ff/numpy-2.5.3-cp313-cp313-macosx_11_0_arm64.whl",
        "sha256": "92f30e89b8ee0ecf363033576c422b2f58fed6a80bed0aa48dff6d14c654663e",
        "size": 12003676,
    },
    "pandas": {
        "url": "https://files.pythonhosted.org/packages/ea/ca/87f8548f73d452aab35e4a90f8b39ae303295e0f2ef0b4055c44d6b3f1be/pandas-3.0.6-cp313-cp313-macosx_11_0_arm64.whl",
        "sha256": "60d81f9e1799b36f3739e7fff44d1fbb2e8fd5a271b3863e03de9715fccda0fa",
        "size": 10064785,
    },
    "polars-runtime-32": {
        "url": "https://files.pythonhosted.org/packages/c2/e0/f3dc93fce4b4e99370db6a89001a1b8d3c606e3560d0d91dda809d6c6324/polars_runtime_32-1.44.2-cp310-abi3-macosx_11_0_arm64.whl",
        "sha256": "e0fd43720c8222ae39919c8ff891636d53b352706087120e62f83544dd3ff782",
        "size": 43331099,
    },
    "protobuf": {
        "url": "https://files.pythonhosted.org/packages/32/72/98342feb672507c8f3a69e34b4fa8961f608edba5c1a48a6f47156d92cb5/protobuf-7.36.2-cp310-abi3-macosx_10_9_universal2.whl",
        "sha256": "cbc70b17ee27e28894c7fee8bb04be1abead49e936bc70eb60052531eee2079e",
        "size": 456039,
    },
    "pyarrow": {
        "url": "https://files.pythonhosted.org/packages/cc/8d/8f271a7a034c834910ec925d56fa4b29733b1380f5289419f5aaa3b02777/pyarrow-25.0.1-cp313-cp313-macosx_12_0_arm64.whl",
        "sha256": "c7c534ec03c358a76ea3e505e74c1b6aef290af90c444dfd092dbfe23e755b85",
        "size": 35855328,
    },
}
