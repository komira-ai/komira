"""One-column record batches as pyarrow writes them, for the engine side's
decoder (native/probe_codec.c, case "pyarrow"): pyarrow builds its
flatbuffers back to front, shares vtables and leaves out fields at their
default, so its layout is not the one the engine and the worker write.

Run by tests/test_fixtures.py (a py_test), which compares what it writes
with the committed tests/fixtures/pyarrow_batches.txt. Writes out/batches.txt, one line per batch:
    name width rows nulls message_hex values_hex validity_hex
where values_hex is the rows' values (width bytes each, little endian, a
null row's as pyarrow wrote it; "." for no rows) and validity_hex the rows' validity bitmap
from row 0, or "-" when there are no nulls.
"""

import os
import sys

import numpy as np
import pyarrow as pa


def bitmap(arr):
    bits = np.array([arr[i].is_valid for i in range(len(arr))], dtype=bool)
    return np.packbits(bits, bitorder="little").tobytes()


def main(out):
    rng = np.random.default_rng(5)
    lines = []
    for typ, width, dtype in ((pa.int64(), 8, np.int64), (pa.float64(), 8, np.float64)):
        for n in (0, 1, 10, 100, 1000):
            for nulls_on in (False, True):
                for start in (0, 3):
                    total = n + start
                    vals = (rng.integers(-(1 << 60), 1 << 60, total) if dtype is np.int64 else rng.random(total) * 1e6)
                    mask = rng.random(total) < 0.25 if nulls_on else None
                    arr = pa.array(vals.astype(dtype), typ, mask=mask).slice(start)
                    msg = pa.record_batch([arr], names=["result"]).serialize().to_pybytes()
                    got = pa.ipc.read_record_batch(pa.py_buffer(msg), pa.schema([("result", typ)])).column(0)
                    values = got.buffers()[1]
                    raw = bytes(memoryview(values).cast("B"))[got.offset * width : (got.offset + n) * width]
                    name = "{}_{}_{}_{}".format(typ, n, "nulls" if nulls_on else "dense", start)
                    valid = bitmap(arr).hex() if arr.null_count else "-"
                    lines.append("{} {} {} {} {} {} {}".format(name, width, n, arr.null_count, msg.hex(), raw.hex() or ".", valid))
    with open(os.path.join(out, "batches.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
