# Single-Node vSphere Supervisor Deployment Automation

[![PowerShell](https://img.shields.io/badge/PowerShell-7.2%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/License-Broadcom-green.svg)](LICENSE.md)
[![Version](https://img.shields.io/badge/Version-1.0.0.2-orange.svg)](CHANGELOG.md)
[![GitHub Clones](https://img.shields.io/badge/dynamic/json?color=success&label=Clone&query=count&url=https://gist.githubusercontent.com/nathanthaler/7c5ed25bb9cea6eef7f015be50e44a6f/raw/clone.json&logo=github)](https://gist.githubusercontent.com/nathanthaler/7c5ed25bb9cea6eef7f015be50e44a6f/raw/clone.json)
![Downloads](https://img.shields.io/github/downloads/vmware/powershell-module-for-simple-supervisor-deployment-at-scale/total?label=Release%20Downloads)
[![Changelog](https://img.shields.io/badge/Changelog-Read-blue)](CHANGELOG.md)

## Overview

This PowerShell automation script is designed to streamline the deployment of a single-node vSphere Supervisor in VMware Cloud Foundation (VCF) 9.x environments. It automates critical steps from initial setup to the creation of the supervisor, including network configuration and content library verification. The script leverages VCF.PowerCLI cmdlets and relies on pre-configured JSON input files (`infrastructure.json` and `supervisor.json`) to tailor the deployment to your environment. Additionally, it addresses the prerequisites for integrating Argo CD operator services and ensures the necessary CLI tools are available for a comprehensive, end-to-end automated solution.

## Pre-requisites

- **VCF 9.x Environment**: A VCF 9.x environment running with a vCenter instance must be available
- **Supervisor Version**: 9.0.0.0100-24845085 or later
- **Host Preparation**: The host is already prepped with ESX and has appropriate network setup
- **Network Connectivity**: ESX and vCenter network connectivity is established
- **Provisioning Access**: Connectivity must be available from the Provisioning host to Supervisor Management Network
- **Datacenter Setup**: Datacenter defined in `infrastructure.json` must already be created and ESX image already populated in the vLCM depot
- **PowerShell**: Version 7.0 or later installed on your system. If not, download and install it from the official Microsoft website
- **kubectl**: Installed on your system. kubectl can be downloaded from upstream at: https://kubernetes.io/docs/tasks/tools/

## Functions Performed by this Automation

This automation script will cover the following key functions:

1. **Cluster Creation and Host Addition**: It will create a new cluster in vCenter and add the specified host to this cluster

2. **Cluster Configuration**:
   - Distributed Resource Scheduler (DRS) will be set to Automatic
   - High Availability (HA) admission control will be disabled

3. **Creation of VDS and related port groups**: A vSphere Distributed Switch (VDS) will be created, along with necessary port groups for edge application and services

4. **Datastore Configuration**:
   - VMFS datastore will be configured based on available disk
   - Local storage only, no external storage

5. **Storage Policy for Edge Datastore**: A storage policy will be created specifically for the Edge Datastore

6. **vSphere Supervisor Enablement**: The vSphere Supervisor feature will be enabled on the newly configured cluster

7. **Supervisor Services**: VM Operator service, VKS Kubernetes Service, Velero backup and restore service, Argo CD Operator Service

8. **Argo CD Instance Creation**: An instance of Argo CD will be created and configured for use

## Execution Steps

### 1. Install VCF.PowerCLI Module

Install the required PowerCLI module for VCF.

### 2. Download Script Files

Download the provided zip file. The downloaded file has the following structure:

- `OneNodeDeployment.ps1` is the main launcher file
- `1.0.1-24896502.yml` is the ArgoCD Operator YAML file supplied by Broadcom
- Neither file requires any modifications for a standard one node deployment
- `infrastructure.json`, `supervisor.json` and `argocd-deployment.yml` are parameter templates that require updating to align with your edge environment
  - `infrastructure.json` contains vSphere configuration details
  - `supervisor.json` contains Supervisor networking, availability and sizing parameters
  - `argocd-deployment.yml` is the ArgoCD instance YAML that defines ArgoCD resource deployment

### 3. Configure argocd-deployment.yml

Open `argocd-deployment.yml` and populate the fields with the details required to run ArgoCD instances to manage your edge application. Follow ArgoCD Instance configuration details in the provided documentation as reference.

### 4. Configure infrastructure.json

Open `infrastructure.json` and review all the fields, updating as required for your environment using the table in `Admin.Guide.Single.Node.Supervisor.rtf` reference. **Accuracy here is crucial for successful deployment.**

### 5. Configure supervisor.json

Open `supervisor.json` and review all the fields, updating as required for your environment using the table in `Admin.Guide.Single.Node.Supervisor.rtf` as reference.

### 6. Argo CD Operator YAML Download (Optional)

Download the necessary YAML file for Argo CD operator creation by following the instructions in the provided documentation.

### 7. Install vcf-cli Plugin

- Follow the installation guide at the official VMware documentation site
- **Important:** After installation, rename file `vcf.exe` on Windows or `vcf` on MacOS or Linux

### 8. Run the Automation Script

Execute the automation script to configure the edge cluster:

```powershell
PS > OneNodeDeployment.ps1 -infrastructureJson /path/to/infrastructure.json -supervisorJson /path/to/supervisor.json
```

## Important Notes

- **Network Configuration**: The automation currently creates a supervisor with four networks: one for management, one for workload, and two for load balancer. The `infrastructure.json` file expects four VLAN IDs for the virtual distributed switch section accordingly. While there are options to reduce network usage by reusing resource pools, this script adheres to the four-network design as per the linked design documents.

- **CLI Plugin Availability**: For a fully automated end-to-end process, it is required that VCF-CLI and KUBECTL are available on your testbed *before* running this script. Refer to step 7 for VCF CLI installation. Kubectl can be downloaded from upstream at: https://kubernetes.io/docs/tasks/tools/

- **Supported Environment**: This script has been tested and validated on the Mac and Windows platforms. Ensure your execution environment matches this specification for optimal performance and compatibility.

