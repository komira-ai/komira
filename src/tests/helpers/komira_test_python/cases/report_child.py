import subprocess
import sys

# Half from the script, half from a child process it starts, which inherits
# file descriptor 1: both are the report.
sys.stdout.write('{"a": 1, ')
sys.stdout.flush()
subprocess.run([sys.executable, "-I", "-S", "-c", "import os; os.write(1, b'\"b\": [2]}\\n')"], check=True)
