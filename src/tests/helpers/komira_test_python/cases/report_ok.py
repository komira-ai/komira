import os
import sys

# Half through sys.stdout, half straight to file descriptor 1: both are the report.
sys.stdout.write('{"a": 1, ')
sys.stdout.flush()
os.write(1, b'"b": [2]}\n')
sys.stderr.write("stderr is not captured\n")
