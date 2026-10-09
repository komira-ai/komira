import os
import sys

with open(os.path.join(sys.argv[1], "a.txt"), "w") as f:
    f.write("a\n")
os.symlink("a.txt", os.path.join(sys.argv[1], "link"))
