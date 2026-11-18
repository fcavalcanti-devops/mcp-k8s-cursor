<#
.SYNOPSIS
    Valida ponta a ponta a conexao do EKS MCP Server do Cursor com os clusters EKS.

.DESCRIPTION
    Sem argumentos, descobre tudo sozinho: le o perfil e a regiao do proprio
    mcp.json e testa todos os clusters visiveis na conta. Confere, em ordem:
    binarios, configuracao do MCP, credenciais, clusters, access entries e uma
    chamada real ao API server de cada cluster.
    Para no primeiro passo que falhar e indica a correcao.

.PARAMETER Profile
    Perfil do AWS CLI. Padrao: o que estiver no mcp.json; se nao houver, usa a
    configuracao ambiente do AWS CLI.

.PARAMETER Region
    Regiao dos clusters. Padrao: a que estiver no mcp.json.

.PARAMETER Clusters
    Clusters a testar. Padrao: todos os visiveis na conta.

.EXAMPLE
    .\Validate-McpEks.ps1

.EXAMPLE
    .\Validate-McpEks.ps1 -Profile <PROFILE_NAME> -Region us-east-2 -Clusters <CLUSTER_NAME>
#>
[CmdletBinding()]
param(
    [string]$Profile,
    [string]$Region,
    [string[]]$Clusters
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param($Text) Write-Host "    [OK]   $Text" -ForegroundColor Green }
function Write-Info { param($Text) Write-Host "    [..]   $Text" -ForegroundColor DarkGray }
function Write-Fail {
    param($Text, $Fix)
    Write-Host "    [FALHA] $Text" -ForegroundColor Red
    if ($Fix) { Write-Host "            Correcao: $Fix" -ForegroundColor Yellow }
    exit 1
}

Write-Step 'Binarios necessarios'
foreach ($bin in 'aws', 'uvx') {
    $cmd = Get-Command $bin -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $fix = if ($bin -eq 'aws') { 'instale o AWS CLI v2' } else { 'instale o uv: winget install --id=astral-sh.uv -e' }
        Write-Fail "$bin nao encontrado no PATH" $fix
    }
    Write-Ok "$bin -> $($cmd.Source)"
}

Write-Step 'Configuracao do MCP no Cursor'
$mcpPath = Join-Path $env:USERPROFILE '.cursor\mcp.json'
if (-not (Test-Path $mcpPath)) {
    Write-Fail "$mcpPath nao existe" 'copie mcp.json.windows.example para esse caminho'
}
$mcp = Get-Content $mcpPath -Raw | ConvertFrom-Json

# O nome da chave e livre, entao localiza o servidor pelo pacote nos args.
$entry = $mcp.mcpServers.PSObject.Properties |
    Where-Object { ($_.Value.args -join ' ') -match 'awslabs\.eks-mcp-server' } |
    Select-Object -First 1
if (-not $entry) {
    Write-Fail 'nenhum servidor do EKS MCP encontrado no mcp.json' 'use mcp.json.windows.example como base'
}
$server = $entry.Value
Write-Ok "servidor '$($entry.Name)' encontrado ($($server.command))"

if ($IsWindows -ne $false -and $server.args -notcontains 'awslabs.eks-mcp-server.exe') {
    Write-Fail 'entry point sem o sufixo .exe' 'no Windows o args precisa de awslabs.eks-mcp-server.exe'
}

# Perfil e regiao: parametro > env do mcp.json > configuracao ambiente do AWS CLI.
if (-not $Profile) { $Profile = $server.env.AWS_PROFILE }
if (-not $Region)  { $Region  = $server.env.AWS_REGION }

if ($Profile) { $env:AWS_PROFILE = $Profile; Write-Ok "perfil: $Profile" }
else          { Write-Info 'sem AWS_PROFILE definido; usando a configuracao ambiente do AWS CLI' }

if ($Region) { $env:AWS_REGION = $Region; Write-Ok "regiao: $Region" }
else         { Write-Fail 'AWS_REGION ausente' 'defina AWS_REGION no env do servidor ou use -Region' }

