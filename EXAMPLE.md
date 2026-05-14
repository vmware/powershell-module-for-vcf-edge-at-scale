# Usage Examples

## Manual installation of module

```Powershell
$tempDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString()))
$fullPath = Join-Path -Path $tempDir -ChildPath "VcfEdgeAtScale.zip"
Invoke-WebRequest -Uri "https://github.com/vmware/powershell-module-for-vcf-edge-at-scale/releases/latest/download/VcfEdgeAtScale.zip" -OutFile $fullPath
Expand-Archive -Path $fullPath -DestinationPath $tempDir
cd $tempDir
pwsh -ExecutionPolicy Bypass -File .\Install-VcfEdgeAtScaleModule.ps1
PS C:\Users\Administrator\AppData\Local\Temp\518be7b1-f3a2-47cc-928a-9f34d15c13a3> pwsh -Executionpolicy Bypass -File .\Install-VcfEdgeAtScaleModule.ps1

VcfEdgeAtScale Module Installer
================================

PREREQUISITE: VCF.PowerCLI 9.0 or newer must be installed before importing this module.

Source      : PS C:\Users\Administrator\AppData\Local\Temp\518be7b1-f3a2-47cc-928a-9f34d15c13a3
Destination : C:\Users\Administrator\Documents\PowerShell\Modules\VcfEdgeAtScale

  Copying VcfEdgeAtScale.psd1...
  Copying VcfEdgeAtScale.psm1...
  Copying PSScriptAnalyzerSettings.psd1...
  Copying Private...
  Copying Templates...
  Copying Tools...
Unblocking installed module files (Windows execution policy)...

Validating module manifest...
Importing module into current session...
          Welcome to VCF PowerCLI!

Log in to a vCenter Server or ESX host:              Connect-VIServer
To find out what commands are available, type:       Get-VICommand
To show searchable help for all PowerCLI commands:   Get-PowerCLIHelp
Once you've connected, display all virtual machines: Get-VM
If you need more help, visit the PowerCLI community: Get-PowerCLICommunity

       Copyright (c) Broadcom. All Rights Reserved.


  Module loaded (version 1.0.3.1006).

Auto-load on every session
  Add the following line to your PowerShell profile (C:\Users\Administrator\Documents\PowerShell\Microsoft.PowerShell_profile.ps1):
    Import-Module VcfEdgeAtScale

Add this line to your profile now? (Y/N, Enter=no): Y
Added 'Import-Module VcfEdgeAtScale' to C:\Users\Administrator\Documents\PowerShell\Microsoft.PowerShell_profile.ps1.
  The module will load automatically in every new PowerShell session.

Installation complete.
  Start-VcfEdgeAtScale -Initialize
```

## Example of initializing the script's configuration directory

```Powershell
PS C:\Users\Administrator> start-VcfEdgeAtScale -Initialize

VcfEdgeAtScale initialize
  Mode: full — configuration base, Logs, ServicesYaml, Docs, optional JSON seed/replace.

  Note: $env:VcfEdgeatScaleRootDirectory pointed at a path that does not exist:
    C:\Users\Administrator\VCFEdgeAtScale
  Stale value cleared from session and user environment. Choose a folder below.

  Default base directory:  C:\Users\Administrator\VCFEdgeAtScale

Press Enter to use the default, or type a full directory path:

  Supervisor service YAML (ServicesYaml)
    Copied: 1.1.0-25100889.yml
    Copied: argocd-deployment.yml
    Copied: harbor-data-values-v2.14.2.yml
    Copied: legacy-harbor-svs-v2.14.2+vmware.2-vks.1-25220498.yml

  Documentation (Docs)
    Copied: EXAMPLE.rtf
    Copied: README.rtf
    Updated: infrastructure-config-help.json
    Updated: supervisor-config-help.json

  Tools
    Copied: veas-json-generator.py  (run: python "C:\Users\Administrator\VCFEdgeAtScale\Tools\veas-json-generator.py")
    Copied: veas-ui.html

  Root JSON files
    Wrote infrastructure.json (common.supervisorServices.parentDirectory -> ServicesYaml; harborConfiguration.parentDirectory -> base directory).
    Copied supervisor.json to deployment root.

=== Initialize summary ===
  Deployment root: C:\Users\Administrator\VCFEdgeAtScale
  Base directory: created (it did not exist before).
  Subdirectories created: Docs, Logs, ServicesYaml, Tools.
  See sections above for YAML, Docs, Tools, and JSON actions.
  Optional Docs/Tools sources may show WARNING if your module install is missing files.
  Root JSON: created or refreshed per your answers above.
  VcfEdgeatScaleRootDirectory -> C:\Users\Administrator\VCFEdgeAtScale (session + user environment persisted).

  Next step: customize infrastructure.json and supervisor.json.
  Option 1 — Direct JSON editing:
    Open infrastructure.json and supervisor.json in any text editor.
    Run 'Start-VcfEdgeAtScale -ValidateOnly' to validate before deploying.
  Option 2 — Browser-based UI:
    python "C:\Users\Administrator\VCFEdgeAtScale\Tools\veas-json-generator.py"
```

## Show parameters for Start-VcfEdgeAtScale

```Powershell
PS C:\Users\Administrator>  Start-VcfEdgeAtScale -?

NAME
    Start-VcfEdgeAtScale

SYNOPSIS
    Automates end-to-end vSphere Supervisor edge deployment at scale in VMware Cloud Foundation 9.x.


SYNTAX
    Start-VcfEdgeAtScale [-AcceptBadCheckResults] [-CheckForUpdates] [[-CleanUp] <String>] [-CollectLogs]
    [-ComputeOnly] [[-DelayBeforeAddingNextHostSeconds] <Int32>] [[-EdgeSite] <String>] [-Force] [-Initialize]
    [-InitializeTemplatesOnly] [[-InfrastructureJson] <String>] [[-LogLevel] <String>] [[-RollbackOnFailure]
    <Nullable`1>] [-SaveHarborYaml] [[-SupervisorJson] <String>] [-ValidateOnly] [-Version] [<CommonParameters>]


