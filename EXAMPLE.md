# Usage Examples

**Prerequisites:** PowerShell 7.4+, **VCF PowerCLI 9.0+** (`VCF.PowerCLI`; 9.0 and 9.1 supported), kubectl, and the VCF CLI (`vcf`), per [README.md](README.md).

## Base JSON files - updated 2026-03-04

### infrastructure.json

```powershell
{
  "common": {
    "nonInteractivePassword": true,
    "labEnvironment": true,
    "vCenterName": "10.191.174.202",
    "vCenterUser": "administrator@vsphere.local",
    "datacenterName": "UnitTest",
    "vLcmImageName": "ESX902-ESA",
    "nicList": [
      { "name": "vmnic0" },
      { "name": "vmnic1" }
    ],
    "contextName": "vcf-context-01"
  },
  "clusters": [
    {
      "edgeSite": "ESA",
      "esxHosts": [
        "10.191.171.173",
        "10.191.171.174"
      ],
      "supervisorServices": {
        "argoCdOperatorYamlPath": "C:\\Users\\Administrator\\1.1.0-25100889.yml",
        "argoCdDeploymentYamlPath": "C:\\Users\\Administrator\\argocd-deployment.yml",
        "vSanWitnessVmName": "10.191.174.196"
      },
      "storagePolicy": {
        "storageType": "vSAN-ESA"
      },
      "networking": {
        "networkSegments": [
          {
            "name": "primaryworkloadnetwork",
            "vlanId": "300",
            "gateway": "10.30.10.1/24"
          },
          {
            "name": "flbmanagementnetwork",
            "vlanId": "301",
            "gateway": "10.30.11.1/24"
          },
          {
            "name": "virtualservernetwork",
            "vlanId": "302",
            "gateway": "10.30.12.1/24"
          },
          {
            "name": "tkgsmgmtnetwork",
            "vlanId": "303",
            "gateway": "10.30.13.1/24"
          }
        ],
        "networkingVmKernelInterfaces": [
          {
            "service": "vMotion",
            "vlanId": "304",
            "netmask": "255.255.255.0",
            "ipList": ["10.30.14.12", "10.30.14.13"]
          },
          {
            "service": "vSAN",
            "vlanId": "305",
            "netmask": "255.255.255.0",
            "ipList": ["10.30.15.12", "10.30.15.13"]
          }
        ]
      }
    },
    {
      "edgeSite": "OSA",
      "esxHosts": [
        "10.191.171.201",
        "10.191.171.171"
      ],
      "supervisorServices": {
        "argoCdOperatorYamlPath": "C:\\Users\\Administrator\\1.1.0-25100889.yml",
        "argoCdDeploymentYamlPath": "C:\\Users\\Administrator\\argocd-deployment.yml",
        "vSanWitnessVmName": "10.191.174.197"
      },
      "storagePolicy": {
        "storageType": "vSAN-OSA"
      },
      "networking": {
        "networkSegments": [
          {
            "name": "primaryworkloadnetwork-2",
            "vlanId": "400",
            "gateway": "10.40.10.1/24"
          },
          {
            "name": "flbmanagementnetwork-2",
            "vlanId": "401",
            "gateway": "10.40.11.1/24"
          },
          {
            "name": "virtualservernetwork-2",
            "vlanId": "402",
            "gateway": "10.40.12.1/24"
          },
          {
            "name": "tkgsmgmtnetwork-2",
            "vlanId": "403",
            "gateway": "10.40.13.1/24"
          }
        ],
        "networkingVmKernelInterfaces": [
          {
            "service": "vMotion",
            "vlanId": "404",
            "netmask": "255.255.255.0",
            "ipList": ["10.40.14.12", "10.40.14.13"]
          },
          {
            "service": "vSAN",
            "vlanId": "405",
            "netmask": "255.255.255.0",
            "ipList": ["10.40.15.12", "10.40.15.13"]
          }
        ]
      }
    },
    {
      "edgeSite": "VMFS",
      "esxHosts": [
        "10.191.171.172"
      ],
      "supervisorServices": {
        "argoCdOperatorYamlPath": "C:\\Users\\Administrator\\1.1.0-25100889.yml",
        "argoCdDeploymentYamlPath": "C:\\Users\\Administrator\\argocd-deployment.yml"
      },
      "storagePolicy": {
        "storageType": "VMFS"
      },
      "networking": {
        "networkSegments": [
          {
            "name": "primaryworkloadnetwork-3",
            "vlanId": "500",
            "gateway": "10.50.10.1/24"
          },
          {
            "name": "flbmanagementnetwork-3",
            "vlanId": "501",
            "gateway": "10.50.11.1/24"
          },
          {
            "name": "virtualservernetwork-3",
            "vlanId": "502",
            "gateway": "10.50.12.1/24"
          },
          {
            "name": "tkgsmgmtnetwork-3",
            "vlanId": "503",
            "gateway": "10.50.13.1/24"
          }
        ]
      }
    }
  ]
}
```

### supervisor.json

```powershell
{
  "commonSupervisorSpec": {
    "controlPlaneVMCount": 1,
    "controlPlaneSize": "SMALL",
    "flbAvailability": "SINGLE_NODE",
    "flbSize": "MEDIUM",
    "flbNetworkType": "DVPG",
    "networkSearchDomains": [
      "vcfedge.demo"
    ],
    "networkNtpServers": [
      "10.34.14.20"
    ],
    "dnsServers": [
      "10.191.174.20"
    ]
  },
  "tkgsSiteSpec": [
    {
      "edgeSite": "ESA",
      "foundationLoadBalancerComponents": {
        "flbName": "flb-site1",
        "flbVipStartIP": "10.30.12.201",
        "flbVipIPCount": 50,
        "flbManagementNetwork": {
          "flbNetworkName": "flbmanagementnetwork",
          "flbNetworkIpAddressStartingIp": "10.30.11.101",
          "flbNetworkIpAddressCount": 40
        },
        "flbVirtualServerNetwork": {
          "flbNetworkName": "virtualservernetwork",
          "flbNetworkIpAddressStartingIp": "10.30.12.141",
          "flbNetworkIpAddressCount": 60
        }
      },
      "tkgsMgmtNetworkSpec": {
        "tkgsMgmtNetworkName": "tkgsmgmtnetwork",
        "tkgsMgmtNetworkStartingIp": "10.30.13.100",
        "tkgsMgmtNetworkIPCount": 7
      },
      "tkgsPrimaryWorkloadNetwork": {
        "tkgsPrimaryWorkloadNetworkName": "primaryworkloadnetwork",
        "tkgsPrimaryWorkloadNetworkStartingIp": "10.30.10.101",
        "tkgsPrimaryWorkloadNetworkIPCount": 100,
        "tkgsWorkloadServiceStartIp": "10.97.0.0",
        "tkgsWorkloadServiceCount": 512
      }
    },
    {
      "edgeSite": "OSA",
      "foundationLoadBalancerComponents": {
        "flbName": "flb-site2",
        "flbVipStartIP": "10.40.12.201",
        "flbVipIPCount": 50,
        "flbManagementNetwork": {
          "flbNetworkName": "flbmanagementnetwork-2",
          "flbNetworkIpAddressStartingIp": "10.40.11.101",
          "flbNetworkIpAddressCount": 40,
          "flbNetworkGateway": "10.40.11.1/24"
        },
        "flbVirtualServerNetwork": {
          "flbNetworkName": "virtualservernetwork-2",
          "flbNetworkIpAddressStartingIp": "10.40.12.141",
          "flbNetworkIpAddressCount": 60,
          "flbNetworkGateway": "10.40.12.1/24"
        }
      },
      "tkgsMgmtNetworkSpec": {
        "tkgsMgmtNetworkName": "tkgsmgmtnetwork-2",
        "tkgsMgmtNetworkStartingIp": "10.40.13.100",
        "tkgsMgmtNetworkIPCount": 7
      },
      "tkgsPrimaryWorkloadNetwork": {
        "tkgsPrimaryWorkloadNetworkName": "primaryworkloadnetwork-2",
        "tkgsPrimaryWorkloadNetworkStartingIp": "10.40.10.101",
        "tkgsPrimaryWorkloadNetworkIPCount": 100,
        "tkgsWorkloadServiceStartIp": "10.97.0.0",
        "tkgsWorkloadServiceCount": 512
      }
    },
    {
      "edgeSite": "VMFS",
      "foundationLoadBalancerComponents": {
        "flbName": "flb-site3",
        "flbVipStartIP": "10.50.12.201",
        "flbVipIPCount": 50,
        "flbManagementNetwork": {
          "flbNetworkName": "flbmanagementnetwork-3",
          "flbNetworkIpAddressStartingIp": "10.50.11.101",
          "flbNetworkIpAddressCount": 40,
          "flbNetworkGateway": "10.50.11.1/24"
        },
        "flbVirtualServerNetwork": {
          "flbNetworkName": "virtualservernetwork-3",
          "flbNetworkIpAddressStartingIp": "10.50.12.141",
          "flbNetworkIpAddressCount": 60,
          "flbNetworkGateway": "10.50.12.1/24"
        }
      },
      "tkgsMgmtNetworkSpec": {
        "tkgsMgmtNetworkName": "tkgsmgmtnetwork-3",
        "tkgsMgmtNetworkStartingIp": "10.50.13.100",
        "tkgsMgmtNetworkIPCount": 7
      },
      "tkgsPrimaryWorkloadNetwork": {
        "tkgsPrimaryWorkloadNetworkName": "primaryworkloadnetwork-3",
        "tkgsPrimaryWorkloadNetworkStartingIp": "10.50.10.101",
        "tkgsPrimaryWorkloadNetworkIPCount": 100,
        "tkgsWorkloadServiceStartIp": "10.97.0.0",
        "tkgsWorkloadServiceCount": 512
      }
    }
  ]
}

```

## Show help for all public functions - 2026-03-04

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -?

NAME
    Start-ModernEdgeAtScale

SYNOPSIS
    Automates the end-to-end deployment of a simple vSphere Supervisor at scale in VMware Cloud Foundation 9.x.


