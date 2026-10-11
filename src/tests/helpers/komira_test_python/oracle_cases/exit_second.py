import os
import sys

with open(os.path.join(sys.argv[1], "always.txt"), "w") as f:
    f.write("x\n")
if os.path.basename(os.path.dirname(sys.argv[1])) == "second":
    # os._exit skips the child's SystemExit handling, so the runner sees status 5 itself.
    os._exit(5)
