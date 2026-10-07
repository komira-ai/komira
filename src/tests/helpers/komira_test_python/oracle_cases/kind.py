import os
import sys

with open(os.path.join(sys.argv[1], "always.txt"), "w") as f:
    f.write("x\n")
path = os.path.join(sys.argv[1], "x")
if os.path.basename(os.path.dirname(sys.argv[1])) == "second":
    with open(path, "w") as f:
        f.write("x\n")
else:
    os.mkdir(path)
