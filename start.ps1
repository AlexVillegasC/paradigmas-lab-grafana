[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('local', 'development', 'help')]
    [string]$Environment = 'local',

    [Parameter(Position = 1)]
    [ValidateSet('up', 'down', 'stop', 'restart', 'build', 'logs', 'ps', 'help')]
    [string]$Action = 'up',

    [string[]]$Services = @(),

    [switch]$NoBuild,
    [switch]$NoDeps,
    [switch]$Foreground,
    [switch]$Volumes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Show-Usage {
    @'
Independent Docker Compose provisioning for the Libraries stack.

Usage:
  .\start.ps1 [environment] [action] [options]

Environments:
  local          API + frontend + local Postgres (--profile local)
  development    API + frontend against Supabase (.env.development)

Actions:
  up       Create and start the stack (default)
  down     Stop and remove containers and networks
  stop     Stop running containers
  restart  Restart containers
  build    Build service images
  logs     Follow logs
  ps       List project containers

Options:
  -Services <name[]>  Provision only these services: postgres, api, frontend
  -NoBuild            Skip image builds on up
  -NoDeps             Do not start dependencies of the selected services
  -Foreground         Run up attached instead of detached
  -Volumes            With down, also remove named volumes

Repos:
  Missing API/frontend repos are cloned into API_CONTEXT / FE_CONTEXT using
  API_REPO / API_REF and FE_REPO / FE_REF from the selected env file.

Examples:
  .\start.ps1 local
  .\start.ps1 development
  .\start.ps1 local up -Services api,frontend -NoDeps
  .\start.ps1 development up -Services api
  .\start.ps1 local down -Volumes
  .\start.ps1 development logs -Services api
'@ | Write-Host
}

function Import-DotEnv {
    param([Parameter(Mandatory)][string]$Path)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { continue }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$key] = $value
    }
    return $values
}

function Get-EnvValue {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default
    )

    if ($Values.ContainsKey($Key)) {
        $value = [string]$Values[$Key]
        if ($value -ne '') { return $value }
    }
    return $Default
}

function Resolve-ContextPath {
    param([Parameter(Mandatory)][string]$Context)

    if ([System.IO.Path]::IsPathRooted($Context)) { return $Context }
    return [System.IO.Path]::GetFullPath((Join-Path $scriptDir $Context))
}

function Ensure-Repo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Repository,
        [string]$Ref,
        [Parameter(Mandatory)][string]$Label
    )

    if (Test-Path -LiteralPath $Path) { return }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git was not found in PATH. Install git, or clone $Label manually into '$Path'."
    }

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Host "Cloning $Label into $Path..." -ForegroundColor Cyan
    if ($Ref) {
        & git clone --branch $Ref --single-branch $Repository $Path
    }
    else {
        & git clone $Repository $Path
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed for $Label ($Repository$(if ($Ref) { " @$Ref" }))."
    }
}

if ($Environment -eq 'help' -or $Action -eq 'help' -or $PSBoundParameters.Count -eq 0) {
    Show-Usage
    return
}

$scriptDir = $PSScriptRoot
$envFile = Join-Path $scriptDir ".env.$Environment"

if (-not (Test-Path -LiteralPath $envFile)) {
    $example = "$envFile.example"
    if (Test-Path -LiteralPath $example) {
        Copy-Item -LiteralPath $example -Destination $envFile
        Write-Host "Created $envFile from $([System.IO.Path]::GetFileName($example))." -ForegroundColor Yellow
    }
    else {
        throw "Missing env file '$envFile' and no example '$example' to copy."
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'The docker CLI was not found in PATH.'
}

$ErrorActionPreference = 'SilentlyContinue'
& docker info *> $null
$dockerReady = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = 'Stop'
if (-not $dockerReady) {
    throw 'The Docker daemon is not reachable. Start Docker Desktop and retry.'
}

$envValues = Import-DotEnv -Path $envFile
$apiContext = Get-EnvValue $envValues 'API_CONTEXT' '../LibrariesApiTest'
$feContext = Get-EnvValue $envValues 'FE_CONTEXT' '../LibrariesFE'
$apiRepo = Get-EnvValue $envValues 'API_REPO' 'https://github.com/AlexVillegasC/LibrariesApiTest.git'
$apiRef = Get-EnvValue $envValues 'API_REF' 'identity-server'
$feRepo = Get-EnvValue $envValues 'FE_REPO' 'https://github.com/AlexVillegasC/LibrariesFE.git'
$feRef = Get-EnvValue $envValues 'FE_REF' 'main'

if ($Action -eq 'up' -or $Action -eq 'build') {
    $selectedServices = if ($Services.Count -gt 0) { $Services } else { @('postgres', 'api', 'frontend') }
    if ($selectedServices -contains 'api') {
        Ensure-Repo -Path (Resolve-ContextPath $apiContext) -Repository $apiRepo -Ref $apiRef -Label 'the API'
    }
    if ($selectedServices -contains 'frontend') {
        Ensure-Repo -Path (Resolve-ContextPath $feContext) -Repository $feRepo -Ref $feRef -Label 'the frontend'
    }
}

$composeBase = @('compose', '--env-file', $envFile)
if ($Environment -eq 'local') {
    $composeBase += @('--profile', 'local')
}

function Invoke-Compose {
    param([Parameter(Mandatory)][string[]]$Arguments)

    Write-Host "> docker $($composeBase -join ' ') $($Arguments -join ' ')" -ForegroundColor DarkGray
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & docker @composeBase @Arguments
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    if ($exitCode -ne 0) {
        throw "docker compose exited with code $exitCode."
    }
}

switch ($Action) {
    'up' {
        $cmd = @('up')
        if (-not $Foreground) { $cmd += '-d' }
        if (-not $NoBuild) { $cmd += '--build' }
        if ($NoDeps) { $cmd += '--no-deps' }
        $cmd += $Services
        Invoke-Compose $cmd
    }
    'down' {
        $cmd = @('down', '--remove-orphans')
        if ($Volumes) { $cmd += '--volumes' }
        Invoke-Compose $cmd
    }
    'stop' {
        Invoke-Compose (@('stop') + $Services)
    }
    'restart' {
        Invoke-Compose (@('restart') + $Services)
    }
    'build' {
        Invoke-Compose (@('build') + $Services)
    }
    'logs' {
        Invoke-Compose (@('logs', '--follow', '--tail', '100') + $Services)
    }
    'ps' {
        Invoke-Compose @('ps')
    }
}

Write-Host "Done: $Action ($Environment)$(if ($Services) { ' [' + ($Services -join ', ') + ']' })." -ForegroundColor Green
