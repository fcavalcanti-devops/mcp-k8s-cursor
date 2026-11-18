#!/usr/bin/env bash
#
# Valida ponta a ponta a conexao do EKS MCP Server do Cursor com os clusters EKS.
#
# Sem argumentos, le o perfil e a regiao do proprio ~/.cursor/mcp.json e testa
# todos os clusters visiveis na conta. Confere, em ordem: binarios, configuracao
# do MCP, credenciais, clusters, access entries e uma chamada real ao API server
# de cada cluster. Para no primeiro passo que falhar e indica a correcao.
#
# Uso:
#   ./validate-mcp-eks.sh
#   ./validate-mcp-eks.sh -p <PROFILE_NAME> -r <REGION> -c <CLUSTER_NAME>
#   ./validate-mcp-eks.sh -f <MCP_JSON_PATH>
#
# Opcoes:
#   -p  perfil do AWS CLI (padrao: AWS_PROFILE do mcp.json)
#   -r  regiao dos clusters (padrao: AWS_REGION do mcp.json)
#   -c  cluster a testar; repita para varios (padrao: todos os visiveis)
#   -f  caminho do mcp.json (padrao: ~/.cursor/mcp.json)

set -uo pipefail

PROFILE=""
REGION=""
MCP_JSON="${MCP_JSON:-$HOME/.cursor/mcp.json}"
CLUSTERS=()

while getopts ':p:r:c:f:h' opt; do
  case "$opt" in
    p) PROFILE=$OPTARG ;;
    r) REGION=$OPTARG ;;
    c) CLUSTERS+=("$OPTARG") ;;
    f) MCP_JSON=$OPTARG ;;
    h) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opcao invalida: -$OPTARG (use -h)" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_DIM=$'\033[90m'; C_OFF=$'\033[0m'
else
  C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi

step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_OFF"; }
ok()   { printf '    %s[OK]%s    %s\n' "$C_OK" "$C_OFF" "$1"; }
info() { printf '    %s[..]    %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
warn() { printf '    %s[AVISO] %s%s\n' "$C_WARN" "$1" "$C_OFF"; }
fail() {
  printf '    %s[FALHA] %s%s\n' "$C_ERR" "$1" "$C_OFF"
  [ $# -gt 1 ] && printf '            %sCorrecao: %s%s\n' "$C_WARN" "$2" "$C_OFF"
  exit 1
}

step 'Binarios necessarios'
for bin in aws jq uvx; do
  path=$(command -v "$bin") || {
    case "$bin" in
      aws) fix='instale o AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html' ;;
      jq)  fix='instale o jq pelo gerenciador de pacotes (apt install jq, dnf install jq)' ;;
      uvx) fix='instale o uv: curl -LsSf https://astral.sh/uv/install.sh | sh' ;;
    esac
    fail "$bin nao encontrado no PATH" "$fix"
  }
  ok "$bin -> $path"
done

step 'Configuracao do MCP no Cursor'
[ -f "$MCP_JSON" ] || fail "$MCP_JSON nao existe" 'copie mcp.json.linux.example para esse caminho ou use -f'
jq -e . "$MCP_JSON" >/dev/null 2>&1 || fail "$MCP_JSON nao e um JSON valido" 'revise a sintaxe'
ok "arquivo: $MCP_JSON"

