import os
import sys

path = os.path.join(sys.argv[1], "tool.sh")
with open(path, "w") as f:
    f.write("true\n")
if os.path.basename(os.path.dirname(sys.argv[1])) == "second":
    os.chmod(path, 0o755)
