import os
import sys

with open(os.path.join(sys.argv[1], "always.txt"), "w") as f:
    f.write("x\n")
if os.path.basename(os.path.dirname(sys.argv[1])) == "second":
    sys.exit(4)
