"""`komira_test_python` -- the Mojo side of the hermetic Python tests.

This package exists for its test: `tests/test_oracle_output.mojo` reads, as
declared test data, the files a `python_oracle` (`:golden_sums`) wrote on the
farm, which shows that an oracle's output reaches a welded Mojo test. It has
no API.
"""