SYNTAX
    Start-ModernEdgeAtScale [-AcceptBadCheckResults] [[-CleanUp] <String>] [-ComputeOnly]
    [[-DelayBeforeAddingNextHostSeconds] <Int32>] [[-EdgeSite] <String>] [-Force] [[-InfrastructureJson] <String>]
    [[-LogLevel] <String>] [[-RollbackOnFailure] <Nullable`1>] [[-SupervisorJson] <String>] [-ValidateOnly] [-Version]
    [<CommonParameters>]


DESCRIPTION
    Start-ModernEdgeAtScale is designed to streamline the deployment of a simple vSphere Supervisor in
    VMware Cloud Foundation (VCF) 9.x environments. The function handles all aspects of the deployment including:

    - vCenter and ESX host connection
    - ESX Cluster creation and host add
    - Datastore creation and storage policy configuration.
    - Virtual Distributed Switch (VDS) setup and port group configuration
    - vSphere Supervisor Deployment
    - ArgoCD installation and configuration for GitOps workflows


RELATED LINKS

REMARKS
    To see the examples, type: "Get-Help Start-ModernEdgeAtScale -Examples"
    For more information, type: "Get-Help Start-ModernEdgeAtScale -Detailed"
    For technical information, type: "Get-Help Start-ModernEdgeAtScale -Full"

PS C:\Users\Administrator> show-SupervisorJsonConfigurationHelp -?

NAME
    Show-SupervisorJsonConfigurationHelp

SYNOPSIS
    Displays a reference table for configuring supervisor.json file.


SYNTAX
    Show-SupervisorJsonConfigurationHelp [[-Filter] <String>] [[-Format] <String>] [[-WidthThreshold] <Int32>]
    [<CommonParameters>]


DESCRIPTION
    This helper function displays a reference table of configuration keys for the supervisor.json file,
    with Required (Yes/No/Conditional) and Notes for each key.


RELATED LINKS

REMARKS
    To see the examples, type: "Get-Help Show-SupervisorJsonConfigurationHelp -Examples"
    For more information, type: "Get-Help Show-SupervisorJsonConfigurationHelp -Detailed"
    For technical information, type: "Get-Help Show-SupervisorJsonConfigurationHelp -Full"

PS C:\Users\Administrator> Show-InfrastructureJsonConfigurationHelp -?

NAME
    Show-InfrastructureJsonConfigurationHelp

SYNOPSIS
    Displays a reference table for configuring infrastructure.json file.


SYNTAX
    Show-InfrastructureJsonConfigurationHelp [[-Filter] <String>] [[-Format] <String>] [[-WidthThreshold] <Int32>]
    [<CommonParameters>]


DESCRIPTION
    This helper function displays a reference table of configuration keys for the infrastructure.json file,
    with Required (Yes/No/Conditional) and Notes for each key.


RELATED LINKS

REMARKS
    To see the examples, type: "Get-Help Show-InfrastructureJsonConfigurationHelp -Examples"
    For more information, type: "Get-Help Show-InfrastructureJsonConfigurationHelp -Detailed"
    For technical information, type: "Get-Help Show-InfrastructureJsonConfigurationHelp -Full"

```

## Example of ValidateOnly (JSON) - 2026-03-04

```powershell
 PS C:\Users\Administrator> start-ModernEdgeAtScale -ValidateOnly

[INFO] Checking for required JSON properties for all sites...
[INFO] Validating property formats and values for all sites...
[INFO] ValidateOnly: validation passed. Exiting without deployment.
PS C:\Users\Administrator> start-ModernEdgeAtScale -ValidateOnly -EdgeSite ESA

[INFO] Checking for required JSON properties for edgeSite(s) "ESA"...
[INFO] Validating property formats and values for edgeSite(s) "ESA"...
[INFO] ValidateOnly: validation passed. Exiting without deployment.
```

## Show infrastructure config options - 2026-03-04

```powershell
PS C:\Users\Administrator> Show-InfrastructureJsonConfigurationHelp


[INFO] ========================================================================================================================
[INFO] Infrastructure.json Configuration Reference
[INFO] ========================================================================================================================



Key                                                    Required    Notes
---                                                    --------    -----
common.vCenterName                                     Yes         vCenter FQDN, 9.0 or later. Script needs HTTPS access.
common.vCenterUser                                     Yes         vCenter login (e.g. administrator@vsphere.local); SSO supported.
common.vSanWitnessVmName                               No          vSAN witness VM name or FQDN; used by vSAN-OSA/ESA.
common.esxUser                                         No          ESX login. Omit to use default root.
common.esxUniquePasswordPerHost                        No          Boolean. Default false when not defined (one password for all hosts). true = prompt per host.
common.nonInteractivePassword                          No          Boolean. When true, uses VCENTER_COMMON_PASSWORD / ESX_COMMON_PASSWORD env vars.
common.labEnvironment                                  No          Boolean. When true, some vSAN health checks are relaxed. With -Force, bypasses cleanup confirmation.
common.datacenterName                                  Yes         Existing vSphere datacenter; clusters are created under it.
common.clusterNamePrefix                               No          Prefix for cluster names. Omit for default cluster; format {prefix}-{edgeSite}.
common.datastoreNamePrefix                             No          Prefix for datastore names. Omit for default datastore; format {prefix}-{edgeSite}.
common.supervisorNamePrefix                            No          Prefix for supervisor names. Omit for default supervisor; format {prefix}-{edgeSite}.
common.vdsNamePrefix                                   No          Prefix for VDS names. Omit for default VDS; format {prefix}-{edgeSite}.
common.supervisorContentLibraryDatastore               No          When the key is present, datastore for supervisor content library (must already exist); script runs
                                                                   Initialize-SupervisorContentLibrary. When the key is omitted (removed) entirely, the content library workflow is skipped.
common.supervisorContentLibrarySubscriptionUrl         No          When supervisorContentLibraryDatastore key is present, subscription URL for the content library. If omitted, default is
                                                                   https://wp-content.vmware.com/supervisor/v1/latest/lib.json.
common.vLcmImageName                                   No          vLCM image name in vCenter Image Catalog; omit to choose at run time.
common.vSanvMotionVmKernelMtuValue                     No          Optional. When defined, overrides the default MTU (9000) for the VDS and for vMotion/vSAN VMkernel adapters only. Mgmt (vmk0) and
                                                                   vSAN Witness (vmk3) are always 1500. Must be 1500-9190 (numbers only; validated at JSON load). Use 1500 when the physical path does
                                                                   not support jumbo frames.
common.vmkernelMtu                                     No          Optional. Legacy. MTU (1500-9190) for VDS and vMotion/vSAN VMkernels when common.vSanvMotionVmKernelMtuValue is not set. Mgmt and
                                                                   vSAN Witness are always 1500.
common.nicList                                         Conditional Array of NICs for the VDS (e.g. [{"name":"vmnic1"},{"name":"vmnic2"}]). Number of uplinks = length of nicList. Required at common or
                                                                   per cluster (clusters[].nicList); cluster overrides common. Must have 2 or 4 NICs.
common.contextName                                     Yes         VCF context name used by VCF CLI for ArgoCD.
clusters                                               Yes         Array of cluster configurations. Each cluster is identified by edgeSite and contains ESX hosts, supervisor services, storage policy,
                                                                   and networking.
clusters[].edgeSite                                    Yes         Unique site ID; must match one tkgsSiteSpec[].edgeSite in supervisor.json.
clusters[].nicList                                     Conditional Optional override for this cluster. When present (2 or 4 NICs), overrides common.nicList. At least one of common.nicList or
                                                                   clusters[].nicList must be defined per cluster.
clusters[].esxHosts                                    Yes         Array of ESX FQDNs or IPs; script needs HTTPS access to each host.
clusters[].supervisorServices.argoCdOperatorYamlPath   Yes         Path to ArgoCD operator YAML (escape backslashes on Windows).
clusters[].supervisorServices.argoCdDeploymentYamlPath Yes         Path to ArgoCD instance YAML; namespace in file must match nameSpacePrefix.
clusters[].supervisorServices.nameSpacePrefix          No          ArgoCD namespace prefix. Omit for default argocd; script appends cluster MoRef for uniqueness.
clusters[].supervisorServices.vmClass                  No          Array of VM class names for ArgoCD namespace. Omit to assign all VM classes from vCenter.
clusters[].storagePolicy.storagePolicyTagCatalog       No          Tag catalog for storage policy. Omit for default {storageType}-Storage-TagCatalog.
clusters[].storagePolicy.storageType                   Yes         Storage type: VMFS, vSAN-ESA, or vSAN-OSA.
clusters[].storagePolicy.storagePolicyRule             No          The only valid value is Fully initialized. Do not change otherwise the script will error.
clusters[].networking.networkSegments                  Yes         Array of segments; names must match supervisor.json network references.
clusters[].networking.networkSegments[].name           Yes         Segment name; lower-case, RFC1123; must match supervisor.json.
clusters[].networking.networkSegments[].vlanId         Yes         VLAN ID (0-4095); unique within this cluster.
clusters[].networking.networkSegments[].gateway        Yes         Gateway in CIDR (e.g. 10.30.10.1/24); mapped into supervisor by segment name.
clusters[].networking.networkingVmKernelInterfaces     Conditional Required for vSAN-ESA and vSAN-OSA only (not VMFS). At least two entries: vMotion, vSAN (required). Optional third: vSAN Witness.
                                                                   When vSAN Witness is omitted, mgmt (vmk0) is tagged with vSAN witness traffic; when present, a dedicated witness VMkernel (vmk3) is
                                                                   created. Each entry: service, vlanId (0-4095), netmask (valid IPv4 netmask), ipList (exactly two unique IPv4s, one per host). Only
                                                                   the vSAN Witness entry requires gateway.
```

## Show Supervisor Configuration Options - 2026-03-04

```powershell
PS C:\Users\Administrator> Show-SupervisorJsonConfigurationHelp


[INFO] ========================================================================================================================
[INFO] Supervisor.json Configuration Reference
[INFO] ========================================================================================================================



Key                                                                                                   Required Notes
---                                                                                                   -------- -----
commonSupervisorSpec.controlPlaneVMCount                                                              No       1 or 3.
commonSupervisorSpec.controlPlaneSize                                                                 No       TINY, SMALL, MEDIUM, or LARGE.
commonSupervisorSpec.flbAvailability                                                                  No       SINGLE_NODE or ACTIVE_PASSIVE.
commonSupervisorSpec.flbSize                                                                          No       SMALL, MEDIUM, LARGE, or X-LARGE.
commonSupervisorSpec.flbNetworkType                                                                   No       Use DVPG.
commonSupervisorSpec.networkSearchDomains                                                             Yes      Array of DNS search domains.
commonSupervisorSpec.networkNtpServers                                                                Yes      Array of NTP servers.
commonSupervisorSpec.dnsServers                                                                       Yes      Array of DNS servers.
tkgsSiteSpec                                                                                          Yes      Array of site-specific supervisor configurations. Each entry is linked to
                                                                                                               infrastructure.json clusters[] via edgeSite.
tkgsSiteSpec[].edgeSite                                                                               Yes      Must match infrastructure.json clusters[].edgeSite.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbName                                               No       FLB name for this site.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbVipStartIP                                         Yes      Start IP for FLB virtual IP range.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbVipIPCount                                         Yes      Count of VIPs from flbVipStartIP.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName                   No       Must match infra networkSegments[].name; gateway from infra.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp    Yes      Start IP for FLB management network.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount         Yes      IP count for FLB management.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkGateway                No       Override gateway (otherwise from infra by name).
tkgsSiteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName                No       Match infra segment name; gateway from infra.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp Yes      Start IP for FLB virtual server network.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount      No       IP count; default may be used.
tkgsSiteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkGateway             No       Override gateway (otherwise from infra by name).
tkgsSiteSpec[].tkgsMgmtNetworkSpec.tkgsMgmtNetworkName                                                No       Must match infra segment name.
tkgsSiteSpec[].tkgsMgmtNetworkSpec.tkgsMgmtNetworkStartingIp                                          Yes      Start IP for VKS management network.
tkgsSiteSpec[].tkgsMgmtNetworkSpec.tkgsMgmtNetworkIPCount                                             Yes      IP count for VKS management.
tkgsSiteSpec[].tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkName                              No       Must match infra segment name.
tkgsSiteSpec[].tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkStartingIp                        Yes      Start IP for workload VIP range.
tkgsSiteSpec[].tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkIPCount                           Yes      IP count for workload VIP range.
tkgsSiteSpec[].tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceStartIp                                  Yes      Start IP for workload service range.
tkgsSiteSpec[].tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceCount                                    No       Count (e.g. 256 or 512); must occupy full CIDR.
```

## Example deploying all sites in a JSON (two NICs, one vDS) - 2026-03-04

```powershell

PS C:\Users\Administrator> start-ModernEdgeAtScale

[INFO] Checking for required JSON properties for all sites...
[INFO] Validating property formats and values for all sites...
[INFO] Processing all 3 edge site(s)...
[INFO] Beginning workflow for 3 edge site(s), starting with edgeSite: "ESA".
[INFO] Performing vCenter and ESX reachability check (TCP 443)...
[INFO] Reachability: all targets OK (vCenter and 5 ESX host(s)).
[INFO] No cluster named "cluster-ESA" was found on vCenter "10.191.174.202". Proceeding with cluster creation.
[INFO] Using vLCM image from configuration: "ESX902-ESA".

DisplayName BaseImage
----------- ---------
ESX902-ESA  9.0.2.0.25148076

[INFO] Creating the cluster "cluster-ESA" on vCenter "10.191.174.202"...  Success
[INFO] Adding ESX host "10.191.171.173" to cluster "cluster-ESA"... Success
[INFO] Adding ESX host "10.191.171.174" to cluster "cluster-ESA"... Success
[INFO] Creating VDS "VDS-ESA" on vCenter "10.191.174.202"...  Success
[INFO] Creating management port group "mgmt-ESA" on VDS "VDS-ESA" (VLAN 0).
[INFO] Added pNIC "vmnic1" to VDS "VDS-ESA" on host "10.191.171.173".
[INFO] Migrated management (vmk0) to VDS "VDS-ESA" port group "mgmt-ESA" on host "10.191.171.173".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.173".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-ESA" on host "10.191.171.173".
[INFO] Added pNIC "vmnic1" to VDS "VDS-ESA" on host "10.191.171.174".
[INFO] Migrated management (vmk0) to VDS "VDS-ESA" port group "mgmt-ESA" on host "10.191.171.174".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.174".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-ESA" on host "10.191.171.174".
[INFO] Creating port group "primaryworkloadnetwork" on VDS "VDS-ESA" with VLAN ID 300... Success
[INFO] Creating port group "flbmanagementnetwork" on VDS "VDS-ESA" with VLAN ID 301... Success
[INFO] Creating port group "virtualservernetwork" on VDS "VDS-ESA" with VLAN ID 302... Success
[INFO] Creating port group "tkgsmgmtnetwork" on VDS "VDS-ESA" with VLAN ID 303... Success
[INFO] VDS "VDS-ESA": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] Creating port group "vmotion-ESA" on VDS "VDS-ESA" with VLAN ID 304... Success
[INFO] Creating port group "vsan-ESA" on VDS "VDS-ESA" with VLAN ID 305... Success
[INFO] Created VMkernel for "vMotion" on host "10.191.171.173" (port group "vmotion-ESA", IP 10.30.14.12, MTU 9000).
[INFO] Created VMkernel for "vMotion" on host "10.191.171.174" (port group "vmotion-ESA", IP 10.30.14.13, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.173" (port group "vsan-ESA", IP 10.30.15.12, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.174" (port group "vsan-ESA", IP 10.30.15.13, MTU 9000).
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.173". Skipping witness traffic add.
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.174". Skipping witness traffic add.
[INFO] Successfully created tag catalog "vSAN-ESA-Storage-TagCatalog" on "10.191.174.202".
[INFO] Successfully created tag name "supervisor-ESA" on "vSAN-ESA-Storage-TagCatalog".
[INFO] Reconfiguring cluster-ESA for HA after moving vmk0 to vDS...
[INFO] Successfully configured VM monitoring settings on cluster "cluster-ESA".
[INFO] Ensuring vSAN configuration is applied to all hosts in cluster "cluster-ESA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-ESA".
[INFO] Retrieving vSAN ESA eligible disks for cluster "cluster-ESA" from all hosts...
[INFO] Found 4 eligible disk(s) for cluster "cluster-ESA".

vSAN ESA disks claimed for cluster "cluster-ESA":

Id VMHostName     CanonicalName                        CapacityGB Model
-- ----------     -------------                        ---------- -----
 1 10.191.171.173 eui.1a11431c54cffe8b000c296603ea3add     500.00 VMware Virtual NVMe Disk
 2 10.191.171.173 eui.ba33eac3dc25680b000c29634aad5191      80.00 VMware Virtual NVMe Disk
 3 10.191.171.174 eui.fa196b4e38295c1d000c2965528e53f8     500.00 VMware Virtual NVMe Disk
 4 10.191.171.174 eui.7734d14c0f1daf33000c296f08ecf6e9      80.00 VMware Virtual NVMe Disk

[INFO] vSAN ESA storage pool: all 4 eligible disk(s) will be added.
[INFO] Adding 2 disk(s) to vSAN ESA datastore from host "10.191.171.173"... Success
[INFO] Adding 2 disk(s) to vSAN ESA datastore from host "10.191.171.174"... Success
[INFO] Successfully configured vSAN ESA datastore for all hosts in cluster "cluster-ESA".
[INFO] Waiting for vSAN datastore to become available and renaming to "datastore-ESA"... Success
[INFO] Configuring vSAN witness host for cluster "cluster-ESA".
[INFO] Ensure connectivity between cluster hosts and witness through vSAN Witness VMkernel interface.
[INFO] Enabling stretched cluster mode and configuring witness host "10.191.174.196" for cluster "cluster-ESA"...
[INFO] Successfully configured witness host "10.191.174.196" for cluster "cluster-ESA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-ESA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-ESA" (config pushed from vCenter to hosts).
[INFO] Running vSAN cluster health check for cluster "cluster-ESA" (after witness).
[INFO] Enabled vSAN health Alarms on cluster "cluster-ESA".
[INFO] Waiting 20 seconds for vSAN health service to reflect HCI workflow skip.
[INFO] Silenced vSAN health checks for lab environment on cluster "cluster-ESA": advcfgsync, controllerdiskmode, controlleronhcl.
[INFO] vSAN advanced config not in sync on all hosts for cluster "cluster-ESA". Pushing current vSAN cluster config from vCenter to hosts.
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-ESA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-ESA" (config pushed from vCenter to hosts).
[INFO] vSAN cluster config re-applied for cluster "cluster-ESA". Sync may complete asynchronously; proceeding.
[INFO] vSAN cluster health is green for cluster "cluster-ESA". Proceeding.
[INFO] Successfully tagged vSAN ESA datastore "datastore-ESA" with tag "supervisor-ESA" (catalog "vSAN-ESA-Storage-TagCatalog").
[INFO] Storage policy "supervisor-ESA" already contains tag "supervisor-ESA" from catalog "vSAN-ESA-Storage-TagCatalog". Skipping tag add.
[INFO] Cluster "cluster-ESA" is compliant to the vLCM image. No remediation required.
[INFO] Suppress 10 GB networking alarm if present (Broadcom KB 394932) on 2/2 host(s) in cluster "cluster-ESA".
[INFO] Forming ArgoCD namespace name "argocd-c1157" from prefix "argocd" and cluster MoRef suffix: "-c1157" to ensure uniqueness.
[INFO] Retrieving supervisor ID for "supervisor-ESA" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-ESA"...
[INFO]   Supervisor "supervisor-ESA" not found.
[INFO] [Step 3/3] Supervisor instance "supervisor-ESA" not found. Proceeding to create it.
[INFO] Beginning Supervisor deployment to cluster "cluster-ESA"...
[INFO] [Step 1/5] Parsing supervisor configuration from JSON...
[INFO]   Management network configuration extracted: tkgsmgmtnetwork with 7 IPs
[INFO]     Starting IP: 10.30.13.100, Gateway: 10.30.13.1/24.
[INFO]   Workload network configuration extracted: primaryworkloadnetwork with 100 node IPs and 512 service IPs.
[INFO]     Node IP: 10.30.10.101, Service IP: 10.97.0.0.
[INFO]   FLB network configuration extracted: flbmanagementnetwork, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 40
[INFO]   FLB network configuration extracted: virtualservernetwork, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 60
[INFO] FLB configuration extracted: flb-site1, Size: MEDIUM, VIPs: 50
[INFO] Supervisor configuration parsed successfully for edgeSite: ESA.
[INFO] Control Plane: 1 x SMALL
[INFO] Management Network: tkgsmgmtnetwork
[INFO] Workload Network: primaryworkloadnetwork
[INFO] Load Balancer: flb-site1
[INFO] Configuration validation passed.
[INFO] [Step 2/5] Building Supervisor specifications...
[INFO]    Building control plane specification...
[INFO]    Control plane specification built successfully: Size=SMALL, VMs=1
[INFO]    Workload network specification built successfully: primaryworkloadnetwork
[INFO] [Step 3/5] Assembling complete supervisor specification...
[INFO] [Step 4/5] Invoking supervisor creation API...
[INFO]    Invoking supervisor creation on cluster "cluster-ESA" (ID: domain-c1157)...
[INFO] [Step 4/5] Supervisor API invocation completed. ID: f4b0be4c-775d-40be-8b74-82089b15510f
[INFO] [Step 5/5] Monitoring supervisor deployment status...
[INFO] Supervisor services on cluster "cluster-ESA" were successfully configured in 1665 seconds.
[INFO] [Step 5/5] Supervisor is ready (elapsed: 1665 seconds)
[INFO] Supervisor deployment completed successfully. Supervisor ID: f4b0be4c-775d-40be-8b74-82089b15510f
[INFO] Checking for available supervisor upgrade versions...
[INFO] No supervisor upgrade available. Current version v1.32.9+vmware.2-fips-vsc9.0.2.0-25129014 is up to date.
[INFO] Using all available VM classes for ArgoCD namespace: guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, best-effort-2xlarge, best-effort-medium, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge
[INFO] Configuring VM classes: guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, best-effort-2xlarge, best-effort-medium, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge
[INFO] The ArgoCD namespace "argocd-c1157" was created successfully.
[INFO] VM classes assigned: guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, best-effort-2xlarge, best-effort-medium, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge
[INFO] The ArgoCD operator was successfully created.  Waiting for configuration tasks to complete.
[INFO] The ArgoCD operator has been successfully installed on vCenter "10.191.174.202". (Took 205 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.30.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01"...
[ok] Token is still active. Skipped the token refresh for context "vcf-context-01"
[i] Successfully activated context 'vcf-context-01' (Type: kubernetes)
[i] Fetching recommended plugins for active context 'vcf-context-01'...
[ok] All recommended plugins are already installed and up-to-date.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] Applying ArgoCD deployment YAML file "C:\Users\Administrator\AppData\Local\Temp\tmpc2lhuh.yml" to namespace "argocd-c1157"...
[INFO] Successfully applied ArgoCD deployment YAML. Output: argocd.argocd-service.vsphere.vmware.com/argocd-instance-1 created
[INFO] kubectl context "vcf-context-01:argocd-c1157" does not exist. This is expected if the namespace was just created. Continuing with namespace flag -n for kubectl operations.
[INFO] Verifying kubectl authentication for namespace "argocd-c1157" (timeout: 60 seconds)...
[INFO] kubectl authentication verified for namespace "argocd-c1157" after 0 seconds
[INFO] ArgoCD pod "argocd-redis-secret-init-2tznh" is now in status Succeeded.
[INFO] ArgoCD pod "argocd-application-controller-0" is now in status Running.
[INFO] ArgoCD pod "argocd-server-6dbfbd4788-ljq4t" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-66f5cf65cf-rnthz" is now in status Running.
[INFO] ArgoCD pod "argocd-repo-server-6dc9c95578-55bkz" is now in status Running.
[INFO] All 5 ArgoCD pods are ready.
[INFO] ArgoCD namespace "vcf-context-01:argocd-c1157" is now available with all pods ready.
[INFO] To login to ArgoCD:
[INFO] Go to https://10.30.12.204/
[INFO] Login as user "admin" using temporary password: FKJxVIDZZnRSNJan
[INFO] To update your password run: "argocd.exe account update-password --server 10.30.12.204 --account admin --insecure"
[INFO] Completed deployment for cluster with edgeSite: ESA

[INFO] Starting deployment for edgeSite: "OSA" (site 2 of 3).

[INFO] No cluster named "cluster-OSA" was found on vCenter "10.191.174.202". Proceeding with cluster creation.
[INFO] Using vLCM image from configuration: "ESX902-ESA".

DisplayName BaseImage
----------- ---------
ESX902-ESA  9.0.2.0.25148076

[INFO] Creating the cluster "cluster-OSA" on vCenter "10.191.174.202"...  Success
[INFO] Adding ESX host "10.191.171.201" to cluster "cluster-OSA"... Success
[INFO] Adding ESX host "10.191.171.171" to cluster "cluster-OSA"... Success
[INFO] Creating VDS "VDS-OSA" on vCenter "10.191.174.202"...  Success
[INFO] Creating management port group "mgmt-OSA" on VDS "VDS-OSA" (VLAN 0).
[INFO] Added pNIC "vmnic1" to VDS "VDS-OSA" on host "10.191.171.201".
[INFO] Migrated management (vmk0) to VDS "VDS-OSA" port group "mgmt-OSA" on host "10.191.171.201".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.201".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-OSA" on host "10.191.171.201".
[INFO] Added pNIC "vmnic1" to VDS "VDS-OSA" on host "10.191.171.171".
[INFO] Migrated management (vmk0) to VDS "VDS-OSA" port group "mgmt-OSA" on host "10.191.171.171".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.171".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-OSA" on host "10.191.171.171".
[INFO] Creating port group "primaryworkloadnetwork-2" on VDS "VDS-OSA" with VLAN ID 400... Success
[INFO] Creating port group "flbmanagementnetwork-2" on VDS "VDS-OSA" with VLAN ID 401... Success
[INFO] Creating port group "virtualservernetwork-2" on VDS "VDS-OSA" with VLAN ID 402... Success
[INFO] Creating port group "tkgsmgmtnetwork-2" on VDS "VDS-OSA" with VLAN ID 403... Success
[INFO] VDS "VDS-OSA": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] Creating port group "vmotion-OSA" on VDS "VDS-OSA" with VLAN ID 404... Success
[INFO] Creating port group "vsan-OSA" on VDS "VDS-OSA" with VLAN ID 405... Success
[INFO] Created VMkernel for "vMotion" on host "10.191.171.201" (port group "vmotion-OSA", IP 10.40.14.12, MTU 9000).
[INFO] Created VMkernel for "vMotion" on host "10.191.171.171" (port group "vmotion-OSA", IP 10.40.14.13, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.201" (port group "vsan-OSA", IP 10.40.15.12, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.171" (port group "vsan-OSA", IP 10.40.15.13, MTU 9000).
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.201". Skipping witness traffic add.
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.171". Skipping witness traffic add.
[INFO] Successfully created tag catalog "vSAN-OSA-Storage-TagCatalog" on "10.191.174.202".
[INFO] Successfully created tag name "supervisor-OSA" on "vSAN-OSA-Storage-TagCatalog".
[INFO] Reconfiguring cluster-OSA for HA after moving vmk0 to vDS...
[INFO] Successfully configured VM monitoring settings on cluster "cluster-OSA".
[INFO] Ensuring vSAN configuration is applied to all hosts in cluster "cluster-OSA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-OSA".
[INFO] Retrieving vSAN OSA eligible disks for cluster "cluster-OSA" from all hosts...
[INFO] Found 4 eligible disk(s) for cluster "cluster-OSA".

vSAN OSA disks claimed for cluster "cluster-OSA" (cache/capacity per host):

Id VMHostName     CanonicalName                        CapacityGB Model                         IsSsd DefaultRole
-- ----------     -------------                        ---------- -----                         ----- -----------
 1 10.191.171.201 eui.e66a4e2eb30856f8000c29699a742394      80.00 NVMe VMware Virtual NVMe Disk  True Cache
 2 10.191.171.201 eui.d3ee04ac6896d25b000c296fa2e103bd     500.00 NVMe VMware Virtual NVMe Disk  True Capacity
 3 10.191.171.171 eui.cfdfa098b55ca99f000c2967f13d0e89      80.00 NVMe VMware Virtual NVMe Disk  True Cache
 4 10.191.171.171 eui.1034ab032139f5ac000c29641fd53e42     500.00 NVMe VMware Virtual NVMe Disk  True Capacity

[INFO] vSAN OSA disk group assignment completed for 2 host(s) (default cache/capacity).
[INFO] Creating vSAN OSA disk group on host "10.191.171.171" (1 cache, 1 capacity disk(s)).
[INFO] Successfully created vSAN OSA disk group on host "10.191.171.171".
[INFO] Creating vSAN OSA disk group on host "10.191.171.201" (1 cache, 1 capacity disk(s)).
[INFO] Successfully created vSAN OSA disk group on host "10.191.171.201".
[INFO] Successfully configured vSAN OSA disk groups for all hosts in cluster "cluster-OSA".
[INFO] Waiting for vSAN datastore to become available and renaming to "datastore-OSA"... Success
[INFO] Configuring vSAN witness for cluster "cluster-OSA" (witness host: "10.191.174.197").
[INFO] Checking whether witness host "10.191.174.197" already has a vSAN OSA disk group...
[INFO] Witness host "10.191.174.197" already has a vSAN OSA disk group. Skipping disk group creation.
[INFO] Configuring vSAN witness host for cluster "cluster-OSA"...
[INFO] Ensure connectivity between cluster hosts and witness through vSAN Witness VMkernel interface.
[INFO] Enabling stretched cluster mode and configuring witness host "10.191.174.197" for cluster "cluster-OSA"...
[INFO] Successfully configured witness host "10.191.174.197" for cluster "cluster-OSA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-OSA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-OSA" (config pushed from vCenter to hosts).
[INFO] Running vSAN cluster health check for cluster "cluster-OSA" (after witness).
[INFO] Waiting 20 seconds for vSAN health service to reflect HCI workflow skip.
[INFO] Silenced vSAN health checks for lab environment on cluster "cluster-OSA": advcfgsync, controllerdiskmode, controlleronhcl.
[INFO] vSAN advanced config not in sync on all hosts for cluster "cluster-OSA". Pushing current vSAN cluster config from vCenter to hosts.
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-OSA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-OSA" (config pushed from vCenter to hosts).
[INFO] vSAN cluster config re-applied for cluster "cluster-OSA". Sync may complete asynchronously; proceeding.
[INFO] vSAN cluster health is green for cluster "cluster-OSA". Proceeding.
[INFO] Enabled vSAN performance service on cluster "cluster-OSA".
[INFO] Successfully tagged vSAN OSA datastore "datastore-OSA" with tag "supervisor-OSA" (catalog "vSAN-OSA-Storage-TagCatalog").
[INFO] Storage policy "supervisor-OSA" already contains tag "supervisor-OSA" from catalog "vSAN-OSA-Storage-TagCatalog". Skipping tag add.
[INFO] Cluster "cluster-OSA" is compliant to the vLCM image. No remediation required.
[INFO] Suppress 10 GB networking alarm if present (Broadcom KB 394932) on 2/2 host(s) in cluster "cluster-OSA".
[WARNING] vSAN cluster "cluster-OSA" has alarm (not auto-remediated): "vSAN performance service alarm 'Stats primary election'" (status: red). Resolve manually if needed.
[INFO] Forming ArgoCD namespace name "argocd-c1202" from prefix "argocd" and cluster MoRef suffix: "-c1202" to ensure uniqueness.
[INFO] Retrieving supervisor ID for "supervisor-OSA" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-OSA"...
[INFO]   Supervisor "supervisor-OSA" not found.
[INFO] [Step 3/3] Supervisor instance "supervisor-OSA" not found. Proceeding to create it.
[INFO] Beginning Supervisor deployment to cluster "cluster-OSA"...
[INFO] [Step 1/5] Parsing supervisor configuration from JSON...
[INFO]   Management network configuration extracted: tkgsmgmtnetwork-2 with 7 IPs
[INFO]     Starting IP: 10.40.13.100, Gateway: 10.40.13.1/24.
[INFO]   Workload network configuration extracted: primaryworkloadnetwork-2 with 100 node IPs and 512 service IPs.
[INFO]     Node IP: 10.40.10.101, Service IP: 10.97.0.0.
[INFO]   FLB network configuration extracted: flbmanagementnetwork-2, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 40
[INFO]   FLB network configuration extracted: virtualservernetwork-2, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 60
[INFO] FLB configuration extracted: flb-site2, Size: MEDIUM, VIPs: 50
[INFO] Supervisor configuration parsed successfully for edgeSite: OSA.
[INFO] Control Plane: 1 x SMALL
[INFO] Management Network: tkgsmgmtnetwork-2
[INFO] Workload Network: primaryworkloadnetwork-2
[INFO] Load Balancer: flb-site2
[INFO] Configuration validation passed.
[INFO] [Step 2/5] Building Supervisor specifications...
[INFO]    Building control plane specification...
[INFO]    Control plane specification built successfully: Size=SMALL, VMs=1
[INFO]    Workload network specification built successfully: primaryworkloadnetwork-2
[INFO] [Step 3/5] Assembling complete supervisor specification...
[INFO] [Step 4/5] Invoking supervisor creation API...
[INFO]    Invoking supervisor creation on cluster "cluster-OSA" (ID: domain-c1202)...
[INFO] [Step 4/5] Supervisor API invocation completed. ID: ab09ea39-6989-4ad4-819c-d5f2b76b3107
[INFO] [Step 5/5] Monitoring supervisor deployment status...
[INFO] Supervisor services on cluster "cluster-OSA" were successfully configured in 1560 seconds.
[INFO] [Step 5/5] Supervisor is ready (elapsed: 1560 seconds)
[INFO] Supervisor deployment completed successfully. Supervisor ID: ab09ea39-6989-4ad4-819c-d5f2b76b3107
[INFO] Checking for available supervisor upgrade versions...
[INFO] No supervisor upgrade available. Current version v1.32.9+vmware.2-fips-vsc9.0.2.0-25129014 is up to date.
[INFO] Using all available VM classes for ArgoCD namespace: best-effort-xsmall, guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-medium, best-effort-2xlarge, guaranteed-4xlarge, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, best-effort-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge
[INFO] Configuring VM classes: best-effort-xsmall, guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-medium, best-effort-2xlarge, guaranteed-4xlarge, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, best-effort-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge
[INFO] The ArgoCD namespace "argocd-c1202" was created successfully.
[INFO] VM classes assigned: best-effort-xsmall, guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-medium, best-effort-2xlarge, guaranteed-4xlarge, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, best-effort-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge
[INFO] The ArgoCD operator was successfully created.  Waiting for configuration tasks to complete.
[INFO] The ArgoCD operator has been successfully installed on vCenter "10.191.174.202". (Took 185 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.40.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01"...
[ok] Token is still active. Skipped the token refresh for context "vcf-context-01"
[i] Successfully activated context 'vcf-context-01' (Type: kubernetes)
[i] Fetching recommended plugins for active context 'vcf-context-01'...
[ok] All recommended plugins are already installed and up-to-date.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] Applying ArgoCD deployment YAML file "C:\Users\Administrator\AppData\Local\Temp\tmpmk5blj.yml" to namespace "argocd-c1202"...
[INFO] Successfully applied ArgoCD deployment YAML. Output: argocd.argocd-service.vsphere.vmware.com/argocd-instance-1 created
[INFO] kubectl context "vcf-context-01:argocd-c1202" does not exist. This is expected if the namespace was just created. Continuing with namespace flag -n for kubectl operations.
[INFO] Verifying kubectl authentication for namespace "argocd-c1202" (timeout: 60 seconds)...
[INFO] kubectl authentication verified for namespace "argocd-c1202" after 0 seconds
[INFO] ArgoCD pod "argocd-redis-secret-init-5hb4j" is now in status Succeeded.
[INFO] ArgoCD pod "argocd-application-controller-0" is now in status Running.
[INFO] ArgoCD pod "argocd-repo-server-5cfc9447db-5bqfs" is now in status Running.
[INFO] ArgoCD pod "argocd-server-fdf6b696f-9j85v" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-844c94d7f5-8spj9" is now in status Running.
[INFO] All 5 ArgoCD pods are ready.
[INFO] ArgoCD namespace "vcf-context-01:argocd-c1202" is now available with all pods ready.
[INFO] To login to ArgoCD:
[INFO] Go to https://10.40.12.204/
[INFO] Login as user "admin" using temporary password: uFVLRVOVNs8i7wQj
[INFO] To update your password run: "argocd.exe account update-password --server 10.40.12.204 --account admin --insecure"
[INFO] Completed deployment for cluster with edgeSite: OSA

[INFO] Starting deployment for edgeSite: "VMFS" (site 3 of 3).

[INFO] Datastore "datastore-VMFS" not found on ESX host "10.191.171.172".
[INFO] Selected largest available drive for VMFS (CapacityGB=500, CanonicalName=eui.b7a6f4385485d169000c2960802a75c4).
[INFO] No cluster named "cluster-VMFS" was found on vCenter "10.191.174.202". Proceeding with cluster creation.
[INFO] Using vLCM image from configuration: "ESX902-ESA".

DisplayName BaseImage
----------- ---------
ESX902-ESA  9.0.2.0.25148076

[INFO] Creating the cluster "cluster-VMFS" on vCenter "10.191.174.202"...  Success
[INFO] Adding ESX host "10.191.171.172" to cluster "cluster-VMFS"... Success
[INFO] Creating VDS "VDS-VMFS" on vCenter "10.191.174.202"...  Success
[INFO] Creating management port group "mgmt-VMFS" on VDS "VDS-VMFS" (VLAN 0).
[INFO] Added pNIC "vmnic1" to VDS "VDS-VMFS" on host "10.191.171.172".
[INFO] Migrated management (vmk0) to VDS "VDS-VMFS" port group "mgmt-VMFS" on host "10.191.171.172".
[INFO] Removed standard switch "vSwitch0" from host "10.191.171.172".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-VMFS" on host "10.191.171.172".
[INFO] Creating port group "primaryworkloadnetwork-3" on VDS "VDS-VMFS" with VLAN ID 500... Success
[INFO] Creating port group "flbmanagementnetwork-3" on VDS "VDS-VMFS" with VLAN ID 501... Success
[INFO] Creating port group "virtualservernetwork-3" on VDS "VDS-VMFS" with VLAN ID 502... Success
[INFO] Creating port group "tkgsmgmtnetwork-3" on VDS "VDS-VMFS" with VLAN ID 503... Success
[INFO] VDS "VDS-VMFS": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] Tag catalog "VMFS-Storage-TagCatalog" already exists on vCenter "10.191.174.202". Skipping tag catalog creation.
[INFO] Tag name "supervisor-VMFS" already exists on "VMFS-Storage-TagCatalog". Skipping tag creation.
[INFO] Reconfiguring cluster-VMFS for HA after moving vmk0 to vDS...
[INFO] Cluster "cluster-VMFS" has one host; HA enabled (admission control disabled), DRS enabled.
[INFO] Creating the new datastore "datastore-VMFS" on ESX host "10.191.171.172"...  Success
[INFO] Successfully tagged datastore "datastore-VMFS" with tag "supervisor-VMFS".
[INFO] Storage policy "supervisor-VMFS" already contains tag "supervisor-VMFS" from catalog "VMFS-Storage-TagCatalog". Skipping tag add.
[INFO] Cluster "cluster-VMFS" is not compliant to the vLCM image (Status: NonCompliant; NonCompliantHosts: 1 - 10.191.171.172). Remediating...
[INFO] vLCM remediation completed for cluster "cluster-VMFS".
[INFO] Forming ArgoCD namespace name "argocd-c1246" from prefix "argocd" and cluster MoRef suffix: "-c1246" to ensure uniqueness.
[INFO] Retrieving supervisor ID for "supervisor-VMFS" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-VMFS"...
[INFO]   Supervisor "supervisor-VMFS" not found.
[INFO] [Step 3/3] Supervisor instance "supervisor-VMFS" not found. Proceeding to create it.
[INFO] Beginning Supervisor deployment to cluster "cluster-VMFS"...
[INFO] [Step 1/5] Parsing supervisor configuration from JSON...
[INFO]   Management network configuration extracted: tkgsmgmtnetwork-3 with 7 IPs
[INFO]     Starting IP: 10.50.13.100, Gateway: 10.50.13.1/24.
[INFO]   Workload network configuration extracted: primaryworkloadnetwork-3 with 100 node IPs and 512 service IPs.
[INFO]     Node IP: 10.50.10.101, Service IP: 10.97.0.0.
[INFO]   FLB network configuration extracted: flbmanagementnetwork-3, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 40
[INFO]   FLB network configuration extracted: virtualservernetwork-3, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 60
[INFO] FLB configuration extracted: flb-site3, Size: MEDIUM, VIPs: 50
[INFO] Supervisor configuration parsed successfully for edgeSite: VMFS.
[INFO] Control Plane: 1 x SMALL
[INFO] Management Network: tkgsmgmtnetwork-3
[INFO] Workload Network: primaryworkloadnetwork-3
[INFO] Load Balancer: flb-site3
[INFO] Configuration validation passed.
[INFO] [Step 2/5] Building Supervisor specifications...
[INFO]    Building control plane specification...
[INFO]    Control plane specification built successfully: Size=SMALL, VMs=1
[INFO]    Workload network specification built successfully: primaryworkloadnetwork-3
[INFO] [Step 3/5] Assembling complete supervisor specification...
[INFO] [Step 4/5] Invoking supervisor creation API...
[INFO]    Invoking supervisor creation on cluster "cluster-VMFS" (ID: domain-c1246)...
[INFO] [Step 4/5] Supervisor API invocation completed. ID: e00bbdaf-d198-4b43-97e4-ada47ad8a104
[INFO] [Step 5/5] Monitoring supervisor deployment status...
[INFO] Supervisor services on cluster "cluster-VMFS" were successfully configured in 1470 seconds.
[INFO] [Step 5/5] Supervisor is ready (elapsed: 1470 seconds)
[INFO] Supervisor deployment completed successfully. Supervisor ID: e00bbdaf-d198-4b43-97e4-ada47ad8a104
[INFO] Checking for available supervisor upgrade versions...
[INFO] No supervisor upgrade available. Current version v1.32.9+vmware.2-fips-vsc9.0.2.0-25129014 is up to date.
[INFO] Using all available VM classes for ArgoCD namespace: guaranteed-4xlarge, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, best-effort-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-xsmall, guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-medium, best-effort-2xlarge
[INFO] Configuring VM classes: guaranteed-4xlarge, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, best-effort-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-xsmall, guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-medium, best-effort-2xlarge
[INFO] The ArgoCD namespace "argocd-c1246" was created successfully.
[INFO] VM classes assigned: guaranteed-4xlarge, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, best-effort-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-xsmall, guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-medium, best-effort-2xlarge
[INFO] The ArgoCD operator was successfully created.  Waiting for configuration tasks to complete.
[INFO] The ArgoCD operator has been successfully installed on vCenter "10.191.174.202". (Took 40 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.50.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01"...
[ok] Token is still active. Skipped the token refresh for context "vcf-context-01"
[i] Successfully activated context 'vcf-context-01' (Type: kubernetes)
[i] Fetching recommended plugins for active context 'vcf-context-01'...
[ok] All recommended plugins are already installed and up-to-date.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] Applying ArgoCD deployment YAML file "C:\Users\Administrator\AppData\Local\Temp\tmp2e3jwe.yml" to namespace "argocd-c1246"...
[INFO] Successfully applied ArgoCD deployment YAML. Output: argocd.argocd-service.vsphere.vmware.com/argocd-instance-1 created
[INFO] kubectl context "vcf-context-01:argocd-c1246" does not exist. This is expected if the namespace was just created. Continuing with namespace flag -n for kubectl operations.
[INFO] Verifying kubectl authentication for namespace "argocd-c1246" (timeout: 60 seconds)...
[INFO] kubectl authentication verified for namespace "argocd-c1246" after 0 seconds
[INFO] ArgoCD pod "argocd-redis-secret-init-sptp2" is now in status Succeeded.
[INFO] ArgoCD pod "argocd-application-controller-0" is now in status Running.
[INFO] ArgoCD pod "argocd-server-78d5999986-jksj9" is now in status Running.
[INFO] ArgoCD pod "argocd-repo-server-7877d65757-xsjh8" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-5d6d4f5b95-thzzl" is now in status Running.
[INFO] All 5 ArgoCD pods are ready.
[INFO] ArgoCD namespace "vcf-context-01:argocd-c1246" is now available with all pods ready.
[INFO] To login to ArgoCD:
[INFO] Go to https://10.50.12.204/
[INFO] Login as user "admin" using temporary password: Ek1wKB3EU8yM7h3s
[INFO] To update your password run: "argocd.exe account update-password --server 10.50.12.204 --account admin --insecure"
[INFO] Completed deployment for cluster with edgeSite: VMFS
```

## Validate idempotency of one deployment against fully deployed site - 2026-03-04

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -edgesite ESA

[INFO] Checking for required JSON properties for edgeSite(s) "ESA"...
[INFO] Validating property formats and values for edgeSite(s) "ESA"...
[INFO] Processing 1 edge site(s): ESA...
[INFO] Beginning workflow for edgeSite: "ESA".
[INFO] Performing vCenter and ESX reachability check (TCP 443)...
[INFO] Reachability: all targets OK (vCenter and 2 ESX host(s)).
[INFO] The cluster "cluster-ESA" in datacenter "UnitTest" is already present. Skipping cluster creation.
[INFO] Host "10.191.171.173" is already in cluster "cluster-ESA". Skipping host add.
[INFO] Host "10.191.171.174" is already in cluster "cluster-ESA". Skipping host add.
[INFO] VDS "VDS-ESA" is already present. Skipping creation.
[INFO] The ESX host "10.191.171.173" is already attached to VDS "VDS-ESA". Skipping attachment.
[INFO] The ESX host "10.191.171.174" is already attached to VDS "VDS-ESA". Skipping attachment.
[INFO] Host "10.191.171.173" management (vmk0) is already on VDS "VDS-ESA". Skipping migration.
[INFO] Host "10.191.171.174" management (vmk0) is already on VDS "VDS-ESA". Skipping migration.
[INFO] Port group "primaryworkloadnetwork" already exists on VDS "VDS-ESA" with VLAN ID 300. Skipping creation.
[INFO] Port group "flbmanagementnetwork" already exists on VDS "VDS-ESA" with VLAN ID 301. Skipping creation.
[INFO] Port group "virtualservernetwork" already exists on VDS "VDS-ESA" with VLAN ID 302. Skipping creation.
[INFO] Port group "tkgsmgmtnetwork" already exists on VDS "VDS-ESA" with VLAN ID 303. Skipping creation.
[INFO] Port group "vmotion-ESA" already exists on VDS "VDS-ESA" with VLAN ID 304. Skipping creation.
[INFO] Port group "vsan-ESA" already exists on VDS "VDS-ESA" with VLAN ID 305. Skipping creation.
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.173". Skipping witness traffic add.
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.174". Skipping witness traffic add.
[INFO] Tag catalog "vSAN-ESA-Storage-TagCatalog" already exists on vCenter "10.191.174.202". Skipping tag catalog creation.
[INFO] Tag name "supervisor-ESA" already exists on "vSAN-ESA-Storage-TagCatalog". Skipping tag creation.
[INFO] Ensuring vSAN configuration is applied to all hosts in cluster "cluster-ESA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-ESA" (config pushed from vCenter to hosts).
[INFO] vSAN datastore "datastore-ESA" already exists with capacity 1159.73 GB and is accessible by all cluster hosts. Skipping vSAN steps.
[INFO] vSAN datastore already exists and witness "10.191.174.196" is already configured for cluster "cluster-ESA". Skipping witness configuration and health check.
[INFO] vSAN ESA datastore "datastore-ESA" already has tag "supervisor-ESA" (catalog "vSAN-ESA-Storage-TagCatalog") assigned. Skipping tag assignment.
[INFO] Storage policy "supervisor-ESA" already contains tag "supervisor-ESA" from catalog "vSAN-ESA-Storage-TagCatalog". Skipping tag add.
[INFO] Cluster "cluster-ESA" is compliant to the vLCM image. No remediation required.
[INFO] Suppress 10 GB networking alarm if present (Broadcom KB 394932) on 2/2 host(s) in cluster "cluster-ESA".
[WARNING] vSAN cluster "cluster-ESA" has alarm (not auto-remediated): "Host memory usage" (status: red). Resolve manually if needed.
[INFO] Forming ArgoCD namespace name "argocd-c1157" from prefix "argocd" and cluster MoRef suffix: "-c1157" to ensure uniqueness.
[INFO] Retrieving supervisor ID for "supervisor-ESA" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-ESA"...
[INFO]   Found supervisor "supervisor-ESA" with ID: f4b0be4c-775d-40be-8b74-82089b15510f.
[INFO] [Step 3/3] Waiting for supervisor to become ready...
[INFO]   Waiting for supervisor "supervisor-ESA" to become ready (timeout: 3600 seconds)...
[INFO]   Supervisor "supervisor-ESA" reached READY status after 0 seconds
[INFO] Supervisor instance "supervisor-ESA" reported status ready, after waiting for 0 seconds.
[INFO] Retrieving supervisor ID for "supervisor-ESA" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-ESA"...
[INFO]   Found supervisor "supervisor-ESA" with ID: f4b0be4c-775d-40be-8b74-82089b15510f.
[INFO] [Step 3/3] Waiting for supervisor to become ready...
[INFO]   Waiting for supervisor "supervisor-ESA" to become ready (timeout: 3600 seconds)...
[INFO]   Supervisor "supervisor-ESA" reached READY status after 0 seconds
[INFO] Using all available VM classes for ArgoCD namespace: guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, best-effort-2xlarge, best-effort-medium, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge
[INFO] The ArgoCD namespace "argocd-c1157" already exists on vCenter "10.191.174.202" Skipping namespace creation.
[INFO] ArgoCD service already exists. Verifying configuration status...
[INFO] The ArgoCD operator has been successfully installed on vCenter "10.191.174.202". (Took 0 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.30.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01"...
[ok] Token is still active. Skipped the token refresh for context "vcf-context-01"
[i] Successfully activated context 'vcf-context-01' (Type: kubernetes)
[i] Fetching recommended plugins for active context 'vcf-context-01'...
[ok] All recommended plugins are already installed and up-to-date.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] Applying ArgoCD deployment YAML file "C:\Users\Administrator\AppData\Local\Temp\tmpmpxlyv.yml" to namespace "argocd-c1157"...
[INFO] Successfully applied ArgoCD deployment YAML. Output: argocd.argocd-service.vsphere.vmware.com/argocd-instance-1 unchanged
[INFO] Verifying kubectl authentication for namespace "argocd-c1157" (timeout: 60 seconds)...
[INFO] kubectl authentication verified for namespace "argocd-c1157" after 0 seconds
[INFO] ArgoCD pod "argocd-application-controller-0" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-66f5cf65cf-rnthz" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-secret-init-2tznh" is now in status Succeeded.
[INFO] ArgoCD pod "argocd-repo-server-6dc9c95578-55bkz" is now in status Running.
[INFO] ArgoCD pod "argocd-server-6dbfbd4788-ljq4t" is now in status Running.
[INFO] All 5 ArgoCD pods are ready.
[INFO] ArgoCD namespace "vcf-context-01:argocd-c1157" is now available with all pods ready.
[INFO] To login to ArgoCD:
[INFO] Go to https://10.30.12.204/
[INFO] Login as user "admin" using temporary password: FKJxVIDZZnRSNJan
[INFO] To update your password run: "argocd.exe account update-password --server 10.30.12.204 --account admin --insecure"
[INFO] Completed deployment for cluster with edgeSite: ESA
```

## Cleanup ArgoCD app (one site, force option (no prompt)) - 2026-03-04

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -Edgesite OSA -Cleanup argocd -Force

[INFO] Processing 1 edge site(s): OSA...
[INFO] Beginning workflow for edgeSite: "OSA".
[INFO] Performing vCenter reachability check (TCP 443) for cleanup...
[INFO] Reachability: vCenter OK.
[ADVISORY] Running in lab mode (common.labenvironment is true in infrastructure JSON).
[INFO] CleanUp is set to "ArgoCD". Cleaning up per scope, then exiting without deploying.
[ADVISORY] Skipping cleanup confirmation (labEnvironment=true and -Force).
[INFO] ArgoCD namespace "argocd-c1202" deleted successfully for cluster "cluster-OSA".
[INFO] CleanUp (ArgoCD) completed. Exiting without deployment.
```

## Example of cleanup of supervisor for one site - 2026-03-05

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -Edgesite OSA -Cleanup supervisor

[INFO] Processing 1 edge site(s): OSA...
[INFO] Beginning workflow for edgeSite: "OSA".
[INFO] Performing vCenter reachability check (TCP 443) for cleanup...
[INFO] Reachability: vCenter OK.
[ADVISORY] Running in lab mode (common.labenvironment is true in infrastructure JSON).
[INFO] CleanUp is set to "Supervisor". Cleaning up per scope, then exiting without deploying.

[ADVISORY] The cleanup process for supervisor will remove all the VMware vSphere Kubernetes Service (VKS) applications in cluster "cluster-OSA". Please backup your data before proceeding.
To confirm cleanup, type exactly (or copy/paste): delete supervisor for OSA
 delete supervisor for OSA
[INFO] Deactivating supervisor on cluster "cluster-OSA" (ID: domain-c1202)...
[INFO] Supervisor deactivation initiated. Polling until fully deactivated (timeout: 3600 seconds)...
[INFO] Supervisor on cluster "cluster-OSA" is fully deactivated after 660 seconds. You can retry deployment.
[INFO] Supervisor deactivated on cluster "cluster-OSA". Compute (VDS, vSAN/VMFS, cluster) remains.
[INFO] CleanUp (Supervisor) completed. Exiting without deployment.
```

## Example of cleanup of compute for one site - 2026-03-04

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -edgesite OSA -Cleanup compute

[INFO] Processing 1 edge site(s): OSA...
[INFO] Beginning workflow for edgeSite: "OSA".
[INFO] Performing vCenter reachability check (TCP 443) for cleanup...
[INFO] Reachability: vCenter OK.
[ADVISORY] Running in lab mode (common.labenvironment is true in infrastructure JSON).
[INFO] CleanUp is set to "Compute". Cleaning up per scope, then exiting without deploying.

[ADVISORY] The cleanup process will remove all resources on edgeSite "OSA" including cluster "cluster-OSA" and datastore "datastore-OSA". Please backup your data before proceeding.
To confirm cleanup, type exactly (or copy/paste): delete compute for OSA
 delete compute for OSA
[INFO] Removing non-management VMkernel interfaces from hosts on VDS "VDS-OSA"... Removed 4 interface(s) from 2 host(s).
[INFO] Restoring management (vmk0) to standard switch on hosts... Moved management to VSS on 2 host(s).
[INFO] Starting vSAN deployment rollback for cluster "cluster-OSA" (vSAN-OSA)...
[INFO] Removing vSAN disk claims from 2 host(s) (OSA disk groups), then vsan cluster leave.
[INFO] vSAN disk removal completed for 2 host(s).
[INFO] vSAN cluster leave completed for cluster "cluster-OSA".
[INFO] Removing storage tag "supervisor-OSA" (catalog "vSAN-OSA-Storage-TagCatalog") from vCenter... Removed
[INFO] Removing empty tag category "vSAN-OSA-Storage-TagCatalog" from vCenter... Removed
[INFO] vSAN deployment rollback completed for cluster "cluster-OSA".
[INFO] Detaching 2 host(s) from VDS "VDS-OSA" (removing pNICs)... Done.
[INFO] Removing distributed port groups from VDS "VDS-OSA"... Removed 7 port group(s).
[INFO] Removing Virtual Distributed Switch "VDS-OSA"... Removed
[INFO] Removing cluster "cluster-OSA" (no running VMs)... Removed
[INFO] CleanUp (Compute) completed. Exiting without deployment.
```

## Example of cleanup of one site (all resources) - 2026-03-04

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -Edgesite ESA -Cleanup all

[INFO] Processing 1 edge site(s): ESA...
[INFO] Beginning workflow for edgeSite: "ESA".
[INFO] Performing vCenter reachability check (TCP 443) for cleanup...
[INFO] Reachability: vCenter OK.
[ADVISORY] Running in lab mode (common.labenvironment is true in infrastructure JSON).
[INFO] CleanUp is set to "All". Cleaning up per scope, then exiting without deploying.

[ADVISORY] The cleanup process will remove all resources on edgeSite "ESA" including cluster "cluster-ESA" and datastore "datastore-ESA". Please backup your data before proceeding.
To confirm cleanup, type exactly (or copy/paste): delete all for ESA
delete all for ESA
[INFO] Deactivating supervisor on cluster "cluster-ESA" before compute cleanup (All).
[INFO] Deactivating supervisor on cluster "cluster-ESA" (ID: domain-c1157)...
[INFO] Supervisor deactivation initiated. Polling until fully deactivated (timeout: 3600 seconds)...
[INFO] Supervisor on cluster "cluster-ESA" is fully deactivated after 1330 seconds. You can retry deployment.
[INFO] Removing non-management VMkernel interfaces from hosts on VDS "VDS-ESA"... Removed 4 interface(s) from 2 host(s).
[INFO] Restoring management (vmk0) to standard switch on hosts... Moved management to VSS on 2 host(s).
[INFO] Starting vSAN deployment rollback for cluster "cluster-ESA" (vSAN-ESA)...
[INFO] Removing vSAN ESA storage pool disk claims from 2 host(s), then vsan cluster leave.
[INFO] vSAN disk removal completed for 2 host(s).
[INFO] vSAN cluster leave completed for cluster "cluster-ESA".
[INFO] Removing storage tag "supervisor-ESA" (catalog "vSAN-ESA-Storage-TagCatalog") from vCenter... Removed
[INFO] Removing empty tag category "vSAN-ESA-Storage-TagCatalog" from vCenter... Removed
[INFO] vSAN deployment rollback completed for cluster "cluster-ESA".
[INFO] Detaching 2 host(s) from VDS "VDS-ESA" (removing pNICs)... Done.
[INFO] Removing distributed port groups from VDS "VDS-ESA"... Removed 7 port group(s).
[INFO] Removing Virtual Distributed Switch "VDS-ESA"... Removed
[INFO] Removing cluster "cluster-ESA" (no running VMs)... Removed
[INFO] CleanUp (All) completed. Exiting without deployment.
```

## Example of deployment of one site (four NICs, two vDSs) - 2026-03-04

```powershell
PPS C:\Users\Administrator> start-ModernEdgeAtScale -EdgeSite OSA

[INFO] Checking for required JSON properties for edgeSite(s) "OSA"...
[INFO] Validating property formats and values for edgeSite(s) "OSA"...
[INFO] Processing 1 edge site(s): OSA...
[INFO] Beginning workflow for edgeSite: "OSA".
[INFO] Performing vCenter and ESX reachability check (TCP 443)...
[INFO] Reachability: all targets OK (vCenter and 2 ESX host(s)).
[INFO] No cluster named "cluster-OSA" was found on vCenter "10.191.174.202". Proceeding with cluster creation.
[INFO] Using vLCM image from configuration: "ESX902-ESA".

DisplayName BaseImage
----------- ---------
ESX902-ESA  9.0.2.0.25148076

[INFO] Creating the cluster "cluster-OSA" on vCenter "10.191.174.202"...  Success
[INFO] Adding ESX host "10.191.171.201" to cluster "cluster-OSA"... Success
[INFO] Adding ESX host "10.191.171.171" to cluster "cluster-OSA"... Success
[INFO] Creating VDS "VDS-OSA-sw1" on vCenter "10.191.174.202"...  Success
[INFO] Creating VDS "VDS-OSA-sw2" on vCenter "10.191.174.202"...  Success
[INFO] Creating management port group "mgmt-OSA" on VDS "VDS-OSA-sw1" (VLAN 0).
[INFO] Added pNIC "vmnic1" to VDS "VDS-OSA-sw1" on host "10.191.171.201".
[INFO] Migrated management (vmk0) to VDS "VDS-OSA-sw1" port group "mgmt-OSA" on host "10.191.171.201".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.201".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-OSA-sw1" on host "10.191.171.201".
[INFO] Added pNIC "vmnic1" to VDS "VDS-OSA-sw1" on host "10.191.171.171".
[INFO] Migrated management (vmk0) to VDS "VDS-OSA-sw1" port group "mgmt-OSA" on host "10.191.171.171".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.171".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-OSA-sw1" on host "10.191.171.171".
[INFO] Creating port group "primaryworkloadnetwork-2" on VDS "VDS-OSA-sw1" with VLAN ID 400... Success
[INFO] Creating port group "flbmanagementnetwork-2" on VDS "VDS-OSA-sw1" with VLAN ID 401... Success
[INFO] Creating port group "virtualservernetwork-2" on VDS "VDS-OSA-sw1" with VLAN ID 402... Success
[INFO] Creating port group "tkgsmgmtnetwork-2" on VDS "VDS-OSA-sw1" with VLAN ID 403... Success
[INFO] VDS "VDS-OSA-sw1": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] VDS "VDS-OSA-sw2": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] Creating port group "vmotion-OSA" on VDS "VDS-OSA-sw2" with VLAN ID 404... Success
[INFO] Creating port group "vsan-OSA" on VDS "VDS-OSA-sw2" with VLAN ID 405... Success
[INFO] Created VMkernel for "vMotion" on host "10.191.171.201" (port group "vmotion-OSA", IP 10.40.14.12, MTU 9000).
[INFO] Created VMkernel for "vMotion" on host "10.191.171.171" (port group "vmotion-OSA", IP 10.40.14.13, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.201" (port group "vsan-OSA", IP 10.40.15.12, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.171" (port group "vsan-OSA", IP 10.40.15.13, MTU 9000).
[INFO] Added vSAN witness traffic to vmk0 on host "10.191.171.201".
[INFO] Added vSAN witness traffic to vmk0 on host "10.191.171.171".
[INFO] Successfully created tag catalog "vSAN-OSA-Storage-TagCatalog" on "10.191.174.202".
[INFO] Successfully created tag name "supervisor-OSA" on "vSAN-OSA-Storage-TagCatalog".
[INFO] Reconfiguring cluster-OSA for HA after moving vmk0 to vDS...
[INFO] Successfully configured VM monitoring settings on cluster "cluster-OSA".
[INFO] Ensuring vSAN configuration is applied to all hosts in cluster "cluster-OSA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-OSA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-OSA" (config pushed from vCenter to hosts).
[INFO] Retrieving vSAN OSA eligible disks for cluster "cluster-OSA" from all hosts...
[INFO] Found 4 eligible disk(s) for cluster "cluster-OSA".

vSAN OSA disks claimed for cluster "cluster-OSA" (cache/capacity per host):

Id VMHostName     CanonicalName                        CapacityGB Model                         IsSsd DefaultRole
-- ----------     -------------                        ---------- -----                         ----- -----------
 1 10.191.171.201 eui.e66a4e2eb30856f8000c29699a742394      80.00 NVMe VMware Virtual NVMe Disk  True Cache
 2 10.191.171.201 eui.d3ee04ac6896d25b000c296fa2e103bd     500.00 NVMe VMware Virtual NVMe Disk  True Capacity
 3 10.191.171.171 eui.cfdfa098b55ca99f000c2967f13d0e89      80.00 NVMe VMware Virtual NVMe Disk  True Cache
 4 10.191.171.171 eui.1034ab032139f5ac000c29641fd53e42     500.00 NVMe VMware Virtual NVMe Disk  True Capacity

[INFO] vSAN OSA disk group assignment completed for 2 host(s) (default cache/capacity).
[INFO] Creating vSAN OSA disk group on host "10.191.171.171" (1 cache, 1 capacity disk(s)).
[INFO] Successfully created vSAN OSA disk group on host "10.191.171.171".
[INFO] Creating vSAN OSA disk group on host "10.191.171.201" (1 cache, 1 capacity disk(s)).
[INFO] Successfully created vSAN OSA disk group on host "10.191.171.201".
[INFO] Successfully configured vSAN OSA disk groups for all hosts in cluster "cluster-OSA".
[INFO] Waiting for vSAN datastore to become available and renaming to "datastore-OSA"... Success
[INFO] Configuring vSAN witness for cluster "cluster-OSA" (witness host: "10.191.174.197").
[INFO] Checking whether witness host "10.191.174.197" already has a vSAN OSA disk group...
[INFO] Witness host "10.191.174.197" already has a vSAN OSA disk group. Skipping disk group creation.
[INFO] Configuring vSAN witness host for cluster "cluster-OSA"...
[INFO] Ensure connectivity between cluster hosts and witness through vSAN Witness VMkernel interface.
[INFO] Enabling stretched cluster mode and configuring witness host "10.191.174.197" for cluster "cluster-OSA"...
[INFO] Successfully configured witness host "10.191.174.197" for cluster "cluster-OSA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-OSA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-OSA" (config pushed from vCenter to hosts).
[INFO] Running vSAN cluster health check for cluster "cluster-OSA" (after witness).
[INFO] Waiting 20 seconds for vSAN health service to reflect HCI workflow skip.
[INFO] Silenced vSAN health checks for lab environment on cluster "cluster-OSA": advcfgsync, controllerdiskmode, controlleronhcl.
[INFO] vSAN advanced config not in sync on all hosts for cluster "cluster-OSA". Pushing current vSAN cluster config from vCenter to hosts.
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-OSA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-OSA" (config pushed from vCenter to hosts).
[INFO] vSAN cluster config re-applied for cluster "cluster-OSA". Sync may complete asynchronously; proceeding.
[INFO] vSAN cluster health is green for cluster "cluster-OSA". Proceeding.
[INFO] Enabled vSAN performance service on cluster "cluster-OSA".
[INFO] Successfully tagged vSAN OSA datastore "datastore-OSA" with tag "supervisor-OSA" (catalog "vSAN-OSA-Storage-TagCatalog").
[INFO] Storage policy "supervisor-OSA" already contains tag "supervisor-OSA" from catalog "vSAN-OSA-Storage-TagCatalog".
[INFO] Cluster "cluster-OSA" is compliant to the vLCM image. No remediation required.
[INFO] Suppress 10 GB networking alarm if present (Broadcom KB 394932) on 2/2 host(s) in cluster "cluster-OSA".
[WARNING] vSAN cluster "cluster-OSA" has alarm (not auto-remediated): "vSAN cluster alarm 'vSAN Cluster Configuration Consistency'" (status: yellow). Resolve manually if needed.
[INFO] vSAN cluster "cluster-OSA" has alarm: "vSAN performance service alarm 'Performance service status'" (status: yellow). Attempting to enable vSAN performance service programmatically.
[INFO] If the alarm persists, it often clears within a few minutes as the performance service starts. Otherwise enable in vCenter (vSAN Services) or check vSAN Health > Performance service.
[INFO] Forming ArgoCD namespace name "argocd-c1283" from prefix "argocd" and cluster MoRef suffix: "-c1283" to ensure uniqueness.
[INFO] Retrieving supervisor ID for "supervisor-OSA" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-OSA"...
[INFO]   Supervisor "supervisor-OSA" not found.
[INFO] [Step 3/3] Supervisor instance "supervisor-OSA" not found. Proceeding to create it.
[INFO] Beginning Supervisor deployment to cluster "cluster-OSA"...
[INFO] [Step 1/5] Parsing supervisor configuration from JSON...
[INFO]   Management network configuration extracted: tkgsmgmtnetwork-2 with 7 IPs
[INFO]     Starting IP: 10.40.13.100, Gateway: 10.40.13.1/24.
[INFO]   Workload network configuration extracted: primaryworkloadnetwork-2 with 100 node IPs and 512 service IPs.
[INFO]     Node IP: 10.40.10.101, Service IP: 10.97.0.0.
[INFO]   FLB network configuration extracted: flbmanagementnetwork-2, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 40
[INFO]   FLB network configuration extracted: virtualservernetwork-2, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 60
[INFO] FLB configuration extracted: flb-site2, Size: MEDIUM, VIPs: 50
[INFO] Supervisor configuration parsed successfully for edgeSite: OSA.
[INFO] Control Plane: 1 x SMALL
[INFO] Management Network: tkgsmgmtnetwork-2
[INFO] Workload Network: primaryworkloadnetwork-2
[INFO] Load Balancer: flb-site2
[INFO] Configuration validation passed.
[INFO] [Step 2/5] Building Supervisor specifications...
[INFO]    Building control plane specification...
[INFO]    Control plane specification built successfully: Size=SMALL, VMs=1
[INFO]    Workload network specification built successfully: primaryworkloadnetwork-2
[INFO] [Step 3/5] Assembling complete supervisor specification...
[INFO] [Step 4/5] Invoking supervisor creation API...
[INFO]    Invoking supervisor creation on cluster "cluster-OSA" (ID: domain-c1283)...
[INFO] [Step 4/5] Supervisor API invocation completed. ID: a1452e65-e213-41fc-8653-82cfb13a1fc2
[INFO] [Step 5/5] Monitoring supervisor deployment status...
[INFO] Supervisor services on cluster "cluster-OSA" were successfully configured in 1715 seconds.
[INFO] [Step 5/5] Supervisor is ready (elapsed: 1715 seconds)
[INFO] Supervisor deployment completed successfully. Supervisor ID: a1452e65-e213-41fc-8653-82cfb13a1fc2
[INFO] Checking for available supervisor upgrade versions...
[INFO] No supervisor upgrade available. Current version v1.32.9+vmware.2-fips-vsc9.0.2.0-25129014 is up to date.
[INFO] Using all available VM classes for ArgoCD namespace: guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, best-effort-8xlarge, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge, guaranteed-small, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, guaranteed-xsmall, best-effort-medium, best-effort-2xlarge
[INFO] Configuring VM classes: guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, best-effort-8xlarge, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge, guaranteed-small, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, guaranteed-xsmall, best-effort-medium, best-effort-2xlarge
[INFO] The ArgoCD namespace "argocd-c1283" was created successfully.
[INFO] VM classes assigned: guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, best-effort-8xlarge, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge, guaranteed-small, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, guaranteed-xsmall, best-effort-medium, best-effort-2xlarge
[INFO] The ArgoCD operator was successfully created.  Waiting for configuration tasks to complete.
[INFO] The ArgoCD operator has been successfully installed on vCenter "10.191.174.202". (Took 190 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.40.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01"...
[ok] Token is still active. Skipped the token refresh for context "vcf-context-01"
[i] Successfully activated context 'vcf-context-01' (Type: kubernetes)
[i] Fetching recommended plugins for active context 'vcf-context-01'...
[ok] All recommended plugins are already installed and up-to-date.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] Applying ArgoCD deployment YAML file "C:\Users\Administrator\AppData\Local\Temp\tmpftzr1r.yml" to namespace "argocd-c1283"...
[INFO] Successfully applied ArgoCD deployment YAML. Output: argocd.argocd-service.vsphere.vmware.com/argocd-instance-1 created
[INFO] kubectl context "vcf-context-01:argocd-c1283" does not exist. This is expected if the namespace was just created. Continuing with namespace flag -n for kubectl operations.
[INFO] Verifying kubectl authentication for namespace "argocd-c1283" (timeout: 60 seconds)...
[INFO] kubectl authentication verified for namespace "argocd-c1283" after 0 seconds
[INFO] ArgoCD pod "argocd-redis-secret-init-6kf5p" is now in status Succeeded.
[INFO] ArgoCD pod "argocd-application-controller-0" is now in status Running.
[INFO] ArgoCD pod "argocd-repo-server-77b766dbc9-qmjq8" is now in status Running.
[INFO] ArgoCD pod "argocd-server-5df67f5f67-4pwwd" is now in status Running.
[INFO] All 5 ArgoCD pods are ready.
[INFO] ArgoCD namespace "vcf-context-01:argocd-c1283" is now available with all pods ready.
[INFO] To login to ArgoCD:
[INFO] Go to https://10.40.12.204/
[INFO] Login as user "admin" using temporary password: uFVLRVOVNs8i7wQj
[INFO] To update your password run: "argocd.exe account update-password --server 10.40.12.204 --account admin --insecure"
[INFO] Completed deployment for cluster with edgeSite: OSA
```

## Example of compute-only one-site deployment (one vDS, two NIC), UN/PW - 2026-03-04

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -EdgeSite ESA -ComputeOnly

[INFO] Checking for required JSON properties for edgeSite(s) "ESA"...
[INFO] Validating property formats and values for edgeSite(s) "ESA"...
[INFO] Processing 1 edge site(s): ESA...
[INFO] Beginning workflow for edgeSite: "ESA".
[INFO] Performing vCenter and ESX reachability check (TCP 443)...
[INFO] Reachability: all targets OK (vCenter and 2 ESX host(s)).

Enter the password for the user "administrator@vsphere.local" on vCenter "10.191.174.202" : ***************

Enter the password for the user "root" on ESX Host(s): 10.191.171.173, 10.191.171.174 : ****************

[INFO] No cluster named "cluster-ESA" was found on vCenter "10.191.174.202". Proceeding with cluster creation.
[INFO] Using vLCM image from configuration: "ESX902-ESA".

DisplayName BaseImage
----------- ---------
ESX902-ESA  9.0.2.0.25148076

[INFO] Creating the cluster "cluster-ESA" on vCenter "10.191.174.202"...  Success
[INFO] Adding ESX host "10.191.171.173" to cluster "cluster-ESA"... Success
[INFO] Adding ESX host "10.191.171.174" to cluster "cluster-ESA"... Success
[INFO] Creating VDS "VDS-ESA" on vCenter "10.191.174.202"...  Success
[INFO] Creating management port group "mgmt-ESA" on VDS "VDS-ESA" (VLAN 0).
[INFO] Added pNIC "vmnic1" to VDS "VDS-ESA" on host "10.191.171.173".
[INFO] Migrated management (vmk0) to VDS "VDS-ESA" port group "mgmt-ESA" on host "10.191.171.173".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.173".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-ESA" on host "10.191.171.173".
[INFO] Added pNIC "vmnic1" to VDS "VDS-ESA" on host "10.191.171.174".
[INFO] Migrated management (vmk0) to VDS "VDS-ESA" port group "mgmt-ESA" on host "10.191.171.174".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.174".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-ESA" on host "10.191.171.174".
[INFO] Creating port group "primaryworkloadnetwork" on VDS "VDS-ESA" with VLAN ID 300... Success
[INFO] Creating port group "flbmanagementnetwork" on VDS "VDS-ESA" with VLAN ID 301... Success
[INFO] Creating port group "virtualservernetwork" on VDS "VDS-ESA" with VLAN ID 302... Success
[INFO] Creating port group "tkgsmgmtnetwork" on VDS "VDS-ESA" with VLAN ID 303... Success
[INFO] VDS "VDS-ESA": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] Creating port group "vmotion-ESA" on VDS "VDS-ESA" with VLAN ID 304... Success
[INFO] Creating port group "vsan-ESA" on VDS "VDS-ESA" with VLAN ID 305... Success
[INFO] Created VMkernel for "vMotion" on host "10.191.171.173" (port group "vmotion-ESA", IP 10.30.14.12, MTU 9000).
[INFO] Created VMkernel for "vMotion" on host "10.191.171.174" (port group "vmotion-ESA", IP 10.30.14.13, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.173" (port group "vsan-ESA", IP 10.30.15.12, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.174" (port group "vsan-ESA", IP 10.30.15.13, MTU 9000).
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.173". Skipping witness traffic add.
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.174". Skipping witness traffic add.
[INFO] Successfully created tag catalog "vSAN-ESA-Storage-TagCatalog" on "10.191.174.202".
[INFO] Successfully created tag name "supervisor-ESA" on "vSAN-ESA-Storage-TagCatalog".
[INFO] Reconfiguring cluster-ESA for HA after moving vmk0 to vDS...
[INFO] Successfully configured VM monitoring settings on cluster "cluster-ESA".
[INFO] Ensuring vSAN configuration is applied to all hosts in cluster "cluster-ESA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-ESA".
[INFO] Retrieving vSAN ESA eligible disks for cluster "cluster-ESA" from all hosts...
[INFO] Found 4 eligible disk(s) for cluster "cluster-ESA".

vSAN ESA disks claimed for cluster "cluster-ESA":

Id VMHostName     CanonicalName                        CapacityGB Model
-- ----------     -------------                        ---------- -----
 1 10.191.171.173 eui.1a11431c54cffe8b000c296603ea3add     500.00 VMware Virtual NVMe Disk
 2 10.191.171.173 eui.ba33eac3dc25680b000c29634aad5191      80.00 VMware Virtual NVMe Disk
 3 10.191.171.174 eui.fa196b4e38295c1d000c2965528e53f8     500.00 VMware Virtual NVMe Disk
 4 10.191.171.174 eui.7734d14c0f1daf33000c296f08ecf6e9      80.00 VMware Virtual NVMe Disk

[INFO] vSAN ESA storage pool: all 4 eligible disk(s) will be added.
[INFO] Adding 2 disk(s) to vSAN ESA datastore from host "10.191.171.173"... Success
[INFO] Adding 2 disk(s) to vSAN ESA datastore from host "10.191.171.174"... Success
[INFO] Successfully configured vSAN ESA datastore for all hosts in cluster "cluster-ESA".
[INFO] Waiting for vSAN datastore to become available and renaming to "datastore-ESA"... Success
[INFO] Configuring vSAN witness host for cluster "cluster-ESA".
[INFO] Ensure connectivity between cluster hosts and witness through vSAN Witness VMkernel interface.
[INFO] Enabling stretched cluster mode and configuring witness host "10.191.174.196" for cluster "cluster-ESA"...
[INFO] Successfully configured witness host "10.191.174.196" for cluster "cluster-ESA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-ESA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-ESA" (config pushed from vCenter to hosts).
[INFO] Running vSAN cluster health check for cluster "cluster-ESA" (after witness).
[INFO] Enabled vSAN health Alarms on cluster "cluster-ESA".
[INFO] Waiting 20 seconds for vSAN health service to reflect HCI workflow skip.
[INFO] Silenced vSAN health checks for lab environment on cluster "cluster-ESA": advcfgsync, controllerdiskmode, controlleronhcl.
[INFO] vSAN advanced config not in sync on all hosts for cluster "cluster-ESA". Pushing current vSAN cluster config from vCenter to hosts.
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-ESA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-ESA" (config pushed from vCenter to hosts).
[INFO] vSAN cluster config re-applied for cluster "cluster-ESA". Sync may complete asynchronously; proceeding.
[INFO] vSAN cluster health is green for cluster "cluster-ESA". Proceeding.
[INFO] Successfully tagged vSAN ESA datastore "datastore-ESA" with tag "supervisor-ESA" (catalog "vSAN-ESA-Storage-TagCatalog").
[INFO] Storage policy "supervisor-ESA" already contains tag "supervisor-ESA" from catalog "vSAN-ESA-Storage-TagCatalog". Skipping tag add.
[INFO] Suppress 10 GB networking alarm if present (Broadcom KB 394932) on 2/2 host(s) in cluster "cluster-ESA".
[INFO] ComputeOnly is set. Pre-supervisor steps complete for cluster "cluster-ESA". Skipping supervisor and post-supervisor steps.
[INFO] ComputeOnly completed. All pre-supervisor steps finished. Exiting without enabling supervisor.
```

## Example of deploying two sites (vSAN-OSA, vSAN-ESA) - 2026-03-05

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -EdgeSite "OSA,ESA"

[INFO] Checking for required JSON properties for edgeSite(s) "OSA", "ESA"...
[INFO] Validating property formats and values for edgeSite(s) "OSA", "ESA"...
[INFO] Processing 2 edge site(s): OSA, ESA...
[INFO] Beginning workflow for 2 edge site(s), starting with edgeSite: "OSA".
[INFO] Performing vCenter and ESX reachability check (TCP 443)...
[INFO] Reachability: all targets OK (vCenter and 4 ESX host(s)).

Enter the password for the user "administrator@vsphere.local" on vCenter "10.191.174.202" : *
PS C:\Users\Administrator> ^C
PS C:\Users\Administrator> Show-InfrastructureJsonConfigurationHelp^C
PS C:\Users\Administrator>
>> $env:VCENTER_COMMON_PASSWORD="VMware1!VMware1!"
>> $env:ESX_COMMON_PASSWORD="VMware1!VMware1!"
>>
PS C:\Users\Administrator> start-ModernEdgeAtScale -EdgeSite "OSA,ESA"

[INFO] Checking for required JSON properties for edgeSite(s) "OSA", "ESA"...
[INFO] Validating property formats and values for edgeSite(s) "OSA", "ESA"...
[INFO] Processing 2 edge site(s): OSA, ESA...
[INFO] Beginning workflow for 2 edge site(s), starting with edgeSite: "OSA".
[INFO] Performing vCenter and ESX reachability check (TCP 443)...
[INFO] Reachability: all targets OK (vCenter and 4 ESX host(s)).
[INFO] No cluster named "cluster-OSA" was found on vCenter "10.191.174.202". Proceeding with cluster creation.
[INFO] Using vLCM image from configuration: "ESX902-ESA".

DisplayName BaseImage
----------- ---------
ESX902-ESA  9.0.2.0.25148076

[INFO] Creating the cluster "cluster-OSA" on vCenter "10.191.174.202"...  Success
[INFO] Adding ESX host "10.191.171.201" to cluster "cluster-OSA"... Success
[INFO] Adding ESX host "10.191.171.171" to cluster "cluster-OSA"... Success
[INFO] Creating VDS "VDS-OSA" on vCenter "10.191.174.202"...  Success
[INFO] Creating management port group "mgmt-OSA" on VDS "VDS-OSA" (VLAN 0).
[INFO] Added pNIC "vmnic1" to VDS "VDS-OSA" on host "10.191.171.201".
[INFO] Migrated management (vmk0) to VDS "VDS-OSA" port group "mgmt-OSA" on host "10.191.171.201".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.201".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-OSA" on host "10.191.171.201".
[INFO] Added pNIC "vmnic1" to VDS "VDS-OSA" on host "10.191.171.171".
[INFO] Migrated management (vmk0) to VDS "VDS-OSA" port group "mgmt-OSA" on host "10.191.171.171".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.171".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-OSA" on host "10.191.171.171".
[INFO] Creating port group "primaryworkloadnetwork-2" on VDS "VDS-OSA" with VLAN ID 400... Success
[INFO] Creating port group "flbmanagementnetwork-2" on VDS "VDS-OSA" with VLAN ID 401... Success
[INFO] Creating port group "virtualservernetwork-2" on VDS "VDS-OSA" with VLAN ID 402... Success
[INFO] Creating port group "tkgsmgmtnetwork-2" on VDS "VDS-OSA" with VLAN ID 403... Success
[INFO] VDS "VDS-OSA": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] Creating port group "vmotion-OSA" on VDS "VDS-OSA" with VLAN ID 404... Success
[INFO] Creating port group "vsan-OSA" on VDS "VDS-OSA" with VLAN ID 405... Success
[INFO] Created VMkernel for "vMotion" on host "10.191.171.201" (port group "vmotion-OSA", IP 10.40.14.12, MTU 9000).
[INFO] Created VMkernel for "vMotion" on host "10.191.171.171" (port group "vmotion-OSA", IP 10.40.14.13, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.201" (port group "vsan-OSA", IP 10.40.15.12, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.171" (port group "vsan-OSA", IP 10.40.15.13, MTU 9000).
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.201". Skipping witness traffic add.
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.171". Skipping witness traffic add.
[INFO] Successfully created tag catalog "vSAN-OSA-Storage-TagCatalog" on "10.191.174.202".
[INFO] Successfully created tag name "supervisor-OSA" on "vSAN-OSA-Storage-TagCatalog".
[INFO] Reconfiguring cluster-OSA for HA after moving vmk0 to vDS...
[INFO] Successfully configured VM monitoring settings on cluster "cluster-OSA".
[INFO] Ensuring vSAN configuration is applied to all hosts in cluster "cluster-OSA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-OSA".
[INFO] Retrieving vSAN OSA eligible disks for cluster "cluster-OSA" from all hosts...
[INFO] Found 4 eligible disk(s) for cluster "cluster-OSA".

vSAN OSA disks claimed for cluster "cluster-OSA" (cache/capacity per host):

Id VMHostName     CanonicalName                        CapacityGB Model                         IsSsd DefaultRole
-- ----------     -------------                        ---------- -----                         ----- -----------
 1 10.191.171.201 eui.e66a4e2eb30856f8000c29699a742394      80.00 NVMe VMware Virtual NVMe Disk  True Cache
 2 10.191.171.201 eui.d3ee04ac6896d25b000c296fa2e103bd     500.00 NVMe VMware Virtual NVMe Disk  True Capacity
 3 10.191.171.171 eui.cfdfa098b55ca99f000c2967f13d0e89      80.00 NVMe VMware Virtual NVMe Disk  True Cache
 4 10.191.171.171 eui.1034ab032139f5ac000c29641fd53e42     500.00 NVMe VMware Virtual NVMe Disk  True Capacity

[INFO] vSAN OSA disk group assignment completed for 2 host(s) (default cache/capacity).
[INFO] Creating vSAN OSA disk group on host "10.191.171.171" (1 cache, 1 capacity disk(s)).
[INFO] Successfully created vSAN OSA disk group on host "10.191.171.171".
[INFO] Creating vSAN OSA disk group on host "10.191.171.201" (1 cache, 1 capacity disk(s)).
[INFO] Successfully created vSAN OSA disk group on host "10.191.171.201".
[INFO] Successfully configured vSAN OSA disk groups for all hosts in cluster "cluster-OSA".
[INFO] Waiting for vSAN datastore to become available and renaming to "datastore-OSA"... Success
[INFO] Configuring vSAN witness for cluster "cluster-OSA" (witness host: "10.191.174.197").
[INFO] Checking whether witness host "10.191.174.197" already has a vSAN OSA disk group...
[INFO] Witness host "10.191.174.197" already has a vSAN OSA disk group. Skipping disk group creation.
[INFO] Configuring vSAN witness host for cluster "cluster-OSA"...
[INFO] Ensure connectivity between cluster hosts and witness through vSAN Witness VMkernel interface.
[INFO] Enabling stretched cluster mode and configuring witness host "10.191.174.197" for cluster "cluster-OSA"...
[INFO] Successfully configured witness host "10.191.174.197" for cluster "cluster-OSA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-OSA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-OSA" (config pushed from vCenter to hosts).
[INFO] Running vSAN cluster health check for cluster "cluster-OSA" (after witness).
[INFO] Waiting 20 seconds for vSAN health service to reflect HCI workflow skip.
[INFO] Silenced vSAN health checks for lab environment on cluster "cluster-OSA": advcfgsync, controllerdiskmode, controlleronhcl.
[INFO] vSAN advanced config not in sync on all hosts for cluster "cluster-OSA". Pushing current vSAN cluster config from vCenter to hosts.
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-OSA" (config pushed from vCenter to hosts).
[INFO] vSAN cluster config re-applied for cluster "cluster-OSA". Sync may complete asynchronously; proceeding.
[INFO] vSAN cluster health is green for cluster "cluster-OSA". Proceeding.
[INFO] Enabled vSAN performance service on cluster "cluster-OSA".
[INFO] Successfully tagged vSAN OSA datastore "datastore-OSA" with tag "supervisor-OSA" (catalog "vSAN-OSA-Storage-TagCatalog").
[INFO] Storage policy "supervisor-OSA" already contains tag "supervisor-OSA" from catalog "vSAN-OSA-Storage-TagCatalog". Skipping tag add.
[INFO] Cluster "cluster-OSA" is compliant to the vLCM image. No remediation required.
[INFO] Suppress 10 GB networking alarm if present (Broadcom KB 394932) on 2/2 host(s) in cluster "cluster-OSA".
[WARNING] vSAN cluster "cluster-OSA" has alarm (not auto-remediated): "vSAN cluster alarm 'vSAN Cluster Configuration Consistency'" (status: yellow). Resolve manually if needed.
[INFO] vSAN cluster "cluster-OSA" has alarm: "vSAN performance service alarm 'Performance service status'" (status: yellow). Attempting to enable vSAN performance service programmatically.
[INFO] If the alarm persists, it often clears within a few minutes as the performance service starts. Otherwise enable in vCenter (vSAN Services) or check vSAN Health > Performance service.
[INFO] Forming ArgoCD namespace name "argocd-c1347" from prefix "argocd" and cluster MoRef suffix: "-c1347" to ensure uniqueness.
[INFO] Retrieving supervisor ID for "supervisor-OSA" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-OSA"...
[INFO]   Supervisor "supervisor-OSA" not found.
[INFO] [Step 3/3] Supervisor instance "supervisor-OSA" not found. Proceeding to create it.
[INFO] Beginning Supervisor deployment to cluster "cluster-OSA"...
[INFO] [Step 1/5] Parsing supervisor configuration from JSON...
[INFO]   Management network configuration extracted: tkgsmgmtnetwork-2 with 7 IPs
[INFO]     Starting IP: 10.40.13.100, Gateway: 10.40.13.1/24.
[INFO]   Workload network configuration extracted: primaryworkloadnetwork-2 with 100 node IPs and 512 service IPs.
[INFO]     Node IP: 10.40.10.101, Service IP: 10.97.0.0.
[INFO]   FLB network configuration extracted: flbmanagementnetwork-2, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 40
[INFO]   FLB network configuration extracted: virtualservernetwork-2, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 60
[INFO] FLB configuration extracted: flb-site2, Size: MEDIUM, VIPs: 50
[INFO] Supervisor configuration parsed successfully for edgeSite: OSA.
[INFO] Control Plane: 1 x SMALL
[INFO] Management Network: tkgsmgmtnetwork-2
[INFO] Workload Network: primaryworkloadnetwork-2
[INFO] Load Balancer: flb-site2
[INFO] Configuration validation passed.
[INFO] [Step 2/5] Building Supervisor specifications...
[INFO]    Building control plane specification...
[INFO]    Control plane specification built successfully: Size=SMALL, VMs=1
[INFO]    Workload network specification built successfully: primaryworkloadnetwork-2
[INFO] [Step 3/5] Assembling complete supervisor specification...
[INFO] [Step 4/5] Invoking supervisor creation API...
[INFO]    Invoking supervisor creation on cluster "cluster-OSA" (ID: domain-c1347)...
[INFO] [Step 4/5] Supervisor API invocation completed. ID: e8c538eb-620b-4e8b-8957-920eef85024c
[INFO] [Step 5/5] Monitoring supervisor deployment status...
[INFO] Supervisor services on cluster "cluster-OSA" were successfully configured in 1395 seconds.
[INFO] [Step 5/5] Supervisor is ready (elapsed: 1395 seconds)
[INFO] Supervisor deployment completed successfully. Supervisor ID: e8c538eb-620b-4e8b-8957-920eef85024c
[INFO] Checking for available supervisor upgrade versions...
[INFO] No supervisor upgrade available. Current version v1.32.9+vmware.2-fips-vsc9.0.2.0-25129014 is up to date.
[INFO] Using all available VM classes for ArgoCD namespace: guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, best-effort-2xlarge, best-effort-medium, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge
[INFO] Configuring VM classes: guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, best-effort-2xlarge, best-effort-medium, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge
[INFO] The ArgoCD namespace "argocd-c1347" was created successfully.
[INFO] VM classes assigned: guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-xsmall, best-effort-2xlarge, best-effort-medium, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge, guaranteed-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-4xlarge
[INFO] The ArgoCD operator was successfully created.  Waiting for configuration tasks to complete.
[INFO] The ArgoCD operator has been successfully installed on vCenter "10.191.174.202". (Took 185 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.40.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01"...
[ok] Token is still active. Skipped the token refresh for context "vcf-context-01"
[i] Successfully activated context 'vcf-context-01' (Type: kubernetes)
[i] Fetching recommended plugins for active context 'vcf-context-01'...
[ok] All recommended plugins are already installed and up-to-date.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] Applying ArgoCD deployment YAML file "C:\Users\Administrator\AppData\Local\Temp\tmpehzv3s.yml" to namespace "argocd-c1347"...
[INFO] Successfully applied ArgoCD deployment YAML. Output: argocd.argocd-service.vsphere.vmware.com/argocd-instance-1 created
[INFO] kubectl context "vcf-context-01:argocd-c1347" does not exist. This is expected if the namespace was just created. Continuing with namespace flag -n for kubectl operations.
[INFO] Verifying kubectl authentication for namespace "argocd-c1347" (timeout: 60 seconds)...
[INFO] kubectl authentication verified for namespace "argocd-c1347" after 0 seconds
[INFO] ArgoCD pod "argocd-redis-secret-init-4mz4m" is now in status Succeeded.
[INFO] ArgoCD pod "argocd-application-controller-0" is now in status Running.
[INFO] ArgoCD pod "argocd-server-6dfcfc7978-tzlbp" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-6fcd8cf67-f79fj" is now in status Running.
[INFO] ArgoCD pod "argocd-repo-server-f9bffc78-7lkxf" is now in status Running.
[INFO] All 5 ArgoCD pods are ready.
[INFO] ArgoCD namespace "vcf-context-01:argocd-c1347" is now available with all pods ready.
[INFO] To login to ArgoCD:
[INFO] Go to https://10.40.12.204/
[INFO] Login as user "admin" using temporary password: -c7W1CvQK3MIZrfd
[INFO] To update your password run: "argocd.exe account update-password --server 10.40.12.204 --account admin --insecure"
[INFO] Completed deployment for cluster with edgeSite: OSA

[INFO] Starting deployment for edgeSite: "ESA" (site 2 of 2).

[INFO] No cluster named "cluster-ESA" was found on vCenter "10.191.174.202". Proceeding with cluster creation.
[INFO] Using vLCM image from configuration: "ESX902-ESA".

DisplayName BaseImage
----------- ---------
ESX902-ESA  9.0.2.0.25148076

[INFO] Creating the cluster "cluster-ESA" on vCenter "10.191.174.202"...  Success
[INFO] Adding ESX host "10.191.171.173" to cluster "cluster-ESA"... Success
[INFO] Adding ESX host "10.191.171.174" to cluster "cluster-ESA"... Success
[INFO] Creating VDS "VDS-ESA" on vCenter "10.191.174.202"...  Success
[INFO] Creating management port group "mgmt-ESA" on VDS "VDS-ESA" (VLAN 0).
[INFO] Added pNIC "vmnic1" to VDS "VDS-ESA" on host "10.191.171.173".
[INFO] Migrated management (vmk0) to VDS "VDS-ESA" port group "mgmt-ESA" on host "10.191.171.173".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.173".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-ESA" on host "10.191.171.173".
[INFO] Added pNIC "vmnic1" to VDS "VDS-ESA" on host "10.191.171.174".
[INFO] Migrated management (vmk0) to VDS "VDS-ESA" port group "mgmt-ESA" on host "10.191.171.174".
[INFO] Removed standard switch "vSwitch0-restore" from host "10.191.171.174".
[INFO] Added reclaimed pNIC "vmnic0" to VDS "VDS-ESA" on host "10.191.171.174".
[INFO] Creating port group "primaryworkloadnetwork" on VDS "VDS-ESA" with VLAN ID 300... Success
[INFO] Creating port group "flbmanagementnetwork" on VDS "VDS-ESA" with VLAN ID 301... Success
[INFO] Creating port group "virtualservernetwork" on VDS "VDS-ESA" with VLAN ID 302... Success
[INFO] Creating port group "tkgsmgmtnetwork" on VDS "VDS-ESA" with VLAN ID 303... Success
[INFO] VDS "VDS-ESA": configured active/standby teaming (active: dvUplink1, standby: dvUplink2, failback enabled).
[INFO] Creating port group "vmotion-ESA" on VDS "VDS-ESA" with VLAN ID 304... Success
[INFO] Creating port group "vsan-ESA" on VDS "VDS-ESA" with VLAN ID 305... Success
[INFO] Created VMkernel for "vMotion" on host "10.191.171.173" (port group "vmotion-ESA", IP 10.30.14.12, MTU 9000).
[INFO] Created VMkernel for "vMotion" on host "10.191.171.174" (port group "vmotion-ESA", IP 10.30.14.13, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.173" (port group "vsan-ESA", IP 10.30.15.12, MTU 9000).
[INFO] Created VMkernel for "vSAN" on host "10.191.171.174" (port group "vsan-ESA", IP 10.30.15.13, MTU 9000).
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.173". Skipping witness traffic add.
[INFO] vSAN witness traffic already configured on vmk0 on host "10.191.171.174". Skipping witness traffic add.
[INFO] Successfully created tag catalog "vSAN-ESA-Storage-TagCatalog" on "10.191.174.202".
[INFO] Successfully created tag name "supervisor-ESA" on "vSAN-ESA-Storage-TagCatalog".
[INFO] Reconfiguring cluster-ESA for HA after moving vmk0 to vDS...
[INFO] Successfully configured VM monitoring settings on cluster "cluster-ESA".
[INFO] Ensuring vSAN configuration is applied to all hosts in cluster "cluster-ESA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-ESA".
[INFO] Retrieving vSAN ESA eligible disks for cluster "cluster-ESA" from all hosts...
[INFO] Found 4 eligible disk(s) for cluster "cluster-ESA".

vSAN ESA disks claimed for cluster "cluster-ESA":

Id VMHostName     CanonicalName                        CapacityGB Model
-- ----------     -------------                        ---------- -----
 1 10.191.171.173 eui.1a11431c54cffe8b000c296603ea3add     500.00 VMware Virtual NVMe Disk
 2 10.191.171.173 eui.ba33eac3dc25680b000c29634aad5191      80.00 VMware Virtual NVMe Disk
 3 10.191.171.174 eui.fa196b4e38295c1d000c2965528e53f8     500.00 VMware Virtual NVMe Disk
 4 10.191.171.174 eui.7734d14c0f1daf33000c296f08ecf6e9      80.00 VMware Virtual NVMe Disk

[INFO] vSAN ESA storage pool: all 4 eligible disk(s) will be added.
[INFO] Adding 2 disk(s) to vSAN ESA datastore from host "10.191.171.173"... Success
[INFO] Adding 2 disk(s) to vSAN ESA datastore from host "10.191.171.174"... Success
[INFO] Successfully configured vSAN ESA datastore for all hosts in cluster "cluster-ESA".
[INFO] Waiting for vSAN datastore to become available and renaming to "datastore-ESA"... Success
[INFO] Configuring vSAN witness host for cluster "cluster-ESA".
[INFO] Ensure connectivity between cluster hosts and witness through vSAN Witness VMkernel interface.
[INFO] Enabling stretched cluster mode and configuring witness host "10.191.174.196" for cluster "cluster-ESA"...
[INFO] Successfully configured witness host "10.191.174.196" for cluster "cluster-ESA".
[INFO] Enabled vSAN automatic rebalancing at 30% for cluster "cluster-ESA".
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-ESA" (config pushed from vCenter to hosts).
[INFO] Running vSAN cluster health check for cluster "cluster-ESA" (after witness).
[INFO] Enabled vSAN health Alarms on cluster "cluster-ESA".
[INFO] Waiting 20 seconds for vSAN health service to reflect HCI workflow skip.
[INFO] Silenced vSAN health checks for lab environment on cluster "cluster-ESA": advcfgsync, controllerdiskmode, controlleronhcl.
[INFO] vSAN advanced config not in sync on all hosts for cluster "cluster-ESA". Pushing current vSAN cluster config from vCenter to hosts.
[INFO] Re-applied vSAN cluster configuration for cluster "cluster-ESA" (config pushed from vCenter to hosts).
[INFO] vSAN cluster config re-applied for cluster "cluster-ESA". Sync may complete asynchronously; proceeding.
[INFO] vSAN cluster health is green for cluster "cluster-ESA". Proceeding.
[INFO] Successfully tagged vSAN ESA datastore "datastore-ESA" with tag "supervisor-ESA" (catalog "vSAN-ESA-Storage-TagCatalog").
[INFO] Storage policy "supervisor-ESA" already contains tag "supervisor-ESA" from catalog "vSAN-ESA-Storage-TagCatalog". Skipping tag add.
[INFO] Cluster "cluster-ESA" is compliant to the vLCM image. No remediation required.
[INFO] Suppress 10 GB networking alarm if present (Broadcom KB 394932) on 2/2 host(s) in cluster "cluster-ESA".
[INFO] Forming ArgoCD namespace name "argocd-c1392" from prefix "argocd" and cluster MoRef suffix: "-c1392" to ensure uniqueness.
[INFO] Retrieving supervisor ID for "supervisor-ESA" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-ESA"...
[INFO]   Supervisor "supervisor-ESA" not found.
[INFO] [Step 3/3] Supervisor instance "supervisor-ESA" not found. Proceeding to create it.
[INFO] Beginning Supervisor deployment to cluster "cluster-ESA"...
[INFO] [Step 1/5] Parsing supervisor configuration from JSON...
[INFO]   Management network configuration extracted: tkgsmgmtnetwork with 7 IPs
[INFO]     Starting IP: 10.30.13.100, Gateway: 10.30.13.1/24.
[INFO]   Workload network configuration extracted: primaryworkloadnetwork with 100 node IPs and 512 service IPs.
[INFO]     Node IP: 10.30.10.101, Service IP: 10.97.0.0.
[INFO]   FLB network configuration extracted: flbmanagementnetwork, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 40
[INFO]   FLB network configuration extracted: virtualservernetwork, Type: DVPG
[INFO]     IP Assignment: STATIC, Count: 60
[INFO] FLB configuration extracted: flb-site1, Size: MEDIUM, VIPs: 50
[INFO] Supervisor configuration parsed successfully for edgeSite: ESA.
[INFO] Control Plane: 1 x SMALL
[INFO] Management Network: tkgsmgmtnetwork
[INFO] Workload Network: primaryworkloadnetwork
[INFO] Load Balancer: flb-site1
[INFO] Configuration validation passed.
[INFO] [Step 2/5] Building Supervisor specifications...
[INFO]    Building control plane specification...
[INFO]    Control plane specification built successfully: Size=SMALL, VMs=1
[INFO]    Workload network specification built successfully: primaryworkloadnetwork
[INFO] [Step 3/5] Assembling complete supervisor specification...
[INFO] [Step 4/5] Invoking supervisor creation API...
[INFO]    Invoking supervisor creation on cluster "cluster-ESA" (ID: domain-c1392)...
[INFO] [Step 4/5] Supervisor API invocation completed. ID: f79dcfac-10f6-4ae1-9cf2-a2057e405973
[INFO] [Step 5/5] Monitoring supervisor deployment status...
[INFO] Supervisor services on cluster "cluster-ESA" were successfully configured in 1935 seconds.
[INFO] [Step 5/5] Supervisor is ready (elapsed: 1935 seconds)
[INFO] Supervisor deployment completed successfully. Supervisor ID: f79dcfac-10f6-4ae1-9cf2-a2057e405973
[INFO] Checking for available supervisor upgrade versions...
[INFO] No supervisor upgrade available. Current version v1.32.9+vmware.2-fips-vsc9.0.2.0-25129014 is up to date.
[INFO] Using all available VM classes for ArgoCD namespace: best-effort-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-xsmall, guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-medium, best-effort-2xlarge, guaranteed-4xlarge, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge
[INFO] Configuring VM classes: best-effort-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-xsmall, guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-medium, best-effort-2xlarge, guaranteed-4xlarge, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge
[INFO] The ArgoCD namespace "argocd-c1392" was created successfully.
[INFO] VM classes assigned: best-effort-4xlarge, guaranteed-small, guaranteed-large, guaranteed-2xlarge, best-effort-xsmall, guaranteed-xsmall, best-effort-small, guaranteed-medium, guaranteed-xlarge, best-effort-medium, best-effort-2xlarge, guaranteed-4xlarge, best-effort-8xlarge, guaranteed-8xlarge, best-effort-large, best-effort-xlarge
[INFO] The ArgoCD operator was successfully created.  Waiting for configuration tasks to complete.
[INFO] The ArgoCD operator has been successfully installed on vCenter "10.191.174.202". (Took 210 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.30.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01"...
[ok] Token is still active. Skipped the token refresh for context "vcf-context-01"
[i] Successfully activated context 'vcf-context-01' (Type: kubernetes)
[i] Fetching recommended plugins for active context 'vcf-context-01'...
[ok] All recommended plugins are already installed and up-to-date.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] Applying ArgoCD deployment YAML file "C:\Users\Administrator\AppData\Local\Temp\tmpe3z51w.yml" to namespace "argocd-c1392"...
[INFO] Successfully applied ArgoCD deployment YAML. Output: argocd.argocd-service.vsphere.vmware.com/argocd-instance-1 created
[INFO] kubectl context "vcf-context-01:argocd-c1392" does not exist. This is expected if the namespace was just created. Continuing with namespace flag -n for kubectl operations.
[INFO] Verifying kubectl authentication for namespace "argocd-c1392" (timeout: 60 seconds)...
[INFO] kubectl authentication verified for namespace "argocd-c1392" after 0 seconds
[INFO] ArgoCD pod "argocd-redis-secret-init-hgszv" is now in status Succeeded.
[INFO] ArgoCD pod "argocd-application-controller-0" is now in status Running.
[INFO] ArgoCD pod "argocd-server-8486d45c45-5kc9v" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-5746987cfb-mv5x5" is now in status Running.
[INFO] ArgoCD pod "argocd-repo-server-59c8f784b4-j6zq7" is now in status Running.
[INFO] All 5 ArgoCD pods are ready.
[INFO] ArgoCD namespace "vcf-context-01:argocd-c1392" is now available with all pods ready.
[INFO] To login to ArgoCD:
[INFO] Go to https://10.30.12.204/
[INFO] Login as user "admin" using temporary password: BXPoL-CyJkzSIDOs
[INFO] To update your password run: "argocd.exe account update-password --server 10.30.12.204 --account admin --insecure"
[INFO] Completed deployment for cluster with edgeSite: ESA
```

## Example of multi-site cleanup - 2026-03-04

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -cleanup all -force

[INFO] Processing all 3 edge site(s)...
[INFO] Beginning workflow for 3 edge site(s), starting with edgeSite: "ESA".
[INFO] Performing vCenter reachability check (TCP 443) for cleanup...
[INFO] Reachability: vCenter OK.
[ADVISORY] Running in lab mode (common.labenvironment is true in infrastructure JSON).
[INFO] CleanUp is set to "All". Cleaning up per scope, then exiting without deploying.
[ADVISORY] Skipping cleanup confirmation (labEnvironment=true and -Force).
[INFO] Deactivating supervisor on cluster "cluster-ESA" before compute cleanup (All).
[INFO] Deactivating supervisor on cluster "cluster-ESA" (ID: domain-c1392)...
[INFO] Supervisor deactivation initiated. Polling until fully deactivated (timeout: 3600 seconds)...
[INFO] Supervisor on cluster "cluster-ESA" is fully deactivated after 2250 seconds. You can retry deployment.
[INFO] Removing non-management VMkernel interfaces from hosts on VDS "VDS-ESA"... Removed 4 interface(s) from 2 host(s).
[INFO] Restoring management (vmk0) to standard switch on hosts... Moved management to VSS on 2 host(s).
[INFO] Starting vSAN deployment rollback for cluster "cluster-ESA" (vSAN-ESA)...
[INFO] Removing vSAN ESA storage pool disk claims from 2 host(s), then vsan cluster leave.
[INFO] vSAN disk removal completed for 2 host(s).
[INFO] vSAN cluster leave completed for cluster "cluster-ESA".
[INFO] Removing storage tag "supervisor-ESA" (catalog "vSAN-ESA-Storage-TagCatalog") from vCenter... Removed
[INFO] Removing empty tag category "vSAN-ESA-Storage-TagCatalog" from vCenter... Removed
[INFO] vSAN deployment rollback completed for cluster "cluster-ESA".
[INFO] Detaching 2 host(s) from VDS "VDS-ESA" (removing pNICs)... Done.
[INFO] Removing distributed port groups from VDS "VDS-ESA"... Removed 7 port group(s).
[INFO] Removing Virtual Distributed Switch "VDS-ESA"... Removed
[INFO] Removing cluster "cluster-ESA" (no running VMs)... Removed
[ADVISORY] Skipping cleanup confirmation (labEnvironment=true and -Force).
[INFO] Deactivating supervisor on cluster "cluster-OSA" before compute cleanup (All).
[INFO] Deactivating supervisor on cluster "cluster-OSA" (ID: domain-c1347)...
[INFO] Supervisor deactivation initiated. Polling until fully deactivated (timeout: 3600 seconds)...
[INFO] Supervisor on cluster "cluster-OSA" is fully deactivated after 2120 seconds. You can retry deployment.
[INFO] Removing non-management VMkernel interfaces from hosts on VDS "VDS-OSA"... Removed 4 interface(s) from 2 host(s).
[INFO] Restoring management (vmk0) to standard switch on hosts... Moved management to VSS on 2 host(s).
[INFO] Starting vSAN deployment rollback for cluster "cluster-OSA" (vSAN-OSA)...
[INFO] Removing vSAN disk claims from 2 host(s) (OSA disk groups), then vsan cluster leave.
[INFO] vSAN disk removal completed for 2 host(s).
[INFO] vSAN cluster leave completed for cluster "cluster-OSA".
[INFO] Removing storage tag "supervisor-OSA" (catalog "vSAN-OSA-Storage-TagCatalog") from vCenter... Removed
[INFO] Removing empty tag category "vSAN-OSA-Storage-TagCatalog" from vCenter... Removed
[INFO] vSAN deployment rollback completed for cluster "cluster-OSA".
[INFO] Detaching 2 host(s) from VDS "VDS-OSA" (removing pNICs)... Done.
[INFO] Removing distributed port groups from VDS "VDS-OSA"... Removed 7 port group(s).
[INFO] Removing Virtual Distributed Switch "VDS-OSA"... Removed
[INFO] Removing cluster "cluster-OSA" (no running VMs)... Removed
[ADVISORY] Skipping cleanup confirmation (labEnvironment=true and -Force).
[WARNING] Cluster "cluster-VMFS" not found; nothing to remove.
[INFO] CleanUp (All) completed. Exiting without deployment.
```

## Example of Harbor Cleanup - 2026-04-01

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -EdgeSite VMFS -cleanup harbor -force

[INFO] Processing 1 edge site(s): VMFS...
[INFO] Beginning workflow for edgeSite: "VMFS".
[INFO] Performing vCenter reachability check (TCP 443) for cleanup...
[INFO] Reachability: vCenter OK.
[ADVISORY] Running in lab mode (common.labenvironment is true in infrastructure JSON).
[INFO] CleanUp is set to "Harbor". Cleaning up per scope, then exiting without deploying.
[ADVISORY] Skipping cleanup confirmation (labEnvironment=true and -Force).
[INFO] Retrieving supervisor ID for "supervisor-vmfs" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-vmfs"...
[INFO]   Found supervisor "supervisor-vmfs" with ID: 77a8cf66-1354-4220-ac48-c0d7ebdebc3d.
[INFO] [Step 3/3] Waiting for supervisor to become ready...
[INFO]   Waiting for supervisor "supervisor-vmfs" to become ready (timeout: 3600 seconds)...
[INFO]   Supervisor "supervisor-vmfs" reached READY status after 0 seconds
[INFO] Harbor service "harbor.tanzu.vmware.com" removed from supervisor "77a8cf66-1354-4220-ac48-c0d7ebdebc3d" for cluster "cluster-VMFS". Supervisor intact.
[INFO] Harbor service namespace(s) still terminating on supervisor "77a8cf66-1354-4220-ac48-c0d7ebdebc3d" for cluster "cluster-VMFS": svc-harbor-zdnps. Waiting for cleanup before completing rollback...
[INFO] Harbor service namespace(s) terminated on supervisor "77a8cf66-1354-4220-ac48-c0d7ebdebc3d" for cluster "cluster-VMFS". Ready for re-deployment.
[INFO] CleanUp (Harbor) completed. Exiting without deployment.
```

## Example of Harbor Deployment (only cert and hostname specified in YAML) - 2026-04-01

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -EdgeSite VMFS

[INFO] Checking for required JSON properties for edgeSite(s) "VMFS"...
[INFO] Validating property formats and values for edgeSite(s) "VMFS"...
[INFO] Processing 1 edge site(s): VMFS...
[INFO] Beginning workflow for edgeSite: "VMFS".
[INFO] Performing vCenter and ESX reachability check (TCP 443)...
[INFO] Reachability: all targets OK (vCenter and 1 ESX host(s)).
[INFO] Datastore "datastore-VMFS" is already mounted on ESX host "automation-esx01.vcfedge.demo" and has 493.23 GB free space.
[INFO] Retrieved canonical name for existing datastore "datastore-VMFS": mpx.vmhba0:C0:T2:L0.
[INFO] The cluster "cluster-VMFS" in datacenter "UnitTest" is already present. Skipping cluster creation.
[INFO] Host "automation-esx01.vcfedge.demo" is already in cluster "cluster-VMFS". Skipping host add.
[INFO] VDS "VDS-VMFS" is already present. Skipping VDS creation.
[INFO] The ESX host "automation-esx01.vcfedge.demo" is already attached to VDS "VDS-VMFS". Skipping attachment.
[INFO] Host "automation-esx01.vcfedge.demo" management (vmk0) is already on VDS "VDS-VMFS". Skipping migration.
[INFO] Port group "primaryworkloadnetwork-3" already exists on VDS "VDS-VMFS" with VLAN ID 500. Skipping creation.
[INFO] Port group "flbmanagementnetwork-3" already exists on VDS "VDS-VMFS" with VLAN ID 501. Skipping creation.
[INFO] Port group "virtualservernetwork-3" already exists on VDS "VDS-VMFS" with VLAN ID 502. Skipping creation.
[INFO] Port group "tkgsmgmtnetwork-3" already exists on VDS "VDS-VMFS" with VLAN ID 503. Skipping creation.
[INFO] Tag catalog "VMFS-Storage-TagCatalog" already exists on vCenter "10.191.174.202". Skipping tag catalog creation.
[INFO] Tag name "supervisor-vmfs" already exists on "VMFS-Storage-TagCatalog". Skipping tag creation.
[INFO] The datastore "datastore-VMFS" was already created on ESX host "automation-esx01.vcfedge.demo". Proceeding to tag assignment.
[INFO] Datastore "datastore-VMFS" already has tag "supervisor-vmfs" assigned. Skipping tag assignment.
[INFO] Storage policy "supervisor-vmfs" already contains tag "supervisor-vmfs" from catalog "VMFS-Storage-TagCatalog". Skipping tag add.
[INFO] Forming ArgoCD namespace name "argocd-c772" from prefix "argocd" and cluster MoRef suffix: "-c772" to ensure uniqueness.
[INFO] Retrieving supervisor ID for "supervisor-vmfs" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-vmfs"...
[INFO]   Found supervisor "supervisor-vmfs" with ID: 77a8cf66-1354-4220-ac48-c0d7ebdebc3d.
[INFO] [Step 3/3] Waiting for supervisor to become ready...
[INFO]   Waiting for supervisor "supervisor-vmfs" to become ready (timeout: 3600 seconds)...
[INFO]   Supervisor "supervisor-vmfs" reached READY status after 0 seconds
[INFO] Supervisor instance "supervisor-vmfs" reported status ready, after waiting for 0 seconds.
[INFO] Retrieving supervisor ID for "supervisor-vmfs" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-vmfs"...
[INFO]   Found supervisor "supervisor-vmfs" with ID: 77a8cf66-1354-4220-ac48-c0d7ebdebc3d.
[INFO] [Step 3/3] Waiting for supervisor to become ready...
[INFO]   Waiting for supervisor "supervisor-vmfs" to become ready (timeout: 3600 seconds)...
[INFO]   Supervisor "supervisor-vmfs" reached READY status after 0 seconds
[INFO] Using all available VM classes for ArgoCD namespace.
[INFO] The ArgoCD namespace "argocd-c772" already exists on vCenter "10.191.174.202" Skipping namespace creation.
[INFO] ArgoCD service already exists. Verifying configuration status...
[INFO] The ArgoCD operator has been successfully installed on vCenter "10.191.174.202". (Took 0 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.50.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01:argocd-c772"...
[INFO] Namespace-scoped context switch failed. Trying base context "vcf-context-01"...
[INFO] VCF context "vcf-context-01" activated successfully.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] Applying ArgoCD deployment YAML file "C:\Users\Administrator\AppData\Local\Temp\tmpgidnam.yml" to namespace "argocd-c772"...
[INFO] Successfully applied ArgoCD deployment YAML. Output: argocd.argocd-service.vsphere.vmware.com/argocd-instance-1 unchanged
[INFO] Verifying kubectl authentication for namespace "argocd-c772" (timeout: 60 seconds)...
[INFO] kubectl authentication verified for namespace "argocd-c772" after 0 seconds
[INFO] ArgoCD pod "argocd-application-controller-0" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-6b4c84cdc7-khj7v" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-secret-init-lzvnk" is now in status Succeeded.
[INFO] ArgoCD pod "argocd-repo-server-84658955b7-2qnbb" is now in status Running.
[INFO] ArgoCD pod "argocd-server-55889fdf59-7w5tb" is now in status Running.
[INFO] All 5 ArgoCD pods are ready.
[INFO] ArgoCD namespace "vcf-context-01:argocd-c772" is now available with all pods ready.
[INFO] To login to ArgoCD:
[INFO] Go to https://10.50.12.203/
[INFO] Login as user "admin" using temporary password: qkSDjHfN1A6YtxTk
[INFO] To update your password run: "argocd.exe account update-password --server 10.50.12.203 --account admin --insecure"
[INFO] Created temporary Harbor data values file for edge site "VMFS" (hostname: "harbor-site1.example.com", storageClass: "supervisor-vmfs")
[INFO] Harbor service "harbor.tanzu.vmware.com" version "2.14.2+vmware.2-vks.1" is already registered globally on this vCenter. Skipping re-registration.
[INFO] Harbor service install request submitted. Waiting for configuration to complete.
[INFO] Harbor service "harbor.tanzu.vmware.com" version "2.14.2+vmware.2-vks.1" is CONFIGURED on supervisor "77a8cf66-1354-4220-ac48-c0d7ebdebc3d".
[INFO] Harbor Supervisor Service installed successfully for edge site "VMFS" (hostname: "harbor-site1.example.com").
[INFO] Completed deployment for cluster with edgeSite: VMFS
```

## Example of Harbor Deployment (save yaml) - 2026-04-01

```powershell
PS C:\Users\Administrator> start-ModernEdgeAtScale -EdgeSite VMFS -SaveHarborYaml

[INFO] Checking for required JSON properties for edgeSite(s) "VMFS"...
[INFO] Validating property formats and values for edgeSite(s) "VMFS"...
[INFO] Processing 1 edge site(s): VMFS...
[INFO] Beginning workflow for edgeSite: "VMFS".
[INFO] Performing vCenter and ESX reachability check (TCP 443)...
[INFO] Reachability: all targets OK (vCenter and 1 ESX host(s)).
[INFO] Datastore "datastore-VMFS" is already mounted on ESX host "automation-esx01.vcfedge.demo" and has 493.23 GB free space.
[INFO] Retrieved canonical name for existing datastore "datastore-VMFS": mpx.vmhba0:C0:T2:L0.
[INFO] The cluster "cluster-VMFS" in datacenter "UnitTest" is already present. Skipping cluster creation.
[INFO] Host "automation-esx01.vcfedge.demo" is already in cluster "cluster-VMFS". Skipping host add.
[INFO] VDS "VDS-VMFS" is already present. Skipping VDS creation.
[INFO] The ESX host "automation-esx01.vcfedge.demo" is already attached to VDS "VDS-VMFS". Skipping attachment.
[INFO] Host "automation-esx01.vcfedge.demo" management (vmk0) is already on VDS "VDS-VMFS". Skipping migration.
[INFO] Port group "primaryworkloadnetwork-3" already exists on VDS "VDS-VMFS" with VLAN ID 500. Skipping creation.
[INFO] Port group "flbmanagementnetwork-3" already exists on VDS "VDS-VMFS" with VLAN ID 501. Skipping creation.
[INFO] Port group "virtualservernetwork-3" already exists on VDS "VDS-VMFS" with VLAN ID 502. Skipping creation.
[INFO] Port group "tkgsmgmtnetwork-3" already exists on VDS "VDS-VMFS" with VLAN ID 503. Skipping creation.
[INFO] Tag catalog "VMFS-Storage-TagCatalog" already exists on vCenter "10.191.174.202". Skipping tag catalog creation.
[INFO] Tag name "supervisor-vmfs" already exists on "VMFS-Storage-TagCatalog". Skipping tag creation.
[INFO] The datastore "datastore-VMFS" was already created on ESX host "automation-esx01.vcfedge.demo". Proceeding to tag assignment.
[INFO] Datastore "datastore-VMFS" already has tag "supervisor-vmfs" assigned. Skipping tag assignment.
[INFO] Storage policy "supervisor-vmfs" already contains tag "supervisor-vmfs" from catalog "VMFS-Storage-TagCatalog". Skipping tag add.
[INFO] Running vLCM cluster compliance check for cluster "cluster-VMFS".
[INFO] Cluster "cluster-VMFS" is compliant to the vLCM image. No remediation required.
[INFO] Forming ArgoCD namespace name "argocd-c772" from prefix "argocd" and cluster MoRef suffix: "-c772" to ensure uniqueness.
[INFO] Retrieving supervisor ID for "supervisor-vmfs" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-vmfs"...
[INFO]   Found supervisor "supervisor-vmfs" with ID: 77a8cf66-1354-4220-ac48-c0d7ebdebc3d.
[INFO] [Step 3/3] Waiting for supervisor to become ready...
[INFO]   Waiting for supervisor "supervisor-vmfs" to become ready (timeout: 3600 seconds)...
[INFO]   Supervisor "supervisor-vmfs" reached READY status after 0 seconds
[INFO] Supervisor instance "supervisor-vmfs" reported status ready, after waiting for 0 seconds.
[INFO] Retrieving supervisor ID for "supervisor-vmfs" on vCenter "10.191.174.202"...
[INFO] [Step 1/3] Creating REST API session...
[INFO]   Creating REST API session with vCenter...
[INFO]   REST API session created successfully.
[INFO] [Step 2/3] Searching for supervisor cluster...
[INFO]   Searching for supervisor "supervisor-vmfs"...
[INFO]   Found supervisor "supervisor-vmfs" with ID: 77a8cf66-1354-4220-ac48-c0d7ebdebc3d.
[INFO] [Step 3/3] Waiting for supervisor to become ready...
[INFO]   Waiting for supervisor "supervisor-vmfs" to become ready (timeout: 3600 seconds)...
[INFO]   Supervisor "supervisor-vmfs" reached READY status after 0 seconds
[INFO] Using all available VM classes for ArgoCD namespace.
[INFO] The ArgoCD namespace "argocd-c772" already exists on vCenter "10.191.174.202" Skipping namespace creation.
[INFO] ArgoCD service already exists. Verifying configuration status...
[INFO] The ArgoCD operator has been successfully installed on vCenter "10.191.174.202". (Took 0 seconds).
[INFO] Creating VCF context "vcf-context-01" with endpoint "10.50.13.101"...
[INFO] VCF context "vcf-context-01" created successfully.
[INFO] Switching to VCF context "vcf-context-01:argocd-c772"...
[INFO] Namespace-scoped context switch failed. Trying base context "vcf-context-01"...
[INFO] VCF context "vcf-context-01" activated successfully.
[INFO] Waiting for ArgoCD operator webhook service to be ready (timeout: 1200 seconds)...
[INFO] ArgoCD operator webhook service is ready with 1 endpoint(s).
[INFO] Applying ArgoCD deployment YAML file "C:\Users\Administrator\AppData\Local\Temp\tmpslmup2.yml" to namespace "argocd-c772"...
[INFO] Successfully applied ArgoCD deployment YAML. Output: argocd.argocd-service.vsphere.vmware.com/argocd-instance-1 unchanged
[INFO] Verifying kubectl authentication for namespace "argocd-c772" (timeout: 60 seconds)...
[INFO] kubectl authentication verified for namespace "argocd-c772" after 0 seconds
[INFO] ArgoCD pod "argocd-application-controller-0" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-6b4c84cdc7-khj7v" is now in status Running.
[INFO] ArgoCD pod "argocd-redis-secret-init-lzvnk" is now in status Succeeded.
[INFO] ArgoCD pod "argocd-repo-server-84658955b7-2qnbb" is now in status Running.
[INFO] ArgoCD pod "argocd-server-55889fdf59-7w5tb" is now in status Running.
[INFO] All 5 ArgoCD pods are ready.
[INFO] ArgoCD namespace "vcf-context-01:argocd-c772" is now available with all pods ready.
[INFO] To login to ArgoCD:
[INFO] Go to https://10.50.12.203/
[INFO] Login as user "admin" using temporary password: qkSDjHfN1A6YtxTk
[INFO] To update your password run: "argocd.exe account update-password --server 10.50.12.203 --account admin --insecure"
[INFO] Created temporary Harbor data values file for edge site "VMFS" (hostname: "harbor-site1.example.com", storageClass: "supervisor-vmfs")
[INFO] Harbor service "harbor.tanzu.vmware.com" version "2.14.2+vmware.2-vks.1" is already registered globally on this vCenter. Skipping re-registration.
[INFO] Harbor service install request submitted. Waiting for configuration to complete.
[INFO] Harbor service "harbor.tanzu.vmware.com" version "2.14.2+vmware.2-vks.1" is CONFIGURED on supervisor "77a8cf66-1354-4220-ac48-c0d7ebdebc3d".
[INFO] Harbor Supervisor Service installed successfully for edge site "VMFS" (hostname: "harbor-site1.example.com").
[INFO] Harbor data values file saved (contains unredacted secrets): "C:\Users\Administrator\HarborYaml\harbor-data-values-VMFS-20260401_060201.yml". A redacted copy is in the deployment log.
[INFO] Completed deployment for cluster with edgeSite: VMFS
```
