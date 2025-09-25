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
sudo /usr/libexec/oci-growfs -y

# Disable problematic repositories to avoid MySQL delays
echo "Configuring repositories..."
sudo dnf config-manager --set-disabled ol8_ksplice 2>/dev/null || true
sudo dnf config-manager --set-disabled mysql-8.0-community 2>/dev/null || true
sudo dnf config-manager --set-disabled mysql-tools-8.0-community 2>/dev/null || true
sudo dnf config-manager --set-disabled mysql-connectors-community 2>/dev/null || true

# Enable ol8_addons and install necessary development tools
echo "Installing required packages..."
sudo dnf config-manager --set-enabled ol8_addons
sudo dnf clean all
sudo dnf install -y podman git libffi-devel bzip2-devel ncurses-devel readline-devel wget make gcc zlib-devel openssl-devel curl unzip python39 python39-pip firewalld

# Install the latest SQLite from source
echo "Installing latest SQLite..."
cd /tmp
wget -q https://www.sqlite.org/2023/sqlite-autoconf-3430000.tar.gz
tar -xzf sqlite-autoconf-3430000.tar.gz
cd sqlite-autoconf-3430000
./configure --prefix=/usr/local
make -s
sudo make install

# Verify the installation of SQLite
echo "SQLite version:"
/usr/local/bin/sqlite3 --version

# Ensure the correct version is in the path and globally
export PATH="/usr/local/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
echo 'export PATH="/usr/local/bin:$PATH"' >> /home/opc/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"' >> /home/opc/.bashrc

# Set environment variables to link the newly installed SQLite with Python build globally
echo 'export CFLAGS="-I/usr/local/include"' >> /home/opc/.bashrc
echo 'export LDFLAGS="-L/usr/local/lib"' >> /home/opc/.bashrc

# Source the updated ~/.bashrc to apply changes globally
source /home/opc/.bashrc

# Create required directories
echo "Creating directories..."
sudo mkdir -p /opt/genai /home/opc/code /home/opc/oradata /home/opc/.venvs
sudo chown -R opc:opc /opt/genai /home/opc/code /home/opc/.venvs

# Create a persistent volume directory for Oracle data
echo "Setting up Oracle data directory..."
sudo chown -R 54321:54321 /home/opc/oradata
sudo chmod -R 755 /home/opc/oradata

# Run the Oracle Database Free Edition container
echo "Running Oracle Database container..."
sudo podman run -d \
    --name 23ai \
    --network=host \
    -e ORACLE_PWD=database123 \
    -e ORACLE_PDB=FREEPDB1 \
    -v /home/opc/oradata:/opt/oracle/oradata:z \
    container-registry.oracle.com/database/free:latest

# Wait for Oracle Container to start
echo "Waiting for Oracle container to initialize..."
timeout=2400  # 40 minutes
elapsed=0
while [ $elapsed -lt $timeout ]; do
  if sudo podman logs 23ai 2>&1 | grep -q "DATABASE IS READY TO USE!"; then
    echo "Oracle Database is ready after ${elapsed}s"
    break
  fi
  if [ $((elapsed % 120)) -eq 0 ] && [ $elapsed -gt 0 ]; then
    echo "Still waiting for database... (${elapsed}s elapsed)"
  fi
  sleep 30
  elapsed=$((elapsed + 30))
done

if [ $elapsed -ge $timeout ]; then
  echo "Database initialization timeout"
  exit 1
fi

echo "Configuring database..."
sleep 30

# Configure PDB
sudo podman exec -i 23ai bash -c '
source /home/oracle/.bashrc
sqlplus -s / as sysdba << EOF
ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
ALTER SYSTEM REGISTER;
EXIT;
EOF
' || true

# Wait for service registration with timeout
echo "Waiting for service registration..."
for i in {1..60}; do
  if sudo podman exec 23ai bash -c "source /home/oracle/.bashrc; lsnrctl status" | grep -qi freepdb1; then
    echo "FREEPDB1 service is registered."
    break
  fi
  sleep 10