# O nome da chave e livre, entao localiza o servidor pelo pacote nos args.
SRV=$(jq -r '.mcpServers // {} | to_entries[]
             | select((.value.args // []) | join(" ") | test("awslabs\\.eks-mcp-server"))
             | .key' "$MCP_JSON" | head -1)
[ -n "$SRV" ] || fail 'nenhum servidor do EKS MCP encontrado no mcp.json' 'use mcp.json.linux.example como base'

srv_json=$(jq -c --arg k "$SRV" '.mcpServers[$k]' "$MCP_JSON")
srv_cmd=$(jq -r '.command // "?"' <<<"$srv_json")
srv_args=$(jq -r '(.args // []) | join(" ")' <<<"$srv_json")
ok "servidor '$SRV' encontrado ($srv_cmd)"

if grep -q 'awslabs\.eks-mcp-server\.exe' <<<"$srv_args"; then
  fail 'entry point com sufixo .exe' 'troque awslabs.eks-mcp-server.exe por awslabs.eks-mcp-server nos args'
fi

# Perfil e regiao: parametro > env do mcp.json > configuracao ambiente do AWS CLI.
[ -n "$PROFILE" ] || PROFILE=$(jq -r '.env.AWS_PROFILE // empty' <<<"$srv_json")
[ -n "$REGION" ]  || REGION=$(jq -r '.env.AWS_REGION // empty' <<<"$srv_json")

if [ -n "$PROFILE" ]; then
  export AWS_PROFILE="$PROFILE"; ok "perfil: $PROFILE"
else
  info 'sem AWS_PROFILE definido; usando a configuracao ambiente do AWS CLI'
fi

if [ -n "$REGION" ]; then
  export AWS_REGION="$REGION"; ok "regiao: $REGION"
else
  fail 'AWS_REGION ausente' 'defina AWS_REGION no env do servidor ou use -r'
fi

if grep -qw -- '--allow-write' <<<"$srv_args"; then
  ok 'modo de escrita: HABILITADO (--allow-write)'
else
  ok 'modo de escrita: somente leitura'
fi

step 'Credenciais AWS'
id_json=$(aws sts get-caller-identity --output json 2>/dev/null) || id_json='{}'
account=$(jq -r '.Account // empty' <<<"$id_json")
arn=$(jq -r '.Arn // empty' <<<"$id_json")
if [ -z "$arn" ]; then
  if [ -n "$PROFILE" ]; then fix="aws sso login --profile $PROFILE"
  else fix='autentique o perfil padrao do AWS CLI'; fi
  fail 'credenciais invalidas ou sessao expirada' "$fix"
fi
ok "conta $account como $arn"

step "Clusters EKS visiveis em $REGION"
mapfile -t FOUND < <(aws eks list-clusters --output json 2>/dev/null | jq -r '.clusters[]?')
[ "${#FOUND[@]}" -gt 0 ] || fail "nenhum cluster visivel em $REGION" 'confira a regiao e as permissoes do perfil'
ok "$(printf '%s, ' "${FOUND[@]}" | sed 's/, $//')"

[ "${#CLUSTERS[@]}" -gt 0 ] || CLUSTERS=("${FOUND[@]}")

# Access entries exigem o role IAM, nao o assumed-role do STS.
principal="$arn"
if [[ "$arn" =~ :assumed-role/([^/]+)/ ]]; then
  role="${BASH_REMATCH[1]}"
  case "$role" in
    AWSReservedSSO_*) principal="arn:aws:iam::${account}:role/aws-reserved/sso.amazonaws.com/${role}" ;;
    *)                principal="arn:aws:iam::${account}:role/${role}" ;;
  esac
fi

has_kubectl=0; command -v kubectl >/dev/null && has_kubectl=1

for cluster in "${CLUSTERS[@]}"; do
  step "Cluster $cluster"

  if ! printf '%s\n' "${FOUND[@]}" | grep -qxF "$cluster"; then
    info 'nao existe nesta conta/regiao'
    continue
  fi

  info_json=$(aws eks describe-cluster --name "$cluster" \
    --query 'cluster.{v:version,s:status,auth:accessConfig.authenticationMode,pub:resourcesVpcConfig.endpointPublicAccess}' \
    --output json 2>/dev/null)
  v=$(jq -r '.v' <<<"$info_json"); s=$(jq -r '.s' <<<"$info_json")
  auth=$(jq -r '.auth' <<<"$info_json"); pub=$(jq -r '.pub' <<<"$info_json")
  ok "versao $v, status $s, auth $auth, endpoint publico: $pub"

  [ "$pub" = "true" ] || warn 'endpoint privado: exige VPN, Direct Connect ou bastion na VPC'
  [ "$auth" = "CONFIG_MAP" ] && warn 'authenticationMode CONFIG_MAP: access entries nao valem; o acesso vem do aws-auth'

  policies=$(aws eks list-associated-access-policies --cluster-name "$cluster" \
    --principal-arn "$principal" --output json 2>/dev/null \
    | jq -r '[.associatedAccessPolicies[]?.policyArn | split("/") | last] | join(", ")')
  [ -n "$policies" ] || fail "sem access entry para $principal" "./setup-eks-access.sh -c $cluster"
  ok "politicas: $policies"

  if [ "$has_kubectl" = 0 ]; then
    info 'kubectl ausente; pulando o teste de conexao ao API server'
    continue
  fi

  # Prova final: fala com o API server usando o mesmo caminho de autenticacao do MCP.
  kubeconfig=$(mktemp)
  if ! aws eks update-kubeconfig --name "$cluster" --kubeconfig "$kubeconfig" >/dev/null 2>&1; then
    rm -f "$kubeconfig"
    fail "nao foi possivel gerar o kubeconfig de $cluster" 'verifique credenciais e permissoes'
  fi
  if ns=$(kubectl --kubeconfig "$kubeconfig" get ns --no-headers 2>&1); then
    rm -f "$kubeconfig"
    ok "API server respondeu: $(wc -l <<<"$ns") namespaces"
  else
    rm -f "$kubeconfig"
    fail "API server recusou a conexao: $ns" 'verifique rede, credenciais e access entry'
  fi
done

printf '\n%sTudo certo. Reinicie o Cursor se tiver alterado o mcp.json.%s\n' "$C_OK" "$C_OFF"
