"""The hermetic Python of the tests: the interpreter and the wheels, each pinned by sha256 and size.

Read by this package's BUCK, which declares the downloads and the installed
targets, and by tests that hold what they import to these pins
(src/tests/helpers/komira_test_python). Every wheel of WHEELS is a binary
wheel for CPython 3.13 on manylinux x86_64 (glibc 2.28 or older) or a
pure-Python one, and every wheel of WHEELS_314 one for CPython 3.14 (`cp314`)
or free-threaded 3.14 (`cp314t`), or a pure-Python one; there is no source
distribution. `license` is the SPDX expression of the
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
# Python user-defined functions; the 3.13 pin above stays every other test's
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
