#!/bin/bash
# cloudinit.sh — Oracle 23ai Free + GenAI stack bootstrap (merged & hardened)

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# --------------------------------------------------------------------
# Grow filesystem (best-effort)
# --------------------------------------------------------------------
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# --------------------------------------------------------------------
# PRE: install Podman so the DB unit can run right away (with resilient dnf)
# --------------------------------------------------------------------
echo "[PRE] installing Podman and basics"

# DNS/egress wait + repo fallback, so yum can't stall on ksplice
echo "[PRE] wait for DNS/egress"
for i in {1..30}; do
  getent hosts yum.oracle.com >/dev/null 2>&1 && break
  sleep 5
done

echo "[PRE] try cache; if ksplice blocks, disable it"
(dnf -y makecache --refresh || true)
dnf config-manager --set-disabled ol8_ksplice || true

echo "[PRE] enable OL8 addons and refresh cache"
dnf -y install dnf-plugins-core || true
dnf config-manager --set-enabled ol8_addons || true
(dnf -y makecache --refresh || true)

# Minimal tools needed immediately
dnf -y install podman curl grep coreutils shadow-utils unzip git jq python3 python3-pip || true
/usr/bin/podman --version || { echo "[PRE] podman missing"; exit 1; }

# ====================================================================
# genai-setup.sh (MAIN provisioning)
# ====================================================================
cat >/usr/local/bin/genai-setup.sh <<'SCRIPT'
#!/bin/bash
set -uxo pipefail

echo "===== GenAI OneClick systemd: start $(date -u) ====="

MARKER="/var/lib/genai.oneclick.done"
if [[ -f "$MARKER" ]]; then
  echo "[INFO] already provisioned; exiting."
  exit 0
fi

retry() { local max=${1:-5}; shift; local n=1; until "$@"; do rc=$?; [[ $n -ge $max ]] && echo "[RETRY] failed after $n: $*" && return $rc; echo "[RETRY] $n -> retrying in $((n*5))s: $*"; sleep $((n*5)); n=$((n+1)); done; return 0; }

# PRE: make dnf resilient in this stage too
echo "[STEP][PRE] dnf preflight"
for i in {1..30}; do
  getent hosts yum.oracle.com >/dev/null 2>&1 && break
  sleep 5
done
retry 3 dnf -y makecache --refresh || true
dnf config-manager --set-disabled ol8_ksplice || true
retry 5 dnf config-manager --set-enabled ol8_addons || true
retry 5 dnf -y makecache --refresh || true

echo "[STEP] enable ol8_addons and install base pkgs"
retry 5 dnf -y install dnf-plugins-core curl
retry 5 dnf config-manager --set-enabled ol8_addons || true
retry 5 dnf -y makecache --refresh
retry 5 dnf -y install git unzip jq tar make gcc gcc-c++ bzip2 bzip2-devel zlib-devel openssl-devel readline-devel libffi-devel wget curl which xz python3 python3-pip podman firewalld

echo "[STEP] enable firewalld"
systemctl enable --now firewalld || true

echo "[STEP] create /opt/genai and /home/opc/code"
mkdir -p /opt/genai /home/opc/code /home/opc/bin
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin

echo "[STEP] fetch css-navigator/gen-ai into /home/opc/code"
CODE_DIR="/home/opc/code"
mkdir -p "$CODE_DIR"

# preflight tools
if ! command -v git   >/dev/null 2>&1; then retry 5 dnf -y install git;   fi
if ! command -v curl  >/dev/null 2>&1; then retry 5 dnf -y install curl;  fi
if ! command -v unzip >/dev/null 2>&1; then retry 5 dnf -y install unzip; fi

TMP_DIR="$(mktemp -d)"
REPO_ZIP="/tmp/cssnav.zip"

# Try sparse checkout first
retry 5 git clone --depth 1 --filter=blob:none --sparse https://github.com/ou-developers/css-navigator.git "$TMP_DIR" || true
retry 5 git -C "$TMP_DIR" sparse-checkout init --cone || true
retry 5 git -C "$TMP_DIR" sparse-checkout set gen-ai || true