done

# Run the SQL commands to configure the PDB and create vector user
echo "Configuring Oracle database in PDB (FREEPDB1)..."
sudo podman exec -i 23ai bash << 'EOF'
source /home/oracle/.bashrc
sqlplus -s sys/database123@localhost:1521/FREEPDB1 as sysdba << EOSQL
WHENEVER SQLERROR CONTINUE
CREATE BIGFILE TABLESPACE tbs2 DATAFILE 'bigtbs_f2.dbf' SIZE 1G AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO;
CREATE UNDO TABLESPACE undots2 DATAFILE 'undotbs_2a.dbf' SIZE 1G AUTOEXTEND ON RETENTION GUARANTEE;
CREATE TEMPORARY TABLESPACE temp_demo TEMPFILE 'temp02.dbf' SIZE 1G REUSE AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;
CREATE USER vector IDENTIFIED BY vector DEFAULT TABLESPACE tbs2 QUOTA UNLIMITED ON tbs2;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
GRANT DB_DEVELOPER_ROLE TO vector;
EXIT;
EOSQL
EOF

# Reconnect to CDB root to apply system-level changes
echo "Switching to CDB root for system-level changes..."
sudo podman exec -i 23ai bash << 'EOF'
source /home/oracle/.bashrc
sqlplus -s / as sysdba << EOSQL
WHENEVER SQLERROR CONTINUE
CREATE PFILE FROM SPFILE;
ALTER SYSTEM SET vector_memory_size = 512M SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
EOSQL
EOF

echo "Database configuration completed."

