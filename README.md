# linux-repo-install-example.sh

This is an example of a Bash script I wrote to automate the provisioning of hardened Linux repositories for Veeam backups across a global enterprise environment.

At the time, we had no formal provisioning system for Linux bare metal. RHEL OS installation was handled manually using Kickstart, but all post-install configuration was being done by hand — which wasn’t scalable given the tight project timeline and the number of systems involved.

### 🛠️ What the Script Does

The script was designed to be run immediately after OS install, and it automates the following tasks:

- Pulls configuration files from the company Azure tenant
- Creates the repository user and imports admin account credentials
- Creates the backup data target directory for Veeam
- Applies network and firewall settings based on site location
- Installs and configures the remote monitoring and management agents
- Installs Duo MFA for SSH and Cockpit web UI access

The goal was to ensure every system was provisioned consistently, securely, and within the time constraints of the deployment window.

---

> 🔐 All sensitive data and organization-specific configuration has been removed or generalized in this example script.

---

### 📎 Use Case

This script is useful as a reference for:
- Building post-install automation where no config management tools exist
- Structuring a one-shot hardening and provisioning workflow
- Automating secure backup repository setups in distributed environments

---

### 📁 File

- `linux-repo-install-example.sh` – The example provisioning script with inline comments for clarity.

---

If you find this helpful or want to chat about infrastructure automation strategies, feel free to connect.

