"""
Unit tests for veas-json-generator.py validation and builder layer.

Run with:  python3 -m pytest VcfEdgeAtScale/Tools/test_veas_validator.py -v
       or:  python3 -m unittest VcfEdgeAtScale/Tools/test_veas_validator.py -v

The module filename contains dashes so standard import cannot be used; importlib
handles this without requiring a rename or sys.path tricks.
"""
import importlib.util
import os
import signal
import tempfile
import unittest
import unittest.mock
from pathlib import Path

# ---------------------------------------------------------------------------
# Module import
# ---------------------------------------------------------------------------
_MODULE_PATH = Path(__file__).parent / "veas-json-generator.py"
_spec = importlib.util.spec_from_file_location("veas_json_generator", _MODULE_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

# Convenience aliases to keep tests readable.
is_valid_ipv4         = _mod.is_valid_ipv4
is_valid_cidr         = _mod.is_valid_cidr
is_valid_netmask      = _mod.is_valid_netmask
is_power_of_two       = _mod.is_power_of_two
validate_vlan_id      = _mod.validate_vlan_id
_validate_vmk         = _mod._validate_vmk_interfaces
_validate_harbor      = _mod._validate_harbor
_validate_cluster     = _mod._validate_cluster
_resolve_bool         = _mod._resolve_bool
validate_infrastructure  = _mod.validate_infrastructure
InfraValidationResult    = _mod.InfraValidationResult
validate_supervisor     = _mod.validate_supervisor
build_infrastructure    = _mod.build_infrastructure
build_supervisor        = _mod.build_supervisor
_build_cluster_obj      = _mod._build_cluster_obj
ENV_VAR_RE              = _mod.ENV_VAR_RE
_MIN_VMK_MTU            = _mod._MIN_VMK_MTU
_MAX_VMK_MTU            = _mod._MAX_VMK_MTU
_MIN_WORKLOAD_SERVICE_COUNT = _mod._MIN_WORKLOAD_SERVICE_COUNT
_MAX_WORKLOAD_SERVICE_COUNT = _mod._MAX_WORKLOAD_SERVICE_COUNT
is_gateway_ip_in_ip_range   = _mod.is_gateway_ip_in_ip_range
_COUNT_PARSE_ERROR          = _mod._COUNT_PARSE_ERROR
_safe_resolve_path          = _mod._safe_resolve_path
_is_windows_absolute_path   = _mod._is_windows_absolute_path
_is_posix_absolute_path     = _mod._is_posix_absolute_path
_HOME_DIR                   = _mod._HOME_DIR
ConfigHandler               = _mod.ConfigHandler
FQDN_OR_IPV4_RE             = _mod.FQDN_OR_IPV4_RE
RFC1123_RE                  = _mod.RFC1123_RE
_validate_step1_messages    = _mod._validate_step1_messages
_validate_step2_harbor_files = _mod._validate_step2_harbor_files


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _minimal_cluster(edge_site="site-1", storage_type="VMFS", esx_hosts=None):
    """Returns a minimal valid VMFS cluster dict."""
    return {
        "edgeSite": edge_site,
        "esxHosts": esx_hosts or ["esx01.lab.local"],
        "storagePolicy": {"storageType": storage_type},
        "networking": {
            "networkSegments": [
                {"name": "mgmt", "vlanId": 100, "gateway": "10.0.0.1/24"},
            ],
        },
        "harborConfiguration": {"hostname": "harbor.lab.local"},
    }


def _minimal_vsan_cluster(edge_site="site-1"):
    """Returns a minimal valid vSAN-OSA cluster dict.

    VMkernel VLANs (200 vMotion, 201 vSAN, 202 witness) are intentionally kept
    out of networkSegments — they require dedicated DVPort Groups separate from
    any workload segment.
    """
    cluster = _minimal_cluster(edge_site=edge_site, storage_type="vSAN-OSA",
                               esx_hosts=["esx01.lab.local", "esx02.lab.local"])
    cluster["vSanWitnessVmName"] = "witness.lab.local"
    cluster["networking"]["networkingVmKernelInterfaces"] = [
        {"service": "vMotion", "vlanId": 200, "netmask": "255.255.255.0",
         "ipList": ["10.1.0.10", "10.1.0.11"]},
        {"service": "vSAN",    "vlanId": 201, "netmask": "255.255.255.0",
         "ipList": ["10.2.0.10", "10.2.0.11"]},
        {"service": "vSAN Witness", "vlanId": 202, "netmask": "255.255.255.0",
         "ipList": ["10.3.0.10", "10.3.0.11"]},
    ]
    return cluster


def _minimal_common(nic_list=None):
    return {
        "vCenterName": "vc.lab.local",
        "vCenterUser": "administrator@vsphere.local",
        "contextName": "test-context",
        "datacenterName": "test-dc",
        "nicList": nic_list or [{"name": "vmnic0"}, {"name": "vmnic1"}],
    }


def _minimal_infra(clusters=None, common=None):
    return {
        "common": common or _minimal_common(),
        "clusters": clusters or [_minimal_cluster()],
    }


def _minimal_supervisor(sites=None):
    """Returns a minimal valid supervisor payload for use in /save and validate_supervisor tests."""
    site = sites[0] if sites else {
        "edgeSite": "site-1",
        "foundationLoadBalancerComponents": {
            "flbName": "flb-site1",
            "flbVipStartIP": "10.0.0.50",
            "flbVipIPCount": 5,
            "flbManagementNetwork": {
                "flbNetworkName": "mgmt",
                "flbNetworkIpAddressStartingIp": "10.0.0.10",
                "flbNetworkIpAddressCount": 5,
            },
            "flbVirtualServerNetwork": {
                "flbNetworkName": "mgmt",
                "flbNetworkIpAddressStartingIp": "10.0.0.20",
                "flbNetworkIpAddressCount": 25,
            },
        },
        "mgmtNetworkSpec": {
            "mgmtNetworkName": "mgmt",
            "mgmtNetworkStartingIp": "10.0.0.30",
            "mgmtNetworkIPCount": 5,
        },
        "primaryWorkloadNetwork": {
            "primaryWorkloadNetworkName": "mgmt",
            "primaryWorkloadNetworkStartingIp": "10.0.0.40",
            "primaryWorkloadNetworkIPCount": 5,
            "workloadServiceStartIp": "10.64.0.0",
            "workloadServiceCount": 512,
        },
    }
    return {
        "commonSupervisorSpec": {
            "controlPlaneVMCount": 1,
            "controlPlaneSize": "SMALL",
            "flbAvailability": "SINGLE_NODE",
            "flbSize": "SMALL",
            "flbNetworkType": "DVPG",
            "dnsServers": ["8.8.8.8"],
            "networkNtpServers": ["pool.ntp.org"],
            "networkSearchDomains": ["lab.local"],
        },
        "siteSpec": sites or [site],
    }


# ---------------------------------------------------------------------------
# IPv4 / CIDR / netmask helpers
# ---------------------------------------------------------------------------
class TestNetworkHelpers(unittest.TestCase):
    def test_valid_ipv4(self):
        for ip in ("0.0.0.0", "192.168.1.1", "255.255.255.255", "10.0.0.1"):
            with self.subTest(ip=ip):
                self.assertTrue(is_valid_ipv4(ip))

    def test_invalid_ipv4(self):
        for ip in ("256.0.0.1", "not-an-ip", "1.2.3", "1.2.3.4.5", "", "10.0.0.a"):
            with self.subTest(ip=ip):
                self.assertFalse(is_valid_ipv4(ip))

    def test_valid_cidr(self):
        for cidr in ("10.0.0.1/24", "192.168.0.0/16", "0.0.0.0/0", "10.10.10.0/32"):
            with self.subTest(cidr=cidr):
                self.assertTrue(is_valid_cidr(cidr))

    def test_invalid_cidr(self):
        for cidr in ("10.0.0.1", "10.0.0.1/33", "not/cidr", ""):
            with self.subTest(cidr=cidr):
                self.assertFalse(is_valid_cidr(cidr))

    def test_valid_netmask(self):
        for mask in ("255.255.255.0", "255.255.0.0", "255.0.0.0", "255.255.255.255"):
            with self.subTest(mask=mask):
                self.assertTrue(is_valid_netmask(mask))

    def test_invalid_netmask(self):
        # "256.0.0.0" uses an out-of-range octet and must be rejected (integer overflow guard).
        # "0.0.0.0" is not a valid subnet mask — it always signals a data-entry error.
        for mask in ("255.0.255.0", "255.255.1.0", "not-a-mask", "256.0.0.0", "255.255.256.0", "0.0.0.0"):
            with self.subTest(mask=mask):
                self.assertFalse(is_valid_netmask(mask))

    def test_power_of_two(self):
        for n in (1, 2, 256, 512, 1024, 65536):
            self.assertTrue(is_power_of_two(n))
        for n in (0, 3, 100, 255, -1, "abc"):
            self.assertFalse(is_power_of_two(n))


# ---------------------------------------------------------------------------
# Gateway-IP-in-range helper
# ---------------------------------------------------------------------------
class TestGatewayIpInRange(unittest.TestCase):
    def test_gateway_at_start_of_range(self):
        self.assertTrue(is_gateway_ip_in_ip_range("10.0.0.1/24", "10.0.0.1", 5))

    def test_gateway_below_range(self):
        self.assertFalse(is_gateway_ip_in_ip_range("10.0.0.1/24", "10.0.0.10", 5))

    def test_gateway_at_end_of_range(self):
        self.assertTrue(is_gateway_ip_in_ip_range("10.0.0.14/24", "10.0.0.10", 5))

    def test_gateway_one_beyond_range(self):
        self.assertFalse(is_gateway_ip_in_ip_range("10.0.0.15/24", "10.0.0.10", 5))

    def test_count_one_gateway_equals_start(self):
        self.assertTrue(is_gateway_ip_in_ip_range("10.0.0.1/24", "10.0.0.1", 1))

    def test_count_one_gateway_differs(self):
        self.assertFalse(is_gateway_ip_in_ip_range("10.0.0.1/24", "10.0.0.2", 1))

    def test_invalid_cidr_returns_false(self):
        self.assertFalse(is_gateway_ip_in_ip_range("not-a-cidr", "10.0.0.1", 5))

    def test_invalid_start_ip_returns_false(self):
        self.assertFalse(is_gateway_ip_in_ip_range("10.0.0.1/24", "999.0.0.1", 5))


# ---------------------------------------------------------------------------
# VLAN ID validator
# ---------------------------------------------------------------------------
class TestVlanId(unittest.TestCase):
    def test_valid_vlan_ids(self):
        for vid in (0, 1, 4095):
            self.assertIsNone(validate_vlan_id(vid, "field"))

    def test_invalid_vlan_ids(self):
        self.assertIsNotNone(validate_vlan_id(-1, "f"))
        self.assertIsNotNone(validate_vlan_id(4096, "f"))
        self.assertIsNotNone(validate_vlan_id("abc", "f"))
        self.assertIsNotNone(validate_vlan_id(None, "f"))


# ---------------------------------------------------------------------------
# ENV_VAR_RE regex
# ---------------------------------------------------------------------------
class TestEnvVarRegex(unittest.TestCase):
    def test_valid_env_var_refs(self):
        for ref in ("$env:HARBOR_SECRET_KEY", "$env:_MYVAR", "$env:Var123"):
            with self.subTest(ref=ref):
                self.assertTrue(bool(ENV_VAR_RE.match(ref)))

    def test_invalid_env_var_refs(self):
        for ref in ("$env:", "$env:123bad", "env:MYVAR", "$MYVAR", "plain-secret"):
            with self.subTest(ref=ref):
                self.assertFalse(bool(ENV_VAR_RE.match(ref)))


# ---------------------------------------------------------------------------
# MTU bounds constants
# ---------------------------------------------------------------------------
class TestMtuConstants(unittest.TestCase):
    def test_constants_have_correct_values(self):
        self.assertEqual(_MIN_VMK_MTU, 1500)
        self.assertEqual(_MAX_VMK_MTU, 9190)


# ---------------------------------------------------------------------------
# _validate_vmk_interfaces
# ---------------------------------------------------------------------------
class TestVmkInterfaces(unittest.TestCase):
    def _valid_vmks(self):
        return [
            {"service": "vMotion", "vlanId": 200, "netmask": "255.255.255.0",
             "ipList": ["10.1.0.10", "10.1.0.11"]},
            {"service": "vSAN",    "vlanId": 201, "netmask": "255.255.255.0",
             "ipList": ["10.2.0.10", "10.2.0.11"]},
            {"service": "vSAN Witness", "vlanId": 202, "netmask": "255.255.255.0",
             "ipList": ["10.3.0.10", "10.3.0.11"]},
        ]

    def test_valid_vmks_produce_no_errors(self):
        errors = []
        _validate_vmk(self._valid_vmks(), "vSAN-OSA", "prefix", errors)
        self.assertEqual(errors, [])

    def test_missing_vmks_produces_error(self):
        errors = []
        _validate_vmk([], "vSAN-OSA", "prefix", errors)
        self.assertTrue(any("required for vSAN-OSA" in e for e in errors))

    def test_vlan_overlap_with_segment_is_flagged(self):
        """VMkernel VLAN must not overlap with any networkSegment VLAN."""
        vmks = self._valid_vmks()
        errors = []
        # Pass VLAN 200 (used by vMotion) as an occupied segment VLAN.
        _validate_vmk(vmks, "vSAN-OSA", "prefix", errors, segment_vlans={"200"})
        self.assertTrue(any("already used by a networkSegment" in e for e in errors))

    def test_no_overlap_when_vlans_are_distinct(self):
        errors = []
        _validate_vmk(self._valid_vmks(), "vSAN-OSA", "prefix", errors,
                      segment_vlans={"100", "101"})
        self.assertFalse(any("already used by a networkSegment" in e for e in errors))

    def test_missing_vmotion_service_is_flagged(self):
        vmks = [v for v in self._valid_vmks() if v["service"] != "vMotion"]
        errors = []
        _validate_vmk(vmks, "vSAN-OSA", "prefix", errors)
        self.assertTrue(any("missing required service 'vMotion'" in e for e in errors))

    def test_duplicate_ips_in_ip_list_flagged(self):
        vmks = self._valid_vmks()
        vmks[0]["ipList"] = ["10.1.0.10", "10.1.0.10"]
        errors = []
        _validate_vmk(vmks, "vSAN-OSA", "prefix", errors)
        self.assertTrue(any("must be unique" in e for e in errors))

    def test_non_contiguous_netmask_rejected(self):
        vmks = self._valid_vmks()
        vmks[0]["netmask"] = "255.0.255.0"
        errors = []
        _validate_vmk(vmks, "vSAN-OSA", "prefix", errors)
        self.assertTrue(any("not a valid subnet mask" in e for e in errors))


# ---------------------------------------------------------------------------
# _validate_harbor
# ---------------------------------------------------------------------------
class TestValidateHarbor(unittest.TestCase):
    def test_valid_harbor_no_errors(self):
        errors = []
        _validate_harbor({"hostname": "harbor.lab.local"}, "prefix", errors)
        self.assertEqual(errors, [])

    def test_bad_hostname_flagged(self):
        errors = []
        _validate_harbor({"hostname": "not a valid host!"}, "prefix", errors)
        self.assertTrue(any("hostname" in e for e in errors))

    def test_secret_key_must_be_16_chars_or_env_ref(self):
        errors = []
        _validate_harbor({"secretKey": "tooshort"}, "prefix", errors)
        self.assertTrue(any("secretKey" in e for e in errors))

    def test_valid_16_char_secret_key(self):
        errors = []
        _validate_harbor({"secretKey": "a" * 16}, "prefix", errors)
        self.assertFalse(any("secretKey" in e for e in errors))

    def test_valid_env_var_secret_key(self):
        errors = []
        _validate_harbor({"secretKey": "$env:HARBOR_SECRET_KEY"}, "prefix", errors)
        self.assertFalse(any("secretKey" in e for e in errors))

    def test_bare_env_prefix_rejected(self):
        """$env: with no variable name must be rejected."""
        errors = []
        _validate_harbor({"secretKey": "$env:"}, "prefix", errors)
        self.assertTrue(any("secretKey" in e for e in errors))

    def test_tls_crt_without_tls_key_flagged(self):
        errors = []
        _validate_harbor({"tlsCrt": "pem-content"}, "prefix", errors)
        self.assertTrue(any("tlsCrt" in e and "tlsKey" in e for e in errors))

    def test_ca_crt_without_tls_pair_flagged(self):
        errors = []
        _validate_harbor({"caCrt": "ca-pem"}, "prefix", errors)
        self.assertTrue(any("caCrt" in e for e in errors))

    def test_invalid_volume_size_flagged(self):
        errors = []
        _validate_harbor({"registryVolumeSize": "10GB"}, "prefix", errors)
        self.assertTrue(any("registryVolumeSize" in e for e in errors))

    def test_valid_volume_size_accepted(self):
        errors = []
        _validate_harbor({"registryVolumeSize": "10Gi"}, "prefix", errors)
        self.assertFalse(any("registryVolumeSize" in e for e in errors))


# ---------------------------------------------------------------------------
# _resolve_bool
# ---------------------------------------------------------------------------
class TestResolveBool(unittest.TestCase):
    def test_cluster_level_true_wins(self):
        cluster = {"supervisorServices": {"disableHarbor": True}}
        common  = {"supervisorServices": {"disableHarbor": False}}
        self.assertTrue(_resolve_bool(cluster, common, "disableHarbor"))

    def test_common_level_used_when_cluster_absent(self):
        cluster = {}
        common  = {"supervisorServices": {"disableHarbor": True}}
        self.assertTrue(_resolve_bool(cluster, common, "disableHarbor"))

    def test_json_null_does_not_override_common_true(self):
        """A JSON null (Python None) at cluster level must not shadow common=True."""
        cluster = {"supervisorServices": {"disableHarbor": None}}
        common  = {"supervisorServices": {"disableHarbor": True}}
        self.assertTrue(_resolve_bool(cluster, common, "disableHarbor"))

    def test_both_absent_returns_false(self):
        self.assertFalse(_resolve_bool({}, {}, "disableHarbor"))

    def test_explicit_false_at_cluster_overrides_common_true(self):
        cluster = {"supervisorServices": {"disableHarbor": False}}
        common  = {"supervisorServices": {"disableHarbor": True}}
        self.assertFalse(_resolve_bool(cluster, common, "disableHarbor"))


# ---------------------------------------------------------------------------
# validate_infrastructure
# ---------------------------------------------------------------------------
class TestValidateInfrastructure(unittest.TestCase):
    def test_minimal_valid_infra_passes(self):
        result = validate_infrastructure(_minimal_infra())
        self.assertIsInstance(result, InfraValidationResult)
        self.assertEqual(result.errors, [])
        self.assertTrue(result.passed)

    def test_minimal_valid_vsan_passes(self):
        result = validate_infrastructure(
            {"common": _minimal_common(), "clusters": [_minimal_vsan_cluster()]}
        )
        self.assertEqual(result.errors, [])
        self.assertTrue(result.passed)

    def test_missing_common_fails(self):
        result = validate_infrastructure({"clusters": [_minimal_cluster()]})
        self.assertTrue(any("common" in e for e in result.errors))
        self.assertFalse(result.passed)

    def test_missing_vc_name_fails(self):
        infra = _minimal_infra()
        del infra["common"]["vCenterName"]
        result = validate_infrastructure(infra)
        self.assertTrue(any("vCenterName" in e for e in result.errors))

    def test_duplicate_edge_sites_fail(self):
        infra = _minimal_infra(clusters=[_minimal_cluster("site-1"), _minimal_cluster("site-1")])
        result = validate_infrastructure(infra)
        self.assertTrue(any("duplicate edgeSite" in e for e in result.errors))

    def test_duplicate_segment_names_across_clusters_fail(self):
        c1 = _minimal_cluster("site-1")
        c2 = _minimal_cluster("site-2")
        # Both clusters use the segment name "mgmt" (already in _minimal_cluster).
        result = validate_infrastructure({"common": _minimal_common(), "clusters": [c1, c2]})
        self.assertTrue(any("globally unique" in e for e in result.errors))

    def test_vmfs_cluster_requires_exactly_one_host(self):
        cluster = _minimal_cluster(esx_hosts=["h1.lab.local", "h2.lab.local"])
        result = validate_infrastructure(_minimal_infra(clusters=[cluster]))
        self.assertTrue(any("VMFS requires exactly 1 host" in e for e in result.errors))

    def test_vsan_cluster_requires_exactly_two_hosts(self):
        cluster = _minimal_vsan_cluster()
        cluster["esxHosts"] = ["h1.lab.local"]
        result = validate_infrastructure(
            {"common": _minimal_common(), "clusters": [cluster]}
        )
        self.assertTrue(any("vSAN-OSA requires exactly 2 hosts" in e for e in result.errors))

    def test_vsan_requires_witness(self):
        cluster = _minimal_vsan_cluster()
        del cluster["vSanWitnessVmName"]
        result = validate_infrastructure(
            {"common": _minimal_common(), "clusters": [cluster]}
        )
        self.assertTrue(any("vSanWitnessVmName" in e for e in result.errors))

    def test_vsan_missing_segments_does_not_raise(self):
        """vSAN cluster with no networkSegments must produce a clean error, not raise an exception.

        Regression: seen_vlans was only defined inside the else-branch of the segments check,
        causing a NameError when _validate_vmk_interfaces was called with no valid segments.
        The guard here is that the call completes without raising — a real NameError would
        surface as an uncaught exception, not as a string in result.errors.
        """
        cluster = _minimal_vsan_cluster()
        cluster["networking"]["networkSegments"] = []
        result = validate_infrastructure(
            {"common": _minimal_common(), "clusters": [cluster]}
        )
        self.assertTrue(any("networkSegments" in e for e in result.errors))

    def test_vmk_vlan_overlapping_segment_vlan_fails(self):
        """VMkernel VLAN must not reuse a networkSegment VLAN — regression for template bug."""
        cluster = _minimal_vsan_cluster()
        # Point vMotion VMK at VLAN 100 which is used by the "mgmt" segment.
        cluster["networking"]["networkingVmKernelInterfaces"][0]["vlanId"] = 100
        result = validate_infrastructure(
            {"common": _minimal_common(), "clusters": [cluster]}
        )
        self.assertTrue(any("already used by a networkSegment" in e for e in result.errors))

    def test_invalid_storage_type_flagged(self):
        cluster = _minimal_cluster()
        cluster["storagePolicy"]["storageType"] = "UNKNOWN"
        result = validate_infrastructure(_minimal_infra(clusters=[cluster]))
        self.assertTrue(any("storageType" in e for e in result.errors))

    def test_mtu_out_of_range_flagged(self):
        infra = _minimal_infra()
        infra["common"]["vSanvMotionVmKernelMtuValue"] = 100
        result = validate_infrastructure(infra)
        self.assertTrue(any(f"{_MIN_VMK_MTU}" in e and f"{_MAX_VMK_MTU}" in e for e in result.errors))

    def test_mtu_at_boundary_accepted(self):
        infra = _minimal_infra()
        infra["common"]["vSanvMotionVmKernelMtuValue"] = _MIN_VMK_MTU
        result = validate_infrastructure(infra)
        self.assertFalse(any(f"{_MIN_VMK_MTU}" in e and f"{_MAX_VMK_MTU}" in e for e in result.errors))

    def test_override_cluster_name_valid_is_accepted(self):
        cluster = _minimal_cluster()
        cluster["overrideClusterName"] = "my-special-cluster"
        result = validate_infrastructure(_minimal_infra(clusters=[cluster]))
        self.assertFalse(any("overrideClusterName" in e for e in result.errors))

    def test_override_cluster_name_with_allowed_special_chars(self):
        cluster = _minimal_cluster()
        cluster["overrideClusterName"] = "Cluster_Edge+01 (prod).v2"
        result = validate_infrastructure(_minimal_infra(clusters=[cluster]))
        self.assertFalse(any("overrideClusterName" in e for e in result.errors))

    def test_override_cluster_name_absent_does_not_error(self):
        cluster = _minimal_cluster()
        result = validate_infrastructure(_minimal_infra(clusters=[cluster]))
        self.assertFalse(any("overrideClusterName" in e for e in result.errors))

    def test_override_cluster_name_invalid_chars_flagged(self):
        cluster = _minimal_cluster()
        cluster["overrideClusterName"] = "bad/name"
        result = validate_infrastructure(_minimal_infra(clusters=[cluster]))
        self.assertTrue(any("overrideClusterName" in e for e in result.errors))

    def test_override_cluster_name_too_long_flagged(self):
        cluster = _minimal_cluster()
        cluster["overrideClusterName"] = "a" * 81
        result = validate_infrastructure(_minimal_infra(clusters=[cluster]))
        self.assertTrue(any("overrideClusterName" in e for e in result.errors))

    def test_override_cluster_name_exactly_80_chars_accepted(self):
        cluster = _minimal_cluster()
        cluster["overrideClusterName"] = "a" * 80
        result = validate_infrastructure(_minimal_infra(clusters=[cluster]))
        self.assertFalse(any("overrideClusterName" in e for e in result.errors))


# ---------------------------------------------------------------------------
# validate_supervisor
# ---------------------------------------------------------------------------
class TestValidateSupervisor(unittest.TestCase):
    # Segment topology used by all supervisor tests:
    #   mgmt    : 10.0.0.0/24  gateway 10.0.0.1/24
    #   workload: 10.1.0.0/24  gateway 10.1.0.1/24
    _SEG_NAMES = {"site-1": ["mgmt", "workload"], "site-2": ["mgmt2", "workload2"]}
    _SEG_GW    = {
        "site-1": {"mgmt": "10.0.0.1/24", "workload": "10.1.0.1/24"},
        "site-2": {"mgmt2": "10.2.0.1/24", "workload2": "10.3.0.1/24"},
    }

    def _minimal_sup_site(self, edge_site="site-1", svc_start="10.64.0.0",
                          svc_count=512, pwn_start="10.1.0.10",
                          mgmt_net="mgmt", vsn_net="workload",
                          flb_mgmt_ip="10.0.0.10", flb_vsn_ip="10.1.0.20",
                          mgmt_start="10.0.0.30"):
        return {
            "edgeSite": edge_site,
            "foundationLoadBalancerComponents": {
                "flbName": "flb-01",
                "flbVipStartIP": "10.0.0.1",
                "flbVipIPCount": 30,
                "flbManagementNetwork": {
                    "flbNetworkName": mgmt_net,
                    "flbNetworkIpAddressStartingIp": flb_mgmt_ip,
                    "flbNetworkIpAddressCount": 10,
                },
                "flbVirtualServerNetwork": {
                    "flbNetworkName": vsn_net,
                    "flbNetworkIpAddressStartingIp": flb_vsn_ip,
                    "flbNetworkIpAddressCount": 30,
                },
            },
            "mgmtNetworkSpec": {
                "mgmtNetworkName": mgmt_net,
                "mgmtNetworkStartingIp": mgmt_start,
                "mgmtNetworkIPCount": 5,
            },
            "primaryWorkloadNetwork": {
                "primaryWorkloadNetworkName": vsn_net,
                "primaryWorkloadNetworkStartingIp": pwn_start,
                "primaryWorkloadNetworkIPCount": 5,
                "workloadServiceStartIp": svc_start,
                "workloadServiceCount": svc_count,
            },
        }

    def _minimal_sup(self, sites=None):
        return {
            "commonSupervisorSpec": {
                "controlPlaneVMCount": 1,
                "controlPlaneSize": "SMALL",
                "flbAvailability": "SINGLE_NODE",
                "flbSize": "MEDIUM",
                "flbNetworkType": "DVPG",
                "dnsServers": ["8.8.8.8"],
                "networkNtpServers": ["pool.ntp.org"],
                "networkSearchDomains": ["lab.local"],
            },
            "siteSpec": sites or [self._minimal_sup_site()],
        }

    def test_minimal_valid_supervisor_passes(self):
        result = validate_supervisor(
            self._minimal_sup(), self._SEG_NAMES, self._SEG_GW
        )
        self.assertEqual(result.errors, [])

    def test_workload_service_count_below_minimum_fails(self):
        sup = self._minimal_sup(sites=[self._minimal_sup_site(svc_count=128)])
        result = validate_supervisor(sup, {"site-1": []})
        self.assertTrue(any("workloadServiceCount" in e for e in result.errors))

    def test_workload_service_count_above_maximum_fails(self):
        sup = self._minimal_sup(sites=[self._minimal_sup_site(svc_count=131072)])
        result = validate_supervisor(sup, {"site-1": []})
        self.assertTrue(any("workloadServiceCount" in e for e in result.errors))

    def test_workload_service_count_non_power_of_two_fails(self):
        sup = self._minimal_sup(sites=[self._minimal_sup_site(svc_count=500)])
        result = validate_supervisor(sup, {"site-1": []})
        self.assertTrue(any("power of 2" in e for e in result.errors))

    def test_duplicate_workload_service_start_ip_across_sites_fails(self):
        """Both sites sharing the same workloadServiceStartIp must be flagged as an error."""
        sites = [
            self._minimal_sup_site(
                "site-1", svc_start="10.64.0.0", pwn_start="10.1.0.10",
                mgmt_net="mgmt", vsn_net="workload",
                flb_mgmt_ip="10.0.0.10", flb_vsn_ip="10.1.0.20", mgmt_start="10.0.0.30",
            ),
            self._minimal_sup_site(
                "site-2", svc_start="10.64.0.0", pwn_start="10.3.0.10",
                mgmt_net="mgmt2", vsn_net="workload2",
                flb_mgmt_ip="10.2.0.10", flb_vsn_ip="10.3.0.20", mgmt_start="10.2.0.30",
            ),
        ]
        sup = self._minimal_sup(sites=sites)
        result = validate_supervisor(sup, self._SEG_NAMES, self._SEG_GW)
        self.assertTrue(any("duplicate workloadServiceStartIp" in e for e in result.errors))

    def test_flb_mgmt_start_ip_equals_gateway_fails(self):
        """FLB management start IP at the gateway address must be rejected."""
        site = self._minimal_sup_site(flb_mgmt_ip="10.0.0.1")
        sup = self._minimal_sup(sites=[site])
        result = validate_supervisor(sup, self._SEG_NAMES, self._SEG_GW)
        self.assertTrue(any("falls within" in e for e in result.errors))

    def test_mgmt_network_start_ip_equals_gateway_fails(self):
        """Management network start IP at the gateway address must be rejected."""
        site = self._minimal_sup_site(mgmt_start="10.0.0.1")
        sup = self._minimal_sup(sites=[site])
        result = validate_supervisor(sup, self._SEG_NAMES, self._SEG_GW)
        self.assertTrue(any("falls within" in e for e in result.errors))

    def test_workload_network_start_ip_equals_gateway_fails(self):
        """Primary workload start IP at the gateway address must be rejected."""
        site = self._minimal_sup_site(pwn_start="10.1.0.1")
        sup = self._minimal_sup(sites=[site])
        result = validate_supervisor(sup, self._SEG_NAMES, self._SEG_GW)
        self.assertTrue(any("falls within" in e for e in result.errors))

    def test_start_ips_after_gateway_produce_no_gateway_conflict(self):
        """All default start IPs are above the gateway — no gateway-conflict error expected."""
        sup = self._minimal_sup()
        result = validate_supervisor(sup, self._SEG_NAMES, self._SEG_GW)
        self.assertEqual([e for e in result.errors if "falls within" in e], [])

    def test_control_plane_vm_count_invalid_is_rejected(self):
        sup = self._minimal_sup()
        sup["commonSupervisorSpec"]["controlPlaneVMCount"] = 2
        result = validate_supervisor(sup, self._SEG_NAMES)
        self.assertTrue(any("controlPlaneVMCount" in e for e in result.errors))

    def test_control_plane_size_invalid_is_rejected(self):
        sup = self._minimal_sup()
        sup["commonSupervisorSpec"]["controlPlaneSize"] = "HUGE"
        result = validate_supervisor(sup, self._SEG_NAMES)
        self.assertTrue(any("controlPlaneSize" in e for e in result.errors))

    def test_flb_size_invalid_is_rejected(self):
        sup = self._minimal_sup()
        sup["commonSupervisorSpec"]["flbSize"] = "GIANT"
        result = validate_supervisor(sup, self._SEG_NAMES)
        self.assertTrue(any("flbSize" in e for e in result.errors))

    def test_flb_network_type_invalid_is_rejected(self):
        sup = self._minimal_sup()
        sup["commonSupervisorSpec"]["flbNetworkType"] = "VLAN"
        result = validate_supervisor(sup, self._SEG_NAMES)
        self.assertTrue(any("flbNetworkType" in e for e in result.errors))

    def test_dns_servers_more_than_three_is_rejected(self):
        sup = self._minimal_sup()
        sup["commonSupervisorSpec"]["dnsServers"] = ["1.1.1.1", "2.2.2.2", "3.3.3.3", "4.4.4.4"]
        result = validate_supervisor(sup, self._SEG_NAMES)
        self.assertTrue(any("dnsServers" in e and "maximum" in e for e in result.errors))

    def test_dns_server_invalid_ip_is_rejected(self):
        sup = self._minimal_sup()
        sup["commonSupervisorSpec"]["dnsServers"] = ["not-an-ip"]
        result = validate_supervisor(sup, self._SEG_NAMES)
        self.assertTrue(any("dnsServers" in e for e in result.errors))

    def test_ntp_server_invalid_entry_is_rejected(self):
        sup = self._minimal_sup()
        sup["commonSupervisorSpec"]["networkNtpServers"] = ["not a valid host!"]
        result = validate_supervisor(sup, self._SEG_NAMES)
        self.assertTrue(any("networkNtpServers" in e for e in result.errors))

    def test_search_domain_invalid_entry_is_rejected(self):
        sup = self._minimal_sup()
        sup["commonSupervisorSpec"]["networkSearchDomains"] = ["not valid!"]
        result = validate_supervisor(sup, self._SEG_NAMES)
        self.assertTrue(any("networkSearchDomains" in e for e in result.errors))

    def test_flb_management_network_ip_count_below_minimum_is_rejected(self):
        site = self._minimal_sup_site()
        site["foundationLoadBalancerComponents"]["flbManagementNetwork"]["flbNetworkIpAddressCount"] = 1
        sup = self._minimal_sup(sites=[site])
        result = validate_supervisor(sup, self._SEG_NAMES)
        self.assertTrue(any("flbNetworkIpAddressCount" in e and "≥ 2" in e for e in result.errors))


# ---------------------------------------------------------------------------
# build_infrastructure / _build_cluster_obj
# ---------------------------------------------------------------------------
class TestBuildInfrastructure(unittest.TestCase):
    def _raw_payload(self):
        """Simulates what buildPayload sends from the browser."""
        return {
            "common": {
                "vCenterName": "vc.lab.local",
                "vCenterUser": "administrator@vsphere.local",
                "contextName": "ctx",
                "datacenterName": "dc",
                "nicList": [{"name": "vmnic0"}, {"name": "vmnic1"}],
            },
            "clusters": [
                {
                    "edgeSite": "site-1",
                    "esxHosts": ["esx01.lab.local"],
                    "storagePolicy": {"storageType": "VMFS"},
                    "networking": {
                        "networkSegments": [
                            {"name": "mgmt", "vlanId": "100", "gateway": "10.0.0.1/24"},
                        ],
                    },
                }
            ],
        }

    def test_niclist_objects_are_preserved(self):
        result = build_infrastructure(self._raw_payload())
        self.assertEqual(result["common"]["nicList"],
                         [{"name": "vmnic0"}, {"name": "vmnic1"}])

    def test_niclist_comma_string_is_normalized(self):
        """Server must still accept the legacy comma-string format for backward compat."""
        payload = self._raw_payload()
        payload["common"]["nicList"] = "vmnic0, vmnic1"
        result = build_infrastructure(payload)
        self.assertEqual(result["common"]["nicList"],
                         [{"name": "vmnic0"}, {"name": "vmnic1"}])

    def test_vlan_id_is_coerced_to_int(self):
        result = build_infrastructure(self._raw_payload())
        seg = result["clusters"][0]["networking"]["networkSegments"][0]
        self.assertIsInstance(seg["vlanId"], int)
        self.assertEqual(seg["vlanId"], 100)

    def test_mtu_zero_is_preserved_via_is_not_none_check(self):
        """A value of 0 must be written even though it's falsy."""
        payload = self._raw_payload()
        payload["common"]["vSanvMotionVmKernelMtuValue"] = 0
        result = build_infrastructure(payload)
        # The validator would reject 0 but the builder must not silently drop it.
        self.assertIn("vSanvMotionVmKernelMtuValue", result["common"])
        self.assertEqual(result["common"]["vSanvMotionVmKernelMtuValue"], 0)

    def test_empty_optional_strings_are_omitted(self):
        result = build_infrastructure(self._raw_payload())
        self.assertNotIn("esxUser", result["common"])
        self.assertNotIn("haPolicy", result["common"])

    def test_build_cluster_obj_harbor_fields(self):
        cluster = _minimal_cluster()
        cluster["harborConfiguration"] = {"hostname": "h.lab.local", "secretKey": "a" * 16}
        obj = _build_cluster_obj(cluster)
        self.assertEqual(obj["harborConfiguration"]["hostname"], "h.lab.local")
        self.assertEqual(obj["harborConfiguration"]["secretKey"], "a" * 16)

    def test_build_cluster_obj_per_site_niclist_string(self):
        cluster = _minimal_cluster()
        cluster["nicList"] = "vmnic2, vmnic3"
        obj = _build_cluster_obj(cluster)
        self.assertEqual(obj["nicList"], [{"name": "vmnic2"}, {"name": "vmnic3"}])

    def test_build_cluster_obj_per_site_niclist_objects(self):
        cluster = _minimal_cluster()
        cluster["nicList"] = [{"name": "vmnic2"}, {"name": "vmnic3"}]
        obj = _build_cluster_obj(cluster)
        self.assertEqual(obj["nicList"], [{"name": "vmnic2"}, {"name": "vmnic3"}])

    def test_build_cluster_obj_override_cluster_name_included(self):
        cluster = _minimal_cluster()
        cluster["overrideClusterName"] = "my-special-cluster"
        obj = _build_cluster_obj(cluster)
        self.assertEqual(obj["overrideClusterName"], "my-special-cluster")

    def test_build_cluster_obj_override_cluster_name_absent_when_not_set(self):
        cluster = _minimal_cluster()
        obj = _build_cluster_obj(cluster)
        self.assertNotIn("overrideClusterName", obj)

    def test_build_cluster_obj_override_cluster_name_absent_when_empty(self):
        cluster = _minimal_cluster()
        cluster["overrideClusterName"] = ""
        obj = _build_cluster_obj(cluster)
        self.assertNotIn("overrideClusterName", obj)


# ---------------------------------------------------------------------------
# build_supervisor
# ---------------------------------------------------------------------------
class TestBuildSupervisor(unittest.TestCase):
    def _minimal_payload(self):
        return {
            "commonSupervisorSpec": {
                "controlPlaneVMCount": 1,
                "controlPlaneSize": "SMALL",
                "flbAvailability": "SINGLE_NODE",
                "flbSize": "MEDIUM",
                "flbNetworkType": "DVPG",
                "dnsServers": "8.8.8.8",
                "networkNtpServers": "pool.ntp.org",
                "networkSearchDomains": "lab.local",
            },
            "siteSpec": [
                {
                    "edgeSite": "site-1",
                    "foundationLoadBalancerComponents": {
                        "flbName": "flb-01",
                        "flbVipStartIP": "10.0.0.1",
                        "flbVipIPCount": "10",
                        "flbManagementNetwork": {
                            "flbNetworkName": "mgmt",
                            "flbNetworkIpAddressStartingIp": "10.0.0.10",
                            "flbNetworkIpAddressCount": "5",
                        },
                        "flbVirtualServerNetwork": {
                            "flbNetworkName": "workload",
                            "flbNetworkIpAddressStartingIp": "10.1.0.10",
                            "flbNetworkIpAddressCount": "5",
                        },
                    },
                    "mgmtNetworkSpec": {
                        "mgmtNetworkName": "mgmt",
                        "mgmtNetworkStartingIp": "10.0.0.20",
                        "mgmtNetworkIPCount": "3",
                    },
                    "primaryWorkloadNetwork": {
                        "primaryWorkloadNetworkName": "workload",
                        "primaryWorkloadNetworkStartingIp": "10.1.0.20",
                        "primaryWorkloadNetworkIPCount": "3",
                        "workloadServiceStartIp": "10.64.0.0",
                        "workloadServiceCount": "512",
                    },
                }
            ],
        }

    def test_minimal_supervisor_builds_required_keys(self):
        result = build_supervisor(self._minimal_payload())
        self.assertIn("commonSupervisorSpec", result)
        self.assertIn("siteSpec", result)
        common = result["commonSupervisorSpec"]
        self.assertIn("controlPlaneVMCount", common)
        self.assertIn("flbAvailability", common)

    def test_control_plane_vm_count_is_coerced_to_int(self):
        payload = self._minimal_payload()
        payload["commonSupervisorSpec"]["controlPlaneVMCount"] = "3"
        result = build_supervisor(payload)
        self.assertEqual(result["commonSupervisorSpec"]["controlPlaneVMCount"], 3)
        self.assertIsInstance(result["commonSupervisorSpec"]["controlPlaneVMCount"], int)

    def test_invalid_control_plane_vm_count_raises_value_error(self):
        payload = self._minimal_payload()
        payload["commonSupervisorSpec"]["controlPlaneVMCount"] = "not-a-number"
        with self.assertRaises(ValueError):
            build_supervisor(payload)

    def test_site_spec_edge_site_is_preserved(self):
        result = build_supervisor(self._minimal_payload())
        self.assertEqual(result["siteSpec"][0]["edgeSite"], "site-1")

    def test_flb_vip_ip_count_is_coerced_to_int(self):
        result = build_supervisor(self._minimal_payload())
        flb = result["siteSpec"][0]["foundationLoadBalancerComponents"]
        self.assertIsInstance(flb["flbVipIPCount"], int)
        self.assertEqual(flb["flbVipIPCount"], 10)

    def test_empty_site_spec_produces_empty_list(self):
        payload = self._minimal_payload()
        payload["siteSpec"] = []
        result = build_supervisor(payload)
        self.assertEqual(result["siteSpec"], [])


class TestHandlerDispatch(unittest.TestCase):
    """Tests for ConfigHandler.do_POST routing and _handle_* input validation.

    Handler methods call read_body_json() and send_json() — both are mocked here
    so tests run without a real HTTP socket.  ConfigHandler.__init__ is bypassed
    via object.__new__ (same pattern as TestCheckOrigin).
    """

    def _make_handler(self, origin="http://127.0.0.1:8080"):
        handler = object.__new__(ConfigHandler)
        handler.headers = {"Origin": origin}
        handler.path = "/"
        handler.base_dir = _HOME_DIR
        handler.send_json = unittest.mock.MagicMock()
        handler.read_body_json = unittest.mock.MagicMock()
        return handler

    def test_do_post_unknown_path_returns_404(self):
        handler = self._make_handler()
        handler.path = "/no-such-endpoint"
        handler.do_POST()
        handler.send_json.assert_called_once_with(404, {"error": "Not found."})

    def test_do_post_csrf_rejected_before_dispatch(self):
        handler = self._make_handler(origin="http://evil.example.com")
        handler.path = "/generate"
        handler.do_POST()
        status, body = handler.send_json.call_args[0]
        self.assertEqual(status, 403)
        self.assertIn("Cross-origin", body.get("error", ""))
        handler.read_body_json.assert_not_called()

    def test_do_post_localhost_origin_is_dispatched(self):
        handler = self._make_handler(origin="http://localhost:8080")
        handler.path = "/no-such-endpoint"
        handler.do_POST()
        status = handler.send_json.call_args[0][0]
        self.assertEqual(status, 404)  # dispatched, not 403

    def test_connectivity_check_no_hosts_returns_400(self):
        handler = self._make_handler()
        handler.read_body_json.return_value = {}
        handler._handle_connectivity_check()
        status, body = handler.send_json.call_args[0]
        self.assertEqual(status, 400)
        self.assertIn("hosts", body["error"].lower())

    def test_connectivity_check_too_many_hosts_returns_400(self):
        handler = self._make_handler()
        handler.read_body_json.return_value = {"hosts": [f"host{i}.lab" for i in range(51)]}
        handler._handle_connectivity_check()
        status, body = handler.send_json.call_args[0]
        self.assertEqual(status, 400)
        self.assertIn("50", body["error"])

    def test_connectivity_check_invalid_host_returns_400(self):
        handler = self._make_handler()
        handler.read_body_json.return_value = {"hosts": ["not a valid host!!!"]}
        handler._handle_connectivity_check()
        status, body = handler.send_json.call_args[0]
        self.assertEqual(status, 400)
        self.assertIn("Invalid host", body["error"])

    def test_connectivity_check_bad_json_returns_400(self):
        import json as _json
        handler = self._make_handler()
        handler.read_body_json.side_effect = _json.JSONDecodeError("bad", "", 0)
        handler._handle_connectivity_check()
        status = handler.send_json.call_args[0][0]
        self.assertEqual(status, 400)

    def test_templates_custom_outside_home_returns_400(self):
        handler = self._make_handler()
        handler.read_body_json.return_value = {"path": "/etc"}
        handler._handle_templates_custom()
        status, body = handler.send_json.call_args[0]
        self.assertEqual(status, 400)
        self.assertIn("home directory", body["error"])

    def test_templates_custom_empty_path_returns_400(self):
        handler = self._make_handler()
        handler.read_body_json.return_value = {"path": ""}
        handler._handle_templates_custom()
        status = handler.send_json.call_args[0][0]
        self.assertEqual(status, 400)

    def test_templates_custom_nonexistent_dir_returns_400(self):
        handler = self._make_handler()
        nonexistent = str(_HOME_DIR / "__veas_test_nonexistent_xyz_dir__")
        handler.read_body_json.return_value = {"path": nonexistent}
        handler._handle_templates_custom()
        status, body = handler.send_json.call_args[0]
        self.assertEqual(status, 400)
        self.assertIn("not exist", body["error"])

    def test_validate_step_unknown_step_returns_error_message(self):
        handler = self._make_handler()
        handler.read_body_json.return_value = {"step": 99, "infrastructure": {}}
        handler._handle_validate_step()
        status, body = handler.send_json.call_args[0]
        self.assertEqual(status, 200)
        self.assertFalse(body["passed"])
        self.assertTrue(any("Unknown step" in m for m in body["messages"]))

    def test_handle_save_validation_failure_returns_422_and_no_write(self):
        """When validation fails, /save must return 422 and not write any files."""
        with tempfile.TemporaryDirectory() as tmp:
            handler = self._make_handler()
            handler.base_dir = Path(tmp)
            # Empty payload fails validation (missing common, clusters, etc.)
            handler.read_body_json.return_value = {"infrastructure": {}, "supervisor": {}}
            handler._handle_save()
            status = handler.send_json.call_args[0][0]
            self.assertEqual(status, 422)
            # No JSON files should have been written.
            self.assertFalse((Path(tmp) / "infrastructure.json").exists())
            self.assertFalse((Path(tmp) / "supervisor.json").exists())

    def test_handle_save_writes_both_files_on_success(self):
        """Happy-path /save: valid payload writes infrastructure.json and supervisor.json."""
        with tempfile.TemporaryDirectory() as tmp:
            handler = self._make_handler()
            handler.base_dir = Path(tmp)
            infra = _minimal_infra()
            sup_payload = _minimal_supervisor()
            handler.read_body_json.return_value = {"infrastructure": infra, "supervisor": sup_payload}
            handler._handle_save()
            status, body = handler.send_json.call_args[0]
            self.assertEqual(status, 200)
            self.assertTrue(body.get("saved"))
            self.assertTrue((Path(tmp) / "infrastructure.json").exists())
            self.assertTrue((Path(tmp) / "supervisor.json").exists())


class TestSafeResolvePath(unittest.TestCase):
    """Tests for _safe_resolve_path — home-directory confinement."""

    def test_empty_string_returns_none(self):
        self.assertIsNone(_safe_resolve_path(""))

    def test_within_home_returns_path(self):
        within_home = str(_HOME_DIR / "some_subdir" / "file.json")
        result = _safe_resolve_path(within_home)
        self.assertIsNotNone(result)

    def test_outside_home_returns_none(self):
        self.assertIsNone(_safe_resolve_path("/etc/passwd"))

    def test_traversal_escape_returns_none(self):
        traversal = str(_HOME_DIR / ".." / ".." / "etc" / "shadow")
        self.assertIsNone(_safe_resolve_path(traversal))

    def test_home_dir_itself_is_allowed(self):
        result = _safe_resolve_path(str(_HOME_DIR))
        self.assertIsNotNone(result)

    def test_tilde_expansion_within_home(self):
        result = _safe_resolve_path("~/Documents")
        self.assertIsNotNone(result)


class TestIsWindowsAbsolutePath(unittest.TestCase):
    """Tests for _is_windows_absolute_path — Windows path detection."""

    def test_drive_letter_backslash(self):
        self.assertTrue(_is_windows_absolute_path(r"C:\Users\Administrator\Documents"))

    def test_drive_letter_forward_slash(self):
        self.assertTrue(_is_windows_absolute_path("D:/some/path"))

    def test_unc_path(self):
        self.assertTrue(_is_windows_absolute_path(r"\\server\share"))

    def test_posix_absolute(self):
        self.assertFalse(_is_windows_absolute_path("/home/user/docs"))

    def test_tilde_path(self):
        self.assertFalse(_is_windows_absolute_path("~/Documents"))

    def test_relative_path(self):
        self.assertFalse(_is_windows_absolute_path("relative/path"))

    def test_empty_string(self):
        self.assertFalse(_is_windows_absolute_path(""))


class TestIsPosixAbsolutePath(unittest.TestCase):
    """Tests for _is_posix_absolute_path — POSIX path detection."""

    def test_posix_absolute(self):
        self.assertTrue(_is_posix_absolute_path("/home/user/docs"))

    def test_posix_root(self):
        self.assertTrue(_is_posix_absolute_path("/"))

    def test_windows_drive_letter(self):
        self.assertFalse(_is_posix_absolute_path(r"C:\Users\foo"))

    def test_tilde_path(self):
        self.assertFalse(_is_posix_absolute_path("~/Documents"))

    def test_relative_path(self):
        self.assertFalse(_is_posix_absolute_path("relative/path"))

    def test_empty_string(self):
        self.assertFalse(_is_posix_absolute_path(""))


class TestWindowsPathFallback(unittest.TestCase):
    """Tests that cross-OS parentDirectory values produce a WARNING and fall back to base_dir."""

    _WINDOWS_PATH = r"C:\Users\Administrator\Documents"
    _POSIX_PATH = "/home/user/vcf-yaml-files"

    def _minimal_infra_supervisor(self, parent_dir):
        return {
            "common": {
                "vCenterName": "vc.lab.local",
                "vCenterUser": "admin@vsphere.local",
                "datacenterName": "dc1",
                "nicList": [{"name": "vmnic0"}, {"name": "vmnic1"}],
                "supervisorServices": {
                    "parentDirectory": parent_dir,
                    "argoCdOperatorYamlFileName": "argocd-operator.yaml",
                },
            }
        }

    @unittest.mock.patch("sys.platform", "darwin")
    def test_supervisor_windows_path_emits_warning(self):
        infra = self._minimal_infra_supervisor(self._WINDOWS_PATH)
        msgs = _validate_step1_messages(infra, base_dir=_HOME_DIR)
        warnings = [m for m in msgs if "[WARNING]" in m and "Windows" in m]
        self.assertGreater(len(warnings), 0, msgs)

    @unittest.mock.patch("sys.platform", "darwin")
    def test_supervisor_windows_path_no_directory_error(self):
        infra = self._minimal_infra_supervisor(self._WINDOWS_PATH)
        msgs = _validate_step1_messages(infra, base_dir=_HOME_DIR)
        dir_errors = [m for m in msgs if "[ERROR]" in m and "parentDirectory" in m]
        self.assertEqual(dir_errors, [], msgs)

    @unittest.mock.patch("sys.platform", "darwin")
    def test_harbor_windows_path_emits_warning(self):
        infra = {
            "clusters": [{
                "edgeSite": "site-1",
                "harborConfiguration": {
                    "parentDirectory": self._WINDOWS_PATH,
                    "tlsCrt": "tls.crt",
                },
            }]
        }
        msgs = _validate_step2_harbor_files(infra, base_dir=_HOME_DIR)
        warnings = [m for m in msgs if "[WARNING]" in m and "Windows" in m]
        self.assertGreater(len(warnings), 0, msgs)

    @unittest.mock.patch("sys.platform", "darwin")
    def test_harbor_windows_path_no_directory_error(self):
        infra = {
            "clusters": [{
                "edgeSite": "site-1",
                "harborConfiguration": {
                    "parentDirectory": self._WINDOWS_PATH,
                    "tlsCrt": "tls.crt",
                },
            }]
        }
        msgs = _validate_step2_harbor_files(infra, base_dir=_HOME_DIR)
        # Match only errors where parentDirectory is the subject field (ends with ".parentDirectory:"),
        # not messages that merely mention the word in their body text.
        dir_errors = [m for m in msgs if "[ERROR]" in m and ".parentDirectory:" in m]
        self.assertEqual(dir_errors, [], msgs)

    @unittest.mock.patch("sys.platform", "win32")
    def test_supervisor_posix_path_emits_warning(self):
        infra = self._minimal_infra_supervisor(self._POSIX_PATH)
        msgs = _validate_step1_messages(infra, base_dir=_HOME_DIR)
        warnings = [m for m in msgs if "[WARNING]" in m and "POSIX" in m]
        self.assertGreater(len(warnings), 0, msgs)

    @unittest.mock.patch("sys.platform", "win32")
    def test_supervisor_posix_path_no_directory_error(self):
        infra = self._minimal_infra_supervisor(self._POSIX_PATH)
        msgs = _validate_step1_messages(infra, base_dir=_HOME_DIR)
        dir_errors = [m for m in msgs if "[ERROR]" in m and "parentDirectory" in m]
        self.assertEqual(dir_errors, [], msgs)

    @unittest.mock.patch("sys.platform", "win32")
    def test_harbor_posix_path_emits_warning(self):
        infra = {
            "clusters": [{
                "edgeSite": "site-1",
                "harborConfiguration": {
                    "parentDirectory": self._POSIX_PATH,
                    "tlsCrt": "tls.crt",
                },
            }]
        }
        msgs = _validate_step2_harbor_files(infra, base_dir=_HOME_DIR)
        warnings = [m for m in msgs if "[WARNING]" in m and "POSIX" in m]
        self.assertGreater(len(warnings), 0, msgs)

    @unittest.mock.patch("sys.platform", "win32")
    def test_harbor_posix_path_no_directory_error(self):
        infra = {
            "clusters": [{
                "edgeSite": "site-1",
                "harborConfiguration": {
                    "parentDirectory": self._POSIX_PATH,
                    "tlsCrt": "tls.crt",
                },
            }]
        }
        msgs = _validate_step2_harbor_files(infra, base_dir=_HOME_DIR)
        dir_errors = [m for m in msgs if "[ERROR]" in m and ".parentDirectory:" in m]
        self.assertEqual(dir_errors, [], msgs)


class TestCheckOrigin(unittest.TestCase):
    """Tests for ConfigHandler._check_origin — CSRF origin guard."""

    def _make_handler(self, origin_value):
        """Bypass BaseHTTPRequestHandler.__init__ and inject a headers dict."""
        handler = object.__new__(ConfigHandler)
        if origin_value is None:
            handler.headers = {}
        else:
            handler.headers = {"Origin": origin_value}
        return handler

    def test_no_origin_header_is_allowed(self):
        self.assertTrue(self._make_handler(None)._check_origin())

    def test_empty_origin_is_allowed(self):
        self.assertTrue(self._make_handler("")._check_origin())

    def test_ipv4_loopback_is_allowed(self):
        self.assertTrue(self._make_handler("http://127.0.0.1:8080")._check_origin())

    def test_ipv6_loopback_is_allowed(self):
        self.assertTrue(self._make_handler("http://[::1]:8080")._check_origin())

    def test_localhost_is_allowed(self):
        self.assertTrue(self._make_handler("http://localhost:8080")._check_origin())

    def test_external_host_is_rejected(self):
        self.assertFalse(self._make_handler("http://evil.example.com")._check_origin())

    def test_malformed_origin_is_rejected(self):
        self.assertFalse(self._make_handler("not-a-url")._check_origin())

    def test_null_origin_is_rejected(self):
        # Browsers send Origin: null for file:// and sandboxed pages; must never be trusted.
        self.assertFalse(self._make_handler("null")._check_origin())

    def test_machine_hostname_is_allowed(self):
        # Windows Server browsers often open http://<COMPUTERNAME>:<port> instead of localhost.
        import socket
        short = socket.gethostname().lower().split(".")[0]
        self.assertTrue(self._make_handler(f"http://{short}:8080")._check_origin())

    def test_machine_hostname_uppercase_is_allowed(self):
        # Origin header hostname comparison must be case-insensitive.
        import socket
        short = socket.gethostname().upper().split(".")[0]
        self.assertTrue(self._make_handler(f"http://{short}:8080")._check_origin())

    def test_machine_fqdn_is_allowed(self):
        # socket.getfqdn() is also added to _ALLOWED_ORIGIN_HOSTS at startup.
        import socket
        fqdn = socket.getfqdn().lower()
        self.assertTrue(self._make_handler(f"http://{fqdn}:8080")._check_origin())


class TestFqdnRegex(unittest.TestCase):
    """Tests for FQDN_OR_IPV4_RE — valid inputs pass, ReDoS inputs do not hang."""

    def test_valid_ipv4(self):
        self.assertIsNotNone(FQDN_OR_IPV4_RE.match("192.168.1.1"))

    def test_valid_fqdn(self):
        self.assertIsNotNone(FQDN_OR_IPV4_RE.match("vcenter.lab.local"))

    def test_valid_single_label(self):
        self.assertIsNotNone(FQDN_OR_IPV4_RE.match("vcenter"))

    def test_invalid_empty_string(self):
        self.assertIsNone(FQDN_OR_IPV4_RE.match(""))

    def test_rfc1123_regex_accepts_valid_edge_site(self):
        self.assertIsNotNone(RFC1123_RE.match("site-1"))

    def test_rfc1123_regex_rejects_uppercase(self):
        self.assertIsNone(RFC1123_RE.match("Site1"))

    def test_rfc1123_regex_rejects_leading_hyphen(self):
        self.assertIsNone(RFC1123_RE.match("-site1"))

    def test_rfc1123_regex_rejects_trailing_hyphen(self):
        self.assertIsNone(RFC1123_RE.match("site1-"))

    def test_rfc1123_regex_rejects_81_char_name(self):
        self.assertIsNone(RFC1123_RE.match("a" * 81))

    @unittest.skipUnless(
        hasattr(__import__("signal"), "SIGALRM"),
        "SIGALRM not available on Windows — ReDoS timeout test skipped.",
    )
    def test_redos_candidate_does_not_hang(self):
        """Potential ReDoS input — must complete near-instantly."""
        def _timeout(_sig, _frame):
            raise AssertionError("FQDN_OR_IPV4_RE timed out — possible ReDoS")

        signal.signal(signal.SIGALRM, _timeout)
        signal.alarm(2)
        try:
            FQDN_OR_IPV4_RE.match("0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.")
        finally:
            signal.alarm(0)


class TestEdgeSiteValidationInInfrastructure(unittest.TestCase):
    """Tests that infrastructure edgeSite field enforces RFC1123 via validate_infrastructure."""

    def _infra(self, edge_site):
        return {"common": _minimal_common(), "clusters": [_minimal_cluster(edge_site=edge_site)]}

    def test_valid_edge_site_produces_no_error(self):
        result = validate_infrastructure(self._infra("site-1"))
        edge_errors = [e for e in result.errors if "edgeSite" in e and "must be" in e]
        self.assertEqual(edge_errors, [])

    def test_uppercase_edge_site_is_rejected(self):
        result = validate_infrastructure(self._infra("Site1"))
        edge_errors = [e for e in result.errors if "edgeSite" in e and "must be" in e]
        self.assertGreater(len(edge_errors), 0)

    def test_leading_hyphen_edge_site_is_rejected(self):
        result = validate_infrastructure(self._infra("-site1"))
        edge_errors = [e for e in result.errors if "edgeSite" in e and "must be" in e]
        self.assertGreater(len(edge_errors), 0)

    def test_trailing_hyphen_edge_site_is_rejected(self):
        result = validate_infrastructure(self._infra("site1-"))
        edge_errors = [e for e in result.errors if "edgeSite" in e and "must be" in e]
        self.assertGreater(len(edge_errors), 0)

    def test_81_char_edge_site_is_rejected(self):
        result = validate_infrastructure(self._infra("a" * 81))
        edge_errors = [e for e in result.errors if "edgeSite" in e and "must be" in e]
        self.assertGreater(len(edge_errors), 0)


class TestPathTraversalFilenames(unittest.TestCase):
    """Tests that _validate_step1_messages and _validate_step2_harbor_files reject traversal filenames."""

    def _minimal_infra_with_supervisor_service(self, filename):
        return {
            "common": {
                "vCenterName": "vc.lab.local",
                "vCenterUser": "admin@vsphere.local",
                "datacenterName": "dc1",
                "nicList": [{"name": "vmnic0"}, {"name": "vmnic1"}],
                "supervisorServices": {
                    "parentDirectory": str(_HOME_DIR),
                    "argoCdOperatorYamlFileName": filename,
                },
            }
        }

    def test_step1_traversal_filename_emits_error(self):
        infra = self._minimal_infra_with_supervisor_service("../../etc/shadow")
        msgs = _validate_step1_messages(infra, base_dir=_HOME_DIR)
        traversal_errors = [m for m in msgs if "path separators" in m]
        self.assertGreater(len(traversal_errors), 0, msgs)

    def test_step1_normal_filename_does_not_emit_traversal_error(self):
        infra = self._minimal_infra_with_supervisor_service("argocd-operator.yaml")
        msgs = _validate_step1_messages(infra, base_dir=_HOME_DIR)
        traversal_errors = [m for m in msgs if "path separators" in m]
        self.assertEqual(traversal_errors, [])

    def test_step2_traversal_filename_emits_error(self):
        infra = {
            "clusters": [
                {
                    "edgeSite": "site-1",
                    "harborConfiguration": {
                        "parentDirectory": str(_HOME_DIR),
                        "tlsCrt": "../../etc/shadow",
                    },
                }
            ]
        }
        msgs = _validate_step2_harbor_files(infra, base_dir=_HOME_DIR)
        traversal_errors = [m for m in msgs if "path separators" in m]
        self.assertGreater(len(traversal_errors), 0, msgs)

    def test_step2_normal_filename_does_not_emit_traversal_error(self):
        infra = {
            "clusters": [
                {
                    "edgeSite": "site-1",
                    "harborConfiguration": {
                        "parentDirectory": str(_HOME_DIR),
                        "tlsCrt": "tls.crt",
                    },
                }
            ]
        }
        msgs = _validate_step2_harbor_files(infra, base_dir=_HOME_DIR)
        traversal_errors = [m for m in msgs if "path separators" in m]
        self.assertEqual(traversal_errors, [])


# ---------------------------------------------------------------------------
# veas-launcher.py — env var allowlist filter
# ---------------------------------------------------------------------------
_LAUNCHER_PATH = Path(__file__).parent / "veas-launcher.py"
_launcher_spec = importlib.util.spec_from_file_location("veas_launcher", _LAUNCHER_PATH)
_launcher_mod = importlib.util.module_from_spec(_launcher_spec)
_launcher_spec.loader.exec_module(_launcher_mod)

_ENV_VAR_ALLOWED_SUFFIXES = _launcher_mod._ENV_VAR_ALLOWED_SUFFIXES
_ENV_VAR_ALLOWED_EXACT    = _launcher_mod._ENV_VAR_ALLOWED_EXACT
_ENV_VAR_KEY_RE           = _launcher_mod._ENV_VAR_KEY_RE


def _is_allowed(key: str) -> bool:
    """Mirrors the allowlist filter logic in veas-launcher._handle_launch."""
    key_upper = key.upper()
    return key_upper in _ENV_VAR_ALLOWED_EXACT or any(
        key_upper.endswith(s) for s in _ENV_VAR_ALLOWED_SUFFIXES
    )


class TestEnvVarFilter(unittest.TestCase):
    """Tests for the env_vars allowlist in veas-launcher._handle_launch.

    The allowlist model means only credential/config keys matching known
    suffixes (_PASSWORD, _PW, _KEY, _TOKEN, _SECRET, _CERT, _PASS) or
    the exact-match set are forwarded; everything else is dropped.
    This is architecturally superior to a denylist because it cannot be
    bypassed by novel environment variable names.
    """

    # --- Allowlist: keys that MUST pass through ---

    def test_harbor_admin_password_is_allowed(self):
        self.assertTrue(_is_allowed("HARBOR_ADMIN_PASSWORD"))

    def test_harbor_admin_pw_is_allowed(self):
        self.assertTrue(_is_allowed("HARBOR_ADMIN_PW"))

    def test_vcenter_common_password_is_allowed(self):
        self.assertTrue(_is_allowed("VCENTER_COMMON_PASSWORD"))

    def test_esx_common_password_is_allowed(self):
        self.assertTrue(_is_allowed("ESX_COMMON_PASSWORD"))

    def test_my_secret_key_is_allowed(self):
        self.assertTrue(_is_allowed("MY_SECRET_KEY"))

    def test_my_api_token_is_allowed(self):
        self.assertTrue(_is_allowed("MY_API_TOKEN"))

    def test_tls_cert_is_allowed(self):
        self.assertTrue(_is_allowed("HARBOR_TLS_CERT"))

    def test_db_secret_is_allowed(self):
        self.assertTrue(_is_allowed("DB_SECRET"))

    def test_suffix_match_is_case_insensitive(self):
        # "_password" lowercase suffix must still be allowed.
        self.assertTrue(_is_allowed("harbor_admin_password"))

    # --- Denylist: keys that MUST be dropped (not on allowlist) ---

    def test_ld_preload_is_not_allowed(self):
        # Dynamic linker hijack — must be dropped.
        self.assertFalse(_is_allowed("LD_PRELOAD"))

    def test_ld_preload_lowercase_is_not_allowed(self):
        self.assertFalse(_is_allowed("ld_preload"))

    def test_path_is_not_allowed(self):
        self.assertFalse(_is_allowed("PATH"))

    def test_path_lowercase_is_not_allowed(self):
        self.assertFalse(_is_allowed("path"))

    def test_home_is_not_allowed(self):
        self.assertFalse(_is_allowed("HOME"))

    def test_dotnet_root_is_not_allowed(self):
        self.assertFalse(_is_allowed("DOTNET_ROOT"))

    def test_xdg_data_home_is_not_allowed(self):
        self.assertFalse(_is_allowed("XDG_DATA_HOME"))

    def test_tmpdir_is_not_allowed(self):
        self.assertFalse(_is_allowed("TMPDIR"))

    def test_shell_is_not_allowed(self):
        self.assertFalse(_is_allowed("SHELL"))

    def test_psmodulepath_is_not_allowed(self):
        self.assertFalse(_is_allowed("PSMODULEPATH"))

    def test_arbitrary_custom_var_is_not_allowed(self):
        # A generic setting that isn't a credential is dropped.
        self.assertFalse(_is_allowed("MY_CUSTOM_SETTING"))

    def test_perl5lib_is_not_allowed(self):
        # Novel runtime var not in any denylist — allowlist catches it automatically.
        self.assertFalse(_is_allowed("PERL5LIB"))

    def test_rubylib_is_not_allowed(self):
        self.assertFalse(_is_allowed("RUBYLIB"))

    def test_gopath_is_not_allowed(self):
        self.assertFalse(_is_allowed("GOPATH"))

    # --- Key format validation ---

    def test_env_var_key_re_rejects_empty(self):
        self.assertIsNone(_ENV_VAR_KEY_RE.match(""))

    def test_env_var_key_re_rejects_hyphenated(self):
        self.assertIsNone(_ENV_VAR_KEY_RE.match("MY-VAR"))

    def test_env_var_key_re_accepts_valid_identifier(self):
        self.assertIsNotNone(_ENV_VAR_KEY_RE.match("MY_VAR_123"))

    def test_value_length_limit_constant_exists(self):
        self.assertGreater(_launcher_mod._MAX_ENV_VAR_VALUE_BYTES, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
