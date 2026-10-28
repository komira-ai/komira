"""The allowlist of the graph check //:python_closure (the root BUCK file;
tools/build/selftest/graph/python_closure.zig says what it refuses).

Python serves only komira's Python surface: its SDK or bindings and their own
tests. No other target depends on it and no other file is Python; CI runs it
only through those tests, in the pull-request sets.

PYTHON_SURFACE: package paths (`src/<pkg>`) where Python is allowed.
Adding one is a ruling, not a review; the shared library's bindings are one.

PYTHON_CEILING: the findings allowed today, exactly as the check spells them
(`target <label>`, `file <path>`, `exec <path>`). It only shrinks: the check
fails on an entry it no longer finds, so a change that removes a violator
deletes its entries here, and a new violator has no entry to land with.
"""

PYTHON_SURFACE = [
    # The hello test of python_binding_test, and the home of the binding tests
    # of the shared library (komira_so).
    "tools/build/examples/python_binding",
    # The Python binding of the shared library.
    "python",
]

PYTHON_CEILING = [
    # The pull-request sets build the binding tests of the surface.
    "target komira//ci:pr",
    "target komira//ci:pr_default",

    # The hermetic-Python rules, their runner scripts and their refusal fixture.
    "file tools/build/python/oracle_run.py",
    "file tools/build/python/pyrun.py",
    "file tools/build/python/wheel_install.py",
    "file tools/build/tests/negative/python_oracle/oracle.py",
    "target komira//tools/build/python:oracle_run.py",
    "target komira//tools/build/python:pyrun.py",
    "target komira//tools/build/python:wheel_install.py",

    # The pinned CPython, its wheels and the libraries they load.
    "target komira//third_party/python:cloudpickle-3.1.2-py3-none-any.whl",
    "target komira//third_party/python:cloudpickle-cp314",
    "target komira//third_party/python:cloudpickle-cp314t",
    "target komira//third_party/python:cpython",
    "target komira//third_party/python:cpython-3.13.16-20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "target komira//third_party/python:cpython-3.14.8-20261003-x86_64-unknown-linux-gnu-freethreaded-install_only_stripped.tar.gz",
    "target komira//third_party/python:cpython-3.14.8-20261003-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
    "target komira//third_party/python:cpython314",
    "target komira//third_party/python:cpython314t",
    "target komira//third_party/python:duckdb",
    "target komira//third_party/python:duckdb-1.5.6-cp313-cp313-manylinux_2_26_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:grpcio",
    "target komira//third_party/python:grpcio-1.84.0-cp313-cp313-manylinux2014_x86_64.manylinux_2_17_x86_64.whl",
    "target komira//third_party/python:joblib-1.6.0-py3-none-any.whl",
    "target komira//third_party/python:joblib-cp314",
    "target komira//third_party/python:joblib-cp314t",
    "target komira//third_party/python:libgcc_15.3.0_linux-64.conda",
    "target komira//third_party/python:libstdcxx_15.3.0_linux-64.conda",
    "target komira//third_party/python:libzlib_1.3.1_linux-64.conda",
    "target komira//third_party/python:narwhals-2.26.0-py3-none-any.whl",
    "target komira//third_party/python:narwhals-cp314",
    "target komira//third_party/python:narwhals-cp314t",
    "target komira//third_party/python:native_libs",
    "target komira//third_party/python:numpy",
    "target komira//third_party/python:numpy-2.5.3-cp313-cp313-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:numpy-2.5.3-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:numpy-2.5.3-cp314-cp314t-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:numpy-cp314",
    "target komira//third_party/python:numpy-cp314t",
    "target komira//third_party/python:pandas",
    "target komira//third_party/python:pandas-3.0.6-cp313-cp313-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:pandas-3.0.6-cp314-cp314-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:pandas-3.0.6-cp314-cp314t-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:pandas-cp314",
    "target komira//third_party/python:pandas-cp314t",
    "target komira//third_party/python:polars",
    "target komira//third_party/python:polars-1.44.2-py3-none-any.whl",
    "target komira//third_party/python:polars-runtime-32",
    "target komira//third_party/python:polars_runtime_32-1.44.2-cp310-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl",
    "target komira//third_party/python:protobuf",
    "target komira//third_party/python:protobuf-7.36.2-cp310-abi3-manylinux2014_x86_64.whl",
    "target komira//third_party/python:pyarrow",
    "target komira//third_party/python:pyarrow-25.0.1-cp313-cp313-manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:pyarrow-25.0.1-cp314-cp314-manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:pyarrow-25.0.1-cp314-cp314t-manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:pyarrow-cp314",
    "target komira//third_party/python:pyarrow-cp314t",
    "target komira//third_party/python:python-dateutil",
    "target komira//third_party/python:python-dateutil-cp314",
    "target komira//third_party/python:python-dateutil-cp314t",
    "target komira//third_party/python:python_dateutil-2.9.0.post0-py2.py3-none-any.whl",
    "target komira//third_party/python:scikit-learn-cp314",
    "target komira//third_party/python:scikit-learn-cp314t",
    "target komira//third_party/python:scikit_learn-1.9.1-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:scikit_learn-1.9.1-cp314-cp314t-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:scipy-1.18.1-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:scipy-1.18.1-cp314-cp314t-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl",
    "target komira//third_party/python:scipy-cp314",
    "target komira//third_party/python:scipy-cp314t",
    "target komira//third_party/python:six",
    "target komira//third_party/python:six-1.17.0-py2.py3-none-any.whl",
    "target komira//third_party/python:six-cp314",
    "target komira//third_party/python:six-cp314t",
    "target komira//third_party/python:threadpoolctl-3.7.0-py3-none-any.whl",
    "target komira//third_party/python:threadpoolctl-cp314",
    "target komira//third_party/python:threadpoolctl-cp314t",
    "target komira//third_party/python:typing-extensions",
    "target komira//third_party/python:typing_extensions-4.16.0-py3-none-any.whl",
    "target komira//third_party/python:tzdata",
    "target komira//third_party/python:tzdata-2026.5-py2.py3-none-any.whl",
    "target komira//third_party/python:tzdata-cp314",
    "target komira//third_party/python:tzdata-cp314t",

    # The CPython peer of the TLS interop tests.
    "file src/tests/e2e/komira_tls_interop_e2e/cpython_peer.py",
    "target komira//src/tests/e2e/komira_tls_interop_e2e:test_cpython_client_vs_komira_server",
    "target komira//src/tests/e2e/komira_tls_interop_e2e:test_komira_client_refuses_cpython_server",
    "target komira//src/tests/e2e/komira_tls_interop_e2e:test_komira_client_vs_cpython_server",

    # The fixture generators of a foreign (pyarrow) writer.
    "file src/komira_arrow_ipc/tests/fixtures/arrow_ipc/gen_fixtures.py",
    "file src/komira_arrow_ipc/tests/fixtures/arrow_ipc/gen_pyarrow_interop_fixtures.py",
    "file src/komira_parquet_codec/tests/fixtures/parquet/gen_pyarrow_fixtures.py",
    "file src/tests/e2e/komira_formats_e2e/tests/fixtures/orc/gen_pyarrow_orc_fixtures.py",
]
