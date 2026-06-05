# Pester tests for VcfEdgeAtScale — Private/Yaml.ps1
#
# RECOMMENDED: Use the wrapper script for human-readable output:
#   ./Tests/Run-Tests.ps1
#   ./Tests/Run-Tests.ps1 -Filter "*FunctionName*"
#
# DIRECT: Invoke-Pester -Path ./Tests/VcfEdgeAtScale.Yaml.Tests.ps1 -Output Detailed
#
# Internal functions are invoked via InModuleScope so the scriptblock runs in module scope.
# Log suppression: Write-LogMessage console output is silenced globally via $Script:LogOnly = "enabled".

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot ".."
    $manifestPath = Join-Path $moduleRoot "VcfEdgeAtScale.psd1"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Module manifest not found at $manifestPath. Run tests from the VcfEdgeAtScale module directory or set path."
    }

    # Ensure no stale copy is loaded before importing the source version.
    # Without this, running from an interactive session that already imported VcfEdgeAtScale
    # (e.g. from PSModulePath or a prior run) leaves two copies in the session, and
    # InModuleScope throws "Multiple script or manifest modules named 'VcfEdgeAtScale' are loaded".
    $null = Remove-Module -Name "VcfEdgeAtScale" -Force -ErrorAction SilentlyContinue

    $script:mod = Import-Module $manifestPath -Force -PassThru -ErrorAction Stop

    # Suppress Write-LogMessage console output for the entire test run.
    # Production code writes [ERROR]/[WARNING]/[INFO] to screen via Write-Host inside Write-LogMessage.
    # Without suppression those lines appear interleaved with Pester output and look alarming even
    # when every test is passing. Setting LogOnly = "enabled" routes all output to the log file only.
    InModuleScope VcfEdgeAtScale { $Script:LogOnly = "enabled" }

    # Snapshot harbor env vars so any unit test that nulls them out cannot pollute a subsequent
    # live test run in the same Invoke-Pester session. Restored in AfterAll below.
    $script:_unitTestSavedHarborPw  = $env:HARBOR_ADMIN_PASSWORD
    $script:_unitTestSavedSecretKey = $env:SECRET_KEY
}
AfterAll {
    InModuleScope VcfEdgeAtScale { $Script:LogOnly = $null }
    $null = Remove-Module -Name "VcfEdgeAtScale" -ErrorAction SilentlyContinue
    # Restore harbor env vars to their pre-unit-test values so live tests that run in the same
    # Pester session (./Tests/Run-Tests.ps1 -Live) see the operator-supplied credentials.
    $env:HARBOR_ADMIN_PASSWORD = $script:_unitTestSavedHarborPw
    $env:SECRET_KEY             = $script:_unitTestSavedSecretKey
}

Describe "ConvertFrom-Yaml" {
    # Both ConvertFrom-Yaml and ConvertTo-Yaml use ValueFromPipeline=$true; invoke via pipeline inside module scope.
    It "Round-trips a simple key-value document" {
        # ConvertFrom-Yaml returns a Hashtable directly (not wrapped in an array).
        $yaml = "name: testvalue`ncount: 42"
        $parsed = InModuleScope VcfEdgeAtScale -ArgumentList $yaml { $args[0] | ConvertFrom-Yaml }
        $parsed | Should -Not -BeNullOrEmpty
        $parsed["name"] | Should -Be "testvalue"
        $parsed["count"] | Should -Be 42
    }

    It "Parses nested objects" {
        $yaml = "parent:`n  child: hello"
        $parsed = InModuleScope VcfEdgeAtScale -ArgumentList $yaml { $args[0] | ConvertFrom-Yaml }
        $parsed["parent"]["child"] | Should -Be "hello"
    }

    It "Handles empty content gracefully" {
        $result = InModuleScope VcfEdgeAtScale { "" | ConvertFrom-Yaml }
        $result | Should -BeNullOrEmpty
    }

    It "Recognizes nested array items (TrimStart fix — previously logged as 'not recognized, skipping')" {
        $yaml = "parent:`n  items:`n    - apple`n    - banana"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $yaml { $args[0] | ConvertFrom-Yaml }
        # Array items stored under the empty-string key in the parent container.
        $result["parent"]["items"][""] | Should -Not -BeNullOrEmpty
        $result["parent"]["items"][""] | Should -Contain "apple"
        $result["parent"]["items"][""] | Should -Contain "banana"
    }

    It "Parses 4-space indented YAML correctly when IndentSize is 4" {
        $yaml = "parent:`n    child: hello"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $yaml {
            $args[0] | ConvertFrom-Yaml -IndentSize 4
        }
        $result["parent"]["child"] | Should -Be "hello"
    }
}

