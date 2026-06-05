# Copyright (c) 2026 Broadcom. All Rights Reserved.
# Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
# and/or its subsidiaries.
#
# =============================================================================
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
# =============================================================================
#
#region Private — YAML serialization and deserialization
function ConvertFrom-Yaml {

    <#
    .SYNOPSIS
        Converts YAML content to PowerShell objects using native PowerShell parsing.

    .DESCRIPTION
        The ConvertFrom-Yaml function parses YAML content and converts it into PowerShell hashtables
        and arrays. This is a native PowerShell implementation that doesn't require external dependencies.
        It returns an array containing hashtables representing the parsed YAML structure.

        Key features:
        - Native PowerShell implementation (no external dependencies)
        - Supports nested objects and arrays
        - Handles multi-document YAML (separated by ---)
        - Returns structured PowerShell objects for easy property access
        - Comprehensive error handling with detailed error messages

    .PARAMETER IndentSize
        Number of spaces per indentation level in the YAML source. Default is 2. Pass 4 when
        the input file uses 4-space indentation.

    .PARAMETER YamlContent
        The YAML content as a string to be parsed. This can be single or multi-document YAML.

    .EXAMPLE
        $yaml = @"
        name: John Doe
        age: 30
        address:
          street: 123 Main St
          city: New York
        "@
        $result = ConvertFrom-Yaml -YamlContent $yaml
        $result[0].name  # Returns: John Doe

    .OUTPUTS
        System.Array
        Returns an array containing hashtables representing the parsed YAML structure.

    .NOTES
        This function is designed to work with the internal ConvertFrom-YamlInternal function
        which handles the actual parsing logic. The function uses PowerShell's pipeline
        capabilities for efficient processing of YAML content.

    #>

    [CmdletBinding()]
    [OutputType([System.Object[]])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 8)] [Int]$IndentSize = 2,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [AllowEmptyString()] [String]$YamlContent
    )

    begin {
        $yamlLines = [System.Collections.Generic.List[String]]::new()
    }

    process {
        # Normalize to LF and split so the parser receives clean lines on all platforms.
        $lines = $YamlContent -split "`n"
        foreach ($line in $lines) {
            $yamlLines.Add($line.TrimEnd("`r"))
        }
    }

    end {
        try {
            $validLines = [System.Collections.Generic.List[String]]::new()
            foreach ($line in $yamlLines) {
                if ($null -ne $line -and $line.Trim() -ne "") {
                    $validLines.Add($line)
                }
            }

            if ($validLines.Count -eq 0) {
                Write-LogMessage -Type DEBUG -Message "YAML content contains no valid lines. Returning empty array."
                return @()
            }

            return ConvertFrom-YamlInternal -IndentSize $IndentSize -YamlLines $validLines
        } catch {
            return Write-ErrorAndReturn -ErrorMessage "YAML parsing failed: $($_.Exception.Message)" -ErrorCode "ERR_YAML_PARSE"
        }
    }
}
function ConvertTo-Yaml {

    <#
    .SYNOPSIS
        Converts a PowerShell object to YAML format.

    .DESCRIPTION
        The ConvertTo-Yaml function converts PowerShell objects (hashtables, arrays, PSCustomObjects)
        into YAML format. It supports nested objects, arrays, and various data types including
        strings, numbers, booleans, and null values.

    .PARAMETER InputObject
        The PowerShell object to be converted to YAML format. This can be a hashtable,
        PSCustomObject, array, or any other PowerShell object.

    .PARAMETER IndentSize
        The number of spaces to use for indentation in the YAML output. Default is 2.

    .EXAMPLE
        $object = @{
            name = "John Doe"
            age = 30
            skills = @("PowerShell", "Python")
            address = @{
                street = "123 Main St"
                city = "New York"
            }
        }
        ConvertTo-Yaml -InputObject $object

    .EXAMPLE
        $array = @("item1", "item2", "item3")
        ConvertTo-Yaml -InputObject $array -IndentSize 4

    .OUTPUTS
        System.String
        Returns the YAML representation of the input object.

    .NOTES
        Delegates recursive serialization to ConvertTo-YamlInternal.

    #>


    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter()] [ValidateRange(1, [Int]::MaxValue)] [Int]$IndentSize = 2,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [Object]$InputObject
    )

    begin {
        Write-LogMessage -Type DEBUG -Message "Entered ConvertTo-Yaml function..."

        $yamlContent = [System.Collections.Generic.List[String]]::new()
    }

    process {
        $lines = ConvertTo-YamlInternal -InputObject $InputObject -IndentSize $IndentSize -CurrentIndent 0
        foreach ($line in $lines) {
            $yamlContent.Add($line)
        }
    }

    end {
        return $yamlContent -join "`n"
    }
}
function ConvertFrom-YamlInternal {

    <#
    .SYNOPSIS
        Internal function that parses YAML lines into a PowerShell array.

    .DESCRIPTION
        The ConvertFrom-YamlInternal function is an internal helper function that processes
        an array of YAML lines and converts them into a PowerShell array containing a hashtable. It handles
        nested objects, arrays, and various YAML structures using a stack-based approach
        to maintain proper indentation levels.

    .PARAMETER IndentSize
        Number of spaces per indentation level in the YAML source. Default is 2. Must match the
        indentation used in the file — 4-space YAML requires IndentSize = 4. Mismatch causes
        incorrect nesting depth resolution.

    .PARAMETER YamlLines
        An array of strings representing the YAML content, where each string is a line
        from the YAML document.

    .EXAMPLE
        $yamlLines = @(
            "name: John Doe",
            "age: 30",
            "address:",
            "  street: 123 Main St",
            "  city: New York"
        )
        $result = ConvertFrom-YamlInternal -YamlLines $yamlLines

    .OUTPUTS
        System.Array
        Returns an array containing a hashtable representing the parsed YAML structure.

    .NOTES
        This is an internal function used by ConvertFrom-Yaml. It should not be called
        directly in most scenarios.
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, 8)] [Int]$IndentSize = 2,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$YamlLines
    )

    $result = @{}
    $stack = [System.Collections.Generic.List[Hashtable]]::new()
    $currentObject = $result
    $lineNumber = 0

    foreach ($line in $YamlLines) {
        $lineNumber++
        $trimmedLine = $line.TrimEnd()

        # Skip empty lines and comments.

        if ([String]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith('#')) {
            continue
        }

        $currentIndentLevel = ($line.Length - $line.TrimStart().Length) / $IndentSize

        while ($stack.Count -gt 0) {
            $lastItem = $stack[$stack.Count - 1]
            if ($lastItem.IndentLevel -ge $currentIndentLevel) {
                $stack.RemoveAt($stack.Count - 1)
            } else {
                break
            }
        }

        $parsedItem = Get-YamlLine -Line $trimmedLine.TrimStart()

        if ($null -ne $parsedItem) {
            if ($stack.Count -eq 0) {
                $currentObject = $result
            } else {
                $currentObject = $stack[$stack.Count - 1].Object
            }

            if ($parsedItem.Type -eq "KeyValue") {
                Add-ObjectProperty -Object $currentObject -Path $parsedItem.Key -Value $parsedItem.Value
            }
            elseif ($parsedItem.Type -eq "ArrayItem") {
                if (-not $currentObject.ContainsKey($parsedItem.Key)) {
                    $currentObject[$parsedItem.Key] = [System.Collections.Generic.List[Object]]::new()
                }
                $currentObject[$parsedItem.Key].Add($parsedItem.Value)
            }
            elseif ($parsedItem.Type -eq "ObjectStart") {
                $newObject = @{}
                Add-ObjectProperty -Object $currentObject -Path $parsedItem.Key -Value $newObject
                $stack.Add(@{
                    Object = $newObject
                    IndentLevel = $currentIndentLevel
                })
            }
            elseif ($parsedItem.Type -eq "ArrayStart") {
                $newArray = [System.Collections.Generic.List[Object]]::new()
                Add-ObjectProperty -Object $currentObject -Path $parsedItem.Key -Value $newArray
                $stack.Add(@{
                    Object = $newArray
                    IndentLevel = $currentIndentLevel
                    IsArray = $true
                })
            }
        }
    }

    return [Object[]]@($result)
}
function Get-YamlLine {

    <#
    .SYNOPSIS
        Parses a single YAML line and returns a structured object representing its content.

    .DESCRIPTION
        The Get-YamlLine function analyzes a single YAML line and determines its type
        (key-value pair, array item, object start, or array start). It returns a hashtable
        with type information and parsed values that can be used by the YAML parser.

    .PARAMETER Line
        The YAML line to be parsed. Should be trimmed of leading/trailing whitespace.

    .EXAMPLE
        $result = Get-YamlLine -Line "name: John Doe"
        # Returns: @{ Type = "KeyValue"; Key = "name"; Value = "John Doe" }

    .EXAMPLE
        $result = Get-YamlLine -Line "- item1"
        # Returns: @{ Type = "ArrayItem"; Key = ""; Value = "item1" }

    .EXAMPLE
        $result = Get-YamlLine -Line "address:"
        # Returns: @{ Type = "ObjectStart"; Key = "address"; Value = $null }

    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with the following possible properties:
        - Type: "KeyValue", "ArrayItem", "ObjectStart", or "ArrayStart"
        - Key: The key name (empty for array items)
        - Value: The parsed value (null for object/array starts)

    .NOTES
        This is an internal function used by ConvertFrom-YamlInternal. It should not be
        called directly in most scenarios.

        Parsing limitation: YAML values must be separated from their key by ": " (colon then space).
        The form "key:value" (no space) is treated as an ObjectStart (nested object) rather than a
        KeyValue pair. Hand-authored YAML files should always use ": " separators. All YAML produced
        by ConvertTo-Yaml in this module uses proper spacing.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Line
    )

    if ($Line.StartsWith('- ')) {
        $value = $Line.Substring(2).Trim()
        return @{
            Type = "ArrayItem"
            Key = ""
            Value = ConvertFrom-YamlValue -Value $value
        }
    }

    if ($Line.Contains(':')) {
        $colonIndex = $Line.IndexOf(':')
        $key = $Line.Substring(0, $colonIndex).Trim()
        $value = $Line.Substring($colonIndex + 1).Trim()

        if ([String]::IsNullOrWhiteSpace($value)) {
            return @{
                Type = "ObjectStart"
                Key = $key
                Value = $null
            }
        }
        elseif ($value -eq '[]') {
            return @{
                Type = "ArrayStart"
                Key = $key
                Value = $null
            }
        }
        else {
            return @{
                Type = "KeyValue"
                Key = $key
                Value = ConvertFrom-YamlValue -Value $value
            }
        }
    }

    return $null
}
function ConvertFrom-YamlValue {

    <#
    .SYNOPSIS
        Converts a YAML value string to its appropriate PowerShell data type.

    .DESCRIPTION
        The ConvertFrom-YamlValue function takes a YAML value string and converts it to
        the appropriate PowerShell data type. It handles strings, numbers, booleans, null
        values, and removes quotes when appropriate.

    .PARAMETER Value
        The YAML value string to be converted to a PowerShell object.

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "John Doe"
        # Returns: "John Doe" (string)

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "30"
        # Returns: 30 (integer)

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "true"
        # Returns: $true (boolean)

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "null"
        # Returns: $null

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value '"quoted string"'
        # Returns: "quoted string" (unquoted string)

    .OUTPUTS
        System.Object
        Returns the converted value as the appropriate PowerShell data type:
        - String (unquoted)
        - Int64 (for integer strings — Int64 avoids Int32 overflow on large values such as Unix timestamps)
        - Double (for decimal strings)
        - Boolean (for true/false values)
        - Null (for null/empty values)

    .NOTES
        This is an internal function used by Get-YamlLine. It should not be called
        directly in most scenarios.
    #>

    [CmdletBinding()]
    [OutputType([Int64], [Double], [Bool], [String])]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [AllowNull()] [String]$Value
    )

    if ([String]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    if (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or
        ($Value.StartsWith("'") -and $Value.EndsWith("'"))) {
        return $Value.Substring(1, $Value.Length - 2)
    }

    switch -Regex ($Value) {
        '^-?\d+$' { return [Int64]$Value }
        '^-?\d+\.\d+$' { return [Double]$Value }
    }

    if ($Value -ieq 'true')  { return $true }
    if ($Value -ieq 'false') { return $false }
    if ($Value -ieq 'null' -or $Value -eq '~') { return $null }

    return $Value
}
function Add-ObjectProperty {

    <#
    .SYNOPSIS
        Adds a property to a hashtable object with the specified key and value.

    .DESCRIPTION
        The Add-ObjectProperty function adds a property to a hashtable object using the
        specified key (path) and value. This is a simple helper function used internally
        by the YAML parser to set properties on objects during parsing.

    .PARAMETER Object
        The hashtable object to which the property will be added.

    .PARAMETER Path
        The key name for the property to be added to the object.

    .PARAMETER Value
        The value to be assigned to the property.

    .EXAMPLE
        $obj = @{}
        Add-ObjectProperty -Object $obj -Path "name" -Value "John Doe"
        # $obj now contains: @{ name = "John Doe" }

    .EXAMPLE
        $obj = @{}
        Add-ObjectProperty -Object $obj -Path "age" -Value 30
        # $obj now contains: @{ age = 30 }

    .EXAMPLE
        $obj = @{}
        Add-ObjectProperty -Object $obj -Path "address" -Value @{ street = "123 Main St" }
        # $obj now contains: @{ address = @{ street = "123 Main St" } }

    .OUTPUTS
        None
        This function modifies the input object in place and does not return a value.

    .NOTES
        This is an internal function used by ConvertFrom-YamlInternal. It should not be
        called directly in most scenarios.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Object,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$Value
    )

    if ([String]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $Object[$Path] = $Value
}
function ConvertTo-YamlInternal {

    <#
    .SYNOPSIS
        Internal helper function that recursively converts PowerShell objects to YAML format with proper indentation.

    .DESCRIPTION
        The ConvertTo-YamlInternal function is an internal helper that performs recursive conversion of PowerShell
        objects (hashtables, PSCustomObjects, arrays, and primitive types) into properly formatted YAML lines
        with appropriate indentation. This function is the core engine behind the ConvertTo-Yaml cmdlet and
        handles the complex logic of traversing nested object structures while maintaining proper YAML formatting.

        The function processes different object types as follows:
        - Hashtables and PSCustomObjects: Converts properties to key-value pairs with nested indentation
        - Arrays and ArrayLists: Converts items to YAML list format with dash prefixes
        - Nested objects: Recursively processes with increased indentation levels
        - Primitive values: Delegates to ConvertTo-YamlValue for proper type conversion

        The function maintains proper YAML indentation by calculating spaces based on the current nesting level
        and the specified indent size, ensuring the output conforms to YAML specification standards.

    .PARAMETER InputObject
        The PowerShell object to be converted to YAML format. This can be any type of object including:
        - Hashtables containing key-value pairs
        - PSCustomObjects with properties
        - Arrays or ArrayLists containing multiple items
        - Primitive types (strings, numbers, booleans)
        - Nested combinations of the above types

    .PARAMETER IndentSize
        The number of spaces to use for each level of indentation in the YAML output.
        This parameter controls the visual formatting and nesting structure of the generated YAML.
        Common values are 2 or 4 spaces per indentation level to match YAML conventions.

    .PARAMETER CurrentIndent
        The current indentation level for the object being processed. This parameter is used
        internally during recursive calls to maintain proper nesting depth. The actual number
        of spaces used for indentation is calculated as (CurrentIndent * IndentSize).
        This parameter starts at 0 for root-level objects and increments for each nesting level.

    .EXAMPLE
        # This function is typically called internally by ConvertTo-Yaml.

        $hashtable = @{
            name = "John Doe"
            age = 30
            skills = @("PowerShell", "Python")
            address = @{
                street = "123 Main St"
                city = "New York"
            }
        }
        $yamlLines = ConvertTo-YamlInternal -InputObject $hashtable -IndentSize 2 -CurrentIndent 0

        This example would produce YAML lines with proper indentation:
        name: John Doe
        age: 30
        skills:
          - PowerShell
          - Python
        address:
          street: 123 Main St
          city: New York

    .EXAMPLE
        # Processing an array at indentation level 1.

        $array = @("item1", "item2", "item3")
        $yamlLines = ConvertTo-YamlInternal -InputObject $array -IndentSize 2 -CurrentIndent 1

        This would produce:
          - item1
          - item2
          - item3

    .OUTPUTS
        System.Collections.Generic.List[String]
        Returns a List[String] where each string represents a line of YAML output
        with appropriate indentation. The caller can join these lines with newline characters to
        create the final YAML document.

    .NOTES
        This is an internal function used by ConvertTo-Yaml and should not be called directly.
        IDictionary types (Hashtable, OrderedDictionary) are iterated via GetEnumerator()/Keys
        to avoid PSObject.Properties returning type members instead of dictionary entries.

    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[String]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(0, [Int]::MaxValue)] [Int]$CurrentIndent,
        [Parameter(Mandatory = $true)] [ValidateRange(1, [Int]::MaxValue)] [Int]$IndentSize,
        [Parameter(Mandatory = $true)] [AllowNull()] [Object]$InputObject
    )

    $yamlLines = [System.Collections.Generic.List[String]]::new()
    $indent = " " * ($CurrentIndent * $IndentSize)

    # IDictionary (Hashtable, OrderedDictionary) must be enumerated via GetEnumerator() —
    # PSObject.Properties on these types exposes the type's own members (Count, Keys, Values…)
    # rather than the dictionary entries.
    if ($InputObject -is [System.Collections.IDictionary] -or $InputObject -is [PSCustomObject]) {
        $isDict = $InputObject -is [System.Collections.IDictionary]
        $keys = if ($isDict) { @($InputObject.Keys) } else { $InputObject.PSObject.Properties.Name }
        foreach ($key in $keys) {
            $value = if ($isDict) { $InputObject[$key] } else { $InputObject.$key }

            if ($value -is [array] -or $value -is [System.Collections.IList]) {
                $yamlLines.Add("$indent$key`:")
                foreach ($item in $value) {
                    $yamlLines.Add("$indent  - $(ConvertTo-YamlValue -Value $item -IndentSize $IndentSize -CurrentIndent ($CurrentIndent + 1))")
                }
            }
            elseif ($value -is [System.Collections.IDictionary] -or $value -is [PSCustomObject]) {
                $yamlLines.Add("$indent$key`:")
                $subLines = ConvertTo-YamlInternal -InputObject $value -IndentSize $IndentSize -CurrentIndent ($CurrentIndent + 1)
                foreach ($line in $subLines) {
                    $yamlLines.Add($line)
                }
            }
            else {
                $yamlLines.Add("$indent$key`: $(ConvertTo-YamlValue -Value $value -IndentSize $IndentSize -CurrentIndent $CurrentIndent)")
            }
        }
    }
    elseif ($InputObject -is [array] -or $InputObject -is [System.Collections.IList]) {
        foreach ($item in $InputObject) {
            $yamlLines.Add("$indent- $(ConvertTo-YamlValue -Value $item -IndentSize $IndentSize -CurrentIndent $CurrentIndent)")
        }
    }
    else {
        $yamlLines.Add("$indent$(ConvertTo-YamlValue -Value $InputObject -IndentSize $IndentSize -CurrentIndent $CurrentIndent)")
    }

    return $yamlLines
}
function ConvertTo-YamlValue {

    <#
    .SYNOPSIS
        Converts a PowerShell object to its YAML string representation.

    .DESCRIPTION
        The ConvertTo-YamlValue function converts a PowerShell object to its appropriate
        YAML string representation. It handles various data types including strings,
        numbers, booleans, null values, hashtables, arrays, and complex objects.

    .PARAMETER Value
        The PowerShell object to be converted to YAML format.

    .PARAMETER IndentSize
        The number of spaces to use for indentation in nested structures.

    .PARAMETER CurrentIndent
        The current indentation level for proper formatting.

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value "Hello World" -IndentSize 2 -CurrentIndent 0
        # Returns: "Hello World"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value 42 -IndentSize 2 -CurrentIndent 0
        # Returns: "42"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value $true -IndentSize 2 -CurrentIndent 0
        # Returns: "true"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value $null -IndentSize 2 -CurrentIndent 0
        # Returns: "null"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value @("item1", "item2") -IndentSize 2 -CurrentIndent 0
        # Returns: Multi-line YAML array representation.


    .OUTPUTS
        System.String
        Returns the YAML string representation of the input object.

    .NOTES
        This is an internal function used by ConvertTo-YamlInternal. It should not be
        called directly in most scenarios.

    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateRange(0, [Int]::MaxValue)] [Int]$CurrentIndent,
        [Parameter(Mandatory = $true)] [ValidateRange(1, [Int]::MaxValue)] [Int]$IndentSize,
        [Parameter(Mandatory = $false)] [AllowNull()] [Object]$Value
    )

    if ($null -eq $Value) {
        return "null"
    }
    elseif ($Value -is [bool]) {
        return $Value.ToString().ToLower()
    }
    elseif ($Value -is [string]) {
        if ($Value.Contains(':') -or $Value.Contains('"') -or $Value.Contains("'") -or
            $Value.StartsWith(' ') -or $Value.EndsWith(' ') -or
            $Value -match '^[0-9]' -or $Value -match '^(true|false|null)$') {
            return "`"$($Value.Replace('"', '\"'))`""
        }
        return $Value
    }
    elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value.ToString()
    }
    elseif ($Value -is [System.Collections.IDictionary] -or $Value -is [PSCustomObject]) {
        $subYaml = ConvertTo-YamlInternal -InputObject $Value -IndentSize $IndentSize -CurrentIndent ($CurrentIndent + 1)
        return "`n$subYaml"
    }
    elseif ($Value -is [array] -or $Value -is [System.Collections.IList]) {
        $arrayItems = [System.Collections.Generic.List[String]]::new()
        foreach ($item in $Value) {
            $itemValue = ConvertTo-YamlValue -Value $item -IndentSize $IndentSize -CurrentIndent $CurrentIndent
            $arrayItems.Add($itemValue)
        }
        return "`n$($arrayItems -join "`n")"
    }
    else {
        return $Value.ToString()
    }
}
function ConvertTo-YamlLiteralBlock {

    <#
        .SYNOPSIS
        Converts a file's contents into an indented YAML literal block scalar string.

        .DESCRIPTION
        Reads the file at FilePath, normalizes line endings to LF, trims trailing whitespace,
        and returns a YAML literal block scalar in the form:

          <KeyIndent><KeyName>: |
          <KeyIndent>  <line 1>
          <KeyIndent>  <line 2>
          ...

        This format is suitable for embedding PEM certificate and private key content into a YAML
        configuration file, as required by the Harbor tlsCertificate block.

        .PARAMETER FilePath
        Full path to the file whose contents will form the YAML literal block value.

        .PARAMETER KeyIndentSpaces
        Number of leading spaces for the key line. Content lines receive two additional spaces of
        indentation (e.g., 2 spaces for the key means 4 spaces for each content line).

        .PARAMETER KeyName
        The YAML key name to emit (e.g., "tls.crt", "tls.key", "ca.crt").

        .OUTPUTS
        [String] The YAML literal block scalar string, including a trailing newline.

        .EXAMPLE
        $block = ConvertTo-YamlLiteralBlock -FilePath "/etc/ssl/tls.crt" -KeyName "tls.crt" -KeyIndentSpaces 2

        Returns a string such as:
          tls.crt: |
            -----BEGIN CERTIFICATE-----
            MIIByTCCAW6g...
            -----END CERTIFICATE-----
    #>


    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath,
        [Parameter(Mandatory = $true)] [ValidateRange(0, 20)] [Int]$KeyIndentSpaces,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$KeyName
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw [VcfDeploymentException]::new("ConvertTo-YamlLiteralBlock: File not found: '$FilePath'")
    }
    $fileContent = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
    # Defensive: -Raw should always return a single string for a single literal path.
    # Guard against unexpected multi-value returns (e.g., some PowerShell 5.1 edge cases).
    if ($fileContent -is [System.Array]) { $fileContent = $fileContent -join "" }
    $fileContent = ($fileContent -replace '\r\n', "`n").TrimEnd()
    $keyIndent = " " * $KeyIndentSpaces
    $contentIndent = " " * ($KeyIndentSpaces + 2)
    $lines = $fileContent -split '\n'
    $indentedLines = $lines | ForEach-Object { $contentIndent + $_ }
    return "$keyIndent${KeyName}: |`n$($indentedLines -join "`n")`n"
}
function ConvertTo-YamlSingleQuotedScalar {

    <#
        .SYNOPSIS
        Wraps a string value in YAML single quotes with proper escaping.

        .DESCRIPTION
        Returns a YAML-safe single-quoted scalar for the given string. Single quoting is the
        safest way to inject user-controlled values into YAML: no indicator characters
        ({, [, >, |, *, &, !, %, @, `) can be misinterpreted, and colons followed by a
        space are inert inside single quotes. The only character that requires escaping in a
        YAML single-quoted scalar is the single quote itself, which is represented as ''.

        .PARAMETER Value
        The plain-text string to encode.

        .OUTPUTS
        [String] The value wrapped in YAML single quotes, with any embedded single quotes doubled.

        .EXAMPLE
        ConvertTo-YamlSingleQuotedScalar -Value "pass'word{}"
        Returns: 'pass''word{}'
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [ValidateNotNull()] [String]$Value
    )

    return "'$($Value.Replace("'", "''"))'"
}
