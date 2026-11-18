#!/usr/bin/env bash
#
# Garante a EKS Access Entry que o MCP Server precisa para acessar um cluster.
#
# Cria a access entry do principal informado (por padrao o principal da sessao
# atual) e associa a politica de acesso com escopo de cluster. E idempotente: se
# a entry ou a associacao ja existirem, apenas informa e segue.
#
# Uso:
#   ./setup-eks-access.sh -c <CLUSTER_NAME>
#   ./setup-eks-access.sh -c <CLUSTER_NAME> -p <PROFILE_NAME> -r <REGION> \
#       -a arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy
#
# Opcoes:
#   -c  nome do cluster EKS (obrigatorio)
#   -n  ARN do role ou usuario IAM (padrao: principal da sessao atual)
#   -a  politica de acesso (padrao: AmazonEKSClusterAdminPolicy)
#       alternativas: AmazonEKSViewPolicy, AmazonEKSEditPolicy, AmazonEKSAdminPolicy
#   -p  perfil do AWS CLI (padrao: AWS_PROFILE do ambiente)
#   -r  regiao do cluster (padrao: AWS_REGION, ou a regiao do perfil)

set -uo pipefail

CLUSTER=""
PRINCIPAL=""
POLICY="arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
PROFILE=""
REGION=""

while getopts ':c:n:a:p:r:h' opt; do
  case "$opt" in
    c) CLUSTER=$OPTARG ;;
    n) PRINCIPAL=$OPTARG ;;
    a) POLICY=$OPTARG ;;
    p) PROFILE=$OPTARG ;;
    r) REGION=$OPTARG ;;
    h) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opcao invalida: -$OPTARG (use -h)" >&2; exit 2 ;;
  esac
done

[ -n "$CLUSTER" ] || { echo "informe o cluster com -c <CLUSTER_NAME> (use -h)" >&2; exit 2; }
command -v aws >/dev/null || { echo "aws CLI nao encontrado no PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq nao encontrado no PATH" >&2; exit 1; }

[ -n "$PROFILE" ] && export AWS_PROFILE="$PROFILE"
[ -n "$REGION" ]  && export AWS_REGION="$REGION"
: "${AWS_REGION:=$(aws configure get region 2>/dev/null)}"
[ -n "${AWS_REGION:-}" ] || { echo "defina a regiao com -r ou configure uma no perfil do AWS CLI" >&2; exit 1; }
export AWS_REGION

id_json=$(aws sts get-caller-identity --output json) || exit 1
account=$(jq -r '.Account' <<<"$id_json")
arn=$(jq -r '.Arn' <<<"$id_json")

if [ -z "$PRINCIPAL" ]; then
  # arn:aws:sts::<acct>:assumed-role/<RoleName>/<session> -> role IAM correspondente
  PRINCIPAL="$arn"
  if [[ "$arn" =~ :assumed-role/([^/]+)/ ]]; then
    role="${BASH_REMATCH[1]}"
    case "$role" in
      AWSReservedSSO_*) PRINCIPAL="arn:aws:iam::${account}:role/aws-reserved/sso.amazonaws.com/${role}" ;;
      *)                PRINCIPAL="arn:aws:iam::${account}:role/${role}" ;;
    esac
  fi
fi

echo "Cluster:   $CLUSTER"
echo "Regiao:    $AWS_REGION"
echo "Principal: $PRINCIPAL"
echo "Politica:  $POLICY"
echo

auth=$(aws eks describe-cluster --name "$CLUSTER" \
  --query 'cluster.accessConfig.authenticationMode' --output text 2>/dev/null)
if [ "$auth" = "CONFIG_MAP" ]; then
  echo "AVISO: cluster em authenticationMode CONFIG_MAP."
  echo "       Access entries so valem em API ou API_AND_CONFIG_MAP."
  echo
fi

if aws eks describe-access-entry --cluster-name "$CLUSTER" \
     --principal-arn "$PRINCIPAL" >/dev/null 2>&1; then
  echo "Access entry ja existe."
else
  aws eks create-access-entry --cluster-name "$CLUSTER" \
    --principal-arn "$PRINCIPAL" --type STANDARD >/dev/null || exit 1
  echo "Access entry criada."
fi

associated=$(aws eks list-associated-access-policies --cluster-name "$CLUSTER" \
  --principal-arn "$PRINCIPAL" --output json 2>/dev/null \
  | jq -r '.associatedAccessPolicies[]?.policyArn')

if grep -qxF "$POLICY" <<<"$associated"; then
  echo "Politica ja associada."
else
  aws eks associate-access-policy --cluster-name "$CLUSTER" \
    --principal-arn "$PRINCIPAL" --policy-arn "$POLICY" \
    --access-scope type=cluster >/dev/null || exit 1
  echo "Politica associada com escopo de cluster."
fi

echo
echo "Valide com: ./validate-mcp-eks.sh"
