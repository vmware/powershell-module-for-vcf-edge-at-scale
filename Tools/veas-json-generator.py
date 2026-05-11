#!/usr/bin/env python3
#
# SOFTWARE LICENSE AGREEMENT
#
# Copyright (c) CA, Inc. All rights reserved.
#
# You are hereby granted a non-exclusive, worldwide, royalty-free license
# under CA, Inc.'s copyrights to use, copy, modify, and distribute this
# software in source code or binary form for use in connection with CA, Inc.
# products.
#
# This copyright notice shall be included in all copies or substantial
# portions of the software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
# VcfEdgeAtScale JSON Configuration UI
# A self-contained Python web server (stdlib only) that guides users through
# building valid infrastructure.json and supervisor.json files.
#
# Usage:
#   python3 veas-json-generator.py [--port PORT] [--base-dir DIR]
#   Default port: 8080
#   Default base-dir: ~/VCFEdgeAtScale (the directory created by Start-VcfEdgeAtScale -Initialize)
#                     Falls back to VcfEdgeAtScale/Templates/ if ~/VCFEdgeAtScale does not exist.
import argparse
import concurrent.futures
import datetime
import io
import ipaddress
import json
import re
import ssl
import socket
import sys
import time
import traceback
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

SCRIPT_DIR = Path(__file__).parent.resolve()
# When installed via -Initialize, this script lives at <BaseDir>/Tools/veas-json-generator.py,
# so SCRIPT_DIR.parent is the deployment base directory. Falls back to <BaseDir>/Templates/
# (which mirrors the module layout when running directly from the module source tree).
_DEFAULT_BASE_DIR = SCRIPT_DIR.parent
_FALLBACK_TEMPLATES_DIR = SCRIPT_DIR.parent / "Templates"

UI_VERSION = "1.0.3.1002"
README_URL = "https://github.com/vmware/powershell-module-for-vcf-edge-at-scale"
_MAX_CONNECTIVITY_WORKERS = 20
# Maximum request body accepted from the browser (5 MB is far more than any
# realistic VCF configuration payload).
_MAX_BODY_BYTES = 5 * 1024 * 1024
# Seconds per host; intentionally short for UI responsiveness.
_CONNECTIVITY_TIMEOUT = 5
# Minimum recommended virtual-server-network IP count per site. Below this a warning is
# issued but validation still passes; the exact requirement depends on which services are
# deployed, but 20 covers common configurations with some headroom.
_FLOATING_IP_WARNING_THRESHOLD = 20
# Edge-at-scale topology: each vSAN cluster requires exactly 2 data hosts (1 per node)
# plus a witness appliance. This is a hard architectural constraint of the deployment model.
_VSAN_HOST_COUNT = 2

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

IPV4_RE = re.compile(
    r"^((25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(25[0-5]|2[0-4]\d|[01]?\d\d?)$"
)
CIDR_RE = re.compile(
    r"^((25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(25[0-5]|2[0-4]\d|[01]?\d\d?)/([0-9]|[1-2]\d|3[0-2])$"
)
# RFC1123: 1–80 chars, lowercase, no leading/trailing hyphen.
RFC1123_RE = re.compile(r"^(?=.{1,80}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
# vSphere object names: 1–80 chars, alphanumeric + space _ + - ()
VSPHERE_NAME_RE = re.compile(r"^[a-zA-Z0-9 _+\-()\\.]{1,80}$")
# vCenter user: alphanumeric + . _ @ -
VCENTER_USER_RE = re.compile(r"^[a-zA-Z0-9._@\-]{1,256}$")
# FQDN or IPv4
FQDN_OR_IPV4_RE = re.compile(
    r"^(?:"
    r"(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
    r"|[a-zA-Z0-9](?:[a-zA-Z0-9\-_.]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9\-_.]*[a-zA-Z0-9])?)*"
    r")$"
)
# Harbor volume size: positive integer followed by Gi
VOLUME_SIZE_RE = re.compile(r"^[1-9]\d*Gi$")


def is_valid_ipv4(value):
    return bool(IPV4_RE.match(str(value).strip()))


def is_valid_cidr(value):
    return bool(CIDR_RE.match(str(value).strip()))


def is_valid_rfc1123(value):
    """Validates that a name matches RFC1123 (lowercase, 1–80 chars, no leading/trailing hyphen)."""
    return bool(RFC1123_RE.match(str(value).strip()))


def is_valid_fqdn_or_ip(value):
    return bool(FQDN_OR_IPV4_RE.match(str(value).strip()))


def is_valid_netmask(value):
    """Validates that value is a proper subnet mask (all-1s followed by all-0s in binary)."""
    try:
        parts = str(value).strip().split(".")
        if len(parts) != 4:
            return False
        bits = 0
        for part in parts:
            bits = (bits << 8) | int(part)
        # A valid netmask has the form: some number of leading 1s then all 0s.
        inverted = bits ^ 0xFFFFFFFF
        return inverted == 0 or (inverted & (inverted + 1)) == 0
    except (ValueError, TypeError):
        return False


def is_ip_in_cidr(ip_str, cidr_str):
    """Returns True if ip_str falls within the network defined by cidr_str (e.g. 10.0.0.1/24)."""
    try:
        network = ipaddress.IPv4Network(cidr_str, strict=False)
        return ipaddress.IPv4Address(ip_str) in network
    except (ValueError, TypeError):
        return False


def is_power_of_two(n):
    try:
        n = int(n)
        return n > 0 and (n & (n - 1)) == 0
    except (TypeError, ValueError):
        return False


def validate_vlan_id(value, field_path):
    """Returns an error string if the VLAN ID is invalid, else None."""
    try:
        vid = int(value)
        if vid < 0 or vid > 4095:
            return f"{field_path}: VLAN ID must be 0–4095, got {value}."
    except (TypeError, ValueError):
        return f"{field_path}: VLAN ID must be an integer, got '{value}'."
    return None


def _validate_common(common, errors):
    """Validates the infrastructure.common block, appending errors in place."""
    vc_name = common.get("vCenterName", "")
    if not vc_name:
        errors.append("infrastructure.common.vCenterName: required field is missing or empty.")
    elif not is_valid_fqdn_or_ip(vc_name):
        errors.append(
            f"infrastructure.common.vCenterName: '{vc_name}' must be a valid FQDN or IPv4 address."
        )

    vc_user = common.get("vCenterUser", "")
    if not vc_user:
        errors.append("infrastructure.common.vCenterUser: required field is missing or empty.")
    elif not VCENTER_USER_RE.match(vc_user):
        errors.append(
            "infrastructure.common.vCenterUser: must match pattern user@domain or user (max 256 chars)."
        )

    dc_name = common.get("datacenterName", "")
    if not dc_name:
        errors.append("infrastructure.common.datacenterName: required field is missing or empty.")
    elif not VSPHERE_NAME_RE.match(dc_name):
        errors.append(
            "infrastructure.common.datacenterName: must be 1–80 chars, alphanumeric with spaces, _, +, -, ()."
        )

    for prefix_field in ("clusterNamePrefix", "datastoreNamePrefix", "supervisorNamePrefix", "vdsNamePrefix"):
        val = common.get(prefix_field, "")
        if val and not VSPHERE_NAME_RE.match(val):
            errors.append(
                f"infrastructure.common.{prefix_field}: must be 1–80 chars, "
                "alphanumeric with spaces, _, +, -, ()."
            )

    common_nic_list = common.get("nicList")
    if common_nic_list is not None:
        if not isinstance(common_nic_list, list) or len(common_nic_list) not in (2, 4):
            errors.append(
                "infrastructure.common.nicList: must be an array of exactly 2 or 4 NIC objects."
            )

    for bool_field in ("esxUniquePasswordPerHost", "nonInteractivePassword", "autoUpdate", "labenvironment", "preserveAutoGeneratedKeyCertPair"):
        val = common.get(bool_field)
        if val is not None and not isinstance(val, bool):
            errors.append(
                f"infrastructure.common.{bool_field}: must be a JSON boolean (true/false), not a string."
            )

    ha_policy = common.get("haPolicy")
    if ha_policy is not None and ha_policy not in ("reservationBased", "slotBased", "disabled"):
        errors.append(
            "infrastructure.common.haPolicy: must be 'reservationBased', 'slotBased', or 'disabled'."
        )

    for mtu_key in ("vSanvMotionVmKernelMtuValue", "vmkernelMtu"):
        mtu = common.get(mtu_key)
        if mtu is not None:
            try:
                mtu_int = int(mtu)
                if mtu_int < 1500 or mtu_int > 9190:
                    errors.append(f"infrastructure.common.{mtu_key}: must be between 1500 and 9190.")
            except (TypeError, ValueError):
                errors.append(f"infrastructure.common.{mtu_key}: must be an integer.")


def _validate_harbor(harbor, prefix, errors):
    """Validates a harborConfiguration block, appending errors in place."""
    hostname = harbor.get("hostname", "")
    if hostname and not is_valid_fqdn_or_ip(hostname):
        errors.append(
            f"{prefix}.harborConfiguration.hostname: '{hostname}' must be a valid FQDN or IPv4 address."
        )

    secret_key = harbor.get("secretKey", "")
    if secret_key and not secret_key.startswith("$env:") and len(secret_key) != 16:
        errors.append(f"{prefix}.harborConfiguration.secretKey: must be exactly 16 characters (AES-128).")

    tls_crt = harbor.get("tlsCrt")
    tls_key = harbor.get("tlsKey")
    if bool(tls_crt) != bool(tls_key):
        errors.append(f"{prefix}.harborConfiguration: 'tlsCrt' and 'tlsKey' must both be defined together.")
    if harbor.get("caCrt") and not (tls_crt and tls_key):
        errors.append(
            f"{prefix}.harborConfiguration.caCrt: only valid when 'tlsCrt' and 'tlsKey' are also defined."
        )

    for vol_field in ("registryVolumeSize", "jobserviceVolumeSize", "databaseVolumeSize",
                      "redisVolumeSize", "trivyVolumeSize"):
        vol = harbor.get(vol_field)
        if vol and not VOLUME_SIZE_RE.match(str(vol)):
            errors.append(
                f"{prefix}.harborConfiguration.{vol_field}: "
                "must be a positive integer followed by 'Gi' (e.g. 10Gi)."
            )


def _validate_vmk_interfaces(vmk_interfaces, storage_type, prefix, errors):
    """Validates networkingVmKernelInterfaces for a vSAN cluster, appending errors in place."""
    if not isinstance(vmk_interfaces, list) or len(vmk_interfaces) == 0:
        errors.append(f"{prefix}.networking.networkingVmKernelInterfaces: required for {storage_type}.")
        return

    found_services = set()
    for vmk_idx, vmk in enumerate(vmk_interfaces):
        service = vmk.get("service", "")
        vmk_label = f'"{service}"' if service else str(vmk_idx)
        vmk_prefix = f"{prefix}.networking.networkingVmKernelInterfaces[{vmk_label}]"
        if service not in ("vMotion", "vSAN", "vSAN Witness"):
            errors.append(f"{vmk_prefix}.service: must be 'vMotion', 'vSAN', or 'vSAN Witness'.")
        else:
            found_services.add(service)

        vlan_err = validate_vlan_id(vmk.get("vlanId"), f"{vmk_prefix}.vlanId")
        if vlan_err:
            errors.append(vlan_err)

        netmask = vmk.get("netmask", "")
        if not is_valid_ipv4(netmask):
            errors.append(f"{vmk_prefix}.netmask: must be a valid IPv4 address.")
        elif not is_valid_netmask(netmask):
            errors.append(
                f"{vmk_prefix}.netmask: '{netmask}' is not a valid subnet mask "
                "(must be contiguous 1-bits followed by 0-bits, e.g. 255.255.255.0)."
            )

        ip_list = vmk.get("ipList", [])
        if not isinstance(ip_list, list) or len(ip_list) != 2:
            errors.append(f"{vmk_prefix}.ipList: must be an array of exactly 2 IPv4 addresses.")
        else:
            for ip in ip_list:
                if not is_valid_ipv4(ip):
                    errors.append(f"{vmk_prefix}.ipList: '{ip}' is not a valid IPv4 address.")
            if len(set(ip_list)) != len(ip_list):
                errors.append(f"{vmk_prefix}.ipList: IP addresses must be unique.")

        if service == "vSAN Witness":
            gw = vmk.get("gateway", "")
            if gw and not is_valid_ipv4(gw):
                errors.append(f"{vmk_prefix}.gateway: must be a valid IPv4 address.")

    for required_svc in ("vMotion", "vSAN"):
        if required_svc not in found_services:
            errors.append(
                f"{prefix}.networking.networkingVmKernelInterfaces: "
                f"missing required service '{required_svc}'."
            )


def _validate_networking(networking, storage_type, prefix, errors):
    """
    Validates a cluster's networking block, appending errors in place.
    Returns (seg_names, seg_gw_map) for the cluster's segments (both empty on validation failure).
    """
    segments = networking.get("networkSegments")
    seg_names = []
    seg_gw_map = {}

    if not isinstance(segments, list) or len(segments) == 0:
        errors.append(f"{prefix}.networking.networkSegments: must be a non-empty array.")
    else:
        seen_vlans = set()
        for seg_idx, seg in enumerate(segments):
            seg_name = seg.get("name", "")
            seg_label = f'"{seg_name}"' if seg_name else str(seg_idx)
            seg_prefix = f"{prefix}.networking.networkSegments[{seg_label}]"
            if not seg_name:
                errors.append(f"{seg_prefix}.name: required field is missing.")
            elif not is_valid_rfc1123(seg_name):
                errors.append(
                    f"{seg_prefix}.name: '{seg_name}' must be lowercase RFC1123 "
                    "(lowercase letters, numbers, hyphens; no leading/trailing hyphens)."
                )
            else:
                seg_names.append(seg_name)

            vlan_err = validate_vlan_id(seg.get("vlanId"), f"{seg_prefix}.vlanId")
            if vlan_err:
                errors.append(vlan_err)
            else:
                # Only track duplicates when the VLAN is structurally valid; validate_vlan_id
                # rejects None/non-integer values so str() here is always a numeric string.
                vid = str(seg.get("vlanId"))
                if vid in seen_vlans:
                    errors.append(f"{seg_prefix}.vlanId: duplicate VLAN ID {vid} within cluster.")
                seen_vlans.add(vid)

            gw = seg.get("gateway", "")
            if not is_valid_cidr(gw):
                errors.append(
                    f"{seg_prefix}.gateway: must be a valid CIDR (e.g. 10.0.0.1/24), got '{gw}'."
                )
            elif seg_name:
                seg_gw_map[seg_name] = gw

    if storage_type in ("vSAN-OSA", "vSAN-ESA"):
        _validate_vmk_interfaces(
            networking.get("networkingVmKernelInterfaces"), storage_type, prefix, errors
        )

    return seg_names, seg_gw_map


def _validate_cluster(cluster, idx, common, common_nic_list, errors):
    """
    Validates a single cluster entry, appending errors in place.
    Returns (edge_site, seg_names, seg_gw_map); edge_site is None on fatal cluster error.
    """
    if not isinstance(cluster, dict):
        errors.append(f"infrastructure.clusters[{idx}]: must be an object.")
        return None, [], {}

    edge_site = cluster.get("edgeSite")
    # Use the edgeSite name in the prefix so errors read clusters["site-1"].field
    # rather than clusters[0].field, making it immediately clear which site failed.
    prefix = f'infrastructure.clusters["{edge_site}"]' if edge_site else f"infrastructure.clusters[{idx}]"

    if not edge_site:
        errors.append(f"{prefix}.edgeSite: required field is missing or empty.")

    esx_hosts = cluster.get("esxHosts")
    if cluster.get("esxHost"):
        errors.append(f"{prefix}: use 'esxHosts' (array), not the deprecated 'esxHost'.")
    if not isinstance(esx_hosts, list) or len(esx_hosts) == 0:
        errors.append(f"{prefix}.esxHosts: must be a non-empty array of host FQDNs/IPs.")
    else:
        for h in esx_hosts:
            if not is_valid_fqdn_or_ip(str(h)):
                errors.append(f"{prefix}.esxHosts: '{h}' is not a valid FQDN or IPv4 address.")

    cluster_nic_list = cluster.get("nicList")
    effective_nic_list = cluster_nic_list if cluster_nic_list is not None else common_nic_list
    if effective_nic_list is None:
        errors.append(
            f"{prefix}.nicList: no nicList found at cluster or common level; must provide 2 or 4 NICs."
        )
    elif not isinstance(effective_nic_list, list) or len(effective_nic_list) not in (2, 4):
        errors.append(f"{prefix}.nicList: effective nicList must have exactly 2 or 4 NIC objects.")

    storage_policy = cluster.get("storagePolicy")
    storage_type = None
    if not isinstance(storage_policy, dict):
        errors.append(f"{prefix}.storagePolicy: required object is missing.")
    else:
        storage_type = storage_policy.get("storageType")
        if storage_type not in ("VMFS", "vSAN-ESA", "vSAN-OSA"):
            errors.append(
                f"{prefix}.storagePolicy.storageType: must be 'VMFS', 'vSAN-ESA', or 'vSAN-OSA'."
            )
        storage_policy_rule = storage_policy.get("storagePolicyRule")
        if storage_policy_rule is not None and storage_policy_rule != "Fully initialized":
            errors.append(
                f"{prefix}.storagePolicy.storagePolicyRule: only valid value is 'Fully initialized'."
            )

    if isinstance(esx_hosts, list) and storage_type is not None:
        if storage_type == "VMFS":
            if len(esx_hosts) != 1:
                errors.append(f"{prefix}.esxHosts: VMFS requires exactly 1 host, got {len(esx_hosts)}.")
        elif storage_type in ("vSAN-OSA", "vSAN-ESA"):
            if len(esx_hosts) != _VSAN_HOST_COUNT:
                errors.append(
                    f"{prefix}.esxHosts: {storage_type} requires exactly {_VSAN_HOST_COUNT} hosts, got {len(esx_hosts)}."
                )

    if storage_type in ("vSAN-OSA", "vSAN-ESA"):
        witness = cluster.get("vSanWitnessVmName") or common.get("vSanWitnessVmName", "")
        if not witness:
            errors.append(
                f"{prefix}.vSanWitnessVmName: required for {storage_type} (at cluster or common level)."
            )
        elif not is_valid_fqdn_or_ip(witness):
            errors.append(
                f"{prefix}.vSanWitnessVmName: '{witness}' must be a valid FQDN or IPv4 address."
            )

    cluster_ha = cluster.get("haPolicy")
    if cluster_ha is not None and cluster_ha not in ("reservationBased", "slotBased", "disabled"):
        errors.append(f"{prefix}.haPolicy: must be 'reservationBased', 'slotBased', or 'disabled'.")

    seg_names, seg_gw_map = [], {}
    networking = cluster.get("networking")
    if not isinstance(networking, dict):
        errors.append(f"{prefix}.networking: required object is missing.")
    else:
        seg_names, seg_gw_map = _validate_networking(networking, storage_type, prefix, errors)

    harbor = cluster.get("harborConfiguration")
    disable_harbor = _resolve_bool(cluster, common, "disableHarbor")
    if not disable_harbor:
        has_hostname = isinstance(harbor, dict) and bool(harbor.get("hostname"))
        lab_mode = common.get("labenvironment") is True
        # In lab mode the PowerShell module falls back to reading hostname from the Harbor data-values
        # YAML template (Get-EffectiveHarborHostnameForInfrastructureCluster), but only when both
        # tlsCrt and tlsKey are omitted. Mirror that logic: if lab mode is active and no custom TLS
        # PEM paths are set, missing hostname is a warning rather than a hard error.
        has_tls_crt = isinstance(harbor, dict) and bool(harbor.get("tlsCrt"))
        has_tls_key = isinstance(harbor, dict) and bool(harbor.get("tlsKey"))
        lab_hostname_fallback = lab_mode and not has_tls_crt and not has_tls_key
        if not has_hostname:
            if lab_hostname_fallback:
                errors.append(
                    f"[WARNING] {prefix}.harborConfiguration.hostname: not set; "
                    "lab mode is enabled so hostname will be read from the Harbor data-values YAML template at runtime."
                )
            else:
                errors.append(
                    f"{prefix}.harborConfiguration.hostname: required unless disableHarbor is true."
                )
        if isinstance(harbor, dict):
            _validate_harbor(harbor, prefix, errors)

    return edge_site, seg_names, seg_gw_map


def validate_infrastructure(infra):
    """
    Validates an infrastructure dict against all known rules.
    Returns (errors, cluster_segment_names, cluster_segment_gateways).
    """
    errors = []

    common = infra.get("common")
    if not isinstance(common, dict):
        errors.append("infrastructure: missing or invalid 'common' object.")
        return errors, {}, {}

    _validate_common(common, errors)

    clusters = infra.get("clusters")
    if not isinstance(clusters, list) or len(clusters) == 0:
        errors.append("infrastructure.clusters: must be a non-empty array.")
        return errors, {}, {}

    seen_edge_sites = set()
    cluster_segment_names = {}
    cluster_segment_gateways = {}

    for idx, cluster in enumerate(clusters):
        edge_site, seg_names, seg_gw_map = _validate_cluster(
            cluster, idx, common, common.get("nicList"), errors
        )
        if edge_site:
            if edge_site in seen_edge_sites:
                errors.append(
                    f"infrastructure.clusters[{idx}].edgeSite: duplicate edgeSite '{edge_site}'."
                )
            else:
                seen_edge_sites.add(edge_site)
                cluster_segment_names[edge_site] = seg_names
                cluster_segment_gateways[edge_site] = seg_gw_map

    # Global: segment names must be unique across ALL clusters (case-sensitive).
    seen_global = {}
    for site, names in cluster_segment_names.items():
        for name in names:
            if name in seen_global:
                errors.append(
                    f"infrastructure: network segment name '{name}' is used in both edgeSite "
                    f"'{seen_global[name]}' and '{site}'. Segment names must be globally unique."
                )
            else:
                seen_global[name] = site

    return errors, cluster_segment_names, cluster_segment_gateways


def _resolve_bool(cluster, common, key):
    """Resolves a boolean flag from cluster supervisorServices, then common supervisorServices."""
    cluster_svcs = cluster.get("supervisorServices", {}) or {}
    common_svcs = common.get("supervisorServices", {}) or {}
    if key in cluster_svcs:
        return bool(cluster_svcs[key])
    if key in common_svcs:
        return bool(common_svcs[key])
    return False


def validate_supervisor(supervisor, cluster_segment_names, cluster_segment_gateways=None):
    """
    Validates a supervisor dict against all known rules.
    cluster_segment_names: dict of {edgeSite: [segment_name, ...]} from infrastructure validation.
    cluster_segment_gateways: dict of {edgeSite: {segment_name: cidr_gateway}} for IP-in-range checks.
    Returns (errors, warnings) — both lists of plain strings. Warnings do not fail validation.
    """
    if cluster_segment_gateways is None:
        cluster_segment_gateways = {}
    errors = []
    warnings = []

    common_spec = supervisor.get("commonSupervisorSpec")
    if not isinstance(common_spec, dict):
        errors.append("supervisor: missing or invalid 'commonSupervisorSpec' object.")
        return errors, warnings

    # Required commonSupervisorSpec fields.
    control_plane_count = common_spec.get("controlPlaneVMCount")
    if control_plane_count not in (1, 3):
        errors.append(
            "supervisor.commonSupervisorSpec.controlPlaneVMCount: must be 1 or 3."
        )

    if common_spec.get("controlPlaneSize") not in ("TINY", "SMALL", "MEDIUM", "LARGE"):
        errors.append(
            "supervisor.commonSupervisorSpec.controlPlaneSize: must be 'TINY', 'SMALL', 'MEDIUM', or 'LARGE'."
        )

    if common_spec.get("flbAvailability") not in ("SINGLE_NODE", "ACTIVE_PASSIVE"):
        errors.append(
            "supervisor.commonSupervisorSpec.flbAvailability: must be 'SINGLE_NODE' or 'ACTIVE_PASSIVE'."
        )

    if common_spec.get("flbSize") not in ("SMALL", "MEDIUM", "LARGE", "X-LARGE"):
        errors.append(
            "supervisor.commonSupervisorSpec.flbSize: must be 'SMALL', 'MEDIUM', 'LARGE', or 'X-LARGE'."
        )

    if common_spec.get("flbNetworkType") != "DVPG":
        errors.append("supervisor.commonSupervisorSpec.flbNetworkType: must be 'DVPG'.")

    for arr_field in ("networkSearchDomains", "networkNtpServers", "dnsServers"):
        val = common_spec.get(arr_field)
        if not isinstance(val, list) or len(val) == 0:
            errors.append(
                f"supervisor.commonSupervisorSpec.{arr_field}: must be a non-empty array."
            )

    # DNS servers: 1–3 entries, each a valid IPv4 address.
    dns_servers = common_spec.get("dnsServers", [])
    if isinstance(dns_servers, list):
        if len(dns_servers) > 3:
            errors.append(
                "supervisor.commonSupervisorSpec.dnsServers: maximum 3 DNS servers allowed."
            )
        for dns in dns_servers:
            if not is_valid_ipv4(str(dns)):
                errors.append(
                    f"supervisor.commonSupervisorSpec.dnsServers: '{dns}' is not a valid IPv4 address."
                )

    site_specs = supervisor.get("siteSpec")
    if not isinstance(site_specs, list) or len(site_specs) == 0:
        errors.append("supervisor.siteSpec: must be a non-empty array.")
        return errors, warnings

    seen_edge_sites = set()
    infra_edge_sites = set(cluster_segment_names.keys())

    # Cross-file check: every supervisor siteSpec entry must match an infrastructure edgeSite,
    # and every infrastructure edgeSite must have a corresponding supervisor siteSpec entry.
    # Only performed when infrastructure was validated and produced at least one edgeSite.
    if infra_edge_sites:
        sup_edge_sites = {
            s.get("edgeSite") for s in site_specs
            if isinstance(s, dict) and s.get("edgeSite")
        }
        for name in sorted(sup_edge_sites - infra_edge_sites):
            errors.append(
                f"supervisor.siteSpec: edgeSite '{name}' does not match any infrastructure "
                f"cluster edgeSite. Infrastructure has: {sorted(infra_edge_sites)}."
            )
        for name in sorted(infra_edge_sites - sup_edge_sites):
            warnings.append(
                f"[WARNING] supervisor.siteSpec: infrastructure edgeSite '{name}' has no matching "
                f"supervisor siteSpec entry. Supervisor configuration for this site will be empty."
            )

    for idx, site in enumerate(site_specs):
        if not isinstance(site, dict):
            errors.append(f"supervisor.siteSpec[{idx}]: must be an object.")
            continue

        edge_site = site.get("edgeSite")
        # Use the edgeSite name in the prefix so errors are immediately attributable.
        prefix = f'supervisor.siteSpec["{edge_site}"]' if edge_site else f"supervisor.siteSpec[{idx}]"

        if not edge_site:
            errors.append(f"{prefix}.edgeSite: required field is missing or empty.")
        elif edge_site in seen_edge_sites:
            errors.append(f"{prefix}.edgeSite: duplicate edgeSite '{edge_site}'.")
        else:
            seen_edge_sites.add(edge_site)

        site_segments = cluster_segment_names.get(edge_site, [])

        # FLB components.
        flb = site.get("foundationLoadBalancerComponents")
        if not isinstance(flb, dict):
            errors.append(f"{prefix}.foundationLoadBalancerComponents: required object is missing.")
        else:
            if not flb.get("flbName"):
                errors.append(f"{prefix}.foundationLoadBalancerComponents.flbName: required.")

            flb_vip_start = flb.get("flbVipStartIP", "")
            if not is_valid_ipv4(flb_vip_start):
                errors.append(
                    f"{prefix}.foundationLoadBalancerComponents.flbVipStartIP: must be a valid IPv4 address."
                )

            try:
                vip_count = int(flb.get("flbVipIPCount", 0))
                if vip_count <= 0:
                    errors.append(
                        f"{prefix}.foundationLoadBalancerComponents.flbVipIPCount: must be a positive integer."
                    )
            except (TypeError, ValueError):
                errors.append(
                    f"{prefix}.foundationLoadBalancerComponents.flbVipIPCount: must be a positive integer."
                )

            for net_key in ("flbManagementNetwork", "flbVirtualServerNetwork"):
                net = flb.get(net_key)
                if not isinstance(net, dict):
                    errors.append(f"{prefix}.foundationLoadBalancerComponents.{net_key}: required object is missing.")
                else:
                    net_name = net.get("flbNetworkName", "")
                    if not net_name:
                        errors.append(
                            f"{prefix}.foundationLoadBalancerComponents.{net_key}.flbNetworkName: required."
                        )
                    elif site_segments and net_name not in site_segments:
                        errors.append(
                            f"{prefix}.foundationLoadBalancerComponents.{net_key}.flbNetworkName: "
                            f"'{net_name}' does not match any networkSegments name for edgeSite '{edge_site}'. "
                            f"Available: {site_segments}."
                        )

                    start_ip = net.get("flbNetworkIpAddressStartingIp", "")
                    if not is_valid_ipv4(start_ip):
                        errors.append(
                            f"{prefix}.foundationLoadBalancerComponents.{net_key}"
                            f".flbNetworkIpAddressStartingIp: must be a valid IPv4 address."
                        )

                    try:
                        ip_count = int(net.get("flbNetworkIpAddressCount", 0))
                    except (TypeError, ValueError):
                        ip_count = -1

                    if net_key == "flbVirtualServerNetwork":
                        # Warn (do not fail) when the virtual-server-network IP pool is small.
                        if ip_count < _FLOATING_IP_WARNING_THRESHOLD:
                            warnings.append(
                                f"{prefix}.foundationLoadBalancerComponents.{net_key}"
                                f".flbNetworkIpAddressCount: {ip_count} IP(s) defined for edgeSite '{edge_site}'."
                                f" Fewer than {_FLOATING_IP_WARNING_THRESHOLD} floating IPs may not be enough"
                                f" to deploy all services."
                            )
                    else:
                        if ip_count < 2:
                            errors.append(
                                f"{prefix}.foundationLoadBalancerComponents.{net_key}"
                                f".flbNetworkIpAddressCount: must be an integer ≥ 2."
                            )

                    gw_override = net.get("flbNetworkGateway")
                    if gw_override and not is_valid_cidr(gw_override) and not is_valid_ipv4(gw_override):
                        errors.append(
                            f"{prefix}.foundationLoadBalancerComponents.{net_key}"
                            f".flbNetworkGateway: must be a valid IPv4 address or CIDR."
                        )

                    # Starting IP must fall within the gateway CIDR for this segment.
                    site_gateways = cluster_segment_gateways.get(edge_site, {})
                    if net_name and net_name in site_gateways and is_valid_ipv4(start_ip):
                        cidr = site_gateways[net_name]
                        if not is_ip_in_cidr(start_ip, cidr):
                            errors.append(
                                f"{prefix}.foundationLoadBalancerComponents.{net_key}"
                                f".flbNetworkIpAddressStartingIp: '{start_ip}' is not within the "
                                f"gateway subnet {cidr} for segment '{net_name}'."
                            )

        # Management network spec.
        mgmt = site.get("mgmtNetworkSpec")
        site_gateways = cluster_segment_gateways.get(edge_site, {})
        if not isinstance(mgmt, dict):
            errors.append(f"{prefix}.mgmtNetworkSpec: required object is missing.")
        else:
            mgmt_name = mgmt.get("mgmtNetworkName", "")
            if not mgmt_name:
                errors.append(f"{prefix}.mgmtNetworkSpec.mgmtNetworkName: required.")
            elif site_segments and mgmt_name not in site_segments:
                errors.append(
                    f"{prefix}.mgmtNetworkSpec.mgmtNetworkName: "
                    f"'{mgmt_name}' does not match any networkSegments name for edgeSite '{edge_site}'. "
                    f"Available: {site_segments}."
                )

            mgmt_start = mgmt.get("mgmtNetworkStartingIp", "")
            if not is_valid_ipv4(mgmt_start):
                errors.append(f"{prefix}.mgmtNetworkSpec.mgmtNetworkStartingIp: must be a valid IPv4 address.")
            elif mgmt_name and mgmt_name in site_gateways and not is_ip_in_cidr(mgmt_start, site_gateways[mgmt_name]):
                errors.append(
                    f"{prefix}.mgmtNetworkSpec.mgmtNetworkStartingIp: '{mgmt_start}' is not within "
                    f"the gateway subnet {site_gateways[mgmt_name]} for segment '{mgmt_name}'."
                )

            try:
                mgmt_count = int(mgmt.get("mgmtNetworkIPCount", 0))
            except (TypeError, ValueError):
                mgmt_count = -1
            if mgmt_count < 5:
                errors.append(f"{prefix}.mgmtNetworkSpec.mgmtNetworkIPCount: must be an integer ≥ 5.")

        # Primary workload network.
        pwn = site.get("primaryWorkloadNetwork")
        if not isinstance(pwn, dict):
            errors.append(f"{prefix}.primaryWorkloadNetwork: required object is missing.")
        else:
            pwn_name = pwn.get("primaryWorkloadNetworkName", "")
            if not pwn_name:
                errors.append(f"{prefix}.primaryWorkloadNetwork.primaryWorkloadNetworkName: required.")
            elif site_segments and pwn_name not in site_segments:
                errors.append(
                    f"{prefix}.primaryWorkloadNetwork.primaryWorkloadNetworkName: "
                    f"'{pwn_name}' does not match any networkSegments name for edgeSite '{edge_site}'. "
                    f"Available: {site_segments}."
                )

            pwn_start = pwn.get("primaryWorkloadNetworkStartingIp", "")
            if not is_valid_ipv4(pwn_start):
                errors.append(
                    f"{prefix}.primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp: must be a valid IPv4 address."
                )
            elif pwn_name and pwn_name in site_gateways and not is_ip_in_cidr(pwn_start, site_gateways[pwn_name]):
                errors.append(
                    f"{prefix}.primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp: '{pwn_start}' is not within "
                    f"the gateway subnet {site_gateways[pwn_name]} for segment '{pwn_name}'."
                )

            try:
                pwn_ip_count = int(pwn.get("primaryWorkloadNetworkIPCount", 0))
            except (TypeError, ValueError):
                pwn_ip_count = -1
            if pwn_ip_count < 2:
                errors.append(
                    f"{prefix}.primaryWorkloadNetwork.primaryWorkloadNetworkIPCount: must be an integer ≥ 2."
                )

            if not is_valid_ipv4(pwn.get("workloadServiceStartIp", "")):
                errors.append(
                    f"{prefix}.primaryWorkloadNetwork.workloadServiceStartIp: must be a valid IPv4 address."
                )

            wsc = pwn.get("workloadServiceCount")
            if not is_power_of_two(wsc):
                errors.append(
                    f"{prefix}.primaryWorkloadNetwork.workloadServiceCount: "
                    f"must be a power of 2 (e.g. 256, 512, 1024) to occupy a full CIDR block."
                )

    return errors, warnings


def validate_cross_file(infra_cluster_sites, supervisor_site_specs):
    """
    Validates that edgeSite values match bidirectionally between infrastructure and supervisor.
    Returns a list of error strings.
    """
    errors = []
    infra_sites = set(infra_cluster_sites)
    sup_sites = set(supervisor_site_specs)

    for site in infra_sites - sup_sites:
        errors.append(
            f"Cross-file: edgeSite '{site}' exists in infrastructure.clusters but has no matching "
            "entry in supervisor.siteSpec."
        )
    for site in sup_sites - infra_sites:
        errors.append(
            f"Cross-file: edgeSite '{site}' exists in supervisor.siteSpec but has no matching "
            "entry in infrastructure.clusters."
        )
    return errors


# ---------------------------------------------------------------------------
# Per-step validation message formatters (PS-style [ERROR]/[WARNING]/[INFO])
# ---------------------------------------------------------------------------

def _fmt(error_str):
    """Converts a plain error string to a PS-style [ERROR] message.

    Strings that already carry a PS-style prefix ([ERROR], [WARNING], [INFO])
    are passed through unchanged so pre-tagged messages (e.g. lab-mode warnings
    emitted directly by validation helpers) are not double-prefixed.
    """
    if error_str.startswith(("[ERROR]", "[WARNING]", "[INFO]")):
        return error_str
    return f"[ERROR] {error_str}"


def _validate_step1_messages(infra, base_dir=None):
    """
    Validates only Step 1 (Common Settings) fields and returns PS-style messages.
    Mirrors the feedback the PowerShell script would emit during pre-flight.

    When base_dir is provided, the four supervisorServices YAML filenames are
    checked for existence on disk (relative to parentDirectory, or base_dir if
    parentDirectory is blank) so the user cannot proceed without valid files.
    """
    messages = []
    common = infra.get("common", {})

    vc_name = common.get("vCenterName", "")
    if not vc_name:
        messages.append("[ERROR] common.vCenterName is required. Specify the FQDN or IP of the vCenter Server 9.0+.")
    elif not is_valid_fqdn_or_ip(vc_name):
        messages.append(f"[ERROR] common.vCenterName: '{vc_name}' is not a valid FQDN or IPv4 address.")
    else:
        messages.append(f"[INFO] common.vCenterName: '{vc_name}' — format OK.")

    vc_user = common.get("vCenterUser", "")
    if not vc_user:
        messages.append("[ERROR] common.vCenterUser is required (e.g. administrator@vsphere.local).")
    elif not VCENTER_USER_RE.match(vc_user):
        messages.append(f"[ERROR] common.vCenterUser: '{vc_user}' contains invalid characters.")
    else:
        messages.append(f"[INFO] common.vCenterUser: '{vc_user}' — format OK.")

    dc = common.get("datacenterName", "")
    if not dc:
        messages.append("[ERROR] common.datacenterName is required. The datacenter must already exist in vCenter.")
    else:
        messages.append(f"[INFO] common.datacenterName: '{dc}'.")

    ctx = common.get("contextName", "")
    if not ctx:
        messages.append("[WARNING] common.contextName is not set. Required unless all clusters disable all supervisor services (ArgoCD and Harbor).")

    nic_list = common.get("nicList", [])
    if not isinstance(nic_list, list) or len(nic_list) == 0:
        messages.append("[ERROR] common.nicList is empty. At least one NIC pair (2 NICs) must be configured.")
    elif len(nic_list) not in (2, 4):
        messages.append(f"[ERROR] common.nicList: found {len(nic_list)} NIC(s). Must be exactly 2 or 4.")
    else:
        nics = ", ".join(n.get("name", "?") for n in nic_list)
        messages.append(f"[INFO] common.nicList: {len(nic_list)} NICs ({nics}) — OK.")

    for bool_field in ("esxUniquePasswordPerHost", "nonInteractivePassword", "autoUpdate", "labenvironment", "preserveAutoGeneratedKeyCertPair"):
        val = common.get(bool_field)
        if val is not None and not isinstance(val, bool):
            messages.append(
                f"[ERROR] common.{bool_field}: must be a JSON boolean (true/false), not a string."
            )

    ha_policy = common.get("haPolicy")
    if ha_policy is not None and ha_policy not in ("reservationBased", "slotBased", "disabled"):
        messages.append(
            f"[ERROR] common.haPolicy: '{ha_policy}' is invalid. "
            "Must be 'reservationBased', 'slotBased', or 'disabled'."
        )
    elif ha_policy:
        messages.append(f"[INFO] common.haPolicy: '{ha_policy}'.")

    for mtu_key in ("vSanvMotionVmKernelMtuValue", "vmkernelMtu"):
        mtu = common.get(mtu_key)
        if mtu is not None:
            try:
                mtu_int = int(mtu)
                if mtu_int < 1500 or mtu_int > 9190:
                    messages.append(f"[ERROR] common.{mtu_key}: {mtu} is out of range. Must be 1500–9190.")
                else:
                    messages.append(f"[INFO] common.{mtu_key}: {mtu_int} — OK.")
            except (TypeError, ValueError):
                messages.append(f"[ERROR] common.{mtu_key}: must be an integer.")

    for prefix_field in ("clusterNamePrefix", "datastoreNamePrefix", "supervisorNamePrefix", "vdsNamePrefix"):
        val = common.get(prefix_field, "")
        if val and not VSPHERE_NAME_RE.match(val):
            messages.append(
                f"[ERROR] common.{prefix_field}: '{val}' contains characters not allowed in vSphere object names."
            )

    # Validate supervisorServices YAML file existence when the server base_dir is available.
    if base_dir is not None:
        svcs = common.get("supervisorServices", {}) or {}
        parent_dir_str = (svcs.get("parentDirectory") or "").strip()
        parent_dir = Path(parent_dir_str) if parent_dir_str else Path(base_dir)

        # Check the parent directory first; if it is missing, emit one error and skip per-file checks.
        if parent_dir_str and not parent_dir.is_dir():
            messages.append(
                f"[ERROR] supervisorServices.parentDirectory: '{parent_dir}' does not exist or is not a directory. "
                "Correct the path before specifying YAML filenames."
            )
        else:
            yaml_fields = (
                ("argoCdOperatorYamlFileName",      "ArgoCD Operator YAML"),
                ("argoCdDeploymentYamlFileName",     "ArgoCD Deployment YAML"),
                ("harborDataTemplateYamlFileName",   "Harbor Data Template YAML"),
                ("harborServiceYamlFileName",        "Harbor Service YAML"),
            )
            for field, label in yaml_fields:
                filename = (svcs.get(field) or "").strip()
                if not filename:
                    continue
                full_path = parent_dir / filename
                if full_path.exists():
                    messages.append(f"[INFO] {label}: '{filename}' found — OK.")
                else:
                    messages.append(
                        f"[ERROR] {label}: '{filename}' not found in '{parent_dir}'. "
                        "Verify the filename is correct."
                    )

    return messages


def _format_infra_messages(errors, infra):
    """
    Converts infrastructure validation errors into PS-style messages,
    adding INFO confirmations for each cluster that has no errors of its own.

    INFO lines are emitted per-cluster regardless of whether other clusters
    have errors, so the user can see which sites are already valid while
    fixing the others.
    """
    messages = [_fmt(e) for e in errors]
    clusters = infra.get("clusters", [])
    for cluster in clusters:
        site = cluster.get("edgeSite", "?")
        # Only emit an OK confirmation when this specific site has no errors.
        site_prefix = f'infrastructure.clusters["{site}"]'
        if not any(site_prefix in m for m in messages):
            storage_type = (cluster.get("storagePolicy") or {}).get("storageType", "?")
            esx_count = len(cluster.get("esxHosts", []))
            seg_count = len((cluster.get("networking") or {}).get("networkSegments", []))
            messages.append(
                f"[INFO] Site '{site}': {storage_type}, {esx_count} ESX host(s), "
                f"{seg_count} network segment(s) — OK."
            )
    return messages


# ---------------------------------------------------------------------------
# JSON builder helpers
# ---------------------------------------------------------------------------

def _iget(d, key, default=None):
    """Case-insensitive dict lookup — tries the exact key first, then lowercased comparison.

    The supervisor.json spec uses camelCase keys but some real-world files use PascalCase
    (e.g. "SiteSpec", "MgmtNetworkSpec"). This helper makes the builder tolerant of both
    without requiring the file to be normalized first.
    """
    if not isinstance(d, dict):
        return default
    if key in d:
        return d[key]
    key_lower = key.lower()
    for k, v in d.items():
        if k.lower() == key_lower:
            return v
    return default


def _to_str_list(value):
    """Converts a comma-separated string or list to a list of stripped strings."""
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    return [s.strip() for s in str(value).split(",") if s.strip()]


def _add_optional_str(target, source, key):
    val = _iget(source, key, "")
    if val:
        target[key] = val


def _add_optional_bool(target, source, key):
    """
    Writes key → bool into target if the source contains a recognizable boolean value.
    Crucially, explicit False IS written (not silently dropped) so that a cluster-level
    False can override a common-level True in the PowerShell module's resolution logic,
    which checks whether the key is present before falling through to common.
    Only a truly absent key (None / missing) is omitted.
    """
    val = _iget(source, key)
    if val is None or val == "":
        return
    if isinstance(val, bool):
        target[key] = val
    elif str(val).lower() == "true":
        target[key] = True
    elif str(val).lower() == "false":
        target[key] = False


def _safe_int(value, default=0):
    """Converts value to int, returning default on failure.

    Prevents cryptic build errors when a numeric field contains a non-numeric
    string (e.g. from a malformed or manually edited input JSON file).
    """
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# JSON builders (dict → clean JSON structure)
# ---------------------------------------------------------------------------

def build_infrastructure(data):
    """Builds a clean infrastructure dict from the validated form data dict."""
    common = data.get("common") or {}

    raw_nic = common.get("nicList", "")
    if isinstance(raw_nic, list):
        nic_list = raw_nic
    else:
        nic_list = [{"name": n.strip()} for n in str(raw_nic).split(",") if n.strip()]

    common_obj = {
        "vCenterName": common.get("vCenterName", ""),
        "vCenterUser": common.get("vCenterUser", ""),
        "contextName": common.get("contextName", ""),
        "datacenterName": common.get("datacenterName", ""),
        "nicList": nic_list,
    }

    _add_optional_str(common_obj, common, "esxUser")
    _add_optional_str(common_obj, common, "vSanWitnessVmName")
    _add_optional_str(common_obj, common, "haPolicy")
    _add_optional_str(common_obj, common, "clusterNamePrefix")
    _add_optional_str(common_obj, common, "datastoreNamePrefix")
    _add_optional_str(common_obj, common, "supervisorNamePrefix")
    _add_optional_str(common_obj, common, "vdsNamePrefix")
    _add_optional_str(common_obj, common, "vLcmImageName")
    _add_optional_str(common_obj, common, "supervisorContentLibraryDatastore")
    _add_optional_str(common_obj, common, "supervisorContentLibrarySubscriptionUrl")
    _add_optional_bool(common_obj, common, "esxUniquePasswordPerHost")
    _add_optional_bool(common_obj, common, "nonInteractivePassword")
    _add_optional_bool(common_obj, common, "autoUpdate")
    _add_optional_bool(common_obj, common, "labenvironment")
    _add_optional_bool(common_obj, common, "preserveAutoGeneratedKeyCertPair")

    if common.get("vSanvMotionVmKernelMtuValue"):
        try:
            common_obj["vSanvMotionVmKernelMtuValue"] = int(common["vSanvMotionVmKernelMtuValue"])
        except (ValueError, TypeError):
            pass

    # Supervisor services at common level.
    svcs_obj = {}
    svcs = common.get("supervisorServices", {})
    _add_optional_str(svcs_obj, svcs, "parentDirectory")
    _add_optional_str(svcs_obj, svcs, "argoCdOperatorYamlFileName")
    _add_optional_str(svcs_obj, svcs, "argoCdDeploymentYamlFileName")
    _add_optional_str(svcs_obj, svcs, "harborDataTemplateYamlFileName")
    _add_optional_str(svcs_obj, svcs, "harborServiceYamlFileName")
    _add_optional_bool(svcs_obj, svcs, "disableArgoCD")
    _add_optional_bool(svcs_obj, svcs, "disableHarbor")
    if svcs_obj:
        common_obj["supervisorServices"] = svcs_obj

    clusters_out = []
    for cluster in data.get("clusters", []):
        cluster_obj = {"edgeSite": cluster.get("edgeSite", "")}

        esx_hosts_raw = cluster.get("esxHosts", "")
        if isinstance(esx_hosts_raw, list):
            cluster_obj["esxHosts"] = esx_hosts_raw
        else:
            cluster_obj["esxHosts"] = [h.strip() for h in str(esx_hosts_raw).split(",") if h.strip()]

        # Per-cluster nicList override.
        cluster_nic_raw = cluster.get("nicList", "")
        if isinstance(cluster_nic_raw, list) and cluster_nic_raw:
            cluster_obj["nicList"] = cluster_nic_raw
        elif isinstance(cluster_nic_raw, str) and cluster_nic_raw.strip():
            cluster_obj["nicList"] = [{"name": n.strip()} for n in cluster_nic_raw.split(",") if n.strip()]

        _add_optional_str(cluster_obj, cluster, "vSanWitnessVmName")
        _add_optional_str(cluster_obj, cluster, "haPolicy")

        # Harbor configuration.
        harbor = cluster.get("harborConfiguration", {})
        harbor_obj = {}
        _add_optional_str(harbor_obj, harbor, "hostname")
        _add_optional_str(harbor_obj, harbor, "parentDirectory")
        _add_optional_str(harbor_obj, harbor, "tlsCrt")
        _add_optional_str(harbor_obj, harbor, "tlsKey")
        _add_optional_str(harbor_obj, harbor, "caCrt")
        _add_optional_str(harbor_obj, harbor, "harborAdminPassword")
        _add_optional_str(harbor_obj, harbor, "secretKey")
        _add_optional_str(harbor_obj, harbor, "databasePassword")
        _add_optional_str(harbor_obj, harbor, "coreSecret")
        _add_optional_str(harbor_obj, harbor, "jobserviceSecret")
        _add_optional_str(harbor_obj, harbor, "registrySecret")
        _add_optional_str(harbor_obj, harbor, "registryVolumeSize")
        _add_optional_str(harbor_obj, harbor, "jobserviceVolumeSize")
        _add_optional_str(harbor_obj, harbor, "databaseVolumeSize")
        _add_optional_str(harbor_obj, harbor, "redisVolumeSize")
        _add_optional_str(harbor_obj, harbor, "trivyVolumeSize")
        if harbor_obj:
            cluster_obj["harborConfiguration"] = harbor_obj

        # Storage policy.
        cluster_obj["storagePolicy"] = {
            "storageType": cluster.get("storagePolicy", {}).get("storageType", "VMFS")
        }
        storage_rule = cluster.get("storagePolicy", {}).get("storagePolicyRule", "").strip()
        if storage_rule:
            cluster_obj["storagePolicy"]["storagePolicyRule"] = storage_rule

        # Networking: segments.
        segments_out = []
        for seg in cluster.get("networking", {}).get("networkSegments", []):
            try:
                vlan_id = int(seg.get("vlanId", 0))
            except (TypeError, ValueError):
                vlan_id = 0
            segments_out.append({
                "name": seg.get("name", ""),
                "vlanId": vlan_id,
                "gateway": seg.get("gateway", ""),
            })

        networking_obj = {"networkSegments": segments_out}

        # VMkernel interfaces (vSAN only).
        vmk_list = cluster.get("networking", {}).get("networkingVmKernelInterfaces", [])
        if vmk_list:
            vmk_out = []
            for vmk in vmk_list:
                raw_ip_list = vmk.get("ipList", "")
                ip_list = raw_ip_list if isinstance(raw_ip_list, list) else [
                    ip.strip() for ip in str(raw_ip_list).split(",") if ip.strip()
                ]
                try:
                    vmk_vlan_id = int(vmk.get("vlanId", 0))
                except (TypeError, ValueError):
                    vmk_vlan_id = 0
                vmk_obj = {
                    "service": vmk.get("service", ""),
                    "vlanId": vmk_vlan_id,
                    "netmask": vmk.get("netmask", ""),
                    "ipList": ip_list,
                }
                gw = vmk.get("gateway", "").strip()
                if gw:
                    vmk_obj["gateway"] = gw
                vmk_out.append(vmk_obj)
            networking_obj["networkingVmKernelInterfaces"] = vmk_out

        cluster_obj["networking"] = networking_obj

        # Per-cluster supervisor services overrides.
        cl_svcs = cluster.get("supervisorServices", {})
        cl_svcs_obj = {}
        _add_optional_str(cl_svcs_obj, cl_svcs, "parentDirectory")
        _add_optional_str(cl_svcs_obj, cl_svcs, "argoCdOperatorYamlFileName")
        _add_optional_str(cl_svcs_obj, cl_svcs, "argoCdDeploymentYamlFileName")
        _add_optional_str(cl_svcs_obj, cl_svcs, "harborDataTemplateYamlFileName")
        _add_optional_str(cl_svcs_obj, cl_svcs, "harborServiceYamlFileName")
        _add_optional_bool(cl_svcs_obj, cl_svcs, "disableArgoCD")
        _add_optional_bool(cl_svcs_obj, cl_svcs, "disableHarbor")
        if cl_svcs_obj:
            cluster_obj["supervisorServices"] = cl_svcs_obj

        clusters_out.append(cluster_obj)

    return {"common": common_obj, "clusters": clusters_out}


def build_supervisor(data):
    """Builds a clean supervisor dict from the validated form data dict."""
    common_spec = data.get("commonSupervisorSpec", {})

    try:
        cp_vm_count = int(common_spec.get("controlPlaneVMCount", 1))
    except (TypeError, ValueError):
        cp_vm_count = 1

    common_obj = {
        "controlPlaneVMCount": cp_vm_count,
        "controlPlaneSize": common_spec.get("controlPlaneSize", "SMALL"),
        "flbAvailability": common_spec.get("flbAvailability", "SINGLE_NODE"),
        "flbSize": common_spec.get("flbSize", "MEDIUM"),
        "flbNetworkType": common_spec.get("flbNetworkType", "DVPG"),
        "networkSearchDomains": _to_str_list(common_spec.get("networkSearchDomains", "")),
        "networkNtpServers": _to_str_list(common_spec.get("networkNtpServers", "")),
        "dnsServers": _to_str_list(common_spec.get("dnsServers", "")),
    }

    sites_out = []
    for site in _iget(data, "siteSpec", []):
        flb = _iget(site, "foundationLoadBalancerComponents", {})
        flb_mgmt = _iget(flb, "flbManagementNetwork", {})
        flb_vsn = _iget(flb, "flbVirtualServerNetwork", {})

        flb_mgmt_obj = {
            "flbNetworkName": _iget(flb_mgmt, "flbNetworkName", ""),
            "flbNetworkIpAddressStartingIp": _iget(flb_mgmt, "flbNetworkIpAddressStartingIp", ""),
            "flbNetworkIpAddressCount": _safe_int(_iget(flb_mgmt, "flbNetworkIpAddressCount", 0)),
        }
        gw_mgmt = (_iget(flb_mgmt, "flbNetworkGateway", "") or "").strip()
        if gw_mgmt:
            flb_mgmt_obj["flbNetworkGateway"] = gw_mgmt

        flb_vsn_obj = {
            "flbNetworkName": _iget(flb_vsn, "flbNetworkName", ""),
            "flbNetworkIpAddressStartingIp": _iget(flb_vsn, "flbNetworkIpAddressStartingIp", ""),
            "flbNetworkIpAddressCount": _safe_int(_iget(flb_vsn, "flbNetworkIpAddressCount", 0)),
        }
        gw_vsn = (_iget(flb_vsn, "flbNetworkGateway", "") or "").strip()
        if gw_vsn:
            flb_vsn_obj["flbNetworkGateway"] = gw_vsn

        mgmt_spec = _iget(site, "mgmtNetworkSpec", {})
        pwn_spec = _iget(site, "primaryWorkloadNetwork", {})

        site_obj = {
            "edgeSite": _iget(site, "edgeSite", ""),
            "foundationLoadBalancerComponents": {
                "flbName": _iget(flb, "flbName", ""),
                "flbVipStartIP": _iget(flb, "flbVipStartIP", ""),
                "flbVipIPCount": _safe_int(_iget(flb, "flbVipIPCount", 0)),
                "flbManagementNetwork": flb_mgmt_obj,
                "flbVirtualServerNetwork": flb_vsn_obj,
            },
            "mgmtNetworkSpec": {
                "mgmtNetworkName": _iget(mgmt_spec, "mgmtNetworkName", ""),
                "mgmtNetworkStartingIp": _iget(mgmt_spec, "mgmtNetworkStartingIp", ""),
                "mgmtNetworkIPCount": _safe_int(_iget(mgmt_spec, "mgmtNetworkIPCount", 0)),
            },
            "primaryWorkloadNetwork": {
                "primaryWorkloadNetworkName": _iget(pwn_spec, "primaryWorkloadNetworkName", ""),
                "primaryWorkloadNetworkStartingIp": _iget(pwn_spec, "primaryWorkloadNetworkStartingIp", ""),
                "primaryWorkloadNetworkIPCount": _safe_int(_iget(pwn_spec, "primaryWorkloadNetworkIPCount", 0)),
                "workloadServiceStartIp": _iget(pwn_spec, "workloadServiceStartIp", ""),
                "workloadServiceCount": _safe_int(_iget(pwn_spec, "workloadServiceCount", 256), default=256),
            },
        }
        sites_out.append(site_obj)

    return {"commonSupervisorSpec": common_obj, "siteSpec": sites_out}


# ---------------------------------------------------------------------------
# Embedded HTML/JS/CSS single-page application
# ---------------------------------------------------------------------------

HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VCF Edge at Scale JSON Generator</title>
<style>
  :root {
    --bg: #1a1d23;
    --surface: #22262f;
    --surface2: #2a2f3a;
    --border: #3a4050;
    --accent: #00b4d8;
    --accent-dark: #0096c7;
    --success: #2ec27e;
    --error: #e05353;
    --warning: #f0a500;
    --text: #e8eaf0;
    --text-muted: #8892a4;
    --radius: 8px;
    --shadow: 0 4px 16px rgba(0,0,0,0.4);
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: 'Segoe UI', system-ui, sans-serif; font-size: 14px; line-height: 1.6; }
  header { background: var(--surface); border-bottom: 1px solid var(--border); padding: 16px 24px; display: flex; align-items: center; gap: 16px; }
  header h1 { font-size: 20px; font-weight: 600; color: var(--accent); }
  header p { font-size: 12px; color: var(--text-muted); }
  .layout { display: flex; min-height: calc(100vh - 61px); }
  .sidebar { width: 220px; background: var(--surface); border-right: 1px solid var(--border); padding: 24px 0; flex-shrink: 0; }
  .sidebar-step { display: flex; align-items: center; gap: 12px; padding: 12px 20px; cursor: pointer; color: var(--text-muted); border-left: 3px solid transparent; transition: all 0.15s; font-size: 13px; }
  .sidebar-step:hover { background: var(--surface2); color: var(--text); }
  .sidebar-step.active { border-left-color: var(--accent); color: var(--accent); background: var(--surface2); font-weight: 600; }
  .sidebar-step.done .step-num { background: var(--success); }
  .step-num { width: 24px; height: 24px; border-radius: 50%; background: var(--border); display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 700; flex-shrink: 0; }
  .active .step-num { background: var(--accent); color: #fff; }
  .main { flex: 1; padding: 32px; overflow-y: auto; max-width: 1000px; }
  .step-panel { display: none; }
  .step-panel.active { display: block; }
  h2 { font-size: 22px; font-weight: 700; margin-bottom: 6px; }
  .subtitle { color: var(--text-muted); font-size: 13px; margin-bottom: 28px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 24px; margin-bottom: 20px; }
  .card-header { font-size: 15px; font-weight: 600; margin-bottom: 18px; padding-bottom: 10px; border-bottom: 1px solid var(--border); display: flex; align-items: center; justify-content: space-between; }
  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  .grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 12px; }
  .field { display: flex; flex-direction: column; gap: 5px; }
  .field label { font-size: 12px; font-weight: 600; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.04em; }
  .field label .req { color: var(--error); margin-left: 2px; }
  .field label .tip { color: var(--text-muted); font-weight: 400; text-transform: none; font-size: 11px; margin-left: 4px; letter-spacing: 0; }
  .tt { position: relative; display: inline-flex; align-items: center; margin-left: 5px; cursor: help; }
  .tt-icon { display: inline-flex; align-items: center; justify-content: center; width: 14px; height: 14px; border-radius: 50%; background: var(--border); color: var(--text-muted); font-size: 9px; font-weight: 700; line-height: 1; text-transform: none; letter-spacing: 0; font-style: normal; }
  .tt-icon:hover { background: var(--accent); color: #fff; }
  .tt .tt-body { visibility: hidden; opacity: 0; position: absolute; bottom: calc(100% + 6px); left: 50%; transform: translateX(-50%); width: 240px; background: #0d1117; border: 1px solid var(--border); border-radius: 6px; padding: 8px 10px; font-size: 11px; font-weight: 400; color: var(--text); text-transform: none; letter-spacing: 0; line-height: 1.5; z-index: 100; pointer-events: none; transition: opacity 0.15s; white-space: normal; box-shadow: var(--shadow); }
  .tt .tt-body::after { content: ''; position: absolute; top: 100%; left: 50%; transform: translateX(-50%); border: 5px solid transparent; border-top-color: var(--border); }
  .tt:hover .tt-body, .tt:focus-within .tt-body { visibility: visible; opacity: 1; }
  input, select, textarea { background: var(--surface2); border: 1px solid var(--border); color: var(--text); border-radius: 6px; padding: 8px 12px; font-size: 13px; width: 100%; outline: none; transition: border-color 0.15s; font-family: inherit; }
  input:focus, select:focus, textarea:focus { border-color: var(--accent); }
  input.invalid, select.invalid { border-color: var(--error) !important; }
  textarea { resize: vertical; min-height: 60px; }
  .field-hint { font-size: 11px; color: var(--text-muted); }
  .field-error { font-size: 11px; color: var(--error); display: none; }
  .inline-row { display: flex; gap: 12px; align-items: flex-end; }
  .inline-row .field { flex: 1; }
  .btn { padding: 9px 20px; border-radius: 6px; border: none; font-size: 13px; font-weight: 600; cursor: pointer; transition: all 0.15s; display: inline-flex; align-items: center; gap: 8px; }
  .btn-primary { background: var(--accent); color: #fff; }
  .btn-primary:hover { background: var(--accent-dark); }
  .btn-secondary { background: var(--surface2); color: var(--text); border: 1px solid var(--border); }
  .btn-secondary:hover { border-color: var(--accent); color: var(--accent); }
  .btn-danger { background: transparent; color: var(--error); border: 1px solid var(--error); padding: 5px 12px; font-size: 12px; }
  .btn-danger:hover { background: var(--error); color: #fff; }
  .btn-success { background: var(--success); color: #fff; }
  .btn-success:hover { filter: brightness(1.1); }
  .btn-reset { background: transparent; color: var(--text-muted); border: 1px solid var(--border); padding: 2px 10px; font-size: 11px; font-weight: 600; margin-left: auto; }
  .btn-reset:hover { color: var(--warning); border-color: var(--warning); }
  .btn:disabled { opacity: 0.4; cursor: not-allowed; }
  .nav-row { display: flex; justify-content: space-between; margin-top: 28px; }
  .segment-item, .vmk-item, .site-block { background: var(--surface2); border: 1px solid var(--border); border-radius: var(--radius); padding: 16px; margin-bottom: 12px; }
  .item-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; font-size: 13px; font-weight: 600; }
  .site-collapse-arrow { display:inline-block; transition: transform 0.2s; font-size:11px; margin-right:6px; color:var(--text-muted); }
  .site-block.is-collapsed .item-header { margin-bottom: 0; }
  .site-block.is-collapsed .site-collapse-arrow { transform: rotate(-90deg); }
  .badge { background: var(--accent); color: #fff; font-size: 11px; padding: 2px 8px; border-radius: 20px; }
  .badge-muted { background: var(--border); color: var(--text-muted); }
  .errors-box { background: #2a1a1a; border: 1px solid var(--error); border-radius: var(--radius); padding: 16px; margin-bottom: 20px; }
  .errors-box h3 { color: var(--error); font-size: 14px; margin-bottom: 10px; }
  .errors-box ul { padding-left: 18px; }
  .errors-box li { color: #ff8a8a; font-size: 12px; margin-bottom: 4px; }
  .success-box { background: #1a2a1e; border: 1px solid var(--success); border-radius: var(--radius); padding: 16px; margin-bottom: 20px; text-align: center; }
  .success-box h3 { color: var(--success); font-size: 16px; margin-bottom: 8px; }
  .success-box p { color: var(--text-muted); font-size: 13px; }
  .toggle-row { display: flex; align-items: center; gap: 10px; cursor: pointer; }
  .toggle-row input[type="checkbox"] { width: 16px; height: 16px; cursor: pointer; accent-color: var(--accent); }
  .toggle-row label { font-size: 13px; cursor: pointer; }
  .collapsible-content { overflow: hidden; transition: max-height 0.3s ease; }
  .collapsible-content.collapsed { display: none; }
  .section-toggle { color: var(--accent); font-size: 12px; cursor: pointer; font-weight: 400; }
  .tag-row { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 4px; }
  .tag { background: var(--surface2); border: 1px solid var(--border); border-radius: 4px; padding: 2px 8px; font-size: 12px; display: flex; align-items: center; gap: 4px; }
  .tag-remove { cursor: pointer; color: var(--text-muted); }
  .tag-remove:hover { color: var(--error); }
  .spinner { display: inline-block; width: 14px; height: 14px; border: 2px solid rgba(255,255,255,0.3); border-top-color: #fff; border-radius: 50%; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .json-preview { background: #0d1117; border: 1px solid var(--border); border-radius: var(--radius); padding: 16px; font-family: 'Consolas', 'Monaco', monospace; font-size: 12px; color: #c9d1d9; white-space: pre; overflow-x: auto; max-height: 400px; overflow-y: auto; }
  .tabs { display: flex; gap: 2px; margin-bottom: 12px; }
  .tab { padding: 7px 16px; border-radius: 6px 6px 0 0; font-size: 13px; cursor: pointer; background: var(--surface2); color: var(--text-muted); border: 1px solid var(--border); border-bottom: none; }
  .tab.active { background: #0d1117; color: var(--accent); font-weight: 600; }
  hr { border: none; border-top: 1px solid var(--border); margin: 20px 0; }
  .logo-badge { background: var(--accent); color: #fff; font-size: 11px; font-weight: 700; padding: 3px 10px; border-radius: 20px; }
  select option { background: var(--surface2); }
  .readonly-note { font-size: 11px; color: var(--text-muted); font-style: italic; margin-top: 4px; }
  .step-console { background: #0d1117; border: 1px solid var(--border); border-radius: var(--radius); padding: 12px 16px; margin-top: 16px; font-family: 'Consolas', 'Monaco', monospace; font-size: 12px; max-height: 220px; overflow-y: auto; display: none; }
  .step-console.visible { display: block; }
  .step-console .line-error { color: #ff6b6b; }
  .step-console .line-warning { color: #f0c040; }
  .step-console .line-info { color: #6bddaa; }
  .step-console .line-plain { color: #c9d1d9; }
  .next-btn-wrap { display: flex; flex-direction: column; align-items: flex-end; gap: 8px; }
  #undoToast { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%); background: var(--surface2); border: 1px solid var(--border); border-radius: 8px; padding: 10px 18px; display: flex; align-items: center; gap: 12px; font-size: 13px; box-shadow: var(--shadow); z-index: 9999; opacity: 0; transition: opacity 0.2s; pointer-events: none; }
  #undoToast.visible { opacity: 1; pointer-events: auto; }
  #undoToast button { padding: 4px 14px; border-radius: 5px; border: 1px solid var(--accent); background: transparent; color: var(--accent); font-size: 12px; font-weight: 700; cursor: pointer; }
  #undoToast button:hover { background: var(--accent); color: #fff; }
  #undoDepth { font-size: 11px; color: var(--text-muted); margin-left: 2px; }
  #checkpointBar { position: fixed; bottom: 0; left: 0; right: 0; background: var(--surface); border-top: 1px solid var(--border); padding: 7px 24px; display: none; align-items: center; gap: 12px; font-size: 12px; color: var(--text-muted); z-index: 9998; }
  #checkpointBar.visible { display: flex; }
  #checkpointBar button { padding: 3px 12px; border-radius: 5px; border: 1px solid var(--warning); background: transparent; color: var(--warning); font-size: 12px; font-weight: 700; cursor: pointer; }
  #checkpointBar button:hover { background: var(--warning); color: #1a1d23; }
  #cloneModal { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.55); z-index: 1000; align-items: center; justify-content: center; }
  #cloneModal.visible { display: flex; }
  #cloneModalBox { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 28px 32px; width: 420px; max-width: 95vw; box-shadow: var(--shadow); }
  #cloneModalBox h3 { margin: 0 0 6px; font-size: 16px; font-weight: 600; color: var(--text); }
  #cloneModalBox p { margin: 0 0 18px; font-size: 13px; color: var(--text-muted); }
  #cloneModalBox label { display: block; font-size: 12px; font-weight: 600; margin-bottom: 6px; color: var(--text-muted); text-transform: uppercase; letter-spacing: .04em; }
  #cloneName { font-size: 14px; font-family: 'Consolas','Monaco',monospace; }
  #cloneNameHint { display: block; min-height: 18px; font-size: 11px; margin-top: 5px; }
  #cloneModalActions { display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px; }
  #siteRemapModal { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.65); z-index: 1100; align-items: center; justify-content: center; }
  #siteRemapModal.visible { display: flex; }
  #siteRemapModalBox { background: var(--surface); border: 1px solid var(--warning); border-radius: var(--radius); padding: 28px 32px; width: 540px; max-width: 96vw; max-height: 80vh; overflow-y: auto; box-shadow: var(--shadow); }
  #siteRemapModalBox h3 { margin: 0 0 6px; font-size: 16px; font-weight: 600; color: var(--warning); }
  #siteRemapModalBox p { margin: 0 0 18px; font-size: 13px; color: var(--text-muted); }
  .remap-row { display: grid; grid-template-columns: 1fr 20px 1fr; align-items: center; gap: 10px; margin-bottom: 12px; }
  .remap-sup { font-family: monospace; font-size: 12px; padding: 6px 10px; background: var(--surface2); border: 1px solid var(--warning); border-radius: 4px; color: var(--warning); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .remap-arrow { text-align: center; color: var(--text-muted); font-size: 14px; }
  #siteRemapModalActions { display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px; border-top: 1px solid var(--border); padding-top: 16px; }
  .remap-infra-note { font-family: monospace; font-size: 12px; padding: 6px 10px; background: var(--surface2); border: 1px solid var(--border); border-radius: 4px; margin-bottom: 8px; color: var(--text-muted); }
  #architectureDiagram svg { display: block; max-width: 100%; height: auto; }
  #archDiagramDetails summary { user-select: none; }
  .nic-chip { display: inline-flex; align-items: center; gap: 5px; background: var(--surface); border: 1px solid var(--accent); color: var(--text); border-radius: 4px; padding: 2px 8px; font-size: 12px; font-family: 'Consolas','Monaco',monospace; }
  .nic-chip-remove { cursor: pointer; color: var(--text-muted); font-size: 14px; line-height: 1; margin-left: 2px; }
  .nic-chip-remove:hover { color: var(--error); }
  .nic-count-ok  { color: var(--success); }
  .nic-count-bad { color: var(--error); }
  .conn-results { margin-top: 10px; display: flex; flex-direction: column; gap: 5px; }
  .conn-row { display: flex; align-items: center; gap: 8px; font-size: 12px; font-family: 'Consolas', 'Monaco', monospace; }
  .conn-badge { display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 700; white-space: nowrap; }
  .conn-ok   { background: rgba(46,194,126,0.15); border: 1px solid var(--success); color: var(--success); }
  .conn-fail { background: rgba(224,83,83,0.15);  border: 1px solid var(--error);   color: var(--error); }
  .conn-spin { background: rgba(136,146,164,0.15); border: 1px solid var(--text-muted); color: var(--text-muted); }
</style>
</head>
<body>
<header>
  <div>
    <h1>VCF Edge at Scale JSON Generator</h1>
    <p>Generate and validate infrastructure.json and supervisor.json for deployment</p>
  </div>
  <div style="display:flex;align-items:center;gap:12px;">
    <a id="readmeLink" href="#" target="_blank"
       style="display:inline-flex;align-items:center;gap:6px;padding:6px 12px;border-radius:6px;background:rgba(0,180,216,0.1);border:1px solid rgba(0,180,216,0.3);color:var(--accent);font-size:12px;font-weight:600;text-decoration:none;transition:all 0.15s;"
       onmouseover="this.style.background='rgba(0,180,216,0.2)';this.style.borderColor='var(--accent)'"
       onmouseout="this.style.background='rgba(0,180,216,0.1)';this.style.borderColor='rgba(0,180,216,0.3)'"
       title="Open the VCF Edge at Scale README for deployment guidance and field reference">
      📖 <span>Help &amp; Documentation</span>
    </a>
    <span id="versionBadge" style="font-size:11px;color:var(--text-muted);font-family:monospace;">v…</span>
  </div>
</header>
<div class="layout">
  <nav class="sidebar">
    <div class="sidebar-step active" data-step="1" onclick="goToStep(1)">
      <span class="step-num">1</span><span>Common Settings</span>
    </div>
    <div class="sidebar-step" data-step="2" onclick="goToStep(2)">
      <span class="step-num">2</span><span>Edge Sites</span>
    </div>
    <div class="sidebar-step" data-step="3" onclick="goToStep(3)">
      <span class="step-num">3</span><span>Supervisor Config</span>
    </div>
    <div class="sidebar-step" data-step="4" onclick="goToStep(4)">
      <span class="step-num">4</span><span>Review &amp; Download</span>
    </div>
  </nav>

  <main class="main">

    <!-- STEP 1: Common Settings -->
    <div class="step-panel active" id="step1">
      <h2>Common Settings</h2>
      <p class="subtitle">These settings apply globally across all clusters. Fields marked <span style="color:var(--error)">*</span> are required.</p>
      <div class="card" style="padding:16px;margin-bottom:20px;">
        <div style="font-size:13px;font-weight:600;margin-bottom:12px;">Load existing configuration</div>
        <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;">
          <button class="btn btn-secondary" onclick="loadFromDefault()" id="loadDefaultBtn">
            📂 Load from default directory
          </button>
          <div style="display:flex;gap:8px;align-items:center;">
            <input type="text" id="customLoadPath" placeholder="Custom path…" style="width:320px;">
            <button class="btn btn-secondary" onclick="loadFromCustom()" id="loadCustomBtn">Load</button>
          </div>
        </div>
        <div id="loadTemplateStatus" style="margin-top:8px;font-size:12px;color:var(--text-muted);min-height:16px;"></div>
        <div id="defaultDirHint" style="margin-top:4px;font-size:11px;color:var(--text-muted);"></div>
      </div>

      <div class="card">
        <div class="card-header">vCenter Connection <span id="resetBtn-vcenter"></span></div>
        <div class="grid-2">
          <div class="field">
            <label>vCenter FQDN <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">Must be a valid FQDN or IPv4 address of a vCenter 9.0+ server. The script requires HTTPS (port 443) access to this host.</span></span></label>
            <div style="display:flex;gap:8px;align-items:center;">
              <input type="text" id="vCenterName" placeholder="vc01.example.com" style="flex:1;">
              <button class="btn btn-secondary" style="white-space:nowrap;font-size:12px;padding:6px 12px;" onclick="checkVcenterConnectivity()" title="Test HTTPS connectivity to this vCenter (port 443). Certificate errors are ignored.">⚡ Check</button>
            </div>
            <span class="field-hint">vCenter 9.0+ FQDN; script needs HTTPS access.</span>
            <div id="vcenterConnResult" class="conn-results"></div>
          </div>
          <div class="field">
            <label>vCenter User <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">vCenter login in the format user@domain or plain username. Allowed characters: letters, digits, . _ @ - (max 256 chars). Example: administrator@vsphere.local</span></span></label>
            <input type="text" id="vCenterUser" placeholder="administrator@vsphere.local">
          </div>
          <div class="field">
            <label>Datacenter Name <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">Name of an existing vSphere datacenter (1–80 chars, letters, digits, spaces, _ + - ()). The datacenter must already exist in vCenter before deployment.</span></span></label>
            <input type="text" id="datacenterName" placeholder="dc01">
            <span class="field-hint">Existing vSphere datacenter; clusters created under it.</span>
          </div>
          <div class="field">
            <label>Context Name <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">VCF CLI context name used by all supervisor services (ArgoCD and Harbor). Lowercase RFC1123: alphanumeric and hyphens, 1–80 characters. Required unless all clusters disable all supervisor services.</span></span></label>
            <input type="text" id="contextName" placeholder="vcf-context-01">
            <span class="field-hint">VCF CLI context name; required for supervisor services (ArgoCD and Harbor).</span>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-header">NIC List <span style="font-size:12px;font-weight:400;color:var(--text-muted)">(required at common or per-cluster level)</span> <span id="resetBtn-niclist"></span></div>
        <div class="field">
          <label>NIC Pairs <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">Physical NIC names on each ESX host. NICs must be added in pairs (2 or 4 total). Enter both NICs of a pair and click "+ Add Pair".</span></span></label>
          <input type="hidden" id="nicList">
          <div id="nicChips" style="display:flex;flex-wrap:wrap;gap:8px;min-height:40px;padding:8px 10px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;align-items:center;">
            <span style="color:var(--text-muted);font-size:13px;">No NICs added yet</span>
          </div>
          <div style="display:flex;gap:8px;margin-top:8px;align-items:flex-end;">
            <div class="field" style="flex:1;gap:4px;">
              <label style="font-size:11px;">NIC A</label>
              <input type="text" id="nicInputA" placeholder="vmnic0" style="font-size:13px;" onkeydown="if(event.key==='Enter'){event.preventDefault();document.getElementById('nicInputB').focus();}">
            </div>
            <div class="field" style="flex:1;gap:4px;">
              <label style="font-size:11px;">NIC B</label>
              <input type="text" id="nicInputB" placeholder="vmnic1" style="font-size:13px;" onkeydown="if(event.key==='Enter'){event.preventDefault();addNicPair();}">
            </div>
            <button class="btn btn-secondary" style="padding:8px 16px;font-size:13px;white-space:nowrap;" onclick="addNicPair()">+ Add Pair</button>
          </div>
          <span class="field-hint" id="nicCountHint">Must be exactly 2 or 4 NICs (1 or 2 pairs).</span>
        </div>
      </div>

      <div class="card">
        <div class="card-header">Optional Common Settings <span class="section-toggle" onclick="toggleSection('optCommon')">[expand]</span> <span id="resetBtn-optcommon"></span></div>
        <div id="optCommon" class="collapsible-content collapsed">
          <div class="grid-2">
            <div class="field">
              <label>ESX User <span class="tip">default: root</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">Login username for ESX hosts. Defaults to root if omitted.</span></span></label>
              <input type="text" id="esxUser" placeholder="root">
            </div>
            <div class="field">
              <label>vSAN Witness VM Name<span class="tt"><span class="tt-icon">?</span><span class="tt-body">FQDN or IPv4 of the vSAN witness appliance. Required for vSAN-OSA and vSAN-ESA clusters. Can be set here (common) or overridden per cluster.</span></span></label>
              <input type="text" id="vSanWitnessVmName" placeholder="vsanwitness.example.com">
              <span class="field-hint">Overridable per cluster.</span>
            </div>
            <div class="field">
              <label>HA Policy<span class="tt"><span class="tt-icon">?</span><span class="tt-body">vSphere HA admission control policy for multi-host clusters. Default: reservationBased (reserves CPU/memory percentage for failover). slotBased: slot-based host failure tolerance. disabled: HA enabled but admission control off. Single-host clusters always disable admission control regardless of this setting.</span></span></label>
              <select id="haPolicy">
                <option value="reservationBased" selected>reservationBased (default)</option>
                <option value="slotBased">slotBased</option>
                <option value="disabled">disabled</option>
              </select>
            </div>
            <div class="field">
              <label>vLCM Image Name<span class="tt"><span class="tt-icon">?</span><span class="tt-body">Name of the vSphere Lifecycle Manager (vLCM) image to apply to hosts. Leave blank to skip vLCM configuration.</span></span></label>
              <input type="text" id="vLcmImageName" placeholder="autogen-software-spec-1">
            </div>
            <div class="field">
              <label>vSAN/vMotion VMkernel MTU<span class="tt"><span class="tt-icon">?</span><span class="tt-body">MTU for vSAN and vMotion VMkernel adapters. Valid range: 1500–9190. Typically 9000 for jumbo frames. Management and vSAN Witness VMkernels are always 1500.</span></span></label>
              <input type="number" id="vSanvMotionVmKernelMtuValue" placeholder="9000" min="1500" max="9190">
              <span class="field-hint">1500–9190; mgmt and vSAN Witness are always 1500.</span>
            </div>
            <div class="field">
              <label>Cluster Name Prefix<span class="tt"><span class="tt-icon">?</span><span class="tt-body">Prefix for generated vSphere cluster names. Pattern: {prefix}-{edgeSite}. Default: "cluster" → cluster-site1. Allowed: 1–80 chars, letters, digits, spaces, _ + - ().</span></span></label>
              <input type="text" id="clusterNamePrefix" placeholder="cluster">
            </div>
            <div class="field">
              <label>Datastore Name Prefix<span class="tt"><span class="tt-icon">?</span><span class="tt-body">Prefix for generated datastore names. Pattern: {prefix}-{edgeSite}. Default: "datastore" → datastore-site1. Allowed: 1–80 chars, letters, digits, spaces, _ + - ().</span></span></label>
              <input type="text" id="datastoreNamePrefix" placeholder="datastore">
            </div>
            <div class="field">
              <label>Supervisor Name Prefix<span class="tt"><span class="tt-icon">?</span><span class="tt-body">Prefix for generated Supervisor (WCP) names. Pattern: {prefix}-{edgeSite}. Default: "supervisor" → supervisor-site1. Also becomes the Kubernetes StorageClass name (lowercased). Allowed: 1–80 chars, letters, digits, spaces, _ + - ().</span></span></label>
              <input type="text" id="supervisorNamePrefix" placeholder="supervisor">
            </div>
            <div class="field">
              <label>VDS Name Prefix<span class="tt"><span class="tt-icon">?</span><span class="tt-body">Prefix for generated vSphere Distributed Switch names. Pattern: {prefix}-{edgeSite}. Default: "VDS" → VDS-site1. Allowed: 1–80 chars, letters, digits, spaces, _ + - ().</span></span></label>
              <input type="text" id="vdsNamePrefix" placeholder="VDS">
            </div>
            <div class="field">
              <label>Content Library Datastore<span class="tt"><span class="tt-icon">?</span><span class="tt-body">Datastore name to use for the Supervisor content library. When provided, triggers automatic content library initialization during deployment.</span></span></label>
              <input type="text" id="supervisorContentLibraryDatastore" placeholder="">
              <span class="field-hint">When present, triggers content library initialization.</span>
            </div>
          </div>
          <hr>
          <div style="display:flex;flex-direction:column;gap:10px;margin-bottom:16px;">
            <label class="toggle-row"><input type="checkbox" id="esxUniquePasswordPerHost"><label for="esxUniquePasswordPerHost">Unique password per ESX host</label></label>
            <label class="toggle-row"><input type="checkbox" id="nonInteractivePassword"><label for="nonInteractivePassword">Use environment variables for passwords (non-interactive)</label></label>
            <label class="toggle-row"><input type="checkbox" id="autoUpdate" checked><label for="autoUpdate">Auto update <span style="font-size:11px;color:var(--text-muted);font-weight:400;">(checked by default)</span></label></label>
            <label class="toggle-row"><input type="checkbox" id="labenvironment"><label for="labenvironment">Lab environment mode (relaxes vSAN validation and other gates)</label></label>
            <label class="toggle-row"><input type="checkbox" id="preserveAutoGeneratedKeyCertPair"><label for="preserveAutoGeneratedKeyCertPair">Preserve auto-generated Harbor key/cert pair (lab mode only — saves <em>.key</em> and <em>.crt</em> to <code>HarborKeyCerts/&lt;site&gt;/</code> under the deployment root)</label></label>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-header">Supervisor Services (ArgoCD / Harbor) <span class="section-toggle" onclick="toggleSection('svcCommon')">[expand]</span> <span id="resetBtn-svc"></span></div>
        <div id="svcCommon" class="collapsible-content collapsed">
          <div class="grid-2">
            <div class="field">
              <label>Parent Directory</label>
              <input type="text" id="svc_parentDirectory" placeholder="C:\Users\Administrator\Documents\">
              <span class="field-hint">Directory containing ArgoCD and Harbor YAML files.</span>
            </div>
            <div class="field">
              <label>ArgoCD Operator YAML Filename</label>
              <input type="text" id="svc_argoCdOperatorYamlFileName" placeholder="1.1.0-25100889.yml">
            </div>
            <div class="field">
              <label>ArgoCD Deployment YAML Filename</label>
              <input type="text" id="svc_argoCdDeploymentYamlFileName" placeholder="argocd-deployment.yml">
            </div>
            <div class="field">
              <label>Harbor Data Template YAML Filename</label>
              <input type="text" id="svc_harborDataTemplateYamlFileName" placeholder="harbor-data-values-v2.14.2.yml">
            </div>
            <div class="field">
              <label>Harbor Service YAML Filename</label>
              <input type="text" id="svc_harborServiceYamlFileName" placeholder="legacy-harbor-svs-v2.14.2+vmware.2-vks.1-25220498.yml">
            </div>
          </div>
          <div style="display:flex;gap:24px;margin-top:12px;">
            <label class="toggle-row"><input type="checkbox" id="svc_disableArgoCD"><label for="svc_disableArgoCD">Disable ArgoCD for all clusters</label></label>
            <label class="toggle-row"><input type="checkbox" id="svc_disableHarbor"><label for="svc_disableHarbor">Disable Harbor for all clusters</label></label>
          </div>
        </div>
      </div>

      <div class="nav-row">
        <div></div>
        <div class="next-btn-wrap">
          <button class="btn btn-primary" onclick="goToStepValidated(1, 2)" id="next1Btn">Next: Edge Sites →</button>
        </div>
      </div>
      <div class="step-console" id="console1"></div>
    </div>

    <!-- STEP 2: Edge Sites -->
    <div class="step-panel" id="step2">
      <h2>Edge Sites</h2>
      <p class="subtitle">Add one site per cluster. Each <strong>edgeSite</strong> name must be unique and will be referenced in the Supervisor config.</p>
      <div id="sitesContainer"></div>
      <button class="btn btn-secondary" onclick="addSite()" style="margin-bottom:20px;">+ Add Site</button>

      <div class="nav-row">
        <button class="btn btn-secondary" onclick="goToStep(1)">← Back</button>
        <div style="display:flex;gap:10px;align-items:center;">
          <button class="btn btn-secondary" style="font-size:12px;" onclick="checkEsxConnectivity()" title="Test HTTPS connectivity to all ESX hosts across all sites (port 443). Certificate errors are ignored.">⚡ Check ESX Connectivity</button>
          <button class="btn btn-primary" onclick="goToStepValidated(2, 3)" id="next2Btn">Next: Supervisor Config →</button>
        </div>
      </div>
      <div id="esxConnResults" class="conn-results" style="margin-top:12px;"></div>
      <div class="step-console" id="console2"></div>
    </div>

    <!-- STEP 3: Supervisor Config -->
    <div class="step-panel" id="step3">
      <h2>Supervisor Configuration</h2>
      <p class="subtitle">Define the supervisor control plane and per-site networking. Network names are populated from your site definitions above.</p>

      <div class="card">
        <div class="card-header">Common Supervisor Spec <span id="resetBtn-supcommon"></span></div>
        <div class="grid-2">
          <div class="field">
            <label>Control Plane VM Count <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">Number of Supervisor control plane VMs. 1 = single-node (no HA); 3 = HA mode with a quorum of 3 VMs.</span></span></label>
            <select id="controlPlaneVMCount">
              <option value="1">1 (single node)</option>
              <option value="3">3 (HA)</option>
            </select>
          </div>
          <div class="field">
            <label>Control Plane Size <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">VM size for Supervisor control plane nodes. Valid values: TINY, SMALL, MEDIUM, LARGE. Determines CPU and memory allocation.</span></span></label>
            <select id="controlPlaneSize">
              <option value="TINY">TINY</option>
              <option value="SMALL" selected>SMALL</option>
              <option value="MEDIUM">MEDIUM</option>
              <option value="LARGE">LARGE</option>
            </select>
          </div>
          <div class="field">
            <label>FLB Availability <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">Foundation Load Balancer deployment mode. SINGLE_NODE: one FLB instance. ACTIVE_PASSIVE: two instances for redundancy.</span></span></label>
            <select id="flbAvailability">
              <option value="SINGLE_NODE" selected>SINGLE_NODE</option>
              <option value="ACTIVE_PASSIVE">ACTIVE_PASSIVE</option>
            </select>
          </div>
          <div class="field">
            <label>FLB Size <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">VM size for Foundation Load Balancer instances. Valid values: SMALL, MEDIUM, LARGE, X-LARGE.</span></span></label>
            <select id="flbSize">
              <option value="SMALL">SMALL</option>
              <option value="MEDIUM" selected>MEDIUM</option>
              <option value="LARGE">LARGE</option>
              <option value="X-LARGE">X-LARGE</option>
            </select>
          </div>
          <div class="field">
            <label>FLB Network Type<span class="tt"><span class="tt-icon">?</span><span class="tt-body">Network type for the FLB. Only DVPG (vSphere Distributed Port Group) is supported.</span></span></label>
            <input type="hidden" id="flbNetworkType" value="DVPG">
            <div style="padding:8px 12px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;font-size:13px;color:var(--text-muted);display:flex;align-items:center;gap:8px;">
              <span style="font-family:'Consolas','Monaco',monospace;color:var(--text);">DVPG</span>
              <span style="font-size:11px;">(vSphere Distributed Port Group — only supported type)</span>
            </div>
          </div>
        </div>
        <hr>
        <div class="grid-3">
          <div class="field">
            <label>DNS Servers <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">IPv4 addresses of DNS servers for the Supervisor. Maximum 3 entries, each a valid IPv4 address.</span></span></label>
            <input type="hidden" id="dnsServers">
            <div id="dnsChips" style="display:flex;flex-wrap:wrap;gap:6px;min-height:34px;padding:6px 10px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;align-items:center;">
              <span style="color:var(--text-muted);font-size:13px;">No DNS servers added</span>
            </div>
            <div style="display:flex;gap:6px;margin-top:6px;">
              <input type="text" id="dnsInput" placeholder="10.0.0.1" style="flex:1;font-size:13px;" onkeydown="if(event.key==='Enter'){event.preventDefault();addDns();}">
              <button class="btn btn-secondary" style="padding:6px 12px;font-size:13px;white-space:nowrap;" onclick="addDns()">+ Add</button>
            </div>
            <span class="field-hint">Max 3 IPv4 addresses.</span>
          </div>
          <div class="field">
            <label>NTP Servers <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">IPv4 addresses or FQDNs of NTP servers for the Supervisor. At least one entry required.</span></span></label>
            <input type="hidden" id="networkNtpServers">
            <div id="ntpChips" style="display:flex;flex-wrap:wrap;gap:6px;min-height:34px;padding:6px 10px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;align-items:center;">
              <span style="color:var(--text-muted);font-size:13px;">No NTP servers added</span>
            </div>
            <div style="display:flex;gap:6px;margin-top:6px;">
              <input type="text" id="ntpInput" placeholder="10.0.0.20" style="flex:1;font-size:13px;" onkeydown="if(event.key==='Enter'){event.preventDefault();addNtp();}">
              <button class="btn btn-secondary" style="padding:6px 12px;font-size:13px;white-space:nowrap;" onclick="addNtp()">+ Add</button>
            </div>
            <span class="field-hint">At least 1 required.</span>
          </div>
          <div class="field">
            <label>Search Domains <span class="req">*</span><span class="tt"><span class="tt-icon">?</span><span class="tt-body">DNS search domains for the Supervisor (e.g. example.com, corp.local). At least one entry required.</span></span></label>
            <input type="hidden" id="networkSearchDomains">
            <div id="searchChips" style="display:flex;flex-wrap:wrap;gap:6px;min-height:34px;padding:6px 10px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;align-items:center;">
              <span style="color:var(--text-muted);font-size:13px;">No search domains added</span>
            </div>
            <div style="display:flex;gap:6px;margin-top:6px;">
              <input type="text" id="searchInput" placeholder="example.com" style="flex:1;font-size:13px;" onkeydown="if(event.key==='Enter'){event.preventDefault();addSearch();}">
              <button class="btn btn-secondary" style="padding:6px 12px;font-size:13px;white-space:nowrap;" onclick="addSearch()">+ Add</button>
            </div>
            <span class="field-hint">At least 1 required.</span>
          </div>
        </div>
      </div>

      <div style="background:rgba(0,180,216,0.07);border:1px solid rgba(0,180,216,0.3);border-radius:8px;padding:14px 18px;margin:0 0 16px;font-size:13px;line-height:1.7;color:var(--text);">
        <div style="font-weight:700;margin-bottom:6px;color:var(--accent);">ℹ How supervisor sites link to infrastructure sites</div>
        <ul style="margin:0;padding-left:18px;color:var(--text-muted);">
          <li>Each site block below corresponds to a cluster defined in <strong>Edge Sites</strong>, matched by its <strong>Edge Site ID</strong>. The PowerShell module joins the two config files on this field — every site must appear in <em>both</em> files with exactly the same name.</li>
          <li>The <strong>network name dropdowns</strong> are pre-populated with segments you defined for that site in Edge Sites. The module performs a <strong>case-sensitive</strong> name lookup when wiring each supervisor network to a vSphere Distributed Port Group.</li>
          <li><strong>Gateway overrides</strong> are optional — leave blank and the module uses the gateway from the matching infrastructure segment automatically.</li>
          <li>The <strong>Supervisor name</strong> is generated as <code style="font-size:11px;background:var(--surface2);padding:1px 5px;border-radius:3px;">{supervisorNamePrefix}-{edgeSite}</code> and also becomes the Kubernetes StorageClass name (lowercased).</li>
        </ul>
      </div>

      <div id="supervisorSitesContainer"></div>

      <div class="nav-row">
        <button class="btn btn-secondary" onclick="goToStep(2)">← Back</button>
        <div class="next-btn-wrap">
          <button class="btn btn-primary" onclick="goToStepValidated(3, 4)" id="next3Btn">Next: Review &amp; Download →</button>
        </div>
      </div>
      <div class="step-console" id="console3"></div>
    </div>

    <!-- STEP 4: Review & Download -->
    <div class="step-panel" id="step4">
      <h2>Review &amp; Download</h2>
      <p class="subtitle">Validate your configuration and download or save the JSON files.</p>

      <div id="validationResults"></div>
      <div id="changeSummary" style="display:none;margin-bottom:16px;"></div>

      <details id="archDiagramDetails" style="display:none;margin-bottom:16px;">
        <summary style="font-weight:600;font-size:13px;cursor:pointer;padding:4px 0;">Architecture Diagram</summary>
        <div id="architectureDiagram" style="margin-top:10px;overflow-x:auto;"></div>
        <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:8px;">
          <button class="btn btn-secondary" onclick="copySvgDiagram()" style="font-size:12px;padding:5px 14px;">Copy SVG</button>
          <button class="btn btn-secondary" onclick="downloadSvgDiagram()" style="font-size:12px;padding:5px 14px;">Download SVG</button>
          <button class="btn btn-secondary" onclick="downloadPngDiagram(2)" style="font-size:12px;padding:5px 14px;">Download PNG (2×)</button>
          <button class="btn btn-secondary" onclick="downloadPngDiagram(4)" style="font-size:12px;padding:5px 14px;">Download PNG (4×)</button>
        </div>
      </details>

      <div id="saveResult" style="display:none;"></div>

      <div style="display:flex;align-items:flex-end;justify-content:space-between;margin-bottom:0;">
        <div class="tabs" style="margin-bottom:0;">
          <div class="tab active" data-tab="infra" onclick="switchTab('infra')">infrastructure.json</div>
          <div class="tab" data-tab="supervisor" onclick="switchTab('supervisor')">supervisor.json</div>
        </div>
        <button id="copyJsonBtn" class="btn btn-secondary" style="font-size:12px;padding:5px 14px;margin-bottom:0;border-radius:6px 6px 0 0;border-bottom:none;"
          onclick="copyActiveJson()" title="Copy the currently displayed JSON to clipboard">⎘ Copy</button>
      </div>
      <div id="infraPreview" class="json-preview"></div>
      <div id="supervisorPreview" class="json-preview" style="display:none;"></div>

      <div class="nav-row">
        <button class="btn btn-secondary" onclick="goToStep(3)">← Back</button>
        <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;justify-content:flex-end;">
          <button class="btn btn-secondary" onclick="refreshPreview()" id="refreshBtn">↻ Refresh</button>
          <button class="btn btn-primary" onclick="saveToBaseDir()" id="saveBtn" disabled
            title="Write infrastructure.json and supervisor.json to the base directory. Existing files are automatically backed up to the Backup/ subdirectory with a timestamp suffix (e.g. Backup/infrastructure.json.bak-20260507-143000) before any overwrite.">
            💾 Save to Base Dir
          </button>
          <button class="btn btn-success" onclick="downloadZip()" id="downloadBtn" disabled
            title="Download a ZIP containing both JSON files">
            ⬇ Export ZIP
          </button>
        </div>
      </div>
    </div>

  </main>
</div>

<div id="undoToast">
  <span id="undoLabel"></span><span id="undoDepth"></span>
  <button onclick="doUndo()">Undo</button>
  <button onclick="_dismissUndo()" style="border-color:var(--text-muted);color:var(--text-muted);">✕</button>
</div>

<div id="checkpointBar">
  <span>📍 Checkpoint saved when you advanced to the next step.</span>
  <button onclick="_restoreCheckpoint()">Restore checkpoint</button>
  <button onclick="_dismissCheckpoint()" style="border-color:var(--text-muted);color:var(--text-muted);margin-left:auto;">✕</button>
</div>

<div id="cloneModal" role="dialog" aria-modal="true" aria-labelledby="cloneModalTitle">
  <div id="cloneModalBox">
    <h3 id="cloneModalTitle">Clone Site</h3>
    <p>Enter a name for the new site. Segment and supervisor network names will be suffixed with <strong id="cloneSuffixPreview"></strong> to keep them globally unique.</p>
    <label for="cloneName">New site name</label>
    <input type="text" id="cloneName" autocomplete="off" spellcheck="false" oninput="_cloneModalValidate()">
    <span id="cloneNameHint"></span>
    <div id="cloneModalActions">
      <button class="btn btn-secondary" onclick="_cloneModalCancel()">Cancel</button>
      <button class="btn btn-primary" id="cloneModalOk" onclick="_cloneModalConfirm()">Clone</button>
    </div>
  </div>
</div>

<div id="siteRemapModal" role="dialog" aria-modal="true" aria-labelledby="siteRemapModalTitle">
  <div id="siteRemapModalBox">
    <h3 id="siteRemapModalTitle">Site Name Mismatch</h3>
    <p id="siteRemapModalDesc">The supervisor.json site names do not match the infrastructure.json cluster names. Map each supervisor site to an infrastructure cluster, or skip it to discard its supervisor configuration.</p>
    <div id="siteRemapRows"></div>
    <div id="siteRemapModalActions">
      <button class="btn btn-secondary" onclick="_siteRemapCancel()">Cancel</button>
      <button class="btn btn-primary" id="siteRemapOk" onclick="_siteRemapConfirm()">Apply</button>
    </div>
  </div>
</div>

<script>
// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
let sites = [];         // [{edgeSite, esxHosts, storageType, ...}, ...]
let siteCounter = 0;

// Multi-level undo stack — up to _MAX_UNDO entries, newest at the end.
// Each entry: { label, restore } where restore() reverts one action.
const _MAX_UNDO = 10;
let _undoStack = [];
let _undoTimer = null;

// Checkpoint — a full deep-copy of sites[] saved when the user successfully
// advances a wizard step. Allows recovering from bulk accidental deletions.
let _checkpoint = null;
let _checkpointLabel = null;

// Common NIC list — array of strings (e.g. ['vmnic0','vmnic1']).
// This is the authoritative state; the hidden #nicList input is kept in sync.
let commonNics = [];

// Supervisor common lists — each synced to a hidden <input> that buildPayload() reads.
let dnsList = [];
let ntpList = [];
let searchDomainList = [];

// Last successfully loaded JSON snapshot — used by section-level reset buttons.
let _loadedSnapshot = null;

// ---------------------------------------------------------------------------
// NIC pair widget — shared rendering core used by both common and per-site widgets.
// Options object:
//   nics          - flat array of NIC name strings (pairs stored consecutively).
//   containerId   - id of the chip display container element.
//   hintId        - id of the count/hint span element.
//   removeFn      - function(pairIdx) called when a pair's × is clicked.
//   emptyMsg      - text shown when nics is empty.
//   emptyValid    - whether an empty list is considered valid (true for per-site overrides).
// ---------------------------------------------------------------------------
function _renderNicPairChips({ nics, containerId, hintId, removeFn, emptyMsg, emptyValid = false }) {
  const container = document.getElementById(containerId);
  const hint = document.getElementById(hintId);
  if (!container) return;
  const count = nics.length;

  if (count === 0) {
    container.innerHTML = `<span style="color:var(--text-muted);font-size:13px;">${esc(emptyMsg)}</span>`;
  } else {
    let html = '';
    for (let i = 0; i < count; i += 2) {
      const a = nics[i];
      const b = nics[i + 1];
      html += `<span style="display:inline-flex;align-items:center;gap:0;border:1px solid var(--accent);border-radius:5px;overflow:hidden;font-family:'Consolas','Monaco',monospace;font-size:12px;">`;
      html += `<span style="padding:3px 8px;background:rgba(0,180,216,0.08);color:var(--text);">${esc(a)}</span>`;
      if (b !== undefined) {
        html += `<span style="padding:3px 2px;color:var(--text-muted);font-size:10px;">+</span>`;
        html += `<span style="padding:3px 8px;background:rgba(0,180,216,0.08);color:var(--text);">${esc(b)}</span>`;
      }
      html += `<span class="nic-chip-remove" data-pair-idx="${i}" title="Remove pair" style="padding:3px 7px;border-left:1px solid var(--border);cursor:pointer;color:var(--text-muted);">×</span>`;
      html += `</span>`;
    }
    container.innerHTML = html;
    // Attach click handlers after setting innerHTML so closure captures removeCallbackFn.
    container.querySelectorAll('[data-pair-idx]').forEach(el => {
      el.addEventListener('click', () => removeFn(parseInt(el.dataset.pairIdx, 10)));
    });
  }

  if (hint) {
    const valid = (emptyValid && count === 0) || count === 2 || count === 4;
    const pairs = Math.floor(count / 2);
    const odd = count % 2 !== 0;
    const emptyHintText = emptyValid ? 'Leave blank to inherit common nicList.' : 'Must be exactly 2 or 4 NICs (1 or 2 pairs).';
    hint.textContent = count === 0
      ? emptyHintText
      : odd
        ? `${count} NIC(s) — ✗ incomplete pair (need even count)`
        : `${pairs} pair(s), ${count} NICs — ${valid ? '✓ OK' : '✗ must be 1 or 2 pairs (2 or 4 NICs)'}`;
    hint.className = 'field-hint ' + (count === 0 ? '' : (valid && !odd) ? 'nic-count-ok' : 'nic-count-bad');
  }
}

// ---------------------------------------------------------------------------
// NIC pair widget (common level)
// NICs are stored flat in commonNics[] but added/removed in pairs.
// ---------------------------------------------------------------------------

// Briefly shows an error message in a NIC hint span, then restores the original text.
function _flashNicHint(hintId, msg) {
  const hint = document.getElementById(hintId);
  if (!hint) return;
  const prevText = hint.textContent;
  const prevClass = hint.className;
  hint.textContent = msg;
  hint.className = 'field-hint nic-count-bad';
  setTimeout(() => { hint.textContent = prevText; hint.className = prevClass; }, 3000);
}

function _syncNicHidden() {
  document.getElementById('nicList').value = commonNics.join(', ');
}

function _renderNicChips() {
  _renderNicPairChips({
    nics: commonNics,
    containerId: 'nicChips',
    hintId: 'nicCountHint',
    removeFn: removeNicPair,
    emptyMsg: 'No NIC pairs added yet',
  });
  _syncNicHidden();
}

function addNicPair() {
  const a = (document.getElementById('nicInputA').value || '').trim();
  const b = (document.getElementById('nicInputB').value || '').trim();
  if (!a || !b) {
    document.getElementById(!a ? 'nicInputA' : 'nicInputB').focus();
    _flashNicHint('nicCountHint', !a ? 'NIC A name is required.' : 'NIC B name is required.');
    return;
  }
  if (commonNics.length >= 4) {
    _flashNicHint('nicCountHint', 'Maximum of 4 NICs (2 pairs) already added.');
    return;
  }
  if (commonNics.includes(a) || commonNics.includes(b)) {
    _flashNicHint('nicCountHint', 'Duplicate NIC name — each NIC must be unique.');
    return;
  }
  commonNics.push(a, b);
  document.getElementById('nicInputA').value = '';
  document.getElementById('nicInputB').value = '';
  document.getElementById('nicInputA').focus();
  _renderNicChips();
}

// Remove the pair starting at pairIdx (removes two consecutive entries).
function removeNicPair(pairIdx) {
  commonNics.splice(pairIdx, 2);
  _renderNicChips();
}

// Populate from a comma-separated string or array (used by load).
function setNicChipsFromValue(val) {
  if (Array.isArray(val)) {
    commonNics = val.filter(Boolean);
  } else {
    commonNics = String(val || '').split(',').map(s => s.trim()).filter(Boolean);
  }
  _renderNicChips();
}

// ---------------------------------------------------------------------------
// NIC pair widget (per-site level) — delegates to shared _renderNicPairChips.
// State lives in site.nicList (array of strings). Called by renderSites() after
// innerHTML is set so the container elements already exist in the DOM.
// ---------------------------------------------------------------------------
function _renderSiteNicChips(siteId) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const nics = Array.isArray(site.nicList) ? site.nicList : [];
  _renderNicPairChips({
    nics,
    containerId: `nicChips_${siteId}`,
    hintId: `nicCountHint_${siteId}`,
    removeFn: pairIdx => removeSiteNicPair(siteId, pairIdx),
    emptyMsg: 'No override — inheriting common nicList',
    emptyValid: true,
  });
}

function addSiteNicPair(siteId) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const a = (document.getElementById(`nicInputA_${siteId}`).value || '').trim();
  const b = (document.getElementById(`nicInputB_${siteId}`).value || '').trim();
  if (!a || !b) {
    document.getElementById(!a ? `nicInputA_${siteId}` : `nicInputB_${siteId}`).focus();
    _flashNicHint(`nicCountHint_${siteId}`, !a ? 'NIC A name is required.' : 'NIC B name is required.');
    return;
  }
  if (!Array.isArray(site.nicList)) site.nicList = [];
  if (site.nicList.length >= 4) {
    _flashNicHint(`nicCountHint_${siteId}`, 'Maximum of 4 NICs (2 pairs) already added.');
    return;
  }
  if (site.nicList.includes(a) || site.nicList.includes(b)) {
    _flashNicHint(`nicCountHint_${siteId}`, 'Duplicate NIC name — each NIC must be unique.');
    return;
  }
  site.nicList.push(a, b);
  document.getElementById(`nicInputA_${siteId}`).value = '';
  document.getElementById(`nicInputB_${siteId}`).value = '';
  document.getElementById(`nicInputA_${siteId}`).focus();
  _renderSiteNicChips(siteId);
}

function removeSiteNicPair(siteId, pairIdx) {
  const site = sites.find(s => s.id === siteId);
  if (!site || !Array.isArray(site.nicList)) return;
  site.nicList.splice(pairIdx, 2);
  _renderSiteNicChips(siteId);
}

// ---------------------------------------------------------------------------
// Generic single-value tag-chip widget (DNS / NTP / Search Domains)
// ---------------------------------------------------------------------------
function _renderSimpleChips(containerId, arr, hiddenId, removeFnName, emptyMsg) {
  const container = document.getElementById(containerId);
  const hidden    = document.getElementById(hiddenId);
  if (arr.length === 0) {
    container.innerHTML = `<span style="color:var(--text-muted);font-size:13px;">${emptyMsg}</span>`;
  } else {
    container.innerHTML = arr.map((v, i) =>
      `<span style="display:inline-flex;align-items:center;gap:0;border:1px solid var(--accent);border-radius:5px;overflow:hidden;font-family:'Consolas','Monaco',monospace;font-size:12px;">` +
      `<span style="padding:3px 8px;background:rgba(0,180,216,0.08);color:var(--text);">${esc(v)}</span>` +
      `<span onclick="${removeFnName}(${i})" title="Remove" style="padding:3px 7px;border-left:1px solid var(--border);cursor:pointer;color:var(--text-muted);">×</span>` +
      `</span>`
    ).join('');
  }
  if (hidden) hidden.value = arr.join(', ');
}

function _fromValue(val) {
  return Array.isArray(val)
    ? val.filter(Boolean)
    : String(val || '').split(',').map(s => s.trim()).filter(Boolean);
}

// DNS servers (max 3)
function renderDnsChips()  { _renderSimpleChips('dnsChips',    dnsList,          'dnsServers',         'removeDns',    'No DNS servers added'); }
function addDns() {
  const input = document.getElementById('dnsInput');
  const val = (input.value || '').trim();
  if (!val || dnsList.length >= 3 || dnsList.includes(val)) { input.focus(); return; }
  dnsList.push(val); input.value = ''; input.focus(); renderDnsChips();
}
function removeDns(i)       { dnsList.splice(i, 1); renderDnsChips(); }
function setDnsFromValue(v) { dnsList = _fromValue(v); renderDnsChips(); }

// NTP servers
function renderNtpChips()  { _renderSimpleChips('ntpChips',    ntpList,          'networkNtpServers',  'removeNtp',    'No NTP servers added'); }
function addNtp() {
  const input = document.getElementById('ntpInput');
  const val = (input.value || '').trim();
  if (!val || ntpList.includes(val)) { input.focus(); return; }
  ntpList.push(val); input.value = ''; input.focus(); renderNtpChips();
}
function removeNtp(i)       { ntpList.splice(i, 1); renderNtpChips(); }
function setNtpFromValue(v) { ntpList = _fromValue(v); renderNtpChips(); }

// Search domains
function renderSearchChips() { _renderSimpleChips('searchChips', searchDomainList, 'networkSearchDomains','removeSearch', 'No search domains added'); }
function addSearch() {
  const input = document.getElementById('searchInput');
  const val = (input.value || '').trim();
  if (!val || searchDomainList.includes(val)) { input.focus(); return; }
  searchDomainList.push(val); input.value = ''; input.focus(); renderSearchChips();
}
function removeSearch(i)       { searchDomainList.splice(i, 1); renderSearchChips(); }
function setSearchFromValue(v) { searchDomainList = _fromValue(v); renderSearchChips(); }

// ---------------------------------------------------------------------------
// Step navigation
// ---------------------------------------------------------------------------
function goToStep(n) {
  document.querySelectorAll('.step-panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.sidebar-step').forEach(s => s.classList.remove('active'));
  document.getElementById('step' + n).classList.add('active');
  document.querySelector('[data-step="' + n + '"]').classList.add('active');
  if (n === 3) rebuildSupervisorSites();
  if (n === 4) refreshPreview();
}

// ---------------------------------------------------------------------------
// Step validation gate — runs before allowing navigation to next step
// ---------------------------------------------------------------------------
async function goToStepValidated(fromStep, toStep) {
  const btn = document.getElementById('next' + fromStep + 'Btn');
  const consoleEl = document.getElementById('console' + fromStep);
  const originalLabel = btn.innerHTML;
  btn.innerHTML = '<span class="spinner"></span> Validating…';
  btn.disabled = true;

  try {
    const payload = buildPayload();
    const resp = await fetch('/validate-step', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ step: fromStep, ...payload }),
    });
    const result = await resp.json();

    renderConsole(consoleEl, result.messages || []);

    if (result.passed) {
      // Capture a checkpoint before navigating so the user can recover
      // all sites if they accidentally delete them on the next step.
      const stepNames = { 1: 'Common Settings', 2: 'Edge Sites', 3: 'Supervisor Config' };
      _saveCheckpoint(stepNames[fromStep] || `Step ${fromStep}`);
      // Brief success flash then navigate; re-enable in case user navigates back.
      setTimeout(() => { goToStep(toStep); btn.innerHTML = originalLabel; btn.disabled = false; }, 400);
    } else {
      // Stay on current step; console is already visible with errors.
      btn.innerHTML = originalLabel;
      btn.disabled = false;
      // If a checkpoint exists, offer a one-click path back to the last known-good values.
      if (_checkpoint) {
        _appendCheckpointOfferToConsole(consoleEl);
      }
    }
  } catch (err) {
    renderConsole(consoleEl, [`[ERROR] Validation request failed: ${err}`]);
    btn.innerHTML = originalLabel;
    btn.disabled = false;
  }
}

// Extracts the site name from an error string that contains ["site-name"].
// Returns null if the error is not site-specific.
function _extractSite(msg) {
  const m = msg.match(/\["([^"]+)"\]/);
  return m ? m[1] : null;
}

function renderConsole(el, messages) {
  el.classList.add('visible');
  let html = '';
  let currentSite = null;

  messages.forEach(line => {
    if (line.startsWith('[INFO]')) return;

    const site = _extractSite(line);
    if (site && site !== currentSite) {
      currentSite = site;
      html += `<div style="margin:8px 0 4px;padding:3px 8px;background:rgba(0,180,216,0.08);border-left:3px solid var(--accent);font-size:11px;font-weight:600;color:var(--accent);letter-spacing:0.04em;">SITE: ${esc(site)}</div>`;
    }

    // Strip the redundant site prefix from the displayed line for brevity.
    const display = site ? line.replace(/\["[^"]+"\]/, '[site]') : line;

    if (line.startsWith('[ERROR]'))        html += `<div class="line-error">${esc(display)}</div>`;
    else if (line.startsWith('[WARNING]')) html += `<div class="line-warning">${esc(display)}</div>`;
    else                                   html += `<div class="line-plain">${esc(display)}</div>`;
  });

  el.innerHTML = html;
  el.scrollTop = el.scrollHeight;
}

// Appends a "Restore checkpoint" offer to the step console when validation fails
// and a checkpoint (last known-good state) is available.
function _appendCheckpointOfferToConsole(consoleEl) {
  if (!consoleEl || !_checkpoint) return;
  // Prevent duplicates when the user clicks Next multiple times on the same failing state.
  if (consoleEl.querySelector('[data-checkpoint-offer]')) return;
  const siteWord = _checkpoint.length === 1 ? 'site' : 'sites';
  const div = document.createElement('div');
  div.setAttribute('data-checkpoint-offer', '');
  div.style.cssText = 'margin-top:10px;padding:8px 10px;background:rgba(240,165,0,0.08);border-left:3px solid var(--warning);border-radius:0 4px 4px 0;display:flex;align-items:center;gap:10px;flex-wrap:wrap;';
  div.innerHTML =
    `<span style="color:var(--warning);font-size:12px;">Last checkpoint: ${_checkpoint.length} ${siteWord} from "${esc(_checkpointLabel)}"</span>` +
    `<button onclick="_restoreCheckpointFromConsole(this)" style="padding:3px 12px;border-radius:4px;border:1px solid var(--warning);background:transparent;color:var(--warning);font-size:12px;font-weight:700;cursor:pointer;white-space:nowrap;">Restore</button>` +
    `<span style="font-size:11px;color:var(--text-muted);">Reverts site data to last successful validation — may resolve the errors above.</span>`;
  consoleEl.appendChild(div);
  consoleEl.scrollTop = consoleEl.scrollHeight;
}

// Restores the checkpoint and re-runs validation so the console updates immediately.
function _restoreCheckpointFromConsole(btn) {
  _restoreCheckpoint();
  btn.closest('div').innerHTML = '<span style="color:var(--success);font-size:12px;">✓ Checkpoint restored. Click Next again to validate.</span>';
}

// ---------------------------------------------------------------------------
// Collapsible sections
// ---------------------------------------------------------------------------
function toggleSection(id) {
  const el = document.getElementById(id);
  if (!el) return;
  el.classList.toggle('collapsed');
  const collapsed = el.classList.contains('collapsed');
  // Walk up to the card-header and find the toggle span within it, rather than
  // relying on previousElementSibling which breaks when extra elements (e.g. reset
  // buttons) are injected between the header and the collapsible content.
  const header = el.closest('.card') && el.closest('.card').querySelector('.card-header');
  const btn = header && header.querySelector('.section-toggle');
  if (btn) btn.textContent = collapsed ? '[expand]' : '[collapse]';
}

// ---------------------------------------------------------------------------
// Sites management (Step 2)
// ---------------------------------------------------------------------------
function addSite(data) {
  const id = ++siteCounter;
  const site = data || { id, edgeSite: '', esxHosts: [], nicList: [], storageType: 'VMFS', vSanWitnessVmName: '', haPolicy: '',
    segments: [], vmkInterfaces: [], harbor: {}, supervisorServices: {}, showAdvanced: false };
  if (!data) site.id = id;
  // When adding a 3rd+ site, collapse the new one and retroactively collapse all existing ones.
  const willExceedTwo = sites.length >= 2;
  if (!('collapsed' in site)) site.collapsed = willExceedTwo;
  if (willExceedTwo) {
    sites.forEach(s => { s.collapsed = true; });
  }
  sites.push(site);
  renderSites();
}

// ---------------------------------------------------------------------------
// Multi-level undo
// ---------------------------------------------------------------------------

function _updateUndoToast() {
  const toast = document.getElementById('undoToast');
  if (!_undoStack.length) {
    toast.classList.remove('visible');
    return;
  }
  const top = _undoStack[_undoStack.length - 1];
  document.getElementById('undoLabel').textContent = top.prefix + ': ' + top.label;
  const depth = _undoStack.length;
  const depthEl = document.getElementById('undoDepth');
  depthEl.textContent = depth > 1 ? ` (+ ${depth - 1} more)` : '';
  toast.classList.add('visible');
}

function _pushUndo(label, restoreFn, prefix = 'Removed') {
  _undoStack.push({ label, restore: restoreFn, prefix });
  // Trim to max depth — oldest entries are dropped first.
  if (_undoStack.length > _MAX_UNDO) _undoStack.shift();
  _updateUndoToast();
  // Auto-dismiss after 8 s of inactivity; cleared by the next _pushUndo call.
  if (_undoTimer) clearTimeout(_undoTimer);
  _undoTimer = setTimeout(_dismissUndo, 8000);
}

function doUndo() {
  if (!_undoStack.length) return;
  const entry = _undoStack.pop();
  entry.restore();
  if (_undoTimer) clearTimeout(_undoTimer);
  if (_undoStack.length) {
    // More actions to undo — keep toast open showing the next entry.
    _undoTimer = setTimeout(_dismissUndo, 8000);
    _updateUndoToast();
  } else {
    document.getElementById('undoToast').classList.remove('visible');
  }
}

function _dismissUndo() {
  clearTimeout(_undoTimer);
  _undoStack = [];
  document.getElementById('undoToast').classList.remove('visible');
}

// ---------------------------------------------------------------------------
// Step checkpoint — saves a full snapshot of sites[] on successful navigation
// ---------------------------------------------------------------------------

function _saveCheckpoint(stepLabel) {
  _checkpoint = JSON.parse(JSON.stringify(sites));
  _checkpointLabel = stepLabel;
  const bar = document.getElementById('checkpointBar');
  bar.querySelector('span').textContent = `📍 Checkpoint: ${sites.length} site${sites.length !== 1 ? 's' : ''} saved when you advanced to "${stepLabel}".`;
  bar.classList.add('visible');
}

function _restoreCheckpoint() {
  if (!_checkpoint) return;
  // Deep-copy restores all site fields including collapsed state at checkpoint time.
  // This is intentional: the user gets back the full state as it was when they passed validation.
  sites = JSON.parse(JSON.stringify(_checkpoint));
  siteCounter = sites.reduce((max, s) => Math.max(max, s.id), 0);
  renderSites();
  rebuildSupervisorSites();
  document.getElementById('checkpointBar').querySelector('span').textContent =
    `✓ Restored ${sites.length} site${sites.length !== 1 ? 's' : ''} from checkpoint.`;
}

function _dismissCheckpoint() {
  _checkpoint = null;
  _checkpointLabel = null;
  document.getElementById('checkpointBar').classList.remove('visible');
}

function removeSite(id) {
  const site = sites.find(s => s.id === id);
  if (!site) return;
  const snapshot = JSON.parse(JSON.stringify(site));
  const insertIdx = sites.findIndex(s => s.id === id);
  sites = sites.filter(s => s.id !== id);
  renderSites();
  rebuildSupervisorSites();
  _pushUndo(snapshot.edgeSite || '(unnamed site)', () => {
    sites.splice(insertIdx, 0, snapshot);
    renderSites();
    rebuildSupervisorSites();
  });
}

// ---------------------------------------------------------------------------
// Clone site modal
// ---------------------------------------------------------------------------

// Tracks which site id is pending a clone while the modal is open.
let _cloneSourceId = null;

// Returns the suggested default clone name for sourceName, avoiding collisions.
// site → site-clone → site-clone1 → site-clone2 …
function _cloneDefaultName(sourceName) {
  const existing = new Set(sites.map(s => s.edgeSite));
  const base = (sourceName || 'site') + '-clone';
  if (!existing.has(base)) return base;
  let n = 1;
  while (existing.has(base + n)) n++;
  return base + n;
}

// Opens the clone-name dialog for the given site id. The chosen name is also used
// as the suffix appended to all segment and supervisor network names (-<newName>).
function cloneSite(id) {
  const src = sites.find(s => s.id === id);
  if (!src) return;
  _cloneSourceId = id;
  const input = document.getElementById('cloneName');
  input.value = _cloneDefaultName(src.edgeSite);
  _cloneModalValidate();
  document.getElementById('cloneModal').classList.add('visible');
  // Focus the input and select all so the user can immediately type a replacement.
  requestAnimationFrame(() => { input.focus(); input.select(); });
}

// Validates the current name input and updates the hint, suffix preview, and OK button state.
function _cloneModalValidate() {
  const input   = document.getElementById('cloneName');
  const hint    = document.getElementById('cloneNameHint');
  const ok      = document.getElementById('cloneModalOk');
  const preview = document.getElementById('cloneSuffixPreview');
  const name    = input.value.trim();
  const existing = new Set(sites.map(s => s.edgeSite));
  if (preview) preview.textContent = name ? '-' + name : '';
  if (!name) {
    hint.textContent = 'Name is required.';
    hint.style.color = 'var(--error)';
    ok.disabled = true;
  } else if (existing.has(name)) {
    hint.textContent = `"${name}" is already in use. Choose a different name.`;
    hint.style.color = 'var(--error)';
    ok.disabled = true;
  } else {
    hint.textContent = '';
    ok.disabled = false;
  }
}

function _cloneModalCancel() {
  document.getElementById('cloneModal').classList.remove('visible');
  _cloneSourceId = null;
}

function _cloneModalConfirm() {
  const newName = document.getElementById('cloneName').value.trim();
  if (!newName) return;
  document.getElementById('cloneModal').classList.remove('visible');
  _executeClone(_cloneSourceId, newName);
  _cloneSourceId = null;
}

// Performs the actual deep-copy and insertion. newName is the user-chosen edgeSite
// name for the clone; segment and supervisor network names are suffixed with
// -<newName> so they are guaranteed unique (newName was already validated as unique).
function _executeClone(srcId, newName) {
  const srcIdx = sites.findIndex(s => s.id === srcId);
  if (srcIdx === -1) return;
  const src = sites[srcIdx];
  const srcName = src.edgeSite || 'site';
  // Always use -<newName> as the suffix so segment/network names are predictable
  // and unique regardless of any relationship between source and clone names.
  const suffix = '-' + newName;

  const clone = JSON.parse(JSON.stringify(src));
  clone.id = ++siteCounter;
  clone.edgeSite = newName;
  clone.collapsed = true;

  // Append suffix to every segment name for global uniqueness.
  (clone.segments || []).forEach(seg => {
    if (seg.name) seg.name = seg.name + suffix;
  });

  // Append suffix to supervisor network names.
  const sv = clone._supervisor || {};
  if (sv.flbMgmt && sv.flbMgmt.flbNetworkName)
    sv.flbMgmt.flbNetworkName = sv.flbMgmt.flbNetworkName + suffix;
  if (sv.flbVirtualServerNet && sv.flbVirtualServerNet.flbNetworkName)
    sv.flbVirtualServerNet.flbNetworkName = sv.flbVirtualServerNet.flbNetworkName + suffix;
  if (sv.mgmt && sv.mgmt.mgmtNetworkName)
    sv.mgmt.mgmtNetworkName = sv.mgmt.mgmtNetworkName + suffix;
  if (sv.workloadNet && sv.workloadNet.primaryWorkloadNetworkName)
    sv.workloadNet.primaryWorkloadNetworkName = sv.workloadNet.primaryWorkloadNetworkName + suffix;

  sites.splice(srcIdx + 1, 0, clone);
  renderSites();
  rebuildSupervisorSites();
  _pushUndo(`"${newName}" (clone of "${srcName}")`, () => {
    sites = sites.filter(s => s.id !== clone.id);
    renderSites();
    rebuildSupervisorSites();
  }, 'Cloned');
}

// Keyboard support: Enter confirms, Escape cancels.
document.addEventListener('keydown', e => {
  if (!document.getElementById('cloneModal').classList.contains('visible')) return;
  if (e.key === 'Enter')  { e.preventDefault(); _cloneModalConfirm(); }
  if (e.key === 'Escape') { e.preventDefault(); _cloneModalCancel();  }
});

// Close on backdrop click.
document.getElementById('cloneModal').addEventListener('click', e => {
  if (e.target === document.getElementById('cloneModal')) _cloneModalCancel();
});

// ---------------------------------------------------------------------------
// ESX hosts chip widget (per-site)
// ---------------------------------------------------------------------------

// Returns a human-readable host-count status message for the ESX hosts chip widget.
function _esxCountMsg(storageType, count) {
  const max = storageType === 'VMFS' ? 1 : 2;
  if (count === max) return `${count} host${count > 1 ? 's' : ''} — OK.`;
  if (count > max)  return `${storageType} requires exactly ${max} host${max > 1 ? 's' : ''} (${count} added).`;
  if (count > 0)    return `${count} of ${max} hosts added.`;
  return `Requires exactly ${max} host${max > 1 ? 's' : ''}.`;
}

// Basic FQDN/IPv4 format check for ESX host entries (server re-validates authoritatively).
const _FQDN_OR_IP_RE = /^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$|^[a-zA-Z0-9](?:[a-zA-Z0-9\-_.]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9\-_.]*[a-zA-Z0-9])?)*$/;
// Strict IPv4-only check for VMkernel IP addresses (FQDNs are not valid here).
const _IPV4_RE = /^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$/;

function _renderEsxChips(siteId) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const hosts = Array.isArray(site.esxHosts) ? site.esxHosts : [];
  const container = document.getElementById(`esxChips_${siteId}`);
  const hint      = document.getElementById(`esxCountHint_${siteId}`);
  if (!container) return;
  const maxHosts = (site.storageType === 'VMFS') ? 1 : 2;
  if (hosts.length === 0) {
    container.innerHTML = `<span style="color:var(--text-muted);font-size:13px;">No hosts added yet.</span>`;
  } else {
    container.innerHTML = hosts.map((h, i) =>
      `<span style="display:inline-flex;align-items:center;gap:0;border:1px solid var(--accent);border-radius:5px;overflow:hidden;font-family:'Consolas','Monaco',monospace;font-size:12px;">` +
      `<span style="padding:3px 8px;background:rgba(0,180,216,0.08);color:var(--text);">${esc(h)}</span>` +
      `<span onclick="removeEsxHost(${siteId},${i})" title="Remove" style="padding:3px 7px;border-left:1px solid var(--border);cursor:pointer;color:var(--text-muted);">×</span>` +
      `</span>`
    ).join('');
  }
  if (hint) {
    const ok = hosts.length === maxHosts;
    hint.textContent = _esxCountMsg(site.storageType, hosts.length);
    hint.className = `field-hint ${ok ? 'nic-count-ok' : 'nic-count-bad'}`;
  }
}

function addEsxHost(siteId) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const input = document.getElementById(`esxInput_${siteId}`);
  const val = (input.value || '').trim();
  if (!val) { input.focus(); return; }
  if (!_FQDN_OR_IP_RE.test(val)) {
    _flashNicHint(`esxCountHint_${siteId}`, `"${val}" is not a valid FQDN or IPv4 address.`);
    return;
  }
  if (!Array.isArray(site.esxHosts)) site.esxHosts = [];
  const maxHosts = (site.storageType === 'VMFS') ? 1 : 2;
  if (site.esxHosts.length >= maxHosts) {
    _flashNicHint(`esxCountHint_${siteId}`, `Maximum of ${maxHosts} host${maxHosts>1?'s':''} for ${site.storageType}.`);
    return;
  }
  if (site.esxHosts.includes(val)) {
    _flashNicHint(`esxCountHint_${siteId}`, 'Duplicate host — each ESX host must be unique.');
    return;
  }
  site.esxHosts.push(val);
  input.value = '';
  input.focus();
  _renderEsxChips(siteId);
}

function removeEsxHost(siteId, idx) {
  const site = sites.find(s => s.id === siteId);
  if (!site || !Array.isArray(site.esxHosts)) return;
  site.esxHosts.splice(idx, 1);
  _renderEsxChips(siteId);
}

// ---------------------------------------------------------------------------
// VMkernel IP chip widget (per-vmk)
// ---------------------------------------------------------------------------

function _renderVmkIpChips(siteId, vmkIdx) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const vmk = (site.vmkInterfaces || [])[vmkIdx];
  if (!vmk) return;
  const ips = Array.isArray(vmk.ipList) ? vmk.ipList : [];
  const container = document.getElementById(`vmkIpChips_${siteId}_${vmkIdx}`);
  if (!container) return;
  if (ips.length === 0) {
    container.innerHTML = `<span style="color:var(--text-muted);font-size:13px;">No IPs added.</span>`;
  } else {
    container.innerHTML = ips.map((ip, i) =>
      `<span style="display:inline-flex;align-items:center;gap:0;border:1px solid var(--accent);border-radius:5px;overflow:hidden;font-family:'Consolas','Monaco',monospace;font-size:12px;">` +
      `<span style="padding:3px 8px;background:rgba(0,180,216,0.08);color:var(--text);">${esc(ip)}</span>` +
      `<span onclick="removeVmkIp(${siteId},${vmkIdx},${i})" title="Remove" style="padding:3px 7px;border-left:1px solid var(--border);cursor:pointer;color:var(--text-muted);">×</span>` +
      `</span>`
    ).join('');
  }
}

function addVmkIp(siteId, vmkIdx) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const vmk = (site.vmkInterfaces || [])[vmkIdx];
  if (!vmk) return;
  const input = document.getElementById(`vmkIpInput_${siteId}_${vmkIdx}`);
  const val = (input.value || '').trim();
  if (!val) { input.focus(); return; }
  if (!_IPV4_RE.test(val)) {
    _flashNicHint(`vmkIpHint_${siteId}_${vmkIdx}`, `"${val}" is not a valid IPv4 address.`);
    return;
  }
  if (!Array.isArray(vmk.ipList)) vmk.ipList = [];
  if (vmk.ipList.length >= 2) {
    _flashNicHint(`vmkIpHint_${siteId}_${vmkIdx}`, 'Maximum of 2 IPs — one per ESX host.');
    return;
  }
  if (vmk.ipList.includes(val)) {
    _flashNicHint(`vmkIpHint_${siteId}_${vmkIdx}`, 'Duplicate IP — both addresses must be unique.');
    return;
  }
  vmk.ipList.push(val);
  input.value = '';
  input.focus();
  _renderVmkIpChips(siteId, vmkIdx);
}

function removeVmkIp(siteId, vmkIdx, ipIdx) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const vmk = (site.vmkInterfaces || [])[vmkIdx];
  if (!vmk || !Array.isArray(vmk.ipList)) return;
  vmk.ipList.splice(ipIdx, 1);
  _renderVmkIpChips(siteId, vmkIdx);
}

function renderSites() {
  const container = document.getElementById('sitesContainer');
  if (sites.length === 0) {
    container.innerHTML = '<p style="color:var(--text-muted);margin-bottom:16px;">No sites added yet. Click "+ Add Site" to begin.</p>';
    return;
  }
  container.innerHTML = sites.map(site => renderSiteBlock(site)).join('');
  // Populate per-site chip containers after the DOM elements exist.
  sites.forEach(site => {
    _renderSiteNicChips(site.id);
    _renderEsxChips(site.id);
    (site.vmkInterfaces || []).forEach((_, vi) => _renderVmkIpChips(site.id, vi));
  });
}

// Renders the service status band showing Harbor & ArgoCD state with override controls.
function renderSiteServiceBand(site) {
  const svcs = site.supervisorServices || {};
  const commonHarborDisabled = !!(document.getElementById('svc_disableHarbor') || {}).checked;
  const commonArgoDisabled   = !!(document.getElementById('svc_disableArgoCD')  || {}).checked;

  function svcState(flag, commonDisabled) {
    if (flag === true)  return 'disabled-site';
    if (flag === false) return 'enabled-override';
    return commonDisabled ? 'disabled-common' : 'enabled';
  }
  function svcBadge(label, state, siteId, flagName, commonDisabled) {
    const badgeStyle = {
      'enabled':          'background:rgba(46,194,126,0.12);border:1px solid var(--success);color:var(--success);',
      'enabled-override': 'background:rgba(46,194,126,0.2);border:2px solid var(--success);color:var(--success);',
      'disabled-common':  'background:rgba(240,165,0,0.12);border:1px solid var(--warning);color:var(--warning);',
      'disabled-site':    'background:rgba(136,146,164,0.12);border:1px solid var(--text-muted);color:var(--text-muted);',
    }[state];
    const statusText = {
      'enabled':          '✓ Enabled',
      'enabled-override': '✓ Enabled (site override)',
      'disabled-common':  '⚠ Disabled at common level',
      'disabled-site':    '— Disabled for this site',
    }[state];

    const disabledVal = svcs[flagName];
    const selVal = disabledVal === true ? 'true' : disabledVal === false ? 'false' : '';

    // Show a "Re-enable for this site" prompt only when disabled at common level and not yet overridden.
    const hint = (state === 'disabled-common')
      ? `<span style="font-size:11px;color:var(--warning);margin-left:6px;">→ use the select below to override</span>`
      : '';

    return `<div style="display:flex;flex-direction:column;gap:4px;">
      <div style="display:flex;align-items:center;gap:8px;">
        <span style="font-size:12px;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:.04em;width:52px;">${esc(label)}</span>
        <span style="padding:2px 10px;border-radius:4px;font-size:11px;font-weight:700;${badgeStyle}">${statusText}</span>
        ${hint}
      </div>
      <select style="font-size:12px;padding:4px 8px;" onchange="updateSiteSvcTriState(${siteId},'${flagName}',this.value)">
        <option value="" ${selVal===''?'selected':''}>Inherit from common${commonDisabled?' (currently: disabled)':' (currently: enabled)'}</option>
        <option value="false" ${selVal==='false'?'selected':''}>⚡ Enable for this site (override common disable)</option>
        <option value="true" ${selVal==='true'?'selected':''}>Disable for this site</option>
      </select>
    </div>`;
  }

  const harborState = svcState(svcs.disableHarbor, commonHarborDisabled);
  const argoState   = svcState(svcs.disableArgoCD,  commonArgoDisabled);
  const harborToggle = harborState !== 'disabled-site' ? `<span class="section-toggle" onclick="toggleSection('harbor-${site.id}')" style="margin-left:8px;">[expand config]</span>` : '';

  return `<div style="margin-top:12px;padding:12px 14px;background:var(--surface2);border:1px solid var(--border);border-radius:var(--radius);">
    <div style="font-size:12px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.05em;margin-bottom:10px;">Supervisor Services — per-site overrides</div>
    <div class="grid-2" style="gap:16px;">
      <div>
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">
          <span style="font-size:13px;font-weight:600;">Harbor</span>${harborToggle}
        </div>
        ${svcBadge('Harbor', harborState, site.id, 'disableHarbor', commonHarborDisabled)}
      </div>
      <div>
        <div style="font-size:13px;font-weight:600;margin-bottom:6px;">ArgoCD</div>
        ${svcBadge('ArgoCD', argoState, site.id, 'disableArgoCD', commonArgoDisabled)}
      </div>
    </div>
  </div>`;
}

// Renders the basic identity/storage fields for a site (edgeSite, esxHosts, storageType, NIC, haPolicy).
function _renderSiteHeaderFields(site) {
  const vmkRequired = (site.storageType === 'vSAN-OSA' || site.storageType === 'vSAN-ESA');
  return `
    <div class="grid-2" style="margin-bottom:14px;">
      <div class="field">
        <label>Edge Site ID <span class="req">*</span>${tt('Unique identifier for this site. Must match exactly in the Supervisor config. Lowercase letters, digits, and hyphens recommended.')}</label>
        <input type="text" value="${esc(site.edgeSite)}" placeholder="site1" oninput="updateSiteField(${site.id},'edgeSite',this.value)">
        <span class="field-hint">Unique ID; must match in supervisor config.</span>
      </div>
      <div class="field">
        <label>ESX Hosts <span class="req">*</span>${tt('FQDN or IPv4 address of each ESX host in this cluster. VMFS: exactly 1 host. vSAN-OSA or vSAN-ESA: exactly 2 hosts.')}</label>
        <div id="esxChips_${site.id}" style="display:flex;flex-wrap:wrap;gap:6px;min-height:34px;padding:6px 10px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;align-items:center;"></div>
        <div style="display:flex;gap:6px;margin-top:6px;">
          <input type="text" id="esxInput_${site.id}" placeholder="esx01.example.com" style="flex:1;font-size:13px;"
            onkeydown="if(event.key==='Enter'){event.preventDefault();addEsxHost(${site.id});}">
          <button class="btn btn-secondary" style="padding:6px 12px;font-size:13px;white-space:nowrap;" onclick="addEsxHost(${site.id})">+ Add</button>
        </div>
        <span class="field-hint" id="esxCountHint_${site.id}"></span>
      </div>
      <div class="field">
        <label>Storage Type <span class="req">*</span>${tt('VMFS: single-host, traditional block storage. vSAN-OSA: 2-host vSAN with Original Storage Architecture. vSAN-ESA: 2-host vSAN with Express Storage Architecture.')}</label>
        <select onchange="updateSiteField(${site.id},'storageType',this.value);_rerenderSiteBlock(${site.id});">
          <option value="VMFS" ${site.storageType==='VMFS'?'selected':''}>VMFS</option>
          <option value="vSAN-OSA" ${site.storageType==='vSAN-OSA'?'selected':''}>vSAN-OSA</option>
          <option value="vSAN-ESA" ${site.storageType==='vSAN-ESA'?'selected':''}>vSAN-ESA</option>
        </select>
      </div>
      <div class="field">
        <label>NIC List Override <span class="tip">optional; overrides common</span>${tt('Override the common NIC list for this site only. NICs must be added in pairs (2 or 4 total). Leave blank to inherit from Common Settings.')}</label>
        <div id="nicChips_${site.id}" style="display:flex;flex-wrap:wrap;gap:8px;min-height:40px;padding:8px 10px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;align-items:center;"></div>
        <div style="display:flex;gap:8px;margin-top:8px;align-items:flex-end;">
          <div class="field" style="flex:1;gap:4px;">
            <label style="font-size:11px;">NIC A</label>
            <input type="text" id="nicInputA_${site.id}" placeholder="vmnic0" style="font-size:13px;" onkeydown="if(event.key==='Enter'){event.preventDefault();document.getElementById('nicInputB_${site.id}').focus();}">
          </div>
          <div class="field" style="flex:1;gap:4px;">
            <label style="font-size:11px;">NIC B</label>
            <input type="text" id="nicInputB_${site.id}" placeholder="vmnic1" style="font-size:13px;" onkeydown="if(event.key==='Enter'){event.preventDefault();addSiteNicPair(${site.id});}">
          </div>
          <button class="btn btn-secondary" style="padding:8px 16px;font-size:13px;white-space:nowrap;" onclick="addSiteNicPair(${site.id})">+ Add Pair</button>
        </div>
        <span class="field-hint" id="nicCountHint_${site.id}">Leave blank to inherit common nicList.</span>
      </div>
      ${vmkRequired ? `
      <div class="field">
        <label>vSAN Witness VM Name${tt('FQDN or IPv4 of the vSAN witness appliance for this site. Required for vSAN-OSA and vSAN-ESA. Overrides the common-level setting if set.')}</label>
        <input type="text" value="${esc(site.vSanWitnessVmName)}" placeholder="vsanwitness.example.com" oninput="updateSiteField(${site.id},'vSanWitnessVmName',this.value)">
      </div>
      ` : ''}
      <div class="field">
        <label>HA Policy Override <span class="tip">optional</span>${tt('Override the HA Policy for this site only. Leave blank to inherit from common (default: reservationBased). reservationBased: percentage-based admission control. slotBased: slot-based. disabled: HA on, no admission control.')}</label>
        <select onchange="updateSiteField(${site.id},'haPolicy',this.value)">
          <option value="" ${!site.haPolicy?'selected':''}>Use common setting (default: reservationBased)</option>
          <option value="reservationBased" ${site.haPolicy==='reservationBased'?'selected':''}>reservationBased</option>
          <option value="slotBased" ${site.haPolicy==='slotBased'?'selected':''}>slotBased</option>
          <option value="disabled" ${site.haPolicy==='disabled'?'selected':''}>disabled</option>
        </select>
      </div>
    </div>`;
}

// Renders the network segments chip editor for a site.
function _renderSiteSegmentsWidget(site) {
  const segs = (site.segments || []);
  return `
    <div style="font-size:13px;font-weight:600;margin-bottom:10px;">Network Segments <span style="font-size:11px;font-weight:400;color:var(--text-muted)">(names must be lowercase RFC1123)</span></div>
    ${segs.map((seg, si) => `
    <div class="segment-item">
      <div class="item-header">
        <span>Segment ${si+1}: <strong>${esc(seg.name)||'(unnamed)'}</strong></span>
        <button class="btn btn-danger" onclick="removeSegment(${site.id},${si})">Remove</button>
      </div>
      <div class="grid-3">
        <div class="field"><label>Name <span class="req">*</span>${tt('Lowercase RFC1123 segment name: letters a-z, digits, hyphens only; no leading/trailing hyphens; 1–80 chars. Must be globally unique across all sites (e.g. mgmt-site1).')}</label>
          <input type="text" value="${esc(seg.name)}" placeholder="primaryworkloadnetwork" oninput="updateSegment(${site.id},${si},'name',this.value)"></div>
        <div class="field"><label>VLAN ID <span class="req">*</span>${tt('Integer VLAN ID 0–4095. Must be unique within this cluster. Use 0 for untagged.')}</label>
          <input type="number" value="${esc(seg.vlanId)}" placeholder="300" min="0" max="4095" oninput="updateSegment(${site.id},${si},'vlanId',this.value)"></div>
        <div class="field"><label>Gateway (CIDR) <span class="req">*</span>${tt('Gateway IP with prefix length in CIDR format (e.g. 10.30.10.1/24). The prefix defines the subnet used for IP-in-range cross-validation of supervisor starting IPs.')}</label>
          <input type="text" value="${esc(seg.gateway)}" placeholder="10.30.10.1/24" oninput="updateSegment(${site.id},${si},'gateway',this.value)"></div>
      </div>
    </div>`).join('')}
    <button class="btn btn-secondary" style="margin-bottom:16px;font-size:12px;" onclick="addSegment(${site.id})">+ Add Segment</button>`;
}

// Renders the VMkernel interfaces editor for a site (only shown for vSAN-OSA/ESA).
function _renderSiteVmkWidget(site) {
  if (site.storageType !== 'vSAN-OSA' && site.storageType !== 'vSAN-ESA') return '';
  const vmks = (site.vmkInterfaces || []);
  return `
    <div style="font-size:13px;font-weight:600;margin-bottom:10px;">VMkernel Interfaces <span style="font-size:11px;font-weight:400;color:var(--text-muted)">(required for ${site.storageType})</span></div>
    ${vmks.map((vmk, vi) => `
    <div class="vmk-item">
      <div class="item-header">
        <span>VMkernel ${vi+1}: <strong>${esc(vmk.service)||'(no service)'}</strong></span>
        <button class="btn btn-danger" onclick="removeVmk(${site.id},${vi})">Remove</button>
      </div>
      <div class="grid-2">
        <div class="field"><label>Service <span class="req">*</span>${tt('VMkernel traffic type. vMotion: live migration traffic. vSAN: storage traffic between data hosts. vSAN Witness: traffic to the witness appliance (one per cluster).')}</label>
          <select onchange="updateVmk(${site.id},${vi},'service',this.value)">
            <option value="vMotion" ${vmk.service==='vMotion'?'selected':''}>vMotion</option>
            <option value="vSAN" ${vmk.service==='vSAN'?'selected':''}>vSAN</option>
            <option value="vSAN Witness" ${vmk.service==='vSAN Witness'?'selected':''}>vSAN Witness</option>
          </select></div>
        <div class="field"><label>VLAN ID <span class="req">*</span>${tt('VLAN ID for this VMkernel adapter (0–4095).')}</label>
          <input type="number" value="${esc(vmk.vlanId)}" placeholder="300" min="0" max="4095" oninput="updateVmk(${site.id},${vi},'vlanId',this.value)"></div>
        <div class="field"><label>Netmask <span class="req">*</span>${tt('Subnet mask for this VMkernel adapter as a dotted-decimal IPv4 address. Must be a contiguous mask (e.g. 255.255.255.0). Arbitrary bitmasks are invalid.')}</label>
          <input type="text" value="${esc(vmk.netmask)}" placeholder="255.255.255.0" oninput="updateVmk(${site.id},${vi},'netmask',this.value)"></div>
        <div class="field"><label>IP List <span class="req">*</span>${tt('Exactly 2 unique IPv4 addresses — one per ESX data host — assigned to this VMkernel adapter type.')}</label>
          <div id="vmkIpChips_${site.id}_${vi}" style="display:flex;flex-wrap:wrap;gap:6px;min-height:30px;padding:5px 8px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;align-items:center;"></div>
          <div style="display:flex;gap:6px;margin-top:5px;">
            <input type="text" id="vmkIpInput_${site.id}_${vi}" placeholder="10.30.10.12" style="flex:1;font-size:13px;"
              onkeydown="if(event.key==='Enter'){event.preventDefault();addVmkIp(${site.id},${vi});}">
            <button class="btn btn-secondary" style="padding:4px 10px;font-size:12px;white-space:nowrap;" onclick="addVmkIp(${site.id},${vi})">+ Add</button>
          </div>
          <span class="field-hint" id="vmkIpHint_${site.id}_${vi}"></span>
        </div>
        ${vmk.service==='vSAN Witness'?`
        <div class="field"><label>Gateway <span class="tip">vSAN Witness only</span>${tt('Default gateway IPv4 address for the vSAN Witness VMkernel. Required when the witness appliance is on a different subnet than the data hosts.')}</label>
          <input type="text" value="${esc(vmk.gateway)}" placeholder="10.30.12.1" oninput="updateVmk(${site.id},${vi},'gateway',this.value)"></div>` : ''}
      </div>
    </div>`).join('')}
    <button class="btn btn-secondary" style="margin-bottom:16px;font-size:12px;" onclick="addVmk(${site.id})">+ Add VMkernel Interface</button>`;
}

// Renders the Harbor configuration fields for a site (inside a collapsible section).
function _renderSiteHarborFields(site) {
  const h = site.harbor || {};
  return `
    <div id="harbor-${site.id}" class="collapsible-content collapsed">
      <div class="grid-2">
        <div class="field"><label>Hostname <span class="req">*</span> <span class="tip">unless disabled</span>${tt('FQDN or IPv4 address of the Harbor registry endpoint. Required unless Disable Harbor is checked for this site.')}</label>
          <input type="text" value="${esc(h.hostname)}" placeholder="harbor-site1.example.com"
            oninput="updateHarbor(${site.id},'hostname',this.value)"></div>
        <div class="field"><label>Parent Directory${tt('Filesystem path containing Harbor YAML and certificate files. Use the directory that holds tlsCrt, tlsKey, and caCrt files.')}</label>
          <input type="text" value="${esc(h.parentDirectory)}" placeholder="C:\path\to\certs\"
            oninput="updateHarbor(${site.id},'parentDirectory',this.value)"></div>
        <div class="field"><label>TLS Cert Filename${tt('Filename of the TLS certificate for Harbor (e.g. tls.crt.pem). Must be defined together with TLS Key Filename. File must exist in Parent Directory.')}</label>
          <input type="text" value="${esc(h.tlsCrt)}" placeholder="tls.crt.pem"
            oninput="updateHarbor(${site.id},'tlsCrt',this.value)"></div>
        <div class="field"><label>TLS Key Filename${tt('Filename of the TLS private key for Harbor (e.g. tls.key.pem). Must be defined together with TLS Cert Filename. File must exist in Parent Directory.')}</label>
          <input type="text" value="${esc(h.tlsKey)}" placeholder="tls.key.pem"
            oninput="updateHarbor(${site.id},'tlsKey',this.value)"></div>
        <div class="field"><label>CA Cert Filename${tt('Filename of the CA certificate (e.g. ca.crt.pem). Only valid when both TLS Cert and TLS Key are also defined.')}</label>
          <input type="text" value="${esc(h.caCrt)}" placeholder="ca.crt.pem"
            oninput="updateHarbor(${site.id},'caCrt',this.value)"></div>
        <div class="field"><label>Admin Password${tt('Harbor admin account password. Use $env:VARNAME to read from an environment variable at deployment time (recommended — avoids storing secrets in JSON).')}</label>
          <input type="text" value="${esc(h.harborAdminPassword)}" placeholder="$env:HARBOR_ADMIN_PASSWORD"
            oninput="updateHarbor(${site.id},'harborAdminPassword',this.value)"></div>
        <div class="field"><label>Secret Key <span class="tip">exactly 16 chars</span>${tt('AES-128 encryption key for Harbor internal data. Must be exactly 16 characters. Use $env:SECRET_KEY to read from an environment variable.')}</label>
          <input type="text" value="${esc(h.secretKey)}" placeholder="$env:SECRET_KEY"
            oninput="updateHarbor(${site.id},'secretKey',this.value)"></div>
        <div class="field"><label>Database Password${tt('Password for the Harbor PostgreSQL database. Use $env:DATABASE_PASSWORD to read from an environment variable.')}</label>
          <input type="text" value="${esc(h.databasePassword)}" placeholder="$env:DATABASE_PASSWORD"
            oninput="updateHarbor(${site.id},'databasePassword',this.value)"></div>
        <div class="field"><label>Registry Volume Size${tt('Persistent volume size for the Harbor registry component. Must be a positive integer followed by Gi (e.g. 10Gi). Minimum recommended: 10Gi.')}</label>
          <input type="text" value="${esc(h.registryVolumeSize)}" placeholder="10Gi"
            oninput="updateHarbor(${site.id},'registryVolumeSize',this.value)"></div>
        <div class="field"><label>Jobservice Volume Size${tt('Persistent volume size for the Harbor job service component (e.g. 5Gi).')}</label>
          <input type="text" value="${esc(h.jobserviceVolumeSize)}" placeholder="5Gi"
            oninput="updateHarbor(${site.id},'jobserviceVolumeSize',this.value)"></div>
        <div class="field"><label>Database Volume Size${tt('Persistent volume size for the Harbor PostgreSQL database (e.g. 10Gi).')}</label>
          <input type="text" value="${esc(h.databaseVolumeSize)}" placeholder="10Gi"
            oninput="updateHarbor(${site.id},'databaseVolumeSize',this.value)"></div>
        <div class="field"><label>Redis Volume Size${tt('Persistent volume size for the Harbor Redis cache (e.g. 1Gi).')}</label>
          <input type="text" value="${esc(h.redisVolumeSize)}" placeholder="1Gi"
            oninput="updateHarbor(${site.id},'redisVolumeSize',this.value)"></div>
        <div class="field"><label>Trivy Volume Size${tt('Persistent volume size for the Trivy vulnerability scanner used by Harbor (e.g. 5Gi).')}</label>
          <input type="text" value="${esc(h.trivyVolumeSize)}" placeholder="5Gi"
            oninput="updateHarbor(${site.id},'trivyVolumeSize',this.value)"></div>
      </div>
    </div>`;
}

// Re-renders a single site block in place without rebuilding all sites.
// Used when a field change (e.g. storageType) requires the block to be visually updated.
function _rerenderSiteBlock(siteId) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const el = document.getElementById(`site-block-${siteId}`);
  if (!el) return;
  el.outerHTML = renderSiteBlock(site);
  _renderSiteNicChips(siteId);
  _renderEsxChips(siteId);
  (site.vmkInterfaces || []).forEach((_, vi) => _renderVmkIpChips(siteId, vi));
}

// Toggles the collapsed state of a site block without a full re-render.
function toggleSiteCollapse(id) {
  const site = sites.find(s => s.id === id);
  if (!site) return;
  site.collapsed = !site.collapsed;
  const block = document.getElementById(`site-block-${id}`);
  const body  = document.getElementById(`site-body-${id}`);
  if (!block || !body) return;
  block.classList.toggle('is-collapsed', site.collapsed);
  body.style.display = site.collapsed ? 'none' : '';
}

// Assembles the full site block from the four section renderers above.
function renderSiteBlock(site) {
  const collapsed = !!site.collapsed;
  return `<div class="site-block${collapsed ? ' is-collapsed' : ''}" id="site-block-${site.id}">
    <div class="item-header" style="cursor:pointer;" onclick="toggleSiteCollapse(${site.id})">
      <span>
        <span class="site-collapse-arrow">&#9660;</span>
        Site: <strong>${esc(site.edgeSite) || '(unnamed)'}</strong> <span class="badge">${esc(site.storageType) || 'VMFS'}</span>
      </span>
      <div style="display:flex;gap:8px;align-items:center;" onclick="event.stopPropagation()">
        ${_resetBtn('site', site.edgeSite)}
        <button class="btn btn-secondary" onclick="cloneSite(${site.id})" title="Clone this site — creates a copy with a unique name immediately below">Clone</button>
        <button class="btn btn-danger" onclick="removeSite(${site.id})">Remove</button>
      </div>
    </div>
    <div id="site-body-${site.id}" style="${collapsed ? 'display:none' : ''}">
      ${_renderSiteHeaderFields(site)}
      ${_renderSiteSegmentsWidget(site)}
      ${_renderSiteVmkWidget(site)}
      ${renderSiteServiceBand(site)}
      ${_renderSiteHarborFields(site)}
    </div>
  </div>`;
}

function updateSiteField(id, field, value) {
  const site = sites.find(s => s.id === id);
  if (site) site[field] = value;
  if (field === 'edgeSite') {
    const header = document.querySelector(`#site-block-${id} .item-header strong`);
    if (header) header.textContent = value || '(unnamed)';
  }
}

function addSegment(siteId) {
  const site = sites.find(s => s.id === siteId);
  if (!site.segments) site.segments = [];
  site.segments.push({ name: '', vlanId: '', gateway: '' });
  renderSites();
}

function removeSegment(siteId, segIdx) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const removed = JSON.parse(JSON.stringify(site.segments[segIdx]));
  site.segments.splice(segIdx, 1);
  renderSites();
  _pushUndo(`segment "${removed.name || segIdx}" in site "${site.edgeSite || siteId}"`, () => {
    const s = sites.find(x => x.id === siteId);
    if (s) { s.segments.splice(segIdx, 0, removed); renderSites(); }
  });
}

function updateSegment(siteId, segIdx, field, value) {
  const site = sites.find(s => s.id === siteId);
  if (site && site.segments[segIdx]) site.segments[segIdx][field] = value;
}

function addVmk(siteId) {
  const site = sites.find(s => s.id === siteId);
  if (!site.vmkInterfaces) site.vmkInterfaces = [];
  site.vmkInterfaces.push({ service: 'vMotion', vlanId: '', netmask: '255.255.255.0', ipList: [], gateway: '' });
  renderSites();
}

function removeVmk(siteId, vmkIdx) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  const removed = JSON.parse(JSON.stringify(site.vmkInterfaces[vmkIdx]));
  site.vmkInterfaces.splice(vmkIdx, 1);
  renderSites();
  _pushUndo(`VMkernel "${removed.service || vmkIdx}" in site "${site.edgeSite || siteId}"`, () => {
    const s = sites.find(x => x.id === siteId);
    if (s) { s.vmkInterfaces.splice(vmkIdx, 0, removed); renderSites(); }
  });
}

function updateVmk(siteId, vmkIdx, field, value) {
  const site = sites.find(s => s.id === siteId);
  if (site && site.vmkInterfaces[vmkIdx]) site.vmkInterfaces[vmkIdx][field] = value;
}

function updateHarbor(siteId, field, value) {
  const site = sites.find(s => s.id === siteId);
  if (!site) return;
  if (!site.harbor) site.harbor = {};
  site.harbor[field] = value;
}

// Three-state service flag handler.
// value "" → delete the key (inherit from common; key absent from JSON).
// value "true" → store boolean true (explicitly disabled).
// value "false" → store boolean false (explicitly enabled, overrides common disable).
function updateSiteSvcTriState(siteId, field, value) {
  const site = sites.find(s => s.id === siteId);
  if (!site.supervisorServices) site.supervisorServices = {};
  if (value === '') {
    delete site.supervisorServices[field];
  } else {
    site.supervisorServices[field] = (value === 'true');
  }
}

// ---------------------------------------------------------------------------
// Supervisor sites (Step 3) — auto-populated from Step 2 segment names
// ---------------------------------------------------------------------------
// Toggles the collapsed state of a supervisor site block without a full re-render.
function toggleSupSiteCollapse(id) {
  const site = sites.find(s => s.id === id);
  if (!site) return;
  site.supCollapsed = !site.supCollapsed;
  const body   = document.getElementById(`sup-site-body-${id}`);
  const arrow  = document.getElementById(`sup-site-arrow-${id}`);
  const toggle = document.getElementById(`sup-site-toggle-${id}`);
  if (body)   body.style.display   = site.supCollapsed ? 'none' : '';
  if (arrow)  arrow.style.transform = site.supCollapsed ? 'rotate(-90deg)' : '';
  if (toggle) toggle.textContent   = site.supCollapsed ? '[expand]' : '[collapse]';
}

function rebuildSupervisorSites() {
  const container = document.getElementById('supervisorSitesContainer');
  if (sites.length === 0) {
    container.innerHTML = '<p style="color:var(--text-muted);">No sites defined in Edge Sites.</p>';
    return;
  }
  // Mirror edge-site collapse behaviour: collapse all supervisor blocks when there are 3+ sites.
  if (sites.length > 2) {
    sites.forEach(s => { if (!('supCollapsed' in s)) s.supCollapsed = true; });
  }
  container.innerHTML = sites.map(site => renderSupervisorSiteBlock(site)).join('');
  // Explicitly set .value on each network-name <select> after innerHTML assignment.
  // Setting innerHTML with a <select> that has a selected <option> does not reliably
  // update the element's .value property in all browsers — explicit assignment is required.
  sites.forEach(site => {
    const sv = site._supervisor || {};
    const setSelect = (id, val) => {
      if (!val) return;
      const el = document.getElementById(id);
      if (!el) return;
      el.value = val;
      if (el.value === val) return;
      // Case-insensitive fallback: find the option whose value matches ignoring case.
      const lower = val.toLowerCase();
      const opt = Array.from(el.options).find(o => o.value.toLowerCase() === lower);
      if (opt) el.value = opt.value;
    };
    setSelect(`sup-${site.id}-flbMgmt-name`, (sv.flbMgmt || {}).flbNetworkName);
    setSelect(`sup-${site.id}-flbVirtualServerNet-name`, (sv.flbVirtualServerNet || {}).flbNetworkName);
    setSelect(`sup-${site.id}-mgmt-name`,                (sv.mgmt               || {}).mgmtNetworkName);
    setSelect(`sup-${site.id}-workloadNet-name`,         (sv.workloadNet        || {}).primaryWorkloadNetworkName);
  });
  _updateResetButtons();
}

// Renders the four fields (Network Name select, Start IP, IP Count, Gateway Override) for
// one FLB network section (flbMgmt or flbVirtualServerNet). The select id and oninput
// section key vary; all other markup is identical between the two sections.
// Options object: { sectionKey, idSuffix, titleText, net, segOpts,
//   nameTooltip, startTooltip, countTooltip, gatewayTooltip, noSegHint }
function _renderFlbNetworkSection(site, opts) {
  const { sectionKey, idSuffix, titleText, net, segOpts,
          nameTooltip, startTooltip, countTooltip, gatewayTooltip, noSegHint = false } = opts;
  return `
    <div style="font-size:12px;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:.04em;margin-bottom:10px;">${titleText}</div>
    <div class="grid-2" style="margin-bottom:16px;">
      <div class="field"><label>Network Name <span class="req">*</span>${nameTooltip}</label>
        <select id="sup-${site.id}-${idSuffix}-name" oninput="updateSupField(${site.id},'${sectionKey}','flbNetworkName',this.value)">
          <option value="">-- select segment --</option>${segOpts(net.flbNetworkName)}
        </select>
        ${noSegHint ? '<span class="field-hint" style="color:var(--warning);">No segments defined for this site yet.</span>' : ''}
      </div>
      <div class="field"><label>Start IP <span class="req">*</span>${startTooltip}</label>
        <input type="text" value="${esc(net.flbNetworkIpAddressStartingIp)}" placeholder="10.30.11.101" oninput="updateSupField(${site.id},'${sectionKey}','flbNetworkIpAddressStartingIp',this.value)"></div>
      <div class="field"><label>IP Count <span class="req">*</span>${countTooltip}</label>
        <input type="number" value="${esc(net.flbNetworkIpAddressCount)}" placeholder="40" min="1" oninput="updateSupField(${site.id},'${sectionKey}','flbNetworkIpAddressCount',this.value)"></div>
      <div class="field"><label>Gateway Override <span class="tip">optional CIDR or IP</span>${gatewayTooltip}</label>
        <input type="text" value="${esc(net.flbNetworkGateway)}" placeholder="" oninput="updateSupField(${site.id},'${sectionKey}','flbNetworkGateway',this.value)"></div>
    </div>`;
}

function renderSupervisorSiteBlock(site) {
  const segNames = (site.segments || []).map(s => s.name).filter(Boolean);
  const lcSel = s => (s || '').toLowerCase();
  const segOpts = selected => segNames.map(n => `<option value="${esc(n)}"${lcSel(n)===lcSel(selected)?' selected':''}>${esc(n)}</option>`).join('');
  const noSegHint = segNames.length === 0;
  const sv = site._supervisor || {};
  const flb = sv.flb || {};
  const mgmt = sv.mgmt || {};
  const workloadNet = sv.workloadNet || {};
  const collapsed = !!site.supCollapsed;

  return `<div class="card" id="sup-site-${site.id}">
    <div class="card-header" style="cursor:pointer;display:flex;align-items:center;justify-content:space-between;"
         onclick="toggleSupSiteCollapse(${site.id})">
      <span>
        <span id="sup-site-arrow-${site.id}" style="display:inline-block;margin-right:6px;transition:transform .15s;${collapsed ? 'transform:rotate(-90deg)' : ''}">&#9660;</span>
        Site:&nbsp;<strong>${esc(site.edgeSite)||'(unnamed)'}</strong>
      </span>
      <span style="display:flex;gap:8px;align-items:center;" onclick="event.stopPropagation()">
        <span id="sup-site-toggle-${site.id}" class="section-toggle">${collapsed ? '[expand]' : '[collapse]'}</span>
        ${_resetBtn('supsite', site.edgeSite)}
      </span>
    </div>
    <div id="sup-site-body-${site.id}" style="${collapsed ? 'display:none' : ''}">
    <div style="font-size:12px;color:var(--text-muted);margin-bottom:14px;padding:8px 12px;background:var(--surface2);border-radius:5px;border-left:3px solid var(--accent);">
      Linked to infrastructure cluster <strong>${esc(site.edgeSite)||'(unnamed)'}</strong> — network name selects below show segments defined for this site in Edge Sites.
    </div>
    <div class="grid-2" style="margin-bottom:16px;">
      <div class="field"><label>FLB Name <span class="req">*</span>${tt('Name for the Foundation Load Balancer instance for this site.')}</label>
        <input type="text" value="${esc(flb.flbName)}" placeholder="flb-site1" oninput="updateSupField(${site.id},'flb','flbName',this.value)"></div>
      <div class="field"><label>FLB VIP Start IP <span class="req">*</span>${tt('First IPv4 address of the FLB Virtual IP range. Must be a valid IPv4 address within a routable subnet.')}</label>
        <input type="text" value="${esc(flb.flbVipStartIP)}" placeholder="10.30.12.201" oninput="updateSupField(${site.id},'flb','flbVipStartIP',this.value)"></div>
      <div class="field"><label>FLB VIP Count <span class="req">*</span>${tt('Number of Virtual IP addresses reserved for the FLB. Must be a positive integer.')}</label>
        <input type="number" value="${esc(flb.flbVipIPCount)}" placeholder="50" min="1" oninput="updateSupField(${site.id},'flb','flbVipIPCount',this.value)"></div>
    </div>
    ${_renderFlbNetworkSection(site, {
        sectionKey: 'flbMgmt', idSuffix: 'flbMgmt',
        titleText: 'FLB Management Network', net: sv.flbMgmt || {}, segOpts,
        nameTooltip:    tt('Segment name used for FLB management traffic. Must match a network segment defined for this site in Edge Sites.'),
        startTooltip:   tt('First IPv4 address of the IP block assigned to FLB management. Must fall within the gateway subnet of the selected segment.'),
        countTooltip:   tt('Number of consecutive IPs to allocate starting from Start IP. Minimum 2.'),
        gatewayTooltip: tt('Override the gateway for this FLB network. Leave blank to use the gateway from the matching infrastructure segment. Accepts IPv4 address or CIDR.'),
        noSegHint })}
    ${_renderFlbNetworkSection(site, {
        sectionKey: 'flbVirtualServerNet', idSuffix: 'flbVirtualServerNet',
        titleText: 'FLB Virtual Server Network', net: sv.flbVirtualServerNet || {}, segOpts,
        nameTooltip:    tt('Segment name used for FLB virtual server (VIP) traffic. Must match a network segment defined for this site in Edge Sites.'),
        startTooltip:   tt('First IPv4 address of the IP block for FLB virtual servers. Must fall within the gateway subnet of the selected segment.'),
        countTooltip:   tt('Number of consecutive IPs to allocate for virtual servers. Minimum 2.'),
        gatewayTooltip: tt('Override the gateway for this FLB virtual server network. Leave blank to use the gateway from the matching infrastructure segment.') })}
    <div style="font-size:12px;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:.04em;margin-bottom:10px;">Management Network Spec</div>
    <div class="grid-2" style="margin-bottom:16px;">
      <div class="field"><label>Network Name <span class="req">*</span>${tt('Segment used for Supervisor management traffic. Must match a network segment defined for this site in Edge Sites.')}</label>
        <select id="sup-${site.id}-mgmt-name" oninput="updateSupField(${site.id},'mgmt','mgmtNetworkName',this.value)">
          <option value="">-- select segment --</option>${segOpts(mgmt.mgmtNetworkName)}
        </select>
      </div>
      <div class="field"><label>Start IP <span class="req">*</span>${tt('First IPv4 address of the management IP block. Must fall within the gateway subnet of the selected segment.')}</label>
        <input type="text" value="${esc(mgmt.mgmtNetworkStartingIp)}" placeholder="10.30.13.100" oninput="updateSupField(${site.id},'mgmt','mgmtNetworkStartingIp',this.value)"></div>
      <div class="field"><label>IP Count <span class="req">*</span>${tt('Number of management IPs to allocate. Minimum 5 (control plane VMs + reserved).')}</label>
        <input type="number" value="${esc(mgmt.mgmtNetworkIPCount)}" placeholder="7" min="1" oninput="updateSupField(${site.id},'mgmt','mgmtNetworkIPCount',this.value)"></div>
    </div>
    <div style="font-size:12px;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:.04em;margin-bottom:10px;">Primary Workload Network</div>
    <div class="grid-2">
      <div class="field"><label>Network Name <span class="req">*</span>${tt('Segment used for Supervisor workload (pod) traffic. Must match a network segment defined for this site in Edge Sites.')}</label>
        <select id="sup-${site.id}-workloadNet-name" oninput="updateSupField(${site.id},'workloadNet','primaryWorkloadNetworkName',this.value)">
          <option value="">-- select segment --</option>${segOpts(workloadNet.primaryWorkloadNetworkName)}
        </select>
      </div>
      <div class="field"><label>Start IP <span class="req">*</span>${tt('First IPv4 address of the workload IP block. Must fall within the gateway subnet of the selected segment.')}</label>
        <input type="text" value="${esc(workloadNet.primaryWorkloadNetworkStartingIp)}" placeholder="10.30.10.101" oninput="updateSupField(${site.id},'workloadNet','primaryWorkloadNetworkStartingIp',this.value)"></div>
      <div class="field"><label>IP Count <span class="req">*</span>${tt('Number of workload IPs to allocate. Minimum 2.')}</label>
        <input type="number" value="${esc(workloadNet.primaryWorkloadNetworkIPCount)}" placeholder="100" min="1" oninput="updateSupField(${site.id},'workloadNet','primaryWorkloadNetworkIPCount',this.value)"></div>
      <div class="field"><label>Workload Service Start IP <span class="req">*</span>${tt('First IP of the Kubernetes service CIDR block for this site. Must be a valid IPv4 address (e.g. 10.97.0.0). Ensure this range does not overlap with physical network subnets.')}</label>
        <input type="text" value="${esc(workloadNet.workloadServiceStartIp)}" placeholder="10.97.0.0" oninput="updateSupField(${site.id},'workloadNet','workloadServiceStartIp',this.value)"></div>
      <div class="field"><label>Workload Service Count <span class="req">*</span> <span class="tip">must be power of 2</span>${tt('Size of the Kubernetes service IP pool. Must be a power of 2 so it aligns with a CIDR boundary (e.g. 256 = /24, 512 = /23, 1024 = /22).')}</label>
        <input type="number" value="${esc(workloadNet.workloadServiceCount)}" placeholder="512" min="1" oninput="updateSupField(${site.id},'workloadNet','workloadServiceCount',this.value)"></div>
    </div>
    </div>
  </div>`;
}

function updateSupField(siteId, section, field, value) {
  const site = sites.find(s => s.id === siteId);
  if (!site._supervisor) site._supervisor = {};
  if (!site._supervisor[section]) site._supervisor[section] = {};
  site._supervisor[section][field] = value;
}

// ---------------------------------------------------------------------------
// Build payload for server
// ---------------------------------------------------------------------------
function buildPayload() {
  const common = {
    vCenterName: v('vCenterName'),
    vCenterUser: v('vCenterUser'),
    contextName: v('contextName'),
    datacenterName: v('datacenterName'),
    nicList: commonNics.join(', '),
    esxUser: v('esxUser'),
    vSanWitnessVmName: v('vSanWitnessVmName'),
    haPolicy: v('haPolicy'),
    vLcmImageName: v('vLcmImageName'),
    vSanvMotionVmKernelMtuValue: v('vSanvMotionVmKernelMtuValue'),
    clusterNamePrefix: v('clusterNamePrefix'),
    datastoreNamePrefix: v('datastoreNamePrefix'),
    supervisorNamePrefix: v('supervisorNamePrefix'),
    vdsNamePrefix: v('vdsNamePrefix'),
    supervisorContentLibraryDatastore: v('supervisorContentLibraryDatastore'),
    esxUniquePasswordPerHost: !!(document.getElementById('esxUniquePasswordPerHost') || {}).checked,
    nonInteractivePassword: !!(document.getElementById('nonInteractivePassword') || {}).checked,
    autoUpdate: !!(document.getElementById('autoUpdate') || {}).checked,
    labenvironment: !!(document.getElementById('labenvironment') || {}).checked,
    preserveAutoGeneratedKeyCertPair: !!(document.getElementById('preserveAutoGeneratedKeyCertPair') || {}).checked,
    supervisorServices: {
      parentDirectory: v('svc_parentDirectory'),
      argoCdOperatorYamlFileName: v('svc_argoCdOperatorYamlFileName'),
      argoCdDeploymentYamlFileName: v('svc_argoCdDeploymentYamlFileName'),
      harborDataTemplateYamlFileName: v('svc_harborDataTemplateYamlFileName'),
      harborServiceYamlFileName: v('svc_harborServiceYamlFileName'),
      disableArgoCD: !!(document.getElementById('svc_disableArgoCD') || {}).checked,
      disableHarbor: !!(document.getElementById('svc_disableHarbor') || {}).checked,
    },
  };

  const clusters = sites.map(site => ({
    edgeSite: site.edgeSite,
    esxHosts: Array.isArray(site.esxHosts) ? site.esxHosts : (site.esxHosts || '').split(',').map(h => h.trim()).filter(Boolean),
    nicList: Array.isArray(site.nicList) ? site.nicList.join(', ') : '',
    vSanWitnessVmName: site.vSanWitnessVmName || '',
    haPolicy: site.haPolicy || '',
    storagePolicy: { storageType: site.storageType },
    harborConfiguration: site.harbor || {},
    supervisorServices: site.supervisorServices || {},
    networking: {
      networkSegments: site.segments || [],
      networkingVmKernelInterfaces: site.vmkInterfaces || [],
    },
  }));

  const commonSupervisorSpec = {
    controlPlaneVMCount: v('controlPlaneVMCount'),
    controlPlaneSize: v('controlPlaneSize'),
    flbAvailability: v('flbAvailability'),
    flbSize: v('flbSize'),
    flbNetworkType: v('flbNetworkType'),
    networkSearchDomains: v('networkSearchDomains'),
    networkNtpServers: v('networkNtpServers'),
    dnsServers: v('dnsServers'),
  };

  const siteSpec = sites.map(site => {
    const sv = site._supervisor || {};
    return {
      edgeSite: site.edgeSite,
      foundationLoadBalancerComponents: {
        ...sv.flb,
        flbManagementNetwork: sv.flbMgmt || {},
        flbVirtualServerNetwork: sv.flbVirtualServerNet || {},
      },
      mgmtNetworkSpec: sv.mgmt || {},
      primaryWorkloadNetwork: sv.workloadNet || {},
    };
  });

  return { infrastructure: { common, clusters }, supervisor: { commonSupervisorSpec, siteSpec } };
}

// ---------------------------------------------------------------------------
// Tooltip helper
// ---------------------------------------------------------------------------
function tt(text) {
  return `<span class="tt"><span class="tt-icon">?</span><span class="tt-body">${esc(text)}</span></span>`;
}

// ---------------------------------------------------------------------------
// Connectivity check helpers
// ---------------------------------------------------------------------------

function _renderConnResults(container, results) {
  container.innerHTML = results.map(r => {
    if (r.pending) {
      return `<div class="conn-row"><span class="conn-badge conn-spin"><span class="spinner"></span> checking…</span><span style="color:var(--text-muted);">${esc(r.host)}</span></div>`;
    }
    if (r.reachable && !r.error) {
      return `<div class="conn-row"><span class="conn-badge conn-ok">✓ ${r.latency_ms}ms</span><span>${esc(r.host)}</span></div>`;
    }
    if (r.reachable && r.error) {
      // TCP reachable but TLS handshake failed — host is up, TLS details differ.
      return `<div class="conn-row"><span class="conn-badge" style="background:rgba(240,165,0,0.15);border:1px solid var(--warning);color:var(--warning);">⚠ TCP ok ${r.latency_ms != null ? r.latency_ms+'ms' : ''}</span><span>${esc(r.host)}</span><span style="color:var(--text-muted);font-size:11px;">— ${esc(r.error)}</span></div>`;
    }
    return `<div class="conn-row"><span class="conn-badge conn-fail">✗ unreachable</span><span>${esc(r.host)}</span><span style="color:var(--text-muted);font-size:11px;">— ${esc(r.error || '')}</span></div>`;
  }).join('');
}

async function _runConnCheck(hosts, container) {
  if (!hosts.length) {
    container.innerHTML = '<div style="font-size:12px;color:var(--text-muted);">No hosts to check.</div>';
    return;
  }
  // Show pending state immediately so the user knows it started.
  _renderConnResults(container, hosts.map(h => ({ host: h, pending: true })));
  try {
    const resp = await fetch('/connectivity-check', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ hosts }),
    });
    const data = await resp.json();
    if (!resp.ok) {
      container.innerHTML = `<div style="font-size:12px;color:var(--error);">Check failed: ${esc(data.error || 'server error')}</div>`;
      return;
    }
    _renderConnResults(container, data.results);
  } catch (err) {
    container.innerHTML = `<div style="font-size:12px;color:var(--error);">Request failed: ${esc(String(err))}</div>`;
  }
}

function checkVcenterConnectivity() {
  const host = (document.getElementById('vCenterName') || {}).value.trim();
  const container = document.getElementById('vcenterConnResult');
  if (!host) {
    container.innerHTML = '<div style="font-size:12px;color:var(--warning);">Enter a vCenter FQDN first.</div>';
    return;
  }
  _runConnCheck([host], container);
}

function checkEsxConnectivity() {
  const container = document.getElementById('esxConnResults');
  const allHosts = [...new Set(sites.flatMap(site => (site.esxHosts || []).filter(Boolean)))];
  _runConnCheck(allHosts, container);
}

// ---------------------------------------------------------------------------
// Error grouping helpers
// ---------------------------------------------------------------------------

// Groups a flat message array (containing [ERROR], [WARNING], and [INFO] prefixed strings)
// by site and severity, returning an HTML string.
// [ERROR] messages appear in the red errors-box; [WARNING]/[INFO] messages appear in a
// separate amber advisory box so they are never confused with blocking validation failures.
function renderGroupedErrors(messages) {
  // Partition into blocking errors and warnings; [INFO] messages are not shown in the UI.
  const errorMsgs    = messages.filter(m => m.startsWith('[ERROR]'));
  const advisoryMsgs = messages.filter(m => m.startsWith('[WARNING]'));

  function _buildGroupedHtml(list) {
    const groups = {};
    const orderList = [];
    list.forEach(e => {
      const site = _extractSite(e);
      const label = site ? `Site: ${site}` : 'Common / Cross-file';
      if (!groups[label]) { groups[label] = []; orderList.push(label); }
      groups[label].push(site ? e.replace(/\["[^"]+"\]/, '[site]') : e);
    });
    let html = '';
    orderList.forEach(label => {
      const errs = groups[label];
      const isSite = label.startsWith('Site:');
      const headerStyle = isSite
        ? 'margin:10px 0 4px;padding:4px 8px;border-left:3px solid var(--accent);font-size:11px;font-weight:700;color:var(--accent);letter-spacing:0.05em;text-transform:uppercase;'
        : 'margin:10px 0 4px;padding:4px 8px;border-left:3px solid var(--text-muted);font-size:11px;font-weight:700;color:var(--text-muted);letter-spacing:0.05em;text-transform:uppercase;';
      html += `<div style="${headerStyle}">${esc(label)} <span style="font-weight:400;opacity:0.7;">(${errs.length})</span></div>`;
      html += `<ul style="margin:0 0 6px 12px;">`;
      errs.forEach(e => { html += `<li>${esc(e)}</li>`; });
      html += `</ul>`;
    });
    return html;
  }

  let html = '';

  if (errorMsgs.length > 0) {
    const siteLabels = [...new Set(errorMsgs.map(e => _extractSite(e)).filter(Boolean))];
    const subtitle = siteLabels.length > 0
      ? `${errorMsgs.length} error(s) across ${siteLabels.length} site(s)`
      : `${errorMsgs.length} error(s)`;
    html += `<div class="errors-box"><h3>⚠ Validation Errors — ${esc(subtitle)}</h3>${_buildGroupedHtml(errorMsgs)}</div>`;
  }

  if (advisoryMsgs.length > 0) {
    const count = advisoryMsgs.length;
    html += `<div style="background:rgba(240,165,0,0.08);border:1px solid var(--warning);border-radius:var(--radius);padding:14px 16px;margin-bottom:12px;">
      <h3 style="color:var(--warning);font-size:13px;margin-bottom:8px;">ℹ ${count} Advisory Note${count > 1 ? 's' : ''}</h3>
      ${_buildGroupedHtml(advisoryMsgs)}
    </div>`;
  }

  return html;
}

// ---------------------------------------------------------------------------
// Validate & preview
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Architecture diagram — pure SVG, zero external dependencies
// ---------------------------------------------------------------------------

// SVG colour constants — CSS variables cannot be read inside SVG attributes.
const _ARCH_COLORS = {
  bg:        '#1a1d23', surface:   '#22262f', surface2:  '#2a2f3a',
  border:    '#3a4050', accent:    '#00b4d8', accentDim: '#0096c7',
  purple:    '#7c5cbf', text:      '#e8eaf0', muted:     '#8892a4',
  label:     '#c4c9d4', // readable secondary text on dark backgrounds (replaces muted for text)
  success:   '#2ec27e', warning:   '#f0a500', error:     '#e05353',
};

// ─── Layout constants ────────────────────────────────────────────────────────
const _A = {
  M:        20,   // outer margin
  GAP:      22,   // gap between site columns
  COL_W:   400,   // width of each site column (wider for richer rows)
  SITE_HDR: 30,   // site column header height
  HOST_H:   22,   // height per ESX host row
  VDS_H:    32,   // VDS bar height
  VMK_H:    22,   // vmkernel connection row height
  NET_H:    22,   // height per supervisor network row
  SEG_H:    22,   // height per network segment row
  FLB_H:    40,   // FLB hero row height
  PAD:      10,   // inner padding
};

// ─── SVG primitive helpers ───────────────────────────────────────────────────

// Labelled section box with a coloured title bar.
function _svgSection(x, y, W, H, title, fillColor, borderColor, titleSize) {
  const C  = _ARCH_COLORS;
  const fS = titleSize || 9;
  let s = `<rect x="${x}" y="${y}" width="${W}" height="${H}" rx="4"
    fill="${fillColor}" fill-opacity="0.10" stroke="${borderColor}" stroke-width="1"/>`;
  s += `<rect x="${x}" y="${y}" width="${W}" height="17" rx="4"
    fill="${borderColor}" fill-opacity="0.35"/>`;
  s += `<text x="${x+8}" y="${y+12}" font-family="system-ui,sans-serif"
    font-size="${fS}" font-weight="700" fill="${C.text}">${_svgEsc(title)}</text>`;
  return s;
}

// Small coloured badge (rounded rect + centred label).
function _svgBadge(x, y, W, H, label, color) {
  const s1 = `<rect x="${x}" y="${y}" width="${W}" height="${H}" rx="3"
    fill="${color}" fill-opacity="0.2" stroke="${color}" stroke-width="0.7"/>`;
  const s2 = `<text x="${x+W/2}" y="${y+H-3}" text-anchor="middle"
    font-family="system-ui,sans-serif" font-size="8" fill="${color}">${_svgEsc(label)}</text>`;
  return s1 + s2;
}

// Connector arrow between two y positions at a given x centre.
function _svgConnector(cx, y1, y2, color) {
  return `<line x1="${cx}" y1="${y1}" x2="${cx}" y2="${y2-4}"
    stroke="${color}" stroke-width="1.2" stroke-dasharray="3,2"/>
  <polygon points="${cx},${y2} ${cx-4},${y2-6} ${cx+4},${y2-6}" fill="${color}"/>`;
}

// ─── Site column sub-renderers ────────────────────────────────────────────────

// Renders the ESX data hosts, vSAN witness, VDS bar, and VMkernel connection map.
// VMkernel rows are the key new element: each shows service | vmkN | VLAN | MTU | L2/L3 | IPs.
function _renderHostVdsBlock(x, y, W, hosts, nics, storage, vmkInterfaces, witnessVm, vdsName, mtu) {
  const C          = _ARCH_COLORS;
  const PAD        = _A.PAD;
  const isVsan     = storage.startsWith('vSAN');
  const storageColor = isVsan ? C.warning : C.accent;
  const hasWitness = !!(witnessVm && isVsan);

  // VMkernel service → colour mapping.
  const vmkColor = svc => {
    if (svc === 'vMotion')     return C.accent;
    if (svc === 'vSAN')        return C.warning;
    if (svc === 'vSAN Witness') return '#e07b39';
    return C.muted;
  };

  // Pre-calculate height.
  const hostH    = Math.max(1, hosts.length) * _A.HOST_H;
  const witnessH = hasWitness ? _A.HOST_H : 0;
  const vmkH     = vmkInterfaces && vmkInterfaces.length > 0
                 ? 14 + vmkInterfaces.length * _A.VMK_H : 0;
  const sectionH = 20 + hostH + witnessH + 14 + _A.VDS_H + 8 + vmkH + 6;

  let s = _svgSection(x, y, W, sectionH, 'ESX Hosts  ·  VDS  ·  VMkernel', C.accent, C.accentDim, 9);
  let ry = y + 20;

  // ESX data host rows.
  if (hosts.length === 0) {
    s += `<text x="${x+PAD}" y="${ry+13}" font-family="system-ui,sans-serif" font-size="9" fill="${C.label}">(no hosts configured)</text>`;
    ry += _A.HOST_H;
  }
  hosts.forEach((h, hi) => {
    s += `<rect x="${x+PAD}" y="${ry+1}" width="${W-PAD*2}" height="${_A.HOST_H-3}" rx="3"
      fill="${C.surface2}" stroke="${storageColor}" stroke-width="0.7" stroke-opacity="0.7"/>`;
    // Host index label on left, FQDN centred.
    s += `<text x="${x+PAD+5}" y="${ry+13}" font-family="system-ui,sans-serif"
      font-size="7.5" font-weight="700" fill="${storageColor}">ESX${hi+1}</text>`;
    s += `<text x="${x+PAD+34}" y="${ry+13}" font-family="'Consolas','Monaco',monospace"
      font-size="8" fill="${C.text}">${_svgEsc(h)}</text>`;
    ry += _A.HOST_H;
  });

  // vSAN Witness appliance row.
  if (hasWitness) {
    s += `<rect x="${x+PAD}" y="${ry+1}" width="${W-PAD*2}" height="${_A.HOST_H-3}" rx="3"
      fill="${C.surface2}" stroke="${C.warning}" stroke-width="1" stroke-dasharray="4,2"/>`;
    s += `<text x="${x+PAD+5}" y="${ry+13}" font-family="system-ui,sans-serif"
      font-size="7.5" font-weight="700" fill="${C.warning}">WIT</text>`;
    s += `<text x="${x+PAD+34}" y="${ry+13}" font-family="'Consolas','Monaco',monospace"
      font-size="8" fill="${C.label}">${_svgEsc(witnessVm)}</text>`;
    ry += _A.HOST_H;
  }

  // VDS bar — show actual VDS name if available, plus uplink NICs.
  const vdsY       = ry + 10;
  const displayVds = vdsName || 'VDS (vSphere Distributed Switch)';
  s += `<rect x="${x+PAD}" y="${vdsY}" width="${W-PAD*2}" height="${_A.VDS_H}" rx="4"
    fill="${C.accent}" fill-opacity="0.18" stroke="${C.accent}" stroke-width="1.4"/>`;
  s += `<text x="${x+PAD+8}" y="${vdsY+13}" font-family="system-ui,sans-serif"
    font-size="9.5" font-weight="700" fill="${C.accent}">${_svgEsc(displayVds)}</text>`;
  // Uplink NIC list right-aligned in VDS bar.
  const uplinkLabel = nics.length > 0 ? `uplinks: ${nics.join(', ')}` : '';
  if (uplinkLabel) {
    s += `<text x="${x+W-PAD-6}" y="${vdsY+26}" text-anchor="end"
      font-family="system-ui,sans-serif" font-size="7.5" fill="${C.accentDim}">${_svgEsc(uplinkLabel)}</text>`;
  }
  // Storage type badge in VDS bar.
  const storageBW = Math.max(52, storage.length * 6 + 10);
  s += `<rect x="${x+PAD+6}" y="${vdsY+17}" width="${storageBW}" height="12" rx="2"
    fill="${storageColor}" fill-opacity="0.22" stroke="${storageColor}" stroke-width="0.6"/>`;
  s += `<text x="${x+PAD+6+storageBW/2}" y="${vdsY+26}" text-anchor="middle"
    font-family="system-ui,sans-serif" font-size="7.5" fill="${storageColor}">${_svgEsc(storage)}</text>`;
  ry = vdsY + _A.VDS_H + 8;

  // VMkernel connection map — one row per interface, showing the full context.
  if (vmkInterfaces && vmkInterfaces.length > 0) {
    s += `<text x="${x+PAD}" y="${ry+11}" font-family="system-ui,sans-serif"
      font-size="7.5" font-weight="700" fill="${C.label}" letter-spacing="0.08em">VMK  SERVICE        VLAN   MTU    ROUTING   HOST IPs</text>`;
    ry += 14;
    vmkInterfaces.forEach((vmk, vi) => {
      const svc      = vmk.service || '';
      const col      = vmkColor(svc);
      const vlan     = vmk.vlanId !== undefined ? String(vmk.vlanId) : '—';
      const isWitnessSvc = svc === 'vSAN Witness';
      // MTU: witness is always 1500; others use the common mtu if set.
      const vmkMtu   = isWitnessSvc ? '1500' : (mtu ? String(mtu) : '—');
      // L2 vs L3: a gateway on the VMK means L3 routing to the witness subnet.
      const hasGw    = !!(vmk.gateway);
      const routing  = hasGw ? `L3 → ${vmk.gateway}` : 'L2';
      const routeCol = hasGw ? C.warning : C.success;
      const ips      = Array.isArray(vmk.ipList) ? vmk.ipList.join(' / ') : (vmk.ipList || '—');

      // Row background.
      s += `<rect x="${x+PAD}" y="${ry}" width="${W-PAD*2}" height="${_A.VMK_H-2}" rx="2"
        fill="${col}" fill-opacity="0.06" stroke="${col}" stroke-width="0.5"/>`;
      // Left colour bar indicates service type.
      s += `<rect x="${x+PAD}" y="${ry}" width="3" height="${_A.VMK_H-2}" rx="1"
        fill="${col}" fill-opacity="0.9"/>`;

      const tx = x + PAD + 7;
      // vmkN index.
      s += `<text x="${tx}" y="${ry+14}" font-family="system-ui,sans-serif"
        font-size="8" font-weight="700" fill="${C.label}">vmk${vi+1}</text>`;
      // Service name.
      s += `<text x="${tx+28}" y="${ry+14}" font-family="system-ui,sans-serif"
        font-size="8" font-weight="700" fill="${col}">${_svgEsc(svc)}</text>`;
      // VLAN badge.
      s += `<rect x="${tx+100}" y="${ry+3}" width="30" height="13" rx="2"
        fill="${col}" fill-opacity="0.2" stroke="${col}" stroke-width="0.5"/>`;
      s += `<text x="${tx+115}" y="${ry+13}" text-anchor="middle"
        font-family="system-ui,sans-serif" font-size="7.5" fill="${col}">${_svgEsc(vlan)}</text>`;
      // MTU.
      s += `<text x="${tx+135}" y="${ry+14}" font-family="system-ui,sans-serif"
        font-size="7.5" fill="${C.label}">${_svgEsc(vmkMtu)}</text>`;
      // L2/L3 routing indicator.
      s += `<text x="${tx+163}" y="${ry+14}" font-family="system-ui,sans-serif"
        font-size="7.5" font-weight="700" fill="${routeCol}">${_svgEsc(routing)}</text>`;
      // Host IPs — right portion, truncated if long.
      const ipMaxW = W - PAD*2 - 7 - 220;
      if (ipMaxW > 40) {
        s += `<text x="${x+W-PAD-4}" y="${ry+14}" text-anchor="end"
          font-family="'Consolas','Monaco',monospace" font-size="7.5" fill="${C.text}">${_svgEsc(ips)}</text>`;
      }
      ry += _A.VMK_H;
    });
  }

  const totalH = ry - y + 6;
  console.assert(totalH === sectionH, `_renderHostVdsBlock: sectionH=${sectionH} totalH=${totalH}`);
  return { svg: s, height: totalH };
}

// Renders supervisor-based networks with swim-lane style rows.
// Each network row shows: type label | segment name | VLAN | L2/L3 | IP range.
function _renderSupBlock(x, y, W, supSite, cs, svcSup) {
  const C       = _ARCH_COLORS;
  const PAD     = _A.PAD;
  const cp      = cs || {};
  const cpSize  = _iget(cp, 'controlPlaneSize',    'SMALL');
  const cpCount = _iget(cp, 'controlPlaneVMCount',  1);
  const flbAvail = _iget(cp, 'flbAvailability', '');
  const flbSize  = _iget(cp, 'flbSize', '');
  const flb      = _iget(supSite, 'foundationLoadBalancerComponents', {});
  const flbName  = _iget(flb, 'flbName', '');
  const flbVip   = _iget(flb, 'flbVipStartIP',  '');
  const flbVipCt = _iget(flb, 'flbVipIPCount',   '');
  const flbMgmt  = _iget(flb, 'flbManagementNetwork', {});
  const flbVsn   = _iget(flb, 'flbVirtualServerNetwork', {});
  const mgmt     = _iget(supSite, 'mgmtNetworkSpec', {});
  const workload = _iget(supSite, 'primaryWorkloadNetwork', {});
  const harborOn = (svcSup || {}).disableHarbor !== true;
  const argoOn   = (svcSup || {}).disableArgoCD !== true;

  // Build swim-lane definitions.  Each has: label | segName | isL3 (gateway present) |
  // ipStart | ipCount | color.
  const lanes = [
    mgmt.mgmtNetworkName ? {
      label: 'SUP MGMT', seg: mgmt.mgmtNetworkName, isL3: false,
      ip: mgmt.mgmtNetworkStartingIp, ct: mgmt.mgmtNetworkIPCount, color: C.purple,
    } : null,
    workload.primaryWorkloadNetworkName ? {
      label: 'WORKLOAD', seg: workload.primaryWorkloadNetworkName, isL3: false,
      ip: workload.primaryWorkloadNetworkStartingIp, ct: workload.primaryWorkloadNetworkIPCount,
      color: C.success,
    } : null,
    flbMgmt.flbNetworkName ? {
      label: 'FLB MGMT', seg: flbMgmt.flbNetworkName, isL3: false,
      ip: flbMgmt.flbNetworkIpAddressStartingIp, ct: flbMgmt.flbNetworkIpAddressCount, color: C.accent,
    } : null,
    flbVsn.flbNetworkName ? {
      label: 'FLB VSN', seg: flbVsn.flbNetworkName, isL3: false,
      ip: flbVsn.flbNetworkIpAddressStartingIp, ct: flbVsn.flbNetworkIpAddressCount, color: C.accent,
    } : null,
  ].filter(Boolean);

  // Height: header(20) + cp line(14) + lanes + FLB hero row + service badges(20) + pad(8).
  const hasFLB = !!(flbName || flbVip);
  const H = 20 + 14 + lanes.length * _A.NET_H + (hasFLB ? _A.FLB_H : 0) + 20 + 8;

  let s = _svgSection(x, y, W, H, 'Supervisor Networks', C.purple, C.purple, 9);
  let ry = y + 22;

  // Control plane info line.
  const cpLabel = `CP: ${cpCount}× ${cpSize}  ·  FLB: ${flbSize || '—'}${flbAvail ? '  (' + flbAvail.replace(/_/g,' ') + ')' : ''}`;
  s += `<text x="${x+PAD}" y="${ry}" font-family="system-ui,sans-serif"
    font-size="8" fill="${C.label}">${_svgEsc(cpLabel)}</text>`;
  ry += 14;

  // Swim-lane network rows.
  lanes.forEach(ln => {
    const NH = _A.NET_H;
    // Row background with left colour bar.
    s += `<rect x="${x+PAD}" y="${ry}" width="${W-PAD*2}" height="${NH-2}" rx="2"
      fill="${ln.color}" fill-opacity="0.07" stroke="${ln.color}" stroke-width="0.5"/>`;
    s += `<rect x="${x+PAD}" y="${ry}" width="3" height="${NH-2}" rx="1"
      fill="${ln.color}" fill-opacity="0.85"/>`;
    // Type label.
    s += `<text x="${x+PAD+7}" y="${ry+13}" font-family="system-ui,sans-serif"
      font-size="7.5" font-weight="700" fill="${ln.color}">${_svgEsc(ln.label)}</text>`;
    // Segment name.
    s += `<text x="${x+PAD+65}" y="${ry+13}" font-family="'Consolas','Monaco',monospace"
      font-size="7.5" fill="${C.text}">${_svgEsc(ln.seg)}</text>`;
    // L2 indicator (supervisor networks are L2 on the Supervisor-managed port groups).
    s += `<text x="${x+W-PAD-70}" y="${ry+13}" font-family="system-ui,sans-serif"
      font-size="7.5" font-weight="700" fill="${C.success}">L2</text>`;
    // IP range right-aligned.
    const ipInfo = ln.ip ? `${ln.ip}${ln.ct ? ' +' + ln.ct : ''}` : '';
    s += `<text x="${x+W-PAD-5}" y="${ry+13}" text-anchor="end"
      font-family="'Consolas','Monaco',monospace" font-size="7.5" fill="${C.label}">${_svgEsc(ipInfo)}</text>`;
    ry += NH;
  });

  // FLB hero row — end-user entry point prominently called out.
  if (hasFLB) {
    const fH = _A.FLB_H;
    s += `<rect x="${x+PAD}" y="${ry}" width="${W-PAD*2}" height="${fH}" rx="4"
      fill="${C.warning}" fill-opacity="0.12" stroke="${C.warning}" stroke-width="1.2"/>`;
    // Left accent bar.
    s += `<rect x="${x+PAD}" y="${ry}" width="4" height="${fH}" rx="2"
      fill="${C.warning}" fill-opacity="0.9"/>`;
    // "END USER →" label.
    s += `<text x="${x+PAD+10}" y="${ry+14}" font-family="system-ui,sans-serif"
      font-size="8" font-weight="700" fill="${C.warning}" letter-spacing="0.06em">END USER ENTRY</text>`;
    // Arrow glyph.
    s += `<text x="${x+PAD+10}" y="${ry+28}" font-family="system-ui,sans-serif"
      font-size="10" fill="${C.warning}">&#8594;</text>`;
    // FLB name large.
    s += `<text x="${x+PAD+28}" y="${ry+29}" font-family="system-ui,sans-serif"
      font-size="10" font-weight="700" fill="${C.text}">${_svgEsc(flbName || 'FLB')}</text>`;
    // VIP range right-aligned.
    const vipInfo = flbVip ? `VIP  ${flbVip}${flbVipCt ? '  (+' + flbVipCt + ')' : ''}` : '';
    if (vipInfo) {
      s += `<text x="${x+W-PAD-6}" y="${ry+29}" text-anchor="end"
        font-family="'Consolas','Monaco',monospace" font-size="8.5" fill="${C.warning}">${_svgEsc(vipInfo)}</text>`;
    }
    ry += fH;
  }

  // Service badges.
  const hc = harborOn ? C.success : C.error;
  const ac = argoOn   ? C.success : C.error;
  ry += 6;
  s += _svgBadge(x+PAD,      ry, 54, 14, harborOn ? 'Harbor ✓' : 'Harbor ✗', hc);
  s += _svgBadge(x+PAD+58,   ry, 56, 14, argoOn   ? 'Argo CD ✓' : 'Argo CD ✗', ac);

  return { svg: s, height: H };
}

// Renders the VDS network segments table (VLAN | name | L2/L3 | gateway).
// L3 is called out explicitly when a gateway is present on the segment.
function _renderVdsPortGroups(x, y, W, segs) {
  const C   = _ARCH_COLORS;
  const PAD = _A.PAD;
  if (segs.length === 0) return { svg: '', height: 0 };

  const titleH = 16;
  let s = `<text x="${x+PAD}" y="${y+titleH-3}" font-family="system-ui,sans-serif"
    font-size="7.5" font-weight="700" fill="${C.label}" letter-spacing="0.07em">NETWORK SEGMENTS (VDS PORT GROUPS)</text>`;
  // Column header row.
  let ry = y + titleH + 2;
  s += `<text x="${x+PAD+3}"  y="${ry+9}" font-family="system-ui,sans-serif" font-size="7" fill="${C.label}">VLAN</text>`;
  s += `<text x="${x+PAD+42}" y="${ry+9}" font-family="system-ui,sans-serif" font-size="7" fill="${C.label}">SEGMENT NAME</text>`;
  s += `<text x="${x+W-PAD-3}" y="${ry+9}" text-anchor="end" font-family="system-ui,sans-serif" font-size="7" fill="${C.label}">ROUTING / GATEWAY</text>`;
  ry += 11;

  segs.forEach(seg => {
    const H      = _A.SEG_H;
    const hasGw  = !!(seg.gateway);
    const routeColor = hasGw ? C.warning : C.success;
    const routeLabel = hasGw ? `L3` : `L2`;

    s += `<rect x="${x+PAD}" y="${ry}" width="${W-PAD*2}" height="${H-2}" rx="2"
      fill="${C.surface2}" stroke="${C.border}" stroke-width="0.4"/>`;
    // VLAN badge.
    s += `<rect x="${x+PAD+2}" y="${ry+3}" width="34" height="13" rx="2"
      fill="${C.accent}" fill-opacity="0.18" stroke="${C.accent}" stroke-width="0.5"/>`;
    s += `<text x="${x+PAD+19}" y="${ry+13}" text-anchor="middle"
      font-family="system-ui,sans-serif" font-size="8" fill="${C.accent}">${_svgEsc(String(seg.vlanId || ''))}</text>`;
    // Segment name.
    s += `<text x="${x+PAD+42}" y="${ry+13}" font-family="'Consolas','Monaco',monospace"
      font-size="7.5" fill="${C.text}">${_svgEsc(seg.name || '')}</text>`;
    // L2/L3 pill.
    s += `<text x="${x+W-PAD-6}" y="${ry+13}" text-anchor="end"
      font-family="system-ui,sans-serif" font-size="8" font-weight="700" fill="${routeColor}">${routeLabel}</text>`;
    // Gateway right-aligned (only when L3).
    if (hasGw) {
      s += `<text x="${x+W-PAD-18}" y="${ry+13}" text-anchor="end"
        font-family="'Consolas','Monaco',monospace" font-size="7.5" fill="${C.label}">${_svgEsc(seg.gateway)}</text>`;
    }
    ry += H;
  });
  return { svg: s, height: ry - y + 4 };
}

// Renders one complete edge site column. Returns { svg, height }.
// commonData is the infrastructure.common object, used for witness and MTU fallback.
function _renderSiteColumn(cl, supSite, cs, x, y, W, commonData) {
  const C        = _ARCH_COLORS;
  const PAD      = _A.PAD;
  const storage  = (cl.storagePolicy || {}).storageType || 'VMFS';
  const hosts    = Array.isArray(cl.esxHosts) ? cl.esxHosts : [];
  const segs     = ((cl.networking || {}).networkSegments || []);
  const vmks     = ((cl.networking || {}).networkingVmKernelInterfaces || []);
  const svcSup   = cl.supervisorServices || {};
  const nics     = (cl.nicList || []).map(n => typeof n === 'string' ? n : (n.name || '')).filter(Boolean);
  const haPolicy = cl.haPolicy || '';
  // Resolve witness and MTU: site-level overrides common-level.
  const witnessVm = cl.vSanWitnessVmName || (commonData || {}).vSanWitnessVmName || '';
  const mtu       = cl.vSanvMotionVmKernelMtuValue || (commonData || {}).vSanvMotionVmKernelMtuValue || 0;
  // Derive VDS display name from the prefix pattern {prefix}-{edgeSite}.
  const vdsPrefix = (commonData || {}).vdsNamePrefix;
  const vdsName   = vdsPrefix
    ? `${vdsPrefix}-${cl.edgeSite || ''}`
    : `VDS-${cl.edgeSite || '(unnamed)'}`;

  // Render all sub-blocks at their final positions in a single pass.
  // Each block is rendered once; heights are read from the returned objects.
  let curY = y + _A.SITE_HDR + 6;
  const hostVdsR = _renderHostVdsBlock(x, curY, W, hosts, nics, storage, vmks, witnessVm, vdsName, mtu);
  curY += hostVdsR.height + 8;
  const supR = _renderSupBlock(x + PAD, curY, W - PAD*2, supSite, cs, svcSup);
  curY += supR.height + 8;
  const pgR = _renderVdsPortGroups(x, curY, W, segs);

  const innerH = _A.SITE_HDR + 6
               + hostVdsR.height + 8
               + supR.height + 8
               + (pgR.height > 0 ? pgR.height + 4 : 0)
               + PAD;

  let s = '';
  // Outer column border (drawn first so sub-blocks render on top).
  s += `<rect x="${x}" y="${y}" width="${W}" height="${innerH}" rx="5"
    fill="${C.surface}" stroke="${C.accentDim}" stroke-width="1.2"/>`;

  // Site header.
  s += `<rect x="${x}" y="${y}" width="${W}" height="${_A.SITE_HDR}" rx="5"
    fill="${C.accentDim}" fill-opacity="0.22"/>`;
  s += `<text x="${x+PAD}" y="${y+18}" font-family="system-ui,sans-serif"
    font-size="12" font-weight="700" fill="${C.accent}">${_svgEsc(cl.edgeSite || '(unnamed)')}</text>`;
  // Storage + HA badges in header.
  const storageColor = storage.startsWith('vSAN') ? C.warning : C.accent;
  const bW = Math.max(44, storage.length * 5.8 + 10);
  s += `<rect x="${x+W-bW-6}" y="${y+7}" width="${bW}" height="14" rx="3"
    fill="${storageColor}" fill-opacity="0.22" stroke="${storageColor}" stroke-width="0.8"/>`;
  s += `<text x="${x+W-bW/2-6}" y="${y+17}" text-anchor="middle"
    font-family="system-ui,sans-serif" font-size="8" fill="${storageColor}">${_svgEsc(storage)}</text>`;
  if (haPolicy) {
    s += `<text x="${x+W-bW-12}" y="${y+17}" text-anchor="end"
      font-family="system-ui,sans-serif" font-size="7.5" fill="${C.label}">HA: ${_svgEsc(haPolicy)}</text>`;
  }

  // Append pre-rendered sub-blocks.
  s += hostVdsR.svg;
  s += supR.svg;
  if (pgR.height > 0) s += pgR.svg;

  return { svg: s, height: innerH };
}

// Renders the common header: vCenter, datacenter, user, NICs, and secondary infra info.
// DNS/NTP/Search are condensed into a single secondary line to keep the header compact.
function _renderCommonHeader(x, y, W, common, cs) {
  const C    = _ARCH_COLORS;
  const PAD  = _A.PAD;
  const nics = (common.nicList || []).map(n => (typeof n === 'string' ? n : (n.name || ''))).filter(Boolean);
  const dns  = (cs.dnsServers           || []).join(', ');
  const ntp  = (cs.networkNtpServers    || []).join(', ');
  const dom  = (cs.networkSearchDomains || []).join(', ');
  // Condense secondary info into a single line to keep the header tight.
  const secondary = [
    dns  ? `DNS: ${dns}`    : '',
    ntp  ? `NTP: ${ntp}`    : '',
    dom  ? `Search: ${dom}` : '',
  ].filter(Boolean).join('   ·   ');
  const H = secondary ? 54 : 42;

  let s = `<rect x="${x}" y="${y}" width="${W}" height="${H}" rx="5"
    fill="${C.surface}" stroke="${C.border}" stroke-width="1"/>`;
  // vCenter + DC on one line.
  s += `<text x="${x+PAD}" y="${y+16}" font-family="system-ui,sans-serif"
    font-size="12" font-weight="700" fill="${C.text}">vCenter: ${_svgEsc(common.vCenterName || '')}`;
  if (common.datacenterName) {
    s += `  <tspan font-size="9" fill="${C.label}">DC: ${_svgEsc(common.datacenterName)}</tspan>`;
  }
  s += `</text>`;
  // User + NICs on second line.
  s += `<text x="${x+PAD}" y="${y+30}" font-family="system-ui,sans-serif" font-size="8.5" fill="${C.label}">`;
  s += `User: ${_svgEsc(common.vCenterUser || '')}`;
  if (nics.length > 0) s += `   ·   NICs: ${_svgEsc(nics.join(', '))}`;
  s += `</text>`;
  // Condensed DNS/NTP/Search line.
  if (secondary) {
    s += `<text x="${x+PAD}" y="${y+43}" font-family="'Consolas','Monaco',monospace"
      font-size="7.5" fill="${C.label}">${_svgEsc(secondary)}</text>`;
  }
  s += `<text x="${x+W-PAD}" y="${y+H-5}" text-anchor="end" font-family="system-ui,sans-serif"
    font-size="7.5" fill="${C.label}" letter-spacing="0.05em">VCF INSTANCE — EDGE SITES</text>`;
  return { svg: s, height: H };
}

// Renders the Upstream Network footer block — VLAN summary across all sites.
// FLB hero rows and VIP information are now shown per-site inside the Supervisor block.
function _renderFlbFooter(x, y, W, clusters, siteSpec) {
  const C   = _ARCH_COLORS;
  const PAD = _A.PAD;

  // Collect unique VLAN IDs and their names from all site network segments.
  const vlanMap = new Map(); // vlanId (string) → segment name
  clusters.forEach(cl => {
    ((cl.networking || {}).networkSegments || []).forEach(seg => {
      const vid = seg.vlanId !== undefined && seg.vlanId !== null ? String(seg.vlanId) : '';
      if (vid !== '' && !vlanMap.has(vid)) vlanMap.set(vid, seg.name || '');
    });
  });
  const vlanList = Array.from(vlanMap.entries()).sort((a, b) => Number(a[0]) - Number(b[0]));

  const hasVlans = vlanList.length > 0;
  const H = 18 + (hasVlans ? 13 + vlanList.length * 14 : 0) + 8;

  let s = `<rect x="${x}" y="${y}" width="${W}" height="${H}" rx="4"
    fill="${C.surface2}" stroke="${C.accentDim}" stroke-width="1"/>`;
  s += `<text x="${x + W/2}" y="${y+13}" text-anchor="middle" font-family="system-ui,sans-serif"
    font-size="8.5" font-weight="700" fill="${C.accent}">UPSTREAM NETWORK — VLANs / LS Routing</text>`;
  let ry = y + 18;

  if (hasVlans) {
    // Column headers.
    s += `<text x="${x+PAD+3}"  y="${ry+10}" font-family="system-ui,sans-serif" font-size="7" fill="${C.label}">VLAN</text>`;
    s += `<text x="${x+PAD+42}" y="${ry+10}" font-family="system-ui,sans-serif" font-size="7" fill="${C.label}">SEGMENT NAME</text>`;
    ry += 13;

    vlanList.forEach(([vid, segName]) => {
      s += `<rect x="${x+PAD}" y="${ry}" width="${W-PAD*2}" height="13" rx="2"
        fill="${C.surface2}" stroke="${C.border}" stroke-width="0.3"/>`;
      // VLAN badge.
      s += `<rect x="${x+PAD+2}" y="${ry+1}" width="34" height="11" rx="2"
        fill="${C.accent}" fill-opacity="0.18" stroke="${C.accent}" stroke-width="0.5"/>`;
      s += `<text x="${x+PAD+19}" y="${ry+10}" text-anchor="middle"
        font-family="system-ui,sans-serif" font-size="7.5" fill="${C.accent}">${_svgEsc(vid)}</text>`;
      s += `<text x="${x+PAD+42}" y="${ry+10}" font-family="'Consolas','Monaco',monospace"
        font-size="7.5" fill="${C.label}">${_svgEsc(segName)}</text>`;
      ry += 14;
    });
  }

  console.assert(ry - y + 8 === H, `_renderFlbFooter: H=${H} ry-y=${ry-y}`);
  return { svg: s, height: H };
}

// ─── Swim-lane layout (2+ sites) ─────────────────────────────────────────────
//
// Structure (top → bottom, fixed canvas width):
//   1. Common header  — vCenter, DC, User, NICs
//   2. FLB hero band  — END USER → FLB name, VIP range
//   3. Supervisor band — per-site columns: CP info + named network swim-lanes
//   4. VDS band        — per-site sub-columns: VDS name, storage, host list, witness
//   5. VMkernel matrix — one shared row per service type, per-site IP cell
//   6. Segments table  — shared VLAN/name/L2-L3 reference rows
//   7. Upstream footer — "Upstream Network / LS Routing"

// Fixed canvas width for swim-lane mode.
const _SL_W   = 960;  // total SVG width
const _SL_M   =  18;  // outer margin
const _SL_GAP =   8;  // gap between per-site sub-columns inside a band
const _SL_BH  =  20;  // band header bar height

// Returns the inner content width.
function _slInnerW() { return _SL_W - _SL_M * 2; }

// Returns an array of { x, w } objects — one per site — that tile exactly across innerW.
// The last column absorbs any leftover pixels from integer division.
function _slCols(n, originX) {
  const inner  = _slInnerW();
  const base   = Math.floor((inner - (n - 1) * _SL_GAP) / n);
  const remainder = inner - (n - 1) * _SL_GAP - base * n;
  const cols = [];
  let cx = originX;
  for (let i = 0; i < n; i++) {
    const w = i === n - 1 ? base + remainder : base;
    cols.push({ x: cx, w });
    cx += w + _SL_GAP;
  }
  return cols;
}

// Draws a full-width band header: coloured title bar the full inner width.
function _slBandHeader(x, y, W, title, color, C) {
  let s = `<rect x="${x}" y="${y}" width="${W}" height="20" rx="3"
    fill="${color}" fill-opacity="0.25" stroke="${color}" stroke-width="0.8"/>`;
  s += `<text x="${x + W/2}" y="${y+14}" text-anchor="middle"
    font-family="system-ui,sans-serif" font-size="9" font-weight="700"
    fill="${C.text}" letter-spacing="0.05em">${_svgEsc(title)}</text>`;
  return s;
}

// Draws a thin horizontal rule labelled on the left.
function _slRule(x, y, W, label, color, C) {
  let s = `<line x1="${x}" y1="${y}" x2="${x+W}" y2="${y}"
    stroke="${color}" stroke-width="0.6" stroke-dasharray="4,3" stroke-opacity="0.5"/>`;
  if (label) {
    s += `<text x="${x+4}" y="${y-2}" font-family="system-ui,sans-serif"
      font-size="7" fill="${color}" opacity="0.8">${_svgEsc(label)}</text>`;
  }
  return s;
}

// Renders the FLB hero band (full width). Returns { svg, height }.
// Layout: standard band header (title + FLB info on one line) above site-column-aligned pills.
// Pills show only the FLB name — VIP details are omitted to keep the band compact.
function _slRenderFlbBand(x, y, W, clusters, siteSpec, cs, C) {
  const PAD      = 8;
  const flbAvail = _iget(cs, 'flbAvailability', '');
  const flbSize  = _iget(cs, 'flbSize', '');
  const n        = clusters.length;

  const entries = clusters.map(cl => {
    const sp  = (siteSpec || []).find(s => s.edgeSite === cl.edgeSite) || {};
    const flb = _iget(sp, 'foundationLoadBalancerComponents', {});
    const name = _iget(flb, 'flbName', '');
    return name ? { site: cl.edgeSite, name } : null;
  }).filter(Boolean);

  if (entries.length === 0) return { svg: '', height: 0 };

  const PILL_H = 26;
  const H      = _SL_BH + 6 + PILL_H + 6;

  // Title: "END USER ENTRY POINT · FLB: MEDIUM · SINGLE NODE" — size + avail on one line.
  const info  = [flbSize, flbAvail ? flbAvail.replace(/_/g, ' ') : ''].filter(Boolean).join(' · ');
  const title = info ? `END USER ENTRY POINT  ·  ${info}` : 'END USER ENTRY POINT';

  // Outer border + standard band header (header sits above pills).
  let s = `<rect x="${x}" y="${y}" width="${W}" height="${H}" rx="4"
    fill="none" stroke="${C.warning}" stroke-width="0.8" stroke-opacity="0.5"/>`;
  s += _slBandHeader(x, y, W, title, C.warning, C);

  // Pills: one per site column, FLB name only.
  const cols = _slCols(n, x);
  entries.forEach(e => {
    const siteIdx = clusters.findIndex(cl => cl.edgeSite === e.site);
    const col  = siteIdx >= 0 ? cols[siteIdx] : cols[0];
    const pillX = col.x + PAD;
    const pillW = col.w - PAD * 2;
    const midX  = col.x + col.w / 2;
    s += `<rect x="${pillX}" y="${y + _SL_BH + 6}" width="${pillW}" height="${PILL_H}" rx="4"
      fill="${C.warning}" fill-opacity="0.18" stroke="${C.warning}" stroke-width="0.9"/>`;
    s += `<text x="${midX}" y="${y + _SL_BH + 6 + PILL_H / 2 + 4}" text-anchor="middle"
      font-family="system-ui,sans-serif" font-size="9" font-weight="700"
      fill="${C.text}">${_svgEsc(e.name || e.site)}</text>`;
  });

  return { svg: s, height: H };
}

// Renders the supervisor band: one sub-column per site, each showing CP + network swim-lanes.
// Returns { svg, height }.
function _slRenderSupBand(x, y, innerW, clusters, siteSpec, cs, C) {
  const PAD  = 8;
  const n    = clusters.length;
  const cols = _slCols(n, x);

  // Calculate the tallest supervisor column so all sub-columns share the same height.
  const maxNets = Math.max(...clusters.map(cl => {
    const sp  = (siteSpec || []).find(s => s.edgeSite === cl.edgeSite) || {};
    const flb = _iget(sp, 'foundationLoadBalancerComponents', {});
    const mgmt = _iget(sp, 'mgmtNetworkSpec', {});
    const wl   = _iget(sp, 'primaryWorkloadNetwork', {});
    const flbM = _iget(flb, 'flbManagementNetwork', {});
    const flbV = _iget(flb, 'flbVirtualServerNetwork', {});
    return [mgmt.mgmtNetworkName, wl.primaryWorkloadNetworkName,
            flbM.flbNetworkName, flbV.flbNetworkName].filter(Boolean).length;
  }));
  const NET_H  = 20;
  const innerH = 32 + maxNets * NET_H + 10;
  const H      = _SL_BH + 4 + innerH;

  let s = _slBandHeader(x, y, innerW, 'SUPERVISOR — Kubernetes Control Plane & Networks', C.purple, C);

  clusters.forEach((cl, i) => {
    const { x: cx, w: colW } = cols[i];
    const sp     = (siteSpec || []).find(s => s.edgeSite === cl.edgeSite) || {};
    const cp     = cs || {};
    const flb    = _iget(sp, 'foundationLoadBalancerComponents', {});
    const mgmt   = _iget(sp, 'mgmtNetworkSpec', {});
    const wl     = _iget(sp, 'primaryWorkloadNetwork', {});
    const flbM   = _iget(flb, 'flbManagementNetwork', {});
    const flbV   = _iget(flb, 'flbVirtualServerNetwork', {});
    const svcSup = cl.supervisorServices || {};
    const harborOn = svcSup.disableHarbor !== true;
    const argoOn   = svcSup.disableArgoCD !== true;

    const bY = y + _SL_BH + 4;
    s += `<rect x="${cx}" y="${bY}" width="${colW}" height="${innerH}" rx="3"
      fill="${C.purple}" fill-opacity="0.07" stroke="${C.purple}" stroke-width="0.8"/>`;
    s += `<text x="${cx+PAD}" y="${bY+14}" font-family="system-ui,sans-serif"
      font-size="10" font-weight="700" fill="${C.purple}">${_svgEsc(cl.edgeSite || '(unnamed)')}</text>`;
    const hc = harborOn ? C.success : C.error;
    const ac = argoOn   ? C.success : C.error;
    s += _svgBadge(cx + colW - 116, bY + 3, 54, 13, harborOn ? 'Harbor ✓' : 'Harbor ✗', hc);
    s += _svgBadge(cx + colW - 58,  bY + 3, 54, 13, argoOn   ? 'Argo CD ✓' : 'Argo CD ✗', ac);

    const cpCount = _iget(cp, 'controlPlaneVMCount', 1);
    const cpSize  = _iget(cp, 'controlPlaneSize', 'SMALL');
    s += `<text x="${cx+PAD}" y="${bY+28}" font-family="system-ui,sans-serif"
      font-size="7.5" fill="${C.label}">CP: ${_svgEsc(String(cpCount))}× ${_svgEsc(cpSize)}</text>`;

    const lanes = [
      mgmt.mgmtNetworkName ? { label: 'SUP MGMT', seg: mgmt.mgmtNetworkName,
        ip: mgmt.mgmtNetworkStartingIp, ct: mgmt.mgmtNetworkIPCount, color: C.purple } : null,
      wl.primaryWorkloadNetworkName ? { label: 'WORKLOAD', seg: wl.primaryWorkloadNetworkName,
        ip: wl.primaryWorkloadNetworkStartingIp, ct: wl.primaryWorkloadNetworkIPCount, color: C.success } : null,
      flbM.flbNetworkName ? { label: 'FLB MGMT', seg: flbM.flbNetworkName,
        ip: flbM.flbNetworkIpAddressStartingIp, ct: flbM.flbNetworkIpAddressCount, color: C.accent } : null,
      flbV.flbNetworkName ? { label: 'FLB VSN', seg: flbV.flbNetworkName,
        ip: flbV.flbNetworkIpAddressStartingIp, ct: flbV.flbNetworkIpAddressCount, color: C.accent } : null,
    ].filter(Boolean);

    let ry = bY + 34;
    lanes.forEach(ln => {
      s += `<rect x="${cx+PAD}" y="${ry}" width="${colW-PAD*2}" height="${NET_H-2}" rx="2"
        fill="${ln.color}" fill-opacity="0.07" stroke="${ln.color}" stroke-width="0.5"/>`;
      // Left colour bar.
      s += `<rect x="${cx+PAD}" y="${ry}" width="3" height="${NET_H-2}" rx="1"
        fill="${ln.color}" fill-opacity="0.85"/>`;
      // Label (fixed 60px).
      s += `<text x="${cx+PAD+7}" y="${ry+13}" font-family="system-ui,sans-serif"
        font-size="7.5" font-weight="700" fill="${ln.color}">${_svgEsc(ln.label)}</text>`;
      // Segment name — plain monospace, no textLength/lengthAdjust (avoids letter-spacing artifacts).
      s += `<text x="${cx+PAD+60}" y="${ry+13}" font-family="'Consolas','Monaco',monospace"
        font-size="7" fill="${C.label}">${_svgEsc(ln.seg)}</text>`;
      // IP + count — bottom right, only if it fits.
      const ipInfo = ln.ip ? `${ln.ip}${ln.ct ? ' +' + ln.ct : ''}` : '';
      if (ipInfo && colW > 200) {
        s += `<text x="${cx+colW-PAD-4}" y="${ry+13}" text-anchor="end"
          font-family="'Consolas','Monaco',monospace" font-size="7" fill="${C.text}">${_svgEsc(ipInfo)}</text>`;
      }
      ry += NET_H;
    });
  });

  return { svg: s, height: H };
}

// Renders the VDS + ESX hosts band. One sub-column per site.
// Returns { svg, height }.
function _slRenderVdsBand(x, y, innerW, clusters, common, C) {
  const PAD  = 8;
  const n    = clusters.length;
  const cols = _slCols(n, x);

  const maxHosts = Math.max(...clusters.map(cl => {
    const isVsan = ((cl.storagePolicy || {}).storageType || 'VMFS').startsWith('vSAN');
    return Math.max(1, (cl.esxHosts || []).length) + (isVsan ? 1 : 0);
  }));
  const HOST_H    = 20;
  const DS_ROW_H  = 16;  // datastore name row below VDS bar
  const SITE_HDR_H = 18; // per-column site-name header (mirrors the Supervisor band pattern)
  const innerH    = SITE_HDR_H + 4 + _A.VDS_H + DS_ROW_H + 4 + maxHosts * HOST_H + 8;
  const H         = _SL_BH + 4 + innerH;

  let s = _slBandHeader(x, y, innerW, 'ESX HOSTS  ·  VDS (vSphere Distributed Switch)', C.accent, C);

  clusters.forEach((cl, i) => {
    const { x: cx, w: colW } = cols[i];
    const storage    = (cl.storagePolicy || {}).storageType || 'VMFS';
    const isVsan     = storage.startsWith('vSAN');
    const storageCol = isVsan ? C.warning : C.accent;
    const hosts      = Array.isArray(cl.esxHosts) ? cl.esxHosts : [];
    const nics       = (cl.nicList || []).map(nn => typeof nn === 'string' ? nn : (nn.name || '')).filter(Boolean);
    const witnessVm  = cl.vSanWitnessVmName || (common || {}).vSanWitnessVmName || '';
    const hasWitness = !!(witnessVm && isVsan);
    // VDS and datastore names follow the same pattern: {prefix}-{edgeSite}.
    // Defaults match PowerShell: vdsNamePrefix → "VDS", datastoreNamePrefix → "datastore".
    const vdsPrefix       = (common || {}).vdsNamePrefix       || 'VDS';
    const datastorePrefix = (common || {}).datastoreNamePrefix || 'datastore';
    const vdsName         = `${vdsPrefix}-${cl.edgeSite || '(unnamed)'}`;
    const datastoreName   = `${datastorePrefix}-${cl.edgeSite || '(unnamed)'}`;
    const haPolicy        = cl.haPolicy || '';

    const bY = y + _SL_BH + 4;
    s += `<rect x="${cx}" y="${bY}" width="${colW}" height="${innerH}" rx="3"
      fill="${C.accent}" fill-opacity="0.05" stroke="${C.accentDim}" stroke-width="0.8"/>`;

    // Per-column site-name header — matches the Supervisor band pattern so columns
    // align visually across bands as the eye scans down the diagram.
    s += `<text x="${cx+PAD}" y="${bY+SITE_HDR_H-3}" font-family="system-ui,sans-serif"
      font-size="10" font-weight="700" fill="${C.accent}">${_svgEsc(cl.edgeSite || '(unnamed)')}</text>`;

    // VDS bar — two clear rows: name (top) + storage badge + uplinks (bottom).
    // _A.VDS_H = 32px gives ~14px per row with 4px padding top/bottom.
    const VDS_BAR_Y = bY + SITE_HDR_H + 4;
    s += `<rect x="${cx+PAD}" y="${VDS_BAR_Y}" width="${colW-PAD*2}" height="${_A.VDS_H}" rx="3"
      fill="${C.accent}" fill-opacity="0.18" stroke="${C.accent}" stroke-width="1.2"/>`;
    // Row 1: VDS name large in accent color (primary identity of this column), HA right.
    s += `<text x="${cx+PAD+6}" y="${VDS_BAR_Y+13}" font-family="system-ui,sans-serif"
      font-size="9" font-weight="700" fill="${C.accent}">${_svgEsc(vdsName)}</text>`;
    if (haPolicy) {
      s += `<text x="${cx+colW-PAD-6}" y="${VDS_BAR_Y+13}" text-anchor="end"
        font-family="system-ui,sans-serif" font-size="7" fill="${C.text}">HA: ${_svgEsc(haPolicy)}</text>`;
    }
    // Row 2: storage type badge left + uplink NICs right.
    const storageBW = Math.max(52, storage.length * 5.5 + 8);
    s += `<rect x="${cx+PAD+4}" y="${VDS_BAR_Y+16}" width="${storageBW}" height="12" rx="2"
      fill="${storageCol}" fill-opacity="0.22" stroke="${storageCol}" stroke-width="0.5"/>`;
    s += `<text x="${cx+PAD+4+storageBW/2}" y="${VDS_BAR_Y+26}" text-anchor="middle"
      font-family="system-ui,sans-serif" font-size="7.5" fill="${storageCol}">${_svgEsc(storage)}</text>`;
    const uplinkStr = nics.length > 0 ? nics.join(', ') : '';
    if (uplinkStr) {
      s += `<text x="${cx+colW-PAD-6}" y="${VDS_BAR_Y+26}" text-anchor="end"
        font-family="system-ui,sans-serif" font-size="7" fill="${C.text}">${_svgEsc(uplinkStr)}</text>`;
    }

    // Datastore name row — immediately below VDS bar.
    const dsY = VDS_BAR_Y + _A.VDS_H + 1;
    s += `<text x="${cx+PAD+4}" y="${dsY+11}" font-family="system-ui,sans-serif"
      font-size="7" fill="${C.label}">DS: </text>`;
    s += `<text x="${cx+PAD+22}" y="${dsY+11}" font-family="'Consolas','Monaco',monospace"
      font-size="7.5" fill="${C.text}">${_svgEsc(datastoreName)}</text>`;

    // Host rows — below the VDS bar + DS row.
    let ry = VDS_BAR_Y + _A.VDS_H + DS_ROW_H + 4;
    if (hosts.length === 0) {
      s += `<text x="${cx+PAD}" y="${ry+12}" font-family="system-ui,sans-serif"
        font-size="8" fill="${C.label}">(no hosts)</text>`;
      ry += HOST_H;
    }
    hosts.forEach((h, hi) => {
      s += `<rect x="${cx+PAD}" y="${ry}" width="${colW-PAD*2}" height="${HOST_H-2}" rx="2"
        fill="${C.surface2}" stroke="${storageCol}" stroke-width="0.6" stroke-opacity="0.7"/>`;
      s += `<text x="${cx+PAD+4}" y="${ry+12}" font-family="system-ui,sans-serif"
        font-size="7.5" font-weight="700" fill="${storageCol}">ESX${hi+1}</text>`;
      s += `<text x="${cx+PAD+28}" y="${ry+12}" font-family="'Consolas','Monaco',monospace"
        font-size="7.5" fill="${C.text}">${_svgEsc(h)}</text>`;
      ry += HOST_H;
    });
    if (hasWitness) {
      s += `<rect x="${cx+PAD}" y="${ry}" width="${colW-PAD*2}" height="${HOST_H-2}" rx="2"
        fill="${C.surface2}" stroke="${C.warning}" stroke-width="1" stroke-dasharray="4,2"/>`;
      s += `<text x="${cx+PAD+4}" y="${ry+12}" font-family="system-ui,sans-serif"
        font-size="7.5" font-weight="700" fill="${C.warning}">Witness</text>`;
      s += `<text x="${cx+PAD+52}" y="${ry+12}" font-family="'Consolas','Monaco',monospace"
        font-size="7.5" fill="${C.label}">${_svgEsc(witnessVm)}</text>`;
    }
  });

  return { svg: s, height: H };
}

// Renders the VMkernel matrix band.
// Rows = unique service types. Left fixed-width label column; right = per-site IP cells.
// Returns { svg, height }.
function _slRenderVmkBand(x, y, innerW, clusters, common, C) {
  const n   = clusters.length;

  const vmkColor = svc => {
    if (svc === 'vMotion')      return C.accent;
    if (svc === 'vSAN')         return C.warning;
    if (svc === 'vSAN Witness') return '#e07b39';
    return C.muted;
  };

  const SVC_ORDER = ['vMotion', 'vSAN', 'vSAN Witness'];
  const usedSvcs  = SVC_ORDER.filter(svc =>
    clusters.some(cl =>
      ((cl.networking || {}).networkingVmKernelInterfaces || []).some(v => v.service === svc)
    )
  );
  if (usedSvcs.length === 0) return { svg: '', height: 0 };

  const ROW_H   = 28;
  const LABEL_W = 170;
  // IP cells tile the remaining width exactly using _slCols logic.
  const ipZoneW  = innerW - LABEL_W;
  const baseCell = Math.floor((ipZoneW - (n - 1) * 1) / n); // 1px dividers
  const lastExtra = ipZoneW - (n - 1) * 1 - baseCell * n;
  const cellWs   = clusters.map((_, i) => i === n - 1 ? baseCell + lastExtra : baseCell);
  const cellXs   = clusters.map((_, i) => {
    let cx = x + LABEL_W;
    for (let j = 0; j < i; j++) cx += cellWs[j] + 1;
    return cx;
  });

  const innerH = 18 + usedSvcs.length * ROW_H + 4;
  const H      = _SL_BH + 4 + innerH;

  let s = _slBandHeader(x, y, innerW, 'VMkernel Interfaces  (vMotion · vSAN · vSAN Witness)   —   Management VMK is configured at host level', C.accentDim, C);

  const bY = y + _SL_BH + 4;
  s += `<rect x="${x}" y="${bY}" width="${innerW}" height="${innerH}" rx="3"
    fill="${C.surface}" stroke="${C.border}" stroke-width="0.6"/>`;

  // Column headers.
  s += `<text x="${x + LABEL_W/2}" y="${bY+12}" text-anchor="middle"
    font-family="system-ui,sans-serif" font-size="7.5" font-weight="700"
    fill="${C.label}">SERVICE / VLAN / MTU / ROUTING</text>`;
  clusters.forEach((cl, i) => {
    s += `<text x="${cellXs[i] + cellWs[i]/2}" y="${bY+12}" text-anchor="middle"
      font-family="system-ui,sans-serif" font-size="7.5" font-weight="700"
      fill="${C.label}">${_svgEsc(cl.edgeSite || 'site' + (i+1))}</text>`;
  });
  // Header divider.
  s += `<line x1="${x}" y1="${bY+16}" x2="${x+innerW}" y2="${bY+16}"
    stroke="${C.border}" stroke-width="0.5"/>`;

  let ry = bY + 18;
  usedSvcs.forEach(svc => {
    const col = vmkColor(svc);
    s += `<rect x="${x}" y="${ry}" width="${innerW}" height="${ROW_H}"
      fill="${col}" fill-opacity="0.05"/>`;
    // Left colour bar.
    s += `<rect x="${x}" y="${ry}" width="4" height="${ROW_H}"
      fill="${col}" fill-opacity="0.9"/>`;
    // Service name.
    s += `<text x="${x+10}" y="${ry+ROW_H/2+4}" font-family="system-ui,sans-serif"
      font-size="8.5" font-weight="700" fill="${col}">${_svgEsc(svc)}</text>`;

    // Shared VLAN / MTU / routing (from first site that has this service).
    let sharedVlan = '—', sharedMtu = '—', isL3 = false, gwStr = '';
    clusters.forEach(cl => {
      const vmk = ((cl.networking || {}).networkingVmKernelInterfaces || [])
                    .find(v => v.service === svc);
      if (vmk && sharedVlan === '—') {
        sharedVlan = vmk.vlanId !== undefined ? String(vmk.vlanId) : '—';
        const mtu  = cl.vSanvMotionVmKernelMtuValue || (common || {}).vSanvMotionVmKernelMtuValue;
        sharedMtu  = svc === 'vSAN Witness' ? '1500' : (mtu ? String(mtu) : '—');
        isL3  = !!(vmk.gateway);
        gwStr = vmk.gateway || '';
      }
    });
    const routeCol = isL3 ? C.warning : C.success;

    // VLAN badge.
    s += `<rect x="${x+82}" y="${ry+6}" width="30" height="14" rx="2"
      fill="${col}" fill-opacity="0.22" stroke="${col}" stroke-width="0.5"/>`;
    s += `<text x="${x+97}" y="${ry+17}" text-anchor="middle"
      font-family="system-ui,sans-serif" font-size="8" fill="${col}">${_svgEsc(sharedVlan)}</text>`;
    s += `<text x="${x+116}" y="${ry+17}" font-family="system-ui,sans-serif"
      font-size="7.5" fill="${C.label}">${_svgEsc(sharedMtu)}</text>`;
    s += `<text x="${x+142}" y="${ry+17}" font-family="system-ui,sans-serif"
      font-size="7.5" font-weight="700" fill="${routeCol}">${isL3 ? 'L3' : 'L2'}</text>`;
    if (isL3 && gwStr) {
      s += `<text x="${x+158}" y="${ry+17}" font-family="'Consolas','Monaco',monospace"
        font-size="7" fill="${C.label}">${_svgEsc(gwStr)}</text>`;
    }

    // Vertical divider between label zone and IP cells.
    s += `<line x1="${x+LABEL_W}" y1="${ry}" x2="${x+LABEL_W}" y2="${ry+ROW_H}"
      stroke="${C.border}" stroke-width="0.5"/>`;

    // Per-site IP cells.
    clusters.forEach((cl, i) => {
      const vmk = ((cl.networking || {}).networkingVmKernelInterfaces || [])
                    .find(v => v.service === svc);
      const ips = vmk && Array.isArray(vmk.ipList) ? vmk.ipList : [];
      const cx  = cellXs[i];
      const cw  = cellWs[i];
      if (i > 0) {
        s += `<line x1="${cx}" y1="${ry}" x2="${cx}" y2="${ry+ROW_H}"
          stroke="${C.border}" stroke-width="0.4"/>`;
      }
      if (ips.length > 0) {
        ips.forEach((ip, ii) => {
          s += `<text x="${cx + cw/2}" y="${ry + 12 + ii * 13}" text-anchor="middle"
            font-family="'Consolas','Monaco',monospace" font-size="8" fill="${C.text}">${_svgEsc(ip)}</text>`;
        });
      } else {
        s += `<text x="${cx + cw/2}" y="${ry+ROW_H/2+4}" text-anchor="middle"
          font-family="system-ui,sans-serif" font-size="8" fill="${C.label}">—</text>`;
      }
    });

    // Row bottom border.
    s += `<line x1="${x}" y1="${ry+ROW_H}" x2="${x+innerW}" y2="${ry+ROW_H}"
      stroke="${C.border}" stroke-width="0.3"/>`;
    ry += ROW_H;
  });

  return { svg: s, height: H };
}

// Renders the network segments reference band.
// Segment names are already shown in the Supervisor band; this band shows the unique
// information: VLAN ID → segment name (for cross-reference) → routing / gateway.
// Layout: VLAN badge | segment name | L2/L3 | gateway CIDR
// Returns { svg, height }.
function _slRenderSegsBand(x, y, innerW, clusters, C) {
  const PAD = 10;
  const segMap = new Map();
  clusters.forEach(cl => {
    ((cl.networking || {}).networkSegments || []).forEach(seg => {
      const vid = seg.vlanId !== undefined ? String(seg.vlanId) : '';
      if (!segMap.has(vid)) segMap.set(vid, seg);
    });
  });
  const segs = Array.from(segMap.values()).sort((a, b) => Number(a.vlanId) - Number(b.vlanId));
  if (segs.length === 0) return { svg: '', height: 0 };

  const ROW_H  = 18;
  const innerH = 18 + segs.length * ROW_H + 4;
  const H      = _SL_BH + 4 + innerH;

  let s = _slBandHeader(x, y, innerW, 'NETWORK SEGMENTS — VLAN to Routing Reference (VDS Port Groups)', C.border, C);
  const bY = y + _SL_BH + 4;
  s += `<rect x="${x}" y="${bY}" width="${innerW}" height="${innerH}" rx="3"
    fill="${C.surface}" stroke="${C.border}" stroke-width="0.6"/>`;

  // Column headers.
  s += `<text x="${x+PAD+17}" y="${bY+12}" text-anchor="middle"
    font-family="system-ui,sans-serif" font-size="7" font-weight="700" fill="${C.accent}">VLAN</text>`;
  s += `<text x="${x+PAD+52}" y="${bY+12}"
    font-family="system-ui,sans-serif" font-size="7" font-weight="700" fill="${C.accent}">SEGMENT</text>`;
  s += `<text x="${x+innerW-PAD-4}" y="${bY+12}" text-anchor="end"
    font-family="system-ui,sans-serif" font-size="7" font-weight="700" fill="${C.accent}">GATEWAY</text>`;
  s += `<line x1="${x}" y1="${bY+15}" x2="${x+innerW}" y2="${bY+15}"
    stroke="${C.border}" stroke-width="0.5"/>`;

  let ry = bY + 18;
  segs.forEach(seg => {
    const hasGw    = !!(seg.gateway);
    const routeCol = hasGw ? C.warning : C.success;
    // Alternating row tint for readability.
    s += `<rect x="${x}" y="${ry}" width="${innerW}" height="${ROW_H}"
      fill="${C.surface2}" stroke="${C.border}" stroke-width="0.2"/>`;
    // VLAN badge.
    s += `<rect x="${x+PAD}" y="${ry+3}" width="34" height="12" rx="2"
      fill="${C.accent}" fill-opacity="0.2" stroke="${C.accent}" stroke-width="0.5"/>`;
    s += `<text x="${x+PAD+17}" y="${ry+13}" text-anchor="middle"
      font-family="system-ui,sans-serif" font-size="8" fill="${C.accent}">${_svgEsc(String(seg.vlanId || ''))}</text>`;
    // Segment name (kept for VLAN cross-reference, rendered in readable white).
    s += `<text x="${x+PAD+48}" y="${ry+13}"
      font-family="'Consolas','Monaco',monospace" font-size="8" fill="${C.text}">${_svgEsc(seg.name || '')}</text>`;
    // Routing column: gateway CIDR for L3 entries, nothing for L2.
    if (hasGw) {
      s += `<text x="${x+innerW-PAD-4}" y="${ry+13}" text-anchor="end"
        font-family="'Consolas','Monaco',monospace" font-size="8" fill="${C.text}">${_svgEsc(seg.gateway)}</text>`;
    }
    ry += ROW_H;
  });

  return { svg: s, height: H };
}

// Renders the upstream network footer band. Returns { svg, height }.
function _slRenderUpstreamBand(x, y, innerW, C) {
  const H = 28;
  let s = `<rect x="${x}" y="${y}" width="${innerW}" height="${H}" rx="4"
    fill="${C.accentDim}" fill-opacity="0.12" stroke="${C.accentDim}" stroke-width="1"/>`;
  s += `<text x="${x + innerW/2}" y="${y+18}" text-anchor="middle"
    font-family="system-ui,sans-serif" font-size="9" font-weight="700"
    fill="${C.accent}" letter-spacing="0.05em">UPSTREAM NETWORK — VLANs / LS Routing</text>`;
  return { svg: s, height: H };
}

// Draws a vertical connector arrow between two bands.
// Draws N short arrows — one centred over each per-site sub-column.
function _slBandConnector(x, y1, y2, clusters, color, C) {
  const n    = clusters.length;
  const cols = _slCols(n, x);
  let s = '';
  cols.forEach(col => {
    const cx  = col.x + col.w / 2;
    const mid = (y1 + y2) / 2;
    s += `<line x1="${cx}" y1="${y1+2}" x2="${cx}" y2="${y2-4}"
      stroke="${color}" stroke-width="1.2" stroke-dasharray="3,2" stroke-opacity="0.7"/>`;
    s += `<polygon points="${cx},${y2} ${cx-4},${y2-6} ${cx+4},${y2-6}"
      fill="${color}" fill-opacity="0.8"/>`;
  });
  return s;
}

// Builds the swim-lane SVG for 2+ sites.
function _buildSwimLaneSvg(infra, sup) {
  const C      = _ARCH_COLORS;
  const M      = _SL_M;
  const GAP    = 14;   // vertical gap between bands (connector arrows live here)
  const totalW = _SL_W;
  const innerW = _slInnerW();

  const clusters = infra.clusters || [];
  const siteSpec = _iget(sup, 'siteSpec', []);
  const common   = infra.common || {};
  const cs       = _iget(sup, 'commonSupervisorSpec', {});

  // Collect all bands with heights first so we can draw connectors in a second pass.
  let bands = [];
  let curY  = M;

  const hdr = _renderCommonHeader(M, curY, innerW, common, cs);
  bands.push({ svg: hdr.svg, y: curY, h: hdr.height, connector: false });
  curY += hdr.height + GAP;

  const flbBand = _slRenderFlbBand(M, curY, innerW, clusters, siteSpec, cs, C);
  if (flbBand.height > 0) {
    bands.push({ svg: flbBand.svg, y: curY, h: flbBand.height, connector: true, color: C.warning });
    curY += flbBand.height + GAP;
  }

  const supBand = _slRenderSupBand(M, curY, innerW, clusters, siteSpec, cs, C);
  bands.push({ svg: supBand.svg, y: curY, h: supBand.height, connector: true, color: C.purple });
  curY += supBand.height + GAP;

  const vdsBand = _slRenderVdsBand(M, curY, innerW, clusters, common, C);
  bands.push({ svg: vdsBand.svg, y: curY, h: vdsBand.height, connector: true, color: C.accent });
  curY += vdsBand.height + GAP;

  const vmkBand = _slRenderVmkBand(M, curY, innerW, clusters, common, C);
  if (vmkBand.height > 0) {
    bands.push({ svg: vmkBand.svg, y: curY, h: vmkBand.height, connector: true, color: C.accentDim });
    curY += vmkBand.height + GAP;
  }

  const segBand = _slRenderSegsBand(M, curY, innerW, clusters, C);
  if (segBand.height > 0) {
    bands.push({ svg: segBand.svg, y: curY, h: segBand.height, connector: true, color: C.border });
    curY += segBand.height + GAP;
  }

  const upBand = _slRenderUpstreamBand(M, curY, innerW, C);
  bands.push({ svg: upBand.svg, y: curY, h: upBand.height, connector: false });
  curY += upBand.height + M;

  // Build body: band SVG + connector arrows between consecutive bands.
  let body = '';
  bands.forEach((band, bi) => {
    body += band.svg;
    if (band.connector && bi + 1 < bands.length) {
      const y1 = band.y + band.h;
      const y2 = bands[bi + 1].y;
      body += _slBandConnector(M, y1, y2, clusters, band.color, C);
    }
  });

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${totalW} ${curY}"
    width="${totalW}" height="${curY}">
    <rect width="${totalW}" height="${curY}" fill="${C.bg}"/>
    ${body}
  </svg>`;
}

// Builds the full SVG string from infra + supervisor payload objects.
// Auto-selects swim-lane layout (≥2 sites) vs single-column layout (1 site).
function _buildArchSvg(infra, sup) {
  const C   = _ARCH_COLORS;
  const M   = _A.M;
  const GAP = _A.GAP;
  const W   = _A.COL_W;

  const clusters = infra.clusters || [];

  // Guard: nothing to draw yet.
  if (clusters.length === 0) {
    const svgW = W * 2 + M * 2;
    const svgH = 120;
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${svgW} ${svgH}" width="${svgW}" height="${svgH}">
      <rect width="${svgW}" height="${svgH}" fill="${C.bg}"/>
      <text x="${svgW/2}" y="${svgH/2+5}" text-anchor="middle"
        font-family="system-ui,sans-serif" font-size="13" fill="${C.label}">No edge sites configured yet.</text>
    </svg>`;
  }

  // 2+ sites: use the fixed-width swim-lane topology diagram.
  if (clusters.length >= 2) return _buildSwimLaneSvg(infra, sup);

  const siteSpec = _iget(sup, 'siteSpec', []);
  const common   = infra.common || {};
  // commonSupervisorSpec is flat on the cs object — pass it directly to renderers.
  const cs = _iget(sup, 'commonSupervisorSpec', {});

  const totalW = M * 2 + clusters.length * W + (clusters.length - 1) * GAP;

  // Render all sections once — cache svg + height to avoid duplicate calls.
  const hdr  = _renderCommonHeader(M, M, totalW - M * 2, common, cs);
  const topY = M + hdr.height + GAP;

  // Site columns rendered at y=0; translate group positions them at topY.
  const colData = clusters.map((cl, i) => {
    const supSite = (siteSpec || []).find(s => s.edgeSite === cl.edgeSite) || {};
    const x = M + i * (W + GAP);
    const rendered = _renderSiteColumn(cl, supSite, cs, x, 0, W, common);
    return { height: rendered.height, svg: rendered.svg };
  });
  const maxColH = Math.max(...colData.map(c => c.height));

  const ftr    = _renderFlbFooter(M, topY + maxColH + GAP, totalW - M * 2, clusters, siteSpec);
  const totalH = topY + maxColH + GAP + ftr.height + M;

  let body = '';
  body += hdr.svg;

  // Site columns — wrapped in a translate group to shift from y=0 to topY.
  body += `<g transform="translate(0,${topY})">`;
  colData.forEach(col => { body += col.svg; });
  body += `</g>`;

  body += ftr.svg;

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${totalW} ${totalH}"
    width="${totalW}" height="${totalH}">
    <rect width="${totalW}" height="${totalH}" fill="${C.bg}"/>
    ${body}
  </svg>`;
}

// Escapes text for safe embedding in SVG text elements.
function _svgEsc(s) {
  return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function renderArchitectureDiagram(infra, sup) {
  const details = document.getElementById('archDiagramDetails');
  const el      = document.getElementById('architectureDiagram');
  if (!el || !infra) { if (details) details.style.display = 'none'; return; }
  try {
    el.innerHTML = _buildArchSvg(infra, sup || {});
    if (details) details.style.display = '';
  } catch (e) {
    el.innerHTML = `<p style="color:var(--error);font-size:12px;">Diagram error: ${esc(String(e))}</p>`;
    if (details) details.style.display = '';
  }
}

function copySvgDiagram() {
  const svgData = _getExportSvgString();
  if (!svgData) return;
  navigator.clipboard.writeText(svgData).catch(() => {});
}

// Serialises the architecture SVG for export.
// Strips fixed width/height so the file scales to its viewBox in any viewer —
// making the SVG resolution-independent (Figma, Inkscape, PowerPoint, browsers).
function _getExportSvgString() {
  const svgEl = document.querySelector('#architectureDiagram svg');
  if (!svgEl) return null;
  // Clone so we don't mutate the live DOM element.
  const clone = svgEl.cloneNode(true);
  clone.removeAttribute('width');
  clone.removeAttribute('height');
  return new XMLSerializer().serializeToString(clone);
}

// Downloads the architecture diagram as a scalable SVG file.
function downloadSvgDiagram() {
  const svgData = _getExportSvgString();
  if (!svgData) return;
  const b64 = btoa(unescape(encodeURIComponent(svgData)));
  const a = document.createElement('a');
  a.download = 'vcf-edge-architecture.svg';
  a.href = 'data:image/svg+xml;base64,' + b64;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
}

// Downloads the architecture diagram as a high-resolution PNG (2× by default).
// The SVG is drawn into an off-screen canvas at the requested scale factor,
// then exported as a lossless PNG.  System fonts may fall back to sans-serif in
// the rasterised output — the SVG download is the canonical high-fidelity export.
function downloadPngDiagram(scale) {
  const svgEl = document.querySelector('#architectureDiagram svg');
  if (!svgEl) return;
  const px  = parseFloat(scale) || 2;
  const vb  = svgEl.viewBox.baseVal;
  // Always derive canvas dimensions from the SVG viewBox — _buildArchSvg always sets
  // an explicit viewBox, so vb.width/height are never zero after a render.
  // getBoundingClientRect().width is intentionally avoided: it returns the CSS-scaled
  // pixel size, not the logical SVG coordinate space, which produces wrong canvas sizes.
  if (!vb.width || !vb.height) return;
  const svgW = vb.width;
  const svgH = vb.height;
  const svgData = _getExportSvgString();
  if (!svgData) return;
  const img = new Image();
  img.onload = function () {
    const cvs = document.createElement('canvas');
    cvs.width  = Math.round(svgW * px);
    cvs.height = Math.round(svgH * px);
    const ctx  = cvs.getContext('2d');
    ctx.scale(px, px);
    ctx.drawImage(img, 0, 0);
    const a = document.createElement('a');
    a.download = `vcf-edge-architecture-${px}x.png`;
    a.href = cvs.toDataURL('image/png');
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  };
  img.src = 'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(svgData)));
}

async function refreshPreview() {
  const btn = document.getElementById('refreshBtn');
  btn.innerHTML = '<span class="spinner"></span> Validating...';
  btn.disabled = true;

  try {
    const payload = buildPayload();
    const resp = await fetch('/validate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const result = await resp.json();

    const resultsDiv = document.getElementById('validationResults');
    const allMessages = result.errors || [];
    const hasErrors = allMessages.some(m => m.startsWith('[ERROR]'));
    if (allMessages.length > 0) {
      resultsDiv.innerHTML = renderGroupedErrors(allMessages);
    } else {
      resultsDiv.innerHTML = `<div class="success-box"><h3>✓ Configuration is valid</h3><p>All required fields and cross-file constraints pass. Ready to save or download.</p></div>`;
    }
    document.getElementById('downloadBtn').disabled = hasErrors;
    document.getElementById('saveBtn').disabled = hasErrors;

    document.getElementById('infraPreview').textContent = JSON.stringify(result.infrastructure, null, 2) || '';
    document.getElementById('supervisorPreview').textContent = JSON.stringify(result.supervisor, null, 2) || '';
    buildChangeSummary(result.infrastructure || {}, result.supervisor || {}, _loadedSnapshot);
    renderArchitectureDiagram(result.infrastructure || {}, result.supervisor || {});
  } catch (err) {
    document.getElementById('validationResults').innerHTML =
      `<div class="errors-box"><h3>Request Error</h3><ul><li>${esc(String(err))}</li></ul></div>`;
  } finally {
    btn.innerHTML = 'Refresh Preview';
    btn.disabled = false;
  }
}

async function downloadZip() {
  const btn = document.getElementById('downloadBtn');
  const resultsDiv = document.getElementById('validationResults');
  btn.innerHTML = '<span class="spinner"></span> Generating...';
  btn.disabled = true;
  try {
    const payload = buildPayload();
    const resp = await fetch('/generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!resp.ok) {
      const err = await resp.json().catch(() => ({}));
      const errs = err.errors || ['Server error — check the console for details.'];
      resultsDiv.innerHTML = renderGroupedErrors(errs);
      return;
    }
    const blob = await resp.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'vcf-edge-config.zip';
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    // Revoke after a short delay so the browser has time to initiate the download.
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (err) {
    resultsDiv.innerHTML = `<div class="errors-box"><h3>Download failed</h3><ul><li>${esc(String(err))}</li></ul></div>`;
  } finally {
    btn.innerHTML = '⬇ Download ZIP';
    btn.disabled = false;
  }
}

// ---------------------------------------------------------------------------
// Save to base directory
// ---------------------------------------------------------------------------
async function saveToBaseDir() {
  const btn = document.getElementById('saveBtn');
  const resultDiv = document.getElementById('saveResult');
  btn.innerHTML = '<span class="spinner"></span> Saving...';
  btn.disabled = true;
  resultDiv.style.display = 'none';

  try {
    const payload = buildPayload();
    const resp = await fetch('/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const result = await resp.json();

    if (!resp.ok || result.errors) {
      resultDiv.style.display = 'block';
      resultDiv.innerHTML = `<div class="errors-box"><h3>Save failed</h3><ul>${
        (result.errors || [result.error || 'Unknown error']).map(e => `<li>${esc(e)}</li>`).join('')
      }</ul></div>`;
    } else {
      resultDiv.style.display = 'block';
      const backups = result.backups || [];
      const backupHtml = backups.length > 0
        ? `<div style="margin-top:12px;padding:10px 12px;background:rgba(0,0,0,0.2);border-radius:6px;border:1px solid var(--border);">
             <p style="font-size:11px;font-weight:600;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:6px;">📦 Backup copies created</p>
             ${backups.map(b => `<p style="font-size:12px;color:var(--text-muted);font-family:monospace;word-break:break-all;">↳ ${esc(b)}</p>`).join('')}
           </div>`
        : `<p style="margin-top:8px;font-size:12px;color:var(--text-muted);">No existing files — no backup needed.</p>`;
      resultDiv.innerHTML = `<div class="success-box">
        <h3>✓ Saved successfully</h3>
        <p>Written to: <code style="font-family:monospace;font-size:12px;">${esc(result.base_dir)}</code></p>
        ${backupHtml}
      </div>`;
    }
  } catch (err) {
    resultDiv.style.display = 'block';
    resultDiv.innerHTML = `<div class="errors-box"><h3>Save failed</h3><ul><li>${esc(String(err))}</li></ul></div>`;
  } finally {
    btn.innerHTML = '💾 Save to Base Dir';
    btn.disabled = false;
  }
}

// ---------------------------------------------------------------------------
// Tab switching
// ---------------------------------------------------------------------------
function switchTab(name) {
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === name));
  document.getElementById('infraPreview').style.display = name === 'infra' ? 'block' : 'none';
  document.getElementById('supervisorPreview').style.display = name === 'supervisor' ? 'block' : 'none';
}

function _flashCopyBtn() {
  const btn = document.getElementById('copyJsonBtn');
  if (!btn) return;
  const orig = btn.innerHTML;
  btn.innerHTML = '✓ Copied!';
  btn.style.color = 'var(--success)';
  btn.style.borderColor = 'var(--success)';
  setTimeout(() => { btn.innerHTML = orig; btn.style.color = ''; btn.style.borderColor = ''; }, 1800);
}

function copyActiveJson() {
  const activeTab = document.querySelector('.tab.active');
  const name = activeTab ? activeTab.dataset.tab : 'infra';
  const el = document.getElementById(name === 'infra' ? 'infraPreview' : 'supervisorPreview');
  const text = el ? el.textContent : '';
  if (!text.trim()) return;
  navigator.clipboard.writeText(text).then(_flashCopyBtn).catch(() => {
    // Fallback for browsers where clipboard API is unavailable (e.g. non-secure context).
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
    _flashCopyBtn();
  });
}

// ---------------------------------------------------------------------------
// Change summary (Step 4)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Configuration Summary helpers
// These three helpers are called by buildChangeSummary() and are each focused
// on a single job, keeping buildChangeSummary itself under 20 lines.
// ---------------------------------------------------------------------------

// Shared service badge used in both the summary table and the site block renderer.
const _summaryServiceBadge = (disabled, label) => disabled
  ? `<span style="font-size:10px;padding:1px 6px;border-radius:3px;background:rgba(136,146,164,0.15);color:var(--text-muted);">${label} off</span>`
  : `<span style="font-size:10px;padding:1px 6px;border-radius:3px;background:rgba(46,194,126,0.12);color:var(--success);">${label}</span>`;

// Builds the summary table + supervisor spec panel HTML string.
// infra and sup come from the server-validated (camelCase) result objects.
function _buildSummaryTableHtml(infra, sup) {
  const common    = infra.common || {};
  const clusters  = infra.clusters || [];
  const supCommon = sup.commonSupervisorSpec || {};

  const siteRows = clusters.map(cl => {
    const storage = (cl.storagePolicy || {}).storageType || '?';
    const segments = ((cl.networking || {}).networkSegments || []);
    const harborDisabled = ((cl.supervisorServices || {}).disableHarbor === true) ||
                           (!!(common.supervisorServices || {}).disableHarbor && (cl.supervisorServices || {}).disableHarbor !== false);
    const argoDisabled   = ((cl.supervisorServices || {}).disableArgoCD === true) ||
                           (!!(common.supervisorServices || {}).disableArgoCD && (cl.supervisorServices || {}).disableArgoCD !== false);
    const vlanList = segments.map(s =>
      `<span style="display:inline-block;font-family:monospace;font-size:10px;padding:1px 5px;border-radius:3px;background:var(--surface2);border:1px solid var(--border);margin:1px;" title="${esc(s.name)}">${esc(String(s.vlanId))}</span>`
    ).join('');
    return `
      <tr style="border-top:1px solid var(--border);">
        <td style="padding:7px 10px;font-weight:600;white-space:nowrap;">${esc(cl.edgeSite || '?')}</td>
        <td style="padding:7px 10px;">${esc(storage)}</td>
        <td style="padding:7px 10px;">${(cl.esxHosts || []).map(h => `<div style="font-size:11px;font-family:monospace;">${esc(h)}</div>`).join('')}</td>
        <td style="padding:7px 10px;">${vlanList || '—'}</td>
        <td style="padding:7px 10px;font-size:11px;">${_summaryServiceBadge(harborDisabled, 'Harbor')} ${_summaryServiceBadge(argoDisabled, 'ArgoCD')}</td>
      </tr>`;
  }).join('');

  const svcs = common.supervisorServices || {};
  const svcFields = [
    ['Parent Directory', svcs.parentDirectory],
    ['ArgoCD Operator', svcs.argoCdOperatorYamlFileName],
    ['ArgoCD Deployment', svcs.argoCdDeploymentYamlFileName],
    ['Harbor Data Template', svcs.harborDataTemplateYamlFileName],
    ['Harbor Service', svcs.harborServiceYamlFileName],
  ].filter(([, v]) => v);

  const svcHtml = svcFields.length > 0 ? `
    <div style="margin-top:12px;">
      <div style="font-size:11px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.05em;margin-bottom:6px;">Supervisor Services YAML</div>
      ${svcFields.map(([k, v]) => `<div style="display:flex;gap:8px;font-size:12px;margin-bottom:3px;"><span style="color:var(--text-muted);min-width:160px;">${esc(k)}</span><span style="font-family:monospace;">${esc(v)}</span></div>`).join('')}
    </div>` : '';

  const dnsNtp = [
    supCommon.dnsServers          && `DNS: ${supCommon.dnsServers.join(', ')}`,
    supCommon.networkNtpServers   && `NTP: ${supCommon.networkNtpServers.join(', ')}`,
    supCommon.networkSearchDomains && `Search: ${supCommon.networkSearchDomains.join(', ')}`,
  ].filter(Boolean);

  return `
    <details style="background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);overflow:hidden;">
      <summary style="padding:12px 16px;cursor:pointer;font-size:13px;font-weight:600;list-style:none;display:flex;align-items:center;gap:8px;user-select:none;">
        <span style="font-size:16px;">\u25b6</span>
        <span>Configuration Summary \u2014 ${clusters.length} site${clusters.length !== 1 ? 's' : ''}</span>
        <span style="font-size:11px;font-weight:400;color:var(--text-muted);margin-left:4px;">(${esc(common.vCenterName || '?')} \u00b7 ${esc(common.datacenterName || '?')})</span>
      </summary>
      <div style="padding:0 16px 16px;">
        <table style="width:100%;border-collapse:collapse;font-size:12px;margin-top:8px;">
          <thead>
            <tr style="border-bottom:2px solid var(--border);">
              <th style="padding:5px 10px;text-align:left;font-size:10px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.05em;">Edge Site</th>
              <th style="padding:5px 10px;text-align:left;font-size:10px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.05em;">Storage</th>
              <th style="padding:5px 10px;text-align:left;font-size:10px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.05em;">ESX Hosts</th>
              <th style="padding:5px 10px;text-align:left;font-size:10px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.05em;">VLANs <span style="font-weight:400;opacity:.7;">(hover for segment name)</span></th>
              <th style="padding:5px 10px;text-align:left;font-size:10px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.05em;">Services</th>
            </tr>
          </thead>
          <tbody>${siteRows}</tbody>
        </table>
        <div style="display:flex;gap:24px;margin-top:12px;flex-wrap:wrap;">
          <div style="font-size:12px;color:var(--text-muted);">
            Control Plane: <strong style="color:var(--text);">${esc(String(supCommon.controlPlaneVMCount || '?'))} \u00d7 ${esc(supCommon.controlPlaneSize || '?')}</strong>
          </div>
          <div style="font-size:12px;color:var(--text-muted);">
            FLB: <strong style="color:var(--text);">${esc(supCommon.flbSize || '?')} / ${esc(supCommon.flbAvailability || '?')}</strong>
          </div>
          ${dnsNtp.map(s => `<div style="font-size:12px;color:var(--text-muted);"><strong style="color:var(--text);">${esc(s)}</strong></div>`).join('')}
        </div>
        ${svcHtml}
      </div>
    </details>`;
}

// Normalizes a NIC entry that may be either a plain string or a {name} object.
// Used by _diffCommonFields and _diffClusters when comparing nicList values.
const _nicName = n => typeof n === 'string' ? n : (n.name || '');

// Diffs common-level fields (vCenter, NICs, supervisorServices) between two infra objects.
function _diffCommonFields(origInfra, infra, chg) {
  const origC = origInfra.common || {};
  const currC = infra.common || {};
  for (const key of ['vCenterName','vCenterUser','datacenterName','contextName',
                      'esxUser','vSanWitnessVmName','vSanvMotionVmKernelMtuValue',
                      'haPolicy','vLcmImageName','supervisorContentLibraryDatastore',
                      'clusterNamePrefix','datastoreNamePrefix','supervisorNamePrefix','vdsNamePrefix',
                      'esxUniquePasswordPerHost','nonInteractivePassword','autoUpdate','labenvironment',
                      'preserveAutoGeneratedKeyCertPair']) {
    chg('Common', key, _iget(origC, key), currC[key]);
  }
  chg('Common', 'nicList',
    (_iget(origC, 'nicList') || []).map(_nicName).join(', '),
    (currC.nicList || []).map(_nicName).join(', '));
  const origSvcs = _iget(origC, 'supervisorServices') || {};
  const currSvcs = currC.supervisorServices || {};
  for (const key of ['parentDirectory','argoCdOperatorYamlFileName','argoCdDeploymentYamlFileName',
                      'harborDataTemplateYamlFileName','harborServiceYamlFileName',
                      'disableArgoCD','disableHarbor']) {
    chg('Common Supervisor Services', key, _iget(origSvcs, key), currSvcs[key]);
  }
}

// Diffs per-cluster infrastructure fields (storage, hosts, segments, harbor, etc.).
function _diffClusters(origInfra, infra, chg) {
  const origClusters = origInfra.clusters || [];
  const currClusters = infra.clusters || [];
  // Pure formatter — defined once, not per-iteration.
  const vmkStr = vmks => vmks.map(v => `${v.service}:vlan${v.vlanId}/${v.netmask}/${(v.ipList||[]).join(',')}`).join('; ');
  // Pre-build lookup maps so the forEach is O(n) rather than O(n²).
  const origByEdgeSite = Object.fromEntries(origClusters.map(c => [c.edgeSite, c]));
  const currByEdgeSite = Object.fromEntries(currClusters.map(c => [c.edgeSite, c]));
  const allSites = [...new Set([...origClusters.map(c => c.edgeSite), ...currClusters.map(c => c.edgeSite)])];
  allSites.forEach(site => {
    const oC = origByEdgeSite[site];
    const nC = currByEdgeSite[site];
    if (!oC) { chg(`Site: ${site}`, '\u2014', '(not in loaded file)', '(added)'); return; }
    if (!nC) { chg(`Site: ${site}`, '\u2014', '(present in loaded file)', '(removed)'); return; }
    const sec = `Site: ${site}`;
    chg(sec, 'storageType', (oC.storagePolicy||{}).storageType||'', (nC.storagePolicy||{}).storageType||'');
    chg(sec, 'esxHosts', (oC.esxHosts||[]).join(', '), (nC.esxHosts||[]).join(', '));
    chg(sec, 'vSanWitnessVmName', oC.vSanWitnessVmName, nC.vSanWitnessVmName);
    chg(sec, 'haPolicy', oC.haPolicy, nC.haPolicy);
    chg(sec, 'nicList', (oC.nicList||[]).map(_nicName).join(', '), (nC.nicList||[]).map(_nicName).join(', '));
    const oNet = _iget(oC, 'networking') || {};
    const oSegs = oNet.networkSegments || [];
    const nSegs = ((nC.networking||{}).networkSegments||[]);
    chg(sec, 'segments',
      oSegs.map(s => `${s.name}/${s.vlanId}/${s.gateway}`).join('; '),
      nSegs.map(s => `${s.name}/${s.vlanId}/${s.gateway}`).join('; '));
    chg(sec, 'vmkInterfaces',
      vmkStr(oNet.networkingVmKernelInterfaces || []),
      vmkStr((nC.networking||{}).networkingVmKernelInterfaces || []));
    const oH = _iget(oC, 'harborConfiguration') || {};
    const nH = nC.harborConfiguration || {};
    for (const key of ['hostname','parentDirectory','tlsCrt','tlsKey','caCrt',
                        'registryVolumeSize','jobserviceVolumeSize','databaseVolumeSize',
                        'redisVolumeSize','trivyVolumeSize']) {
      chg(sec, `harbor.${key}`, _iget(oH, key), nH[key]);
    }
    const oCS = _iget(oC, 'supervisorServices') || {};
    const nCS = nC.supervisorServices || {};
    for (const key of ['disableHarbor','disableArgoCD']) {
      chg(sec, `services.${key}`, _iget(oCS, key), nCS[key]);
    }
  });
}

// Diffs supervisor common spec and per-site networking fields.
function _diffSupervisor(origSup, sup, chg) {
  const origSC = _iget(origSup, 'commonSupervisorSpec', {});
  const currSC = sup.commonSupervisorSpec || {};
  for (const key of ['controlPlaneVMCount','controlPlaneSize','flbAvailability','flbSize']) {
    chg('Supervisor Common', key, origSC[key] ?? '', currSC[key] ?? '');
  }
  chg('Supervisor Common', 'dnsServers',    (origSC.dnsServers||[]).join(', '),             (currSC.dnsServers||[]).join(', '));
  chg('Supervisor Common', 'ntpServers',    (origSC.networkNtpServers||[]).join(', '),      (currSC.networkNtpServers||[]).join(', '));
  chg('Supervisor Common', 'searchDomains', (origSC.networkSearchDomains||[]).join(', '),   (currSC.networkSearchDomains||[]).join(', '));

  const origSiteSpecs = _iget(origSup, 'siteSpec', []);
  const currSiteSpecs = sup.siteSpec || [];
  const origSupByEdgeSite = Object.fromEntries(origSiteSpecs.map(s => [s.edgeSite, s]));
  const currSupByEdgeSite = Object.fromEntries(currSiteSpecs.map(s => [s.edgeSite, s]));
  const allSupSites = [...new Set([...origSiteSpecs.map(s => s.edgeSite), ...currSiteSpecs.map(s => s.edgeSite)])];
  allSupSites.forEach(site => {
    const oS = origSupByEdgeSite[site] || {};
    const nS = currSupByEdgeSite[site] || {};
    const sec = `Supervisor Site: ${site}`;
    const oFlb = _iget(oS, 'foundationLoadBalancerComponents', {});
    const nFlb = nS.foundationLoadBalancerComponents || {};
    chg(sec, 'flbName',       _iget(oFlb, 'flbName',       ''), nFlb.flbName       || '');
    chg(sec, 'flbVipStartIP', _iget(oFlb, 'flbVipStartIP', ''), nFlb.flbVipStartIP || '');
    chg(sec, 'flbVipIPCount', _iget(oFlb, 'flbVipIPCount', ''), nFlb.flbVipIPCount ?? '');
    const oMgmt = _iget(oFlb, 'flbManagementNetwork', {});
    const nMgmt = nFlb.flbManagementNetwork || {};
    chg(sec, 'flbMgmt.networkName', _iget(oMgmt, 'flbNetworkName', ''),                nMgmt.flbNetworkName || '');
    chg(sec, 'flbMgmt.startIP',     _iget(oMgmt, 'flbNetworkIpAddressStartingIp', ''), nMgmt.flbNetworkIpAddressStartingIp || '');
    chg(sec, 'flbMgmt.ipCount',     _iget(oMgmt, 'flbNetworkIpAddressCount', ''),      nMgmt.flbNetworkIpAddressCount ?? '');
    chg(sec, 'flbMgmt.gateway',     _iget(oMgmt, 'flbNetworkGateway', ''),             nMgmt.flbNetworkGateway || '');
    const oFlbVirtualServerNet = _iget(oFlb, 'flbVirtualServerNetwork', {});
    const nFlbVirtualServerNet = nFlb.flbVirtualServerNetwork || {};
    chg(sec, 'flbVirtualServerNet.networkName', _iget(oFlbVirtualServerNet, 'flbNetworkName', ''),                 nFlbVirtualServerNet.flbNetworkName || '');
    chg(sec, 'flbVirtualServerNet.startIP',     _iget(oFlbVirtualServerNet, 'flbNetworkIpAddressStartingIp', ''), nFlbVirtualServerNet.flbNetworkIpAddressStartingIp || '');
    chg(sec, 'flbVirtualServerNet.ipCount',     _iget(oFlbVirtualServerNet, 'flbNetworkIpAddressCount', ''),      nFlbVirtualServerNet.flbNetworkIpAddressCount ?? '');
    chg(sec, 'flbVirtualServerNet.gateway',     _iget(oFlbVirtualServerNet, 'flbNetworkGateway', ''),             nFlbVirtualServerNet.flbNetworkGateway || '');
    const oMgmtSpec = _iget(oS, 'mgmtNetworkSpec', {});
    const nMgmtSpec = nS.mgmtNetworkSpec || {};
    chg(sec, 'mgmt.networkName', _iget(oMgmtSpec, 'mgmtNetworkName', ''),          nMgmtSpec.mgmtNetworkName || '');
    chg(sec, 'mgmt.startIP',     _iget(oMgmtSpec, 'mgmtNetworkStartingIp', ''),    nMgmtSpec.mgmtNetworkStartingIp || '');
    chg(sec, 'mgmt.ipCount',     _iget(oMgmtSpec, 'mgmtNetworkIPCount', ''),       nMgmtSpec.mgmtNetworkIPCount ?? '');
    const oWorkloadNet = _iget(oS, 'primaryWorkloadNetwork', {});
    const nWorkloadNet = nS.primaryWorkloadNetwork || {};
    chg(sec, 'workloadNet.networkName',    _iget(oWorkloadNet, 'primaryWorkloadNetworkName', ''),       nWorkloadNet.primaryWorkloadNetworkName || '');
    chg(sec, 'workloadNet.startIP',        _iget(oWorkloadNet, 'primaryWorkloadNetworkStartingIp', ''), nWorkloadNet.primaryWorkloadNetworkStartingIp || '');
    chg(sec, 'workloadNet.ipCount',        _iget(oWorkloadNet, 'primaryWorkloadNetworkIPCount', ''),    nWorkloadNet.primaryWorkloadNetworkIPCount ?? '');
    chg(sec, 'workloadNet.serviceStartIP', _iget(oWorkloadNet, 'workloadServiceStartIp', ''),           nWorkloadNet.workloadServiceStartIp || '');
    chg(sec, 'workloadNet.serviceCount',   _iget(oWorkloadNet, 'workloadServiceCount', ''),             nWorkloadNet.workloadServiceCount ?? '');
  });
}

// Compares current infra+supervisor against a loaded snapshot and returns an array of
// change objects { section, field, from, to }. Uses _iget throughout so PascalCase keys
// in the raw snapshot do not produce phantom diffs against the server-normalized state.
// Parameters: current state first, original snapshot second — mirrors a standard diff(a, b) convention.
function _detectChanges(infra, sup, origInfra, origSup) {
  const changes = [];
  // null/undefined are normalized to '' so absent fields don't diff against explicit false/0.
  const chg = (section, field, from, to) => {
    const f = from ?? '';
    const t = to ?? '';
    if (String(f) !== String(t)) changes.push({ section, field, from: String(f), to: String(t) });
  };
  _diffCommonFields(origInfra, infra, chg);
  _diffClusters(origInfra, infra, chg);
  _diffSupervisor(origSup, sup, chg);
  return changes;
}

// Renders a changes array (from _detectChanges) as a collapsible diff HTML block.
function _buildDiffHtml(changes) {
  const dStyle = `background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);overflow:hidden;margin-top:10px;`;
  const sStyle = `padding:12px 16px;cursor:pointer;font-size:13px;font-weight:600;list-style:none;display:flex;align-items:center;gap:8px;user-select:none;`;

  if (changes.length === 0) {
    const badge = `<span style="font-size:11px;font-weight:400;color:var(--success);margin-left:4px;">\u2014 no changes detected</span>`;
    return `<details style="${dStyle}">
      <summary style="${sStyle}"><span class="diff-arrow" style="font-size:16px;">\u25b6</span>
      <span>Changes from Loaded File</span>${badge}</summary>
      <div style="padding:12px 16px;font-size:12px;color:var(--text-muted);">All compared fields match the loaded file.</div>
    </details>`;
  }

  const badge = `<span style="font-size:11px;font-weight:400;color:var(--warning);margin-left:4px;">\u2014 ${changes.length} field${changes.length !== 1 ? 's' : ''} changed</span>`;
  const grouped = {};
  changes.forEach(c => { (grouped[c.section] = grouped[c.section] || []).push(c); });
  const diffRows = Object.entries(grouped).map(([sec, entries]) =>
    `<div style="margin-top:10px;">
      <div style="font-size:10px;font-weight:700;color:var(--accent);text-transform:uppercase;letter-spacing:.05em;margin-bottom:4px;padding:3px 8px;background:rgba(0,180,216,0.07);border-left:3px solid var(--accent);">${esc(sec)}</div>
      <table style="width:100%;border-collapse:collapse;font-size:12px;">
      ${entries.map(e =>
        `<tr style="border-bottom:1px solid var(--border);">
          <td style="padding:4px 8px;color:var(--text-muted);white-space:nowrap;width:28%;">${esc(e.field)}</td>
          <td style="padding:4px 8px;font-family:monospace;font-size:11px;color:var(--error);text-decoration:line-through;word-break:break-all;">${esc(e.from)||'\u2014'}</td>
          <td style="padding:2px 4px;color:var(--text-muted);">\u2192</td>
          <td style="padding:4px 8px;font-family:monospace;font-size:11px;color:var(--success);word-break:break-all;">${esc(e.to)||'\u2014'}</td>
        </tr>`).join('')}
      </table>
    </div>`).join('');

  return `<details style="${dStyle}">
    <summary style="${sStyle}"><span class="diff-arrow" style="font-size:16px;">\u25b6</span>
    <span>Changes from Loaded File</span>${badge}</summary>
    <div style="padding:0 16px 16px;">${diffRows}</div>
  </details>`;
}

// Builds and injects the expandable configuration summary from the validated JSON objects.
// snapshot (optional) is the _loadedSnapshot value — when present a second collapsible
// "Changes from Loaded File" section is appended below the summary table.
function buildChangeSummary(infra, sup, snapshot) {
  const el = document.getElementById('changeSummary');
  if (!el) return;

  const diffHtml = snapshot
    ? _buildDiffHtml(_detectChanges(infra, sup, snapshot.infrastructure || {}, snapshot.supervisor || {}))
    : '';

  el.style.display = 'block';
  el.innerHTML = _buildSummaryTableHtml(infra, sup) + diffHtml;

  // Rotate the ▶ arrow on each <details> block when toggled.
  el.querySelectorAll('details').forEach(d => {
    const arrow = d.querySelector('summary .diff-arrow, summary span:first-child');
    d.addEventListener('toggle', () => {
      if (arrow) arrow.textContent = d.open ? '\u25bc' : '\u25b6';
    });
  });
}

// ---------------------------------------------------------------------------
// Delegated listener for reset buttons (uses data-* attributes, not inline onclick).
// ---------------------------------------------------------------------------
document.addEventListener('click', function(e) {
  const btn = e.target.closest('[data-reset-section]');
  if (btn) _resetSection(btn.dataset.resetSection, btn.dataset.resetSite);
});

// ---------------------------------------------------------------------------
// Startup: fetch /info to populate version, README link, default dir hint
// ---------------------------------------------------------------------------
(async function initInfo() {
  try {
    const resp = await fetch('/info');
    const info = await resp.json();
    const vb = document.getElementById('versionBadge');
    if (vb) vb.textContent = 'v' + info.version;
    const rl = document.getElementById('readmeLink');
    if (rl && /^https?:\/\//.test(info.readme_url)) { rl.href = info.readme_url; }
    const hint = document.getElementById('defaultDirHint');
    if (hint) {
      hint.textContent = info.base_dir_exists
        ? 'Default directory: ' + info.base_dir
        : 'Default directory not found: ' + info.base_dir + ' — use custom path or run Start-VcfEdgeAtScale -Initialize first.';
    }
  } catch (_) {}
})();

// ---------------------------------------------------------------------------
// Load templates
// ---------------------------------------------------------------------------
async function loadFromDefault() {
  await _doLoad('/templates', null);
}

async function loadFromCustom() {
  const path = (document.getElementById('customLoadPath') || {}).value || '';
  if (!path.trim()) {
    const s = document.getElementById('loadTemplateStatus');
    s.textContent = 'Enter a directory path first.';
    s.style.color = 'var(--warning)';
    return;
  }
  await _doLoad('/templates-custom', { path: path.trim() });
}

async function _doLoad(url, body) {
  const status = document.getElementById('loadTemplateStatus');
  const defaultBtn = document.getElementById('loadDefaultBtn');
  const customBtn = document.getElementById('loadCustomBtn');
  if (defaultBtn) defaultBtn.disabled = true;
  if (customBtn) customBtn.disabled = true;
  status.textContent = 'Loading...';
  status.style.color = 'var(--text-muted)';
  try {
    const resp = body
      ? await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
      : await fetch(url);
    if (!resp.ok) {
      const err = await resp.json().catch(() => ({}));
      throw new Error(err.error || 'Server error');
    }
    const data = await resp.json();
    _loadedSnapshot = data;
    _applySnapshot(data);
    _updateResetButtons();
    status.textContent = '✓ Loaded from: ' + (data._source || 'unknown');
    status.style.color = 'var(--success)';
  } catch (err) {
    status.textContent = '✗ ' + err;
    status.style.color = 'var(--error)';
  } finally {
    if (defaultBtn) defaultBtn.disabled = false;
    if (customBtn) customBtn.disabled = false;
  }
}

// ---------------------------------------------------------------------------
// Snapshot apply (full + per-section) — includes site-name mismatch detection
// ---------------------------------------------------------------------------

// Returns { orphanSup: string[], orphanInfra: string[] } comparing the two
// sets of edgeSite names. Both arrays are sorted for stable display order.
function _detectSiteMismatches(infra, sup) {
  const infraSites = new Set((infra.clusters || []).map(c => c.edgeSite).filter(Boolean));
  const supSites   = new Set((_iget(sup, 'siteSpec', [])).map(s => s.edgeSite).filter(Boolean));
  return {
    orphanSup:   [...supSites].filter(n => !infraSites.has(n)).sort(),
    orphanInfra: [...infraSites].filter(n => !supSites.has(n)).sort(),
  };
}

// Pending snapshot stored while the remap modal is open.
let _pendingRemapData = null;

// Shows the site-remap modal. orphanSup are supervisor entries with no infra match;
// orphanInfra are infra clusters with no supervisor entry.
// infraSites is the full sorted list of infra edgeSite names for the dropdowns.
function _showSiteRemapModal(data, orphanSup, orphanInfra, infraSites) {
  _pendingRemapData = data;
  const rows = document.getElementById('siteRemapRows');
  const desc = document.getElementById('siteRemapModalDesc');
  desc.textContent =
    'The supervisor.json site names do not match the infrastructure.json cluster names. ' +
    'Map each unmatched supervisor entry to the correct infrastructure cluster, or choose ' +
    '"— skip —" to discard its supervisor configuration. Infrastructure clusters with no ' +
    'supervisor entry will start with blank supervisor fields.';

  let html = '';

  if (orphanSup.length > 0) {
    html += `<div style="font-size:11px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.05em;margin-bottom:8px;">Unmatched supervisor entries</div>`;
    // Build options once — infraSites is constant across all rows.
    const opts = infraSites.map(n => `<option value="${esc(n)}">${esc(n)}</option>`).join('');
    orphanSup.forEach(name => {
      html += `<div class="remap-row">
        <div class="remap-sup" title="${esc(name)}">${esc(name)}</div>
        <div class="remap-arrow">→</div>
        <select data-remap-sup="${esc(name)}">
          <option value="">— skip —</option>
          ${opts}
        </select>
      </div>`;
    });
  }

  if (orphanInfra.length > 0) {
    html += `<div style="font-size:11px;font-weight:700;color:var(--text-muted);text-transform:uppercase;letter-spacing:.05em;margin:16px 0 8px;">Infrastructure clusters with no supervisor entry</div>`;
    orphanInfra.forEach(name => {
      html += `<div class="remap-infra-note">${esc(name)} — will load with blank supervisor fields</div>`;
    });
  }

  rows.innerHTML = html;
  document.getElementById('siteRemapModal').classList.add('visible');
}

function _siteRemapCancel() {
  document.getElementById('siteRemapModal').classList.remove('visible');
  _pendingRemapData = null;
}

// Reads the user's dropdown selections, rewrites the supervisor siteSpec edgeSite
// names accordingly, then continues the normal apply flow.
function _siteRemapConfirm() {
  document.getElementById('siteRemapModal').classList.remove('visible');
  if (!_pendingRemapData) return;

  const data = _pendingRemapData;
  _pendingRemapData = null;

  const sup = data.supervisor || {};
  const siteSpec = _iget(sup, 'siteSpec', []);

  document.querySelectorAll('[data-remap-sup]').forEach(sel => {
    const oldName = sel.dataset.remapSup;
    const newName = sel.value;
    const entry = siteSpec.find(s => s.edgeSite === oldName);
    if (!entry) return;
    if (newName) {
      entry.edgeSite = newName;
    } else {
      // Skip: remove the entry entirely so the infra cluster gets blank sup fields.
      const idx = siteSpec.indexOf(entry);
      if (idx !== -1) siteSpec.splice(idx, 1);
    }
  });

  _applySnapshotNow(data);
}

function _applySnapshot(data) {
  const infra = data.infrastructure || {};
  const sup   = data.supervisor || {};

  const { orphanSup, orphanInfra } = _detectSiteMismatches(infra, sup);
  if (orphanSup.length > 0 || orphanInfra.length > 0) {
    const infraSites = (infra.clusters || []).map(c => c.edgeSite).filter(Boolean).sort();
    _showSiteRemapModal(data, orphanSup, orphanInfra, infraSites);
    return;
  }

  _applySnapshotNow(data);
}

function _applySnapshotNow(data) {
  const infra = data.infrastructure || {};
  const sup = data.supervisor || {};
  const c = infra.common || {};

  _applyVcenterSection(c);
  _applyNicSection(c);
  _applyOptionalCommonSection(c);
  _applySvcSection(c);
  _applySitesSection(infra, sup);
  _applySupCommonSection(sup);
  renderSites();
  rebuildSupervisorSites();
}

function _applyVcenterSection(c) {
  sv('vCenterName', c.vCenterName || '');
  sv('vCenterUser', c.vCenterUser || '');
  sv('contextName', c.contextName || '');
  sv('datacenterName', c.datacenterName || '');
}

function _applyNicSection(c) {
  setNicChipsFromValue((c.nicList || []).map(n => n.name));
}

function _applyOptionalCommonSection(c) {
  sv('esxUser', c.esxUser || '');
  sv('vSanWitnessVmName', c.vSanWitnessVmName || '');
  sv('haPolicy', c.haPolicy || 'reservationBased');
  sv('vLcmImageName', c.vLcmImageName || '');
  sv('vSanvMotionVmKernelMtuValue', c.vSanvMotionVmKernelMtuValue != null ? String(c.vSanvMotionVmKernelMtuValue) : '');
  sv('clusterNamePrefix', c.clusterNamePrefix || '');
  sv('datastoreNamePrefix', c.datastoreNamePrefix || '');
  sv('supervisorNamePrefix', c.supervisorNamePrefix || '');
  sv('vdsNamePrefix', c.vdsNamePrefix || '');
  sv('supervisorContentLibraryDatastore', c.supervisorContentLibraryDatastore || '');
  sc('esxUniquePasswordPerHost', c.esxUniquePasswordPerHost);
  sc('nonInteractivePassword', c.nonInteractivePassword);
  sc('autoUpdate', c.autoUpdate !== undefined ? c.autoUpdate : true);
  sc('labenvironment', c.labenvironment);
  sc('preserveAutoGeneratedKeyCertPair', c.preserveAutoGeneratedKeyCertPair);
}

function _applySvcSection(c) {
  const svcs = c.supervisorServices || {};
  sv('svc_parentDirectory', svcs.parentDirectory || '');
  sv('svc_argoCdOperatorYamlFileName', svcs.argoCdOperatorYamlFileName || '');
  sv('svc_argoCdDeploymentYamlFileName', svcs.argoCdDeploymentYamlFileName || '');
  sv('svc_harborDataTemplateYamlFileName', svcs.harborDataTemplateYamlFileName || '');
  sv('svc_harborServiceYamlFileName', svcs.harborServiceYamlFileName || '');
  sc('svc_disableArgoCD', svcs.disableArgoCD);
  sc('svc_disableHarbor', svcs.disableHarbor);
}

// Normalizes a raw supervisor network object by extracting only the known camelCase fields
// (using _iget for case-insensitive lookup) into a new clean object. Unknown keys from the
// raw JSON are not propagated, preventing unexpected values from reaching the rendered DOM.
function _normSupNet(raw, keySet) {
  if (!raw || typeof raw !== 'object') return {};
  const out = {};
  for (const camel of keySet) {
    const val = _iget(raw, camel);
    if (val !== undefined) out[camel] = val;
  }
  return out;
}

// Known camelCase field names for each supervisor network sub-object type.
// _iget handles case-insensitive lookup against the raw JSON keys.
const _FLB_NET_KEYS = new Set(['flbNetworkName', 'flbNetworkIpAddressStartingIp', 'flbNetworkIpAddressCount', 'flbNetworkGateway']);
const _MGMT_NET_KEYS = new Set(['mgmtNetworkName', 'mgmtNetworkStartingIp', 'mgmtNetworkIPCount']);
const _WORKLOAD_NET_KEYS = new Set(['primaryWorkloadNetworkName', 'primaryWorkloadNetworkStartingIp', 'primaryWorkloadNetworkIPCount', 'workloadServiceStartIp', 'workloadServiceCount']);

// Builds a site object from a raw cluster + supervisor site entry.
// Deep-copies all mutable sub-objects so later edits never corrupt the stored snapshot.
// Normalizes supervisor sub-objects to camelCase at load time so the renderer and
// buildPayload() can use plain property access without case-insensitive lookups.
function _buildSiteFromCluster(cluster, supSite, id) {
  const flb = _iget(supSite, 'foundationLoadBalancerComponents', {});
  return {
    id,
    edgeSite: cluster.edgeSite || '',
    esxHosts: cluster.esxHosts || [],
    nicList: (cluster.nicList || []).map(n => n.name),
    storageType: (cluster.storagePolicy || {}).storageType || 'VMFS',
    vSanWitnessVmName: cluster.vSanWitnessVmName || '',
    haPolicy: cluster.haPolicy || '',
    segments: ((cluster.networking || {}).networkSegments || []).map(seg => ({
      name:    _iget(seg, 'name',    ''),
      vlanId:  _iget(seg, 'vlanId',  ''),
      gateway: _iget(seg, 'gateway', ''),
    })),
    vmkInterfaces: ((cluster.networking || {}).networkingVmKernelInterfaces || []).map(v => ({
      ...v,
      ipList: Array.isArray(v.ipList) ? [...v.ipList] : (String(v.ipList || '')).split(',').map(s => s.trim()).filter(Boolean),
    })),
    harbor: JSON.parse(JSON.stringify(cluster.harborConfiguration || {})),
    supervisorServices: JSON.parse(JSON.stringify(cluster.supervisorServices || {})),
    _supervisor: {
      flb: { flbName: _iget(flb, 'flbName', ''), flbVipStartIP: _iget(flb, 'flbVipStartIP', ''), flbVipIPCount: _iget(flb, 'flbVipIPCount', 0) },
      flbMgmt: _normSupNet(_iget(flb, 'flbManagementNetwork', {}), _FLB_NET_KEYS),
      flbVirtualServerNet: _normSupNet(_iget(flb, 'flbVirtualServerNetwork', {}), _FLB_NET_KEYS),
      mgmt:    _normSupNet(_iget(supSite, 'mgmtNetworkSpec', {}), _MGMT_NET_KEYS),
      // Default workloadServiceCount to 512 so the number input always has an actual
      // value; without it the field shows the placeholder and pressing ↑ snaps to min=1.
      workloadNet: { workloadServiceCount: 512, ..._normSupNet(_iget(supSite, 'primaryWorkloadNetwork', {}), _WORKLOAD_NET_KEYS) },
    },
  };
}

function _applySitesSection(infra, sup) {
  sites = [];
  siteCounter = 0;
  const siteSpec = _iget(sup, 'siteSpec', []);
  const clusters = infra.clusters || [];
  clusters.forEach((cluster, idx) => {
    const supSite = siteSpec.find(s => s.edgeSite === cluster.edgeSite) || {};
    const site = _buildSiteFromCluster(cluster, supSite, ++siteCounter);
    // Collapse all sites when loading a file with 3+ sites.
    site.collapsed = clusters.length > 2;
    sites.push(site);
  });
}

function _applySupCommonSection(sup) {
  const cs = _iget(sup, 'commonSupervisorSpec', {});
  sv('controlPlaneVMCount', String(cs.controlPlaneVMCount || '1'));
  sv('controlPlaneSize', cs.controlPlaneSize || 'SMALL');
  sv('flbAvailability', cs.flbAvailability || 'SINGLE_NODE');
  sv('flbSize', cs.flbSize || 'MEDIUM');
  sv('flbNetworkType', cs.flbNetworkType || 'DVPG');
  setDnsFromValue(cs.dnsServers || []);
  setNtpFromValue(cs.networkNtpServers || []);
  setSearchFromValue(cs.networkSearchDomains || []);
}

// ---------------------------------------------------------------------------
// Per-section reset handlers — called from "↺ Reset" buttons
// ---------------------------------------------------------------------------

// Captures the current live state for a section so it can be restored by undo.
function _captureCurrentSection(section, siteId) {
  const gv = id => (document.getElementById(id) || {}).value || '';
  const gc = id => !!((document.getElementById(id) || {}).checked);
  switch (section) {
    case 'vcenter':
      return { vCenterName: gv('vCenterName'), vCenterUser: gv('vCenterUser'),
               contextName: gv('contextName'), datacenterName: gv('datacenterName') };
    case 'niclist':
      return { nics: [...commonNics] };
    case 'optcommon':
      return {
        esxUser: gv('esxUser'), vSanWitnessVmName: gv('vSanWitnessVmName'),
        haPolicy: gv('haPolicy'), vLcmImageName: gv('vLcmImageName'),
        vSanvMotionVmKernelMtuValue: gv('vSanvMotionVmKernelMtuValue'),
        clusterNamePrefix: gv('clusterNamePrefix'), datastoreNamePrefix: gv('datastoreNamePrefix'),
        supervisorNamePrefix: gv('supervisorNamePrefix'), vdsNamePrefix: gv('vdsNamePrefix'),
        supervisorContentLibraryDatastore: gv('supervisorContentLibraryDatastore'),
        esxUniquePasswordPerHost: gc('esxUniquePasswordPerHost'),
        nonInteractivePassword: gc('nonInteractivePassword'),
        autoUpdate: gc('autoUpdate'), labenvironment: gc('labenvironment'),
        preserveAutoGeneratedKeyCertPair: gc('preserveAutoGeneratedKeyCertPair'),
      };
    case 'svc':
      return {
        parentDirectory: gv('svc_parentDirectory'),
        argoCdOperatorYamlFileName: gv('svc_argoCdOperatorYamlFileName'),
        argoCdDeploymentYamlFileName: gv('svc_argoCdDeploymentYamlFileName'),
        harborDataTemplateYamlFileName: gv('svc_harborDataTemplateYamlFileName'),
        harborServiceYamlFileName: gv('svc_harborServiceYamlFileName'),
        disableArgoCD: gc('svc_disableArgoCD'), disableHarbor: gc('svc_disableHarbor'),
      };
    case 'site': {
      const idx = sites.findIndex(s => s.edgeSite === siteId);
      return idx !== -1 ? JSON.parse(JSON.stringify(sites[idx])) : null;
    }
    case 'supsite': {
      // Capture only the supervisor sub-object so undoing a supervisor-site reset
      // does not clobber concurrent infrastructure edits to the same site.
      const idx = sites.findIndex(s => s.edgeSite === siteId);
      return idx !== -1 ? { _siteId: siteId, _supervisor: JSON.parse(JSON.stringify(sites[idx]._supervisor || {})) } : null;
    }
    case 'supcommon':
      return {
        controlPlaneVMCount: gv('controlPlaneVMCount'), controlPlaneSize: gv('controlPlaneSize'),
        flbAvailability: gv('flbAvailability'), flbSize: gv('flbSize'),
        dnsServers: [...dnsList], networkNtpServers: [...ntpList],
        networkSearchDomains: [...searchDomainList],
      };
    default:
      return null;
  }
}

// Restores a previously captured section state (inverse of _captureCurrentSection).
function _restoreSection(section, captured) {
  if (!captured) return;
  switch (section) {
    case 'vcenter':
      sv('vCenterName', captured.vCenterName); sv('vCenterUser', captured.vCenterUser);
      sv('contextName', captured.contextName); sv('datacenterName', captured.datacenterName);
      break;
    case 'niclist':
      setNicChipsFromValue(captured.nics);
      break;
    case 'optcommon':
      sv('esxUser', captured.esxUser); sv('vSanWitnessVmName', captured.vSanWitnessVmName);
      sv('haPolicy', captured.haPolicy); sv('vLcmImageName', captured.vLcmImageName);
      sv('vSanvMotionVmKernelMtuValue', captured.vSanvMotionVmKernelMtuValue);
      sv('clusterNamePrefix', captured.clusterNamePrefix);
      sv('datastoreNamePrefix', captured.datastoreNamePrefix);
      sv('supervisorNamePrefix', captured.supervisorNamePrefix);
      sv('vdsNamePrefix', captured.vdsNamePrefix);
      sv('supervisorContentLibraryDatastore', captured.supervisorContentLibraryDatastore);
      sc('esxUniquePasswordPerHost', captured.esxUniquePasswordPerHost);
      sc('nonInteractivePassword', captured.nonInteractivePassword);
      sc('autoUpdate', captured.autoUpdate); sc('labenvironment', captured.labenvironment);
      sc('preserveAutoGeneratedKeyCertPair', captured.preserveAutoGeneratedKeyCertPair);
      break;
    case 'svc':
      sv('svc_parentDirectory', captured.parentDirectory);
      sv('svc_argoCdOperatorYamlFileName', captured.argoCdOperatorYamlFileName);
      sv('svc_argoCdDeploymentYamlFileName', captured.argoCdDeploymentYamlFileName);
      sv('svc_harborDataTemplateYamlFileName', captured.harborDataTemplateYamlFileName);
      sv('svc_harborServiceYamlFileName', captured.harborServiceYamlFileName);
      sc('svc_disableArgoCD', captured.disableArgoCD);
      sc('svc_disableHarbor', captured.disableHarbor);
      break;
    case 'site': {
      const idx = sites.findIndex(s => s.edgeSite === captured.edgeSite);
      if (idx !== -1) { sites[idx] = captured; renderSites(); rebuildSupervisorSites(); }
      break;
    }
    case 'supsite': {
      const idx = sites.findIndex(s => s.edgeSite === captured._siteId);
      if (idx !== -1) { sites[idx]._supervisor = captured._supervisor; rebuildSupervisorSites(); }
      break;
    }
    case 'supcommon':
      sv('controlPlaneVMCount', captured.controlPlaneVMCount);
      sv('controlPlaneSize', captured.controlPlaneSize);
      sv('flbAvailability', captured.flbAvailability);
      sv('flbSize', captured.flbSize);
      setDnsFromValue(captured.dnsServers);
      setNtpFromValue(captured.networkNtpServers);
      setSearchFromValue(captured.networkSearchDomains);
      break;
  }
}

function _resetSection(section, siteId) {
  if (!_loadedSnapshot) return;

  const c = (_loadedSnapshot.infrastructure || {}).common || {};
  const sup = _loadedSnapshot.supervisor || {};

  // For simple sections, capture undo state before applying the reset.
  // For site-specific sections, early-return guards must pass first so we
  // don't register an undo entry for a reset that did nothing.
  let before;
  switch (section) {
    case 'vcenter':
      before = _captureCurrentSection(section, siteId);
      _applyVcenterSection(c);
      break;
    case 'niclist':
      before = _captureCurrentSection(section, siteId);
      _applyNicSection(c);
      break;
    case 'optcommon':
      before = _captureCurrentSection(section, siteId);
      _applyOptionalCommonSection(c);
      break;
    case 'svc':
      before = _captureCurrentSection(section, siteId);
      _applySvcSection(c);
      break;
    case 'site': {
      const infra = _loadedSnapshot.infrastructure || {};
      const cluster = (infra.clusters || []).find(cl => cl.edgeSite === siteId);
      if (!cluster) return;
      const supSite = (_iget(sup, 'siteSpec', [])).find(s => s.edgeSite === siteId) || {};
      const idx = sites.findIndex(s => s.edgeSite === siteId);
      if (idx === -1) return;
      before = _captureCurrentSection(section, siteId);
      const existingId = sites[idx].id;
      const wasCollapsed = sites[idx].collapsed;
      sites[idx] = _buildSiteFromCluster(cluster, supSite, existingId);
      // Preserve the user's collapsed/expanded state — a reset shouldn't pop the site open.
      sites[idx].collapsed = wasCollapsed;
      renderSites();
      rebuildSupervisorSites();
      break;
    }
    case 'supcommon':
      before = _captureCurrentSection(section, siteId);
      _applySupCommonSection(sup);
      break;
    case 'supsite': {
      const supSite = (_iget(sup, 'siteSpec', [])).find(s => s.edgeSite === siteId) || {};
      const flb = _iget(supSite, 'foundationLoadBalancerComponents', {});
      const idx = sites.findIndex(s => s.edgeSite === siteId);
      if (idx === -1) return;
      before = _captureCurrentSection(section, siteId);
      // Normalize to camelCase so the renderer can use plain property access.
      sites[idx]._supervisor = {
        flb: { flbName: _iget(flb, 'flbName', ''), flbVipStartIP: _iget(flb, 'flbVipStartIP', ''), flbVipIPCount: _iget(flb, 'flbVipIPCount', 0) },
        flbMgmt: _normSupNet(_iget(flb, 'flbManagementNetwork', {}), _FLB_NET_KEYS),
        flbVirtualServerNet: _normSupNet(_iget(flb, 'flbVirtualServerNetwork', {}), _FLB_NET_KEYS),
        mgmt:    _normSupNet(_iget(supSite, 'mgmtNetworkSpec', {}), _MGMT_NET_KEYS),
        workloadNet: { workloadServiceCount: 512, ..._normSupNet(_iget(supSite, 'primaryWorkloadNetwork', {}), _WORKLOAD_NET_KEYS) },
      };
      rebuildSupervisorSites();
      break;
    }
    default:
      return;
  }

  // Show undo toast so the user can revert the reset if it was accidental.
  const sectionLabels = {
    vcenter: 'vCenter Connection', niclist: 'NIC List',
    optcommon: 'Optional Common Settings', svc: 'Supervisor Services',
    site: `Edge Site "${siteId}"`, supcommon: 'Common Supervisor Spec',
    supsite: `Supervisor Site "${siteId}"`,
  };
  const label = sectionLabels[section] || section;
  _pushUndo(label, () => _restoreSection(section, before), 'Reset');
}

// Renders a small reset button HTML string for a card header.
// Uses data-* attributes instead of inline onclick to avoid JS-context injection —
// esc() is HTML-escaping and is not safe for values placed inside JS string literals.
// A single delegated listener on document handles all reset buttons.
function _resetBtn(section, siteId) {
  if (!_loadedSnapshot) return '';
  const siteAttr = siteId !== undefined ? ` data-reset-site="${esc(siteId)}"` : '';
  return `<button class="btn btn-reset" data-reset-section="${esc(section)}"${siteAttr} title="Reset this section to the last loaded values">↺ Reset</button>`;
}

// Populates the static placeholder <span id="resetBtn-*"> slots in Step 1 and Step 3
// static card headers. Called after every successful load.
function _updateResetButtons() {
  const slots = ['vcenter', 'niclist', 'optcommon', 'svc', 'supcommon'];
  slots.forEach(key => {
    const el = document.getElementById('resetBtn-' + key);
    if (el) el.innerHTML = _resetBtn(key);
  });
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------
function v(id) { return (document.getElementById(id) || {}).value || ''; }
function sv(id, val) { const el = document.getElementById(id); if (el) el.value = val; }
function sc(id, val) { const el = document.getElementById(id); if (el) el.checked = !!val; }

// Case-insensitive object key lookup. Tries exact key first, then lowercased comparison.
// Needed because real-world JSON files sometimes use PascalCase keys
// (e.g. "SiteSpec", "MgmtNetworkSpec") instead of the spec's camelCase.
function _iget(obj, key, fallback) {
  if (!obj || typeof obj !== 'object') return fallback;
  if (key in obj) return obj[key];
  const lower = key.toLowerCase();
  for (const k of Object.keys(obj)) {
    if (k.toLowerCase() === lower) return obj[k];
  }
  return fallback;
}

function esc(s) {
  if (s === null || s === undefined) return '';
  const MAP = {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'};
  return String(s).replace(/[&<>"']/g, c => MAP[c]);
}
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# HTTP request handler
# ---------------------------------------------------------------------------


def _check_host_https(host, timeout=_CONNECTIVITY_TIMEOUT):
    """
    Probes host:443 with a TLS 1.2 handshake (as required by vCenter 9.0+).
    Certificate validation and hostname checking are disabled — self-signed
    certificates are expected in VCF lab environments.

    If the TLS handshake fails (e.g. the FQDN points to a non-HTTPS service
    or a server with incompatible TLS config), the error is reported as a
    warning rather than marking the host unreachable, since TCP connectivity
    itself may be fine.

    Returns a dict:
      { "host": str, "reachable": bool, "latency_ms": int|None, "error": str|None }
    """
    start = time.monotonic()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, 443), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host):
                latency_ms = round((time.monotonic() - start) * 1000)
                return {"host": host, "reachable": True, "latency_ms": latency_ms, "error": None}
    except ssl.SSLError as exc:
        # TCP port 443 is open but TLS negotiation failed. Most likely cause:
        # the FQDN does not point to a vCenter (or any HTTPS server). Reported
        # as "TCP reachable" so the user knows the host is up but the endpoint
        # is unexpected. vCenter 9.0+ requires TLS 1.2 — if this fires against
        # a real vCenter, check the host's TLS configuration.
        latency_ms = round((time.monotonic() - start) * 1000)
        reason = exc.reason or str(exc)
        return {
            "host": host,
            "reachable": True,
            "latency_ms": latency_ms,
            "error": f"Port 443 open but TLS handshake failed ({reason}) — verify this FQDN points to a vCenter/ESXi host",
        }
    except (socket.timeout, TimeoutError):
        return {"host": host, "reachable": False, "latency_ms": None, "error": "Connection timed out"}
    except ConnectionRefusedError:
        return {"host": host, "reachable": False, "latency_ms": None, "error": "Connection refused (port 443 closed)"}
    except socket.gaierror as exc:
        return {"host": host, "reachable": False, "latency_ms": None, "error": f"DNS resolution failed: {exc.args[1] if exc.args else exc}"}
    except OSError as exc:
        return {"host": host, "reachable": False, "latency_ms": None, "error": str(exc)}


def _build_and_validate(payload):
    """
    Builds infrastructure and supervisor dicts from a raw payload dict, then
    runs full validation (infrastructure, supervisor, cross-file).

    Returns (infra_built, sup_built, all_errors, all_warnings).
    Raises ValueError with a descriptive message if the build step itself fails.
    """
    infra_data = payload.get("infrastructure", {})
    sup_data = payload.get("supervisor", {})

    try:
        infra_built = build_infrastructure(infra_data)
    except Exception as exc:
        traceback.print_exc()
        raise ValueError(f"Failed to build infrastructure: {type(exc).__name__}: {exc}") from exc

    try:
        sup_built = build_supervisor(sup_data)
    except Exception as exc:
        traceback.print_exc()
        raise ValueError(f"Failed to build supervisor: {type(exc).__name__}: {exc}") from exc

    try:
        infra_errors, cluster_segment_names, cluster_segment_gateways = validate_infrastructure(infra_built)
    except Exception as exc:
        traceback.print_exc()
        raise ValueError(f"Failed to validate infrastructure: {type(exc).__name__}: {exc}") from exc

    try:
        sup_errors, sup_warnings = validate_supervisor(sup_built, cluster_segment_names, cluster_segment_gateways)
    except Exception as exc:
        traceback.print_exc()
        raise ValueError(f"Failed to validate supervisor: {type(exc).__name__}: {exc}") from exc

    infra_sites = [c.get("edgeSite", "") for c in infra_built.get("clusters", [])]
    sup_sites = [s.get("edgeSite", "") for s in sup_built.get("siteSpec", [])]
    cross_errors = validate_cross_file(infra_sites, sup_sites)

    # Separate pre-tagged [WARNING]/[INFO] strings from true [ERROR] strings.
    # validate_infrastructure() may emit [WARNING]-prefixed strings (e.g. lab-mode
    # hostname advisory) mixed into its errors list; these must not block generate/save.
    infra_true_errors   = [e for e in infra_errors if not e.startswith(("[WARNING]", "[INFO]"))]
    infra_warnings_list = [e for e in infra_errors if e.startswith(("[WARNING]", "[INFO]"))]

    all_errors   = infra_true_errors + sup_errors + cross_errors
    all_warnings = infra_warnings_list + [f"[WARNING] {w}" for w in sup_warnings]
    return infra_built, sup_built, all_errors, all_warnings


class ConfigHandler(BaseHTTPRequestHandler):

    # Set by main() before the server starts; avoids a mutable module-level global.
    base_dir: Path = _DEFAULT_BASE_DIR

    def log_message(self, fmt, *args):
        print(f"[{self.log_date_time_string()}] {fmt % args}")

    def handle(self):
        """Wraps the request lifecycle to suppress benign client-disconnect errors.

        ConnectionAbortedError (WinError 10053 on Windows), ConnectionResetError,
        and BrokenPipeError are normal browser pre-close events that occur when the
        browser speculatively opens a second connection and aborts it before the
        server finishes sending. They are not server errors and should not be logged.
        Catching them here prevents the traceback from appearing even on Python 3.14+
        where the error surfaces inside handle_one_request rather than propagating to
        the socketserver error handler.
        """
        try:
            super().handle()
        except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
            pass

    def handle_error(self, request, client_address):
        """Suppresses benign client-disconnect errors at the socketserver level."""
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionAbortedError, ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)

    def _send_security_headers(self):
        """Sends common security headers on every response.

        X-Content-Type-Options prevents MIME-sniffing of JSON/ZIP responses as
        executable content. Cache-Control ensures configuration data is not
        cached by the browser. X-Frame-Options and CSP defend against
        clickjacking and injection if the server is ever exposed beyond
        localhost (e.g. via --host 0.0.0.0).

        'unsafe-inline' in script-src and style-src is required by the
        self-contained SPA (all JS and CSS live in the HTML_PAGE constant);
        browsers only enforce CSP on HTML documents, so this header is harmless
        on JSON and ZIP responses.
        """
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'"
        )

    def send_json(self, status, data):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def send_bytes(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self._send_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def read_body_json(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            raise ValueError("Invalid or missing Content-Length header.") from None
        if length < 0 or length > _MAX_BODY_BYTES:
            raise ValueError(f"Request body too large or invalid ({length} bytes; limit is {_MAX_BODY_BYTES}).")
        raw = self.rfile.read(length)
        return json.loads(raw)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        if path == "/":
            body = HTML_PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self._send_security_headers()
            self.end_headers()
            self.wfile.write(body)

        elif path == "/templates":
            self._handle_templates()

        elif path == "/info":
            base_dir = self.__class__.base_dir
            self.send_json(200, {
                "version": UI_VERSION,
                "base_dir": str(base_dir),
                "base_dir_exists": base_dir.is_dir(),
                "readme_url": README_URL,
            })

        else:
            self.send_json(404, {"error": "Not found."})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/validate":
            self._handle_validate()
        elif path == "/validate-step":
            self._handle_validate_step()
        elif path == "/generate":
            self._handle_generate()
        elif path == "/save":
            self._handle_save()
        elif path == "/templates-custom":
            self._handle_templates_custom()
        elif path == "/connectivity-check":
            self._handle_connectivity_check()
        else:
            self.send_json(404, {"error": "Not found."})

    def _handle_templates(self):
        """Returns the infrastructure.json and supervisor.json from the resolved base directory."""
        base_dir = self.__class__.base_dir
        infra_path = base_dir / "infrastructure.json"
        sup_path = base_dir / "supervisor.json"
        try:
            with open(infra_path, encoding="utf-8") as f:
                infra = json.load(f)
            with open(sup_path, encoding="utf-8") as f:
                supervisor = json.load(f)
            self.send_json(200, {
                "infrastructure": infra,
                "supervisor": supervisor,
                "_source": str(base_dir),
            })
        except FileNotFoundError as exc:
            self.send_json(404, {
                "error": (
                    f"JSON file not found in base directory '{base_dir}': {exc.filename}. "
                    "Run 'Start-VcfEdgeAtScale -Initialize' first, or pass --base-dir to point "
                    "at the directory containing infrastructure.json and supervisor.json."
                )
            })
        except json.JSONDecodeError as exc:
            self.send_json(500, {"error": f"JSON file is malformed: {exc}"})
        except (PermissionError, UnicodeDecodeError) as exc:
            self.send_json(500, {"error": f"Could not read file: {exc}"})

    def _handle_connectivity_check(self):
        """
        POST /connectivity-check
        Body: { "hosts": ["host1", "host2", ...] }
        Probes each host on TCP 443 with a TLS handshake in parallel.
        Certificate errors are ignored (self-signed certs are expected).
        Returns JSON: { "results": [ { host, reachable, latency_ms, error }, ... ] }

        POST is used (not GET) so that a cross-origin page cannot trigger outbound
        probes to attacker-supplied hosts via a simple GET request (CSRF).
        """
        try:
            payload = self.read_body_json()
        except (json.JSONDecodeError, ValueError) as exc:
            self.send_json(400, {"error": f"Invalid JSON payload: {exc}"})
            return
        hosts = [str(h).strip() for h in payload.get("hosts", []) if str(h).strip()]

        if not hosts:
            self.send_json(400, {"error": "No hosts specified. Provide { \"hosts\": [\"host1\", \"host2\"] } in the request body."})
            return

        if len(hosts) > 50:
            self.send_json(400, {"error": "Too many hosts (max 50 per request)."})
            return

        # Validate each host is a recognizable FQDN or IPv4 before attempting network I/O.
        for host in hosts:
            if not is_valid_fqdn_or_ip(host):
                self.send_json(400, {"error": f"Invalid host: '{host}'. Must be a valid FQDN or IPv4 address."})
                return

        with concurrent.futures.ThreadPoolExecutor(max_workers=min(len(hosts), _MAX_CONNECTIVITY_WORKERS)) as pool:
            results = list(pool.map(_check_host_https, hosts))

        self.send_json(200, {"results": results})

    def _handle_templates_custom(self):
        """Loads infrastructure.json and supervisor.json from a caller-specified directory."""
        try:
            payload = self.read_body_json()
        except (json.JSONDecodeError, ValueError) as exc:
            self.send_json(400, {"error": f"Invalid JSON: {exc}"})
            return

        custom_dir = Path(str(payload.get("path", "")).strip()).expanduser().resolve()

        # Restrict traversal to within the user's home directory to prevent a
        # browser tab from reading arbitrary paths on the local filesystem.
        # is_relative_to() is used instead of a startswith() string comparison
        # because startswith() has a prefix-collision bug on all platforms:
        # e.g. /home/user would incorrectly match /home/userEvil.
        home_dir = Path.home().resolve()
        if not custom_dir.is_relative_to(home_dir):
            self.send_json(400, {"error": "Custom path must be within your home directory."})
            return

        if not custom_dir.is_dir():
            self.send_json(400, {"error": f"Directory does not exist: {custom_dir}"})
            return

        infra_path = custom_dir / "infrastructure.json"
        sup_path = custom_dir / "supervisor.json"
        try:
            with open(infra_path, encoding="utf-8") as f:
                infra = json.load(f)
            with open(sup_path, encoding="utf-8") as f:
                supervisor = json.load(f)
            self.send_json(200, {
                "infrastructure": infra,
                "supervisor": supervisor,
                "_source": str(custom_dir),
            })
        except FileNotFoundError as exc:
            self.send_json(400, {"error": f"File not found: {exc.filename}"})
        except json.JSONDecodeError as exc:
            self.send_json(400, {"error": f"JSON is malformed: {exc}"})
        except (PermissionError, UnicodeDecodeError) as exc:
            self.send_json(400, {"error": f"Could not read file: {exc}"})

    def _handle_validate_step(self):
        """
        Validates only the fields relevant to a specific wizard step.
        step 1 = Common Settings, step 2 = Edge Sites, step 3 = Supervisor.
        Returns PS-style [ERROR]/[WARNING]/[INFO] messages with a pass/fail flag.
        """
        try:
            payload = self.read_body_json()
        except (json.JSONDecodeError, ValueError) as exc:
            self.send_json(400, {"errors": [f"[ERROR] Invalid JSON payload: {exc}"]})
            return

        step = payload.get("step", 1)
        messages = []

        try:
            # Build only what this step requires — step 1 and 2 only need infra;
            # step 3 needs both. Avoids redundant builds on every wizard navigation.
            infra_built = build_infrastructure(payload.get("infrastructure", {}))
            sup_built = build_supervisor(payload.get("supervisor", {})) if step == 3 else None
        except Exception as exc:
            traceback.print_exc()
            self.send_json(200, {
                "passed": False,
                "messages": [f"[ERROR] Could not parse configuration: {type(exc).__name__}: {exc}"],
            })
            return

        try:
            if step == 1:
                messages = _validate_step1_messages(infra_built, base_dir=self.__class__.base_dir)
            elif step == 2:
                infra_errors, cluster_segment_names, _ = validate_infrastructure(infra_built)
                messages = _format_infra_messages(infra_errors, infra_built)
            elif step == 3:
                # Validate infrastructure first so those errors are also surfaced on Step 3,
                # then pass the segment maps through to supervisor validation.
                infra_errors, cluster_segment_names, cluster_segment_gateways = validate_infrastructure(infra_built)
                sup_errors, sup_warnings = validate_supervisor(sup_built, cluster_segment_names, cluster_segment_gateways)
                infra_sites = [c.get("edgeSite", "") for c in infra_built.get("clusters", [])]
                sup_sites = [s.get("edgeSite", "") for s in sup_built.get("siteSpec", [])]
                cross_errors = validate_cross_file(infra_sites, sup_sites)
                messages = (
                    [_fmt(e) for e in infra_errors + sup_errors + cross_errors]
                    + [f"[WARNING] {w}" for w in sup_warnings]
                )
            else:
                messages = ["[ERROR] Unknown step."]
        except Exception as exc:
            traceback.print_exc()
            self.send_json(200, {
                "passed": False,
                "messages": [f"[ERROR] Unexpected validation error: {type(exc).__name__}: {exc}"],
            })
            return

        passed = not any(m.startswith("[ERROR]") for m in messages)
        if passed and not messages:
            step_labels = {1: "Common Settings", 2: "Edge Sites", 3: "Supervisor Config"}
            messages = [f"[INFO] {step_labels.get(step, 'Step ' + str(step))}: all checks passed."]

        self.send_json(200, {"passed": passed, "messages": messages})

    def _handle_validate(self):
        """Validates the infrastructure and supervisor dicts, returns errors + warnings + built JSON."""
        try:
            payload = self.read_body_json()
        except (json.JSONDecodeError, ValueError) as exc:
            self.send_json(400, {"errors": [f"Invalid JSON payload: {exc}"]})
            return

        try:
            infra_built, sup_built, all_errors, all_warnings = _build_and_validate(payload)
        except Exception as exc:
            traceback.print_exc()
            self.send_json(400, {"errors": [f"Validation failed: {type(exc).__name__}: {exc}"]})
            return

        self.send_json(200, {
            "errors": all_errors + all_warnings,
            "infrastructure": infra_built,
            "supervisor": sup_built,
        })

    def _handle_generate(self):
        """Validates and returns a zip file containing both JSON files."""
        try:
            payload = self.read_body_json()
        except (json.JSONDecodeError, ValueError) as exc:
            self.send_json(400, {"errors": [f"Invalid JSON payload: {exc}"]})
            return

        try:
            infra_built, sup_built, all_errors, all_warnings = _build_and_validate(payload)
        except ValueError as exc:
            self.send_json(400, {"errors": [str(exc)]})
            return

        if all_errors:
            self.send_json(422, {"errors": all_errors + all_warnings})
            return

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("infrastructure.json", json.dumps(infra_built, indent=2))
            zf.writestr("supervisor.json", json.dumps(sup_built, indent=2))
        body = buf.getvalue()

        self.send_bytes(200, "application/zip", body)

    def _handle_save(self):
        """Validates, backs up existing files, then writes both JSON files to base_dir."""
        try:
            payload = self.read_body_json()
        except (json.JSONDecodeError, ValueError) as exc:
            self.send_json(400, {"errors": [f"Invalid JSON payload: {exc}"]})
            return

        try:
            infra_built, sup_built, all_errors, all_warnings = _build_and_validate(payload)
        except ValueError as exc:
            self.send_json(400, {"errors": [str(exc)]})
            return

        if all_errors:
            self.send_json(422, {"errors": all_errors + all_warnings})
            return

        base_dir = self.__class__.base_dir
        timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        infra_path = base_dir / "infrastructure.json"
        sup_path = base_dir / "supervisor.json"
        backups = []

        try:
            base_dir.mkdir(parents=True, exist_ok=True)

            # Backup existing files into a dedicated Backup/ subdirectory.
            # On Linux/macOS, chmod 600 restricts backup files to owner-only access so
            # they are not world-readable when the server runs with a permissive umask.
            # On Windows, Path.chmod() maps to the read-only attribute only (ACLs control
            # real access), so this call is a no-op from a security standpoint there —
            # acceptable since the tool runs as a single-user localhost process on Windows.
            backup_dir = base_dir / "Backup"
            backup_dir.mkdir(exist_ok=True)
            for src_path in (infra_path, sup_path):
                if src_path.exists():
                    backup_path = backup_dir / f"{src_path.name}.bak-{timestamp}"
                    backup_path.write_bytes(src_path.read_bytes())
                    backup_path.chmod(0o600)
                    backups.append(str(backup_path))

            # Write new files atomically via sibling temp files.
            for dest_path, content in (
                (infra_path, json.dumps(infra_built, indent=2)),
                (sup_path, json.dumps(sup_built, indent=2)),
            ):
                tmp_path = dest_path.with_name(dest_path.name + ".tmp")
                tmp_path.write_text(content, encoding="utf-8")
                tmp_path.replace(dest_path)

        except OSError as exc:
            self.send_json(500, {"errors": [f"Failed to write files: {exc}"]})
            return

        self.send_json(200, {
            "saved": True,
            "base_dir": str(base_dir),
            "backups": backups,
        })


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="VcfEdgeAtScale JSON Configuration UI — stdlib-only web server."
    )
    parser.add_argument("--port", type=int, default=8080, help="TCP port to listen on (default: 8080)")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind to (default: 127.0.0.1)")
    parser.add_argument(
        "--base-dir",
        default=None,
        help=(
            "Directory containing infrastructure.json and supervisor.json "
            "(default: the parent of this script's directory, i.e. the deployment base created by "
            "Start-VcfEdgeAtScale -Initialize). Falls back to the Templates/ sibling directory if "
            "the default does not exist."
        ),
    )
    args = parser.parse_args()

    if args.base_dir:
        base_dir = Path(args.base_dir).expanduser().resolve()
    elif _DEFAULT_BASE_DIR.exists():
        base_dir = _DEFAULT_BASE_DIR
    else:
        base_dir = _FALLBACK_TEMPLATES_DIR

    ConfigHandler.base_dir = base_dir

    try:
        server = HTTPServer((args.host, args.port), ConfigHandler)
    except OSError as exc:
        if exc.errno == 48 or exc.errno == 98:  # EADDRINUSE (macOS=48, Linux=98)
            print(
                f"ERROR: Port {args.port} is already in use.\n"
                f"  Another instance of this server may already be running.\n"
                f"  Try one of the following:\n"
                f"    • Open http://{args.host}:{args.port} in your browser — it may already be ready.\n"
                f"    • Run with a different port:  python3 veas-json-generator.py --port 8081\n"
                f"    • Find and stop the existing process:\n"
                f"        macOS/Linux:  lsof -ti :{args.port} | xargs kill\n"
                f"        Windows:      netstat -ano | findstr :{args.port}"
            )
            sys.exit(1)
        raise

    url = f"http://{args.host}:{args.port}"
    print("VcfEdgeAtScale Configuration UI")
    print(f"Listening on  {url}")
    print(f"Base directory: {base_dir}")
    if not (base_dir / "infrastructure.json").exists():
        print("  WARNING: infrastructure.json not found in base directory.")
        print("  Run 'Start-VcfEdgeAtScale -Initialize' or pass --base-dir to set the correct path.")
    print(f"Open {url} in your browser to begin.")
    print("Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()
        sys.exit(0)


if __name__ == "__main__":
    main()
