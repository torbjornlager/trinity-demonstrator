import subprocess,sys
from pathlib import Path
P=Path(__file__).resolve().parent
for name in ['smoke_context.py','smoke_exercises.py','smoke_swi.py','smoke_n5.py']:
 subprocess.run([sys.executable,str(P/name)],check=True)