if [ -d "$TMP_DIR/gen-ai" ] && [ -n "$(ls -A "$TMP_DIR/gen-ai" 2>/dev/null)" ]; then
  echo "[STEP] copying from sparse-checkout"
  chmod -R a+rx "$TMP_DIR/gen-ai" || true
  cp -a "$TMP_DIR/gen-ai"/. "$CODE_DIR"/
else
  echo "[STEP] sparse-checkout empty; falling back to zip"
  retry 5 curl -L -o "$REPO_ZIP" https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main
  TMP_ZIP_DIR="$(mktemp -d)"
  unzip -q -o "$REPO_ZIP" -d "$TMP_ZIP_DIR"
  if [ -d "$TMP_ZIP_DIR/css-navigator-main/gen-ai" ]; then
    chmod -R a+rx "$TMP_ZIP_DIR/css-navigator-main/gen-ai" || true
    cp -a "$TMP_ZIP_DIR/css-navigator-main/gen-ai"/. "$CODE_DIR"/
  else
    echo "[WARN] gen-ai folder not found in zip"
  fi
  rm -rf "$TMP_ZIP_DIR" "$REPO_ZIP"
fi

rm -rf "$TMP_DIR"

# ownership and a backward-compat symlink
chown -R opc:opc "$CODE_DIR" || true
chmod -R a+rX "$CODE_DIR" || true
ln -sfn "$CODE_DIR" /opt/code || true

echo "[STEP] embed user's init-genailabs.sh (no DB start here; DB unit handles it)"
cat >/opt/genai/init-genailabs.sh <<'USERSCRIPT'
#!/bin/bash
set -Eeuo pipefail
LOGFILE=/var/log/cloud-init-output.log
exec > >(tee -a $LOGFILE) 2>&1

MARKER_FILE="/home/opc/.init_done"
if [ -f "$MARKER_FILE" ]; then
  echo "Init script has already been run. Exiting."
  exit 0
fi

echo "===== Starting Cloud-Init User Script ====="

# Expand boot volume (best-effort)
sudo /usr/libexec/oci-growfs -y || true

# Build prerequisites (SQLite path kept)
sudo dnf config-manager --set-enabled ol8_addons || true
sudo dnf install -y git libffi-devel bzip2-devel ncurses-devel readline-devel wget make gcc zlib-devel openssl-devel || true

# Install latest SQLite from source (kept)
cd /tmp
wget -q https://www.sqlite.org/2023/sqlite-autoconf-3430000.tar.gz
tar -xzf sqlite-autoconf-3430000.tar.gz
cd sqlite-autoconf-3430000
./configure --prefix=/usr/local
make -s
sudo make install
/usr/local/bin/sqlite3 --version || true

# PATH/LD for SQLite (kept)
echo 'export PATH="/usr/local/bin:$PATH"' >> /home/opc/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"' >> /home/opc/.bashrc
echo 'export CFLAGS="-I/usr/local/include"' >> /home/opc/.bashrc
echo 'export LDFLAGS="-L/usr/local/lib"' >> /home/opc/.bashrc
source /home/opc/.bashrc

# Persistent oradata
sudo mkdir -p /home/opc/oradata
sudo chown -R 54321:54321 /home/opc/oradata
sudo chmod -R 755 /home/opc/oradata

# Wait for DB container + FREEPDB1 registration
echo "Waiting for 23ai container to be created..."
for i in {1..120}; do
  if /usr/bin/podman ps -a --format '{{.Names}}' | grep -qw 23ai; then
    echo "23ai container exists."
    break
  fi
  sleep 5
done

echo "Waiting for FREEPDB1 service to be registered with the listener..."
for i in {1..180}; do
  if /usr/bin/podman exec 23ai bash -lc '. /home/oracle/.bashrc; lsnrctl status' | grep -qi 'Service "FREEPDB1"'; then
    echo "FREEPDB1 service is registered."
    break
  fi
  sleep 10
done

# Quick connection smoke (non-fatal)
OUTPUT=$(/usr/bin/podman exec 23ai bash -lc 'echo | sqlplus -S -L sys/database123@127.0.0.1:1521/FREEPDB1 as sysdba || true')
echo "$OUTPUT" | tail -n 2

# (Optional) CDB root tweaks (kept but non-fatal)
echo "Switching to CDB root for system-level changes..."
sudo /usr/bin/podman exec -i 23ai bash -lc '. /home/oracle/.bashrc; sqlplus -S -L / as sysdba <<EOSQL
WHENEVER SQLERROR CONTINUE
CREATE PFILE FROM SPFILE;
ALTER SYSTEM SET vector_memory_size = 512M SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT
EOSQL' || true

