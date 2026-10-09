import os
import sys

with open(os.path.join(sys.argv[1], "where.txt"), "w") as f:
    f.write(sys.argv[1] + "\n")