Describe "ConvertTo-Yaml" {
    It "Produces key: value output for an ordered dictionary" {
        $obj = [ordered]@{ key = "value" }
        $yaml = InModuleScope VcfEdgeAtScale -ArgumentList $obj { $args[0] | ConvertTo-Yaml }
        $yaml | Should -Match "key:"
        $yaml | Should -Match "value"
    }

    It "Produces key: value output for a regular hashtable" {
        $obj = @{ key = "value" }
        $yaml = InModuleScope VcfEdgeAtScale -ArgumentList $obj { $args[0] | ConvertTo-Yaml }
        $yaml | Should -Match "key:"
        $yaml | Should -Match "value"
    }

    It "Indents nested objects correctly" {
        $obj = [ordered]@{ parent = [ordered]@{ child = "hello" } }
        $yaml = InModuleScope VcfEdgeAtScale -ArgumentList $obj { $args[0] | ConvertTo-Yaml }
        # The child key must be indented (appear after at least two spaces) — not at column 0.
        $yaml | Should -Match "(?m)^\s+child:"
        $yaml | Should -Match "hello"
    }

    It "Indents array items correctly" {
        $obj = [ordered]@{ items = @("a", "b") }
        $yaml = InModuleScope VcfEdgeAtScale -ArgumentList $obj { $args[0] | ConvertTo-Yaml }
        $yaml | Should -Match "items:"
        $yaml | Should -Match "(?m)^\s+-\s+a"
        $yaml | Should -Match "(?m)^\s+-\s+b"
    }

    It "Round-trips through ConvertFrom-Yaml for nested structures" {
        $obj = [ordered]@{ name = "test"; config = [ordered]@{ enabled = "true"; count = "2" } }
        $yaml = InModuleScope VcfEdgeAtScale -ArgumentList $obj { $args[0] | ConvertTo-Yaml }
        $roundTripped = InModuleScope VcfEdgeAtScale -ArgumentList $yaml { $args[0] | ConvertFrom-Yaml }
        $roundTripped["name"] | Should -Be "test"
        $roundTripped["config"]["enabled"] | Should -Be "true"
    }
}


Describe "ConvertTo-YamlLiteralBlock" {
    BeforeAll {
        $script:tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-test-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Produces correct key line and indented content lines" {
        $certFile = Join-Path $script:tempDir "tls.crt"
        Set-Content -Path $certFile -Value "-----BEGIN CERTIFICATE-----`nMIIByTCC`n-----END CERTIFICATE-----" -Encoding UTF8 -NoNewline
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $certFile { ConvertTo-YamlLiteralBlock -FilePath $args[0] -KeyName "tls.crt" -KeyIndentSpaces 2 }
        $result | Should -Match "^  tls\.crt: \|"
        $result | Should -Match "    -----BEGIN CERTIFICATE-----"
        $result | Should -Match "    -----END CERTIFICATE-----"
    }

    It "Normalizes CRLF line endings to LF" {
        $crlfFile = Join-Path $script:tempDir "crlf.txt"
        [System.IO.File]::WriteAllBytes($crlfFile, [System.Text.Encoding]::UTF8.GetBytes("line1`r`nline2`r`nline3"))
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $crlfFile { ConvertTo-YamlLiteralBlock -FilePath $args[0] -KeyName "data" -KeyIndentSpaces 0 }
        $result | Should -Not -Match "\r"
        $result | Should -Match "line1"
        $result | Should -Match "line2"
    }

    It "Respects KeyIndentSpaces = 0 (no leading indent)" {
        $simpleFile = Join-Path $script:tempDir "simple.txt"
        Set-Content -Path $simpleFile -Value "hello" -Encoding UTF8 -NoNewline
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $simpleFile { ConvertTo-YamlLiteralBlock -FilePath $args[0] -KeyName "msg" -KeyIndentSpaces 0 }
        $result | Should -Match "^msg: \|"
        # (?m) enables multiline mode so ^ matches start of each line, not start of the whole string.
        $result | Should -Match "(?m)^  hello"
    }
}


Describe "ConvertTo-YamlSingleQuotedScalar" {
    It "Wraps a plain value in single quotes" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-YamlSingleQuotedScalar -Value "mypassword" }
        $result | Should -Be "'mypassword'"
    }

    It "Doubles embedded single quotes" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-YamlSingleQuotedScalar -Value "it's" }
        $result | Should -Be "'it''s'"
    }

    It "Safely wraps a value starting with a YAML flow indicator ({)" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-YamlSingleQuotedScalar -Value "{bad}" }
        $result | Should -Be "'{bad}'"
    }

    It "Safely wraps a value containing a colon-space sequence" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-YamlSingleQuotedScalar -Value "host: value" }
        $result | Should -Be "'host: value'"
    }

    It "Returns empty single-quoted string for empty input" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-YamlSingleQuotedScalar -Value "" }
        $result | Should -Be "''"
    }

    It "Handles a value that contains only single quotes" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-YamlSingleQuotedScalar -Value "''" }
        # Input ''  (2 quotes) → each ' doubled → '''' (4 quotes) → wrapped → '''''' (6 quotes).
        $result | Should -Be "''''''"
    }
}