# Download css-navigator gen-ai files
echo "Downloading css-navigator gen-ai files..."
cd /tmp
wget -q -O genai-source.zip "https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main"
if [ -f genai-source.zip ]; then
  unzip -q genai-source.zip
  if [ -d css-navigator-main/gen-ai ]; then
    cp -r css-navigator-main/gen-ai/* /home/opc/code/
    echo "Gen-AI source files copied to /home/opc/code/"
  fi
  rm -rf css-navigator-main genai-source.zip
fi
sudo chown -R opc:opc /home/opc/code

# Now switch to opc user for Python environment setup
sudo -u opc -i bash << 'EOF_OPC'

# Set environment variables
export HOME=/home/opc
export PYENV_ROOT="$HOME/.pyenv"
curl -sS https://pyenv.run | bash

# Add pyenv initialization to ~/.bashrc for opc
cat << EOF >> $HOME/.bashrc
export PYENV_ROOT="\$HOME/.pyenv"
[[ -d "\$PYENV_ROOT/bin" ]] && export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init --path)"
eval "\$(pyenv init -)"
eval "\$(pyenv virtualenv-init -)"
EOF

# Ensure .bashrc is sourced on login
cat << EOF >> $HOME/.bash_profile
if [ -f ~/.bashrc ]; then
   source ~/.bashrc
fi
EOF

# Source the updated ~/.bashrc to apply pyenv changes
source $HOME/.bashrc

# Export PATH to ensure pyenv is correctly initialized
export PATH="$PYENV_ROOT/bin:$PATH"

# Install Python 3.11.9 using pyenv with the correct SQLite version linked
CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib" LD_LIBRARY_PATH="/usr/local/lib" pyenv install -s 3.11.9

# Rehash pyenv to update shims
pyenv rehash

# Set up labs directory and Python 3.11.9 environment
mkdir -p $HOME/labs
cd $HOME/labs
pyenv local 3.11.9

# Rehash again to ensure shims are up to date
pyenv rehash

# Verify Python version in the labs directory
python --version

# Adding the PYTHONPATH for correct installation and look up for the libraries
export PYTHONPATH=$HOME/.pyenv/versions/3.11.9/lib/python3.11/site-packages:$PYTHONPATH

# Install required Python packages
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir \
    oci==2.129.1 \
    oracledb \
    sentence-transformers \
    langchain==0.2.6 \
    langchain-community==0.2.6 \
    langchain-chroma==0.1.2 \
    langchain-core==0.2.11 \
    langchain-text-splitters==0.2.2 \
    langsmith==0.1.83 \
    pypdf==4.2.0 \
    streamlit==1.36.0 \
    python-multipart==0.0.9 \
    chroma-hnswlib==0.7.3 \
    chromadb==0.5.3 \
    torch==2.5.0

# Download the model during script execution
python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L12-v2')"

# Install JupyterLab
pip install --user jupyterlab

# Install OCI CLI
echo "Installing OCI CLI..."
curl -sL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o install.sh
chmod +x install.sh
./install.sh --accept-all-defaults

# Ensure all the binaries are added to PATH
echo 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc
source $HOME/.bashrc

# Copy files from the ou-generativeai-pro repo labs folder
echo "Copying files from the OU Git repository labs folder..."
REPO_URL="https://github.com/ou-developers/ou-generativeai-pro.git"
FINAL_DIR="$HOME/labs"

# Initialize a new git repository in labs directory
cd $FINAL_DIR
git init

# Add the remote repository
git remote add origin $REPO_URL

# Enable sparse-checkout and specify the folder to download
git config core.sparseCheckout true
echo "labs/*" >> .git/info/sparse-checkout

# Pull only the specified folder
git pull origin main || true

# Move the contents of the 'labs' subfolder to the root of FINAL_DIR, if necessary
mv labs/* . 2>/dev/null || true

# Remove any remaining empty 'labs' directory and .git folder
rm -rf .git labs 2>/dev/null || true

echo "Files successfully downloaded to $FINAL_DIR"

EOF_OPC

# Create additional Python 3.9 venv for compatibility
echo "Creating Python 3.9 virtual environment..."
sudo -u opc python3.9 -m venv /home/opc/.venvs/genai
sudo -u opc bash -c 'source /home/opc/.venvs/genai/bin/activate; pip install --upgrade pip; pip install jupyterlab streamlit oracledb torch --index-url https://download.pytorch.org/whl/cpu'

# Create Jupyter startup script
echo "Creating Jupyter startup script..."
cat > /home/opc/start_jupyter.sh << 'EOF'
#!/bin/bash
export HOME=/home/opc
cd $HOME/labs
source $HOME/.pyenv/versions/3.11.9/bin/activate 2>/dev/null || source $HOME/.venvs/genai/bin/activate
jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --NotebookApp.token='' --NotebookApp.password='' --allow-root
EOF

sudo chown opc:opc /home/opc/start_jupyter.sh
sudo chmod +x /home/opc/start_jupyter.sh

# Create config files in /opt/genai
echo "Creating configuration files..."
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

sudo mkdir -p /opt/genai/txt-docs /opt/genai/pdf-docs
echo "faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier." > /opt/genai/txt-docs/faq.txt
sudo chown -R opc:opc /opt/genai

# Configure firewall
echo "Configuring firewall..."
sudo systemctl enable --now firewalld
sleep 5
sudo firewall-cmd --permanent --add-port=8888/tcp || true
sudo firewall-cmd --permanent --add-port=8501/tcp || true  
sudo firewall-cmd --permanent --add-port=1521/tcp || true
sudo firewall-cmd --reload || true

# Start Jupyter Lab
echo "Starting JupyterLab..."
sudo -u opc nohup /home/opc/start_jupyter.sh > /home/opc/jupyter.log 2>&1 &

# Create the marker file to indicate the script has been run
touch "$MARKER_FILE"

echo "===== Cloud-Init Script Completed Successfully ====="
echo "JupyterLab accessible at: http://your-vm-ip:8888"
echo "Database: vector/vector@localhost:1521/FREEPDB1"
echo "Gen-AI files located in: /home/opc/code/"
echo "Labs files located in: /home/opc/labs/"
exit 0