DESCRIPTION
    Start-VcfEdgeAtScale orchestrates vSphere Supervisor cluster preparation and deployment in
    VMware Cloud Foundation (VCF) 9.x environments. The function handles the deployment workflow including:

    - vCenter and ESX host connection
    - ESX Cluster creation and host add
    - Datastore creation and storage policy configuration.
    - Virtual Distributed Switch (VDS) setup and port group configuration
    - vSphere Supervisor Deployment
    - ArgoCD installation and configuration for GitOps workflows

    For normal runs (not -Version or -Initialize), the environment variable VcfEdgeatScaleRootDirectory must
    point at your configuration base directory. Defaults for -InfrastructureJson and -SupervisorJson join that
    directory with infrastructure.json and supervisor.json when you omit those parameters. Logs are written
    under Join-Path(VcfEdgeatScaleRootDirectory, "Logs"). Use Start-VcfEdgeAtScale -Initialize to create or
    refresh the recommended layout from module Templates (new or existing base directory; use
    -Initialize -InitializeTemplatesOnly to refresh only ServicesYaml and Docs without changing root JSON).
    Use Start-VcfEdgeAtScale -CollectLogs to zip infrastructure.json, supervisor.json, Logs, and ServicesYaml for
    support (interactive prompts).


RELATED LINKS

REMARKS
    To see the examples, type: "Get-Help Start-VcfEdgeAtScale -Examples"
    For more information, type: "Get-Help Start-VcfEdgeAtScale -Detailed"
    For technical information, type: "Get-Help Start-VcfEdgeAtScale -Full"

```

## Show Supervisor Configuration Options

```Powershell
PS C:\Users\Administrator> Show-SupervisorJsonConfigurationHelp


[INFO] ========================================================================================================================
[INFO] Supervisor.json Configuration Reference
[INFO] ========================================================================================================================

Key                                                                                               Required Notes
---                                                                                               -------- -----
commonSupervisorSpec.controlPlaneVMCount                                                          Yes      1 or 3. Shallow validation requires the key; values follow platform rules.
commonSupervisorSpec.controlPlaneSize                                                             Yes      TINY, SMALL, MEDIUM, or LARGE.
commonSupervisorSpec.flbAvailability                                                              Yes      SINGLE_NODE or ACTIVE_PASSIVE.
commonSupervisorSpec.flbSize                                                                      Yes      SMALL, MEDIUM, LARGE, or X-LARGE.
commonSupervisorSpec.flbNetworkType                                                               Yes      Use DVPG.
commonSupervisorSpec.networkSearchDomains                                                         Yes      Array of DNS search domains.
commonSupervisorSpec.networkNtpServers                                                            Yes      Array of NTP servers.
commonSupervisorSpec.dnsServers                                                                   Yes      Array of DNS servers.
siteSpec                                                                                          Yes      Array of site-specific supervisor configurations. Each entry is linked to infrastructure.json clusters[]
                                                                                                           via edgeSite.
siteSpec[].edgeSite                                                                               Yes      Must match infrastructure.json clusters[].edgeSite.
siteSpec[].foundationLoadBalancerComponents.flbName                                               Yes      FLB name for this site.
siteSpec[].foundationLoadBalancerComponents.flbVipStartIP                                         Yes      Start IP for FLB virtual IP range.
siteSpec[].foundationLoadBalancerComponents.flbVipIPCount                                         Yes      Count of VIPs from flbVipStartIP.
siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName                   Yes      Must match infra networkSegments[].name; gateway from infra unless flbNetworkGateway is set.
siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp    Yes      Start IP for FLB management network.
siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount         Yes      IP count for FLB management.
siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkGateway                No       Override gateway (otherwise from infra by name).
siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName                Yes      Must match infra segment name; gateway from infra unless flbNetworkGateway is set.
siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp Yes      Start IP for FLB virtual server network.
siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount      Yes      IP count for the FLB virtual-server network range; required by shallow validation (e.g. match segment
                                                                                                           size).
siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkGateway             No       Override gateway (otherwise from infra by name).
siteSpec[].mgmtNetworkSpec.mgmtNetworkName                                                        Yes      Must match infra segment name.
siteSpec[].mgmtNetworkSpec.mgmtNetworkStartingIp                                                  Yes      Start IP for VKS management network.
siteSpec[].mgmtNetworkSpec.mgmtNetworkIPCount                                                     Yes      IP count for VKS management.
siteSpec[].primaryWorkloadNetwork.primaryWorkloadNetworkName                                      Yes      Must match infra segment name.
siteSpec[].primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp                                Yes      Start IP for workload VIP range.
siteSpec[].primaryWorkloadNetwork.primaryWorkloadNetworkIPCount                                   Yes      IP count for workload VIP range.
siteSpec[].primaryWorkloadNetwork.workloadServiceStartIp                                          Yes      Start IP for workload service range.
siteSpec[].primaryWorkloadNetwork.workloadServiceCount                                            Yes      Count (e.g. 256 or 512); must occupy full CIDR. Shallow validation requires this key.
```

## Show Infrastructure Configuration Options

```Powershell
PS C:\Users\Administrator> Show-InfrastructureJsonConfigurationHelp


[INFO] ========================================================================================================================
[INFO] Infrastructure.json Configuration Reference
[INFO] ========================================================================================================================

Key                                                          Required    Notes
---                                                          --------    -----
common.vCenterName                                           Yes         vCenter FQDN, 9.0 or later. Script needs HTTPS access.
common.vCenterUser                                           Yes         vCenter login (e.g. administrator@vsphere.local); SSO supported.
common.datacenterName                                        Yes         Existing vSphere datacenter; clusters are created under it.
common.contextName                                           Yes         VCF context name used by VCF CLI for ArgoCD.
common.nicList                                               Conditional Array of NICs for the VDS (e.g. [{"name":"vmnic1"},{"name":"vmnic2"}]). Number of uplinks = length of nicList. Required at common or per
                                                                         cluster (clusters[].nicList); cluster overrides common. Must have 2 or 4 NICs.
common.vSanWitnessVmName                                     No          vSAN witness VM name or FQDN; used by vSAN-OSA/ESA. Overridable per cluster.
common.haPolicy                                              No          vSAN-OSA/ESA multi-host only: reservationBased (default when key omitted; percentage admission), slotBased (host failures tolerated = 1),
                                                                         or disabled (HA on, admission off). When the key exists, value must be exactly one of those three strings. Overridable per cluster.
common.esxUser                                               No          ESX login. Omit to use default root.
common.esxUniquePasswordPerHost                              No          Boolean. Default false when not defined (one password for all hosts). true = prompt per host.
common.nonInteractivePassword                                No          Boolean. When true, uses VCENTER_COMMON_PASSWORD / ESX_COMMON_PASSWORD env vars.
common.labenvironment                                        No          Boolean lab mode (property name is case-insensitive in JSON; templates use labenvironment). Relaxes some gates; Harbor TLS may be omitted
                                                                         when true.
