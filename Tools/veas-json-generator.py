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
#   Default base-dir: the parent directory of this script (i.e. <deploy-root>/Tools/../ = <deploy-root>).
#                     When installed via Start-VcfEdgeAtScale -Initialize this resolves to the
#                     deployment root (e.g. ~/VCFEdgeAtScale).  When running directly from the
#                     module source tree it resolves to the repo's VcfEdgeAtScale/ directory.
#                     Falls back to <script-dir>/../Templates/ if infrastructure.json is absent.
import argparse
import concurrent.futures
import datetime
import errno
import io
import ipaddress
import json
import os
import re
import socket
import ssl
import sys
import threading
import time
import traceback
import webbrowser
import zipfile
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).parent.resolve()
# When installed via -Initialize, this script lives at <BaseDir>/Tools/veas-json-generator.py,
# so SCRIPT_DIR.parent is the deployment base directory. Falls back to <BaseDir>/Templates/
# (which mirrors the module layout when running directly from the module source tree).
_DEFAULT_BASE_DIR = SCRIPT_DIR.parent
_FALLBACK_TEMPLATES_DIR = SCRIPT_DIR.parent / "Templates"

# Must stay in sync with VEAS-UI-VERSION in veas-ui.html.
UI_VERSION = "1.0.3.1013"
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
# Default workload service IP count. Must be a power of 2 (determines the Kubernetes service
# CIDR block size, e.g. 512 = /23). Used as the server-side build default and injected into
# the UI so both sides always agree. Change this constant to change both simultaneously.
_DEFAULT_WORKLOAD_SERVICE_COUNT = 512
# Workload service IP pool bounds. The count must be a power of 2 to align with a CIDR
# boundary. 256 = /24 (minimum sensible Kubernetes service range); 65536 = /16 (practical
# ceiling). Values outside this range pass the power-of-two check but produce unusable or
# absurdly large service CIDRs at deployment time.
_MIN_WORKLOAD_SERVICE_COUNT = 256
_MAX_WORKLOAD_SERVICE_COUNT = 65536
# Seconds to wait before opening the browser after the HTTP server starts, giving
# the server time to bind and begin accepting connections before the first request.
_BROWSER_OPEN_DELAY_SECONDS = 0.8
# Filename of the HTML UI template that must live alongside this script.
_TEMPLATE_FILE = "veas-ui.html"
# Set VEAS_DEBUG=1 in the environment to print full tracebacks to the console
# for unexpected server-side exceptions.  Off by default to keep operator
# output clean during normal use.
_DEBUG = os.environ.get("VEAS_DEBUG", "").strip() not in ("", "0", "false")
# VMkernel MTU bounds. 1500 is standard Ethernet; 9190 is the VMware jumbo-frame ceiling.
# Management and vSAN Witness VMkernels are always 1500 regardless of this setting.
_MIN_VMK_MTU = 1500
_MAX_VMK_MTU = 9190
# Bind address for the HTTP server. Localhost only — the server has no TLS and is
# not designed for network exposure. Use SSH port-forwarding for remote access.
_BIND_HOST = "127.0.0.1"

# Resolved once at import time so every path-safety check uses the same anchor
# and avoids repeated syscalls.
_HOME_DIR = Path.home().resolve()


def _safe_resolve_path(path_str: str) -> "Path | None":
    """Resolves *path_str* and returns it only when the result lies within the
    current user's home directory.

    Returns None for empty strings, unresolvable values, or paths that escape
    the home tree.  Callers must treat a None return as an untrusted path and
    reject it with an appropriate error message rather than using it for any
    filesystem operation.
    """
    if not path_str:
        return None
    try:
        resolved = Path(path_str).expanduser().resolve()
    except (TypeError, ValueError, RuntimeError):
        return None
    return resolved if resolved.is_relative_to(_HOME_DIR) else None


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
# vSphere object names: 1–80 chars, alphanumeric + space _ + - () .
# Dots are allowed because vSphere datacenter/cluster/VDS names commonly include them.
# Keep in sync with _isValidVsphereLabel in veas-ui.html.
VSPHERE_NAME_RE = re.compile(r"^[a-zA-Z0-9 _+\-().]{1,80}$")
# vCenter user: alphanumeric + . _ @ -
VCENTER_USER_RE = re.compile(r"^[a-zA-Z0-9._@\-]{1,256}$")
# FQDN or IPv4.
# Each FQDN label uses [a-zA-Z0-9\-_] (no dot) so that the dot can only ever
# be consumed as the explicit label separator \. and never by the character
# class.  Including dot in the class creates two competing ways to consume a
# '.' which allows exponential backtracking on inputs like '0.0.0.0.0.0.'.
FQDN_OR_IPV4_RE = re.compile(
    r"^(?:"
    r"(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
    r"|[a-zA-Z0-9](?:[a-zA-Z0-9\-_]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9\-_]*[a-zA-Z0-9])?)*"
    r")$"
)
# Harbor volume size: positive integer followed by Gi
VOLUME_SIZE_RE = re.compile(r"^[1-9]\d*Gi$")
# PowerShell environment-variable reference: $env: followed by a valid identifier (must have
# at least one character after the colon so bare "$env:" is rejected).
ENV_VAR_RE = re.compile(r"^\$env:[A-Za-z_][A-Za-z0-9_]*$")


def is_valid_ipv4(value):
    return bool(IPV4_RE.match(str(value).strip()))


def is_valid_cidr(value):
    return bool(CIDR_RE.match(str(value).strip()))


def is_valid_rfc1123(value):
    """Validates that a name matches RFC1123 (lowercase, 1–80 chars, no leading/trailing hyphen)."""
    return bool(RFC1123_RE.match(str(value).strip()))


def is_valid_fqdn_or_ip(value):
    """Returns True when value is a valid FQDN or IPv4 address.

    Strings containing only digits and dots are treated as IPv4 attempts and must
    pass strict IPv4 validation. This prevents all-digit labels like "10.0.0.12345"
    from slipping through as technically valid (but nonsensical) FQDNs.
    """
    val = str(value).strip()
    if re.match(r'^[\d.]+$', val):
        return is_valid_ipv4(val)
    return bool(FQDN_OR_IPV4_RE.match(val))