# Install a Python 3.9 venv for Jupyter + libs (no labs dir)
sudo -u opc bash -lc '
  python3.9 -m venv $HOME/.venvs/genai || true
  echo "source $HOME/.venvs/genai/bin/activate" >> $HOME/.bashrc
  source $HOME/.venvs/genai/bin/activate
  python -m pip install --upgrade pip wheel setuptools
  pip install --no-cache-dir jupyterlab==4.2.5 streamlit==1.36.0 oracledb sentence-transformers langchain==0.2.6 langchain-community==0.2.6 langchain-chroma==0.1.2 langchain-core==0.2.11 langchain-text-splitters==0.2.2 langsmith==0.1.83 pypdf==4.2.0 python-multipart==0.0.9 chroma-hnswlib==0.7.3 chromadb==0.5.3 torch==2.5.0 oci oracle-ads
'

# OCI CLI (user-local)
sudo -u opc bash -lc '
  curl -sSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/oci-install.sh
  bash /tmp/oci-install.sh --accept-all-defaults --exec-dir $HOME/bin --install-dir $HOME/lib/oci-cli --update-path false
  grep -q "export PATH=\$HOME/bin" $HOME/.bashrc || echo "export PATH=\$HOME/bin:\$PATH" >> $HOME/.bashrc
  echo "export PATH=\$PATH:\$HOME/.local/bin" >> $HOME/.bashrc
  source $HOME/.bashrc
'

touch "$MARKER_FILE"
echo "===== Cloud-Init User Script Completed Successfully ====="
exit 0
USERSCRIPT
chmod +x /opt/genai/init-genailabs.sh
cp -f /opt/genai/init-genailabs.sh /home/opc/init-genailabs.sh || true
chown opc:opc /home/opc/init-genailabs.sh || true

echo "[STEP] install Python 3.9 for OL8 and create venv (base)"
retry 5 dnf -y module enable python39 || true
retry 5 dnf -y install python39 python39-pip || true

echo "[STEP] seed /opt/genai content"
cat >/opt/genai/LoadProperties.py <<'PY'
class LoadProperties:
    def __init__(self):
        import json
        with open('config.txt') as f:
            js = json.load(f)
        self.model_name = js.get("model_name")
        self.embedding_model_name = js.get("embedding_model_name")
        self.endpoint = js.get("endpoint")
        self.compartment_ocid = js.get("compartment_ocid")
    def getModelName(self): return self.model_name
    def getEmbeddingModelName(self): return self.embedding_model_name
    def getEndpoint(self): return self.endpoint
    def getCompartment(self): return self.compartment_ocid
PY
cat >/opt/genai/config.txt <<'CFG'
{"model_name":"cohere.command-r-16k","embedding_model_name":"cohere.embed-english-v3.0","endpoint":"https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com","compartment_ocid":"ocid1.compartment.oc1....replace_me..."}
CFG
mkdir -p /opt/genai/txt-docs /opt/genai/pdf-docs
echo "faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier." >/opt/genai/txt-docs/faq.txt
chown -R opc:opc /opt/genai

echo "[STEP] write start_jupyter.sh"
cat >/home/opc/start_jupyter.sh <<'SH'
#!/bin/bash
set -eux
source $HOME/.venvs/genai/bin/activate
jupyter lab --NotebookApp.token='' --NotebookApp.password='' --ip=0.0.0.0 --port=8888 --no-browser
SH
chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

echo "[STEP] open firewall ports"
for p in 8888 8501 1521; do firewall-cmd --zone=public --add-port=${p}/tcp --permanent || true; done
firewall-cmd --reload || true

echo "[STEP] run user's init-genailabs.sh (non-fatal)"
set +e
bash /opt/genai/init-genailabs.sh
USR_RC=$?
set -e
echo "[STEP] user init script exit code: $USR_RC"

touch "$MARKER"
echo "===== GenAI OneClick systemd: COMPLETE $(date -u) ====="
SCRIPT
chmod +x /usr/local/bin/genai-setup.sh