common.clusterNamePrefix                                     No          Prefix for cluster names. Omit for default cluster; format {prefix}-{edgeSite}.
common.datastoreNamePrefix                                   No          Prefix for datastore names. Omit for default datastore; format {prefix}-{edgeSite}.
common.supervisorNamePrefix                                  No          Prefix for supervisor names. Omit for default supervisor; format {prefix}-{edgeSite}.
common.vdsNamePrefix                                         No          Prefix for VDS names. Omit for default VDS; format {prefix}-{edgeSite}.
common.supervisorContentLibraryDatastore                     No          When the key is present, datastore for supervisor content library (must already exist); script runs Initialize-SupervisorContentLibrary.
                                                                         When the key is omitted (removed) entirely, the content library workflow is skipped.
common.supervisorContentLibrarySubscriptionUrl               No          When supervisorContentLibraryDatastore key is present, subscription URL for the content library. If omitted, default is
                                                                         https://wp-content.vmware.com/supervisor/v1/latest/lib.json.
common.vLcmImageName                                         No          vLCM image name in vCenter Image Catalog; omit to choose at run time.
common.vSanvMotionVmKernelMtuValue                           No          Optional. When defined, overrides the default MTU (9000) for the VDS and for vMotion/vSAN VMkernel adapters only. Mgmt (vmk0) and vSAN
                                                                         Witness (vmk3) are always 1500. Must be 1500-9190 (numbers only; validated at JSON load). Use 1500 when the physical path does not support
                                                                         jumbo frames.
common.vmkernelMtu                                           No          Optional. Legacy. MTU (1500-9190) for VDS and vMotion/vSAN VMkernels when common.vSanvMotionVmKernelMtuValue is not set. Mgmt and vSAN
                                                                         Witness are always 1500.
common.supervisorServices.parentDirectory                    Conditional Directory containing Argo CD and Harbor YAML files when using *YamlFileName keys (escape backslashes on Windows). Not required if every
                                                                         Argo- or Harbor-enabled cluster resolves YAML via legacy *YamlPath properties at common or cluster level. When set with a file name, paths
                                                                         are Join-Path(parentDirectory, *YamlFileName).
common.supervisorServices.argoCdOperatorYamlFileName         Conditional File name only (e.g. 1.1.0-25100889.yml) under parentDirectory for the Argo CD operator package. Use with parentDirectory, or use
                                                                         common.supervisorServices.argoCdOperatorYamlPath instead. Ignored when disableArgoCD is true.
common.supervisorServices.argoCdDeploymentYamlFileName       Conditional File name only under parentDirectory for the Argo CD instance YAML; namespace in file must match nameSpacePrefix. Use with
                                                                         parentDirectory, or use common.supervisorServices.argoCdDeploymentYamlPath instead. Ignored when disableArgoCD is true.
common.supervisorServices.disableArgoCD                      No          Boolean. When true, skips ArgoCD deployment (service, namespace, operator, instance) for all clusters. Cluster-level override wins.
                                                                         Default: false.
common.supervisorServices.disableHarbor                      No          Boolean. When true, skips Harbor deployment (service registration, data values generation, installation) for all clusters. Cluster-level
                                                                         override wins. Default: false.
common.supervisorServices.harborDataTemplateYamlFileName     Conditional File name only (e.g. harbor-data-values-v2.14.2.yml) under parentDirectory for the Harbor data values template. The script creates a
                                                                         per-site copy at runtime; the original is never modified. Use with parentDirectory, or use
                                                                         common.supervisorServices.harborDataTemplateYamlPath instead. Not required when disableHarbor is true for all clusters.
common.supervisorServices.harborServiceYamlFileName          Conditional File name only for the Harbor Supervisor Service Carvel package YAML (e.g. legacy-harbor-svs-v2.14.2+vmware.2-vks.1-25220498.yml) under
                                                                         parentDirectory. Use with parentDirectory, or use common.supervisorServices.harborServiceYamlPath instead. Not required when disableHarbor
                                                                         is true for all clusters.
common.supervisorServices.argoCdOperatorYamlPath             Conditional Legacy full or infrastructure-relative path to the Argo CD operator package YAML. Used when parentDirectory and argoCdOperatorYamlFileName
                                                                         do not both resolve (cluster overrides common). Ignored when disableArgoCD is true.
common.supervisorServices.argoCdDeploymentYamlPath           Conditional Legacy full or infrastructure-relative path to the Argo CD instance YAML. Used when parentDirectory and argoCdDeploymentYamlFileName do
                                                                         not both resolve (cluster overrides common). Ignored when disableArgoCD is true.
common.supervisorServices.harborDataTemplateYamlPath         Conditional Legacy full or infrastructure-relative path to the Harbor data values template YAML. Used when parentDirectory and
                                                                         harborDataTemplateYamlFileName do not both resolve (cluster overrides common). Not required when disableHarbor is true for all clusters.
common.supervisorServices.harborServiceYamlPath              Conditional Legacy full or infrastructure-relative path to the Harbor Supervisor Service Carvel package YAML. Used when parentDirectory and
                                                                         harborServiceYamlFileName do not both resolve (cluster overrides common). Not required when disableHarbor is true for all clusters.
clusters                                                     Yes         Array of cluster configurations. Each cluster is identified by edgeSite and contains ESX hosts, supervisor services, storage policy, and
                                                                         networking.
clusters[].edgeSite                                          Yes         Unique site ID; must match one siteSpec[].edgeSite in supervisor.json.
clusters[].esxHosts                                          Yes         Array of ESX FQDNs or IPs; script needs HTTPS access to each host.
clusters[].networking                                        Yes         Container for networkSegments and (for vSAN) networkingVmKernelInterfaces. Required by shallow validation.
clusters[].storagePolicy                                     Yes         Container for storage type and tag catalog. Required by shallow validation.
clusters[].nicList                                           Conditional Optional override for this cluster. When present (2 or 4 NICs), overrides common.nicList. At least one of common.nicList or
                                                                         clusters[].nicList must be defined per cluster.
clusters[].vSanWitnessVmName                                 Conditional vSAN witness VM name or FQDN for this cluster. Overrides common.vSanWitnessVmName. Required (at cluster or common level) for vSAN-OSA and
                                                                         vSAN-ESA; not used for VMFS.
clusters[].haPolicy                                          No          Overrides common.haPolicy for this cluster. Same allowed values and vSAN-only scope as common.haPolicy. When the key exists, value must be
                                                                         reservationBased, slotBased, or disabled.
clusters[].supervisorServices.parentDirectory                No          Override directory for this cluster’s supervisorServices YAML files. When set, used instead of common.supervisorServices.parentDirectory
                                                                         for Join-Path with *YamlFileName keys. Omit to use common parentDirectory or legacy *YamlPath resolution.
clusters[].supervisorServices.argoCdOperatorYamlFileName     Conditional Overrides common.supervisorServices.argoCdOperatorYamlFileName for this cluster when defined. Use with parentDirectory, or use
                                                                         clusters[].supervisorServices.argoCdOperatorYamlPath instead. Ignored when disableArgoCD is true.
