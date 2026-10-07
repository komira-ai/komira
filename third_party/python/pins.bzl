"""The hermetic Python of the tests: the interpreter and the wheels, each pinned by sha256 and size.

Read by this package's BUCK, which declares the downloads and the installed
targets, and by tests that hold what they import to these pins
(src/tests/helpers/komira_test_python). Every wheel is a binary wheel for
CPython 3.13 on manylinux x86_64 (glibc 2.28 or older) or a pure-Python one;
there is no source distribution. `license` is the SPDX expression of the
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
    _wheel(
        "polars",
        "2.0.0",
        "https://files.pythonhosted.org/packages/ac/09/cc33bbd5463749c116b62c204d88bed6c02a6cb901eac7adab0d38651b07/polars-2.0.0-py3-none-any.whl",
        "35d62f3541b7a6d4c360a2e2f07fccc0c2bcbd33b0ea51c83a25417a47a3f3ad",
        876611,
        "MIT",
        deps = ["polars-runtime-32"],
    ),
    _wheel(
        "polars-runtime-32",
        "2.0.0",
        "https://files.pythonhosted.org/packages/83/88/e9fecfd49159da92f54ff2445883577a0f1bc195da53ecc9535c458d55dd/polars_runtime_32-2.0.0-cp310-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl",
        "0d6ac584ea2b38913784db943879412380d92e28ab9cb88e20a77ba71ba3f911",
        54475036,
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
]
