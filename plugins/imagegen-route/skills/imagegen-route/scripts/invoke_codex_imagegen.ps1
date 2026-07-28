#requires -Version 7.0

param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep credentials out of diagnostics even if a child process prints them.
$script:Redactions = [System.Collections.Generic.List[string]]::new()

function Add-Redaction {
    param([AllowNull()][string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value.Length -ge 4) {
        [void]$script:Redactions.Add($Value)
    }
}

function Protect-Text {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    $safe = $Text
    foreach ($secret in $script:Redactions) {
        $safe = $safe.Replace($secret, '[REDACTED]')
    }
    $safe = [regex]::Replace(
        $safe,
        '(?i)(authorization\s*:\s*bearer\s+)[^\s\r\n]+',
        '$1[REDACTED]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)data:[^;\s]+;base64,[A-Za-z0-9+/=]{128,}',
        'data:[REDACTED]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?m)(?<![A-Za-z0-9])[A-Za-z0-9+/]{256,}={0,2}(?![A-Za-z0-9+/=])',
        '[BASE64_REDACTED]'
    )
    if ($safe.Length -gt 20000) {
        $safe = $safe.Substring(0, 20000) + "`n[OUTPUT_TRUNCATED]"
    }
    return $safe
}

function Stop-Wrapper {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Code = 64
    )

    $exception = [System.Exception]::new($Message)
    $exception.Data['ExitCode'] = $Code
    throw $exception
}

function Assert-RegularFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        Stop-Wrapper "Required file is unavailable." 66
    }

    if ($item.PSIsContainer) {
        Stop-Wrapper "Expected a file, but received a directory." 66
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Wrapper "Refusing to read a reparse-point credential or configuration file." 77
    }
}

function Get-FileFingerprint {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-RegularFile $Path
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        Stop-Wrapper "Could not fingerprint a configuration file." 66
    }
}

function Resolve-CodexHome {
    param([AllowNull()][string]$Override)

    $raw = $Override
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = [System.IO.Path]::Combine(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile),
            '.codex'
        )
    }

    try {
        $full = [System.IO.Path]::GetFullPath($raw)
    }
    catch {
        Stop-Wrapper "CODEX_HOME is not a valid path." 64
    }

    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Stop-Wrapper "CODEX_HOME does not exist." 66
    }
    return $full
}

function Parse-WrapperArgs {
    param([object[]]$RawArgs)

    $forward = [System.Collections.Generic.List[string]]::new()
    $codexHome = $null
    $python = $null
    $checkRoute = $false
    $index = 0

    # Wrapper-only options are accepted only before the imagegen command. This
    # preserves prompt values and every argument after the first CLI token.
    while ($index -lt $RawArgs.Count) {
        $token = [string]$RawArgs[$index]
        if ($token -eq '--check-route') {
            $checkRoute = $true
            $index++
            continue
        }
        if ($token -like '--codex-home=*') {
            $codexHome = $token.Substring(13)
            if ([string]::IsNullOrWhiteSpace($codexHome)) {
                Stop-Wrapper "--codex-home requires a value." 64
            }
            $index++
            continue
        }
        if ($token -eq '--codex-home') {
            if ($index + 1 -ge $RawArgs.Count) {
                Stop-Wrapper "--codex-home requires a value." 64
            }
            $codexHome = [string]$RawArgs[$index + 1]
            if ([string]::IsNullOrWhiteSpace($codexHome)) {
                Stop-Wrapper "--codex-home requires a value." 64
            }
            $index += 2
            continue
        }
        if ($token -like '--python=*') {
            $python = $token.Substring(9)
            if ([string]::IsNullOrWhiteSpace($python)) {
                Stop-Wrapper "--python requires a value." 64
            }
            $index++
            continue
        }
        if ($token -eq '--python') {
            if ($index + 1 -ge $RawArgs.Count) {
                Stop-Wrapper "--python requires a value." 64
            }
            $python = [string]$RawArgs[$index + 1]
            if ([string]::IsNullOrWhiteSpace($python)) {
                Stop-Wrapper "--python requires a value." 64
            }
            $index += 2
            continue
        }
        break
    }

    while ($index -lt $RawArgs.Count) {
        [void]$forward.Add([string]$RawArgs[$index])
        $index++
    }

    return [pscustomobject]@{
        CodexHome = $codexHome
        Python = $python
        CheckRoute = $checkRoute
        Forward = $forward
    }
}

