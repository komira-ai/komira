import os
import sys
import time

with open(os.path.join(sys.argv[1], "stamp.txt"), "w") as f:
    f.write("%d %d\n" % (time.time_ns(), os.getpid()))
