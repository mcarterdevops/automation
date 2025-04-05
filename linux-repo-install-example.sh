#!/bin/bash
set -e

<<INPUT
Prompts for the installation location.
INPUT
read -p "Enter the installation location: " location
echo "Installation location: $location"

<<AZURE
Download the necessary files based on the installation location.
AZURE

# -----------------------------
# Install Azure CLI
# -----------------------------

rpm --import https://packages.microsoft.com/keys/microsoft.asc

sudo tee /etc/yum.repos.d/azure-cli.repo <<EOF
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

dnf install azure-cli -y

# -----------------------------
# Download main configuration file from Azure
# -----------------------------

AZURE_STORAGE_ACCOUNT="yourStorageAccountName"
AZURE_CONTAINER_NAME="yourContainerName"
BLOB_NAME="veeam_config_${location}.txt"
LOCAL_FILE="/tmp/${BLOB_NAME}"

echo "Downloading configuration file '$BLOB_NAME' from Azure..."
az storage blob download \
  --account-name "$AZURE_STORAGE_ACCOUNT" \
  --container-name "$AZURE_CONTAINER_NAME" \
  --name "$BLOB_NAME" \
  --file "$LOCAL_FILE" \
  --auth-mode login

if [ $? -ne 0 ]; then
  echo "Error: Failed to download configuration file. Exiting."
  exit 1
fi
echo "Configuration file downloaded to $LOCAL_FILE"

# -----------------------------
# Parse configuration file for required parameters
# -----------------------------

veeam_server_ip=$(grep '^VEEAM_SERVER_IP=' "$LOCAL_FILE" | cut -d'=' -f2)
if [ -z "$veeam_server_ip" ]; then
  echo "Veeam Server IP not found in configuration file."
  read -p "Enter Veeam Server IP: " veeam_server_ip
fi

management_ip=$(grep '^MANAGEMENT_IP=' "$LOCAL_FILE" | cut -d'=' -f2)
if [ -z "$management_ip" ]; then
  echo "Management IP not found in configuration file."
  read -p "Enter Management IP: " management_ip
fi

local_subnet=$(grep '^LOCAL_SUBNET=' "$LOCAL_FILE" | cut -d'=' -f2)
if [ -z "$local_subnet" ]; then
  echo "Local subnet not found in configuration file."
  read -p "Enter local subnet in CIDR format: " local_subnet
fi

repo_user=$(grep '^REPO_USER=' "$LOCAL_FILE" | cut -d'=' -f2)
repo_password=$(grep '^REPO_PASSWORD=' "$LOCAL_FILE" | cut -d'=' -f2)

echo "Veeam Server IP: $veeam_server_ip"
echo "Management IP: $management_ip"
echo "Local Subnet: $local_subnet"

# -----------------------------
# Download and store additional files from Azure
# -----------------------------

echo "Creating required directories in /tmp..."
mkdir -p /tmp/etc/snmp /tmp/etc/yum.repos.d /tmp/crowdstrike /tmp/omsa /tmp/etc/duo /tmp/etc/pam.d /tmp/etc/ssh /tmp/etc/firewalld

echo "Downloading SNMP config from Azure..."
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "etc/snmp/snmpd.conf" --file "/tmp/etc/snmp/snmpd.conf" --auth-mode login

echo "Downloading Duo repository file from Azure..."
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "etc/yum.repos.d/duosecurity.repo" --file "/tmp/etc/yum.repos.d/duosecurity.repo" --auth-mode login

echo "Downloading CrowdStrike RPM from Azure..."
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "crowdstrike/falcon-sensor-6.45.0-14203.el8.x86_64.rpm" --file "/tmp/crowdstrike/falcon-sensor-6.45.0-14203.el8.x86_64.rpm" --auth-mode login

echo "Downloading OMSA tarball from Azure..."
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "omsa/OM-SrvAdmin-Dell-Web-LX-10.3.0.0-5081_A01.tar.gz" --file "/tmp/omsa/OM-SrvAdmin-Dell-Web-LX-10.3.0.0-5081_A01.tar.gz" --auth-mode login

echo "Downloading Duo configuration file from Azure..."
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "etc/duo/pam_duo.conf" --file "/tmp/etc/duo/pam_duo.conf" --auth-mode login

echo "Downloading PAM configuration files (cockpit and sshd) from Azure..."
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "etc/pam.d/cockpit" --file "/tmp/etc/pam.d/cockpit" --auth-mode login
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "etc/pam.d/sshd" --file "/tmp/etc/pam.d/sshd" --auth-mode login

echo "Downloading SSH configuration file from Azure..."
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "etc/ssh/sshd_config" --file "/tmp/etc/ssh/sshd_config" --auth-mode login

echo "Downloading firewalld configuration file from Azure..."
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "etc/firewalld/firewalld.conf" --file "/tmp/etc/firewalld/firewalld.conf" --auth-mode login

<<USERS_AND_DIRECTORIES
Creates the necessary user accounts and repo locations
USERS_AND_DIRECTORIES

