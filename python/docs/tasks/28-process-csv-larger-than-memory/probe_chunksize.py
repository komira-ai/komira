# The form komira does not have yet: pandas' read_csv(chunksize=...), which
# hands back the file as an iterator of frames to loop over
# (komira-ai/komira#2369). It must fail with the line of
# probe_chunksize.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text("id,city,amount\n1,Oslo,5\n2,Lima,7\n3,Pune,9\n")

for chunk in komira.read_csv("sales.csv", chunksize=2):
    print(chunk)
