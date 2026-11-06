#!/usr/bin/env python3
"""Verify MariaDB, rebuild current source, then validate with run.py.

Rebuilding prevents a stale executable from being measured after a source edit.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import run


def main():
    if "--help" in sys.argv or "-h" in sys.argv:
        return subprocess.call([sys.executable,str(run.HERE/"run.py"),"--help"])
    parser=argparse.ArgumentParser(add_help=False)
    parser.add_argument("--config",type=Path,default=run.HERE/".local/environment.json")
    args,_=parser.parse_known_args()
    try:
        env=os.environ.copy(); env.update(json.loads(args.config.read_text()))
        version=run.sql_client(env,"SELECT VERSION()")
        if "MariaDB" not in version: raise RuntimeError("expected MariaDB")
    except Exception as error:
        raise SystemExit("MariaDB must be installed, configured and running before validation. See validation/MACOS.md.\n"+str(error))
    print("Server verified before build:",version,flush=True)
    subprocess.run(["cabal","build","exe:mariadb-validation","test:test","test:integration","--enable-tests","-O2"],cwd=run.ROOT,check=True)
    return subprocess.call([sys.executable,str(run.HERE/"run.py"),*sys.argv[1:]],cwd=run.ROOT)


if __name__=="__main__": raise SystemExit(main())
