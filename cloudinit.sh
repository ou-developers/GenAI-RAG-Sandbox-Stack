#!/bin/bash

# Define a log file for capturing all output
LOGFILE=/var/log/cloud-init-output.log
exec > >(tee -a $LOGFILE) 2>&1

# Marker file to ensure the script only runs once
MARKER_FILE="/home/opc/.init_done"

# Check if the marker file exists
if [ -f "$MARKER_FILE" ]; then
  echo "Init script has already been run. Exiting."
  exit 0
fi

echo "===== Starting Cloud-Init Script ====="

# Expand the boot volume
echo "Expanding boot volume..."
/usr/libexec/oci-growfs -y || true

# AGGRESSIVE repository cleanup - disable ALL problematic repos
echo "Disabling problematic repositories..."
dnf config-manager --set-disabled ol8_ksplice 2>/dev/null || true
dnf config-manager --set-disabled mysql-8.0-community 2>/dev/null || true
dnf config-manager --set-disabled mysql-tools-8.0-community 2>/dev/null || true
dnf config-manager --set-disabled mysql-connectors-community 2>/dev/null || true
dnf config-manager --set-disabled ol8_MySQL84 2>/dev/null || true
dnf config-manager --set-disabled ol8_mysql 2>/dev/null || true

# Clean everything and work with minimal repos
echo "Cleaning package cache..."
dnf clean all
rm -rf /var/cache/dnf/*

# Only enable essential Oracle repos
echo "Enabling essential repositories only..."
dnf config-manager --enable ol8_baseos_latest ol8_appstream

# Quick network test
echo "Testing network connectivity..."
for i in {1..30}; do
  if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "Network is working"
    break
  fi
  sleep 2
done

# Install packages with aggressive error handling
echo "Installing core packages..."
dnf -y install dnf-plugins-core curl wget || {
  echo "Failed to install basic tools"
  exit 1
}

# Enable ol8_addons only after basic tools work
dnf config-manager --enable ol8_addons || true

# Force cache refresh with timeout
echo "Refreshing package cache with timeout..."
timeout 300 dnf makecache --refresh || echo "Cache refresh timed out, using existing cache"

# Install essential packages one by one
for pkg in podman git python39 python39-pip gcc make openssl-devel libffi-devel firewalld unzip; do
  echo "Installing $pkg..."
  dnf -y install $pkg || echo "Warning: Failed to install $pkg"
done

# Verify critical tools
echo "Verifying installations..."
if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: Podman not installed, trying alternative method"
  dnf -y install podman-docker || dnf -y install docker
  if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    echo "FATAL: No container runtime available"
    exit 1
  fi
fi

if ! command -v python3.9 >/dev/null 2>&1; then
  echo "ERROR: Python 3.9 not available"
  exit 1
fi

echo "Podman: $(podman --version 2>/dev/null || echo 'not found')"
echo "Python: $(python3.9 --version 2>/dev/null || echo 'not found')"

# Skip SQLite compilation for now - use system version
echo "Using system SQLite version..."
echo "SQLite version: $(python3.9 -c 'import sqlite3; print(sqlite3.sqlite_version)' 2>/dev/null || echo 'not available')"

# Create required directories
echo "Creating directories..."
mkdir -p /opt/genai /home/opc/code /home/opc/oradata /home/opc/.venvs /home/opc/labs
chown -R opc:opc /opt/genai /home/opc/code /home/opc/.venvs /home/opc/labs

# Set up Oracle data directory
echo "Setting up Oracle data directory..."
chown -R 54321:54321 /home/opc/oradata
chmod -R 755 /home/opc/oradata

# Download source code first (while network is working)
echo "Downloading source code..."
cd /tmp
for attempt in 1 2 3; do
  echo "Download attempt $attempt/3"
  if wget -q --timeout=60 -O genai-source.zip "https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main"; then
    unzip -q genai-source.zip 2>/dev/null || true
    if [ -d css-navigator-main/gen-ai ]; then
      cp -r css-navigator-main/gen-ai/* /home/opc/code/
      echo "Gen-AI source files copied successfully"
      break
    fi
  fi
  sleep 10
done

# Create basic files if download failed
if [ ! -f /home/opc/code/README.md ]; then
  echo "Source download failed, creating basic structure"
  cat > /home/opc/code/README.md << 'EOF'
# GenAI Code Directory
Source download failed, but basic structure is ready.
You can manually upload notebooks here.
EOF
fi

rm -rf /tmp/css-navigator-main /tmp/genai-source.zip 2>/dev/null || true
chown -R opc:opc /home/opc/code

# Run the Oracle Database Free Edition container
echo "Starting Oracle Database container..."
podman pull container-registry.oracle.com/database/free:latest || {
  echo "ERROR: Failed to pull Oracle image"
  exit 1
}

podman run -d \
    --name 23ai \
    --network=host \
    -e ORACLE_PWD=database123 \
    -e ORACLE_PDB=FREEPDB1 \
    -v /home/opc/oradata:/opt/oracle/oradata:z \
    container-registry.oracle.com/database/free:latest || {
  echo "ERROR: Failed to start Oracle container"
  exit 1
}

# Wait for Oracle with better progress reporting
echo "Waiting for Oracle database initialization (this takes 15-25 minutes)..."
timeout=2400  # 40 minutes max
elapsed=0
while [ $elapsed -lt $timeout ]; do
  if podman logs 23ai 2>&1 | grep -q "DATABASE IS READY TO USE!"; then
    echo "Oracle Database is ready! (took ${elapsed}s)"
    break
  fi
  
  # Show progress every 2 minutes
  if [ $((elapsed % 120)) -eq 0 ] && [ $elapsed -gt 0 ]; then
    echo "Database still initializing... (${elapsed}s elapsed)"
    # Show recent meaningful logs
    podman logs --tail=3 23ai 2>&1 | grep -E "(percent|complete|Creating|Starting)" | tail -1 || true
  fi
  
  sleep 30
  elapsed=$((elapsed + 30))
done

if [ $elapsed -ge $timeout ]; then
  echo "ERROR: Database initialization timeout after $timeout seconds"
  echo "Final container logs:"
  podman logs --tail=20 23ai
  exit 1
fi

# Configure database with simpler approach
echo "Configuring database..."
sleep 30

# Simple PDB configuration
podman exec 23ai bash -c '
source /home/oracle/.bashrc 2>/dev/null || true
sqlplus -s / as sysdba << EOF || true
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;  
EXIT;
EOF
' || echo "PDB configuration completed (may have been redundant)"

# Wait briefly for service registration
echo "Waiting for database service registration..."
sleep 60

# Create vector user with simple approach
echo "Creating vector database user..."
podman exec 23ai bash -c '
source /home/oracle/.bashrc 2>/dev/null || true
sqlplus -s sys/database123@localhost:1521/FREEPDB1 as sysdba << EOF || true
CREATE USER vector IDENTIFIED BY vector;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
ALTER USER vector QUOTA UNLIMITED ON USERS;
EXIT;
EOF
' || echo "Vector user setup completed (may already exist)"

echo "Database configuration completed"

# Create simple Python environment
echo "Setting up Python environment..."
sudo -u opc bash << 'EOF'
cd /home/opc

# Create simple venv
python3.9 -m venv .venvs/genai
source .venvs/genai/bin/activate
pip install --upgrade pip

# Install essential packages only (to avoid space/network issues)
pip install --no-cache-dir oracledb
pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
pip install --no-cache-dir jupyterlab streamlit
pip install --no-cache-dir langchain oci

# Add activation to bashrc
echo 'source $HOME/.venvs/genai/bin/activate' >> .bashrc
EOF

# Create simple Jupyter startup script
echo "Creating Jupyter startup script..."
cat > /home/opc/start_jupyter.sh << 'EOF'
#!/bin/bash
export HOME=/home/opc
cd $HOME

# Try venv first, fallback to system python
if [ -f .venvs/genai/bin/activate ]; then
  source .venvs/genai/bin/activate
else
  export PATH=/home/opc/.local/bin:$PATH
fi

jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --NotebookApp.token='' --NotebookApp.password=''
EOF

chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

# Create basic config files
echo "Creating configuration files..."
cat > /opt/genai/config.txt << 'EOF'
{
  "model_name": "cohere.command-r-16k",
  "embedding_model_name": "cohere.embed-english-v3.0",
  "endpoint": "https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com",
  "compartment_ocid": "replace_with_your_compartment_ocid"
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

mkdir -p /opt/genai/txt-docs
echo "faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier." > /opt/genai/txt-docs/faq.txt
chown -R opc:opc /opt/genai

# Configure firewall (non-critical)
echo "Configuring firewall..."
systemctl enable --now firewalld || true
sleep 3
firewall-cmd --permanent --add-port=8888/tcp || true
firewall-cmd --permanent --add-port=1521/tcp || true
firewall-cmd --reload || true

# Start JupyterLab
echo "Starting JupyterLab..."
sudo -u opc nohup /home/opc/start_jupyter.sh > /home/opc/jupyter.log 2>&1 &

# Final verification
echo "Performing final verification..."
sleep 10
if pgrep -f "jupyter" >/dev/null; then
  echo "✓ JupyterLab is running"
else
  echo "⚠ JupyterLab may not have started - check /home/opc/jupyter.log"
fi

if podman ps | grep -q 23ai; then
  echo "✓ Oracle container is running"
else
  echo "⚠ Oracle container issue - check with 'podman ps -a'"
fi

# Create the completion marker
touch "$MARKER_FILE"

echo "===== Cloud-Init Script Completed ====="
echo ""
echo "🎉 Setup Summary:"
echo "   JupyterLab: http://your-vm-ip:8888" 
echo "   Database: vector/vector@localhost:1521/FREEPDB1"
echo "   Files: /home/opc/code/ and /home/opc/labs/"
echo "   Logs: tail -f /var/log/cloud-init-output.log"
echo ""
exit 0
