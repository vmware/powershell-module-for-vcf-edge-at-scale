# 1.0.0.3

* Transitioned script to a module.
* Added support for vLCM images for clusters (using vCenter image catalog) (interactive or JSON)
* Added support for deploying multiple clusters in a single vCenter
* Added support for defining multiple clusters in a single set of infrastructure/supervisor JSON files
* Breaking change: update JSON structures to support multi-node and multi-edge deployments
* Automatic Supervisor content catalog creation 
* Automatic Supervisor upgrade to latest version upon deployment
* Show ArgoCD login information (URL and admin credentials) per edge location
* Clusters are configured for Retreat mode automatically (KB316514), removing the vCLS
* vSAN ESA and OSA are now supported in a stretched cluster configuration
* Automatic diskclaim 
* Witness validation and disk group / disk claim setup (as needed)
* Check if correct witness OVA is used for ESA vs OSA environment
* vmk NIC validation and setup for data nodes and witness
* Enable vSAN health checks (if labEnvironment=true, certain checks are suppressed)
* Ensure configuration is in sync from vCenter to hosts before supervisor deployment
* Ensure vSAN is not partitioned before supervisor deployment
* Configure vSAN for auto-rebalance at 30%
* Check to make sure ESA and OSA data nodes contribute approximately equal disks (WARN if they do not)
* User prompted for rollback if compute or supervisor rollback fails (supervisor failure will rollback only supervisor)
* Support for optional non-interactive authentication using environmental variables
* ComputeOnly deployment option (optional)
* Auto-diskclaim for VMFS too (largest available disk)
* vLCM image compliance check before supervisor workflow
* Updated to ArgoCD 1.1.0

# 1.0.0.2 

* Fixes Windows compatibility issues with YAML parsing and handling kubectl/vcf commands on Windows.
* Improved error messages.

# 1.0.0.1 

* Initial Release.