clusters[].supervisorServices.argoCdDeploymentYamlFileName   Conditional Overrides common.supervisorServices.argoCdDeploymentYamlFileName for this cluster when defined. Use with parentDirectory, or use
                                                                         clusters[].supervisorServices.argoCdDeploymentYamlPath instead. Ignored when disableArgoCD is true.
clusters[].supervisorServices.harborDataTemplateYamlFileName Conditional Overrides common.supervisorServices.harborDataTemplateYamlFileName for this cluster when defined. Use with parentDirectory, or use
                                                                         clusters[].supervisorServices.harborDataTemplateYamlPath instead. Ignored when disableHarbor is true.
clusters[].supervisorServices.harborServiceYamlFileName      Conditional Overrides common.supervisorServices.harborServiceYamlFileName for this cluster when defined. Use with parentDirectory, or use
                                                                         clusters[].supervisorServices.harborServiceYamlPath instead. Ignored when disableHarbor is true.
clusters[].supervisorServices.argoCdOperatorYamlPath         Conditional Per-cluster legacy path to the Argo CD operator YAML; overrides common when set. Used when parentDirectory and argoCdOperatorYamlFileName
                                                                         do not both resolve. Ignored when disableArgoCD is true.
clusters[].supervisorServices.argoCdDeploymentYamlPath       Conditional Per-cluster legacy path to the Argo CD instance YAML; overrides common when set. Ignored when disableArgoCD is true.
clusters[].supervisorServices.harborDataTemplateYamlPath     Conditional Per-cluster legacy path to the Harbor data values template YAML; overrides common when set. Ignored when disableHarbor is true.
clusters[].supervisorServices.harborServiceYamlPath          Conditional Per-cluster legacy path to the Harbor Carvel package YAML; overrides common when set. Ignored when disableHarbor is true.
clusters[].supervisorServices.disableArgoCD                  No          Boolean. Overrides common.supervisorServices.disableArgoCD for this cluster only. When true, skips ArgoCD deployment for this cluster.
                                                                         Default: false.
clusters[].supervisorServices.disableHarbor                  No          Boolean. Overrides common.supervisorServices.disableHarbor for this cluster only. When true, skips Harbor deployment for this cluster.
                                                                         Default: false.
clusters[].supervisorServices.nameSpacePrefix                No          ArgoCD namespace prefix. Omit for default argocd; script appends cluster MoRef for uniqueness.
clusters[].supervisorServices.vmClass                        No          Array of VM class names for ArgoCD namespace. Omit to assign all VM classes from vCenter.
clusters[].harborConfiguration.hostname                      Conditional Required unless disableHarbor is true. DNS-compatible FQDN or IP for the Harbor registry (e.g. harbor.site1.example.com). Sets the
                                                                         hostname key in the Harbor data values YAML.
clusters[].harborConfiguration.harborAdminPassword           No          Override for the Harbor admin password. Prefix with $env: to resolve from an environment variable at runtime. If the variable is unset,
                                                                         the script prompts interactively (masked input) during pre-flight.
clusters[].harborConfiguration.secretKey                     No          AES-128 encryption key; must be exactly 16 characters. Plain-text values of the wrong length are rejected at pre-flight. Supports $env:
                                                                         resolution with interactive fallback prompt when unset.
clusters[].harborConfiguration.databasePassword              No          Override for the internal PostgreSQL password. Supports $env: resolution with interactive fallback prompt when unset.
clusters[].harborConfiguration.coreSecret                    No          Override for the core inter-service secret. Supports $env: resolution with interactive fallback prompt when unset.
clusters[].harborConfiguration.jobserviceSecret              No          Override for the jobservice inter-service secret. Supports $env: resolution with interactive fallback prompt when unset.
clusters[].harborConfiguration.registrySecret                No          Override for the registry upload-state secret. Supports $env: resolution with interactive fallback prompt when unset.
clusters[].harborConfiguration.parentDirectory               Conditional When tlsCrt, tlsKey, or caCrt are set: optional directory containing those PEM files as file names (or relative fragments under this
                                                                         directory). When omitted, tlsCrt, tlsKey, and caCrt are full or infrastructure-relative paths (legacy).
clusters[].harborConfiguration.tlsCrt                        Conditional With parentDirectory: TLS certificate file name (e.g. tls.crt.pem). Without parentDirectory: full or infrastructure-relative path to the
                                                                         PEM file. Required when tlsKey is set; both must be defined together. Contents injected as tls.crt under tlsCertificate in the YAML.
clusters[].harborConfiguration.tlsKey                        Conditional With parentDirectory: TLS private key file name (e.g. tls.key.pem). Without parentDirectory: full or infrastructure-relative path.
                                                                         Required when tlsCrt is set; both must be defined together. Contents injected as tls.key under tlsCertificate in the YAML.
clusters[].harborConfiguration.caCrt                         No          With parentDirectory: CA certificate file name. Without parentDirectory: full or infrastructure-relative path. Only valid when both tlsCrt
                                                                         and tlsKey are defined. Contents injected as ca.crt under tlsCertificate in the YAML. Also used when registering Harbor as a Supervisor
                                                                         container image registry.
clusters[].harborConfiguration.registryVolumeSize            No          Override for persistence.persistentVolumeClaim.registry.size. Format: positive integer followed by Gi (e.g. 10Gi). Omit to use the
                                                                         template default.
clusters[].harborConfiguration.jobserviceVolumeSize          No          Override for persistence.persistentVolumeClaim.jobservice.jobLog.size. Format: <N>Gi. Omit to use the template default.
clusters[].harborConfiguration.databaseVolumeSize            No          Override for persistence.persistentVolumeClaim.database.size. Format: <N>Gi. Omit to use the template default.
clusters[].harborConfiguration.redisVolumeSize               No          Override for persistence.persistentVolumeClaim.redis.size. Format: <N>Gi. Omit to use the template default.
clusters[].harborConfiguration.trivyVolumeSize               No          Override for persistence.persistentVolumeClaim.trivy.size. Format: <N>Gi. Omit to use the template default.
clusters[].storagePolicy.storagePolicyTagCatalog             No          Tag catalog for storage policy. Omit for default {storageType}-Storage-TagCatalog.
clusters[].storagePolicy.storageType                         Yes         Storage type: VMFS, vSAN-ESA, or vSAN-OSA.
clusters[].storagePolicy.storagePolicyRule                   No          The only valid value is Fully initialized. Do not change otherwise the script will error.
clusters[].networking.networkSegments                        Yes         Array of segments; names must match supervisor.json network references.
clusters[].networking.networkSegments[].name                 Yes         Segment name; lower-case, RFC1123; must match supervisor.json.
clusters[].networking.networkSegments[].vlanId               Yes         VLAN ID (0-4095); unique within this cluster.
clusters[].networking.networkSegments[].gateway              Yes         Gateway in CIDR (e.g. 10.30.10.1/24); mapped into supervisor by segment name.
clusters[].networking.networkingVmKernelInterfaces           Conditional Required for vSAN-ESA and vSAN-OSA only (not VMFS). At least two entries: vMotion, vSAN (required). Optional third: vSAN Witness. Shallow
                                                                         / deeper checks validate the child keys below.
