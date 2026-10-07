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

Examples:
  .\start.ps1 local
  .\start.ps1 development
  .\start.ps1 local up -Services api,frontend -NoDeps
  .\start.ps1 development up -Services api
  .\start.ps1 local down -Volumes
  .\start.ps1 development logs -Services api
'@ | Write-Host
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