# ====================================================================
# genai-db.sh (DB container) — robust bootstrap for 23ai
# ====================================================================
cat >/usr/local/bin/genai-db.sh <<'DBSCR'
#!/bin/bash
set -Eeuo pipefail

PODMAN="/usr/bin/podman"
log(){ echo "[DB] $*"; }
retry() { local t=${1:-5}; shift; local n=1; until "$@"; do local rc=$?;
  if (( n>=t )); then return "$rc"; fi
  log "retry $n/$t (rc=$rc): $*"; sleep $((n*5)); ((n++));
done; }

ORACLE_PWD="database123"
ORACLE_PDB="FREEPDB1"
ORADATA_DIR="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
NAME="23ai"

log "start $(date -u)"
mkdir -p "$ORADATA_DIR" && chown -R 54321:54321 "$ORADATA_DIR" || true

retry 5 "$PODMAN" pull "$IMAGE" || true
"$PODMAN" rm -f "$NAME" || true

retry 5 "$PODMAN" run -d --name "$NAME" --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="$ORACLE_PDB" \
  -e ORACLE_MEMORY='2048' \
  -v "$ORADATA_DIR":/opt/oracle/oradata:z \
  "$IMAGE"

log "waiting for 'DATABASE IS READY TO USE!'"
for i in {1..144}; do
  "$PODMAN" logs "$NAME" 2>&1 | grep -q 'DATABASE IS READY TO USE!' && break
  sleep 5
done

log "opening PDB and saving state..."
"$PODMAN" exec -e ORACLE_PWD="$ORACLE_PWD" -i "$NAME" bash -lc '
  . /home/oracle/.bashrc
  sqlplus -S -L /nolog <<SQL
  CONNECT sys/${ORACLE_PWD}@127.0.0.1:1521/FREE AS SYSDBA
  WHENEVER SQLERROR EXIT SQL.SQLCODE
  ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
  ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
  ALTER SYSTEM REGISTER;
  EXIT
SQL
' || log "WARN: open/save state returned non-zero (may already be open)"

log "waiting for listener to publish FREEPDB1..."
for i in {1..60}; do
  "$PODMAN" exec -i "$NAME" bash -lc '. /home/oracle/.bashrc; lsnrctl status' \
    | grep -qi 'Service "FREEPDB1"' && { log "FREEPDB1 registered"; break; }
  sleep 3
done

log "creating PDB user 'vector' (idempotent)"
"$PODMAN" exec -e ORACLE_PWD="$ORACLE_PWD" -i "$NAME" bash -lc '
  . /home/oracle/.bashrc
  sqlplus -S -L /nolog <<SQL
  CONNECT sys/${ORACLE_PWD}@127.0.0.1:1521/FREEPDB1 AS SYSDBA
  SET DEFINE OFF
  WHENEVER SQLERROR CONTINUE
  CREATE USER vector IDENTIFIED BY "vector";
  GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
  ALTER USER vector QUOTA UNLIMITED ON USERS;
  EXIT
SQL
' || log "WARN: vector user create step returned non-zero"

log "done $(date -u)"
DBSCR
chmod +x /usr/local/bin/genai-db.sh

# ====================================================================
# systemd units — DB FIRST, then setup
# ====================================================================
cat >/etc/systemd/system/genai-23ai.service <<'UNIT_DB'
[Unit]
Description=GenAI oneclick - Oracle 23ai container
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=0
KillMode=process
ExecStart=/bin/bash -lc '/usr/local/bin/genai-db.sh >> /var/log/genai_setup.log 2>&1'
Restart=no

[Install]
WantedBy=multi-user.target
UNIT_DB

cat >/etc/systemd/system/genai-setup.service <<'UNIT_SETUP'
[Unit]
Description=GenAI oneclick post-boot setup
Wants=network-online.target genai-23ai.service
After=network-online.target genai-23ai.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -lc '/usr/local/bin/genai-setup.sh >> /var/log/genai_setup.log 2>&1'
Restart=no

[Install]
WantedBy=multi-user.target
UNIT_SETUP

systemctl daemon-reload
systemctl enable genai-23ai.service
systemctl enable genai-setup.service
systemctl start genai-23ai.service      # DB/bootstrap first
systemctl start genai-setup.service     # then app/setup

echo "===== GenAI OneClick: cloud-init done $(date -u) ====="
