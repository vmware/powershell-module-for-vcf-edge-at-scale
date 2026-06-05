# VcfEdgeAtScale Test Coverage

## Test File Structure

The unit test suite is organized into per-source-file test modules. Each file covers the functions
defined in its corresponding `Private/*.ps1` source file.

| Test File | Source File | Describes | Lines |
|---|---|---|---|
| `VcfEdgeAtScale.Cluster.Tests.ps1` | `Private/Cluster.ps1` | 156 | ~7.2k |
| `VcfEdgeAtScale.Deployment.Tests.ps1` | `Private/Deployment.ps1` | 60 | ~4k |
| `VcfEdgeAtScale.EntryPoints.Tests.ps1` | `Private/EntryPoints.ps1` | 31 | ~1.8k |
| `VcfEdgeAtScale.Infrastructure.Tests.ps1` | Module-level types, exceptions, metadata | 9 | ~440 |
| `VcfEdgeAtScale.Logging.Tests.ps1` | `Private/Logging.ps1` | 45 | ~1.7k |
| `VcfEdgeAtScale.Networking.Tests.ps1` | `Private/Networking.ps1` | 106 | ~6.1k |
| `VcfEdgeAtScale.Supervisor.Tests.ps1` | `Private/Supervisor.ps1` | 121 | ~6.8k |
| `VcfEdgeAtScale.Validation.Tests.ps1` | `Private/Validation.ps1` | 107 | ~5.2k |
| `VcfEdgeAtScale.Yaml.Tests.ps1` | `Private/Yaml.ps1` | 10 | ~450 |
| `VcfEdgeAtScale.Live.Tests.ps1` | Full system (requires vCenter) | 65 | ~1.7k |

## Running Tests

```powershell
# Run all unit tests (auto-discovers all VcfEdgeAtScale.*.Tests.ps1 files)
./Tests/Run-Tests.ps1

# Run only one module area
./Tests/Run-Tests.ps1 -Module Cluster
./Tests/Run-Tests.ps1 -Module Networking
./Tests/Run-Tests.ps1 -Module Supervisor

# Run a single Describe block by name
./Tests/Run-Tests.ps1 -Filter "*Assert-ContextKeys*"

# Run with live integration tests (requires VCF_TEST_VCENTER + VCF_TEST_PASSWORD)
./Tests/Run-Tests.ps1 -Live

# Run only live tests
./Tests/Run-Tests.ps1 -Live -TestPath ""
```

## Coverage Gaps (Intentionally Deferred)

The following functions have no unit tests because they require live infrastructure state
that cannot be meaningfully mocked without a real VDS object graph, ESX host, or vCenter session.
Integration coverage via `VcfEdgeAtScale.Live.Tests.ps1` is the appropriate test layer for these.

| Function | File | Reason deferred |
|---|---|---|
| `Invoke-ManagementRestoreForCleanup` | `Networking.ps1` | Requires live VDS port group objects |
| `Invoke-VdsPnicDetach` | `Networking.ps1` | Requires live VDS and pNIC objects |
| `Invoke-VdsPortGroupFirstPass` | `Networking.ps1` | Requires live VDS |
| `Invoke-VdsPortGroupRestoreFallback` | `Networking.ps1` | Requires live VDS |
| `Invoke-VsanOsaStaleDiskClaimResolution` | `Networking.ps1` | Requires live vSAN disk state |
| `Invoke-VsanEsaStaleClaimRemediation` | `Networking.ps1` | Requires live vSAN ESA state |
| `Invoke-SupervisorUpgradePollLoop` | `Supervisor.ps1` | Long-running poll; live-only |
| `Invoke-SupervisorPollUntilReady` | `Supervisor.ps1` | Long-running poll; live-only |
| `Invoke-VsanPreSupervisorRollbackCore` | `Deployment.ps1` | Full teardown; live-only (core helpers tested) |
| `Get-InsecureTlsFromPowerCliConfig` | `Supervisor.ps1` | Reads live PowerCLI config |
| `Get-MacOsVersionInfo` / `Get-WindowsVersionInfo` | `Logging.ps1` | Platform detection; live-only |
| `Read-HarborSecretInteractively` | `Validation.ps1` | Requires interactive console |

## Coverage Philosophy

- **Unit tests** mock all external dependencies (VMware PowerCLI cmdlets, file system, network).
  They test logic correctness: branching, error propagation, state mutations.
- **Live tests** validate the module against a real VCF/vCenter environment. They are skipped
  gracefully (not failed) when the required infrastructure is absent.
- Functions that are purely orchestration (sequential dispatch with no logic of their own) are
  covered indirectly through their callers' tests.
- Diagnostic `Write-*` helpers are smoke-tested to ensure they do not throw.

## Adding New Tests

1. Find the correct test file for the function's source file (e.g. functions in `Private/Cluster.ps1`
   belong in `VcfEdgeAtScale.Cluster.Tests.ps1`).
2. Add the `Describe` block adjacent to the closest sibling function's tests.
3. Follow the Pester 5 patterns in `CLAUDE.md` (Rules 1–13).
4. Run `./Tests/Run-Tests.ps1 -Module <Area>` to verify your additions pass before committing.