clusters[].networking.networkingVmKernelInterfaces[].service Conditional One of: vMotion, vSAN, vSAN Witness (exact strings). vMotion and vSAN are required across the array; vSAN Witness is optional.
clusters[].networking.networkingVmKernelInterfaces[].vlanId  Conditional VLAN ID 0-4095; must match a segment used for that traffic class.
clusters[].networking.networkingVmKernelInterfaces[].netmask Conditional IPv4 netmask for the VMkernel (e.g. 255.255.255.0).
clusters[].networking.networkingVmKernelInterfaces[].ipList  Conditional Array of exactly two unique IPv4 addresses (order aligns with esxHosts order).
clusters[].networking.networkingVmKernelInterfaces[].gateway Conditional Optional. Used on the vSAN Witness entry only: IPv4 gateway applied via esxcli after the VMkernel exists.
```

## Example of checking for an update

```Powershell
PS C:\Users\Administrator> start-VcfEdgeAtScale -checkForUpdates

[ADVISORY] A new version of VcfEdgeAtScale is available: 1.0.3.1006 (you have 1.0.3.1003).

Install update now? [Y/n]: Y
[INFO] Installing VcfEdgeAtScale 1.0.3.1006 from PSGallery...
[INFO] VcfEdgeAtScale 1.0.3.1006 installed successfully.
[INFO] Updating config UI tool: version 1.0.3.1003 → 1.0.3.1006.
[INFO] Config UI tool updated to 1.0.3.1006 at C:\Users\Administrator\VCFEdgeAtScale\Tools\veas-json-generator.py.
  Config UI tool updated: veas-json-generator.py (1.0.3.1003 → 1.0.3.1006)
[INFO] Updating UI template: version 1.0.3.1003 → 1.0.3.1006.
[INFO] UI template updated to 1.0.3.1006 at C:\Users\Administrator\VCFEdgeAtScale\Tools\veas-ui.html.
  UI template updated: veas-ui.html (1.0.3.1003 → 1.0.3.1006)

Update complete. Open a new PowerShell window to use the new version.

```

## Example of single edge side deployment (four vNICs, vSAN-OSA, two VKS networks)

```Powershell
PS C:\Users\Administrator> Start-VcfEdgeAtScale -Edgesite vsan-edge1

[INFO] Checking for required JSON properties for edgeSite(s) "vsan-edge1"...
[INFO] Validating property formats and values for edgeSite(s) "vsan-edge1"...
[INFO] Processing 1 edge site(s): vsan-edge1...
[INFO] Beginning workflow for edgeSite: "vsan-edge1".
[INFO] Performing vCenter reachability check (TCP 443)...
[INFO] Reachability: vCenter OK.
[INFO] Performing ESX reachability check (TCP 443) for 2 host(s)...
[INFO] Reachability: all targets OK (vCenter and 2 ESX host(s)).
[INFO] Pre-flight checking ESX version (9.0.0 minimum) across 2 host(s)...
[INFO] ESX pre-flight version check passed for all 2 host(s).
[INFO] No cluster named "cluster-vsan-edge1" was found on vCenter "vcenter202.vcfedge.demo". Proceeding with cluster creation.
[INFO] Using vLCM image from configuration: "VCF91".

DisplayName BaseImage
----------- ---------
VCF91       9.1.0.0.25370933