def is_valid_netmask(value):
    """Validates that value is a proper subnet mask (all-1s followed by all-0s in binary).

    Each octet must be a valid 8-bit value (0–255). Rejecting out-of-range octets prevents
    an integer overflow in the bit-math that would otherwise cause e.g. '256.0.0.0' to pass.
    """
    try:
        parts = str(value).strip().split(".")
        if len(parts) != 4:
            return False
        bits = 0
        for part in parts:
            octet = int(part)
            if octet < 0 or octet > 255:
                return False
            bits = (bits << 8) | octet
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


def validate_vlan_id(value, field_path: str) -> str | None:
    """Returns an error string if the VLAN ID is invalid, else None."""
    try:
        vid = int(value)
        if vid < 0 or vid > 4095:
            return f"{field_path}: VLAN ID must be 0–4095, got {value}."
    except (TypeError, ValueError):
        return f"{field_path}: VLAN ID must be an integer, got '{value}'."
    return None


def _validate_common(common: dict, errors: list[str], warnings: list[str]) -> None:
    """Validates the infrastructure.common block, appending errors and warnings in place."""
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
            "infrastructure.common.datacenterName: must be 1–80 chars, alphanumeric with spaces, _, +, -, (), ."
        )

    if not common.get("contextName"):
        warnings.append(
            "infrastructure.common.contextName: not set. "
            "Required unless all clusters disable all supervisor services (ArgoCD and Harbor)."
        )

    for prefix_field in ("clusterNamePrefix", "datastoreNamePrefix", "supervisorNamePrefix", "vdsNamePrefix"):
        val = common.get(prefix_field, "")
        if val and not VSPHERE_NAME_RE.match(val):
            errors.append(
                f"infrastructure.common.{prefix_field}: must be 1–80 chars, "
                "alphanumeric with spaces, _, +, -, (), ."
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
                if mtu_int < _MIN_VMK_MTU or mtu_int > _MAX_VMK_MTU:
                    errors.append(
                        f"infrastructure.common.{mtu_key}: must be between {_MIN_VMK_MTU} and {_MAX_VMK_MTU}."
                    )
            except (TypeError, ValueError):
                errors.append(f"infrastructure.common.{mtu_key}: must be an integer.")


def _validate_harbor(harbor: dict, prefix: str, errors: list[str]) -> None:
    """Validates a harborConfiguration block, appending errors in place."""
    hostname = harbor.get("hostname", "")
    if hostname and not is_valid_fqdn_or_ip(hostname):
        errors.append(
            f"{prefix}.harborConfiguration.hostname: '{hostname}' must be a valid FQDN or IPv4 address."
        )

    secret_key = harbor.get("secretKey", "")
    if secret_key and not ENV_VAR_RE.match(secret_key) and len(secret_key) != 16:
        errors.append(
            f"{prefix}.harborConfiguration.secretKey: must be exactly 16 characters (AES-128) "
            "or a valid env-var reference (e.g. '$env:HARBOR_SECRET_KEY')."
        )

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

    for secret_field in ("harborAdminPassword", "databasePassword", "coreSecret",
                         "jobserviceSecret", "registrySecret"):
        val = harbor.get(secret_field, "")
        if val and val.startswith("$") and not ENV_VAR_RE.match(val):
            errors.append(
                f"{prefix}.harborConfiguration.{secret_field}: value starting with '$' must be a "
                "valid environment variable reference using the format $env:VARNAME "
                "(VARNAME must start with a letter or underscore and contain only letters, digits, and underscores)."
            )


def _validate_vmk_interfaces(vmk_interfaces, storage_type: str, prefix: str, errors: list[str], segment_vlans: set[str] | None = None) -> None:
    """
    Validates networkingVmKernelInterfaces for a vSAN cluster, appending errors in place.
    segment_vlans: set of VLAN IDs (as strings) already occupied by networkSegments; when
    provided, any VMkernel interface that shares a VLAN with a segment is flagged as an error
    because vSAN/vMotion traffic must run on dedicated VLANs (separate DVPort Groups).
    """
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
        elif segment_vlans is not None:
            vid = str(vmk.get("vlanId"))
            if vid in segment_vlans:
                errors.append(
                    f"{vmk_prefix}.vlanId: VLAN {vid} is already used by a networkSegment. "
                    "VMkernel interfaces require dedicated VLANs (separate DVPort Groups)."
                )

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


def _validate_networking(networking: dict, storage_type: str | None, prefix: str, errors: list[str]) -> tuple[list[str], dict[str, str]]:
    """
    Validates a cluster's networking block, appending errors in place.
    Returns (seg_names, seg_gw_map) for the cluster's segments (both empty on validation failure).
    """
    segments = networking.get("networkSegments")
    seg_names = []
    seg_gw_map = {}

    seen_vlans: set[str] = set()
    if not isinstance(segments, list) or len(segments) == 0:
        errors.append(f"{prefix}.networking.networkSegments: must be a non-empty array.")
    else:
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
            if not gw:
                errors.append(
                    f"{seg_prefix}.gateway: required field is missing or empty."
                )
            elif not is_valid_cidr(gw):
                errors.append(
                    f"{seg_prefix}.gateway: must be a valid CIDR (e.g. 10.0.0.1/24), got '{gw}'."
                )
            elif seg_name:
                seg_gw_map[seg_name] = gw

    if storage_type in ("vSAN-OSA", "vSAN-ESA"):
        _validate_vmk_interfaces(
            networking.get("networkingVmKernelInterfaces"), storage_type, prefix, errors,
            segment_vlans=seen_vlans,
        )

    return seg_names, seg_gw_map


def _resolve_bool(cluster: dict, common: dict, key: str) -> bool:
    """
    Resolves a boolean flag from cluster supervisorServices, then common supervisorServices.
    A JSON null value (Python None) is treated as absent — not as False — so that a null
    entry does not override an explicit True at the common level, and does not silently
    disable a service the user intended to keep enabled.
    """
    cluster_svcs = cluster.get("supervisorServices", {}) or {}
    common_svcs = common.get("supervisorServices", {}) or {}
    for svcs in (cluster_svcs, common_svcs):
        val = svcs.get(key)
        if val is not None:
            return bool(val)
    return False


def _validate_storage_policy(
    cluster: dict, esx_hosts, common: dict, prefix: str, errors: list[str]
) -> str | None:
    """Validates storagePolicy, per-type host counts, and vSAN witness for one cluster.

    Returns the resolved storageType string on success, or None when storagePolicy is absent
    or its storageType is unrecognized (errors are appended in place in both cases).
    """
    storage_policy = cluster.get("storagePolicy")
    storage_type = None
    if not isinstance(storage_policy, dict):
        errors.append(f"{prefix}.storagePolicy: required object is missing.")
        return None

    storage_type = storage_policy.get("storageType")
    if storage_type not in ("VMFS", "vSAN-ESA", "vSAN-OSA"):
        errors.append(
            f"{prefix}.storagePolicy.storageType: must be 'VMFS', 'vSAN-ESA', or 'vSAN-OSA'."
        )
        storage_type = None

    storage_policy_rule = storage_policy.get("storagePolicyRule")
    if storage_policy_rule is not None and storage_policy_rule != "Fully initialized":
        errors.append(
            f"{prefix}.storagePolicy.storagePolicyRule: only valid value is 'Fully initialized'."
        )

    # Only check per-storage-type host counts when the array is non-empty.
    # An empty array is already reported above; emitting a count error on top would
    # produce two errors for the same field (e.g. "must be non-empty" + "VMFS requires 1").
    if isinstance(esx_hosts, list) and len(esx_hosts) > 0 and storage_type in ("VMFS", "vSAN-OSA", "vSAN-ESA"):
        if storage_type == "VMFS":
            if len(esx_hosts) != 1:
                errors.append(f"{prefix}.esxHosts: VMFS requires exactly 1 host, got {len(esx_hosts)}.")
        else:
            if len(esx_hosts) != _VSAN_HOST_COUNT:
                errors.append(
                    f"{prefix}.esxHosts: {storage_type} requires exactly {_VSAN_HOST_COUNT} hosts, "
                    f"got {len(esx_hosts)}."
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

    return storage_type


def _validate_cluster(cluster, idx: int, common: dict, common_nic_list, errors: list[str], warnings: list[str]) -> tuple[str | None, list[str], dict[str, str]]:
    """
    Validates a single cluster entry, appending errors and warnings in place.
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

    storage_type = _validate_storage_policy(cluster, esx_hosts, common, prefix, errors)

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
                warnings.append(
                    f"{prefix}.harborConfiguration.hostname: not set; "
                    "lab mode is enabled so hostname will be read from the Harbor data-values YAML template at runtime."
                )
            else:
                errors.append(
                    f"{prefix}.harborConfiguration.hostname: required unless disableHarbor is true."
                )
        if isinstance(harbor, dict):
            _validate_harbor(harbor, prefix, errors)

    return edge_site, seg_names, seg_gw_map


@dataclass
class InfraValidationResult:
    """Structured result returned by validate_infrastructure.

    Separating these four values into named fields avoids the positional-index
    guessing game that a 4-tuple imposes on every call site.
    """

    errors: list[str]
    warnings: list[str]
    cluster_segment_names: dict[str, list[str]]
    cluster_segment_gateways: dict[str, dict[str, str]]

    @property
    def passed(self) -> bool:
        """True when no blocking errors were found."""
        return not bool(self.errors)


def validate_infrastructure(infra: dict) -> InfraValidationResult:
    """
    Validates an infrastructure dict against all known rules.
    Returns an InfraValidationResult; .errors block generation, .warnings are advisory.
    """
    errors: list[str] = []
    warnings: list[str] = []

    common = infra.get("common")
    if not isinstance(common, dict):
        errors.append("infrastructure: missing or invalid 'common' object.")
        return InfraValidationResult(errors=errors, warnings=warnings, cluster_segment_names={}, cluster_segment_gateways={})

    _validate_common(common, errors, warnings)

    clusters = infra.get("clusters")
    if not isinstance(clusters, list) or len(clusters) == 0:
        errors.append("infrastructure.clusters: must be a non-empty array.")
        return InfraValidationResult(errors=errors, warnings=warnings, cluster_segment_names={}, cluster_segment_gateways={})

    seen_edge_sites = set()
    cluster_segment_names = {}
    cluster_segment_gateways = {}

    for idx, cluster in enumerate(clusters):
        edge_site, seg_names, seg_gw_map = _validate_cluster(
            cluster, idx, common, common.get("nicList"), errors, warnings
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

    # Global: ESX host names/IPs must be unique across ALL clusters (case-insensitive).
    seen_esx_hosts: dict[str, str] = {}
    for idx, cluster in enumerate(clusters):
        site = cluster.get("edgeSite") or f"clusters[{idx}]"
        for host in (cluster.get("esxHosts") or []):
            if not host:
                continue
            host_key = host.lower()
            if host_key in seen_esx_hosts:
                errors.append(
                    f"infrastructure: ESX host '{host}' appears in both edgeSite "
                    f"'{seen_esx_hosts[host_key]}' and '{site}'. "
                    "Each ESX host must be unique across all edge sites."
                )
            else:
                seen_esx_hosts[host_key] = site

    return InfraValidationResult(
        errors=errors,
        warnings=warnings,
        cluster_segment_names=cluster_segment_names,
        cluster_segment_gateways=cluster_segment_gateways,
    )


@dataclass
class SupervisorValidationResult:
    """Structured result returned by validate_supervisor.

    Mirrors InfraValidationResult so both validators have a consistent,
    named-field return type rather than requiring callers to track tuple order.
    """

    errors: list[str]
    warnings: list[str]

    @property
    def passed(self) -> bool:
        """True when no blocking errors were found."""
        return not bool(self.errors)


def validate_supervisor(
    supervisor: dict,
    cluster_segment_names: dict[str, list[str]],
    cluster_segment_gateways: dict[str, dict[str, str]] | None = None,
) -> SupervisorValidationResult:
    """
    Validates a supervisor dict against all known rules.
    cluster_segment_names: dict of {edgeSite: [segment_name, ...]} from infrastructure validation.
    cluster_segment_gateways: dict of {edgeSite: {segment_name: cidr_gateway}} for IP-in-range checks.
    Returns a SupervisorValidationResult; .errors block generation, .warnings are advisory.
    """
    if cluster_segment_gateways is None:
        cluster_segment_gateways = {}
    errors = []
    warnings = []

    common_spec = supervisor.get("commonSupervisorSpec")
    if not isinstance(common_spec, dict):
        errors.append("supervisor: missing or invalid 'commonSupervisorSpec' object.")
        return SupervisorValidationResult(errors=errors, warnings=warnings)

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
        return SupervisorValidationResult(errors=errors, warnings=warnings)

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
                f"supervisor.siteSpec: infrastructure edgeSite '{name}' has no matching "
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
                    # Skip the cross-check when either side is empty — the empty-field
                    # validator already covers that case and we must not block mid-edit.
                    site_gateways = cluster_segment_gateways.get(edge_site, {})
                    cidr = site_gateways.get(net_name, "") if net_name else ""
                    if cidr and is_valid_cidr(cidr) and start_ip and is_valid_ipv4(start_ip):
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
            else:
                # Skip the cross-check when the gateway CIDR is empty — the empty-field
                # validator already covers that case and we must not block mid-edit.
                mgmt_cidr = site_gateways.get(mgmt_name, "") if mgmt_name else ""
                if mgmt_cidr and is_valid_cidr(mgmt_cidr) and not is_ip_in_cidr(mgmt_start, mgmt_cidr):
                    errors.append(
                        f"{prefix}.mgmtNetworkSpec.mgmtNetworkStartingIp: '{mgmt_start}' is not within "
                        f"the gateway subnet {mgmt_cidr} for segment '{mgmt_name}'."
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
            else:
                # Skip the cross-check when the gateway CIDR is empty — the empty-field
                # validator already covers that case and we must not block mid-edit.
                pwn_cidr = site_gateways.get(pwn_name, "") if pwn_name else ""
                if pwn_cidr and is_valid_cidr(pwn_cidr) and not is_ip_in_cidr(pwn_start, pwn_cidr):
                    errors.append(
                        f"{prefix}.primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp: '{pwn_start}' is not within "
                        f"the gateway subnet {pwn_cidr} for segment '{pwn_name}'."
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
            try:
                wsc_int = int(wsc) if wsc is not None else None
            except (TypeError, ValueError):
                wsc_int = None
            if wsc_int is None or not is_power_of_two(wsc_int):
                errors.append(
                    f"{prefix}.primaryWorkloadNetwork.workloadServiceCount: "
                    f"must be a power of 2 (e.g. 256, 512, 1024) to occupy a full CIDR block."
                )
            elif not (_MIN_WORKLOAD_SERVICE_COUNT <= wsc_int <= _MAX_WORKLOAD_SERVICE_COUNT):
                errors.append(
                    f"{prefix}.primaryWorkloadNetwork.workloadServiceCount: "
                    f"{wsc_int} is outside the supported range "
                    f"({_MIN_WORKLOAD_SERVICE_COUNT}–{_MAX_WORKLOAD_SERVICE_COUNT}); "
                    f"valid values produce /24 through /16 CIDR blocks."
                )

    # Cross-site: workloadServiceStartIp must be unique across all sites because each site's
    # Kubernetes service CIDR must not overlap with another site's range.
    seen_svc_start_ips = {}
    for site in site_specs:
        if not isinstance(site, dict):
            continue
        pwn = site.get("primaryWorkloadNetwork")
        svc_ip = (pwn or {}).get("workloadServiceStartIp", "")
        edge_site = site.get("edgeSite", "")
        if svc_ip and is_valid_ipv4(svc_ip):
            if svc_ip in seen_svc_start_ips:
                errors.append(
                    f"supervisor.siteSpec: duplicate workloadServiceStartIp '{svc_ip}' used by "
                    f"edgeSite '{seen_svc_start_ips[svc_ip]}' and '{edge_site}'. "
                    f"Each site's Kubernetes service CIDR must not overlap."
                )
            else:
                seen_svc_start_ips[svc_ip] = edge_site

    return SupervisorValidationResult(errors=errors, warnings=warnings)


# ---------------------------------------------------------------------------
# Per-step validation message formatters (PS-style [ERROR]/[WARNING]/[INFO])
# ---------------------------------------------------------------------------

def _tag_error(error_str: str) -> str:
    """Converts a plain error string to a PS-style [ERROR] message.

    Strings that already carry a [ERROR] or [WARNING] prefix are passed through
    unchanged so pre-tagged messages (e.g. lab-mode warnings emitted directly by
    validation helpers) are not double-prefixed. [INFO] messages are never passed
    through this function — they are built separately in the message formatters.
    """
    if error_str.startswith(("[ERROR]", "[WARNING]")):
        return error_str
    return f"[ERROR] {error_str}"


def _validate_step1_messages(infra: dict, base_dir: Path | None = None) -> list[str]:
    """
    Validates only Step 1 (Common Settings) fields and returns PS-style messages.
    Delegates validation logic to _validate_common so rules are defined once.
    Adds [INFO] confirmations for fields that passed, and (when base_dir is provided)
    checks supervisorServices YAML filenames for existence on disk.
    """
    common = infra.get("common", {})

    # Collect errors and warnings from the shared validator; strip the "infrastructure.common."
    # prefix for the condensed step-1 display (the user is already on the common settings form).
    raw_errors: list[str] = []
    raw_warnings: list[str] = []
    _validate_common(common, raw_errors, raw_warnings)
    messages  = [_tag_error(e.replace("infrastructure.common.", "common.")) for e in raw_errors]
    messages += [f"[WARNING] {w.replace('infrastructure.common.', 'common.')}" for w in raw_warnings]

    # Add [INFO] confirmations for each field that produced no error.
    def _field_is_clean(*field_name_parts):
        """Returns True when no message in the current list mentions all given name parts."""
        return not any(all(part in msg for part in field_name_parts) for msg in messages)

    vc_name = common.get("vCenterName", "")
    if vc_name and _field_is_clean("vCenterName"):
        messages.append(f"[INFO] common.vCenterName: '{vc_name}' — format OK.")

    vc_user = common.get("vCenterUser", "")
    if vc_user and _field_is_clean("vCenterUser"):
        messages.append(f"[INFO] common.vCenterUser: '{vc_user}' — format OK.")

    dc = common.get("datacenterName", "")
    if dc and _field_is_clean("datacenterName"):
        messages.append(f"[INFO] common.datacenterName: '{dc}'.")

    nic_list = common.get("nicList", [])
    if isinstance(nic_list, list) and len(nic_list) in (2, 4) and _field_is_clean("nicList"):
        nics = ", ".join(n.get("name", "?") for n in nic_list)
        messages.append(f"[INFO] common.nicList: {len(nic_list)} NICs ({nics}) — OK.")

    ha_policy = common.get("haPolicy")
    if ha_policy and _field_is_clean("haPolicy"):
        messages.append(f"[INFO] common.haPolicy: '{ha_policy}'.")

    for mtu_key in ("vSanvMotionVmKernelMtuValue", "vmkernelMtu"):
        mtu = common.get(mtu_key)
        if mtu is not None and _field_is_clean(mtu_key):
            try:
                messages.append(f"[INFO] common.{mtu_key}: {int(mtu)} — OK.")
            except (TypeError, ValueError):
                pass

    # supervisorServices YAML file existence — unique to step-1 (requires base_dir).
    if base_dir is not None:
        svcs = common.get("supervisorServices", {}) or {}
        parent_dir_str = (svcs.get("parentDirectory") or "").strip()

        # Resolve the parent directory and confine it to the home tree so that
        # a crafted JSON payload cannot probe arbitrary filesystem paths.
        if parent_dir_str:
            parent_dir = _safe_resolve_path(parent_dir_str)
            if parent_dir is None:
                messages.append(
                    "[ERROR] supervisorServices.parentDirectory: the path must be within "
                    "your home directory."
                )
                parent_dir = None
            elif not parent_dir.is_dir():
                messages.append(
                    f"[ERROR] supervisorServices.parentDirectory: '{parent_dir}' does not "
                    "exist or is not a directory. Correct the path before specifying YAML filenames."
                )
                parent_dir = None
        else:
            parent_dir = Path(base_dir)

        if parent_dir is not None:
            yaml_fields = (
                ("argoCdOperatorYamlFileName",    "ArgoCD Operator YAML"),
                ("argoCdDeploymentYamlFileName",   "ArgoCD Deployment YAML"),
                ("harborDataTemplateYamlFileName", "Harbor Data Template YAML"),
                ("harborServiceYamlFileName",      "Harbor Service YAML"),
            )
            for field, label in yaml_fields:
                filename = (svcs.get(field) or "").strip()
                if not filename:
                    continue
                # Use only the basename so a crafted filename such as
                # '../../etc/shadow' cannot escape the parent directory.
                safe_name = Path(filename).name
                if safe_name != filename:
                    messages.append(
                        f"[ERROR] {label}: filename must not contain path separators."
                    )
                    continue
                full_path = parent_dir / safe_name
                if full_path.exists():
                    messages.append(f"[INFO] {label}: '{safe_name}' found — OK.")
                else:
                    messages.append(
                        f"[ERROR] {label}: '{safe_name}' not found in '{parent_dir}'. "
                        "Verify the filename is correct."
                    )

    return messages


def _validate_step2_harbor_files(infra: dict, base_dir: Path | None) -> list[str]:
    """
    Checks harborConfiguration.parentDirectory + TLS filename existence on disk for each
    cluster.  Only runs in launcher mode (when base_dir is available).

    Rules:
    - When parentDirectory is set but the directory does not exist, and at least one TLS
      filename (tlsCrt, tlsKey, caCrt) is also specified, emit an error for the directory.
    - When the directory exists, check each specified TLS filename (tlsCrt, tlsKey, caCrt)
      for existence and emit an error for any that are missing.
    - parentDirectory alone (without any TLS filename) is valid in lab mode and is not
      flagged here.

    Returns PS-style [ERROR]/[WARNING]/[INFO] messages.
    """
    if base_dir is None:
        return []
    messages: list[str] = []
    tls_fields = (
        ("tlsCrt", "TLS certificate"),
        ("tlsKey",  "TLS key"),
        ("caCrt",   "CA certificate"),
    )
    for cluster in infra.get("clusters", []) or []:
        site = cluster.get("edgeSite", "?")
        harbor = cluster.get("harborConfiguration") or {}
        parent_dir_str = (harbor.get("parentDirectory") or "").strip()
        if not parent_dir_str:
            continue

        # Resolve and confine to the home tree before any filesystem operation.
        parent_dir = _safe_resolve_path(parent_dir_str)
        if parent_dir is None:
            messages.append(
                f"[ERROR] infrastructure.clusters[\"{site}\"].harborConfiguration.parentDirectory: "
                "the path must be within your home directory."
            )
            continue

        tls_filenames_set = any((harbor.get(f) or "").strip() for f, _ in tls_fields)
        if not parent_dir.is_dir():
            if tls_filenames_set:
                messages.append(
                    f"[ERROR] infrastructure.clusters[\"{site}\"].harborConfiguration.parentDirectory: "
                    f"'{parent_dir}' does not exist or is not a directory. "
                    "Correct the path or remove parentDirectory if TLS is auto-generated (lab mode)."
                )
            continue
        for field, label in tls_fields:
            filename = (harbor.get(field) or "").strip()
            if not filename:
                continue
            # Use only the basename so a crafted filename cannot traverse outside parent_dir.
            safe_name = Path(filename).name
            if safe_name != filename:
                messages.append(
                    f"[ERROR] infrastructure.clusters[\"{site}\"].harborConfiguration.{field}: "
                    "filename must not contain path separators."
                )
                continue
            full_path = parent_dir / safe_name
            if full_path.exists():
                messages.append(
                    f"[INFO] Site '{site}': {label} '{safe_name}' found in '{parent_dir}' — OK."
                )
            else:
                messages.append(
                    f"[ERROR] infrastructure.clusters[\"{site}\"].harborConfiguration.{field}: "
                    f"'{safe_name}' not found in '{parent_dir}'. "
                    "Verify the filename and parentDirectory are correct."
                )
    return messages


def _format_infra_messages(errors: list[str], infra: dict) -> list[str]:
    """
    Converts infrastructure validation errors into PS-style messages,
    adding INFO confirmations for each cluster that has no errors of its own.

    INFO lines are emitted per-cluster regardless of whether other clusters
    have errors, so the user can see which sites are already valid while
    fixing the others.
    """
    messages = [_tag_error(e) for e in errors]
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

def _iget(d, key: str, default=None):
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


def _to_str_list(value) -> list[str]:
    """Converts a comma-separated string or list to a list of stripped strings."""
    if isinstance(value, list):
        return [s for v in value if (s := str(v).strip())]
    return [s.strip() for s in str(value).split(",") if s.strip()]


def _add_optional_str(target: dict, source: dict, key: str) -> None:
    val = _iget(source, key, "")
    if val:
        target[key] = val


def _add_optional_bool(target: dict, source: dict, key: str) -> None:
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


def _safe_int(value, default: int = 0) -> int:
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

def build_infrastructure(data: dict) -> dict:
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

    if common.get("vSanvMotionVmKernelMtuValue") is not None:
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

    clusters_out = [_build_cluster_obj(cluster) for cluster in data.get("clusters", [])]
    return {"common": common_obj, "clusters": clusters_out}


def _build_cluster_obj(cluster: dict) -> dict:
    """Builds a single cluster entry dict from raw form data.

    Called by build_infrastructure for each element of the clusters array.
    Handles both list and comma-string formats for esxHosts and nicList to
    support both the browser UI payload and hand-crafted JSON input.
    """
    cluster_obj = {"edgeSite": cluster.get("edgeSite", "")}

    esx_hosts_raw = cluster.get("esxHosts", "")
    if isinstance(esx_hosts_raw, list):
        cluster_obj["esxHosts"] = esx_hosts_raw
    else:
        cluster_obj["esxHosts"] = [h.strip() for h in str(esx_hosts_raw).split(",") if h.strip()]

    # Per-cluster nicList override (list of {name:...} objects or comma-separated string).
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
    for field in (
        "hostname", "parentDirectory", "tlsCrt", "tlsKey", "caCrt",
        "harborAdminPassword", "secretKey", "databasePassword",
        "coreSecret", "jobserviceSecret", "registrySecret",
        "registryVolumeSize", "jobserviceVolumeSize", "databaseVolumeSize",
        "redisVolumeSize", "trivyVolumeSize",
    ):
        _add_optional_str(harbor_obj, harbor, field)
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
    for field in (
        "parentDirectory", "argoCdOperatorYamlFileName", "argoCdDeploymentYamlFileName",
        "harborDataTemplateYamlFileName", "harborServiceYamlFileName",
    ):
        _add_optional_str(cl_svcs_obj, cl_svcs, field)
    _add_optional_bool(cl_svcs_obj, cl_svcs, "disableArgoCD")
    _add_optional_bool(cl_svcs_obj, cl_svcs, "disableHarbor")
    if cl_svcs_obj:
        cluster_obj["supervisorServices"] = cl_svcs_obj

    return cluster_obj


def _build_flb_network_obj(raw: dict) -> dict:
    """Builds a single FLB network object (management or virtual-server) from raw form data.

    Both flbManagementNetwork and flbVirtualServerNetwork share the same three required
    fields plus an optional gateway.  This helper eliminates the copy-paste duplication
    that previously existed in build_supervisor and ensures any future field additions
    are made in exactly one place.
    """
    obj = {
        "flbNetworkName":               _iget(raw, "flbNetworkName", ""),
        "flbNetworkIpAddressStartingIp": _iget(raw, "flbNetworkIpAddressStartingIp", ""),
        "flbNetworkIpAddressCount":      _safe_int(_iget(raw, "flbNetworkIpAddressCount", 0)),
    }
    gw = (_iget(raw, "flbNetworkGateway", "") or "").strip()
    if gw:
        obj["flbNetworkGateway"] = gw
    return obj


def build_supervisor(data: dict) -> dict:
    """Builds a clean supervisor dict from the validated form data dict."""
    common_spec = data.get("commonSupervisorSpec", {})

    try:
        cp_vm_count = int(common_spec.get("controlPlaneVMCount", 1))
    except (TypeError, ValueError) as exc:
        raise ValueError(
            f"controlPlaneVMCount must be an integer, got: {common_spec.get('controlPlaneVMCount', 1)!r}"
        ) from exc

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

        flb_mgmt_obj = _build_flb_network_obj(flb_mgmt)
        flb_vsn_obj  = _build_flb_network_obj(flb_vsn)

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
                "workloadServiceCount": _safe_int(
                    _iget(pwn_spec, "workloadServiceCount", _DEFAULT_WORKLOAD_SERVICE_COUNT)
                ),
            },
        }
        sites_out.append(site_obj)

    return {"commonSupervisorSpec": common_obj, "siteSpec": sites_out}


# ---------------------------------------------------------------------------
# Embedded HTML/JS/CSS single-page application
# ---------------------------------------------------------------------------


def _load_html_template() -> bytes:
    """Reads the UI HTML template from disk.

    The template file (veas-ui.html) must live alongside this script in the
    same directory. Run 'Start-VcfEdgeAtScale -Initialize' to install it into
    the deployment Tools directory if it is missing.
    """
    template_path = SCRIPT_DIR / _TEMPLATE_FILE
    if not template_path.is_file():
        raise FileNotFoundError(
            f"UI template not found at {template_path}. "
            "Run 'Start-VcfEdgeAtScale -Initialize' to install it."
        )
    return template_path.read_bytes()


# ---------------------------------------------------------------------------
# HTTP request handler
# ---------------------------------------------------------------------------


def _check_host_https(host: str, timeout: float = _CONNECTIVITY_TIMEOUT) -> dict[str, object]:
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
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
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


def _build_and_validate(payload: dict) -> tuple[dict, dict, list[str], list[str]]:
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
        raise ValueError(f"Failed to build infrastructure: {type(exc).__name__}: {exc}") from exc

    try:
        sup_built = build_supervisor(sup_data)
    except Exception as exc:
        raise ValueError(f"Failed to build supervisor: {type(exc).__name__}: {exc}") from exc

    try:
        infra_result = validate_infrastructure(infra_built)
    except Exception as exc:
        raise ValueError(f"Failed to validate infrastructure: {type(exc).__name__}: {exc}") from exc

    try:
        sup_result = validate_supervisor(
            sup_built,
            infra_result.cluster_segment_names,
            infra_result.cluster_segment_gateways,
        )
    except Exception as exc:
        raise ValueError(f"Failed to validate supervisor: {type(exc).__name__}: {exc}") from exc

    all_errors   = infra_result.errors + sup_result.errors
    all_warnings = [f"[WARNING] {w}" for w in infra_result.warnings + sup_result.warnings]
    return infra_built, sup_built, all_errors, all_warnings


class ConfigHandler(BaseHTTPRequestHandler):

    # Default base directory; overridden per-instance via _make_handler().
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

    def _check_origin(self) -> bool:
        """Returns True when the request is safe to process.

        Non-browser clients (curl, PowerShell Invoke-RestMethod) send no Origin
        header and are always allowed.  Browser-initiated cross-origin requests
        include an Origin; we only permit origins whose host resolves to the
        loopback interface so that a malicious page cannot CSRF-trigger /save,
        /generate, or /connectivity-check against the locally running server.
        """
        origin = self.headers.get("Origin", "")
        if not origin:
            return True
        try:
            host = urlparse(origin).hostname or ""
            return host in ("127.0.0.1", "localhost", "::1")
        except Exception:
            return False

    def _send_security_headers(self):
        """Sends common security headers on every response.

        X-Content-Type-Options prevents MIME-sniffing of JSON/ZIP responses as
        executable content. Cache-Control ensures configuration data is not
        cached by the browser. X-Frame-Options and CSP defend against
        clickjacking and injection attacks.

        NOTE: 'unsafe-inline' in script-src and style-src is required because
        veas-ui.html is a self-contained single-file SPA with inline <script>
        and <style> blocks — a deliberate trade-off for stdlib-only deployability.
        Adding a nonce would require server-side templating on every request.
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
            try:
                body = _load_html_template()
            except OSError as exc:
                self.send_json(503, {"error": str(exc)})
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self._send_security_headers()
            self.end_headers()
            self.wfile.write(body)

        elif path == "/templates":
            self._handle_templates()

        elif path == "/info":
            base_dir = self.base_dir
            self.send_json(200, {
                "version": UI_VERSION,
                "base_dir": str(base_dir),
                "base_dir_exists": base_dir.is_dir(),
                "has_json_files": (
                    (base_dir / "infrastructure.json").is_file()
                    and (base_dir / "supervisor.json").is_file()
                ),
                "readme_url": README_URL,
            })

        else:
            self.send_json(404, {"error": "Not found."})

    def do_POST(self):
        if not self._check_origin():
            self.send_json(403, {"error": "Cross-origin requests are not permitted."})
            return
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

    def _load_json_pair(self, directory: Path, not_found_status: int = 404, not_found_hint: str = "") -> bool:
        """Loads infrastructure.json and supervisor.json from directory and sends the JSON response.

        Returns True on success (200 sent). On error, sends the appropriate error response and
        returns False. Callers should return immediately when this method returns False.

        not_found_status: HTTP status for FileNotFoundError (404 for the default dir, 400 for a
            caller-supplied custom path — the caller chose the path, so it is a client error).
        not_found_hint: Optional sentence appended to the not-found error message (e.g. how to
            recover) — allows each call site to give context-appropriate guidance.
        """
        try:
            infra      = json.loads((directory / "infrastructure.json").read_text(encoding="utf-8"))
            supervisor = json.loads((directory / "supervisor.json").read_text(encoding="utf-8"))
            self.send_json(200, {
                "infrastructure": infra,
                "supervisor":     supervisor,
                "_source":        str(directory),
            })
            return True
        except FileNotFoundError as exc:
            msg = f"JSON file not found in '{directory}': {exc.filename}."
            if not_found_hint:
                msg += f" {not_found_hint}"
            self.send_json(not_found_status, {"error": msg})
        except json.JSONDecodeError as exc:
            self.send_json(500, {"error": f"JSON file is malformed: {exc}"})
        except (PermissionError, UnicodeDecodeError) as exc:
            self.send_json(500, {"error": f"Could not read file: {exc}"})
        return False

    def _handle_templates(self):
        """Returns the infrastructure.json and supervisor.json from the resolved base directory."""
        self._load_json_pair(
            self.base_dir,
            not_found_status=404,
            not_found_hint=(
                "Run 'Start-VcfEdgeAtScale -Initialize' first, or pass --base-dir to point "
                "at the directory containing infrastructure.json and supervisor.json."
            ),
        )

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

        # _safe_resolve_path resolves the path and enforces home-directory
        # confinement in one step, consistent with how validation helpers
        # sanitise parentDirectory values from the JSON payload.
        custom_dir = _safe_resolve_path(str(payload.get("path", "")).strip())
        if custom_dir is None:
            self.send_json(400, {"error": "Custom path must be within your home directory."})
            return

        if not custom_dir.is_dir():
            self.send_json(400, {"error": f"Directory does not exist: {custom_dir}"})
            return

        self._load_json_pair(custom_dir, not_found_status=400)

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

        try:
            step = int(payload.get("step", 1))
        except (TypeError, ValueError):
            step = -1
        messages = []

        try:
            # Build only what this step requires — step 1 and 2 only need infra;
            # step 3 needs both. Avoids redundant builds on every wizard navigation.
            infra_built = build_infrastructure(payload.get("infrastructure", {}))
            sup_built = build_supervisor(payload.get("supervisor", {})) if step == 3 else None
        except Exception as exc:
            if _DEBUG:
                traceback.print_exc()
            self.send_json(400, {
                "passed": False,
                "messages": [f"[ERROR] Could not parse configuration: {type(exc).__name__}: {exc}"],
            })
            return

        try:
            if step == 1:
                messages = _validate_step1_messages(infra_built, base_dir=self.base_dir)
            elif step == 2:
                infra_result = validate_infrastructure(infra_built)
                messages = (
                    _format_infra_messages(infra_result.errors, infra_built)
                    + [f"[WARNING] {w}" for w in infra_result.warnings]
                    + _validate_step2_harbor_files(infra_built, base_dir=self.base_dir)
                )
            elif step == 3:
                # Validate infrastructure first so those errors are also surfaced on Step 3,
                # then pass the segment maps through to supervisor validation.
                # Use _format_infra_messages (same as step 2) so that per-site INFO
                # confirmations appear even when there are supervisor errors to fix.
                infra_result = validate_infrastructure(infra_built)
                sup_result = validate_supervisor(
                    sup_built,
                    infra_result.cluster_segment_names,
                    infra_result.cluster_segment_gateways,
                )
                messages = (
                    _format_infra_messages(infra_result.errors, infra_built)
                    + [_tag_error(e) for e in sup_result.errors]
                    + [f"[WARNING] {w}" for w in infra_result.warnings + sup_result.warnings]
                )
            else:
                messages = ["[ERROR] Unknown step."]
        except Exception as exc:
            if _DEBUG:
                traceback.print_exc()
            self.send_json(400, {
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
            self.send_json(400, {"errors": [f"Invalid JSON payload: {exc}"], "warnings": [], "passed": False})
            return

        try:
            infra_built, sup_built, all_errors, all_warnings = _build_and_validate(payload)
        except ValueError as exc:
            if _DEBUG:
                traceback.print_exc()
            self.send_json(400, {"errors": [f"Validation failed: {exc}"], "warnings": [], "passed": False})
            return

        self.send_json(200, {
            "passed": not bool(all_errors),
            "errors": all_errors,
            "warnings": all_warnings,
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
            # Include a warnings file when validation produced warnings so the
            # operator sees them when opening the archive, even if they skipped
            # the preview step.
            if all_warnings:
                warning_lines = "\n".join(f"- {w}" for w in all_warnings)
                zf.writestr("WARNINGS.txt", f"Validation warnings:\n{warning_lines}\n")
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

        base_dir = self.base_dir
        _now = datetime.datetime.now()
        timestamp = f"{_now.strftime('%Y%m%d-%H%M%S')}-{_now.microsecond // 1000:03d}"
        infra_path = base_dir / "infrastructure.json"
        sup_path = base_dir / "supervisor.json"
        backups = []

        try:
            base_dir.mkdir(parents=True, exist_ok=True)

            # Backup existing files into a dedicated Backup/ subdirectory.
            # os.open with O_CREAT | O_EXCL and mode 0o600 creates the file with
            # owner-only permissions atomically — no world-readable window between
            # creation and chmod that the write_bytes + chmod pattern would leave.
            # On Windows, os.open honours the mode bits as-is (no ACL mapping), so
            # this is a best-effort restriction that works correctly on Unix.
            backup_dir = base_dir / "Backup"
            backup_dir.mkdir(exist_ok=True)
            for src_path in (infra_path, sup_path):
                if src_path.exists():
                    backup_path = backup_dir / f"{src_path.name}.bak-{timestamp}"
                    fd = os.open(str(backup_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    try:
                        with os.fdopen(fd, "wb") as bf:
                            bf.write(src_path.read_bytes())
                    except OSError:
                        backup_path.unlink(missing_ok=True)
                        raise
                    backups.append(str(backup_path))

            # Write new files atomically via sibling temp files with owner-only permissions.
            # os.open with O_CREAT | O_EXCL | mode 0o600 ensures no world-readable window
            # between creation and write — the same pattern used for backup files above.
            # Each tmp file is cleaned up if replace() fails so no orphaned files remain.
            for dest_path, content in (
                (infra_path, json.dumps(infra_built, indent=2)),
                (sup_path, json.dumps(sup_built, indent=2)),
            ):
                tmp_path = dest_path.with_name(dest_path.name + ".tmp")
                try:
                    fd = os.open(str(tmp_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(fd, "wb") as tf:
                        tf.write(content.encode("utf-8"))
                    tmp_path.replace(dest_path)
                except OSError:
                    tmp_path.unlink(missing_ok=True)
                    raise

        except OSError as exc:
            self.send_json(500, {"errors": [f"Failed to write files: {exc}"]})
            return

        self.send_json(200, {
            "saved": True,
            "base_dir": str(base_dir),
            "backups": backups,
            "warnings": all_warnings,
        })


def _make_handler(configured_base_dir: Path) -> type:
    """Returns a ConfigHandler subclass with base_dir bound at class creation time.

    Using a subclass avoids mutating ConfigHandler itself, so each call produces
    an independent handler class — safe for testing and multi-server scenarios.
    """
    class _Handler(ConfigHandler):
        base_dir = configured_base_dir
    return _Handler


class _SecureHTTPServer(HTTPServer):
    """Suppresses benign browser-disconnect errors at the server level.

    handle_error belongs on the server (BaseServer), not the handler — this is
    the correct override point for catching exceptions from process_request().
    """

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionAbortedError, ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="VcfEdgeAtScale JSON Configuration UI — stdlib-only web server."
    )
    parser.add_argument("--port", type=int, default=8080, help="TCP port to listen on (default: 8080)")
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
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="Do not automatically open a browser tab on startup (useful for headless or SSH environments).",
    )
    args = parser.parse_args()

    if args.base_dir:
        base_dir = Path(args.base_dir).expanduser().resolve()
    elif _DEFAULT_BASE_DIR.exists():
        base_dir = _DEFAULT_BASE_DIR
    else:
        base_dir = _FALLBACK_TEMPLATES_DIR

    browser_url = f"http://localhost:{args.port}"

    try:
        server = _SecureHTTPServer((_BIND_HOST, args.port), _make_handler(base_dir))
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            print(
                f"ERROR: Port {args.port} is already in use.\n"
                f"  Another instance of this server may already be running.\n"
                f"  Try one of the following:\n"
                f"    • Open {browser_url} in your browser — it may already be ready.\n"
                f"    • Run with a different port:  python3 veas-json-generator.py --port 8081\n"
                f"    • Find and stop the existing process:\n"
                f"        macOS/Linux:  lsof -ti :{args.port} | xargs kill\n"
                f"        Windows:      netstat -ano | findstr :{args.port}"
            )
            sys.exit(1)
        raise

    print("VcfEdgeAtScale Configuration UI")
    print(f"Listening on {_BIND_HOST}:{args.port} (localhost only)")
    print(f"Base directory: {base_dir}")
    if not (base_dir / "infrastructure.json").exists():
        print("  WARNING: infrastructure.json not found in base directory.")
        print("  Run 'Start-VcfEdgeAtScale -Initialize' or pass --base-dir to set the correct path.")
    print(f"Open {browser_url} in your browser to begin.")
    print("Press Ctrl+C to stop.")

    if not args.no_browser:
        def _open_browser():
            time.sleep(_BROWSER_OPEN_DELAY_SECONDS)
            webbrowser.open(browser_url)
        threading.Thread(target=_open_browser, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()
        sys.exit(0)


if __name__ == "__main__":
    main()