Describe "ConvertFrom-YamlValue" {
    It "Returns null for whitespace-only input" {
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "   " } | Should -Be $null
    }

    It "Converts integer string to Int64" {
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "42" } | Should -Be 42
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "42" } | Should -BeOfType [Int64]
    }

    It "Converts negative integer string" {
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "-7" } | Should -Be -7
    }

    It "Converts integer string larger than Int32.MaxValue to Int64 without overflow" {
        $result = InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "2147483648" }
        $result | Should -Be 2147483648
        $result | Should -BeOfType [Int64]
    }

    It "Converts decimal string to double" {
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "3.14" } | Should -Be 3.14
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "3.14" } | Should -BeOfType [double]
    }

    It "Converts 'true' / 'True' / 'TRUE' to boolean true" {
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "true" }  | Should -Be $true
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "True" }  | Should -Be $true
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "TRUE" }  | Should -Be $true
    }

    It "Converts 'false' / 'False' / 'FALSE' to boolean false" {
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "false" } | Should -Be $false
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "False" } | Should -Be $false
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "FALSE" } | Should -Be $false
    }

    It "Converts 'null' / 'Null' / 'NULL' / '~' to null" {
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "null" }  | Should -Be $null
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "Null" }  | Should -Be $null
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "NULL" }  | Should -Be $null
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "~" }     | Should -Be $null
    }

    It "Returns plain string for unquoted non-special values" {
        InModuleScope VcfEdgeAtScale { ConvertFrom-YamlValue -Value "hello" } | Should -Be "hello"
    }
}


Describe "ConvertTo-YamlValue" {
    It "Returns 'null' for null input" {
        InModuleScope VcfEdgeAtScale { ConvertTo-YamlValue -Value $null -IndentSize 2 -CurrentIndent 0 } | Should -Be "null"
    }

    It "Returns 'true' for boolean true" {
        InModuleScope VcfEdgeAtScale { ConvertTo-YamlValue -Value $true -IndentSize 2 -CurrentIndent 0 } | Should -Be "true"
    }

    It "Returns 'false' for boolean false" {
        InModuleScope VcfEdgeAtScale { ConvertTo-YamlValue -Value $false -IndentSize 2 -CurrentIndent 0 } | Should -Be "false"
    }

    It "Returns string representation of an integer" {
        InModuleScope VcfEdgeAtScale { ConvertTo-YamlValue -Value 42 -IndentSize 2 -CurrentIndent 0 } | Should -Be "42"
    }

    It "Returns plain string for a simple identifier" {
        InModuleScope VcfEdgeAtScale { ConvertTo-YamlValue -Value "hello" -IndentSize 2 -CurrentIndent 0 } | Should -Be "hello"
    }

    It "Returns quoted string when value contains a colon" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-YamlValue -Value "host:port" -IndentSize 2 -CurrentIndent 0 }
        $result | Should -Match '"'
    }

    It "Returns quoted string for a value that starts with a digit" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-YamlValue -Value "123abc" -IndentSize 2 -CurrentIndent 0 }
        $result | Should -Match '"'
    }

    It "Returns quoted string for 'true' as a string (not bool)" {
        $result = InModuleScope VcfEdgeAtScale { ConvertTo-YamlValue -Value "true" -IndentSize 2 -CurrentIndent 0 }
        $result | Should -Match '"'
    }
}


Describe "Get-YamlLine" {
    It "Parses a key-value pair" {
        $result = InModuleScope VcfEdgeAtScale { Get-YamlLine -Line "name: John" }
        $result.Type  | Should -Be "KeyValue"
        $result.Key   | Should -Be "name"
        $result.Value | Should -Be "John"
    }

    It "Parses an array item line" {
        $result = InModuleScope VcfEdgeAtScale { Get-YamlLine -Line "- item1" }
        $result.Type  | Should -Be "ArrayItem"
        $result.Key   | Should -Be ""
        $result.Value | Should -Be "item1"
    }

    It "Parses an object-start line (key with no value)" {
        $result = InModuleScope VcfEdgeAtScale { Get-YamlLine -Line "address:" }
        $result.Type | Should -Be "ObjectStart"
        $result.Key  | Should -Be "address"
    }

    It "Converts the value of a key-value pair to integer" {
        $result = InModuleScope VcfEdgeAtScale { Get-YamlLine -Line "port: 8080" }
        $result.Value | Should -Be 8080
        $result.Value | Should -BeOfType [long]
    }

    It "Converts boolean value in a key-value pair" {
        $result = InModuleScope VcfEdgeAtScale { Get-YamlLine -Line "enabled: true" }
        $result.Value | Should -Be $true
    }
}