[INFO] Creating the cluster "cluster-vsan-edge1" on vCenter "vcenter202.vcfedge.demo"...  Success
[INFO] Adding ESX host "automation-esx02.vcfedge.demo" to cluster "cluster-vsan-edge1"... Success
[INFO] Adding ESX host "automation-esx03.vcfedge.demo" to cluster "cluster-vsan-edge1"... Success
[INFO] Creating VDS "VDS-vsan-edge1-sw1" on vCenter "vcenter202.vcfedge.demo"...  Success
[INFO] Creating VDS "VDS-vsan-edge1-sw2" on vCenter "vcenter202.vcfedge.demo"...  Success
[INFO] Migrating management (vmk0) to VDS "VDS-vsan-edge1-sw1" for 2 host(s)... Done
[INFO] Creating port group "managementnetwork" on VDS "VDS-vsan-edge1-sw1" with VLAN ID 401... Success
[INFO] Creating port group "guestnetwork" on VDS "VDS-vsan-edge1-sw1" with VLAN ID 402... Success
[INFO] VDS "VDS-vsan-edge1-sw1": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] VDS "VDS-vsan-edge1-sw2": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] Creating port group "vmotion-vsan-edge1" on VDS "VDS-vsan-edge1-sw2" with VLAN ID 404... Success
[INFO] Creating port group "vsan-vsan-edge1" on VDS "VDS-vsan-edge1-sw2" with VLAN ID 405... Success
[INFO] Created VMkernel for "vMotion" on host "automation-esx02.vcfedge.demo" (port group "vmotion-vsan-edge1", IP 10.40.14.12, MTU 9000).
[INFO] Created VMkernel for "vMotion" on host "automation-esx03.vcfedge.demo" (port group "vmotion-vsan-edge1", IP 10.40.14.13, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "automation-esx02.vcfedge.demo" (port group "vsan-vsan-edge1", IP 10.40.15.12, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "automation-esx03.vcfedge.demo" (port group "vsan-vsan-edge1", IP 10.40.15.13, MTU 9000).
[INFO] Successfully created tag catalog "vSAN-OSA-Storage-TagCatalog" on "vcenter202.vcfedge.demo".
[INFO] Successfully created tag name "supervisor-vsan-edge1" on "vSAN-OSA-Storage-TagCatalog".
[INFO] Retrieving vSAN OSA eligible disks for cluster "cluster-vsan-edge1" from all hosts...
[INFO] Found 4 eligible disk(s) for cluster "cluster-vsan-edge1".

vSAN OSA disks claimed for cluster "cluster-vsan-edge1" (cache/capacity per host):

Id VMHostName                    CanonicalName       CapacityGB Model                     IsSsd DefaultRole
-- ----------                    -------------       ---------- -----                     ----- -----------
 1 automation-esx02.vcfedge.demo mpx.vmhba0:C0:T2:L0     600.00 VMware   Virtual disk      True Capacity
 2 automation-esx02.vcfedge.demo mpx.vmhba0:C0:T1:L0      80.00 VMware   Virtual disk      True Cache
 3 automation-esx03.vcfedge.demo mpx.vmhba0:C0:T2:L0     600.00 VMware   Virtual disk      True Capacity
 4 automation-esx03.vcfedge.demo mpx.vmhba0:C0:T1:L0      80.00 VMware   Virtual disk      True Cache

[INFO] vSAN OSA disk group assignment completed for 2 host(s) (default cache/capacity).
[INFO] Creating vSAN OSA disk group on host "automation-esx02.vcfedge.demo" (1 cache, 1 capacity disk(s)).
[INFO] Successfully created vSAN OSA disk group on host "automation-esx02.vcfedge.demo".
[INFO] Creating vSAN OSA disk group on host "automation-esx03.vcfedge.demo" (1 cache, 1 capacity disk(s)).
[INFO] Successfully created vSAN OSA disk group on host "automation-esx03.vcfedge.demo".
[INFO] Successfully configured vSAN OSA disk groups for all hosts in cluster "cluster-vsan-edge1".
[INFO] Waiting for vSAN datastore to become available and renaming to "datastore-vsan-edge1"... Success
[INFO] Configuring vSAN witness for cluster "cluster-vsan-edge1" (witness host: "10.191.174.197").
[INFO] Checking whether witness host "10.191.174.197" already has a vSAN OSA disk group...
[INFO] Witness host "10.191.174.197" already has a vSAN OSA disk group. Skipping disk group creation.
[INFO] Configuring vSAN witness host for cluster "cluster-vsan-edge1"...
[INFO] Ensure connectivity between cluster hosts and witness through vSAN Witness VMkernel interface.
[INFO] Enabling stretched cluster mode and configuring witness host "10.191.174.197" for cluster "cluster-vsan-edge1"...
[INFO] Successfully configured witness host "10.191.174.197" for cluster "cluster-vsan-edge1".
[INFO] vSAN cluster health is green for cluster "cluster-vsan-edge1". Proceeding.
[INFO] Successfully tagged vSAN OSA datastore "datastore-vsan-edge1" with tag "supervisor-vsan-edge1" (catalog "vSAN-OSA-Storage-TagCatalog").
[INFO] Running vLCM cluster compliance check for cluster "cluster-vsan-edge1".
[INFO] Cluster "cluster-vsan-edge1" is compliant to the vLCM image. No remediation required.
[INFO] Retrieving supervisor ID for "supervisor-vsan-edge1" on vCenter "vcenter202.vcfedge.demo"...
[INFO] Beginning Supervisor deployment to cluster "cluster-vsan-edge1"...
[INFO] Supervisor configuration parsed successfully for edgeSite: vsan-edge1.
[INFO] Configuration validation passed.
[INFO] Supervisor services on cluster "cluster-vsan-edge1" were successfully configured in 1430 seconds.
[INFO] Supervisor deployment completed successfully. Supervisor ID: 0612c330-c930-4187-9a58-655191f7a94e
[INFO] Checking for available supervisor upgrade versions...
[INFO] No supervisor upgrade available. Current version v1.32.9+vmware.2-fips-vsc9.1.0.0-25234335 is up to date.
[INFO] Using all available VM classes for ArgoCD namespace.
[INFO] The ArgoCD namespace "argocd-c3942" was created successfully with 29 VM classes assigned: best-effort-medium, best-effort-large, guaranteed-4xlarge, 6cpu-guaranteed-24576mb-guaranteed, guaranteed-large, best-effort-4xlarge, guaranteed-8xlarge, best-effort-xsmall, best-effort-xlarge, guaranteed-xlarge, best-effort-small, guaranteed-small, 2cpu-besteffort-8192mb-besteffort, 4cpu-besteffort-16384mb-besteffort, guaranteed-2xlarge, best-effort-2xlarge, guaranteed-medium, 2cpu-besteffort-3072mb-besteffort, 32cpu-besteffort-131072mb-besteffort, 1cpu-besteffort-2048mb-besteffort, 16cpu-besteffort-131072mb-besteffort, 4cpu-besteffort-12288mb-besteffort, 4cpu-besteffort-21504mb-besteffort, guaranteed-xsmall, 8cpu-besteffort-98304mb-besteffort, 8cpu-besteffort-32768mb-besteffort, 32cpu-besteffort-262144mb-besteffort, 4cpu-besteffort-4096mb-besteffort, best-effort-8xlarge
[INFO] The ArgoCD operator has been successfully installed on vCenter "vcenter202.vcfedge.demo". (Took 45 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.40.11.181"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01:argocd-c3942"...
[INFO] VCF context "vcf-context-01" activated successfully.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] All 5 ArgoCD pods are ready.

[INFO] ╔═══════════════════════════════════════╗
[INFO]   ArgoCD Login
[INFO]    Go to https://10.40.12.203/
[INFO]    Login as user "admin" using temporary password: xxxxxxxxxxxx
[INFO]    To update your password run: "argocd.exe account update-password --server 10.40.12.203 --account admin --insecure"
[INFO] ╚═══════════════════════════════════════╝
[INFO] Created temporary Harbor data values file for edge site "vsan-edge1" (hostname: "harbor-site1.example.com", storageClass: "supervisor-vsan-edge1")
[INFO] Harbor service "harbor.tanzu.vmware.com" version "2.14.2+vmware.2-vks.1" is already registered globally on this vCenter. Skipping re-registration.
[INFO] Harbor service install request submitted. Waiting for configuration to complete.
[INFO] Harbor service "harbor.tanzu.vmware.com" version "2.14.2+vmware.2-vks.1" is CONFIGURED on supervisor "0612c330-c930-4187-9a58-655191f7a94e".
[INFO] Harbor Supervisor Service installed successfully for edge site "vsan-edge1" (hostname: "harbor-site1.example.com").
[INFO] ╔═══════════════════════════════════════╗
[INFO]   Harbor — cluster-vsan-edge1
[INFO]   Username : admin
[INFO]   Password : xxxxxxxxxxxxxxxxx
[INFO]   Namespace: svc-harbor-4laok
[INFO]   URL      : https://10.40.12.204
[INFO]   DNS      : Create a record pointing "harbor-site1.example.com" to 10.40.12.204 (Harbor load balancer external IP).
[INFO] ╚═══════════════════════════════════════╝
[INFO] Registering Harbor as container image registry "harbor" on supervisor "0612c330-c930-4187-9a58-655191f7a94e" for cluster "cluster-vsan-edge1" (endpoint: "10.40.12.204")...
[INFO] Harbor container image registry "harbor" registered on supervisor "0612c330-c930-4187-9a58-655191f7a94e" for cluster "cluster-vsan-edge1" (id: "2669572d-5cc2-4d78-b84d-19848e34e0bf", endpoint: "10.40.12.204").
[INFO] Completed deployment for cluster with edgeSite: vsan-edge1
[INFO] ESX node health for cluster "cluster-vsan-edge1" (2 host(s)): all Connected/PoweredOn.
[INFO] Supervisor health for cluster "cluster-vsan-edge1" (supervisor "0612c330-c930-4187-9a58-655191f7a94e"): ConfigStatus=RUNNING, KubernetesStatus=READY, no outstanding messages or conditions.
[INFO] Running on-demand vSAN health test for cluster "cluster-vsan-edge1" (vSAN Health RETEST equivalent after deployment; VMCreateTimeoutSeconds=120).
[INFO] On-demand vSAN health test completed for cluster "cluster-vsan-edge1". Refresh vSAN Health in vCenter to review current status.
```

## Example of ValidateOnly (JSON)

```powershell
 PS C:\Users\Administrator> Start-VcfEdgeAtScale -ValidateOnly

[INFO] Checking for required JSON properties for all sites...
[INFO] Validating property formats and values for all sites...
[INFO] ValidateOnly: validation passed. Exiting without deployment.
PS C:\Users\Administrator> Start-VcfEdgeAtScale -ValidateOnly -EdgeSite ESA

[INFO] Checking for required JSON properties for edgeSite(s) "ESA"...
[INFO] Validating property formats and values for edgeSite(s) "ESA"...
[INFO] ValidateOnly: validation passed. Exiting without deployment.
```

## Example of single site deployment (four NICs, VMFS datastore, four VKS networks)

```Powershell
PS C:\Users\Administrator> Start-VcfEdgeAtScale -Edgesite localdisk-edge2

[INFO] Checking for required JSON properties for edgeSite(s) "localdisk-edge2"...
[INFO] Validating property formats and values for edgeSite(s) "localdisk-edge2"...
[INFO] Processing 1 edge site(s): localdisk-edge2...
[INFO] Beginning workflow for edgeSite: "localdisk-edge2".
[INFO] Performing vCenter reachability check (TCP 443)...
[INFO] Reachability: vCenter OK.
[INFO] Performing ESX reachability check (TCP 443) for 1 host(s)...
[INFO] Reachability: all targets OK (vCenter and 1 ESX host(s)).
[INFO] Pre-flight checking ESX version (9.0.0 minimum) across 1 host(s)...
[INFO] ESX pre-flight version check passed for all 1 host(s).
[INFO] Datastore "datastore-localdisk-edge2" not found on ESX host "automation-esx01.vcfedge.demo".
[INFO] Selected largest available drive for VMFS (CapacityGB=600, CanonicalName=mpx.vmhba0:C0:T2:L0).
[INFO] No cluster named "cluster-localdisk-edge2" was found on vCenter "vcenter202.vcfedge.demo". Proceeding with cluster creation.
[INFO] Using vLCM image from configuration: "VCF91".

DisplayName BaseImage
----------- ---------
VCF91       9.1.0.0.25370933

[INFO] Creating the cluster "cluster-localdisk-edge2" on vCenter "vcenter202.vcfedge.demo"...  Success
[INFO] Adding ESX host "automation-esx01.vcfedge.demo" to cluster "cluster-localdisk-edge2"... Success
[INFO] Creating VDS "VDS-localdisk-edge2-sw1" on vCenter "vcenter202.vcfedge.demo"...  Success
[INFO] Creating VDS "VDS-localdisk-edge2-sw2" on vCenter "vcenter202.vcfedge.demo"...  Success
[INFO] Migrating management (vmk0) to VDS "VDS-localdisk-edge2-sw1" for 1 host(s)... Done
[INFO] Creating port group "primaryworkloadnetwork-3" on VDS "VDS-localdisk-edge2-sw1" with VLAN ID 500... Success
[INFO] Creating port group "flbmanagementnetwork-3" on VDS "VDS-localdisk-edge2-sw1" with VLAN ID 501... Success
[INFO] Creating port group "virtualservernetwork-3" on VDS "VDS-localdisk-edge2-sw1" with VLAN ID 502... Success
[INFO] Creating port group "mgmtnetwork-3" on VDS "VDS-localdisk-edge2-sw1" with VLAN ID 503... Success
[INFO] VDS "VDS-localdisk-edge2-sw1": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] VDS "VDS-localdisk-edge2-sw2": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] Tag catalog "VMFS-Storage-TagCatalog" already exists on vCenter "vcenter202.vcfedge.demo". Skipping tag catalog creation.
[INFO] Tag name "supervisor-localdisk-edge2" already exists on "VMFS-Storage-TagCatalog". Skipping tag creation.
[INFO] Cluster "cluster-localdisk-edge2" has one host; HA enabled (admission control disabled), DRS enabled.
[INFO] Creating the new datastore "datastore-localdisk-edge2" on ESX host "automation-esx01.vcfedge.demo"...  Success
[INFO] Successfully tagged datastore "datastore-localdisk-edge2" with tag "supervisor-localdisk-edge2".
[INFO] Running vLCM cluster compliance check for cluster "cluster-localdisk-edge2".
[INFO] Cluster "cluster-localdisk-edge2" is compliant to the vLCM image. No remediation required.
[INFO] Retrieving supervisor ID for "supervisor-localdisk-edge2" on vCenter "vcenter202.vcfedge.demo"...
[INFO] Beginning Supervisor deployment to cluster "cluster-localdisk-edge2"...
[INFO] Supervisor configuration parsed successfully for edgeSite: localdisk-edge2.
[INFO] Configuration validation passed.
[INFO] Supervisor services on cluster "cluster-localdisk-edge2" were successfully configured in 1365 seconds.
[INFO] Supervisor deployment completed successfully. Supervisor ID: d6ed32b3-bef9-4578-af54-397b79d758ce
[INFO] Checking for available supervisor upgrade versions...
[INFO] No supervisor upgrade available. Current version v1.32.9+vmware.2-fips-vsc9.1.0.0-25234335 is up to date.
[INFO] Using all available VM classes for ArgoCD namespace.
[INFO] The ArgoCD namespace "argocd-c4000" was created successfully with 29 VM classes assigned: guaranteed-xlarge, best-effort-small, guaranteed-small, 2cpu-besteffort-8192mb-besteffort, 4cpu-besteffort-16384mb-besteffort, guaranteed-2xlarge, best-effort-2xlarge, guaranteed-medium, 2cpu-besteffort-3072mb-besteffort, 32cpu-besteffort-131072mb-besteffort, 1cpu-besteffort-2048mb-besteffort, 16cpu-besteffort-131072mb-besteffort, 4cpu-besteffort-12288mb-besteffort, 4cpu-besteffort-21504mb-besteffort, guaranteed-xsmall, 8cpu-besteffort-98304mb-besteffort, 8cpu-besteffort-32768mb-besteffort, 32cpu-besteffort-262144mb-besteffort, 4cpu-besteffort-4096mb-besteffort, best-effort-8xlarge, best-effort-medium, best-effort-large, guaranteed-4xlarge, 6cpu-guaranteed-24576mb-guaranteed, guaranteed-large, best-effort-4xlarge, guaranteed-8xlarge, best-effort-xsmall, best-effort-xlarge
[INFO] The ArgoCD operator has been successfully installed on vCenter "vcenter202.vcfedge.demo". (Took 45 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.50.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01:argocd-c4000"...
[INFO] VCF context "vcf-context-01" activated successfully.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] All 5 ArgoCD pods are ready.

