# Release Notes

<a id="v1.0.3.1009"></a>
## 1.0.3.1009

### Release date: 2026-05-17

### Details
- Feature: Added module staleness check: `Start-VcfEdgeAtScale` now detects when the module on disk has been updated since the current PowerShell session imported it and warns the user to open a new window.
- Security: Windows-equivalent ACL restriction applied for harbor data files (current-user full control, all inherited ACEs stripped) via `System.Security.AccessControl` when running on Windows. The existing `chmod 600` path is unchanged for macOS/Linux. Both platforms now enforce owner-only read on the Harbor data values temp file.
- Security:  Environment variables `HARBOR_ADMIN_PASSWORD` and `SECRET_KEY` cleared from the process environment after every run (success or failure). Previously, credentials entered interactively via `Resolve-HarborSecretValue` persisted in the process environment for the entire session lifetime.
- Fix: Converted all remaining plain `throw "string"` sites in `Cluster.ps1`, `Networking.ps1`, and `Supervisor.ps1` (34 locations) to `throw [VcfDeploymentException]::new()` with a preceding `Write-LogMessage -Type ERROR` where not already present. This eliminates double-logging caused by outer generic `catch {}` blocks re-wrapping and re-logging the original message, and ensures all deployment failures route through the `catch [VcfDeploymentException]` handler for clean user-facing output.
- Fix: Resolved issue with VM detection safeguard during host-add.
- Fix: Resovled issue with vcf-cli detection edge-case impacting Log creation.
- Fix: Minor element positioning fixes for JSON generator UI.

---

<a id="v1.0.3.1008"></a>
## 1.0.3.1008

### Release date: 2026-05-15

### Details
- Checks for updates automatically daily, unless the feature is disabled. Provides manual update feature.
- Configurable vSphere HA admission policy for vSAN stretched clusters.
- Added support for vLCM images for clusters (using vCenter image catalog) (interactive or JSON).
- Added support for deploying multiple clusters in a single vCenter.
- Added support for defining multiple clusters in a single set of infrastructure/supervisor JSON files.
- Breaking change: update JSON structures to support multi-node and multi-edge deployments.
- Added Python-based UI alternative for authoring JSON infrastructure and supervisor JSON files
- Automatic Supervisor content catalog creation.
- Automatic Supervisor upgrade to latest version upon deployment.
- Show ArgoCD login information (URL and admin credentials) per edge location.
- Added support for Harbor registries per edge location.
- Clusters are configured for Retreat mode automatically (KB316514), removing the vCLS.
- vSAN ESA and OSA are now supported in a stretched cluster configuration.
- Automatic disk claim for vSAN.
- Emulate automatic disk claim for VMFS by selecting largest available disk.
- Witness validation and disk group / disk claim setup (as needed).
- Check if correct witness OVA is used for ESA vs OSA environment.
- vmk NIC validation and setup for data nodes and witness.
- Ensure configuration is in sync from vCenter to hosts before supervisor deployment.
- Ensure vSAN is not partitioned before supervisor deployment.
- Configure vSAN for auto-rebalance at 30%.
- Check to make sure ESA and OSA data nodes contribute approximately equal disks (WARN if they do not).
- User prompted for rollback if compute or supervisor rollback fails (supervisor failure will rollback only supervisor).
- Support for optional non-interactive authentication using environmental variables.
- ComputeOnly deployment option.
- vLCM image compliance check before supervisor workflow.
- Ability to disable ArgoCD or Harbor services (non-default).
- Updated ArgoCD version.

<a id="v1.0.0.2"></a>
## 1.0.0.2

- Fixes Windows compatibility issues with YAML parsing and handling kubectl/vcf commands on Windows.
- Improved error messages.

<a id="v1.0.0.1"></a>
## 1.0.0.1

- Initial Release