# -----------------------------
# Download admins.txt file from Azure
# -----------------------------

ADMIN_FILE="/tmp/admins.txt"
echo "Downloading admins.txt file from Azure..."
az storage blob download --account-name "$AZURE_STORAGE_ACCOUNT" --container-name "$AZURE_CONTAINER_NAME" --name "admins.txt" --file "$ADMIN_FILE" --auth-mode login

if [ $? -ne 0 ]; then
  echo "Error: Failed to download admins.txt file."
  exit 1
fi
echo "admins.txt downloaded to $ADMIN_FILE"

# -----------------------------
# Create user accounts
# -----------------------------

echo "Processing admins.txt to create user accounts and add them to the wheel group..."
while IFS= read -r admin_user || [ -n "$admin_user" ]; do
  [[ -z "$admin_user" || "$admin_user" =~ ^# ]] && continue
  echo "Creating user account for: $admin_user"
  if id "$admin_user" &>/dev/null; then
    echo "User $admin_user already exists, skipping creation."
  else
    sudo useradd -m "$admin_user"
    echo "User $admin_user created."
  fi
  sudo usermod -aG wheel "$admin_user"
  echo "User $admin_user added to wheel group."
done < "$ADMIN_FILE"

# -----------------------------
# Create repository directory and assign ownership
# -----------------------------

echo -e "Creating repo directory and assigning ownership... \n"
mkdir -p "/bkdata/bak"
chown -R $repo_user:$repo_user "/bkdata/bak"
chmod 700 "/bkdata/bak"
echo -e "Repository directory setup complete.\n"

<<NETWORK
Firewall and Network Configuration
NETWORK

# -----------------------------
# Create firewall zone files
# -----------------------------

# Management zone file
MGMT_ZONE_FILE="/etc/firewalld/zones/management.xml"
echo "Creating management firewalld zone file at $MGMT_ZONE_FILE..."
sudo tee "$MGMT_ZONE_FILE" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<zone target="DROP">
  <short>Management</short>
  <description>Management Zone. All connections dropped unless defined.</description>
  <service name="ssh"/>
  <service name="cockpit"/>
  <service name="dell-ome"/>
  <service name="puppet-console"/>
  <service name="puppet-orchestrator"/>
  <source address="$management_ip"/>
</zone>
EOF

# Backup zone file
BACKUP_ZONE_FILE="/etc/firewalld/zones/backup.xml"
echo "Creating backup firewalld zone file at $BACKUP_ZONE_FILE..."
sudo tee "$BACKUP_ZONE_FILE" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<zone target="DROP">
  <short>Backup</short>
  <description>Backup data traffic zone. All connections dropped unless defined.</description>
  <service name="bak-transmission"/>
  <service name="bak-communication"/>
  <source address="$veeam_server_ip"/>
  <source address="$local_subnet"/>
</zone>
EOF

# Drop zone file
DROP_ZONE_FILE="/etc/firewalld/zones/drop.xml"
echo "Creating drop firewalld zone file at $DROP_ZONE_FILE..."
sudo tee "$DROP_ZONE_FILE" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<zone target="DROP">
  <short>Drop</short>
  <description>Unsolicited incoming network packets are dropped. Incoming packets related to outgoing connections are accepted. Outgoing connections are allowed.</description>
</zone>
EOF

# -----------------------------
# Create firewall service files
# -----------------------------

SERVICES_DIR="/etc/firewalld/services"

# bak-communication
SERVICE_FILE="${SERVICES_DIR}/bak-communication.xml"
echo "Creating service file for bak-communication at ${SERVICE_FILE}..."
sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>bak-communication</short>
  <description>Service for Veeam connect</description>
  <port protocol="tcp" port="6162"/>
</service>
EOF

# bak-transmission
SERVICE_FILE="${SERVICES_DIR}/bak-transmission.xml"
echo "Creating service file for bak-transmission at ${SERVICE_FILE}..."
sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>bak-transmission</short>
  <description>Service for Veeam transport</description>
  <port protocol="tcp" port="2500-3300"/>
</service>
EOF

# dell-ome
SERVICE_FILE="${SERVICES_DIR}/dell-ome.xml"
echo "Creating service file for dell-ome at ${SERVICE_FILE}..."
sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>dell-ome</short>
  <description>Service for Dell Open Manage</description>
  <port protocol="tcp" port="137"/>
  <port protocol="tcp" port="138"/>
  <port protocol="tcp" port="139"/>
  <port protocol="tcp" port="445"/>
  <port protocol="tcp" port="161"/>
  <port protocol="tcp" port="162"/>
  <port protocol="tcp" port="443"/>
  <port protocol="tcp" port="135"/>
</service>
EOF

# puppet-console
SERVICE_FILE="${SERVICES_DIR}/puppet-console.xml"
echo "Creating service file for puppet-console at ${SERVICE_FILE}..."
sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>puppet-console</short>
  <description>Service for Puppet console</description>
  <port protocol="tcp" port="8139"/>
  <port protocol="tcp" port="8140"/>
</service>
EOF

# puppet-orchestrator
SERVICE_FILE="${SERVICES_DIR}/puppet-orchestrator.xml"
echo "Creating service file for puppet-orchestrator at ${SERVICE_FILE}..."
sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>puppet-orchestrator</short>
  <description>Service for Puppet orchestrator</description>
  <port protocol="tcp" port="8142"/>
</service>
EOF

echo "Reloading firewalld to apply the new zones and service definitions..."
sudo firewall-cmd --reload

# -----------------------------
# Update Drop zone
# -----------------------------

echo -e "Listing active network connections: \n"
var_conlist=$(nmcli -g name connection show --active)
echo -e "$var_conlist\n"
IFS=$'\n'

echo -e "Processing connections... \n"
for item in $var_conlist; do
  nmcli con mod "$item" connection.zone drop
done
echo -e "Done processing connections.\n"

echo "The following interfaces have been moved into the drop zone:"
firewall-cmd --zone=drop --list-interfaces
echo -e "\n"

# -----------------------------
# Change the default firewall zone behavior to disallow zone drifting 
# -----------------------------

echo -e "Updating zone drifting directive and setting Drop as default zone \n"
mv -f "/tmp/etc/firewalld/firewalld.conf" "/etc/firewalld/firewalld.conf"
firewall-cmd --reload
systemctl restart firewalld
echo -e "Networking configuration complete \n"

<<RMM
Remote monitoring and management components 
RMM
# -----------------------------
# Install RMM prerequisites
# -----------------------------

echo -e "Installing Remote Monitoring & Management Prerequisites... \n"
dnf install -y net-snmp net-snmp-libs net-snmp-utils libcmpiCppImpl0.i686 libcmpiCppImpl0.x86_64 openwsman-server sblim-sfcb sblim-sfcc libwsman1.x86_64 libwsman1.i686 openwsman-client
echo -e "RMM prerequisites complete \n"

# -----------------------------
# Configure SNMP 
# -----------------------------

echo -e "Configuring SNMP... \n"
mv --force "/tmp/etc/snmp/snmpd.conf" "/etc/snmp/"
systemctl restart snmpd
echo -e "SNMP configuration complete \n"

# -----------------------------
# Install Crowdstrike 
# -----------------------------

echo -e "Installing CrowdStrike... \n"
dnf install "/tmp/crowdstrike/falcon-sensor-6.45.0-14203.el8.x86_64.rpm" -y
"/opt/CrowdStrike/falconctl" -s --cid="REDACTED"
systemctl start falcon-sensor
echo -e "CrowdStrike installation complete \n"

# -----------------------------
# Install Dell Open Manage 
# -----------------------------

echo -e "Installing Dell OpenManage Agent... \n"
tar xvzf "/tmp/omsa/OM-SrvAdmin-Dell-Web-LX-10.3.0.0-5081_A01.tar.gz" -C "/tmp/omsa/"
sh "/tmp/omsa/setup.sh" --agent --snmp --autostart
echo -e "Dell OpenManage installation complete \n"

# -----------------------------
# Install Puppet agent
# -----------------------------

echo -e "Installing Puppet agent... \n"
dnf install puppet-agent -y
systemctl enable puppet
systemctl start puppet
echo -e "Puppet agent installation complete \n"

<<MFA
Multi-Factor Authentication with DUO
MFA
# -----------------------------
# Make sure server is added to Veeam
# -----------------------------

echo -e "Veeam one-time passwords cannot navigate MFA \n It is imperative that you go to the Veeam console now \n and add this repo as a managed server before proceeding \n"
read -n 1 -r -s -p $'Press [Enter] when ready to continue with Duo install...\n'

# -----------------------------
# Proceeding with DUO install 
# -----------------------------

echo -e "Installing Duo prerequisites... \n"
dnf install openssl-devel pam-devel selinux-policy-devel bzip2 -y > /dev/null
echo -e "Duo prerequisites complete. \n"

echo -e "Setting repository for Duo... \n"
mv -f "/tmp/etc/yum.repos.d/duosecurity.repo" "/etc/yum.repos.d/"
rpm --import 'https://duo.com/DUO-GPG-PUBLIC-KEY.asc'

echo -e "Installing Duo... \n"
dnf install duo_unix -y > /dev/null
echo -e "Duo installation complete. \n"

echo -e "Updating Duo configuration files... \n"
mv -f "/tmp/etc/duo/pam_duo.conf" "/etc/duo/"
mv -f "/tmp/etc/pam.d/cockpit" "/etc/pam.d/"
mv -f "/tmp/etc/pam.d/sshd" "/etc/pam.d/"
mv -f "/tmp/etc/ssh/sshd_config" "/etc/ssh/"
echo -e "Duo configuration update complete. \n"

# -----------------------------
# Finalize server build
# -----------------------------

echo -e "All components have been installed or updated. Script complete. \n"
read -t 15 -r -s -p "Cockpit and SSH will restart in 15 seconds, or press [Enter] to restart immediately"
systemctl restart sshd
systemctl restart cockpit

