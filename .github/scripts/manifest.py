#!/usr/bin/env python3
"""HUMig-files.sha256 erstellen: SHA256 aller Dateien des ausgecheckten Commits (Inhalt wie im Repo, ohne .github/).
Erste Zeile: '# HUMig-Release <Tag>' - Pull.ps1 prueft damit, dass die (signierte) Datei zu genau diesem Release gehoert.
Danach Format wie sha256sum: '<hash>  <pfad>' - Pull.ps1 prueft damit jede geladene Datei.
Aufruf: manifest.py <Ausgabedatei> <Tag>   (Tag ersatzweise aus der Umgebungsvariable TAG)"""
import hashlib, os, re, subprocess, sys

out = sys.argv[1] if len(sys.argv) > 1 else 'HUMig-files.sha256'
tag = (sys.argv[2] if len(sys.argv) > 2 else os.environ.get('TAG', '')).strip()
if not re.fullmatch(r'[vV]?\d+(\.\d+){1,3}', tag):
    sys.exit(f"manifest.py: Tag fehlt oder ungueltig ('{tag}') - Aufruf: manifest.py <Datei> <Tag>")
files = [f for f in subprocess.check_output(['git', 'ls-files', '-z']).decode('utf-8').split('\0') if f and not f.startswith('.github/')]
lines = [f"# HUMig-Release {tag}"]
for f in sorted(files):
    data = subprocess.check_output(['git', 'show', 'HEAD:' + f])
    lines.append(f"{hashlib.sha256(data).hexdigest()}  {f}")
with open(out, 'w', encoding='utf-8', newline='\n') as fh:
    fh.write('\n'.join(lines) + '\n')
print(f"{len(lines) - 1} Dateien -> {out} (Release {tag})")