function Resolve-PythonInvocation {
    param([AllowNull()][string]$Override)

    $candidate = $Override
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $env:CODEX_IMAGEGEN_PYTHON
    }

    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $command = Get-Command -Name $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $command = Get-Item -LiteralPath $candidate -Force
        }
        if ($null -eq $command) {
            Stop-Wrapper "The requested Python interpreter was not found." 69
        }
        return [pscustomobject]@{
            FileName = if ($command.Path) { $command.Path } else { $command.FullName }
            Prefix = [string[]]@()
        }
    }

    $pythonCommand = Get-Command -Name 'python.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $pythonCommand) {
        $pythonCommand = Get-Command -Name 'python' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -ne $pythonCommand) {
        return [pscustomobject]@{
            FileName = if ($pythonCommand.Path) { $pythonCommand.Path } else { $pythonCommand.Source }
            Prefix = [string[]]@()
        }
    }

    $launcher = Get-Command -Name 'py.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $launcher) {
        return [pscustomobject]@{
            FileName = if ($launcher.Path) { $launcher.Path } else { $launcher.Source }
            Prefix = [string[]]@('-3')
        }
    }

    Stop-Wrapper "A Python 3.11+ interpreter is required." 69
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [AllowNull()][hashtable]$Environment
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = (Get-Location).Path

    # Always remove inherited OpenAI routing variables before applying the
    # selected values. The parent PowerShell process is never modified.
    [void]$startInfo.Environment.Remove('OPENAI_API_KEY')
    [void]$startInfo.Environment.Remove('OPENAI_BASE_URL')
    if ($null -ne $Environment) {
        foreach ($name in $Environment.Keys) {
            $value = [string]$Environment[$name]
            $startInfo.Environment[$name] = $value
        }
    }
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            Stop-Wrapper "Could not start the child process." 70
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Read-ProviderRoute {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)]$Python
    )

    $before = Get-FileFingerprint $ConfigPath
    $reader = @'
import json
import sys
import tomllib

with open(sys.argv[-1], "rb") as handle:
    config = tomllib.load(handle)

provider_name = config.get("model_provider")
providers = config.get("model_providers")
if not isinstance(provider_name, str) or not provider_name.strip():
    raise ValueError("missing model_provider")
if not isinstance(providers, dict):
    raise ValueError("missing model_providers")
provider = providers.get(provider_name)
if not isinstance(provider, dict):
    raise ValueError("missing selected provider table")
base_url = provider.get("base_url")
if not isinstance(base_url, str) or not base_url.strip():
    raise ValueError("missing provider base_url")
wire_api = provider.get("wire_api", "")
if not isinstance(wire_api, str):
    wire_api = ""
print(json.dumps({
    "provider": provider_name,
    "base_url": base_url,
    "wire_api": wire_api,
}, ensure_ascii=True, separators=(",", ":")))
'@

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($prefix in $Python.Prefix) {
        [void]$arguments.Add($prefix)
    }
    [void]$arguments.Add('-c')
    [void]$arguments.Add($reader)
    [void]$arguments.Add('--')
    [void]$arguments.Add($ConfigPath)
    $result = Invoke-CapturedProcess -FileName $Python.FileName -Arguments $arguments.ToArray() -Environment @{}
    if ($result.ExitCode -ne 0) {
        Stop-Wrapper "Could not parse the active Codex TOML configuration." 65
    }

    $after = Get-FileFingerprint $ConfigPath
    if ($before -ne $after) {
        Stop-Wrapper "Codex configuration changed while it was being read; retry." 75
    }

    try {
        $route = $result.StdOut.Trim() | ConvertFrom-Json -ErrorAction Stop
        $providerName = [string]$route.provider
        $rawBaseUrl = [string]$route.base_url
        $wireApi = [string]$route.wire_api
    }
    catch {
        Stop-Wrapper "The active Codex provider route is invalid." 65
    }

    if ([string]::IsNullOrWhiteSpace($providerName) -or [string]::IsNullOrWhiteSpace($rawBaseUrl)) {
        Stop-Wrapper "The active Codex provider route is incomplete." 65
    }
    try {
        $uri = [System.Uri]::new($rawBaseUrl, [System.UriKind]::Absolute)
    }
    catch {
        Stop-Wrapper "The active provider base_url is not an absolute URL." 65
    }
    if ($uri.Scheme -ne 'https') {
        Stop-Wrapper "Refusing a non-HTTPS image API endpoint." 65
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        Stop-Wrapper "The provider base_url must not contain credentials, query, or fragment data." 65
    }
    if ([string]::Equals($uri.Host, 'api.openai.com', [StringComparison]::OrdinalIgnoreCase) -or
        $providerName -in @('openai', 'default')) {
        Stop-Wrapper "Refusing to fall back to the public OpenAI endpoint; configure the custom provider explicitly." 65
    }

    return [pscustomobject]@{
        Provider = $providerName
        BaseUrl = $rawBaseUrl.TrimEnd('/') + '/'
        WireApi = $wireApi
    }
}