[INFO] ╔═══════════════════════════════════════╗
[INFO]   ArgoCD Login
[INFO]    Go to https://10.50.12.203/
[INFO]    Login as user "admin" using temporary password: xxxxxxxxxxxx
[INFO]    To update your password run: "argocd.exe account update-password --server 10.50.12.203 --account admin --insecure"
[INFO] ╚═══════════════════════════════════════╝
[INFO] Created temporary Harbor data values file for edge site "localdisk-edge2" (hostname: "harbor-site1.example.com", storageClass: "supervisor-localdisk-edge2")
[INFO] Harbor service "harbor.tanzu.vmware.com" version "2.14.2+vmware.2-vks.1" is already registered globally on this vCenter. Skipping re-registration.
[INFO] Harbor service install request submitted. Waiting for configuration to complete.
[INFO] Harbor service "harbor.tanzu.vmware.com" version "2.14.2+vmware.2-vks.1" is CONFIGURED on supervisor "d6ed32b3-bef9-4578-af54-397b79d758ce".
[INFO] Harbor Supervisor Service installed successfully for edge site "localdisk-edge2" (hostname: "harbor-site1.example.com").
[INFO] ╔═══════════════════════════════════════╗
[INFO]   Harbor — cluster-localdisk-edge2
[INFO]   Username : admin
[INFO]   Password : xxxxxxxxxxxxxx
[INFO]   Namespace: svc-harbor-ecpka
[INFO]   URL      : https://10.50.12.204
[INFO]   DNS      : Create a record pointing "harbor-site1.example.com" to 10.50.12.204 (Harbor load balancer external IP).
[INFO] ╚═══════════════════════════════════════╝

