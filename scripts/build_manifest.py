#!/usr/bin/env python3
"""Record source/dependency pins without collecting device or account data."""
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    pins={str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'server/requirements.lock',ROOT/'Vendor/libsignal/Cargo.lock',ROOT/'Vendor/TorRuntime/Package.swift'] if p.exists()}
    packages=[]
    for line in (ROOT/'server/requirements.lock').read_text().splitlines():
        if '==' in line and not line.startswith('#'):
            name=line.split('==')[0].split('[')[0]
            try: packages.append({'name':name,'installedVersion':importlib.metadata.version(name)})
            except importlib.metadata.PackageNotFoundError: pass
    result={'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            'libsignalCommit':'efe13e9b363d2c115dba61b76e5e53bbfc2874bc','torWrapperSourceCommit':'51cc492a817bbbc8a647b493d7dde2c0b765ae41',
            'fileDigests':pins,'pythonPackages':packages,'fullyReproducible':False,
            'limitations':['Tor binary uses upstream release and checksum; upstream does not claim reproducible builds','Container base images and system packages require separate operator digest pins','Device build is unsigned for Apple; GitHub provenance attests the archive, not an independent security audit']}
    directory=ROOT/'build-evidence'; directory.mkdir(exist_ok=True)
    (directory/'dependencies.json').write_text(json.dumps(result,indent=2)+'\n')

if __name__=='__main__': main()
