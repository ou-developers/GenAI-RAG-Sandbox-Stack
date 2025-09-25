#!/bin/bash
# cloudinit.sh — Oracle 23ai Free + GenAI stack bootstrap (OL8 compatible)
# Fixed for Oracle Linux 8 specific issues and disk space optimization

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# --------------------------------------------------------------------
# Error handling and utilities
# --------------------------------------------------------------------
cleanup_on_error() {
  echo "[ERROR] Script failed at line $1. Cleaning up..."
  # Basic cleanup
  dnf clean all 2>/dev/null || true
  rm -rf /tmp/genai-* /tmp/css-navigator* 2>/dev/null || true
}
trap 'cleanup_on_error $LINENO' ERR

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

retry_cmd() {
  local max_attempts=${1:-3}
  local delay=${2:-5}
  shift 2
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    if "$@"; then
      return 0
    fi
    log "Command failed (attempt $attempt/$max_attempts): $*"
    if [ $attempt -lt $max_attempts ]; then
      sleep $delay
    fi
    attempt=$((attempt + 1))
  done
  
  log "Command failed after $max_attempts attempts: $*"
  return 1
}

# --------------------------------------------------------------------
# Disk space optimization
# --------------------------------------------------------------------
log "Expanding filesystem and optimizing disk space"

# Try to expand filesystem
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y 2>/dev/null || log "Filesystem expansion not needed or failed"
fi