---------------------------------------
[INFO] Registering Harbor as container image registry "harbor" on supervisor "d6ed32b3-bef9-4578-af54-397b79d758ce" for cluster "cluster-localdisk-edge2" (endpoint: "10.50.12.204")...
[INFO] Harbor container image registry "harbor" registered on supervisor "d6ed32b3-bef9-4578-af54-397b79d758ce" for cluster "cluster-localdisk-edge2" (id: "d7970dd5-28c4-48f3-857e-6ff48dbeb9be", endpoint: "10.50.12.204").
[INFO] Completed deployment for cluster with edgeSite: localdisk-edge2
[INFO] ESX node health for cluster "cluster-localdisk-edge2" (1 host(s)): all Connected/PoweredOn.
[INFO] Supervisor health for cluster "cluster-localdisk-edge2" (supervisor "d6ed32b3-bef9-4578-af54-397b79d758ce"): ConfigStatus=RUNNING, KubernetesStatus=READY, no outstanding messages or conditions.
```

## Example cleaning up ArgoCD

```Powershell
PS C:\Users\Administrator> Start-VcfEdgeAtScale -Edgesite localdisk-edge2 -Cleanup argocd

[INFO] Processing 1 edge site(s): localdisk-edge2...
[INFO] Beginning workflow for edgeSite: "localdisk-edge2".
[INFO] Performing vCenter reachability check (TCP 443)...
[INFO] Reachability: vCenter OK.
[INFO] CleanUp is set to "ArgoCD". Cleaning up per scope, then exiting without deploying.

[ADVISORY] The cleanup process will remove only the ArgoCD namespace "argocd-c4000" for cluster "cluster-localdisk-edge2" (edgeSite "localdisk-edge2"). No supervisor deactivation or compute removal. Please backup your data before proceeding.
To confirm cleanup, type exactly (or copy/paste): delete argocd for localdisk-edge2
delete argocd for localdisk-edge2
[INFO] ArgoCD namespace "argocd-c4000" deleted successfully for cluster "cluster-localdisk-edge2".
[INFO] CleanUp (ArgoCD) completed. Exiting without deployment
```

## Example cleaning up Supervisor

```Powershell
PS C:\Users\Administrator> Start-VcfEdgeAtScale -Edgesite localdisk-edge2 -Cleanup Supervisor

[INFO] Processing 1 edge site(s): localdisk-edge2...
[INFO] Beginning workflow for edgeSite: "localdisk-edge2".
[INFO] Performing vCenter reachability check (TCP 443)...
[INFO] Reachability: vCenter OK.
[INFO] CleanUp is set to "Supervisor". Cleaning up per scope, then exiting without deploying.

[ADVISORY] The cleanup process for supervisor will remove all the VMware vSphere Kubernetes Service (VKS) applications in cluster "cluster-localdisk-edge2". Please backup your data before proceeding.
To confirm cleanup, type exactly (or copy/paste): delete supervisor for localdisk-edge2
 delete supervisor for localdisk-edge2
[INFO] Deactivating supervisor on cluster "cluster-localdisk-edge2" (ID: domain-c4000)... fully deactivated after 550 seconds. You can retry deployment.
[INFO] Supervisor deactivated on cluster "cluster-localdisk-edge2". Compute (VDS, vSAN/VMFS, cluster) remains.
[INFO] CleanUp (Supervisor) completed. Exiting without deployment.
```

## Example of creating a log bundle

```Powershell
PS C:\Users\Administrator> start-VcfEdgeAtScale -CollectLogs

Default JSON files under deployment root:
  C:\Users\Administrator\VCFEdgeAtScale\infrastructure.json
  C:\Users\Administrator\VCFEdgeAtScale\supervisor.json
Use these two files in the zip? (Y/n): y

CollectLogs finished. Archive saved to:
  C:\Users\Administrator\VcfEdgeatScale-logs-20260508-073118.zip
PS C:\Users\Administrator>
```

## Example of check the module version

```Powershell
PS C:\Users\Administrator> start-VcfEdgeAtScale -Version
[INFO] VcfEdgeAtScale version: 1.0.3.1006
```
