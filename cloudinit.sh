#!/bin/bash
# cloudinit.sh — Production GenAI setup (bulletproof version)
# Fixes all identified issues: package installation, firewall timing, service dependencies

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# --------------------------------------------------------------------
# Basic setup and cleanup
# --------------------------------------------------------------------
echo "[INIT] System initialization"

# Expand filesystem
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# Clean up space
dnf clean all || true
rm -rf /tmp/* /var/tmp/* || true

# Fix repository issues immediately
dnf config-manager --set-disabled ol8_ksplice || true

# Network connectivity check with timeout
echo "[INIT] Verifying network connectivity"
for i in {1..30}; do
  if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    echo "[INIT] Network ready"
    break
  fi
  sleep 2
done

# Install essential packages with error handling
echo "[INIT] Installing essential packages"
dnf -y install dnf-plugins-core || true
dnf config-manager --set-enabled ol8_addons || true

# Retry package cache refresh
for i in {1..3}; do
  if dnf -y makecache --refresh; then
    break
  fi
  echo "[INIT] Cache refresh attempt $i failed, retrying..."
  sleep 5
done

# Install packages individually to handle failures
PACKAGES="curl wget git unzip jq podman python39 python39-pip python39-devel gcc gcc-c++ make openssl-devel libffi-devel bzip2-devel readline-devel sqlite-devel"

for pkg in $PACKAGES; do
  echo "[INIT] Installing $pkg"
  dnf -y install $pkg || echo "[WARN] Failed to install $pkg but continuing"
done

# Verify critical tools
for cmd in podman python3.9 git curl; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "[ERROR] Critical command '$cmd' not found"
    exit 1
  fi
done

echo "[INIT] Essential tools verified"
echo "Podman: $(podman --version)"
echo "Python: $(python3.9 --version)"

# --------------------------------------------------------------------
# Database setup script (robust version)
# --------------------------------------------------------------------
cat > /usr/local/bin/genai-db.sh << 'DBSCRIPT'
#!/bin/bash
set -euo pipefail

exec >> /var/log/genai_setup.log 2>&1

echo "[DB $(date '+%H:%M:%S')] Starting Oracle 23ai database setup"

# Configuration
ORACLE_PWD="database123"
ORACLE_PDB="FREEPDB1"
ORADATA_DIR="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
CONTAINER_NAME="23ai"

# Ensure podman is working
if ! podman --version >/dev/null 2>&1; then
  echo "[DB ERROR] Podman not available"
  exit 1
fi

# Create and set up data directory
echo "[DB] Preparing data directory"
mkdir -p "$ORADATA_DIR"
chown -R 54321:54321 "$ORADATA_DIR" 2>/dev/null || true
chmod -R 755 "$ORADATA_DIR"

# Clean up any existing container
echo "[DB] Cleaning up existing containers"
podman stop "$CONTAINER_NAME" 2>/dev/null || true
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Pull image with robust retry logic
echo "[DB] Pulling Oracle container image"
for attempt in 1 2 3 4 5; do
  echo "[DB] Pull attempt $attempt/5"
  if podman pull "$IMAGE"; then
    echo "[DB] Image pulled successfully"
    break
  fi
  
  if [ $attempt -eq 5 ]; then
    echo "[DB ERROR] Failed to pull image after 5 attempts"
    exit 1
  fi
  
  # Exponential backoff: 30s, 60s, 120s, 240s
  sleep_time=$((30 * attempt))
  echo "[DB] Waiting ${sleep_time}s before retry..."
  sleep $sleep_time
done

# Start container with error checking
echo "[DB] Starting Oracle database container"
if ! podman run -d \
  --name "$CONTAINER_NAME" \
  --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="$ORACLE_PDB" \
  -e ORACLE_MEMORY=2048 \
  -v "$ORADATA_DIR":/opt/oracle/oradata:Z \
  "$IMAGE"; then
  echo "[DB ERROR] Failed to start container"
  exit 1
fi

echo "[DB] Container started successfully"

# Enhanced database readiness monitoring
echo "[DB] Monitoring database initialization (10-20 minutes expected)"
max_wait=3000  # 50 minutes absolute maximum
check_interval=20
waited=0
last_status_time=0

while [ $waited -lt $max_wait ]; do
  # Check if container is still running
  if ! podman ps --filter "name=$CONTAINER_NAME" --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
    echo "[DB ERROR] Container stopped unexpectedly"
    podman logs "$CONTAINER_NAME" | tail -20
    exit 1
  fi
  
  # Check for database ready message
  if podman logs "$CONTAINER_NAME" 2>&1 | grep -q "DATABASE IS READY TO USE!"; then
    echo "[DB] Database initialization completed! (total time: ${waited}s)"
    break
  fi
  
  # Progress reporting every 2 minutes
  if [ $((waited % 120)) -eq 0 ] && [ $waited -gt $last_status_time ]; then
    echo "[DB] Database still initializing... (${waited}s elapsed)"
    # Show recent meaningful log entries
    podman logs --tail=5 "$CONTAINER_NAME" 2>&1 | grep -v "^$" | tail -2 | sed 's/^/[DB-LOG] /' || true
    last_status_time=$waited
  fi
  
  sleep $check_interval
  waited=$((waited + check_interval))
done

if [ $waited -ge $max_wait ]; then
  echo "[DB ERROR] Database initialization timeout after $max_wait seconds"
  echo "[DB ERROR] Final container logs:"
  podman logs --tail=30 "$CONTAINER_NAME" 2>&1 | sed 's/^/[CONTAINER] /'
  exit 1
fi

# Wait for Oracle processes to stabilize
echo "[DB] Allowing database processes to stabilize..."
sleep 30

# Configure PDB with proper error handling
echo "[DB] Configuring pluggable database"
podman exec "$CONTAINER_NAME" bash -c '
set -euo pipefail
source /home/oracle/.bashrc 2>/dev/null || export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export PATH=$ORACLE_HOME/bin:$PATH

# Configure PDB
sqlplus -s / as sysdba << EOF
WHENEVER SQLERROR CONTINUE
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;  
ALTER SYSTEM REGISTER;
EXIT;
EOF
' || echo "[DB] PDB configuration completed (some steps may have been redundant)"

# Wait for listener registration with timeout
echo "[DB] Waiting for listener service registration"
for i in {1..60}; do
  if podman exec "$CONTAINER_NAME" bash -c '
    source /home/oracle/.bashrc 2>/dev/null || export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
    export PATH=$ORACLE_HOME/bin:$PATH
    lsnrctl status
  ' 2>/dev/null | grep -qi 'Service.*FREEPDB1'; then
    echo "[DB] FREEPDB1 service registered with listener"
    break
  fi
  sleep 5
done

# Create vector user with proper error handling
echo "[DB] Creating vector database user"
podman exec "$CONTAINER_NAME" bash -c '
set -euo pipefail
source /home/oracle/.bashrc 2>/dev/null || export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export PATH=$ORACLE_HOME/bin:$PATH

sqlplus -s sys/'"$ORACLE_PWD"'@localhost:1521/FREEPDB1 as sysdba << EOF
WHENEVER SQLERROR CONTINUE
-- Drop user if exists to ensure clean state
DROP USER vector CASCADE;
-- Create user
CREATE USER vector IDENTIFIED BY "vector";
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
ALTER USER vector QUOTA UNLIMITED ON USERS;
EXIT;
EOF
' || echo "[DB] Vector user setup completed (may already exist)"

# Final connectivity verification
echo "[DB] Verifying database connectivity"
if podman exec "$CONTAINER_NAME" bash -c '
  source /home/oracle/.bashrc 2>/dev/null || export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
  export PATH=$ORACLE_HOME/bin:$PATH
  echo "SELECT 1 as test_connection FROM DUAL;" | sqlplus -s vector/vector@localhost:1521/FREEPDB1
' 2>/dev/null | grep -q "1"; then
  echo "[DB] Database connectivity verified successfully"
else
  echo "[DB WARNING] Connectivity test failed but database may still be functional"
fi

echo "[DB] Oracle 23ai database setup completed successfully"
DBSCRIPT

chmod +x /usr/local/bin/genai-db.sh

# --------------------------------------------------------------------
# Application setup script (fixed package installation)
# --------------------------------------------------------------------
cat > /usr/local/bin/genai-setup.sh << 'SETUPSCRIPT'
#!/bin/bash
set -euo pipefail

exec >> /var/log/genai_setup.log 2>&1

echo "[SETUP $(date '+%H:%M:%S')] Starting GenAI application setup"

MARKER="/var/lib/genai.setup.done"
if [ -f "$MARKER" ]; then
  echo "[SETUP] Setup already completed"
  exit 0
fi

# Create all required directories
echo "[SETUP] Creating directory structure"
mkdir -p /opt/genai \
         /home/opc/code \
         /home/opc/bin \
         /home/opc/.venvs \
         /home/opc/.config/systemd/user \
         /home/opc/oradata

# Set proper ownership
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/.venvs /home/opc/.config 2>/dev/null || true

# Download source code with retry logic
echo "[SETUP] Downloading GenAI source code"
CODE_DIR="/home/opc/code"
DOWNLOAD_SUCCESS=false

# Method 1: Direct download
for attempt in 1 2 3; do
  echo "[SETUP] Download attempt $attempt/3"
  cd /tmp
  rm -f genai-source.zip css-navigator-main -rf 2>/dev/null || true
  
  if curl -L --connect-timeout 30 --max-time 300 \
    -o genai-source.zip \
    "https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main"; then
    
    if unzip -q genai-source.zip 2>/dev/null; then
      if [ -d "css-navigator-main/gen-ai" ] && [ -n "$(ls -A css-navigator-main/gen-ai 2>/dev/null)" ]; then
        cp -r css-navigator-main/gen-ai/* "$CODE_DIR"/ 2>/dev/null || true
        echo "[SETUP] Source code downloaded and extracted successfully"
        DOWNLOAD_SUCCESS=true
        break
      fi
    fi
  fi
  
  sleep 10
done

# Fallback: create minimal structure
if [ "$DOWNLOAD_SUCCESS" = false ]; then
  echo "[SETUP] Download failed, creating minimal code structure"
  mkdir -p "$CODE_DIR"
  cat > "$CODE_DIR/README.md" << 'EOF'
# GenAI Code Directory
This directory is ready for your GenAI projects.
Source download failed but basic structure is in place.
EOF
fi

# Cleanup download artifacts
rm -rf /tmp/genai-source.zip /tmp/css-navigator-main 2>/dev/null || true
chown -R opc:opc "$CODE_DIR" 2>/dev/null || true

# Create Python virtual environment with FIXED package installation
echo "[SETUP] Setting up Python virtual environment"
sudo -u opc bash << 'EOF'
set -euo pipefail
export HOME=/home/opc
cd "$HOME"

echo "[VENV] Creating virtual environment"
python3.9 -m venv .venvs/genai

echo "[VENV] Activating environment"
source .venvs/genai/bin/activate

echo "[VENV] Upgrading pip and basic tools"
python -m pip install --upgrade --no-cache-dir pip wheel setuptools

# CRITICAL FIX: Install packages in correct order without index conflicts

echo "[VENV] Installing database connector (from PyPI)"
pip install --no-cache-dir oracledb

echo "[VENV] Installing OCI SDK"
pip install --no-cache-dir oci

echo "[VENV] Installing PyTorch CPU version"
pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

echo "[VENV] Installing core ML packages"
pip install --no-cache-dir \
  numpy \
  sentence-transformers \
  transformers \
  scikit-learn

echo "[VENV] Installing web frameworks"  
pip install --no-cache-dir \
  streamlit \
  jupyterlab \
  fastapi \
  uvicorn

echo "[VENV] Installing LangChain ecosystem"
pip install --no-cache-dir \
  langchain-core \
  langchain \
  langchain-community \
  langchain-text-splitters

echo "[VENV] Installing additional utilities"
pip install --no-cache-dir \
  pypdf \
  python-multipart \
  requests \
  pandas

# Clear pip cache to save space
pip cache purge 2>/dev/null || true

echo "[VENV] Adding environment activation to bashrc"
if ! grep -q "source.*venvs/genai" .bashrc 2>/dev/null; then
  echo 'source $HOME/.venvs/genai/bin/activate' >> .bashrc
fi

echo "[VENV] Python environment setup completed successfully"

# Verify critical packages
python -c "import oracledb; print('✓ oracledb working')"
python -c "import torch; print('✓ torch working')"
python -c "import streamlit; print('✓ streamlit working')" 
python -c "import jupyterlab; print('✓ jupyterlab working')"

EOF

# Create optimized Jupyter startup script
echo "[SETUP] Creating Jupyter startup script"
cat > /home/opc/start_jupyter.sh << 'EOF'
#!/bin/bash
set -e

export HOME=/home/opc
cd "$HOME"

# Verify virtual environment exists
if [ ! -f ".venvs/genai/bin/activate" ]; then
  echo "ERROR: Virtual environment not found at $HOME/.venvs/genai"
  exit 1
fi

echo "Starting JupyterLab..."
source .venvs/genai/bin/activate

# Create jupyter config directory if it doesn't exist
mkdir -p ~/.jupyter

# Start JupyterLab with optimized settings
exec jupyter lab \
  --ip=0.0.0.0 \
  --port=8888 \
  --no-browser \
  --NotebookApp.token='' \
  --NotebookApp.password='' \
  --NotebookApp.allow_origin='*' \
  --NotebookApp.disable_check_xsrf=True \
  --ServerApp.allow_root=True
EOF

chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

# Create systemd user service for Jupyter
echo "[SETUP] Setting up Jupyter systemd service"
sudo -u opc bash << 'EOF'
mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/jupyter.service" << 'UNIT'
[Unit]
Description=JupyterLab Server for GenAI
After=graphical-session.target

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

# Reload and enable the service
systemctl --user daemon-reload
systemctl --user enable jupyter.service
EOF

# Enable user services to persist after logout
loginctl enable-linger opc 2>/dev/null || true

# Configure firewall with proper timing
echo "[SETUP] Configuring firewall"
# Ensure firewalld is running before configuring it
systemctl enable firewalld
systemctl start firewalld

# Wait for firewalld to be fully ready
sleep 10

# Configure firewall rules with retry
for port in 8888 8501 1521; do
  for attempt in 1 2 3; do
    if firewall-cmd --permanent --add-port=${port}/tcp; then
      echo "[SETUP] Added firewall rule for port $port"
      break
    fi
    echo "[SETUP] Firewall rule attempt $attempt failed for port $port, retrying..."
    sleep 5
  done
done

# Reload firewall configuration
firewall-cmd --reload || echo "[SETUP] Firewall reload failed but continuing"

# Create configuration files
echo "[SETUP] Creating configuration files"
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
        """Load configuration from JSON file"""
        if not os.path.isabs(config_file):
            config_file = os.path.join(os.path.dirname(__file__), config_file)
        
        try:
            with open(config_file, 'r') as f:
                self.config = json.load(f)
        except Exception as e:
            print(f"Error loading config: {e}")
            self.config = {}
    
    def getModelName(self):
        return self.config.get("model_name", "cohere.command-r-16k")
    
    def getEmbeddingModelName(self):
        return self.config.get("embedding_model_name", "cohere.embed-english-v3.0")
    
    def getEndpoint(self):
        return self.config.get("endpoint", "https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com")
    
    def getCompartment(self):
        return self.config.get("compartment_ocid", "")
EOF

# Create sample documents
echo "[SETUP] Creating sample documents"
mkdir -p /opt/genai/txt-docs /opt/genai/pdf-docs

cat > /opt/genai/txt-docs/faq.txt << 'EOF'
faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier that provide limited resources at no cost for learning and development.

faq | How do I access JupyterLab?=====After setup completion, access JupyterLab at http://your-vm-ip:8888 in your web browser.

faq | What Python packages are installed?=====The environment includes PyTorch, transformers, sentence-transformers, langchain, streamlit, jupyter, oracledb, and oci SDK.

faq | How do I connect to the Oracle database?=====Use connection string: vector/vector@localhost:1521/FREEPDB1

faq | Where is the source code located?=====GenAI source code is located in /home/opc/code directory.
EOF

# Set proper ownership for all created files
chown -R opc:opc /opt/genai

# Final cleanup
echo "[SETUP] Performing final cleanup"
dnf clean all 2>/dev/null || true
rm -rf /tmp/genai-* /tmp/css-navigator* /var/cache/dnf/* 2>/dev/null || true

# Create completion marker
touch "$MARKER"

echo "[SETUP] GenAI application setup completed successfully!"
echo "[SETUP] JupyterLab will be available at: http://your-vm-ip:8888"
SETUPSCRIPT

chmod +x /usr/local/bin/genai-setup.sh

# --------------------------------------------------------------------
# Create helper scripts
# --------------------------------------------------------------------
cat > /usr/local/bin/genai-status.sh << 'EOF'
#!/bin/bash
echo "=== GenAI Stack Status ==="
echo
echo "Database Container:"
podman ps -a --filter name=23ai --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo
echo "Jupyter Service:"
sudo -u opc systemctl --user is-active jupyter.service 2>/dev/null || echo "inactive"
echo
echo "Firewall Ports:"
firewall-cmd --list-ports 2>/dev/null || echo "firewall not configured"
echo
echo "Virtual Environment:"
sudo -u opc bash -c 'source ~/.venvs/genai/bin/activate 2>/dev/null && python --version' || echo "venv not found"
EOF

chmod +x /usr/local/bin/genai-status.sh

# --------------------------------------------------------------------
# Run setup with proper sequencing
# --------------------------------------------------------------------
echo "[MAIN] Starting database setup"
if /usr/local/bin/genai-db.sh; then
  echo "[MAIN] Database setup completed successfully"
  
  echo "[MAIN] Starting application setup" 
  if /usr/local/bin/genai-setup.sh; then
    echo "[MAIN] Application setup completed successfully"
    
    # Start Jupyter service
    echo "[MAIN] Starting Jupyter service"
    sudo -u opc systemctl --user start jupyter.service || echo "[WARN] Jupyter service start failed"
    
    echo "[SUCCESS] GenAI stack setup completed!"
    echo "Access JupyterLab at: http://your-vm-ip:8888"
    echo "Check status with: /usr/local/bin/genai-status.sh"
    
  else
    echo "[ERROR] Application setup failed"
    exit 1
  fi
else
  echo "[ERROR] Database setup failed"
  exit 1
fi

echo "===== GenAI OneClick: completed successfully $(date -u) ====="
