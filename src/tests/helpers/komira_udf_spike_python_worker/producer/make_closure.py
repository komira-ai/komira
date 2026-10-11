"""The producer side of a VALUE UDF, as an SDK would capture it: a plain,
type-hinted function defined in __main__ that closes over a loaded object
(a numpy "model"), serialized by value with cloudpickle.

Run by tests/test_fixtures.py (a py_test), which compares what it writes
with the committed tests/fixtures/closure (the payloads gzip'd). Writes
  payload      the payload
  payload_bad  the payload with its last byte flipped (a code object that
               does not match its digest)
  info.json    {"sha256", "payload_bytes", "model_bytes"}
`code_layer` (defs.bzl) then names each by the payload's sha256, as a code
layer does (komira_udf_spec.code_root holds code objects named by hex
sha256).

cloudpickle pickles a function by reference when its module can be imported,
and then the model would not ship; a function of __main__ is pickled by
value. The script refuses a payload smaller than the model, so a function
pickled by reference fails this build.
"""

import hashlib
import json
import os
import sys

import cloudpickle
import numpy as np

MODEL_MIB = 16

# A constant model (its pages are as private or shared as random ones), so
# the committed payload compresses to a few KiB (tests/fixtures/closure).
model = np.full((MODEL_MIB * 1024 * 1024 // 8 // 1024, 1024), 0.25)
model[0, 0] = 1.8


def score(x: np.ndarray) -> np.ndarray:
    """x * 1.8 + 32, the 1.8 read from the model."""
    return x * model[0, 0] + 32.0


def _path_free(f, name):
    """cloudpickle keeps the function's file name and its module's __file__;
    both are set to the script's bare name, so the bytes do not depend on
    where the script runs (tests/test_fixtures.py regenerates them)."""
    f.__code__ = f.__code__.replace(co_filename=name)
    f.__globals__["__file__"] = name


def main(out):
    _path_free(score, "make_closure.py")
    payload = cloudpickle.dumps(score)
    if len(payload) < model.nbytes:
        raise SystemExit(
            "make_closure: the payload is {} bytes, the model {}: score was pickled by reference".format(
                len(payload), model.nbytes
            )
        )
    sha = hashlib.sha256(payload).hexdigest()
    with open(os.path.join(out, "payload"), "wb") as f:
        f.write(payload)
    with open(os.path.join(out, "payload_bad"), "wb") as f:
        f.write(payload[:-1] + bytes([payload[-1] ^ 1]))
    with open(os.path.join(out, "info.json"), "w") as f:
        json.dump({"sha256": sha, "payload_bytes": len(payload), "model_bytes": int(model.nbytes)}, f)


if __name__ == "__main__":
    main(sys.argv[1])
