<#
.SYNOPSIS
    Garante a EKS Access Entry que o MCP Server precisa para acessar um cluster.

.DESCRIPTION
    Cria a access entry do principal informado (por padrao o principal da sessao
    atual) e associa a politica de acesso com escopo de cluster. O script e
    idempotente: se a entry ou a associacao ja existirem, apenas informa e segue.

.PARAMETER Cluster
    Nome do cluster EKS.

.PARAMETER PrincipalArn
    ARN do role ou usuario IAM. Padrao: o principal da sessao atual, convertido
    de assumed-role para o role IAM correspondente.

.PARAMETER PolicyArn
    Politica de acesso do EKS. Padrao: AmazonEKSClusterAdminPolicy.
    Alternativas: AmazonEKSViewPolicy (somente leitura), AmazonEKSEditPolicy,
    AmazonEKSAdminPolicy.

.PARAMETER Profile
    Perfil do AWS CLI. Padrao: AWS_PROFILE do ambiente, ou o perfil padrao.

.PARAMETER Region
    Regiao do cluster. Padrao: AWS_REGION do ambiente, ou a regiao do perfil.

.EXAMPLE
    .\Setup-EksAccess.ps1 -Cluster <CLUSTER_NAME>

.EXAMPLE
    .\Setup-EksAccess.ps1 -Cluster <CLUSTER_NAME> -Profile <PROFILE_NAME> -Region us-east-2 `
        -PolicyArn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Cluster,

    [string]$PrincipalArn,
    [string]$PolicyArn = 'arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy',
    [string]$Profile,
    [string]$Region
)

$ErrorActionPreference = 'Stop'

if ($Profile) { $env:AWS_PROFILE = $Profile }
if ($Region)  { $env:AWS_REGION  = $Region }

if (-not $env:AWS_REGION) {
    $env:AWS_REGION = (aws configure get region 2>$null)
}
if (-not $env:AWS_REGION) {
    Write-Host "Defina a regiao com -Region ou configure uma no perfil do AWS CLI." -ForegroundColor Red
    exit 1
}

$id = aws sts get-caller-identity --output json | ConvertFrom-Json

if (-not $PrincipalArn) {
    # arn:aws:sts::<acct>:assumed-role/<RoleName>/<session> -> role IAM correspondente
    $PrincipalArn = $id.Arn
    if ($PrincipalArn -match ':assumed-role/([^/]+)/') {
        $roleName = $Matches[1]
        $PrincipalArn = if ($roleName -like 'AWSReservedSSO_*') {
            "arn:aws:iam::$($id.Account):role/aws-reserved/sso.amazonaws.com/$roleName"
        } else {
            "arn:aws:iam::$($id.Account):role/$roleName"
        }
    }
}

Write-Host "Cluster:   $Cluster"
Write-Host "Regiao:    $($env:AWS_REGION)"
Write-Host "Principal: $PrincipalArn"
Write-Host "Politica:  $PolicyArn`n"

$authMode = aws eks describe-cluster --name $Cluster --query 'cluster.accessConfig.authenticationMode' --output text 2>$null
if ($authMode -eq 'CONFIG_MAP') {
    Write-Host "AVISO: cluster em authenticationMode CONFIG_MAP." -ForegroundColor Yellow
    Write-Host "       Access entries so valem em API ou API_AND_CONFIG_MAP.`n" -ForegroundColor Yellow
}

$existing = aws eks describe-access-entry --cluster-name $Cluster `
    --principal-arn $PrincipalArn --output json 2>$null

if ($existing) {
    Write-Host "Access entry ja existe." -ForegroundColor DarkGray
} else {
    aws eks create-access-entry --cluster-name $Cluster `
        --principal-arn $PrincipalArn --type STANDARD | Out-Null
    Write-Host "Access entry criada." -ForegroundColor Green
}

$associated = (aws eks list-associated-access-policies --cluster-name $Cluster `
    --principal-arn $PrincipalArn --output json | ConvertFrom-Json).associatedAccessPolicies

if ($associated.policyArn -contains $PolicyArn) {
    Write-Host "Politica ja associada." -ForegroundColor DarkGray
} else {
    aws eks associate-access-policy --cluster-name $Cluster `
        --principal-arn $PrincipalArn --policy-arn $PolicyArn `
        --access-scope 'type=cluster' | Out-Null
    Write-Host "Politica associada com escopo de cluster." -ForegroundColor Green
}

Write-Host "`nValide com: .\Validate-McpEks.ps1"
