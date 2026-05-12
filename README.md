# VcfEdgeAtScale — VCF Edge at Scale

[![PowerShell](https://img.shields.io/badge/PowerShell-7.4%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/License-Broadcom-green.svg)](LICENSE.md)
[![GitHub Clones](https://img.shields.io/badge/dynamic/json?color=success&label=Clone&query=count&url=https://gist.githubusercontent.com/nathanthaler/7c5ed25bb9cea6eef7f015be50e44a6f/raw/clone.json&logo=github)](https://gist.githubusercontent.com/nathanthaler/7c5ed25bb9cea6eef7f015be50e44a6f/raw/clone.json)
[![PS Version](https://img.shields.io/powershellgallery/v/VcfEdgeAtScale?label=Version)](https://www.powershellgallery.com/packages/VcfEdgeAtScale)
[![PS Downloads](https://img.shields.io/powershellgallery/dt/VcfEdgeAtScale?label=PS%20Gallery%20Downloads)](https://www.powershellgallery.com/packages/VcfEdgeAtScale)
[![Downloads](https://img.shields.io/github/downloads/vmware/powershell-module-for-vcf-edge-at-scale/total?label=Github%20Release%20Downloads)](https://github.com/vmware/powershell-module-for-vcf-edge-at-scale/releases)

## Overview

The VCF Edge at Scale PowerShell module provides streamlined deployment of VCF for edge sites, offering turnkey enablement of 1–2 node clusters with vSphere Supervisor and Supervisor services (Harbor and Argo CD).  Leveraging two simple JSON input files, `infrastructure.json` and `supervisor.json`, it provides a flexible, idempotent deployment mechanism to drive different, validated edge deployment topologies.  A Python-based JSON generator is provided to help create the JSON files needed to generate edge configurations with safeguards against configuration errors.

## Prerequisites

- **vCenter:** vCenter 9.0 with a virtual datacenter and at least one vLCM image present in the Image Catalog (per `infrastructure.json`).
- **Hosts:** ESX 9.0 installed: management and required data networks reachable.
- **Provisioning host:** Script execution system can route to vCenter, ESX, and proposed Supervisor management network.
- **PowerShell:** 7.4 or newer ([PowerShell](https://github.com/PowerShell/PowerShell)).
- **VCF PowerCLI:** `VCF.PowerCLI` on script execution system. [VCF.PowerCLI](https://developer.broadcom.com/powercli)
- **kubectl:** installed on script execution system [Kubernetes tools](https://kubernetes.io/docs/tasks/tools/).
- **VCF CLI:** installed on script execution system [Installing and using VCF CLI v9](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html).
- **Python** The JSON generation tool requires Python 3.9 or greater. [Python](https://www.python.org/downloads/)

## Step 1: Installation

<a id="install-psgallery"></a>

### Option 1: PowerShell Gallery

```text
Install-Module -Name VcfEdgeAtScale
```

<a id="install-github-clone"></a>

### Option 2: Clone from GitHub and install manually

```Powershell
# Open a PowerShell 7.4+ prompt (pwsh on macOS/Linux, PowerShell 7 on Windows)
git clone https://github.com/vmware/powershell-module-for-vcf-edge-at-scale.git
cd powershell-module-for-vcf-edge-at-scale/VcfEdgeAtScale
pwsh -ExecutionPolicy Bypass -File .\Install-VcfEdgeAtScaleModule.ps1
```

<a id="install-github-release"></a>

### Option 3: Download latest release from GitHub and install manually

```Powershell
$tempDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString()))
$fullPath = Join-Path -Path $tempDir -ChildPath "VcfEdgeAtScale.zip"
Invoke-WebRequest -Uri "https://github.com/vmware/powershell-module-for-vcf-edge-at-scale/releases/latest/download/VcfEdgeAtScale.zip" -OutFile $fullPath
Expand-Archive -Path $fullPath -DestinationPath $tempDir
cd $tempDir
pwsh -ExecutionPolicy Bypass -File .\Install-VcfEdgeAtScaleModule.ps1
```

> [!NOTE]
> **`-ExecutionPolicy Bypass`** is required on Windows when running a script downloaded from the internet. It is accepted but has no effect on macOS and Linux, so the same command works on all platforms. The installer also calls `Unblock-File` on all installed module files to remove the Windows "mark of the web" that would otherwise block `Import-Module` even after the script completes.

The installer prompts whether to add `Import-Module VcfEdgeAtScale` to your `$PROFILE` so the module loads automatically in every new PowerShell session. To skip the prompt, pass `-AddToProfile` to always add the line or `-SkipProfileUpdate` to never modify the profile.

## Step 2: Initialize Settings

The initialization function performs the following steps

- Establishes a base directory for the module's logs and configuration files based on user input.
- Copies templated JSON files into said base directory.
- Copies Service YAML files into a ServiceYaml subdirectory.
- Copies the JSON configuration generator tool (`veas-json-generator.py`) into place.
- Copies local help files into place (accessible through the module).
- Creates an environment variable for the base directory.
- Creates a logs directory for the module's debug logs.
- Establishes the `$env:VcfEdgeatScaleRootDirectory` variable pointing to the base directory.

```Powershell
Start-VcfEdgeAtScale -Initialize
```

> [!NOTE]
> **macOS / Linux:** After `-Initialize` completes, the variable is set for the current session and the line is automatically appended to your `$PROFILE` so new terminal sessions inherit it. No manual steps are required.

What `-Initialize` places on disk:

After **`Start-VcfEdgeAtScale -Initialize`** (or **`-Initialize -InitializeTemplatesOnly`**), the base directory contains:

- **`infrastructure.json`** / **`supervisor.json`** at the base (full init only, unless you decline replacement when they already exist)
- **`ServicesYaml/`** — `1.1.0-25100889.yml`, `argocd-deployment.yml`, `harbor-data-values-v2.14.2.yml`, `legacy-harbor-svs-v2.14.2+vmware.2-vks.1-25220498.yml`
- **`Docs/`** — `infrastructure-config-help.json`, `supervisor-config-help.json`, `README.rtf`, `EXAMPLE.rtf`
- **`Tools/`** — `veas-json-generator.py` + `veas-ui.html` — a stdlib-only Python 3 web UI for building and validating `infrastructure.json` and `supervisor.json` without hand-editing JSON
- **`Logs/`** — daily deployment logs once you run **`Start-VcfEdgeAtScale`** (not created by init alone beyond the empty folder)

## Step 3: Customize JSON files

The initialization function copies templated supervisor and infrastructure JSON files into place, but they must be customized for your specific edge site locations.

### Option 1: Guided generation

- Change to your VcfEdgeatScaleRootDirectory directory.
- Run `python3 Tools/veas-json-generator.py` — the server starts on `http://127.0.0.1:8080` and opens a browser tab automatically.
- To use a different port: `python3 Tools/veas-json-generator.py --port 8081`
- To suppress the automatic browser open (headless / SSH environments): add `--no-browser`
- Follow the on-screen instructions.

### Option 2: Modify JSON files by hand

- Open `$env:VcfEdgeatScaleRootDirectory/infrastructure.json` and `$env:VcfEdgeatScaleRootDirectory/supervisor.json` in the editor of your choice.
- Modify the files
- Run `Start-VcfEdgeAtScale -ValidateOnly` to validate your entries.

## Informational: Deployment Process (per edge site)

1. **Cluster creation and host addition**: Creates a new cluster in vCenter and adds the specified host(s) to the cluster. If a host is already managed by vCenter before it is added to the cluster, the module refuses to proceed while that host has **powered-on** VMs unless you confirm at a **Y/N** prompt (default **N**); it logs each running VM’s name, power state, and guest OS, and the vCenter server name.

2. Cluster configuration:
   - DRS set to Automatic
   - vLCM: image selection from the vCenter Image Catalog (by name from JSON or interactive prompt); cluster compliance check and remediation run before vSAN health checks (if applicable).

3. VDS and networking:
   - vSphere Distributed Switch (VDS) creation with required port groups (management, vMotion, vSAN, vSAN Witness as configured) and VMkernel interfaces. Management (vmk0) remains management-only; vMotion, vSAN, and vSAN Witness use dedicated VMkernel interfaces when configured. With **four physical NICs** (two VDS instances, `-sw1` and `-sw2`), **vSAN witness traffic stays on the first VDS** (`VDS-<edgesite>-sw1`): the dedicated witness VMkernel (vmk3) and its distributed port group are created there; vMotion and vSAN VMkernels remain on the second VDS (`VDS-<edgesite>-sw2`). With two NICs, all VMkernel port groups use the single VDS.
   - The management vmkernel interface will be automatically migrated from a standard vSwitch to a new vDS during the initialization process.
   - Physical NIC connectivity check before VDS creation; active/standby uplink teaming; MTU from config (default 9000 for vMotion/vSAN, 1500 for management and vSAN Witness).
   - The **vSAN Witness** VMkernel interface may be configured with an optional **`gateway`**.

4. **Storage**:
   - **VMFS**: When this storage type is selected, the largest, unformatted disk is automatically selected for as a VMFS datastore.
   - **vSAN OSA or vSAN ESA**: For vSAN enabled configurations, OSA or ESA, auto-disk claim is utilized.  Both vSAN variants storage types require a vSAN witness.  The witness can be defined at the common level or the edge site level.  If both are defined, the edge site takes priority.  Please take note: there are two different types of vSAN witness virtual appliances, one for ESA and one for OSA; the witness ESX version must also match the ESX host version.  Throughout vSAN health checks and vLCM gate checks are performed before a supervisor deployment may begin.

5. **vSphere Supervisor enablement**: Unless the edge site is deployed with the `-ComputeOnly` flag, a Supervisor is automatically deployed upon successful standup of the compute and networking stack.  After which, the PowerShell module will check if there are any pending supervisor updates available and apply them.  Unless Argo CD and/or Harbor are disabled, it will then proceed to deploy one or both of those services.

6. **Argo CD instance creation**: Argo CD instance created and configured. After deployment, it prints the URL and temporary admin password for immediate use.

7. **Harbor instance creation**: Harbor registry created and configured from a templated data file so many edge sites stay consistent and easier to maintain.  The code will also show a URL and login password post deployment.

## Informational: In-application help

```powershell
# View infrastructure.json configuration reference (auto-detects best format)
Show-InfrastructureJsonConfigurationHelp

# View supervisor.json configuration reference (auto-detects best format)
Show-SupervisorJsonConfigurationHelp

# Use list format for narrow screens
Show-InfrastructureJsonConfigurationHelp -Format List
Show-SupervisorJsonConfigurationHelp -Format List

# Use table format for wide screens (with separators for readability)
Show-InfrastructureJsonConfigurationHelp -Format Table
Show-SupervisorJsonConfigurationHelp -Format Table

# Use interactive grid view (Windows PowerShell only)
Show-InfrastructureJsonConfigurationHelp -Format GridView
Show-SupervisorJsonConfigurationHelp -Format GridView
```

## Step 4: Deployment

```Powershell
.\Start-VcfEdgeAtScale
```

**Deployment Parameters:**

- `AcceptBadCheckResults` (Switch, optional) - When specified, automatically proceed when vSAN cluster health is red or when vLCM cluster compliance remediation fails (no Y/N prompts).
  - **PSGallery install** (`Install-Module`): prompts to run `Update-Module` automatically if a newer version is available.
  - **Manual install** (git clone / `Install-VcfEdgeAtScaleModule.ps1`): announces the newer version and shows the `git pull` + re-run installer steps; no automatic install is attempted.
  - If PSGallery cannot be reached (network error, proxy, air-gap), the check is silently skipped — it is always non-fatal.
  - For silent once-per-day auto-checks see `common.autoUpdate` in the infrastructure JSON reference table below.
- `CleanUp` (String, optional) - Cleanup only; no deploy. Must be `Supervisor`, `Compute`, `All`, `ArgoCD`, or `Harbor`. **Supervisor** disables Supervisor only. **Compute** removes VDS, storage, and cluster (fails if Supervisor exists). **All** disables Supervisor then removes compute. **ArgoCD** removes only the Argo CD supervisor namespace (polls until gone). **Harbor** removes only the Harbor Supervisor Service (polls until gone). Confirm with a typed phrase such as `delete harbor for site1` unless `-Force` is used with `common.labenvironment` true (see module help for the exact pattern).
- `ComputeOnly` (Switch, optional) - Run all pre-supervisor steps (clusters, hosts, storage, VDS, vLCM) then exit without enabling the supervisor or deploying Argo CD.
- `EdgeSite` (String, optional) - Comma-delimited list of edge site names (e.g. `"site1,site2"`). Deploy only clusters whose `edgeSite` matches one of the values, in the order listed. Omit to deploy all clusters. Only comma is allowed as separator; invalid delimiters or unknown site names cause the workflow to fail.
- `Force` (Switch, optional) - When `common.labenvironment` is true in infrastructure JSON, bypasses the cleanup confirmation prompt when using `-CleanUp`. Has no effect otherwise; a warning is shown if used without lab.
- `InfrastructureJson` (String, optional) - Path to infrastructure configuration JSON file. When omitted (or null/empty), defaults to **`Join-Path $env:VcfEdgeatScaleRootDirectory 'infrastructure.json'`
- `LogLevel` (String, optional) - Minimum log level for console output. Valid values: `DEBUG`, `INFO`, `ADVISORY`, `WARNING`, `EXCEPTION`, `ERROR`. Default: `"INFO"`.
- `RollbackOnFailure` (Boolean, optional) - When `$true`: always rollback on failure (no prompt; for autonomous runs). When `$false`: never rollback; leave site in current state and continue to next site if any. When omitted: prompt (Y/N/Always). Rollback scope is automatic by failure state (see **Rollback behavior** below). **Operational guidance:** answer Y (or use `$true`) before you re-try after a failure so the site is torn back to a consistent state. Use `$false` or N only for intentional leave-as-is debugging; afterward run the appropriate `-CleanUp` for that scope and edge site (for example `-CleanUp Harbor -EdgeSite site1`) before another full deployment.
- `SaveHarborYaml` (Switch, optional) - When specified, the per-site Harbor data values YAML generated at runtime is moved to a `HarborYaml` subdirectory under the module directory instead of being deleted after installation. **Warning:** this file contains Harbor passwords and secrets in plain text. A `[WARNING]` is shown whenever this switch is used. Delete the file immediately after inspecting it.
- `SupervisorJson` (String, optional) - Path to supervisor configuration JSON file. When omitted (or null/empty), defaults to **`Join-Path $env:VcfEdgeatScaleRootDirectory 'supervisor.json'`**.

**Rollback behavior:** Scope follows where the run failed: compute or vSAN before Supervisor → full compute teardown; after compute but before Argo CD → Supervisor disabled only; Argo CD issues → namespace removed, Supervisor kept; Harbor issues → Harbor service removed only. `-RollbackOnFailure` sets prompt, always, or never.

**Re-trying after a failure:** Prefer rolling back first (interactive Y or A, or `-RollbackOnFailure $true`). Skipping rollback (`N` or `-RollbackOnFailure $false`) is for manual inspection only. After debugging, either re-run and choose rollback at the next failure prompt, or force a clean baseline with `-CleanUp` (same scopes as **Cleanup** above): for example `Start-VcfEdgeAtScale -CleanUp ArgoCD -EdgeSite site1` if only the Argo CD namespace should be removed, `-CleanUp Harbor` if only Harbor should be removed, `-CleanUp Supervisor` to disable the supervisor, `-CleanUp Compute` to remove compute (fails if the supervisor is still enabled), or `-CleanUp All` for supervisor then compute. Then fix your JSON or YAML and deploy again.

**Examples:**

```powershell
# Default edge deployment (All edge sites defined in JSON files)
Start-VcfEdgeAtScale

# Deployment with custom configuration files
Start-VcfEdgeAtScale `
    -InfrastructureJson "infrastructure-test.json" `
    -SupervisorJson "prod-supervisor-test.json"

# Deployment with DEBUG logging for troubleshooting
Start-VcfEdgeAtScale -LogLevel DEBUG

# Deploy only a specific edge site (targeted deployments or troubleshooting)
Start-VcfEdgeAtScale -EdgeSite "site1"

# Deploy multiple edge sites in order (comma-delimited; only comma is allowed as separator)
Start-VcfEdgeAtScale -EdgeSite "site1,site2"

# Deploy specific edge site(s) with custom configuration files
Start-VcfEdgeAtScale `
    -EdgeSite "site2" `
    -InfrastructureJson "infrastructure-test.json" `
    -SupervisorJson "supervisor-test.json"

# Autonomous run: always rollback on failure without prompting
Start-VcfEdgeAtScale -RollbackOnFailure $true

# Never rollback on failure; leave site in current state and continue to next site
Start-VcfEdgeAtScale -RollbackOnFailure $false

# Compute-only: prepare clusters, hosts, storage, VDS, and vLCM; exit without enabling supervisor
Start-VcfEdgeAtScale -ComputeOnly

# Cleanup supervisor only for site1 (compute remains); you must type "delete supervisor for site1" to confirm
Start-VcfEdgeAtScale -CleanUp Supervisor -EdgeSite "site1"

# Cleanup Argo CD namespace only for site1 (supervisor and compute remain); confirm with "delete argocd for site1"
Start-VcfEdgeAtScale -CleanUp ArgoCD -EdgeSite "site1"

# Cleanup Harbor Supervisor Service only for site1 (supervisor, Argo CD, and compute remain); confirm with "delete harbor for site1"
Start-VcfEdgeAtScale -CleanUp Harbor -EdgeSite "site1"

# Cleanup compute only for site1 (fails if supervisor is deployed); confirm with "delete compute for site1"
Start-VcfEdgeAtScale -CleanUp Compute -EdgeSite "site1"

# Cleanup all (supervisor then compute) for all sites; confirm per site with "delete all for <edgeSite>"
Start-VcfEdgeAtScale -CleanUp All

# Cleanup all with -Force when common.labenvironment is true in infrastructure.json (bypasses confirmation)
Start-VcfEdgeAtScale -CleanUp All -Force

# Accept bad vSAN health or vLCM compliance (proceed without Y/N prompts)
Start-VcfEdgeAtScale -AcceptBadCheckResults

# Validate JSON and YAML only (no deployment) using files under VcfEdgeatScaleRootDirectory
Start-VcfEdgeAtScale -ValidateOnly

# Or validate explicit paths (VcfEdgeatScaleRootDirectory must still be set; these paths override the default JSON filenames only)
Start-VcfEdgeAtScale -ValidateOnly -InfrastructureJson "infrastructure-test.json" -SupervisorJson "supervisor-test.json"
```

### Informational: Operational modes

Most commands may be issued through **`Start-VcfEdgeAtScale`**

- **Deployment** (`-EdgeSite`) : Specify one or more EdgeSites
- **Validate only** (`-ValidateOnly`): JSON checks (including network segments) and YAML path checks only; no vCenter session and no deployment.
- **Compute only** (`-ComputeOnly`): Cluster, hosts, storage, VDS, and vLCM through remediation; stops before Supervisor, Argo CD, and Harbor. JSON/YAML validation is limited to compute paths (supervisor.json, Argo/Harbor YAML, and `common.contextName` are not required).
- **Cleanup** (`-CleanUp`): Removes the chosen scope without deploying. Values: `Supervisor`, `Compute`, `All`, `ArgoCD`, `Harbor`.
  - **Supervisor:** Disable Supervisor; compute stays.
  - **Compute:** Remove VDS, storage, and cluster; fails if Supervisor is still enabled.
  - **All:** Disable Supervisor, then remove compute.
  - **ArgoCD:** Remove the Argo CD supervisor namespace for that cluster; script waits until it is gone.
  - **Harbor:** Remove the Harbor Supervisor Service from the supervisor; script waits until it is gone.
  - Typed confirmation is required unless `-Force` is used with `common.labenvironment` true (for example `delete harbor for site1`; use your cleanup scope and edge site name).
- **Rollback on failure:** Rollback follows the failure point (compute, Supervisor, Argo CD namespace, or Harbor service). `-RollbackOnFailure` selects always, never, or prompt (Y/N/Always). For a normal fix-and-retry workflow, choose rollback (Y, A, or `-RollbackOnFailure $true`) before you change configuration and run again. Use N or `-RollbackOnFailure $false` only when you deliberately keep a partial deployment open for hands-on debugging; when you are finished, run the matching `-CleanUp` scope (see **Cleanup** above) for that edge site so the next run does not stack on a broken half-state.

### Collect logs

If you run into a problem and need to share a log bundle with Broadcom, please run the following:

```Powershell
Start-VcfEdgeAtScale -CollectLogs
```

The module will create an archive containing your infrastructure.json, supervisor.json, logs from the `$env:VcfEdgeatScaleRootDirectory`/log directory, and the `$env:VcfEdgeatScaleRootDirectory`/VcfEdgeBaseDir directory.

## Check module version

```Powershell
Start-VcfEdgeAtScale -Version
```

## Check for new releases

> [!NOTE]
> The module automatically checks for new versions once per day when used. The behaviour differs by install source:
>
> - **PSGallery install** (`Install-Module`): when a newer version is available, you are prompted to run `Update-Module` automatically (default Y). After a successful update both `veas-json-generator.py` and `veas-ui.html` are synced to your deployment root if their versions differ.
> - **Manual / GitHub install** (git clone + `Install-VcfEdgeAtScaleModule.ps1`): announces the newer version and shows the manual update steps (`git pull` + re-run installer); no automatic install is attempted.
> - If PSGallery cannot be reached (network error, proxy, air-gap), the check is silently skipped — it is always non-fatal.
> - Disable automatic daily checks by setting `"autoUpdate": false` in `common` of your `infrastructure.json`.

```Powershell
Start-VcfEdgeAtScale -CheckForUpdates
```

**EdgeSite Parameter Usage:**

The `-EdgeSite` parameter lets you target one or more edge sites from your infrastructure.json instead of processing all clusters. Use a comma-delimited list to deploy multiple sites (e.g. `-EdgeSite "site1,site2"`). This is useful for the following:

- **Targeted deployments**: Deploy or redeploy specific edge sites without processing others
- **Troubleshooting**: Isolate issues to specific clusters
- **Incremental rollouts**: Deploy a subset of sites in a chosen order
- **Testing**: Validate configuration for selected sites before deploying all

**How it works:**

- When `-EdgeSite` is **not specified**: All clusters in the `clusters[]` array are processed sequentially. The script connects to vCenter once and processes each cluster in order, maintaining the connection between clusters that share the same vCenter FQDN.
- When `-EdgeSite` **is specified**: Only clusters whose `edgeSite` matches one of the comma-separated values are processed, in the order you list them (e.g. `-EdgeSite "site2,site1"` deploys site2 then site1).

**Important Notes:**

- Use **only a comma** to separate site names. Invalid delimiters (e.g. semicolon) cause the workflow to fail.
- Each value must exactly match an `edgeSite` in your infrastructure.json `clusters[]` array. If any specified site is invalid, the workflow fails with the list of valid values.
- All clusters in the same infrastructure.json share the same vCenter connection (from `common.vCenterName`), so the connection persists when processing multiple clusters.

### Show-InfrastructureJsonConfigurationHelp

Displays a reference table for configuring the `infrastructure.json` file (Key, Required, Notes).

**Parameters:**

- `Format` (String, optional) - Output format. Valid values: `Auto` (default), `List`, `Table`, `GridView`. Default: `Auto`
- `Filter` (String, optional) - Filters configuration elements by Element Name using wildcard matching. The filter is automatically wrapped with wildcards (*) on both sides.

**Examples:**

```powershell
# Display infrastructure.json configuration reference (auto-detects best format)
Show-InfrastructureJsonConfigurationHelp

# Use list format for narrow screens
Show-InfrastructureJsonConfigurationHelp -Format List

# Use table format for wide screens (with separators)
Show-InfrastructureJsonConfigurationHelp -Format Table

# Use interactive grid view (Windows PowerShell only)
Show-InfrastructureJsonConfigurationHelp -Format GridView

# Filter to show only argoCD related elements
Show-InfrastructureJsonConfigurationHelp -Filter argoCD

# Combine filter with format
Show-InfrastructureJsonConfigurationHelp -Filter storagePolicy -Format List
```

**Format Options:**

- **Auto**: Automatically selects the best format based on terminal width
- **List**: Vertical layout, ideal for narrow screens (40-50+ characters)
- **Table**: Table format with horizontal separators, ideal for wide screens (120+ characters)
- **GridView**: Interactive window with sorting/filtering (Windows PowerShell only)

The output includes detailed information about:

- vCenter and ESX host configuration
- Cluster and datacenter settings
- Storage policy and datastore configuration
- Virtual Distributed Switch (VDS) settings
- Port group and network configuration
- Argo CD operator and deployment settings

### Show-SupervisorJsonConfigurationHelp

Displays a reference table for configuring the `supervisor.json` file (Key, Required, Notes).

**Parameters:**

- `Format` (String, optional) - Output format. Valid values: `Auto` (default), `List`, `Table`, `GridView`. Default: `Auto`
- `Filter` (String, optional) - Filters configuration elements by Element Name using wildcard matching. The filter is automatically wrapped with wildcards (*) on both sides.

**Examples:**

```powershell
# Display supervisor.json configuration reference (auto-detects best format)
Show-SupervisorJsonConfigurationHelp

# Use list format for narrow screens
Show-SupervisorJsonConfigurationHelp -Format List

# Use table format for wide screens (with separators)
Show-SupervisorJsonConfigurationHelp -Format Table

# Use interactive grid view (Windows PowerShell only)
Show-SupervisorJsonConfigurationHelp -Format GridView

# Filter to show only supervisor site elements
Show-SupervisorJsonConfigurationHelp -Filter siteSpec

# Filter for load balancer elements
Show-SupervisorJsonConfigurationHelp -Filter flb -Format List
```

**Format Options:**

- **Auto**: Automatically selects the best format based on terminal width
- **List**: Vertical layout, ideal for narrow screens (40-50+ characters)
- **Table**: Table format with horizontal separators, ideal for wide screens (120+ characters)
- **GridView**: Interactive window with sorting/filtering (Windows PowerShell only)

The output includes detailed information about:

- Supervisor control plane configuration (VM count, size)
- Foundation Load Balancer settings (name, size, availability)
- Network IP ranges and assignments
- DNS, NTP, and search domain configuration
- VKS management and workload network settings

## Configuration Files

Deployment is driven by two JSON inputs: `infrastructure.json` (vCenter, clusters, networking, storage, Argo CD paths) and `supervisor.json` (supervisor sizing, load balancer, and network IP ranges). Each `edgeSite` in `infrastructure.json` `clusters[]` must have a matching `edgeSite` in `supervisor.json` `siteSpec[]`.

### infrastructure.json

This file defines vCenter connection, datacenter, and shared naming prefixes; then one or more clusters, each with ESX hosts, storage type, networking segments, and Argo CD paths. Many fields are **optional** and have defaults so you can omit them for a minimal config.

**Structure:**

- **`common`** – Settings used for all clusters (one vCenter, one datacenter, shared prefixes and content library). Prefixes and `esxUser` are optional; when omitted, defaults apply (see tables below).
- **`clusters`** – Array of cluster objects. Each cluster is identified by `edgeSite` (must match a site in `supervisor.json`). Per-cluster you define ESX hosts, storage type, and network segments. **`supervisorServices`** file names, **`parentDirectory`**, or legacy **`*YamlPath`** keys may be defined here to override the common defaults.

**Important behavior:**

- **Uplinks:** There is no `numUplinks` field. The number of VDS uplinks is taken from the length of `nicList` (e.g. two NICs in `nicList` means two uplinks). **nicList** may be defined at **common** (applies to all clusters) or per **clusters[]** (cluster overrides common). At least one definition is mandatory: either `common.nicList` or `clusters[].nicList` for each cluster. When both are defined, the cluster value takes precedence. Effective list must have 2 or 4 NICs.
- **Storage:** Use `storagePolicy.storageType` (`VMFS`, `vSAN-ESA`, or `vSAN-OSA`). The tag catalog name can be omitted; it defaults to `{storageType}-Storage-TagCatalog` (e.g. `VMFS-Storage-TagCatalog`).
- **vSAN witness:** `vSanWitnessVmName` may be defined at `common` (applies to all vSAN clusters) or per `clusters[]` (cluster root level only; cluster overrides common). Required for vSAN-OSA and vSAN-ESA storage types; not used for VMFS.
- **vSphere HA admission (vSAN OSA/ESA only):** `haPolicy` may be defined at `common` or per `clusters[]` (cluster overrides common). Omitted means **`reservationBased`** (CPU and memory percentage admission; default percentage is ceiling(100 / host count) unless overridden). **`slotBased`** uses host failures tolerated = 1 (slot-style admission). **`disabled`** leaves HA on with admission control off (VM restart only, no capacity reservation). These values apply when the workflow re-applies HA after moving management to the VDS and when the vSAN alarm check remediates **vSphere HA host status**. **VMFS** clusters are not governed by this JSON key; HA re-apply after the VDS step continues to use **reservationBased**. When the key is present, JSON validation accepts only the three strings above.
- **vSAN Health — Stats Primary election:** The module **does not** add Stats Primary to the vSAN **silent-check** list (no `VsanHealthSetVsanClusterSilentChecks` for that test). When the post-witness health summary is non-green **only** for Stats Primary election/selection (including common `perfsvc.masterexist` / label variants on older builds), it **re-triggers** evaluation: ensures the vSAN performance service is enabled, runs **`Test-VsanClusterHealth`** when the cmdlet exists (with **`VMCreateTimeoutSeconds`** when supported—default 120), waits between attempts, and re-reads health up to **four** times (45 s between attempts by default). If it still only shows that finding, deployment **proceeds with a warning** so a transient leader election does not block the gate. `common.labenvironment: true` still applies **separate** lab-only silent checks for other tests. After a successful vSAN edge deployment, **`Test-VsanClusterHealth`** runs again when available. Manual remediation remains per [Broadcom KB 401679](https://knowledge.broadcom.com/external/article/401679/stats-primary-election-alert-via-vsan-he.html). The module does not SSH to ESX to restart services automatically.
- **Lab environment and the vSAN HCL (important):** When **`common.labenvironment`** is **`true`**, `Set-VsanLabSilentChecksIfRequested` silences these vSAN Health checks before the post-witness evaluation: **`advcfgsync`**, **`controllerdiskmode`**, **`controlleronhcl`**, **`controllerfirmware`**, **`controllerdriver`**, **`hclhostbadstate`**. Only `advcfgsync` is a transient-sync test; the other five map to vSAN HCL / hardware-compatibility findings (storage controller on HCL, controller disk mode, firmware, driver, and host HCL DB state). Silencing changes only the vCenter **signal layer** (health test status and the cluster alarms derived from it); it does **not** change the underlying hardware state. Two consequences you should plan for:
  - The same cluster may deploy cleanly in lab mode and **fail to enable Supervisor outside lab mode on identical hardware**, because WCP enforces cluster/host HCL conformance downstream of this module's red-alarm gate. Accepting the red vSAN alarm in non-lab mode does not fix the HCL state.
  - `Invoke-VsanClusterAlarmCheckAndRemediate` classifies each blocking red alarm with **`Test-VsanTriggeredAlarmIsHclRelated`** (matches **HCL**, **hardware compatibility**, **hardware vSAN support**, and **controller firmware/driver/disk mode/on HCL**). When any blocking red alarm is HCL-related, the **ERROR/WARNING** banner, **`AcceptBadCheckResults`** message, **Y/N** prompt, and the `Y`-accepted log line all explicitly state that Supervisor enablement is expected to fail until the cluster is HCL-conformant.
  - For production-equivalent edge deployments use **HCL-listed** storage controllers, firmware revisions, and drivers, and keep **`common.labenvironment`** set to **`false`**. Use **`true`** only for nested/demo environments where HCL conformance is known not to hold and Supervisor enablement is expected to work only because WCP's nested-host path tolerates those signals; do not rely on a successful lab-mode run to predict non-lab-mode behavior.
- **Supervisor service YAML files:** Preferred: under `supervisorServices`, set **`parentDirectory`** (folder containing the YAML files) and **`argoCdOperatorYamlFileName`**, **`argoCdDeploymentYamlFileName`**, **`harborDataTemplateYamlFileName`**, and **`harborServiceYamlFileName`** (file names only). Define these at `common` and/or override per `clusters[].supervisorServices` (cluster wins per key). If a cluster omits a file name, the common value is used when resolving the combined path. **Legacy:** omit **`parentDirectory`** (and rely on **`\*YamlPath`** instead) by setting **`argoCdOperatorYamlPath`**, **`argoCdDeploymentYamlPath`**, **`harborDataTemplateYamlPath`**, and **`harborServiceYamlPath`** to full or JSON-relative paths at `common` and/or per cluster (cluster overrides common per key). When `disableArgoCD` is true, Argo paths are not required. When `disableHarbor` is true, Harbor YAML paths are not required. `supervisorServices.nameSpacePrefix` defaults to `argocd` if omitted. `supervisorServices.vmClass` is optional; when omitted, the script assigns all VM classes reported by vCenter to the ArgoCD namespace.
- **Disabling supervisor services:** Set `supervisorServices.disableArgoCD: true` or `supervisorServices.disableHarbor: true` at `common` (affects all clusters) or per `clusters[]` (overrides common for that cluster only). Both default to `false` (enabled). When `disableArgoCD` is true, the Argo CD service, namespace, operator, and instance steps are all skipped and Argo file names do not need to be configured. When `disableHarbor` is true, Harbor service registration, data values generation, and installation are all skipped; `harborConfiguration` is not required and Harbor YAML file names do not need to be configured. **Service flags also affect the LB virtual server network IP minimum** (see `flbVirtualServerNetwork.flbNetworkIpAddressCount` in the supervisor.json reference): Harbor enabled requires at least 50 IPs; Argo CD only requires at least 20; neither requires at least 10.
- **Harbor configuration:** Each cluster needs a `harborConfiguration` block unless `disableHarbor` is true.
  - **Hostname:** `harborConfiguration.hostname` is required (FQDN or IP that DNS accepts) unless **`common.labenvironment`** is **`true`**, Harbor is enabled, and **`tlsCrt`** / **`tlsKey`** are **both omitted**—then the hostname is read from the top-level `hostname:` line in the Harbor data values template (**`harborDataTemplateYamlFileName`** / **`harborDataTemplateYamlPath`**). You may still set **`hostname`** in JSON to override the template.
  - **Volume sizes:** Optional `registryVolumeSize`, `jobserviceVolumeSize`, `databaseVolumeSize`, `redisVolumeSize`, `trivyVolumeSize` use `<positive integer>Gi` (for example `10Gi`).
  - **Secrets:** Optional keys map into the Harbor data values YAML. Prefix with `$env:VAR` to load at runtime so secrets stay out of JSON.
  - **Prompts:** If `$env:` is used and the variable is unset, the script asks once during pre-flight (masked input) and caches the value for the process. Plain text in JSON is never prompted for.
  - **TLS:** **`tlsCrt`** and **`tlsKey`** must be defined **together** or **both omitted**; defining only one is an error. When using your own PEMs, either set **`harborConfiguration.parentDirectory`** and use **`tlsCrt`** / **`tlsKey`** as **file names** under that directory (both required together), with optional **`caCrt`** as a file name when both TLS files are set, **or** omit **`parentDirectory`** and set **`tlsCrt`**, **`tlsKey`**, and optional **`caCrt`** to full or infrastructure-relative PEM paths (legacy). Paths are validated before deploy. When **`common.labenvironment`** is **`true`** and **both** **`tlsCrt`** and **`tlsKey`** are omitted, the module generates a **self-signed** RSA certificate (via .NET, works on Windows and macOS/Linux), injects it into the Harbor data values YAML, and uses the same PEM for Supervisor container-registry trust; post-install **Harbor connection details** note that TLS is self-signed for lab. Set **`common.preserveAutoGeneratedKeyCertPair`** to **`true`** to save the generated key and certificate to **`$env:VcfEdgeatScaleRootDirectory/HarborKeyCerts/<edgeSite>/`** (as **`<edgeSite>.key`** / **`<edgeSite>.crt`**) after a successful deployment; on non-Windows the private key is restricted to owner-read-only (`chmod 0600`). This has no effect when `tlsCrt`/`tlsKey` are supplied or when `labenvironment` is `false`.
  - **Service YAML:** Download the Harbor Supervisor Service Carvel package from Broadcom; set **`harborServiceYamlFileName`** (with **`parentDirectory`**) under `supervisorServices`, or use legacy **`harborServiceYamlPath`** / **`harborDataTemplateYamlPath`**.
  - **Order and rollback:** Harbor installs after Argo CD. Failure rolls back Harbor only so you can fix and re-run. `-CleanUp Harbor` removes Harbor without touching Supervisor or Argo CD.
- **Network segment names** must be lower-case and RFC1123-compliant; they are matched to supervisor.json network references (case-sensitive).

**Required vs optional:** In the tables below, **Req** reflects whether you typically must supply a value for your environment. **`Start-VcfEdgeAtScale -ValidateOnly`** (shallow validation) still requires certain **keys to exist** in JSON even when defaults apply — for the authoritative **Key / Required / Notes** list (aligned with **`Templates/*-config-help.json`**), run **`Show-InfrastructureJsonConfigurationHelp`** / **`Show-SupervisorJsonConfigurationHelp`** or open the copies under **`Docs/`** after **`-Initialize`**.

#### common

| Field | Req | Notes |
| ----- | --- | ----- |
| `vCenterName` | Yes | vCenter FQDN, 9.0 or later. Script needs HTTPS access. |
| `vCenterUser` | Yes | vCenter login (SSO supported); example UPN `administrator@vsphere.local`. |
| `vSanWitnessVmName` | No | vSAN witness VM name or FQDN; used by vSAN-OSA/ESA. |
| `haPolicy` | No | vSAN-OSA/ESA multi-host HA admission: `reservationBased` (default when omitted), `slotBased`, or `disabled`. Validated when the key exists. |
| `esxUser` | No | ESX login. Omit to use default `root`. |
| `esxUniquePasswordPerHost` | No | Boolean. Default false when not defined (one password for all hosts). true = prompt per host. |
| `nonInteractivePassword` | No | Boolean. When true, uses VCENTER_COMMON_PASSWORD / ESX_COMMON_PASSWORD env vars. |
| `autoUpdate` | No | Boolean. Default: omitted (auto-check enabled). When `false`, disables the once-per-day automatic PSGallery version check. The auto-check runs regardless of install source — PSGallery installs are offered `Update-Module`; manually installed copies are shown `git pull` + re-run installer steps. All PSGallery failures are non-fatal. Use `Start-VcfEdgeAtScale -CheckForUpdates` to check manually at any time. |
| `labenvironment` | No | Boolean lab mode. JSON property name is case-insensitive; **`labenvironment`** matches **`Templates/infrastructure.json`** and **`Docs/infrastructure-config-help.json`**. Default `false`. When `true`, silences the vSAN HCL / hardware-compatibility health checks (`controlleronhcl`, `controllerdiskmode`, `controllerfirmware`, `controllerdriver`, `hclhostbadstate`) plus transient `advcfgsync`, and lab-filters the third-party IO filter alarm. This masks the red vSAN alarm signal but does **not** change the underlying hardware state; Supervisor enablement (WCP) still enforces cluster/host HCL conformance downstream, so a cluster that deploys cleanly in lab mode may fail to enable Supervisor outside lab mode on identical hardware. Also permits `-Force` to bypass cleanup confirmation and allows Harbor self-signed TLS when `tlsCrt`/`tlsKey` are both omitted. Keep `false` for production-equivalent deployments; use `true` only for nested / demo environments. See the **Lab environment and the vSAN HCL** bullet above. |
| `preserveAutoGeneratedKeyCertPair` | No | Boolean. Only meaningful when `labenvironment` is `true` and Harbor TLS is auto-generated (`tlsCrt` and `tlsKey` both omitted). When `true`, saves the generated private key as `<edgeSite>.key` and certificate as `<edgeSite>.crt` to **`$env:VcfEdgeatScaleRootDirectory/HarborKeyCerts/<edgeSite>/`** after a successful deployment. On non-Windows, the private key is restricted to owner-read-only (`chmod 0600`). Ignored if `labenvironment` is `false` or `tlsCrt`/`tlsKey` are supplied. Default `false` when absent. |
| `datacenterName` | Yes | Existing vSphere datacenter; clusters are created under it. |
| `clusterNamePrefix` | No | Prefix for cluster names. Omit for default `cluster`; format `{prefix}-{edgeSite}`. |
| `datastoreNamePrefix` | No | Prefix for datastore names. Omit for default `datastore`; format `{prefix}-{edgeSite}`. |
| `supervisorNamePrefix` | No | Prefix for supervisor names. Omit for default `supervisor`; format `{prefix}-{edgeSite}`. |
| `vdsNamePrefix` | No | Prefix for VDS names. Omit for default `VDS`; format `{prefix}-{edgeSite}`. |
| `supervisorContentLibraryDatastore` | No | When the key is present, datastore for supervisor content library (must already exist); script runs Initialize-SupervisorContentLibrary. When the key is omitted (removed) entirely, the content library workflow is skipped. |
| `supervisorContentLibrarySubscriptionUrl` | No | When `supervisorContentLibraryDatastore` key is present, subscription URL for the content library. If this key is omitted, the default is the [VMware supervisor content library](https://wp-content.vmware.com/supervisor/v1/latest/lib.json) subscription URL. Only used when datastore key is present. |
| `vLcmImageName` | No | vLCM image name in vCenter Image Catalog; omit to choose at run time. |
| `vSanvMotionVmKernelMtuValue` | No | Optional. When defined, overrides the default MTU (9000) for the VDS and for vMotion/vSAN VMkernel adapters only. Mgmt (vmk0) and vSAN Witness (vmk3) are always 1500. Must be a number between 1500 and 9190 (numbers only; validated at JSON load). Use 1500 when the physical path does not support jumbo frames. |
| `nicList` | Conditional | Array of NICs for the VDS (e.g. `[{"name":"vmnic1"},{"name":"vmnic2"}]`). Number of uplinks = length of nicList. Required at common or per cluster; cluster overrides common. Must have 2 or 4 NICs. |
| `supervisorServices.parentDirectory` | Conditional | Directory for Argo CD and Harbor YAML files when using `*YamlFileName` keys (escape backslashes on Windows). Not required if every Argo- or Harbor-enabled cluster resolves paths via legacy `*YamlPath` properties at common or cluster level. |
| `supervisorServices.argoCdOperatorYamlFileName` | Conditional | File name under `parentDirectory` for the Argo CD operator package. Use with `parentDirectory`, or use `supervisorServices.argoCdOperatorYamlPath` instead. Ignored when `disableArgoCD` is true. |
| `supervisorServices.argoCdDeploymentYamlFileName` | Conditional | File name under `parentDirectory` for the Argo CD instance YAML; namespace in file must match `nameSpacePrefix`. Use with `parentDirectory`, or use `supervisorServices.argoCdDeploymentYamlPath` instead. Ignored when `disableArgoCD` is true. |
| `supervisorServices.argoCdOperatorYamlPath` | Conditional | Legacy full path to the Argo CD operator package YAML. Used when `parentDirectory` + `argoCdOperatorYamlFileName` do not both resolve. Ignored when `disableArgoCD` is true. |
| `supervisorServices.argoCdDeploymentYamlPath` | Conditional | Legacy full path to the Argo CD instance YAML. Used when `parentDirectory` + `argoCdDeploymentYamlFileName` do not both resolve. Ignored when `disableArgoCD` is true. |
| `supervisorServices.disableArgoCD` | No | Boolean. When true, skips Argo CD deployment (service, namespace, operator, instance) for all clusters. Cluster-level override wins. Default: false. |
| `supervisorServices.disableHarbor` | No | Boolean. When true, skips Harbor deployment (service registration, data values generation, installation) for all clusters. Cluster-level override wins. Default: false. |
| `supervisorServices.harborDataTemplateYamlFileName` | Conditional | File name under `parentDirectory` for the Harbor data values template (e.g. `harbor-data-values-v2.14.2.yml`). The script mutates a per-site copy at runtime. Use with `parentDirectory`, or use `supervisorServices.harborDataTemplateYamlPath` instead. Not required when `disableHarbor` is true for all clusters. |
| `supervisorServices.harborServiceYamlFileName` | Conditional | File name under `parentDirectory` for the Harbor Carvel package YAML. Use with `parentDirectory`, or use `supervisorServices.harborServiceYamlPath` instead. Not required when `disableHarbor` is true for all clusters. |
| `supervisorServices.harborDataTemplateYamlPath` | Conditional | Legacy full path to the Harbor data values template YAML. Used when `parentDirectory` + `harborDataTemplateYamlFileName` do not both resolve. Not required when `disableHarbor` is true for all clusters. |
| `supervisorServices.harborServiceYamlPath` | Conditional | Legacy full path to the Harbor Supervisor Service Carvel package YAML. Used when `parentDirectory` + `harborServiceYamlFileName` do not both resolve. Not required when `disableHarbor` is true for all clusters. |
| `contextName` | Yes | VCF context name used by VCF CLI for Argo CD. |

#### clusters[] (each element)

| Field | Req | Notes |
| ----- | --- | ----- |
| `edgeSite` | Yes | Unique site ID; must match one `siteSpec[].edgeSite` in supervisor.json. |
| `nicList` | Conditional | Optional override for this cluster. When present (2 or 4 NICs), overrides `common.nicList`. At least one of `common.nicList` or `clusters[].nicList` must be defined per cluster. |
| `esxHosts` | Yes | Array of ESX FQDNs or IPs; script needs HTTPS access to each host. |
| `networking` | Yes | Object containing `networkSegments` and, for vSAN clusters, `networkingVmKernelInterfaces`. Required by shallow validation. |
| `storagePolicy` | Yes | Object containing `storageType` and optional tag catalog. Required by shallow validation. |
| `vSanWitnessVmName` | Conditional | vSAN witness VM name or FQDN for this cluster. Overrides `common.vSanWitnessVmName`. Required (at cluster or common level) for vSAN-OSA and vSAN-ESA; not used for VMFS. |
| `haPolicy` | No | Overrides `common.haPolicy` for this cluster when set. Same values and vSAN-only behavior as `common.haPolicy`. |
| `supervisorServices.parentDirectory` | No | Overrides `common.supervisorServices.parentDirectory` for this cluster when set. |
| `supervisorServices.argoCdOperatorYamlFileName` | Conditional | Overrides common file name for this cluster when defined. Ignored when `disableArgoCD` is true. |
| `supervisorServices.argoCdDeploymentYamlFileName` | Conditional | Overrides common file name for this cluster when defined. Ignored when `disableArgoCD` is true. |
| `supervisorServices.argoCdOperatorYamlPath` | Conditional | Per-cluster legacy path to the Argo CD operator YAML; overrides common when set. Ignored when `disableArgoCD` is true. |
| `supervisorServices.argoCdDeploymentYamlPath` | Conditional | Per-cluster legacy path to the Argo CD instance YAML; overrides common when set. Ignored when `disableArgoCD` is true. |
| `supervisorServices.harborDataTemplateYamlFileName` | Conditional | Overrides common Harbor data template file name when defined. Ignored when `disableHarbor` is true. |
| `supervisorServices.harborServiceYamlFileName` | Conditional | Overrides common Harbor service package file name when defined. Ignored when `disableHarbor` is true. |
| `supervisorServices.harborDataTemplateYamlPath` | Conditional | Per-cluster legacy path to the Harbor data values template YAML; overrides common when set. Ignored when `disableHarbor` is true. |
| `supervisorServices.harborServiceYamlPath` | Conditional | Per-cluster legacy path to the Harbor Carvel package YAML; overrides common when set. Ignored when `disableHarbor` is true. |
| `supervisorServices.disableArgoCD` | No | Boolean. Overrides `common.supervisorServices.disableArgoCD` for this cluster only. When true, skips Argo CD deployment for this cluster. Default: false. |
| `supervisorServices.disableHarbor` | No | Boolean. Overrides `common.supervisorServices.disableHarbor` for this cluster only. When true, skips Harbor deployment (service registration, data values generation, installation) for this cluster. Default: false. |
| `supervisorServices.nameSpacePrefix` | No | Argo CD namespace prefix. Omit for default `argocd`; script appends cluster MoRef for uniqueness. |
| `supervisorServices.vmClass` | No | Array of VM class names for the Argo CD namespace. Omit to assign all VM classes from vCenter. |
| `harborConfiguration.hostname` | Conditional | **Required unless `disableHarbor` is true**, except when **`common.labenvironment`** is **`true`** and **`tlsCrt`** / **`tlsKey`** are both omitted—in that case the hostname may be taken from the Harbor data values template `hostname:` line. Otherwise set a DNS-compatible FQDN or IP (e.g. `harbor.site1.example.com`). Sets the `hostname` key in the Harbor data values YAML. |
| `harborConfiguration.registryVolumeSize` | No | Override for `persistence.persistentVolumeClaim.registry.size`. Format: positive integer followed by `Gi` (e.g. `10Gi`). Omit to use the template default. |
| `harborConfiguration.jobserviceVolumeSize` | No | Override for `persistence.persistentVolumeClaim.jobservice.jobLog.size`. Format: `<N>Gi`. Omit to use the template default. |
| `harborConfiguration.databaseVolumeSize` | No | Override for `persistence.persistentVolumeClaim.database.size`. Format: `<N>Gi`. Omit to use the template default. |
| `harborConfiguration.redisVolumeSize` | No | Override for `persistence.persistentVolumeClaim.redis.size`. Format: `<N>Gi`. Omit to use the template default. |
| `harborConfiguration.trivyVolumeSize` | No | Override for `persistence.persistentVolumeClaim.trivy.size`. Format: `<N>Gi`. Omit to use the template default. |
| `harborConfiguration.harborAdminPassword` | No | Override for the Harbor admin password (`harborAdminPassword` in YAML). Prefix with `$env:` to resolve from an environment variable at runtime (e.g. `$env:HARBOR_ADMIN_PW`). If the variable is unset at runtime, the script prompts interactively (masked input) and caches the value in that environment variable for the remainder of the run. |
| `harborConfiguration.secretKey` | No | Override for the encryption secret key (`secretKey` in YAML). Harbor uses this as an AES-128 encryption key: **must be exactly 16 characters**. Plain-text values of the wrong length are rejected at pre-flight with a clear error before deployment begins. `$env:` references are validated after resolution before the YAML is submitted — a resolved value of the wrong length also throws a pre-deployment error. Supports `$env:` resolution with interactive fallback prompt when unset. |
| `harborConfiguration.databasePassword` | No | Override for the internal PostgreSQL password (`database.password` in YAML). Supports `$env:` resolution with interactive fallback prompt when unset. |
| `harborConfiguration.coreSecret` | No | Override for the core inter-service secret (`core.secret` in YAML). Supports `$env:` resolution with interactive fallback prompt when unset. |
| `harborConfiguration.jobserviceSecret` | No | Override for the jobservice inter-service secret (`jobservice.secret` in YAML). Supports `$env:` resolution with interactive fallback prompt when unset. |
| `harborConfiguration.registrySecret` | No | Override for the registry upload-state secret (`registry.secret` in YAML). Supports `$env:` resolution with interactive fallback prompt when unset. |
| `harborConfiguration.parentDirectory` | Conditional | When set, directory for TLS PEM files; `tlsCrt` / `tlsKey` / `caCrt` are file names under this directory. Omit when using full paths for those fields (legacy). |
| `harborConfiguration.tlsCrt` | Conditional | With `parentDirectory`: certificate **file name** (e.g. `tls.crt.pem`). Without `parentDirectory`: full or JSON-relative path to the PEM file. Required when `tlsKey` is set; both must be defined together. |
| `harborConfiguration.tlsKey` | Conditional | With `parentDirectory`: private key **file name**. Without `parentDirectory`: full or JSON-relative path. Required when `tlsCrt` is set; both must be defined together. |
| `harborConfiguration.caCrt` | No | With `parentDirectory`: CA **file name**. Without `parentDirectory`: full or JSON-relative path. Only valid when both `tlsCrt` and `tlsKey` are defined. |
| `storagePolicy.storagePolicyTagCatalog` | No | Tag catalog for storage policy. Omit for default `{storageType}-Storage-TagCatalog`. |
| `storagePolicy.storageType` | Yes | Storage type: `VMFS`, `vSAN-ESA`, or `vSAN-OSA`. |
| `networking.networkSegments` | Yes | Array of segments; names must match supervisor.json network references. |
| `networking.networkSegments[].name` | Yes | Segment name; lower-case, RFC1123; must match supervisor.json. |
| `networking.networkSegments[].vlanId` | Yes | VLAN ID (0–4095); unique within this cluster. |
| `networking.networkSegments[].gateway` | Yes | Gateway in CIDR (e.g. `10.30.10.1/24`); mapped into supervisor by segment name. |
| `networking.networkingVmKernelInterfaces` | Conditional | **Required for vSAN-ESA and vSAN-OSA only** (not VMFS). At least two entries: **vMotion**, **vSAN** (required). Optional third: **vSAN Witness**. When vSAN Witness is omitted, mgmt (vmk0) is tagged with vSAN witness traffic in addition to mgmt; when present, a dedicated witness VMkernel (vmk3) is created on the **first** VDS when `nicList` has four NICs (`VDS-<edgesite>-sw1`), with vMotion/vSAN on the second VDS (`-sw2`); with two NICs, all three services share the one VDS. Each entry includes the fields in the following rows. |
| `networking.networkingVmKernelInterfaces[].service` | Conditional | One of: `vMotion`, `vSAN`, `vSAN Witness` (exact strings). vMotion and vSAN must appear across the array; vSAN Witness is optional. |
| `networking.networkingVmKernelInterfaces[].vlanId` | Conditional | VLAN ID 0–4095; must align with segment design. |
| `networking.networkingVmKernelInterfaces[].netmask` | Conditional | IPv4 netmask for the VMkernel (e.g. `255.255.255.0`). |
| `networking.networkingVmKernelInterfaces[].ipList` | Conditional | Array of exactly two unique IPv4 addresses (host order matches `esxHosts`). |
| `networking.networkingVmKernelInterfaces[].gateway` | Conditional | Optional on **vSAN Witness** entry only: IPv4 gateway string applied with **esxcli** after the VMkernel exists (not used on vMotion/vSAN entries by design). |

**Configuration Help:** Run `Show-InfrastructureJsonConfigurationHelp` to view the full reference (Key, Required, Notes). Use `-Format List` for narrow screens, `-Format Table` for wide; `-Filter` for wildcard search on keys.

### supervisor.json

Top-level keys: `commonSupervisorSpec` (shared supervisor and FLB settings) and `siteSpec` (array of per-site config). Each `siteSpec[].edgeSite` must match one `clusters[].edgeSite` in `infrastructure.json`.

The following are **script parameters** (not in supervisor JSON) with fixed defaults: `flbProvider` (VSPHERE_FOUNDATION), `flbNetworkIpAssignmentMode`, `primaryWorkloadIpAssignmentMode`, `mgmtIpAssignmentMode` (all STATIC), and FLB network personas (management: Management; virtual server: FRONTEND, WORKLOAD). See `Add-Supervisor` and `Get-SupervisorConfigurationFromJson` help.

#### commonSupervisorSpec

| Field | Req | Notes |
| ----- | --- | ----- |
| `controlPlaneVMCount` | Yes | `1` or `3`. Key required by shallow validation. |
| `controlPlaneSize` | Yes | `TINY`, `SMALL`, `MEDIUM`, or `LARGE`. Key required by shallow validation. |
| `flbAvailability` | Yes | `SINGLE_NODE` or `ACTIVE_PASSIVE`. Key required by shallow validation. |
| `flbSize` | Yes | `SMALL`, `MEDIUM`, `LARGE`, or `X-LARGE`. Key required by shallow validation. |
| `flbNetworkType` | Yes | Use `DVPG`. Key required by shallow validation. |
| `networkSearchDomains` | Yes | Array of DNS search domains. |
| `networkNtpServers` | Yes | Array of NTP servers. |
| `dnsServers` | Yes | Array of DNS servers. |

#### siteSpec[] (each element)

| Field | Req | Notes |
| ----- | --- | ----- |
| `edgeSite` | Yes | Must match `infrastructure.json` `clusters[].edgeSite`. |
| `foundationLoadBalancerComponents.flbName` | Yes | FLB name for this site. Key required by shallow validation. |
| `foundationLoadBalancerComponents.flbVipStartIP` | Yes | Start IP for FLB virtual IP range. |
| `foundationLoadBalancerComponents.flbVipIPCount` | Yes | Count of VIPs from flbVipStartIP. |
| `foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName` | Yes | Must match infra `networkSegments[].name`; gateway from infra unless `flbNetworkGateway` is set. |
| `foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp` | Yes | Start IP for FLB management network. |
| `foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount` | Yes | IP count for FLB management. |
| `foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkGateway` | No | Override gateway (otherwise from infra by name). |
| `foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName` | Yes | Match infra segment name; gateway from infra unless `flbNetworkGateway` is set. |
| `foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp` | Yes | Start IP for FLB virtual server network. |
| `foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount` | Yes | IP count for the FLB virtual-server network range. **Minimum enforced by validation based on enabled services**: Harbor enabled → **50**; Argo CD only → **20**; neither service → **10**. |
| `foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkGateway` | No | Override gateway (otherwise from infra by name). |
| `mgmtNetworkSpec.mgmtNetworkName` | Yes | Must match infra segment name. Key required by shallow validation. |
| `mgmtNetworkSpec.mgmtNetworkStartingIp` | Yes | Start IP for supervisor management network. |
| `mgmtNetworkSpec.mgmtNetworkIPCount` | Yes | IP count for supervisor management. |
| `primaryWorkloadNetwork.primaryWorkloadNetworkName` | Yes | Must match infra segment name. Key required by shallow validation. |
| `primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp` | Yes | Start IP for workload VIP range. |
| `primaryWorkloadNetwork.primaryWorkloadNetworkIPCount` | Yes | IP count for workload VIP range. |
| `primaryWorkloadNetwork.workloadServiceStartIp` | Yes | Start IP for workload service range. |
| `primaryWorkloadNetwork.workloadServiceCount` | Yes | Count (e.g. 256 or 512); must occupy full CIDR. Key required by shallow validation. |

**Configuration Help**: Run `Show-SupervisorJsonConfigurationHelp` to view the full reference (Key, Required, Notes). Use `-Format List` for narrow screens or `-Format Table` for wide; `-Filter` for wildcard search on keys.

## Harbor and Argo CD Deployment Notes

### Harbor: Secret Management and Just-in-Time Environment Variables

Harbor requires six secrets. Each `harborConfiguration` secret field supports two modes:

- **Plain-text in JSON** – Value is used as-is. Not recommended for production secrets in version-controlled files.
- **`$env:VARNAME` reference** – Resolved from the named environment variable at runtime. If the variable is not set when the script runs, you are prompted interactively (masked input) during the pre-flight phase — before any deployment step begins. The entered value is stored in the process environment for the remainder of the run so each variable is prompted for at most once.

**Setting environment variables on Windows before running (recommended for automation):**

```powershell
$env:HARBOR_ADMIN_PASSWORD = "MyAdminPassword1"
$env:SECRET_KEY             = "MySecretKey12345"   # Must be exactly 16 characters (AES-128)
$env:DATABASE_PASSWORD      = "MyDatabasePw1"
$env:CORE_SECRET_KEY        = "MyCoreSecret1"
$env:JOBSERVICE_SECRET_KEY  = "MyJobSvcSecret1"
$env:REGISTRY_SECRET_KEY    = "MyRegSecret1"
Start-VcfEdgeAtScale -EdgeSite "site1"
```

**If env vars are not pre-set,** the script prompts at the start of the run (before connecting to vCenter):

```text
[WARNING] Environment variable "HARBOR_ADMIN_PASSWORD" (harborConfiguration.harborAdminPassword)
          is not set. Prompting for interactive input.
Enter value for harborConfiguration.harborAdminPassword (env:HARBOR_ADMIN_PASSWORD): ****

[WARNING] Environment variable "SECRET_KEY" (harborConfiguration.secretKey) is not set.
          Prompting for interactive input.
Enter value for harborConfiguration.secretKey (env:SECRET_KEY): ****************
```

**`secretKey` length:** Must be exactly **16 characters** (AES-128). This constraint is enforced at the point of entry — whether the value came from a pre-set env var or interactive input:

- **Pre-set env var with wrong length:** An error is logged, the variable is cleared, and you are prompted to enter a corrected 16-character value before deployment proceeds.
- **Interactive input with wrong length:** The error is shown immediately and the prompt repeats until a valid 16-character value is entered (or Ctrl+C to abort).
- **Plain-text value in JSON with wrong length:** Caught at pre-flight validation (`-ValidateOnly` or at the start of any run) before any deployment begins.

Example session when `SECRET_KEY` is set to an 8-character value:

```text
[ERROR] Environment variable "SECRET_KEY" (harborConfiguration.secretKey) has 8 character(s)
        but must be exactly 16.
Would you like to re-enter harborConfiguration.secretKey? (Y/N): Y
[WARNING] Prompting for corrected value for harborConfiguration.secretKey (env:SECRET_KEY).
Enter value for harborConfiguration.secretKey (env:SECRET_KEY): ________
[ERROR] harborConfiguration.secretKey must be exactly 16 character(s) but the entered value
        is 8 character(s).
Would you like to re-enter harborConfiguration.secretKey? (Y/N): Y
Enter value for harborConfiguration.secretKey (env:SECRET_KEY): ________________
```

Choosing **N** at the `(Y/N)` prompt aborts the deployment cleanly before any vCenter connection or deployment step:

```text
Would you like to re-enter harborConfiguration.secretKey? (Y/N): N
[ERROR] User chose not to re-enter harborConfiguration.secretKey. Aborting deployment.
Exception: Deployment aborted: harborConfiguration.secretKey must be exactly 16 character(s).
```

**TLS certificate and private key validation:** `tlsCrt` and `caCrt` must contain PEM certificates (`-----BEGIN CERTIFICATE-----`). `tlsKey` must contain a PEM private key. The script validates the first line of each file before deployment and produces a clear error if the types are swapped (a common mistake when the `.crt` and `.key` file paths are accidentally transposed).

**Debug log redaction:** When running with `-LogLevel DEBUG`, all secret values in the YAML dump are replaced with `[REDACTED]`. The private key PEM block (`tls.key`) is redacted line-by-line. The TLS certificate (`tls.crt`) is left visible as it is public material. The key name and YAML structure remain intact for structural debugging.

**Saving the Harbor data values file (`-SaveHarborYaml`):** By default, the temporary Harbor data values YAML is deleted after successful installation. Specify `-SaveHarborYaml` to move it to a `HarborYaml` subdirectory under the module directory instead:

```powershell
Start-VcfEdgeAtScale -SaveHarborYaml
```

The directory is created automatically. If it cannot be created, deployment exits with an error before Harbor installation begins.

> **Security warning:** The saved file contains **Harbor passwords and secrets in plain text**. A `[WARNING]` is logged whenever this switch is used. A redacted copy is available in the deployment log. Treat the `HarborYaml` directory like a credentials store — restrict access, exclude it from source control, and **delete the file immediately** after resolving the issue.

**Harbor credentials display:** After a successful Harbor deployment, the script always prints the Harbor login details (URL, admin username, and password) directly to the console, regardless of the configured `LogLevel`. This ensures credentials are never silently swallowed even when running at a high log level.

**Supervisor container image registry registration:** After Harbor succeeds, the module registers it on the Supervisor (**Supervisor → Configure → Container Registries** in vCenter) using the Harbor VIP, admin login, and optional `caCrt`, and sets it as the default registry.

On `-CleanUp Harbor`, `-CleanUp Supervisor`, or `-CleanUp All`, that registration is removed before the Harbor service uninstall. Failures there log as warnings; finish the step in vCenter if needed.

### Argo CD: Deployment Output, Namespace Uniqueness, and Fallback

**Deployment output:** After a successful Argo CD instance deployment, the script logs the initial admin credentials and provides the command to change them:

```text
[INFO] Login as user "admin" using temporary password: vEHJgoj3wGtHQDlI
[INFO] To update your password run: "argocd.exe account update-password
       --server 10.40.12.203 --account admin --insecure"
```

Change the password immediately after deployment using the provided command.

**Namespace uniqueness:** The Argo CD namespace in `argocd-deployment.yml` is automatically suffixed with the cluster MoRef (e.g. `argocd` → `argocd-c462`). This prevents conflicts when multiple supervisor clusters share the same vCenter. The base namespace in `argocd-deployment.yml` must match `supervisorServices.nameSpacePrefix` in `infrastructure.json`; the suffix is appended automatically.

**Argo CD rollback and retry:** If Argo CD deployment fails (pods do not reach ready state, instance timeout, or YAML misconfiguration), rollback removes only the Argo CD namespace. The supervisor and Harbor remain intact. To fix the YAML and retry:

```powershell
# 1. Remove only the Argo CD namespace; supervisor and Harbor remain intact.
Start-VcfEdgeAtScale -CleanUp ArgoCD -EdgeSite "site1"

# 2. Fix your argocd-deployment.yml, then re-run.
#    Supervisor and Harbor steps are idempotently skipped.
Start-VcfEdgeAtScale -EdgeSite "site1"
```

**Harbor rollback and retry:** Harbor failure rolls back only the Harbor Supervisor Service. The supervisor and Argo CD remain intact and are idempotently verified (not re-deployed) on retry:

```powershell
# 1. If you declined the rollback prompt or the service is stuck in ERROR state:
Start-VcfEdgeAtScale -CleanUp Harbor -EdgeSite "site1"

# 2. Fix the issue (see Troubleshooting below), then retry.
#    Supervisor and Argo CD steps are idempotently skipped.
Start-VcfEdgeAtScale -EdgeSite "site1"
```

**Autonomous (unattended) runs:** Use `-RollbackOnFailure $true` to roll back automatically on any failure without prompting (recommended default for unattended pipelines). Use `-RollbackOnFailure $false` only when you accept a partial deployment and will run scoped `-CleanUp` yourself before the next attempt. Omit the parameter for an interactive Y/N/Always prompt at each failure.

## Logging

The module provides comprehensive logging with multiple levels:

- **DEBUG**: Per-step and per-host sub-operation detail (pNIC adds, vmk0 migration, vSAN witness traffic idempotency skips, supervisor build sub-steps, REST session steps, Argo CD per-pod status, etc.). Use `-LogLevel DEBUG` for troubleshooting.
- **INFO**: Phase-level milestones visible during a standard deployment (cluster created, hosts added, VDS created, supervisor ready, Argo CD pods ready, Harbor configured, etc.). Default level.
- **ADVISORY**: Important notices that don't indicate problems.
- **WARNING**: Warning messages about potential issues.
- **EXCEPTION**: Caught exceptions that were handled.
- **ERROR**: Error messages indicating failures.

All levels are always written to the log file regardless of the configured `-LogLevel`. Console output is filtered to the configured level and above.

Log files are created under **`Join-Path $env:VcfEdgeatScaleRootDirectory 'Logs'`** (not under the module folder) with the naming pattern:

```text
<your-base-directory>/Logs/VcfEdgeAtScale-YYYY-MM-DD.log
```

## Troubleshooting

### Template files or Templates directory missing

If **`Start-VcfEdgeAtScale -Initialize`** reports missing files under **`Templates`**:

```powershell
# Check module installation path
(Get-Module -Name VcfEdgeAtScale -ListAvailable).ModuleBase

# Verify Templates exists
Test-Path (Join-Path (Get-Module VcfEdgeAtScale -ListAvailable | Select-Object -First 1).ModuleBase "Templates")
```

### Module Not Found

If the module is not recognized:

```powershell
# Check if module is installed
Get-Module -Name VcfEdgeAtScale -ListAvailable

# Check module path
$env:PSModulePath

# Reinstall if needed
Install-Module -Name VcfEdgeAtScale -Force
```

### Deployment Failures

1. **Enable DEBUG logging**: `Start-VcfEdgeAtScale -LogLevel DEBUG`
2. **Check log files**: Review **`Join-Path $env:VcfEdgeatScaleRootDirectory 'Logs/VcfEdgeAtScale-*.log'`** (or the path shown in errors)
3. **Validate JSON files**: Ensure configuration files are valid JSON
4. **Verify prerequisites**: Confirm VCF.PowerCLI 9.0+, kubectl, and vcf CLI are available

### Cleanup: Management Restore or VDS Removal Fails

Cleanup no longer requires `clusters.networking.temporaryManagementIp`. Management (vmk0) is moved from the VDS to a standard switch programmatically using the same API as vCenter’s **Migrate VMkernel Adapter** wizard. If that fails, the script reports the error and instructs you to move vmk0 manually in vCenter, then re-run cleanup.

If cleanup reports "could not remove any pNIC from VDS" (vSphere rolled back to avoid disconnecting the host) or "Port group mgmt is in use":

1. In vCenter go to **Host → Configure → Networking → VMkernel adapters** for each host in the cluster.
2. Edit **vmk0** and change its port group from the distributed "mgmt" port group to a standard switch (e.g. create a temporary vSwitch with one pNIC and a Management port group, or use an existing standard switch).
3. Save so vmk0 is on a standard switch on all hosts.
4. Re-run cleanup with the same parameters (e.g. `-EdgeSite site2 -CleanUp Compute -Force`). With management off the VDS, cleanup will skip restore and remove the VDS and cluster.

### Harbor: secretKey Wrong Length

**When using `$env:` references:** The script detects a wrong-length value during the pre-flight prompting phase and asks whether you want to re-enter:

```text
[ERROR] Environment variable "SECRET_KEY" (harborConfiguration.secretKey) has 8 character(s)
        but must be exactly 16.
Would you like to re-enter harborConfiguration.secretKey? (Y/N): Y
[WARNING] Prompting for corrected value for harborConfiguration.secretKey (env:SECRET_KEY).
Enter value for harborConfiguration.secretKey (env:SECRET_KEY): ________________
```

- **Y** — re-prompts. The Y/N question repeats after each wrong-length entry.
- **N** — aborts deployment cleanly. No rollback is needed; nothing has been deployed yet.

**When using a plain-text value in JSON:**

```text
[ERROR] clusters[].harborConfiguration.secretKey for edgeSite "site1" must be
        exactly 16 characters but is 8 character(s). Harbor uses it as an AES-128
        encryption key.
```

**Fix:** Update the `secretKey` value in `infrastructure.json` to exactly 16 characters, then re-run. No rollback is needed.

### Harbor: TLS Certificate and Key Swapped (PEM Type Mismatch)

**Error:**

```text
[ERROR] clusters[].harborConfiguration.tlsCrt must contain a PEM certificate
        (-----BEGIN CERTIFICATE-----) but the file at "...\tls.crt" begins with
        "-----BEGIN PRIVATE KEY-----" for edgeSite "site1".
        Check that tlsCrt and tlsKey paths are not swapped.
```

**Fix:** Verify that `tlsCrt` points to the certificate file and `tlsKey` points to the private key file. This error is caught at pre-flight validation before any deployment begins.

### Harbor: Service Enters ERROR State

On deployment failure, a redacted copy of the Harbor data values file (with password fields replaced by `[REDACTED]`) is automatically saved for diagnostics — see the `[WARNING]` message in the console output for its path. The original secrets file is deleted immediately.

If Harbor enters an `ERROR` state shortly after installation (within 5–10 seconds of the first status poll):

1. **Check vCenter Events** (Menu → Events) for messages containing `"Registering harbor.tanzu.vmware.com... already exists"`. If present, this is a vCenter async conflict: delete the service from **Menu → Supervisor Management → Services**, then roll back and re-run.
2. **Check the secretKey length** — Harbor will fail immediately if `secretKey` is not exactly 16 characters. Look for `[ERROR]` messages about secretKey length in the pre-flight output.
3. **Check the vCenter Events for detailed error text** — the `ERROR` message from the script (e.g. `"OCI Registry"`) identifies the failing component but not the root cause. The full error is in vCenter Events for the supervisor.
4. **Admission or scheduling:** HA admission can block new VMs even when free capacity looks sufficient. For vSAN OSA/ESA, try **`haPolicy`** in `infrastructure.json` (`reservationBased`, `slotBased`, or `disabled`) or change HA admission in vCenter, then retry.

**Recovery:**

```powershell
# Roll back Harbor only (supervisor and Argo CD remain).
Start-VcfEdgeAtScale -CleanUp Harbor -EdgeSite "site1"

# Fix the issue, then retry.
Start-VcfEdgeAtScale -EdgeSite "site1"
```

### Common Issues

- **"Templates directory not found"**: Reinstall the module or verify FileList in manifest
- **"Required module template is missing"** (during **`-Initialize`**): Reinstall the module; confirm **`FileList`** in **`VcfEdgeAtScale.psd1`** includes the **`Templates/`** files.
- **"Unable to determine module installation path"**: Ensure module is properly installed via `Install-Module`

## Requirements

### PowerShell Module Dependencies

- **VCF.PowerCLI**

  ```powershell
  Install-Module -Name VCF.PowerCLI
  ```

### External Tools

- **kubectl**: Required for Argo CD operations
- **vcf CLI**: Required for supervisor management operations
- **veas-json-generator.py** + **veas-ui.html** (Python 3, no extra packages): Browser-based JSON configuration UI copied to **`Tools/`** by **`Start-VcfEdgeAtScale -Initialize`**. Run `python3 Tools/veas-json-generator.py` from your base directory — the server starts on `http://127.0.0.1:8080` and opens a browser tab automatically. Pass `--no-browser` to suppress auto-open in headless or SSH environments. Validates **`infrastructure.json`** and **`supervisor.json`** against the same rules as the PowerShell module (service-aware LB IP minimums, RFC1123 names, cross-file site matching, cross-site ESX host uniqueness, and more) and saves both files.

### Environment

- VMware Cloud Foundation 9.x
- vCenter Server with administrative access
- ESX hosts in connected state
- Network connectivity to vCenter and ESX hosts

## Version History

See [CHANGELOG.md](CHANGELOG.md) for detailed version history.

### Version 1.0.3.1003 (current)

See [CHANGELOG.md](CHANGELOG.md) for the authoritative per-release list. Recent additions include:

- **Template split**: The HTML/JS/CSS frontend has been extracted from `veas-json-generator.py` into a standalone `veas-ui.html` file. Both files are deployed to `Tools/` by `-Initialize` and synced on module upgrade.
- **Browser auto-open**: `python3 veas-json-generator.py` now opens a browser tab automatically on startup. Use `--no-browser` to suppress in headless environments.
- **VDS name accuracy**: The topology diagram now correctly renders VDS names using the configured `vdsNamePrefix` and edge site name (e.g. `VDS-vsan-edge1-sw1` / `-sw2` for 4-NIC).
- **PNG export fix**: The PNG download now rasterises correctly at all scale factors.
- **Cross-site ESX host uniqueness**: Both the Python validator and the PowerShell module now reject duplicate ESX host entries across edge sites before any deployment begins.
- **Clone feature improvements**: Auto-generated network names are RFC1123-compliant; cloned sites omit source ESX hostnames, gateway addresses, and VMkernel IPs; a banner guides the user through required post-clone edits.

### Version 1.0.3.1001

- Added update feature

### Version 1.0.3.1000

Summary aligned with [CHANGELOG.md](CHANGELOG.md) and [RELEASE_NOTES.md](RELEASE_NOTES.md): PowerShell module packaging for VCF 9.x edge Supervisor deployments (multi-site **`infrastructure.json`** / **`supervisor.json`**). Highlights include vLCM catalog workflows, stretched vSAN ESA/OSA, Harbor and Argo CD per site, optional **`-ComputeOnly`**, **`disableArgoCD`** / **`disableHarbor`**, lab-mode behavior (**`common.labenvironment`**), HA policy for vSAN multi-host clusters, VMkernel and witness handling, rollback/cleanup flows, cross-platform **`Import-Module`**, **`-Initialize`** persisting **`VcfEdgeatScaleRootDirectory`** via **`[System.Environment]::SetEnvironmentVariable`**, and **`Templates/*-config-help.json`** shipped under **`Docs/`** for **`Show-*ConfigurationHelp`**. See **[CHANGELOG.md](CHANGELOG.md)** for the authoritative per-release list.

### Version 1.0.2

- Significant reliability and performance improvements
- Cross-platform compatibility fixes
- Enhanced error handling and logging

## Contributing

This module is maintained by Broadcom. For issues, feature requests, or contributions, please refer to the project repository.

## License

Copyright (c) 2026 Broadcom. All Rights Reserved.

See the module manifest or LICENSE file for full license details.

## Support

For support and documentation:

- **Project Repository**: [GitHub Repository](https://github.com/vmware/powershell-module-for-vcf-edge-at-scale)
- **Documentation**: See module help: `Get-Help Start-VcfEdgeAtScale -Full`
- **VMware Cloud Foundation Documentation**: [VCF Documentation](https://techdocs.broadcom.com/us/en/vmware-cloud-foundation.html)

### Support troubleshooting

Use the **log file** under `Logs/` (see `New-LogFile` / run output for the path). Search the log for the same keywords as the console.

| Symptom / throw text | Log hints | What to do |
| --- | --- | --- |
| `VCF.PowerCLI is not installed` or `below the minimum required` | `(ERROR)` lines from `Initialize-ScriptVcfPowerCliModuleVersion` | Install [VCF PowerCLI](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/administration-sdks-cli-and-tools/introduction-to-vmware-vsphere-powercli.html) **9.0+**; run `Get-Module VCF.PowerCLI -ListAvailable`. |
| `No vCenter password supplied` / REST `Success = false` with password message | `New-VCenterRestApiSession` or `Get-SupervisorId` ERROR | Main flow: ensure **Connect-Vcenter** succeeded (sets `Script:VcenterInsecurePassword`). Ad-hoc REST: pass **`-VcenterPassword`** (SecureString) or **`-VcenterInsecurePassword`**. See [PASSWORD_HANDLING.md](PASSWORD_HANDLING.md). |
| `401` / `Unauthorized` (REST session) | ERROR + WARNING credential lines after `New-VCenterRestApiSession` | Wrong SSO password, locked user, or missing API privileges—not the ESX root password. Confirm `common.vCenterUser` and account role. |
| SSL / certificate / TLS (REST) | ERROR containing `SSL` or `certificate` | Lab: use **`-InsecureTls`** where supported, import vCenter CA, or align `Set-PowerCLIConfiguration -InvalidCertificateAction` with your policy. |
| `Required cmdlet ... was not found` (supervisor upgrade / Harbor / Argo service spec) | DEBUG around `Get-VcfSdkInitializeCommand` | Ensure VCF.PowerCLI **9.0+** is installed (`Install-Module VCF.PowerCLI`), then re-run `Import-Module VcfEdgeAtScale`. The module loads the required SDK submodule automatically via `RequiredModules`. Cmdlet names differ slightly between builds; the module resolves them when the SDK is loaded. |
| Supervisor / namespace API failures | `(ERROR)` with cmdlet or REST path | Capture **log + vCenter version + VCF.PowerCLI version** (`Get-Module VCF.PowerCLI -ListAvailable`). Open a support issue with that bundle. |

## Related Resources

- [VMware Cloud Foundation Documentation](https://techdocs.broadcom.com/us/en/vmware-cloud-foundation.html)
- [Single-Node vSphere Supervisor Design Guidance](https://blogs.vmware.com/cloud-foundation/2025/07/14/modernizing-your-edge-with-single-node-vsphere-supervisor-in-vmware-cloud-foundation-9-0/)
- [Argo CD Service Documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/using-argo-cd-service/argocd-custom-resrouce-reference.html)

### Install VCF CLI

- Install the VCF CLI per Broadcom: [Installing and Using VCF CLI v9](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html). First-run terms and CEIP are described there; set those before unattended automation.
- **Windows:** The installer typically provides `vcf.exe`. The module accepts **`vcf.exe` or `vcf`** on PATH (it picks the first name that resolves). Rename or adjust only if your deployment standard requires a specific filename.
- **Linux / macOS:** Use the `vcf` binary from the same documentation. Install **kubectl** from [Kubernetes install tools](https://kubernetes.io/docs/tasks/tools/) if you have not already.

## Important Notes

- **Networks:** Expect the four-network edge layout (management, workload, two load balancer segments) and four VLAN IDs in `infrastructure.json`, matching the design docs linked above.

- **CLI tools:** Install **kubectl** ([Kubernetes install tools](https://kubernetes.io/docs/tasks/tools/)) and the **VCF CLI** ([Installing and Using VCF CLI v9](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html)) before you run the module (see step 6).

- **Platforms:** Tested on Windows and macOS with PowerShell 7.4+.
