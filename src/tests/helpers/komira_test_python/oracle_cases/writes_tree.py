import os
import sys

out, data = sys.argv[1], sys.argv[2]
with open(os.path.join(out, "a.txt"), "w") as f:
    f.write("a\n")
os.makedirs(os.path.join(out, "sub"))
with open(os.path.join(out, "sub", "b.txt"), "w") as f:
    f.write("b\n")
with open(os.path.join(data, "in.txt")) as src, open(os.path.join(out, "copy.txt"), "w") as f:
    f.write(src.read())
# A set of strings iterates in hash order, the same in both runs only when the
# hash seed is.
with open(os.path.join(out, "set.txt"), "w") as f:
    f.write(",".join({"k%d" % i for i in range(64)}) + "\n")