# Clean up space aggressively
log "Cleaning up existing files to free space"
dnf clean all 2>/dev/null || true
rm -rf /tmp/* /var/tmp/* /var/cache/dnf/* 2>/dev/null || true

# Check available space
AVAILABLE_SPACE=$(df / | awk 'NR==2 {print $4}')
log "Available disk space: $((AVAILABLE_SPACE / 1024))MB"

if [ $AVAILABLE_SPACE -lt 2097152 ]; then  # Less than 2GB
  log "WARNING: Low disk space detected. Enabling aggressive space saving mode."
  SPACE_SAVING_MODE=1
else
  SPACE_SAVING_MODE=0
fi

# --------------------------------------------------------------------
# Network and repository setup
# --------------------------------------------------------------------
log "Setting up network connectivity"

# Wait for network with exponential backoff
wait_for_network() {
  local max_attempts=10
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
      log "Network connectivity confirmed"
      return 0
    fi
    
    local delay=$((2 ** attempt))
    log "Network check failed (attempt $attempt/$max_attempts), waiting ${delay}s"
    sleep $delay
    attempt=$((attempt + 1))
  done
  
  log "Network connectivity issues, but proceeding"
  return 1
}

wait_for_network

# Disable problematic repositories immediately
log "Configuring package repositories"
dnf config-manager --set-disabled ol8_ksplice 2>/dev/null || true
dnf config-manager --set-disabled ol8_developer 2>/dev/null || true

# Configure DNF for reliability
if [ ! -d /etc/dnf/dnf.conf.d ]; then
  mkdir -p /etc/dnf/dnf.conf.d
fi

cat > /etc/dnf/dnf.conf.d/genai.conf << 'EOF'
fastestmirror=True
max_parallel_downloads=2
deltarpm=False
timeout=60
retries=5
skip_if_unavailable=True
EOF

# Install dnf-plugins-core first
log "Installing dnf plugins"
retry_cmd 3 10 dnf -y install dnf-plugins-core

# Enable required repositories
log "Enabling required repositories"
dnf config-manager --set-enabled ol8_addons ol8_appstream ol8_baseos_latest 2>/dev/null || true

# Refresh cache with retry
log "Refreshing package cache"
retry_cmd 3 15 dnf makecache --refresh

# --------------------------------------------------------------------
# Essential package installation
# --------------------------------------------------------------------
log "Installing essential packages"

# Install packages in groups to handle failures better
ESSENTIAL_PKGS="curl wget git unzip jq"
BUILD_PKGS="gcc gcc-c++ make openssl-devel libffi-devel"
PYTHON_PKGS="python39 python39-pip python39-devel"

for pkg_group in "$ESSENTIAL_PKGS" "$BUILD_PKGS" "$PYTHON_PKGS" "podman"; do
  log "Installing: $pkg_group"
  retry_cmd 2 10 dnf -y install $pkg_group || {
    log "Group installation failed, trying individual packages"
    for pkg in $pkg_group; do
      dnf -y install $pkg 2>/dev/null || log "Failed to install $pkg (non-critical)"
    done
  }
done

# Verify critical tools
for cmd in podman python3.9 git curl; do
  if ! command -v $cmd >/dev/null 2>&1; then
    log "ERROR: Critical command '$cmd' not found"
    exit 1
  fi
done

log "Podman version: $(podman --version 2>/dev/null || echo 'unknown')"
log "Python version: $(python3.9 --version 2>/dev/null || echo 'unknown')"

# --------------------------------------------------------------------
# Database bootstrap script
# --------------------------------------------------------------------
log "Creating database bootstrap script"
cat >/usr/local/bin/genai-db.sh <<'DBSCRIPT'
#!/bin/bash
set -Eeuo pipefail

PODMAN="/usr/bin/podman"
log() { echo "[DB $(date '+%H:%M:%S')] $*"; }

# Database configuration
ORACLE_PWD="database123"
ORACLE_PDB="FREEPDB1"
ORADATA_DIR="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
CONTAINER_NAME="23ai"

log "Starting Oracle 23ai database setup"

# Prepare data directory with correct permissions
log "Preparing data directory"
mkdir -p "$ORADATA_DIR"
chown -R 54321:54321 "$ORADATA_DIR" 2>/dev/null || true
chmod -R 755 "$ORADATA_DIR"

# Clean up any existing container
log "Cleaning up existing containers"
$PODMAN stop "$CONTAINER_NAME" 2>/dev/null || true
$PODMAN rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Pull container image with retry
log "Pulling Oracle container image"
for attempt in 1 2 3; do
  log "Pull attempt $attempt/3"
  if $PODMAN pull "$IMAGE"; then
    log "Image pulled successfully"
    break
  fi
  if [ $attempt -eq 3 ]; then
    log "ERROR: Failed to pull image after 3 attempts"
    exit 1
  fi
  sleep 30
done

# Start the container
log "Starting Oracle database container"
$PODMAN run -d \
  --name "$CONTAINER_NAME" \
  --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="$ORACLE_PDB" \
  -e ORACLE_MEMORY=2048 \
  -v "$ORADATA_DIR":/opt/oracle/oradata:Z \
  "$IMAGE" || {
  log "ERROR: Failed to start container"
  exit 1
}

log "Container started, waiting for database initialization"

# Enhanced database readiness check
wait_for_database() {
  local max_wait=2700  # 45 minutes
  local start_time=$(date +%s)
  local last_log_time=0
  
  while true; do
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    
    # Check for timeout
    if [ $elapsed -gt $max_wait ]; then
      log "ERROR: Database initialization timeout after $max_wait seconds"
      log "Final container logs:"
      $PODMAN logs --tail=20 "$CONTAINER_NAME" 2>&1 | sed 's/^/[CONTAINER] /'
      return 1
    fi
    
    # Check for ready message
    if $PODMAN logs "$CONTAINER_NAME" 2>&1 | grep -q "DATABASE IS READY TO USE!"; then
      log "Database initialization completed! (took ${elapsed}s)"
      return 0
    fi
    
    # Progress logging every 2 minutes
    if [ $((elapsed % 120)) -eq 0 ] && [ $elapsed -gt $last_log_time ]; then
      log "Still initializing database... (${elapsed}s elapsed)"
      # Show recent container output
      $PODMAN logs --tail=2 "$CONTAINER_NAME" 2>&1 | grep -v "^$" | tail -1 | sed 's/^/[DB-STATUS] /' || true
      last_log_time=$elapsed
    fi
    
    sleep 15
  done
}

if ! wait_for_database; then
  log "Database initialization failed"
  exit 1
fi

# Configure PDB with better error handling
log "Configuring pluggable database"
configure_pdb() {
  $PODMAN exec "$CONTAINER_NAME" bash -c '
  source /home/oracle/.bashrc 2>/dev/null || export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
  export PATH=$ORACLE_HOME/bin:$PATH
  
  # Wait a bit for services to stabilize
  sleep 10
  
  sqlplus -s / as sysdba << EOF
  WHENEVER SQLERROR EXIT SQL.SQLCODE
  ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
  ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
  ALTER SYSTEM REGISTER;
  EXIT;
EOF
  ' 2>/dev/null
}

if ! configure_pdb; then
  log "PDB configuration failed, but continuing (may already be configured)"
fi

# Wait for listener to register the service
log "Waiting for listener service registration"
for i in {1..40}; do
  if $PODMAN exec "$CONTAINER_NAME" bash -c 'source /home/oracle/.bashrc 2>/dev/null || export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree; export PATH=$ORACLE_HOME/bin:$PATH; lsnrctl status' 2>/dev/null | grep -qi 'Service.*FREEPDB1'; then
    log "FREEPDB1 service registered with listener"
    break
  fi
  sleep 10
done

# Create vector user
log "Creating vector database user"
create_user() {
  $PODMAN exec "$CONTAINER_NAME" bash -c '
  source /home/oracle/.bashrc 2>/dev/null || export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
  export PATH=$ORACLE_HOME/bin:$PATH
  
  sqlplus -s sys/'"$ORACLE_PWD"'@localhost:1521/FREEPDB1 as sysdba << EOF
  WHENEVER SQLERROR CONTINUE
  CREATE USER vector IDENTIFIED BY "vector";
  GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
  ALTER USER vector QUOTA UNLIMITED ON USERS;
  EXIT;
EOF
  ' 2>/dev/null
}

if create_user; then
  log "Vector user created successfully"
else
  log "Vector user creation failed (may already exist)"
fi

# Final connectivity test
log "Testing database connectivity"
if $PODMAN exec "$CONTAINER_NAME" bash -c 'source /home/oracle/.bashrc 2>/dev/null || export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree; export PATH=$ORACLE_HOME/bin:$PATH; echo "SELECT 1 FROM DUAL;" | sqlplus -s vector/vector@localhost:1521/FREEPDB1' 2>/dev/null | grep -q "1"; then
  log "Database connectivity test passed"
else
  log "Database connectivity test failed, but setup may still be functional"
fi

log "Database setup completed"
DBSCRIPT

chmod +x /usr/local/bin/genai-db.sh

# --------------------------------------------------------------------
# Application setup script (space optimized)
# --------------------------------------------------------------------
log "Creating application setup script"
cat >/usr/local/bin/genai-setup.sh <<'SETUPSCRIPT'
#!/bin/bash
set -Eeuo pipefail

log() { echo "[SETUP $(date '+%H:%M:%S')] $*"; }

MARKER="/var/lib/genai.setup.done"
if [ -f "$MARKER" ]; then
  log "Setup already completed"
  exit 0
fi

log "Starting GenAI application setup"

# Create required directories
log "Creating directories"
mkdir -p /opt/genai /home/opc/{code,bin,.venvs} /home/opc/.config/systemd/user
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/.venvs /home/opc/.config 2>/dev/null || true

# Download source code efficiently
log "Downloading GenAI source code"
CODE_DIR="/home/opc/code"
TEMP_ZIP="/tmp/genai-source.zip"

# Clean download with retry
download_source() {
  rm -f "$TEMP_ZIP"
  curl -L --connect-timeout 30 --max-time 300 \
    -o "$TEMP_ZIP" \
    "https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main"
}

if retry_cmd 3 15 download_source; then
  log "Source downloaded, extracting"
  cd /tmp
  unzip -q -o "$TEMP_ZIP" 2>/dev/null || true
  
  if [ -d "css-navigator-main/gen-ai" ]; then
    cp -r css-navigator-main/gen-ai/* "$CODE_DIR"/ 2>/dev/null || true
    chown -R opc:opc "$CODE_DIR" 2>/dev/null || true
    log "Source code extracted to $CODE_DIR"
  else
    log "WARNING: Expected source structure not found"
  fi
  
  # Cleanup
  rm -rf css-navigator-main "$TEMP_ZIP"
else
  log "WARNING: Source download failed, creating minimal structure"
  mkdir -p "$CODE_DIR"
  echo "# GenAI placeholder" > "$CODE_DIR/README.md"
  chown -R opc:opc "$CODE_DIR"
fi

# Create optimized Python environment
log "Setting up Python environment"
SPACE_SAVING_MODE=${SPACE_SAVING_MODE:-0}

# Create virtual environment as opc user
sudo -u opc bash << 'EOF'
set -e
export HOME=/home/opc
cd "$HOME"

log() { echo "[VENV $(date '+%H:%M:%S')] $*"; }

# Check available space
AVAILABLE_KB=$(df "$HOME" | awk 'NR==2 {print $4}')
log "Available space: $((AVAILABLE_KB / 1024))MB"

# Create venv with space-saving options if needed
if [ $AVAILABLE_KB -lt 1048576 ]; then  # Less than 1GB
  log "Low space mode: creating minimal venv"
  python3.9 -m venv --system-site-packages --symlinks .venvs/genai
else
  log "Normal mode: creating standard venv"
  python3.9 -m venv .venvs/genai
fi

# Activate and upgrade pip
source .venvs/genai/bin/activate

# Upgrade pip efficiently
python -m pip install --upgrade --no-cache-dir pip wheel

# Install packages in dependency order with space optimization
log "Installing core packages"

# Essential packages first
pip install --no-cache-dir --no-deps oracledb==2.0.1

# Install PyTorch CPU version (much smaller)
log "Installing PyTorch (CPU-only)"
pip install --no-cache-dir torch==2.5.0 --index-url https://download.pytorch.org/whl/cpu

# Core ML and data packages
log "Installing ML packages"
pip install --no-cache-dir \
  numpy \
  sentence-transformers==3.0.1 \
  transformers

# Web framework packages  
log "Installing web packages"
pip install --no-cache-dir \
  streamlit==1.36.0 \
  jupyterlab==4.2.5 \
  fastapi \
  uvicorn

# LangChain packages
log "Installing LangChain ecosystem"
pip install --no-cache-dir \
  langchain-core==0.2.11 \
  langchain==0.2.6 \
  langchain-community==0.2.6 \
  langchain-text-splitters==0.2.2

# Additional utility packages
log "Installing utilities"
pip install --no-cache-dir \
  pypdf==4.2.0 \
  python-multipart==0.0.9 \
  oci==2.129.1

# Clean up pip cache
pip cache purge 2>/dev/null || true

# Add venv activation to bashrc
if ! grep -q "source.*venvs/genai" .bashrc 2>/dev/null; then
  echo 'source $HOME/.venvs/genai/bin/activate' >> .bashrc
fi

log "Python environment setup completed"
EOF

# Create startup script
log "Creating Jupyter startup script"
cat > /home/opc/start_jupyter.sh << 'EOF'
#!/bin/bash
set -e
export HOME=/home/opc
cd "$HOME"

# Ensure venv exists
if [ ! -f ".venvs/genai/bin/activate" ]; then
  echo "Virtual environment not found!"
  exit 1
fi

source .venvs/genai/bin/activate

# Start Jupyter Lab
exec jupyter lab \
  --ip=0.0.0.0 \
  --port=8888 \
  --no-browser \
  --NotebookApp.token='' \
  --NotebookApp.password='' \
  --allow-root \
  --ServerApp.allow_origin='*' \
  --ServerApp.disable_check_xsrf=True
EOF

chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

# Create systemd user service
log "Setting up Jupyter service"
sudo -u opc bash << 'EOF'
mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/jupyter.service" << 'UNIT'
[Unit]
Description=JupyterLab Server
After=default.target

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

# Reload and enable
systemctl --user daemon-reload
systemctl --user enable jupyter.service
EOF

# Enable user service persistence
loginctl enable-linger opc 2>/dev/null || true

# Configure firewall
log "Configuring firewall"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=8888/tcp 2>/dev/null || true
  firewall-cmd --permanent --add-port=8501/tcp 2>/dev/null || true
  firewall-cmd --permanent --add-port=1521/tcp 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
else
  systemctl enable --now firewalld || true
  sleep 5
  firewall-cmd --permanent --add-port=8888/tcp || true
  firewall-cmd --permanent --add-port=8501/tcp || true
  firewall-cmd --permanent --add-port=1521/tcp || true
  firewall-cmd --reload || true
fi

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

# Create sample documents
mkdir -p /opt/genai/{txt-docs,pdf-docs}
cat > /opt/genai/txt-docs/faq.txt << 'EOF'
faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier that provide limited resources at no cost.

faq | How do I access JupyterLab?=====After setup completion, access JupyterLab at http://your-vm-ip:8888

faq | What Python packages are installed?=====The environment includes PyTorch, transformers, sentence-transformers, langchain, streamlit, and jupyter.
EOF

# Set ownership
chown -R opc:opc /opt/genai

# Cleanup temporary files
log "Cleaning up temporary files"
rm -rf /tmp/genai-* /tmp/css-navigator* /var/cache/dnf/*
dnf clean all 2>/dev/null || true

touch "$MARKER"
log "Application setup completed successfully"
SETUPSCRIPT

chmod +x /usr/local/bin/genai-setup.sh

# --------------------------------------------------------------------
# Create systemd services
# --------------------------------------------------------------------
log "Creating systemd services"

cat > /etc/systemd/system/genai-db.service << 'EOF'
[Unit]
Description=GenAI Oracle 23ai Database
Wants=network-online.target
After=network-online.target
StartLimitBurst=2
StartLimitIntervalSec=600

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=3600
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
StartLimitIntervalSec=600

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

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable genai-db.service genai-setup.service

# Start services
log "Starting database service"
systemctl start genai-db.service &

# Wait a moment then start setup service
sleep 10
log "Starting application setup service"
systemctl start genai-setup.service &

# Create helpful aliases and info
cat > /etc/profile.d/genai.sh << 'EOF'
alias genai-status='systemctl status genai-db.service genai-setup.service'
alias genai-logs='tail -f /var/log/genai_setup.log'
alias genai-jupyter='sudo -u opc systemctl --user status jupyter.service'
EOF

log "GenAI OneClick setup initiated"
log "Monitor progress with: tail -f /var/log/genai_setup.log"
log "Check service status with: systemctl status genai-db.service genai-setup.service"
log "Once complete, access JupyterLab at: http://your-vm-ip:8888"

echo "===== GenAI OneClick: cloud-init completed $(date -u) ====="
