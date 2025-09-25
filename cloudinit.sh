#!/bin/bash
# cloudinit.sh - Clean GenAI setup (based on working version)
# Simplified, proven approach without complex error handling

set -e

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# Basic system setup
echo "[INIT] Basic system setup"
/usr/libexec/oci-growfs -y 2>/dev/null || true
dnf clean all
dnf config-manager --set-disabled ol8_ksplice 2>/dev/null || true
dnf -y install dnf-plugins-core
dnf config-manager --set-enabled ol8_addons
dnf -y makecache --refresh

# Install packages
echo "[INIT] Installing packages"
dnf -y install curl wget git unzip jq podman python39 python39-pip gcc gcc-c++ make openssl-devel libffi-devel firewalld

# Verify essentials
podman --version
python3.9 --version

echo "[INIT] Creating directories"
mkdir -p /opt/genai /home/opc/code /home/opc/bin /home/opc/.venvs /home/opc/oradata
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin /home/opc/.venvs /home/opc/oradata

# Start database
echo "[DB] Starting Oracle database"
mkdir -p /home/opc/oradata
chown -R 54321:54321 /home/opc/oradata
chmod -R 755 /home/opc/oradata

podman rm -f 23ai 2>/dev/null || true
podman pull container-registry.oracle.com/database/free:latest

podman run -d --name 23ai --network=host \
  -e ORACLE_PWD=database123 \
  -e ORACLE_PDB=FREEPDB1 \
  -e ORACLE_MEMORY=2048 \
  -v /home/opc/oradata:/opt/oracle/oradata:Z \
  container-registry.oracle.com/database/free:latest

echo "[DB] Waiting for database initialization (15-20 minutes)"
timeout=2400
elapsed=0
while [ $elapsed -lt $timeout ]; do
  if podman logs 23ai 2>&1 | grep -q "DATABASE IS READY TO USE!"; then
    echo "[DB] Database ready after ${elapsed}s"
    break
  fi
  if [ $((elapsed % 120)) -eq 0 ] && [ $elapsed -gt 0 ]; then
    echo "[DB] Still waiting... (${elapsed}s)"
  fi
  sleep 30
  elapsed=$((elapsed + 30))
done

if [ $elapsed -ge $timeout ]; then
  echo "[ERROR] Database timeout"
  exit 1
fi

# Configure database
echo "[DB] Configuring database"
sleep 30

podman exec 23ai bash -c '
source /home/oracle/.bashrc
sqlplus -s / as sysdba << EOF
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
ALTER SYSTEM REGISTER;
EXIT;
EOF
' || true

# Wait for service registration
echo "[DB] Waiting for service registration"
for i in {1..60}; do
  if podman exec 23ai bash -c 'source /home/oracle/.bashrc; lsnrctl status' 2>/dev/null | grep -qi FREEPDB1; then
    echo "[DB] Service registered"
    break
  fi
  sleep 5
done

# Create vector user
echo "[DB] Creating vector user"
podman exec 23ai bash -c '
source /home/oracle/.bashrc
sqlplus -s sys/database123@localhost:1521/FREEPDB1 as sysdba << EOF || true
CREATE USER vector IDENTIFIED BY "vector";
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
ALTER USER vector QUOTA UNLIMITED ON USERS;
EXIT;
EOF
' || true

echo "[DB] Database setup complete"

# Download source code
echo "[APP] Downloading source code"
cd /tmp
wget -q -O source.zip "https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main"
unzip -q source.zip
if [ -d css-navigator-main/gen-ai ]; then
  cp -r css-navigator-main/gen-ai/* /home/opc/code/
fi
rm -rf css-navigator-main source.zip
chown -R opc:opc /home/opc/code

# Setup Python environment
echo "[APP] Setting up Python environment"
sudo -u opc bash << 'EOF'
cd /home/opc
python3.9 -m venv .venvs/genai
source .venvs/genai/bin/activate
pip install --upgrade pip

# Install packages in working order
pip install oracledb
pip install torch --index-url https://download.pytorch.org/whl/cpu
pip install sentence-transformers transformers
pip install streamlit jupyterlab fastapi
pip install langchain langchain-community langchain-core
pip install pypdf python-multipart oci pandas requests

echo 'source $HOME/.venvs/genai/bin/activate' >> .bashrc
EOF

# Create startup script
echo "[APP] Creating Jupyter startup script"
cat > /home/opc/start_jupyter.sh << 'EOF'
#!/bin/bash
export HOME=/home/opc
cd $HOME
source .venvs/genai/bin/activate
jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --NotebookApp.token='' --NotebookApp.password='' --allow-root
EOF
chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

# Create systemd service
echo "[APP] Creating systemd service"
sudo -u opc bash << 'EOF'
mkdir -p $HOME/.config/systemd/user
cat > $HOME/.config/systemd/user/jupyter.service << 'UNIT'
[Unit]
Description=JupyterLab

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
echo "[APP] Configuring firewall"
systemctl enable --now firewalld
sleep 5
firewall-cmd --permanent --add-port=8888/tcp
firewall-cmd --permanent --add-port=8501/tcp  
firewall-cmd --permanent --add-port=1521/tcp
firewall-cmd --reload

# Create config files
echo "[APP] Creating config files"
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

# Start Jupyter
echo "[APP] Starting Jupyter service"
sudo -u opc systemctl --user start jupyter.service

# Cleanup
dnf clean all
rm -rf /tmp/*

echo "===== GenAI OneClick: COMPLETED $(date -u) ====="
echo "Access JupyterLab at: http://your-vm-ip:8888"
echo "Database: vector/vector@localhost:1521/FREEPDB1"