$writeEnabled = $server.args -contains '--allow-write'
Write-Ok ("modo de escrita: " + $(if ($writeEnabled) { 'HABILITADO (--allow-write)' } else { 'somente leitura' }))

Write-Step 'Credenciais AWS'
try {
    $id = aws sts get-caller-identity --output json 2>&1 | ConvertFrom-Json
} catch {
    $id = $null
}
if (-not $id.Arn) {
    $fix = if ($Profile) { "aws sso login --profile $Profile" } else { 'autentique o perfil padrao do AWS CLI' }
    Write-Fail 'credenciais invalidas ou sessao expirada' $fix
}
Write-Ok "conta $($id.Account) como $($id.Arn)"

Write-Step "Clusters EKS visiveis em $Region"
$found = (aws eks list-clusters --output json | ConvertFrom-Json).clusters
if (-not $found) { Write-Fail "nenhum cluster visivel em $Region" 'confira a regiao e as permissoes do perfil' }
Write-Ok ($found -join ', ')

if (-not $Clusters) { $Clusters = $found }

# Converte o assumed-role do STS no role IAM correspondente.
$principal = $id.Arn
if ($principal -match ':assumed-role/([^/]+)/') {
    $roleName = $Matches[1]
    $principal = if ($roleName -like 'AWSReservedSSO_*') {
        "arn:aws:iam::$($id.Account):role/aws-reserved/sso.amazonaws.com/$roleName"
    } else {
        "arn:aws:iam::$($id.Account):role/$roleName"
    }
}

$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue

foreach ($cluster in $Clusters) {
    Write-Step "Cluster $cluster"

    if ($found -notcontains $cluster) {
        Write-Host "    [SKIP] nao existe nesta conta/regiao" -ForegroundColor DarkGray
        continue
    }

    $info = aws eks describe-cluster --name $cluster `
        --query 'cluster.{v:version,s:status,auth:accessConfig.authenticationMode,pub:resourcesVpcConfig.endpointPublicAccess}' `
        --output json | ConvertFrom-Json
    Write-Ok "versao $($info.v), status $($info.s), auth $($info.auth), endpoint publico: $($info.pub)"

    if (-not $info.pub) {
        Write-Host "    [AVISO] endpoint privado: exige VPN, Direct Connect ou bastion na VPC" -ForegroundColor Yellow
    }
    if ($info.auth -eq 'CONFIG_MAP') {
        Write-Host "    [AVISO] authenticationMode CONFIG_MAP: access entries nao valem; o acesso vem do aws-auth" -ForegroundColor Yellow
    }

    $policies = (aws eks list-associated-access-policies --cluster-name $cluster `
        --principal-arn $principal --output json 2>$null | ConvertFrom-Json).associatedAccessPolicies
    if (-not $policies) {
        Write-Fail "sem access entry para $principal" ".\Setup-EksAccess.ps1 -Cluster $cluster"
    }
    Write-Ok ('politicas: ' + (($policies.policyArn | Split-Path -Leaf) -join ', '))

    if (-not $kubectl) {
        Write-Info 'kubectl ausente; pulando o teste de conexao ao API server'
        continue
    }

    # Prova final: fala com o API server usando o mesmo caminho de autenticacao do MCP.
    $kubeconfig = Join-Path $env:TEMP "mcp-eks-validate-$cluster.yaml"
    try {
        aws eks update-kubeconfig --name $cluster --kubeconfig $kubeconfig | Out-Null
        $ns = kubectl --kubeconfig $kubeconfig get ns --no-headers 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Fail "API server recusou a conexao: $ns" 'verifique rede, credenciais e access entry' }
        Write-Ok "API server respondeu: $(($ns | Measure-Object -Line).Lines) namespaces"
    } finally {
        Remove-Item $kubeconfig -ErrorAction SilentlyContinue
    }
}

Write-Host "`nTudo certo. Reinicie o Cursor se tiver alterado o mcp.json." -ForegroundColor Green