Describe "ConvertFrom-YamlInternal" {
    It "Parses a flat key-value document into a hashtable" {
        # @() preserves the System.Object[1] returned by the function; without it PowerShell
        # unwraps the single-element array and $result becomes the hashtable directly.
        $result = @(InModuleScope VcfEdgeAtScale {
            ConvertFrom-YamlInternal -YamlLines @("name: Alice", "city: London")
        })
        $result[0]["name"] | Should -Be "Alice"
        $result[0]["city"] | Should -Be "London"
    }

    It "Converts an integer value to a typed [int]" {
        $result = @(InModuleScope VcfEdgeAtScale {
            ConvertFrom-YamlInternal -YamlLines @("port: 8080")
        })
        $result[0]["port"] | Should -Be 8080
        $result[0]["port"] | Should -BeOfType [long]
    }

    It "Parses a nested object via ObjectStart + child key-values" {
        $result = @(InModuleScope VcfEdgeAtScale {
            ConvertFrom-YamlInternal -YamlLines @("server:", "  host: vcenter.local", "  port: 443")
        })
        $result[0]["server"]["host"] | Should -Be "vcenter.local"
        $result[0]["server"]["port"] | Should -Be 443
    }

    It "Ignores comment lines (# ...)" {
        $result = @(InModuleScope VcfEdgeAtScale {
            ConvertFrom-YamlInternal -YamlLines @("# comment", "name: Bob")
        })
        $result[0]["name"] | Should -Be "Bob"
        $result[0].ContainsKey("# comment") | Should -Be $false
    }
}


Describe "ConvertTo-YamlInternal" {
    It "Serializes a single-key ordered dict to a key: value line" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            ConvertTo-YamlInternal -InputObject ([ordered]@{ name = "Alice" }) -IndentSize 2 -CurrentIndent 0
        }
        $result | Should -Contain "name: Alice"
    }

    It "Preserves insertion order of an ordered dictionary" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            ConvertTo-YamlInternal -InputObject ([ordered]@{ first = "a"; second = "b" }) -IndentSize 2 -CurrentIndent 0
        }
        $result[0] | Should -Be "first: a"
        $result[1] | Should -Be "second: b"
    }

    It "Serializes an array value as a YAML list with dash items" {
        $joined = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            (ConvertTo-YamlInternal -InputObject ([ordered]@{ skills = @("PowerShell", "Python") }) -IndentSize 2 -CurrentIndent 0) -join "`n"
        }
        $joined | Should -Match "skills:"
        $joined | Should -Match "- PowerShell"
        $joined | Should -Match "- Python"
    }

    It "Serializes a nested hashtable with increased indentation" {
        $joined = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            (ConvertTo-YamlInternal -InputObject ([ordered]@{ address = [ordered]@{ city = "London" } }) -IndentSize 2 -CurrentIndent 0) -join "`n"
        }
        $joined | Should -Match "address:"
        $joined | Should -Match "  city: London"
    }

    It "Serializes a boolean value as lowercase 'true'" {
        $joined = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            (ConvertTo-YamlInternal -InputObject ([ordered]@{ enabled = $true }) -IndentSize 2 -CurrentIndent 0) -join "`n"
        }
        $joined | Should -Match "enabled: true"
    }

    It "Serializes a null value as 'null'" {
        $joined = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            (ConvertTo-YamlInternal -InputObject ([ordered]@{ field = $null }) -IndentSize 2 -CurrentIndent 0) -join "`n"
        }
        $joined | Should -Match "field: null"
    }
}


Describe "Add-ObjectProperty" {
    It "Adds a simple key-value pair to a hashtable" {
        $obj = @{}
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Add-ObjectProperty -Object $args[0] -Path "name" -Value "John"
            $args[0]["name"]
        } | Should -Be "John"
    }

    It "Adds an integer value to a hashtable" {
        $obj = @{}
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Add-ObjectProperty -Object $args[0] -Path "age" -Value 42
            $args[0]["age"]
        } | Should -Be 42
    }

    It "Returns immediately for a whitespace-only path (no-op)" {
        $obj = @{ existing = "value" }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Add-ObjectProperty -Object $args[0] -Path "   " -Value "ignored"
            $args[0].Count
        } | Should -Be 1
    }

    It "Overwrites an existing key" {
        $obj = @{ name = "old" }
        InModuleScope VcfEdgeAtScale -ArgumentList $obj {
            Add-ObjectProperty -Object $args[0] -Path "name" -Value "new"
            $args[0]["name"]
        } | Should -Be "new"
    }
}

