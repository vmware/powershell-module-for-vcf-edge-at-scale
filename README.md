# Simple Supervisor Deployment at Scale Automation

[![PowerShell](https://img.shields.io/badge/PowerShell-7.2%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/License-Broadcom-green.svg)](LICENSE.md)
[![Version](https://img.shields.io/badge/Version-1.0.0.3-orange.svg)](CHANGELOG.md)
[![GitHub Clones](https://img.shields.io/badge/dynamic/json?color=success&label=Clone&query=count&url=https://gist.githubusercontent.com/nathanthaler/7c5ed25bb9cea6eef7f015be50e44a6f/raw/clone.json&logo=github)](https://gist.githubusercontent.com/nathanthaler/7c5ed25bb9cea6eef7f015be50e44a6f/raw/clone.json)

## Overview

The **SimpleSupervisorDeploymentAtScale** PowerShell module automates the end-to-end deployment of a vSphere Supervisor in VMware Cloud Foundation (VCF) 9.x environments based on this [design guidance](https://blogs.vmware.com/cloud-foundation/2025/07/14/modernizing-your-edge-with-single-node-vsphere-supervisor-in-vmware-cloud-foundation-9-0/). It automates critical steps from initial setup to the creation of the supervisor, including network configuration and content library verification. The script leverages VCF.PowerCLI cmdlets and relies on pre-configured JSON input files (`infrastructure.json` and `supervisor.json`) to tailor the deployment to your environment. Additionally, it addresses the prerequisites for integrating Argo CD operator services and ensures the necessary CLI tools are available for a comprehensive, end-to-end automated solution.

## Pre-requisites

- **VCF 9.x Environment**: A VCF 9.x environment running with a vCenter instance must be available
- **Host Preparation**: The host is already prepped with ESX and has appropriate network setup
- **Network Connectivity**: ESX and vCenter network connectivity is established
- **Provisioning Access**: Connectivity must be available from the Provisioning host to Supervisor Management Network
- **Datacenter Setup**: Datacenter defined in `infrastructure.json` must already be created and have a vLCM image present in the vCenter Image Catalog
- **PowerShell**: Version 7.2 or later installed on your system. If not, download and install it from the official Microsoft website
- **kubectl**: Installed on your system. kubectl can be downloaded from upstream at: https://kubernetes.io/docs/tasks/tools/
- **vcf**: Installed on your system. To download the VCF consumption CLI see this [techdocs URL](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9.html) for details.

## Functions Performed by this Automation

This automation performs the following:

### Deployment (per edge site)

1. **Cluster creation and host addition**: Creates a new cluster in vCenter and adds the specified host(s) to the cluster. Supports retry when the cluster is in a transitional state.

2. **Cluster configuration**:
   - DRS set to Automatic; HA admission control disabled.
   - vLCM: image selection from the vCenter Image Catalog (by name from JSON or interactive prompt); cluster compliance check and remediation run before vSAN health checks.

3. **VDS and networking**:
   - vSphere Distributed Switch (VDS) creation with required port groups (management, vMotion, vSAN, vSAN Witness as configured) and VMkernel interfaces. Management (vmk0) remains management-only; vMotion, vSAN, and vSAN Witness use dedicated VMkernels when configured.
   - Physical NIC connectivity check before VDS creation; active/standby uplink teaming; MTU from config (default 9000 for vMotion/vSAN, 1500 for management and vSAN Witness).

4. **Storage**:
   - **VMFS**: Local VMFS datastore from available disk; storage policy for the edge datastore.
   - **vSAN OSA or vSAN ESA**: vSAN enabled (OSA or ESA per config); disk auto-claim; vSAN witness traffic (and optional witness host); vSAN performance service and alarm checks (with optional `-AcceptBadCheckResults` to proceed when health is red or vLCM remediation fails).

5. **vSphere Supervisor enablement**: Supervisor enabled on the cluster with VM Operator, VKS, Velero, and Argo CD Operator services.

6. **Argo CD instance**: Argo CD instance created and configured. The script appends the cluster MoRef to the ArgoCD namespace (e.g., `argocd` becomes `argocd-c462`) so multiple supervisor clusters on the same vCenter do not conflict.

### At-scale and targeting

- **Multiple edge sites**: Deploys all clusters defined in `infrastructure.json` sequentially, or a subset via `-EdgeSite "site1,site2"` in the order specified.

### Operational modes

- **Validate only** (`-ValidateOnly`): Full JSON validation (shallow, deeper, network segment uniqueness) and YAML file existence checks; no vCenter connection or deployment.
- **Compute only** (`-ComputeOnly`): Runs cluster creation, hosts, storage, VDS, and vLCM remediation, then exits without enabling the supervisor or deploying Argo CD.
- **Cleanup** (`-CleanUp Supervisor | Compute | All | ArgoCD`): Supervisor = disable supervisor only (compute remains). Compute = remove compute only (VDS, vSAN/VMFS, cluster); fails if supervisor is enabled. All = disable supervisor then remove compute. ArgoCD = remove only the Argo CD supervisor namespace per cluster. Confirmation prompt unless `-Force` with lab environment.
- **Rollback on failure**: On deployment failure, rollback scope is automatic: compute/vSAN failure → full compute rollback; supervisor failure → supervisor-only rollback; Argo CD failure → Argo CD namespace removal only. Use `-RollbackOnFailure` to always roll back, never roll back, or prompt (Y/N/Always).

### Helper functions

- **Copy-SimpleSupervisorTemplates**: Copies template files (infrastructure.json, supervisor.json, argocd-deployment.yml, Argo CD operator YAML) from the module to your working directory.
- **Show-InfrastructureJsonConfigurationHelp** / **Show-SupervisorJsonConfigurationHelp**: Display configuration reference (Key, Required, Notes) for the JSON files (List, Table, GridView, or Auto by terminal width; optional `-Filter`).

## Installation

### Manual Installation

1. Download the module files from this repository
2. Extract to your PowerShell modules directory:
   - **Windows**: `$env:USERPROFILE\Documents\PowerShell\Modules\SimpleSupervisorDeploymentAtScale\`
   - **Linux/macOS**: `~/.local/share/powershell/Modules/SimpleSupervisorDeploymentAtScale/`
3. Import the module: `Import-Module SimpleSupervisorDeploymentAtScale`

## Quick Start

### 1. Get Template Files

The module includes default configuration templates. Copy them to your working directory:

```powershell
# Copy all template files to current directory
Copy-SimpleSupervisorTemplates

# Or specify a destination
Copy-SimpleSupervisorTemplates -DestinationPath "./config"

# Preview what would be copied (without actually copying)
Copy-SimpleSupervisorTemplates -WhatIf
```

This will copy four template files:
- `infrastructure.json` - Infrastructure configuration (vCenter, cluster, network, storage)
- `supervisor.json` - Supervisor cluster configuration (networks, load balancer)
- `argocd-deployment.yml` - ArgoCD instance deployment YAML
- `1.1.0-25100889.yml` - ArgoCD operator package YAML

### 2. Configure Template Files

Edit the template files with your environment-specific values:

- **infrastructure.json**: Update vCenter details, ESX host, cluster name, network settings, storage configuration
- **supervisor.json**: Configure supervisor cluster settings, network IP ranges, load balancer configuration
- **argocd-deployment.yml**: Configure ArgoCD instance settings. **Note:** The namespace value in this file will be automatically modified during deployment to ensure uniqueness (the cluster MoRef identifier will be appended). The namespace value in `infrastructure.json` should match the base namespace value in this file.
- **1.1.0-25100889.yml**: Typically no changes needed (ArgoCD operator package)

**Need help configuring your JSON files?** Use the built-in helper functions to view detailed configuration reference tables:

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

**Format Options:**
- **Auto** (default): Automatically selects the best format based on terminal width. Uses 'List' for narrow screens (< 120 characters) and 'Table' for wide screens (≥ 120 characters).
- **List**: Displays each field on its own line. Works best for narrow screens (40-50+ characters). No column wrapping issues.
- **Table**: Displays data in a table format with horizontal separators between rows. Best for wide screens (120+ characters).
- **GridView**: Opens an interactive grid view window with sorting and filtering capabilities. Works on any screen size but requires Windows PowerShell (not available in PowerShell Core on macOS/Linux).

These functions display a reference table with **Key**, **Required** (Yes/No/Conditional), and **Notes** for each configuration field.

## 3. Run Deployment

```powershell
# Deploy using default configuration files
Start-SimpleSupervisorDeploymentAtScale

# Validate configuration files only (no vCenter connection or deployment)
Start-SimpleSupervisorDeploymentAtScale -ValidateOnly

# Or specify custom file paths and log level
Start-SimpleSupervisorDeploymentAtScale `
    -InfrastructureJson "./config/infrastructure.json" `
    -SupervisorJson "./config/supervisor.json" `
    -LogLevel INFO

# Deploy a single site, or run cleanup (Supervisor / Compute / All / ArgoCD), or compute-only
# See the Start-SimpleSupervisorDeploymentAtScale section below for more examples.
```


## Module Functions

### Start-SimpleSupervisorDeploymentAtScale

Main deployment function that automates the complete vSphere Supervisor deployment process.

**Parameters:**
- `AcceptBadCheckResults` (Switch, optional) - When specified, automatically proceed when vSAN cluster health is red or when vLCM cluster compliance remediation fails (no Y/N prompts).
- `CleanUp` (String, optional) - Cleanup only; must be one of `Supervisor`, `Compute`, `All`, or `ArgoCD`. Supervisor = disable supervisor only. Compute = remove only compute (fails if supervisor is deployed). All = disable supervisor then remove compute. ArgoCD = remove only the ArgoCD supervisor namespace for each cluster (no supervisor deactivation or compute removal); the script polls until the namespace is gone and shows progress. Exits without deploying. Confirmation requires typing exactly "delete &lt;scope&gt; for &lt;edgeSite&gt;" (e.g. "delete argocd for site1") unless `-Force` is used with `common.labenvironment` true.
- `ComputeOnly` (Switch, optional) - Run all pre-supervisor steps (clusters, hosts, storage, VDS, vLCM) then exit without enabling the supervisor or deploying ArgoCD.
- `EdgeSite` (String, optional) - Comma-delimited list of edge site names (e.g. `"site1,site2"`). Deploy only clusters whose `edgeSite` matches one of the values, in the order listed. Omit to deploy all clusters. Only comma is allowed as separator; invalid delimiters or unknown site names cause the workflow to fail.
- `Force` (Switch, optional) - When `common.labenvironment` is true in infrastructure JSON, bypasses the cleanup confirmation prompt when using `-CleanUp`. Has no effect otherwise; a warning is shown if used without lab.
- `InfrastructureJson` (String, optional) - Path to infrastructure configuration JSON file. Default: `"infrastructure.json"`.
- `LogLevel` (String, optional) - Minimum log level for console output. Valid values: `DEBUG`, `INFO`, `ADVISORY`, `WARNING`, `EXCEPTION`, `ERROR`. Default: `"INFO"`.
- `RollbackOnFailure` (Boolean, optional) - When `$true`: always rollback on failure (no prompt; for autonomous runs). When `$false`: never rollback; leave site in current state and continue to next site if any. When omitted: prompt (Y/N/Always). Rollback scope is automatic by failure state (see **Rollback behavior** below).
- `SupervisorJson` (String, optional) - Path to supervisor configuration JSON file. Default: `"supervisor.json"`.
- `ValidateOnly` (Switch, optional) - Run full JSON validation (shallow, deeper, network segment uniqueness) and YAML file existence checks, then exit without connecting to vCenter or deploying. Use to validate configuration files before deployment.
- `Version` (Switch, optional) - Display module version and exit.

**Rollback behavior:** On deployment failure, rollback scope is determined by the failure state (no separate parameter). **Compute/vSAN failure** (before supervisor) → full compute rollback (vSAN/VDS/cluster teardown). **Supervisor failure** (after compute, before ArgoCD) → supervisor-only rollback (supervisor disabled; compute remains). **ArgoCD failure** (e.g. pods don't come up) → ArgoCD-only rollback (ArgoCD namespace removed; supervisor left intact so you can fix and re-run). Use `-RollbackOnFailure` to control whether the script prompts (Y/N/Always), always rolls back, or never rolls back.

**Examples:**

```powershell
# Basic deployment with default files
Start-SimpleSupervisorDeploymentAtScale

# Deployment with custom configuration files
Start-SimpleSupervisorDeploymentAtScale `
    -InfrastructureJson "config/prod-infrastructure.json" `
    -SupervisorJson "config/prod-supervisor.json"

# Deployment with DEBUG logging for troubleshooting
Start-SimpleSupervisorDeploymentAtScale -LogLevel DEBUG

# Deploy only a specific edge site (targeted deployments or troubleshooting)
Start-SimpleSupervisorDeploymentAtScale -EdgeSite "site1"

# Deploy multiple edge sites in order (comma-delimited; only comma is allowed as separator)
Start-SimpleSupervisorDeploymentAtScale -EdgeSite "site1,site2"

# Deploy specific edge site(s) with custom configuration files
Start-SimpleSupervisorDeploymentAtScale `
    -EdgeSite "site2" `
    -InfrastructureJson "./config/infrastructure.json" `
    -SupervisorJson "./config/supervisor.json"

# Autonomous run: always rollback on failure without prompting
Start-SimpleSupervisorDeploymentAtScale -RollbackOnFailure $true

# Never rollback on failure; leave site in current state and continue to next site
Start-SimpleSupervisorDeploymentAtScale -RollbackOnFailure $false

# Compute-only: prepare clusters, hosts, storage, VDS, and vLCM; exit without enabling supervisor
Start-SimpleSupervisorDeploymentAtScale -ComputeOnly

# Cleanup supervisor only for site1 (compute remains); you must type "delete supervisor for site1" to confirm
Start-SimpleSupervisorDeploymentAtScale -CleanUp Supervisor -EdgeSite "site1"

# Cleanup ArgoCD namespace only for site1 (supervisor and compute remain); confirm with "delete argocd for site1"
Start-SimpleSupervisorDeploymentAtScale -CleanUp ArgoCD -EdgeSite "site1"

# Cleanup compute only for site1 (fails if supervisor is deployed); confirm with "delete compute for site1"
Start-SimpleSupervisorDeploymentAtScale -CleanUp Compute -EdgeSite "site1"

# Cleanup all (supervisor then compute) for all sites; confirm per site with "delete all for <edgeSite>"
Start-SimpleSupervisorDeploymentAtScale -CleanUp All

# Cleanup all with -Force when common.labenvironment is true in infrastructure.json (bypasses confirmation)
Start-SimpleSupervisorDeploymentAtScale -CleanUp All -Force

# Accept bad vSAN health or vLCM compliance (proceed without Y/N prompts)
Start-SimpleSupervisorDeploymentAtScale -AcceptBadCheckResults

# Validate JSON and YAML only (no deployment)
Start-SimpleSupervisorDeploymentAtScale -ValidateOnly -InfrastructureJson "infrastructure.json" -SupervisorJson "supervisor.json"

# Check module version
Start-SimpleSupervisorDeploymentAtScale -Version
```

**EdgeSite Parameter Usage:**

The `-EdgeSite` parameter lets you target one or more edge sites from your infrastructure.json instead of processing all clusters. Use a comma-delimited list to deploy multiple sites (e.g. `-EdgeSite "site1,site2"`). This is useful for:

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

### Copy-SimpleSupervisorTemplates

Copies all required template files from the module installation directory to a specified destination.

**Parameters:**
- `DestinationPath` (String, optional) - Destination directory for template files. Default: Current working directory (`$PWD`)
- `WhatIf` (Switch) - Preview what would happen without actually copying files
- `Confirm` (Switch) - Prompt for confirmation before performing operations

**Examples:**

```powershell
# Copy templates to current directory
Copy-SimpleSupervisorTemplates

# Copy templates to specific directory
Copy-SimpleSupervisorTemplates -DestinationPath "./config"

# Preview what would be copied
Copy-SimpleSupervisorTemplates -WhatIf

# Copy with confirmation prompt
Copy-SimpleSupervisorTemplates -DestinationPath "./config" -Confirm
```

**Template Files Included:**
- `infrastructure.json` - Infrastructure configuration template
- `supervisor.json` - Supervisor cluster configuration template
- `argocd-deployment.yml` - ArgoCD deployment YAML template
- `1.1.0-25100889.yml` - ArgoCD operator package template

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
- ArgoCD operator and deployment settings

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

# Filter to show only tkgsComponentSpec related elements
Show-SupervisorJsonConfigurationHelp -Filter tkgsComponentSpec

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

Deployment is driven by two JSON inputs: `infrastructure.json` (vCenter, clusters, networking, storage, ArgoCD paths) and `supervisor.json` (supervisor sizing, load balancer, and network IP ranges). Each `edgeSite` in `infrastructure.json` `clusters[]` must have a matching `edgeSite` in `supervisor.json` `tkgsSiteSpec[]`.

### infrastructure.json

This file defines vCenter connection, datacenter, and shared naming prefixes; then one or more clusters, each with ESX hosts, storage type, networking segments, and ArgoCD paths. Many fields are **optional** and have defaults so you can omit them for a minimal config.

**Structure:**

- **`common`** – Settings used for all clusters (one vCenter, one datacenter, shared prefixes and content library). Prefixes and `esxUser` are optional; when omitted, defaults apply (see tables below).
- **`clusters`** – Array of cluster objects. Each cluster is identified by `edgeSite` (must match a site in `supervisor.json`). Per-cluster you define ESX hosts, storage type, network segments, and ArgoCD operator/deployment YAML paths.

**Important behavior:**

- **Uplinks:** There is no `numUplinks` field. The number of VDS uplinks is taken from the length of `nicList` (e.g. two NICs in `nicList` means two uplinks). **nicList** may be defined at **common** (applies to all clusters) or per **clusters[]** (cluster overrides common). At least one definition is mandatory: either `common.nicList` or `clusters[].nicList` for each cluster. When both are defined, the cluster value takes precedence. Effective list must have 2 or 4 NICs.
- **Storage:** Use `storagePolicy.storageType` (`VMFS`, `vSAN-ESA`, or `vSAN-OSA`). The tag catalog name can be omitted; it defaults to `{storageType}-Storage-TagCatalog` (e.g. `VMFS-Storage-TagCatalog`).
- **ArgoCD:** `supervisorServices.nameSpacePrefix` defaults to `argocd` if omitted. `supervisorServices.vmClass` is optional; when omitted, the script assigns all VM classes reported by vCenter to the ArgoCD namespace.
- **Network segment names** must be lower-case and RFC1123-compliant; they are matched to supervisor.json network references (case-sensitive).

**Required vs optional:** In the tables below, **Req** is **Yes** only when the value must be set for your environment; **No** means the field can be omitted and a default or derived value is used (described in the Notes column).

#### common

| Field | Req | Notes |
| ----- | --- | ----- |
| `vCenterName` | Yes | vCenter FQDN, 9.0 or later. Script needs HTTPS access. |
| `vCenterUser` | Yes | vCenter login (e.g. administrator@vsphere.local); SSO supported. |
| `vSanWitnessVmName` | No | vSAN witness VM name or FQDN; used by vSAN-OSA/ESA. |
| `esxUser` | No | ESX login. Omit to use default `root`. |
| `esxUniquePasswordPerHost` | No | Boolean. Default false when not defined (one password for all hosts). true = prompt per host. |
| `nonInteractivePassword` | No | Boolean. When true, uses VCENTER_COMMON_PASSWORD / ESX_COMMON_PASSWORD env vars. |
| `labEnvironment` | No | Boolean. When true, some vSAN health checks are relaxed. |
| `datacenterName` | Yes | Existing vSphere datacenter; clusters are created under it. |
| `clusterNamePrefix` | No | Prefix for cluster names. Omit for default `cluster`; format `{prefix}-{edgeSite}`. |
| `datastoreNamePrefix` | No | Prefix for datastore names. Omit for default `datastore`; format `{prefix}-{edgeSite}`. |
| `supervisorNamePrefix` | No | Prefix for supervisor names. Omit for default `supervisor`; format `{prefix}-{edgeSite}`. |
| `vdsNamePrefix` | No | Prefix for VDS names. Omit for default `VDS`; format `{prefix}-{edgeSite}`. |
| `supervisorContentLibraryDatastore` | No | When the key is present, datastore for supervisor content library (must already exist); script runs Initialize-SupervisorContentLibrary. When the key is omitted (removed) entirely, the content library workflow is skipped. |
| `supervisorContentLibrarySubscriptionUrl` | No | When `supervisorContentLibraryDatastore` key is present, subscription URL for the content library. If this key is omitted, default is `https://wp-content.vmware.com/supervisor/v1/latest/lib.json`. Only used when datastore key is present. |
| `vLcmImageName` | No | vLCM image name in vCenter Image Catalog; omit to choose at run time. |
| `vSanvMotionVmKernelMtuValue` | No | Optional. When defined, overrides the default MTU (9000) for the VDS and for vMotion/vSAN VMkernel adapters only. Mgmt (vmk0) and vSAN Witness (vmk3) are always 1500. Must be a number between 1500 and 9190 (numbers only; validated at JSON load). Use 1500 when the physical path does not support jumbo frames. |
| `nicList` | Conditional | Array of NICs for the VDS (e.g. `[{"name":"vmnic1"},{"name":"vmnic2"}]`). Number of uplinks = length of nicList. Required at common or per cluster; cluster overrides common. Must have 2 or 4 NICs. |
| `contextName` | Yes | VCF context name used by VCF CLI for ArgoCD. |

#### clusters[] (each element)

| Field | Req | Notes |
| ----- | --- | ----- |
| `edgeSite` | Yes | Unique site ID; must match one `tkgsSiteSpec[].edgeSite` in supervisor.json. |
| `nicList` | Conditional | Optional override for this cluster. When present (2 or 4 NICs), overrides `common.nicList`. At least one of `common.nicList` or `clusters[].nicList` must be defined per cluster. |
| `esxHosts` | Yes | Array of ESX FQDNs or IPs; script needs HTTPS access to each host. |
| `supervisorServices.argoCdOperatorYamlPath` | Yes | Path to ArgoCD operator YAML (escape backslashes on Windows). |
| `supervisorServices.argoCdDeploymentYamlPath` | Yes | Path to ArgoCD instance YAML; namespace in file must match `nameSpacePrefix`. |
| `supervisorServices.nameSpacePrefix` | No | ArgoCD namespace prefix. Omit for default `argocd`; script appends cluster MoRef for uniqueness. |
| `supervisorServices.vmClass` | No | Array of VM class names for ArgoCD namespace. Omit to assign all VM classes from vCenter. |
| `storagePolicy.storagePolicyTagCatalog` | No | Tag catalog for storage policy. Omit for default `{storageType}-Storage-TagCatalog`. |
| `storagePolicy.storageType` | Yes | Storage type: `VMFS`, `vSAN-ESA`, or `vSAN-OSA`. |
| `networking.networkSegments` | Yes | Array of segments; names must match supervisor.json network references. |
| `networking.networkSegments[].name` | Yes | Segment name; lower-case, RFC1123; must match supervisor.json. |
| `networking.networkSegments[].vlanId` | Yes | VLAN ID (0–4095); unique within this cluster. |
| `networking.networkSegments[].gateway` | Yes | Gateway in CIDR (e.g. `10.30.10.1/24`); mapped into supervisor by segment name. |
| `networking.networkingVmKernelInterfaces` | Conditional | **Required for vSAN-ESA and vSAN-OSA only** (not VMFS). At least two entries: **vMotion**, **vSAN** (required). Optional third: **vSAN Witness**. When vSAN Witness is omitted, mgmt (vmk0) is tagged with vSAN witness traffic in addition to mgmt; when present, a dedicated witness VMkernel (vmk3) is created. Each entry: `service`, `vlanId` (0–4095), `netmask` (valid IPv4 netmask), `ipList` (exactly two unique IPv4s, one per host). Only the **vSAN Witness** entry requires `gateway` (VMkernel interfaces are not configured with a gateway by the script). |

**Configuration Help:** Run `Show-InfrastructureJsonConfigurationHelp` to view the full reference (Key, Required, Notes). Use `-Format List` for narrow screens, `-Format Table` for wide; `-Filter` for wildcard search on keys.

### supervisor.json

Top-level keys: `commonSupervisorSpec` (shared supervisor and FLB settings) and `tkgsSiteSpec` (array of per-site config). Each `tkgsSiteSpec[].edgeSite` must match one `clusters[].edgeSite` in `infrastructure.json`.

The following are **script parameters** (not in supervisor JSON) with fixed defaults: `flbProvider` (VSPHERE_FOUNDATION), `flbNetworkIpAssignmentMode`, `tkgsPrimaryWorkloadIpAssignmentMode`, `tkgsMgmtIpAssignmentMode` (all STATIC), and FLB network personas (management: Management; virtual server: FRONTEND, WORKLOAD). See `Add-Supervisor` and `Get-SupervisorConfigurationFromJson` help.

#### commonSupervisorSpec

| Field | Req | Notes |
| ----- | --- | ----- |
| `controlPlaneVMCount` | No | `1` or `3`. |
| `controlPlaneSize` | No | `TINY`, `SMALL`, `MEDIUM`, or `LARGE`. |
| `flbAvailability` | No | `SINGLE_NODE` or `ACTIVE_PASSIVE`. |
| `flbSize` | No | `SMALL`, `MEDIUM`, `LARGE`, or `X-LARGE`. |
| `flbNetworkType` | No | Use `DVPG`. |
| `networkSearchDomains` | Yes | Array of DNS search domains. |
| `networkNtpServers` | Yes | Array of NTP servers. |
| `dnsServers` | Yes | Array of DNS servers. |

#### tkgsSiteSpec[] (each element)

| Field | Req | Notes |
| ----- | --- | ----- |
| `edgeSite` | Yes | Must match `infrastructure.json` `clusters[].edgeSite`. |
| `foundationLoadBalancerComponents.flbName` | No | FLB name for this site. |
| `foundationLoadBalancerComponents.flbVipStartIP` | Yes | Start IP for FLB virtual IP range. |
| `foundationLoadBalancerComponents.flbVipIPCount` | Yes | Count of VIPs from flbVipStartIP. |
| `foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName` | No | Must match infra `networkSegments[].name`; gateway from infra. |
| `foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp` | Yes | Start IP for FLB management network. |
| `foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount` | Yes | IP count for FLB management. |
| `foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkGateway` | No | Override gateway (otherwise from infra by name). |
| `foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName` | No | Match infra segment name; gateway from infra. |
| `foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp` | Yes | Start IP for FLB virtual server network. |
| `foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount` | No | IP count; default may be used. |
| `foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkGateway` | No | Override gateway (otherwise from infra by name). |
| `tkgsMgmtNetworkSpec.tkgsMgmtNetworkName` | No | Must match infra segment name. |
| `tkgsMgmtNetworkSpec.tkgsMgmtNetworkStartingIp` | Yes | Start IP for VKS management network. |
| `tkgsMgmtNetworkSpec.tkgsMgmtNetworkIPCount` | Yes | IP count for VKS management. |
| `tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkName` | No | Must match infra segment name. |
| `tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkStartingIp` | Yes | Start IP for workload VIP range. |
| `tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkIPCount` | Yes | IP count for workload VIP range. |
| `tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceStartIp` | Yes | Start IP for workload service range. |
| `tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceCount` | No | Count (e.g. 256 or 512); must occupy full CIDR. |

**Configuration Help**: Run `Show-SupervisorJsonConfigurationHelp` to view the full reference (Key, Required, Notes). Use `-Format List` for narrow screens or `-Format Table` for wide; `-Filter` for wildcard search on keys.

# Logging

The module provides comprehensive logging with multiple levels:

- **DEBUG**: Detailed diagnostic information for troubleshooting
- **INFO**: General informational messages about deployment progress
- **ADVISORY**: Important notices that don't indicate problems
- **WARNING**: Warning messages about potential issues
- **EXCEPTION**: Caught exceptions that were handled
- **ERROR**: Error messages indicating failures

Log files are created in the `logs` subdirectory with the naming pattern:
```
logs/SimpleSupervisorDeploymentAtScale-YYYY-MM-DD.log
```

## Troubleshooting

### Template Files Not Found

If `Copy-SimpleSupervisorTemplates` cannot find template files:

```powershell
# Check module installation path
(Get-Module -Name SimpleSupervisorDeploymentAtScale -ListAvailable).ModuleBase

# Verify templates exist
Test-Path "$((Get-Module SimpleSupervisorDeploymentAtScale -ListAvailable).ModuleBase)\Templates"
```

### Module Not Found

If the module is not recognized:

```powershell
# Check if module is installed
Get-Module -Name SimpleSupervisorDeploymentAtScale -ListAvailable

# Check module path
$env:PSModulePath

# Reinstall if needed
Install-Module -Name SimpleSupervisorDeploymentAtScale -Force
```

### Deployment Failures

1. **Enable DEBUG logging**: `Start-SimpleSupervisorDeploymentAtScale -LogLevel DEBUG`
2. **Check log files**: Review `logs/SimpleSupervisorDeploymentAtScale-*.log`
3. **Validate JSON files**: Ensure configuration files are valid JSON
4. **Verify prerequisites**: Confirm VCF.PowerCLI, kubectl, and vcf CLI are available

### Cleanup: Management Restore or VDS Removal Fails

Cleanup no longer requires `clusters.networking.temporaryManagementIp`. Management (vmk0) is moved from the VDS to a standard switch programmatically using the same API as vCenter’s **Migrate VMkernel Adapter** wizard. If that fails, the script reports the error and instructs you to move vmk0 manually in vCenter, then re-run cleanup.

If cleanup reports "could not remove any pNIC from VDS" (vSphere rolled back to avoid disconnecting the host) or "Port group mgmt is in use":

1. In vCenter go to **Host → Configure → Networking → VMkernel adapters** for each host in the cluster.
2. Edit **vmk0** and change its port group from the distributed "mgmt" port group to a standard switch (e.g. create a temporary vSwitch with one pNIC and a Management port group, or use an existing standard switch).
3. Save so vmk0 is on a standard switch on all hosts.
4. Re-run cleanup with the same parameters (e.g. `-EdgeSite site2 -CleanUp Compute -Force`). With management off the VDS, cleanup will skip restore and remove the VDS and cluster.

### Common Issues

- **"Templates directory not found"**: Reinstall the module or verify FileList in manifest
- **"Required template files not found"**: Run `Copy-SimpleSupervisorTemplates` to verify files exist
- **"Unable to determine module installation path"**: Ensure module is properly installed via `Install-Module`

## Requirements

### PowerShell Module Dependencies

- **VCF.PowerCLI** (Version 9.0 or later)
  ```powershell
  Install-Module -Name VCF.PowerCLI -MinimumVersion 9.0
  ```

### External Tools

- **kubectl**: Required for ArgoCD operations
- **vcf CLI**: Required for supervisor management operations

### Environment

- VMware Cloud Foundation 9.x
- vCenter Server with administrative access
- ESX hosts in connected state
- Network connectivity to vCenter and ESX hosts

## Version History

See [CHANGELOG.md](CHANGELOG.md) for detailed version history.

### Version 1.0.0.3 (Current)
- Added `Copy-SimpleSupervisorTemplates` function for template file management
- Added `Show-InfrastructureJsonConfigurationHelp` and `Show-SupervisorJsonConfigurationHelp` helper functions for configuration reference
- Included all template files in module package
- Enhanced path resolution for various installation scenarios
- Improved WhatIf support and user experience

### Version 1.0.0.2
- Significant reliability and performance improvements
- Cross-platform compatibility fixes
- Enhanced error handling and logging

## Contributing

This module is maintained by Broadcom. For issues, feature requests, or contributions, please refer to the project repository.

## License

Copyright (c) 2025 Broadcom. All Rights Reserved.

See the module manifest or LICENSE file for full license details.

## Support

For support and documentation:
- **Project Repository**: [GitHub Repository](https://github.com/vmware/powershell-module-for-simple-supervisor-deployment-at-scale)
- **Documentation**: See module help: `Get-Help Start-SimpleSupervisorDeploymentAtScale -Full`
- **VMware Cloud Foundation Documentation**: [VCF Documentation](https://techdocs.broadcom.com/us/en/vmware-cloud-foundation.html)

## Related Resources

- [VMware Cloud Foundation Documentation](https://techdocs.broadcom.com/us/en/vmware-cloud-foundation.html)
- [Single-Node vSphere Supervisor Design Guidance](https://blogs.vmware.com/cloud-foundation/2025/07/14/modernizing-your-edge-with-single-node-vsphere-supervisor-in-vmware-cloud-foundation-9-0/)
- [ArgoCD Service Documentation](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/using-argo-cd-service/argocd-custom-resrouce-reference.html)


## Execution Steps

### 1. Install VCF.PowerCLI Module

Install the required PowerCLI module for VCF.

### 2. Download Script Files

Download the provided zip file. The downloaded file has the following structure:

- `SimpleSupervisorDeploymentAtScale.psd1` and `SimpleSupervisorDeploymentAtScale.psm1` comprise the powershell module
- `1.1.0-25100889.yml` is the ArgoCD Operator YAML file supplied by Broadcom
- `infrastructure.json`, `supervisor.json` and `argocd-deployment.yml` are parameter templates that require updating to align with your edge environment
  - `infrastructure.json` contains vSphere configuration details
  - `supervisor.json` contains Supervisor networking, availability and sizing parameters
  - `argocd-deployment.yml` is the ArgoCD instance YAML that defines ArgoCD resource deployment

### 3. Configure argocd-deployment.yml

Open `argocd-deployment.yml` and populate the fields with the details required to run ArgoCD instances to manage your edge application. Follow ArgoCD Instance configuration details in the provided documentation as reference.

**Important:** The namespace value specified in `argocd-deployment.yml` should match the namespace value in `infrastructure.json`. During deployment, the script will automatically modify the namespace in the YAML file to ensure uniqueness by appending the cluster MoRef identifier (e.g., if you specify `argocd` in both files, it will become `argocd-c462` where `c462` is the cluster identifier). This prevents namespace conflicts when deploying multiple supervisor clusters on the same vCenter.

### 4. Configure infrastructure.json

Open `infrastructure.json` and review all the fields, updating as required for your environment. **Accuracy here is crucial for successful deployment.**

**Quick Reference**: Use the built-in helper function to view the configuration reference table:
```Powershell
# Auto-detects best format based on terminal width
Show-InfrastructureJsonConfigurationHelp

# Or specify format explicitly
Show-InfrastructureJsonConfigurationHelp -Format List    # For narrow screens
Show-InfrastructureJsonConfigurationHelp -Format Table     # For wide screens
Show-InfrastructureJsonConfigurationHelp -Format GridView # Interactive (Windows only)
```

Alternatively, refer to the table in `Admin.Guide.Single.Node.Supervisor.rtf` for detailed configuration guidance.

### 5. Configure supervisor.json

Open `supervisor.json` and review all the fields, updating as required for your environment.

**Quick Reference**: Use the built-in helper function to view the configuration reference table:
```Powershell
# Auto-detects best format based on terminal width
Show-SupervisorJsonConfigurationHelp

# Or specify format explicitly
Show-SupervisorJsonConfigurationHelp -Format List    # For narrow screens
Show-SupervisorJsonConfigurationHelp -Format Table     # For wide screens
Show-SupervisorJsonConfigurationHelp -Format GridView # Interactive (Windows only)
```

Alternatively, refer to the table in `Admin.Guide.Single.Node.Supervisor.rtf` for detailed configuration guidance.

### 6. Argo CD Operator YAML Download (Optional)

Download the necessary YAML file for Argo CD operator creation by following the instructions in the provided documentation.

### 7. Install vcf-cli Plugin

- Follow the installation guide at the official VMware documentation site
- **Important:** After installation, rename file `vcf.exe` on Windows or `vcf` on MacOS or Linux


## Important Notes

- **Network Configuration**: The automation currently creates a supervisor with four networks: one for management, one for workload, and two for load balancer. The `infrastructure.json` file expects four VLAN IDs for the virtual distributed switch section accordingly. While there are options to reduce network usage by reusing resource pools, this script adheres to the four-network design as per the linked design documents.

- **CLI Plugin Availability**: For a fully automated end-to-end process, it is required that VCF-CLI and KUBECTL are available on your testbed *before* running this script. Refer to step 7 for VCF CLI installation. Kubectl can be downloaded from upstream at: https://kubernetes.io/docs/tasks/tools/

- **Supported Environment**: This script has been tested and validated on the Mac and Windows platforms. Ensure your execution environment matches this specification for optimal performance and compatibility.
