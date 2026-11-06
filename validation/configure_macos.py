#!/usr/bin/env python3
"""Configure an installed Homebrew MariaDB for this local validation suite.

Preserves the data directory and refuses to overwrite unrelated my.cnf files.
Creates a private test CA without adding it to the macOS trust store.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

MARKER = "# Local development MariaDB, managed by Homebrew."


def call(args, **kwargs):
    return subprocess.run(args,check=True,**kwargs)


def main():
    prefix=Path(subprocess.check_output(["brew","--prefix"],text=True).strip())
    package=Path(subprocess.check_output(["brew","--prefix","mariadb@12.3"],text=True).strip())
    openssl=prefix / "opt/openssl@4/bin/openssl"
    if not openssl.exists(): openssl=Path("openssl")
    config=prefix / "etc/my.cnf"
    if config.exists() and not config.read_text().startswith(MARKER):
        raise SystemExit(f"{config} already contains another configuration. Merge the documented validation settings into it explicitly.")
    tls=prefix / "var/mariadb-haskell/tls"
    tls.mkdir(parents=True,exist_ok=True,mode=0o700)
    def crypto(*args):
        result=subprocess.run([str(openssl),*map(str,args)],capture_output=True,text=True)
        if result.returncode: raise SystemExit(result.stderr)
    if not (tls / "ca.pem").exists():
        crypto("req","-x509","-newkey","rsa:2048","-nodes","-keyout",tls/"ca-key.pem","-out",tls/"ca.pem","-sha256","-days","3650","-subj","/CN=MariaDB Haskell Local Test CA")
    with tempfile.TemporaryDirectory(prefix="mariadb-haskell-tls-") as temporary:
        folder=Path(temporary)
        extension=folder/"tls.cnf"
        extension.write_text("[v3]\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:localhost,DNS:Winter,IP:127.0.0.1\n")
        for stem,days in [("server",365),("client",365),("expired-client",0)]:
            cert=tls/(stem+"-cert.pem"); key=tls/(stem+"-key.pem")
            if cert.exists() and key.exists():
                valid=subprocess.run([str(openssl),"x509","-in",str(cert),"-noout","-checkend","86400"],capture_output=True).returncode==0
                if not days or valid: continue
            request=folder/(stem+".csr")
            crypto("req","-new","-newkey","rsa:2048","-nodes","-keyout",key,"-out",request,"-subj","/CN=localhost")
            validity=["-days",str(days)] if days else ["-not_before","20200101000000Z","-not_after","20210101000000Z"]
            crypto("x509","-req","-in",request,"-CA",tls/"ca.pem","-CAkey",tls/"ca-key.pem","-CAcreateserial","-out",cert,*validity,"-sha256","-extfile",extension,"-extensions","v3")
    for path in tls.glob("*.pem"): path.chmod(0o600)
    config.write_text(f"""{MARKER}
[mariadbd]
bind-address=127.0.0.1
port=3306
max-allowed-packet=384M
server-id=610123
log-bin=mariadb-bin
binlog-format=ROW
binlog-row-image=FULL
binlog-checksum=CRC32
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-time-zone=+00:00
ssl-ca={tls}/ca.pem
ssl-cert={tls}/server-cert.pem
ssl-key={tls}/server-key.pem
""")
    config.chmod(0o644)
    call(["brew","services","restart","mariadb@12.3"])
    uid=os.getuid()
    subprocess.run(["launchctl","kickstart",f"gui/{uid}/sh.brew.mariadb@12.3"],check=False,capture_output=True)
    client=str(package/"bin/mariadb")
    for _ in range(30):
        result=subprocess.run([client,"--protocol=socket","--connect-timeout=1","--batch","--skip-column-names","-e","SELECT VERSION(), @@bind_address, @@have_ssl, @@log_bin"],capture_output=True,text=True)
        if result.returncode==0:
            print(result.stdout.strip()); break
        time.sleep(1)
    else: raise SystemExit("MariaDB did not become ready: "+result.stderr)
    print("Managed configuration:",config)
    print("Private local TLS files:",tls)


if __name__=="__main__": main()
