# Recovery Bundle

This bundle captures the current two-node monitoring architecture:

- Docker host stack:
  - Wazuh single-node stack
  - Alertmanager
  - Wazuh alert forwarder
  - Prometheus
  - Blackbox exporter
- Ubuntu sensor VM:
  - Wazuh agent
  - Suricata
  - Cowrie
  - OpenCanary
  - Maltrail
  - mitmproxy

## Layout

- `backups/monitoring-host/<timestamp>/`
  - Immutable snapshot of the current Windows host project files used by the architecture.
  - Includes `docker-volumes/` with exported Wazuh Docker volumes from the running stack.
- `backups/sensor-vm/ubuntu-subash-192.168.1.6-<timestamp>.tgz`
  - Compressed Ubuntu VM snapshot containing the current service configs, custom app trees, Wazuh agent tree, and service units.
- `backups/metadata/<timestamp>/`
  - Service inventory, package list, ownership map, Docker state, resolved compose configs, volume manifest, and SHA256 checksums.
- `blueprints/monitoring-host/`
  - Deployable host-side source files.
- `scripts/`
  - Reusable backup, host deploy, and Ubuntu restore scripts.
- `config/offsite-backup.env.example`
  - Template for the automated off-host backup job.
- `config/hyperv-provision.env.example`
  - Template for one-click Hyper-V Ubuntu sensor VM provisioning.

## One-Click Use

### Windows Docker host

From this bundle:

```powershell
.\scripts\deploy-monitoring-host.ps1 -HostAddress 192.168.1.3 -TargetRoot D:\Monitoring
```

To restore the backed-up Wazuh Docker state on a clean host:

```powershell
.\scripts\deploy-monitoring-host.ps1 -HostAddress 192.168.1.3 -TargetRoot D:\Monitoring -BundleStamp 20260309-004828 -RestoreVolumeBackups
```

### Linux Docker host

```bash
chmod +x ./scripts/deploy-monitoring-host.sh
sudo ./scripts/deploy-monitoring-host.sh --host-address 192.168.1.3 --target-root /opt/monitoring
```

To restore the backed-up Wazuh Docker state on a clean Linux host:

```bash
sudo ./scripts/deploy-monitoring-host.sh --host-address 192.168.1.3 --target-root /opt/monitoring --bundle-stamp 20260309-004828 --restore-volume-backups
```

### Ubuntu sensor VM

Copy the VM archive and restore script to the Ubuntu VM, then run:

```bash
chmod +x restore-sensor-vm.sh
sudo ./restore-sensor-vm.sh --archive ./ubuntu-subash-192.168.1.6-<timestamp>.tgz --manager-ip 192.168.1.3
```

### Full Two-Node Redeploy From Windows

This deploys the Docker host locally and restores the Ubuntu sensor VM over SSH in one run:

```powershell
.\scripts\deploy-full-architecture.ps1 -HostAddress 192.168.1.3 -VmAddress 192.168.1.6 -VmUser subash -VmPassword <vm-password> -SudoPassword <sudo-password>
```

### Full Two-Node Redeploy On Hyper-V

This is the one-click path for a new Windows server with Hyper-V. It deploys the Docker monitoring host, downloads the official Ubuntu cloud image, creates the Ubuntu VM, attaches it to the detected external LAN switch, waits for DHCP, and restores the latest sensor snapshot automatically:

```powershell
.\scripts\deploy-full-architecture-hyperv.ps1 -TargetRoot D:\Monitoring
```

Hyper-V provisioning config:

- example: `config/hyperv-provision.env.example`
- local machine config: `config/hyperv-provision.env`

Standalone VM creation only:

```powershell
.\scripts\new-hyperv-sensor-vm.ps1 -ConfigPath .\config\hyperv-provision.env
```

## Automated Off-Host Backup

### 1. Create the backup config

Copy `config/offsite-backup.env.example` to `config/offsite-backup.env`, then fill in:

- `TARGET_TYPE=filesystem` and `TARGET_ROOT=\\server\share\path` for a NAS or network share
- or `TARGET_TYPE=rclone` and `TARGET_ROOT=<remote>:<path>` for cloud storage
- VM credentials using either `VM_SSH_PASSWORD` / `VM_SUDO_PASSWORD` or the matching `*_FILE` values

Current local-only setup on this machine:

- `TARGET_TYPE=filesystem`
- `TARGET_ROOT=D:\Monitoring\wazuh-docker-stack\single-node\recovery-bundle\offline-archive`
- production config file: `config/offsite-backup.env`

### 2. Run the job manually once

```powershell
.\scripts\run-offsite-backup.ps1 -ConfigPath .\config\offsite-backup.env
```

This will:

- create a fresh recovery bundle snapshot
- upload the current bundle blueprints, scripts, and snapshot to the off-host target
- prune local and remote snapshots using the configured retention counts
- write logs to `logs/offsite-backup/`

### 3. Install the Windows schedule

Interactive mode, no Windows password needed:

```powershell
.\scripts\install-offsite-backup-schedule.ps1 -ConfigPath .\config\offsite-backup.env -DailyAt 02:30
```

Unattended mode, runs even when you are logged out:

```powershell
.\scripts\install-offsite-backup-schedule.ps1 -ConfigPath .\config\offsite-backup.env -DailyAt 02:30 -RunWhenLoggedOut -UserName YOURPC\YourUser -PasswordFile D:\secure\windows-user-password.txt
```

## Notes

- The host deployment script patches `WAZUH_DASHBOARD_URL` to the host address you pass in.
- Restoring the exported `single-node_*` Docker volumes is opt-in with `-RestoreVolumeBackups` so the current live host is not modified accidentally.
- The VM restore script patches the Wazuh agent manager address in `/var/ossec/etc/ossec.conf` to the manager IP you pass in.
- The Ubuntu archive is intentionally focused on the monitoring stack's files, configs, app trees, and service units; it does not include transient logs, sockets, or unrelated workloads.
- The current stack-specific metadata is stored in `backups/metadata/<timestamp>/` to make rebuilding and auditing easier.
- Volume backups are live exports taken while containers remain running. They are intended for practical recovery and migration without interrupting your other projects.
- The off-host config file is intentionally kept outside the exported bundle snapshots so backup destination credentials are not copied into every recovery snapshot.

