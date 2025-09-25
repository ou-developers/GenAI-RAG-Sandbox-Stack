#!/bin/bash
# cloudinit.sh — Oracle 23ai Free + GenAI stack bootstrap (optimized, robust)
# Key improvements:
# - Better disk space management and cleanup
# - Robust network handling with fallbacks
# - Streamlined package installation
# - Fixed venv creation and dependency management
# - Improved DB startup timing and health checks

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# --------------------------------------------------------------------
# Disk space optimization and filesystem expansion
# --------------------------------------------------------------------
echo "[DISK] Expanding filesystem and cleaning up space"
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# Clean up existing packages and cache to free space
dnf clean all || true
rm -rf /tmp/* /var/tmp/* || true
# Remove old kernels if any (keep current + 1)
package-cleanup --oldkernels --count=1 || dnf remove $(dnf repoquery --installonly --latest-limit=-1 -q) || true

# --------------------------------------------------------------------
# Network and repository setup with robust fallbacks
# --------------------------------------------------------------------
echo "[NET] Setting up network connectivity and repositories"

# Wait for network with timeout
wait_for_network() {
  local timeout=60
  local count=0
  while [ $count -lt $timeout ]; do
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
      echo "[NET] Network connectivity confirmed"
      return 0
    fi
    sleep 2
    count=$((count + 2))
  done
  echo "[NET] Network timeout, proceeding anyway"
  return 1
}

wait_for_network

# Disable problematic ksplice repo immediately
dnf config-manager --set-disabled ol8_ksplice || true

# Configure DNF for better reliability
cat > /etc/dnf/dnf.conf.d/genai.conf << 'EOF'
fastestmirror=True
max_parallel_downloads=3
deltarpm=False
timeout=30
retries=3
EOF

# Enable required repositories
echo "[REPO] Enabling repositories"
dnf -y install dnf-plugins-core || true
dnf config-manager --set-enabled ol8_addons ol8_appstream ol8_baseos_latest || true

# Force cache refresh with retry
for i in {1..3}; do
  dnf makecache --refresh && break
  echo "[REPO] Cache refresh attempt $i failed, retrying..."
  sleep 5
done

# --------------------------------------------------------------------
# Pre-install essential packages (minimal set)
# --------------------------------------------------------------------
echo "[PRE] Installing essential packages"
dnf -y install curl wget git unzip jq podman python39 python39-pip || {
  echo "[PRE] Package installation failed, trying individual packages"
  for pkg in curl wget git unzip jq podman python39 python39-pip; do
    dnf -y install $pkg || echo "[WARN] Failed to install $pkg"
  done
}

# Verify podman installation
if ! command -v podman >/dev/null 2>&1; then
  echo "[ERROR] Podman installation failed"
  exit 1
fi

echo "[PRE] Podman version: $(podman --version)"

# --------------------------------------------------------------------
# Database bootstrap script (improved timing and error handling)
# --------------------------------------------------------------------
cat >/usr/local/bin/genai-db.sh <<'DBSCRIPT'
#!/bin/bash
set -Eeuo pipefail

PODMAN="/usr/bin/podman"
log() { echo "[DB $(date '+%H:%M:%S')] $*"; }

# Configuration
ORACLE_PWD="database123"
ORACLE_PDB="FREEPDB1"
ORADATA_DIR="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
CONTAINER_NAME="23ai"

log "Starting Oracle 23ai container setup"

# Prepare data directory
mkdir -p "$ORADATA_DIR"
chown -R 54321:54321 "$ORADATA_DIR"
chmod -R 755 "$ORADATA_DIR"

# Clean up any existing container
$PODMAN rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Pull image with retry
for i in {1..3}; do
  log "Pulling Oracle container image (attempt $i/3)"
  if $PODMAN pull "$IMAGE"; then
    break
  fi
  if [ $i -eq 3 ]; then
    log "ERROR: Failed to pull container image after 3 attempts"
    exit 1
  fi
  sleep 10
done

# Start container
log "Starting Oracle container"
$PODMAN run -d --name "$CONTAINER_NAME" \
  --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="$ORACLE_PDB" \
  -e ORACLE_MEMORY=2048 \
  -v "$ORADATA_DIR":/opt/oracle/oradata:Z \
  "$IMAGE"

# Wait for database to be ready with better logging
log "Waiting for database initialization (this may take 5-15 minutes)"
start_time=$(date +%s)
max_wait=1800  # 30 minutes max

while true; do
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))
  
  if [ $elapsed -gt $max_wait ]; then
    log "ERROR: Database initialization timeout after $max_wait seconds"
    $PODMAN logs "$CONTAINER_NAME" | tail -20
    exit 1
  fi
  
  # Check for ready message
  if $PODMAN logs "$CONTAINER_NAME" 2>&1 | grep -q "DATABASE IS READY TO USE!"; then
    log "Database is ready! (took ${elapsed}s)"
    break
  fi
  
  # Progress indicator every minute
  if [ $((elapsed % 60)) -eq 0 ] && [ $elapsed -gt 0 ]; then
    log "Still waiting... (${elapsed}s elapsed)"
    # Show recent logs for debugging
    $PODMAN logs --tail=3 "$CONTAINER_NAME" 2>&1 | sed 's/^/[DB-LOG] /'
  fi
  
  sleep 10
done

# Configure PDB
log "Configuring pluggable database"
$PODMAN exec "$CONTAINER_NAME" bash -c '
source /home/oracle/.bashrc
sqlplus -s / as sysdba << EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
ALTER SYSTEM REGISTER;
EXIT;
EOF
' || log "WARN: PDB configuration had issues but continuing"

# Wait for listener registration
log "Waiting for listener to register FREEPDB1 service"
for i in {1..30}; do
  if $PODMAN exec "$CONTAINER_NAME" bash -c 'source /home/oracle/.bashrc; lsnrctl status' | grep -qi 'Service "FREEPDB1"'; then
    log "FREEPDB1 service registered successfully"
    break
  fi
  sleep 5
done

# Create vector user
log "Creating vector user"
$PODMAN exec "$CONTAINER_NAME" bash -c '
source /home/oracle/.bashrc
sqlplus -s sys/'"$ORACLE_PWD"'@localhost:1521/FREEPDB1 as sysdba << EOF
WHENEVER SQLERROR CONTINUE
CREATE USER vector IDENTIFIED BY "vector";
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
ALTER USER vector QUOTA UNLIMITED ON USERS;
EXIT;
EOF
' || log "WARN: Vector user creation had issues"

log "Database setup completed successfully"
DBSCRIPT

chmod +x /usr/local/bin/genai-db.sh

# --------------------------------------------------------------------
# Main application setup script (streamlined)
# --------------------------------------------------------------------
cat >/usr/local/bin/genai-setup.sh <<'SETUPSCRIPT'
#!/bin/bash
set -Eeuo pipefail

log() { echo "[SETUP $(date '+%H:%M:%S')] $*"; }

MARKER="/var/lib/genai.setup.done"
if [ -f "$MARKER" ]; then
  log "Setup already completed, skipping"
  exit 0
fi

log "Starting GenAI application setup"

# Create directories
mkdir -p /opt/genai /home/opc/code /home/opc/bin /home/opc/.venvs
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/.venvs

# Install additional packages needed for Python compilation
log "Installing build dependencies"
dnf -y install gcc gcc-c++ make openssl-devel libffi-devel bzip2-devel readline-devel \
  sqlite-devel xz-devel zlib-devel ncurses-devel tk-devel || true

# Download source code
log "Downloading GenAI source code"
CODE_DIR="/home/opc/code"
TMP_ZIP="/tmp/genai-source.zip"

curl -L -o "$TMP_ZIP" "https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main"
unzip -q -o "$TMP_ZIP" -d /tmp/
if [ -d "/tmp/css-navigator-main/gen-ai" ]; then
  cp -r /tmp/css-navigator-main/gen-ai/* "$CODE_DIR"/
  chown -R opc:opc "$CODE_DIR"
fi
rm -rf /tmp/css-navigator-main "$TMP_ZIP"

# Create optimized Python virtual environment
log "Creating Python virtual environment"
sudo -u opc bash << 'EOF'
set -e
export HOME=/home/opc
cd $HOME

# Create venv with system site packages to save space
python3.9 -m venv --system-site-packages .venvs/genai
source .venvs/genai/bin/activate

# Upgrade pip and essential tools
python -m pip install --upgrade pip wheel setuptools

# Install packages efficiently (in order of dependency)
pip install --no-cache-dir --disable-pip-version-check \
  oracledb==2.0.1 \
  oci==2.129.1 \
  torch==2.5.0 --index-url https://download.pytorch.org/whl/cpu \
  sentence-transformers==3.0.1 \
  streamlit==1.36.0 \
  jupyterlab==4.2.5 \
  langchain==0.2.6 \
  langchain-community==0.2.6 \
  langchain-core==0.2.11 \
  langchain-text-splitters==0.2.2 \
  langchain-chroma==0.1.2 \
  pypdf==4.2.0 \
  python-multipart==0.0.9 \
  chromadb==0.5.3

# Clean up pip cache to save space
pip cache purge

# Add activation to bashrc
echo 'source $HOME/.venvs/genai/bin/activate' >> $HOME/.bashrc
EOF

# Create startup scripts
log "Creating startup scripts"
cat > /home/opc/start_jupyter.sh << 'EOF'
#!/bin/bash
set -e
export HOME=/home/opc
cd $HOME

source .venvs/genai/bin/activate
exec jupyter lab --ip=0.0.0.0 --port=8888 --no-browser \
  --NotebookApp.token='' --NotebookApp.password='' \
  --allow-root
EOF

chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

# Create user systemd service for Jupyter
log "Setting up Jupyter service"
sudo -u opc bash << 'EOF'
mkdir -p $HOME/.config/systemd/user
cat > $HOME/.config/systemd/user/jupyter.service << 'UNIT'
[Unit]
Description=JupyterLab Server
After=genai-23ai.service

[Service]
Type=simple
ExecStart=%h/start_jupyter.sh
Restart=always
RestartSec=10
WorkingDirectory=%h
Environment=HOME=%h

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable jupyter.service
EOF

# Enable lingering for user services
loginctl enable-linger opc || true

# Setup firewall
log "Configuring firewall"
systemctl enable --now firewalld || true
firewall-cmd --permanent --add-port=8888/tcp || true
firewall-cmd --permanent --add-port=8501/tcp || true
firewall-cmd --permanent --add-port=1521/tcp || true
firewall-cmd --reload || true

# Create configuration files
log "Creating configuration files"
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

class LoadProperties:
    def __init__(self):
        with open('config.txt') as f:
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

# Create sample documents
mkdir -p /opt/genai/txt-docs /opt/genai/pdf-docs
echo "faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier." > /opt/genai/txt-docs/faq.txt

chown -R opc:opc /opt/genai

# Final cleanup
log "Cleaning up temporary files"
dnf clean all
rm -rf /tmp/* /var/tmp/*

touch "$MARKER"
log "GenAI setup completed successfully"
SETUPSCRIPT

chmod +x /usr/local/bin/genai-setup.sh

# --------------------------------------------------------------------
# Create systemd services with proper dependencies
# --------------------------------------------------------------------
echo "[SYSTEMD] Creating service units"

cat > /etc/systemd/system/genai-db.service << 'EOF'
[Unit]
Description=GenAI Oracle 23ai Database
Wants=network-online.target
After=network-online.target
StartLimitBurst=3
StartLimitIntervalSec=300

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=2400
ExecStart=/usr/local/bin/genai-db.sh
StandardOutput=append:/var/log/genai_setup.log
StandardError=append:/var/log/genai_setup.log

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/genai-setup.service << 'EOF'
[Unit]
Description=GenAI Application Setup
Wants=genai-db.service
After=genai-db.service
StartLimitBurst=2
StartLimitIntervalSec=300

[Service]
Type=oneshot  
RemainAfterExit=yes
TimeoutStartSec=1800
ExecStart=/usr/local/bin/genai-setup.sh
StandardOutput=append:/var/log/genai_setup.log
StandardError=append:/var/log/genai_setup.log

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
systemctl daemon-reload
systemctl enable genai-db.service genai-setup.service

# Start database service first
echo "[START] Starting database service"
systemctl start genai-db.service

# Start application setup service  
echo "[START] Starting application setup service"
systemctl start genai-setup.service

echo "===== GenAI OneClick: cloud-init completed $(date -u) ====="
echo "[INFO] Check service status with:"
echo "  systemctl status genai-db.service"
echo "  systemctl status genai-setup.service"
echo "[INFO] View logs with:"
echo "  tail -f /var/log/genai_setup.log"
