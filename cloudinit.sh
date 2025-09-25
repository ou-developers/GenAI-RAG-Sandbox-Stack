#!/bin/bash
# cloudinit.sh — Working GenAI setup (fixes systemd stdout issues)

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# --------------------------------------------------------------------
# Basic setup and cleanup
# --------------------------------------------------------------------
echo "[SETUP] Basic initialization"

# Expand filesystem
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# Clean up space
dnf clean all || true
rm -rf /tmp/* /var/tmp/* || true

# Fix repository issues
dnf config-manager --set-disabled ol8_ksplice || true

# Install essential packages
dnf -y install dnf-plugins-core || true
dnf config-manager --set-enabled ol8_addons || true
dnf -y makecache --refresh || true

# Install packages with retries
for pkg in curl wget git unzip jq podman python39 python39-pip gcc gcc-c++ make openssl-devel libffi-devel; do
  dnf -y install $pkg || echo "Warning: Failed to install $pkg"
done

# Verify podman
if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: Podman not installed"
  exit 1
fi

echo "Podman version: $(podman --version)"

# --------------------------------------------------------------------
# Create database script (simplified logging)
# --------------------------------------------------------------------
cat > /usr/local/bin/genai-db.sh << 'DBSCRIPT'
#!/bin/bash

# Simple logging to file
exec >> /var/log/genai_setup.log 2>&1

echo "[DB $(date '+%H:%M:%S')] Starting database setup"

ORACLE_PWD="database123"
ORACLE_PDB="FREEPDB1"
ORADATA_DIR="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
CONTAINER_NAME="23ai"

# Create data directory
mkdir -p "$ORADATA_DIR"
chown -R 54321:54321 "$ORADATA_DIR" 2>/dev/null || true
chmod -R 755 "$ORADATA_DIR"

# Clean existing container
podman stop "$CONTAINER_NAME" 2>/dev/null || true
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Pull image
echo "[DB] Pulling Oracle image"
for i in 1 2 3; do
  if podman pull "$IMAGE"; then
    echo "[DB] Image pulled successfully"
    break
  fi
  echo "[DB] Pull attempt $i failed"
  sleep 30
done

# Start container
echo "[DB] Starting container"
podman run -d \
  --name "$CONTAINER_NAME" \
  --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="$ORACLE_PDB" \
  -e ORACLE_MEMORY=2048 \
  -v "$ORADATA_DIR":/opt/oracle/oradata:Z \
  "$IMAGE"

if [ $? -ne 0 ]; then
  echo "[DB] ERROR: Failed to start container"
  exit 1
fi

# Wait for database
echo "[DB] Waiting for database (this takes 10-20 minutes)"
max_wait=2400  # 40 minutes
waited=0

while [ $waited -lt $max_wait ]; do
  if podman logs "$CONTAINER_NAME" 2>&1 | grep -q "DATABASE IS READY TO USE!"; then
    echo "[DB] Database is ready (waited ${waited}s)"
    break
  fi
  
  if [ $((waited % 120)) -eq 0 ] && [ $waited -gt 0 ]; then
    echo "[DB] Still waiting... (${waited}s elapsed)"
  fi
  
  sleep 30
  waited=$((waited + 30))
done

if [ $waited -ge $max_wait ]; then
  echo "[DB] ERROR: Database timeout"
  podman logs "$CONTAINER_NAME" | tail -10
  exit 1
fi

# Configure PDB
echo "[DB] Configuring PDB"
sleep 30
podman exec "$CONTAINER_NAME" bash -c '
source /home/oracle/.bashrc 2>/dev/null || true
export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export PATH=$ORACLE_HOME/bin:$PATH

sqlplus -s / as sysdba << EOF || true
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
ALTER SYSTEM REGISTER;
EXIT;
EOF
' || echo "[DB] PDB config warning (may already be configured)"

# Create vector user
echo "[DB] Creating vector user"
podman exec "$CONTAINER_NAME" bash -c '
source /home/oracle/.bashrc 2>/dev/null || true
export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export PATH=$ORACLE_HOME/bin:$PATH

sqlplus -s sys/'"$ORACLE_PWD"'@localhost:1521/FREEPDB1 as sysdba << EOF || true
CREATE USER vector IDENTIFIED BY "vector";
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
ALTER USER vector QUOTA UNLIMITED ON USERS;
EXIT;
EOF
' || echo "[DB] Vector user warning (may already exist)"

echo "[DB] Database setup completed"
DBSCRIPT

chmod +x /usr/local/bin/genai-db.sh

# --------------------------------------------------------------------
# Create application setup script (simplified)
# --------------------------------------------------------------------
cat > /usr/local/bin/genai-setup.sh << 'SETUPSCRIPT'
#!/bin/bash

# Simple logging to file
exec >> /var/log/genai_setup.log 2>&1

echo "[SETUP $(date '+%H:%M:%S')] Starting application setup"

MARKER="/var/lib/genai.setup.done"
if [ -f "$MARKER" ]; then
  echo "[SETUP] Already completed"
  exit 0
fi

# Create directories
echo "[SETUP] Creating directories"
mkdir -p /opt/genai /home/opc/code /home/opc/bin /home/opc/.venvs /home/opc/.config/systemd/user
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/.venvs /home/opc/.config 2>/dev/null || true

# Download source code
echo "[SETUP] Downloading source code"
CODE_DIR="/home/opc/code"
cd /tmp

# Simple download method
wget -q -O genai-source.zip "https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main" || {
  echo "[SETUP] Download failed, creating minimal structure"
  mkdir -p "$CODE_DIR"
  echo "# GenAI code directory" > "$CODE_DIR/README.md"
}

if [ -f genai-source.zip ]; then
  unzip -q genai-source.zip 2>/dev/null || true
  if [ -d css-navigator-main/gen-ai ]; then
    cp -r css-navigator-main/gen-ai/* "$CODE_DIR"/ 2>/dev/null || true
    echo "[SETUP] Source code copied"
  fi
  rm -rf css-navigator-main genai-source.zip
fi

chown -R opc:opc "$CODE_DIR" 2>/dev/null || true

# Create Python environment
echo "[SETUP] Setting up Python environment"
sudo -u opc bash << 'EOF'
cd /home/opc

# Create virtual environment
python3.9 -m venv .venvs/genai
source .venvs/genai/bin/activate

# Upgrade pip
python -m pip install --upgrade pip wheel

# Install essential packages only
echo "Installing core packages..."
pip install --no-cache-dir \
  oracledb \
  torch --index-url https://download.pytorch.org/whl/cpu \
  streamlit \
  jupyterlab \
  langchain \
  langchain-community \
  sentence-transformers \
  pypdf \
  oci

# Add to bashrc
echo 'source $HOME/.venvs/genai/bin/activate' >> .bashrc

pip cache purge 2>/dev/null || true
EOF

# Create startup script
echo "[SETUP] Creating startup script"
cat > /home/opc/start_jupyter.sh << 'EOF'
#!/bin/bash
export HOME=/home/opc
cd "$HOME"

if [ ! -f ".venvs/genai/bin/activate" ]; then
  echo "Virtual environment not found!"
  exit 1
fi

source .venvs/genai/bin/activate
exec jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --NotebookApp.token='' --NotebookApp.password='' --allow-root
EOF

chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

# Create user service
echo "[SETUP] Creating Jupyter service"
sudo -u opc bash << 'EOF'
cat > "$HOME/.config/systemd/user/jupyter.service" << 'UNIT'
[Unit]
Description=JupyterLab Server

[Service]
Type=simple
ExecStart=%h/start_jupyter.sh
Restart=always
RestartSec=10
WorkingDirectory=%h

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable jupyter.service
EOF

loginctl enable-linger opc 2>/dev/null || true

# Configure firewall
echo "[SETUP] Configuring firewall"
systemctl enable --now firewalld || true
firewall-cmd --permanent --add-port=8888/tcp || true
firewall-cmd --permanent --add-port=8501/tcp || true
firewall-cmd --permanent --add-port=1521/tcp || true
firewall-cmd --reload || true

# Create config files
echo "[SETUP] Creating config files"
cat > /opt/genai/config.txt << 'EOF'
{
  "model_name": "cohere.command-r-16k",
  "embedding_model_name": "cohere.embed-english-v3.0",
  "endpoint": "https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com",
  "compartment_ocid": "ocid1.compartment.oc1....replace_me..."
}
EOF

cat > /opt/genai/LoadProperties.py << 'EOF'
import json
import os

class LoadProperties:
    def __init__(self, config_file='config.txt'):
        config_path = os.path.join(os.path.dirname(__file__), config_file)
        with open(config_path, 'r') as f:
            self.config = json.load(f)
    
    def getModelName(self):
        return self.config.get("model_name")
    
    def getEmbeddingModelName(self):
        return self.config.get("embedding_model_name")
    
    def getEndpoint(self):
        return self.config.get("endpoint")
    
    def getCompartment(self):
        return self.config.get("compartment_ocid")
EOF

mkdir -p /opt/genai/txt-docs /opt/genai/pdf-docs
echo "faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier." > /opt/genai/txt-docs/faq.txt

chown -R opc:opc /opt/genai

# Cleanup
rm -rf /tmp/genai-* /tmp/css-navigator*
dnf clean all || true

touch "$MARKER"
echo "[SETUP] Application setup completed"
SETUPSCRIPT

chmod +x /usr/local/bin/genai-setup.sh

# --------------------------------------------------------------------
# Create simple systemd services (fixed stdout issue)
# --------------------------------------------------------------------
echo "[SYSTEMD] Creating services"

cat > /etc/systemd/system/genai-db.service << 'EOF'
[Unit]
Description=GenAI Oracle Database
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=3600
ExecStart=/usr/local/bin/genai-db.sh

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/genai-setup.service << 'EOF'
[Unit]
Description=GenAI Application Setup
After=genai-db.service
Wants=genai-db.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=1800
ExecStart=/usr/local/bin/genai-setup.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable genai-db.service genai-setup.service

# --------------------------------------------------------------------
# Run setup directly (avoid systemd issues for now)
# --------------------------------------------------------------------
echo "[DIRECT] Running database setup directly"
/usr/local/bin/genai-db.sh &
DB_PID=$!

echo "[DIRECT] Database setup started (PID: $DB_PID)"
echo "[INFO] This will take 10-20 minutes. Monitor with: tail -f /var/log/genai_setup.log"

# Wait for DB setup to complete, then start app setup
wait $DB_PID
DB_EXIT_CODE=$?

if [ $DB_EXIT_CODE -eq 0 ]; then
  echo "[DIRECT] Database setup completed, starting application setup"
  /usr/local/bin/genai-setup.sh &
  APP_PID=$!
  echo "[DIRECT] Application setup started (PID: $APP_PID)"
else
  echo "[ERROR] Database setup failed with exit code $DB_EXIT_CODE"
fi

echo "===== GenAI OneClick: cloud-init completed $(date -u) ====="
echo "Monitor progress: tail -f /var/log/genai_setup.log"
echo "After completion, access JupyterLab: http://your-vm-ip:8888"