function Read-AuthKey {
    param([Parameter(Mandatory = $true)][string]$AuthPath)

    $before = Get-FileFingerprint $AuthPath
    try {
        $text = [System.IO.File]::ReadAllText($AuthPath)
        $auth = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        Stop-Wrapper "Could not read the Codex auth store." 67
    }

    $after = Get-FileFingerprint $AuthPath
    if ($before -ne $after) {
        Stop-Wrapper "Codex auth changed while it was being read; retry." 75
    }
    if ($auth -isnot [System.Collections.IDictionary] -or
        -not $auth.Contains('OPENAI_API_KEY')) {
        Stop-Wrapper "Codex auth.json does not contain an OPENAI_API_KEY string." 67
    }

    $key = $auth['OPENAI_API_KEY']
    if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or $key.Length -lt 8) {
        Stop-Wrapper "Codex auth.json contains a missing or invalid OPENAI_API_KEY." 67
    }
    if ($key.IndexOf([char]0) -ge 0 -or $key.Contains("`r") -or $key.Contains("`n")) {
        Stop-Wrapper "Codex auth.json contains an invalid OPENAI_API_KEY value." 67
    }
    Add-Redaction $key
    return [string]$key
}

function Get-ImageGenScript {
    param([Parameter(Mandatory = $true)][string]$CodexHome)

    $path = Join-Path $CodexHome 'skills\.system\imagegen\scripts\image_gen.py'
    Assert-RegularFile $path
    return $path
}

$exitCode = 1
try {
    $parsed = Parse-WrapperArgs -RawArgs @($args)
    $codexHome = Resolve-CodexHome $parsed.CodexHome
    $python = Resolve-PythonInvocation $parsed.Python
    $configPath = Join-Path $codexHome 'config.toml'
    $authPath = Join-Path $codexHome 'auth.json'

    Assert-RegularFile $configPath
    Assert-RegularFile $authPath
    $configSnapshot = Get-FileFingerprint $configPath
    $authSnapshot = Get-FileFingerprint $authPath
    $route = Read-ProviderRoute -ConfigPath $configPath -Python $python
    $apiKey = Read-AuthKey -AuthPath $authPath

    # Re-check both files after both values have been collected. This avoids
    # combining a route from one snapshot with credentials from another.
    if ($configSnapshot -ne (Get-FileFingerprint $configPath) -or
        $authSnapshot -ne (Get-FileFingerprint $authPath)) {
        Stop-Wrapper "Codex configuration changed during validation; retry." 75
    }

    if ($parsed.CheckRoute) {
        [Console]::Out.WriteLine(
            "imagegen route validated for provider '$($route.Provider)' (HTTPS endpoint)."
        )
        $exitCode = 0
        exit $exitCode
    }

    if ($parsed.Forward.Count -eq 0) {
        Stop-Wrapper "Provide image_gen.py arguments, or use --check-route." 64
    }
    if ($parsed.Forward[0] -notin @('generate', 'edit', 'generate-batch', '--help', '-h')) {
        Stop-Wrapper "The wrapper only forwards image_gen.py generate, edit, or generate-batch commands." 64
    }

    $scriptPath = Get-ImageGenScript $codexHome
    $childArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($prefix in $python.Prefix) {
        [void]$childArguments.Add($prefix)
    }
    [void]$childArguments.Add($scriptPath)
    foreach ($argument in $parsed.Forward) {
        [void]$childArguments.Add($argument)
    }

    $childEnvironment = @{
        OPENAI_API_KEY = $apiKey
        OPENAI_BASE_URL = $route.BaseUrl
    }
    $child = Invoke-CapturedProcess -FileName $python.FileName -Arguments $childArguments.ToArray() -Environment $childEnvironment
    $safeStdOut = Protect-Text $child.StdOut
    $safeStdErr = Protect-Text $child.StdErr
    if (-not [string]::IsNullOrEmpty($safeStdOut)) {
        [Console]::Out.Write($safeStdOut)
    }
    if (-not [string]::IsNullOrEmpty($safeStdErr)) {
        [Console]::Error.Write($safeStdErr)
    }
    $exitCode = [int]$child.ExitCode
    exit $exitCode
}
catch {
    if ($_.Exception.Data.Contains('ExitCode')) {
        $exitCode = [int]$_.Exception.Data['ExitCode']
    }
    else {
        $exitCode = 1
    }
    [Console]::Error.WriteLine("invoke_codex_imagegen: $(Protect-Text $_.Exception.Message)")
    exit $exitCode
}
