# Servidor MCP `eks`

Como configurar o [AWS Labs EKS MCP Server](https://awslabs.github.io/mcp/servers/eks-mcp-server)
no Cursor, do zero, para qualquer conta e cluster Amazon EKS.

Cada bloco de comando diz onde roda: **Windows** (PowerShell), **Linux** (bash)
ou **Windows e Linux**, quando é idêntico nos dois.

---

## Requisitos

| Requisito | Para quê | Windows | Linux |
|---|---|---|---|
| `uv` / `uvx` ≥ 0.10 | baixa e executa o servidor MCP | `winget install --id=astral-sh.uv -e` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| AWS CLI v2 ≥ 2.12 | login e gestão das access entries | [instalador oficial](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | [instalador oficial](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Perfil AWS | credenciais da conta do cluster | `aws configure sso` | `aws configure sso` |
| Shell dos scripts | rodar [`scripts/`](scripts) | PowerShell 5.1+ (já vem no sistema) | `bash` + `jq` |
| EKS Access Entry | autorização dentro do cluster | [ACESSO-AWS.md](ACESSO-AWS.md) | [ACESSO-AWS.md](ACESSO-AWS.md) |

Não precisa de `kubectl`: o servidor chama a API do EKS, gera o token na hora a
partir das credenciais AWS e fala direto com o API server. Não existe passo de
`aws eks update-kubeconfig` aqui.

### Preparar os scripts

Os scripts existem em duas versões com o mesmo comportamento.

**Windows** — a política de execução padrão é `Restricted` e bloqueia qualquer
`.ps1`. Libere para o seu usuário uma vez, sem precisar de administrador:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Para não alterar nada de forma permanente, use
`powershell -ExecutionPolicy Bypass -File .\scripts\Validate-McpEks.ps1` a cada
execução.

**Linux** — dê permissão de execução uma vez:

```bash
chmod +x scripts/*.sh
```

---

## 1. Descobrir os valores do seu ambiente

**Windows e Linux**

```shell
aws configure list-profiles
aws sts get-caller-identity --profile <PROFILE_NAME>
aws eks list-clusters --profile <PROFILE_NAME> --region <REGION>
```

Anote três coisas: o **nome do perfil**, a **região** dos clusters e o **ARN do
principal** (role ou usuário) devolvido pelo `get-caller-identity`. Os três
aparecem nos passos seguintes.

---

## 2. Garantir acesso ao cluster

O servidor só enxerga o que o seu principal IAM pode ver dentro do cluster. Se
ainda não houver uma access entry para ele:

**Windows**

```powershell
.\scripts\Setup-EksAccess.ps1 -Cluster <CLUSTER_NAME> -Profile <PROFILE_NAME> -Region <REGION>
```

**Linux**

```bash
./scripts/setup-eks-access.sh -c <CLUSTER_NAME> -p <PROFILE_NAME> -r <REGION>
```

O script é idempotente e, por padrão, associa `AmazonEKSClusterAdminPolicy`. Para
acesso somente leitura, veja [ACESSO-AWS.md](ACESSO-AWS.md).

---

## 3. Configurar o `mcp.json`

A única diferença entre os sistemas é o nome do entry point.

**Windows** — em `%USERPROFILE%\.cursor\mcp.json`, cópia pronta em
[`mcp.json.windows.example`](mcp.json.windows.example):

```json
"eks": {
  "command": "uvx",
  "args": [
    "--from",
    "awslabs.eks-mcp-server@latest",
    "awslabs.eks-mcp-server.exe",
    "--allow-sensitive-data-access"
  ],
  "env": {
    "AWS_PROFILE": "<PROFILE_NAME>",
    "AWS_REGION": "<REGION>",
    "FASTMCP_LOG_LEVEL": "ERROR"
  }
}
```

O sufixo `.exe` é obrigatório: sem ele o `uvx` não acha o executável e o
servidor nem inicia.

**Linux** — em `~/.cursor/mcp.json`, cópia pronta em
[`mcp.json.linux.example`](mcp.json.linux.example):

```json
"eks": {
  "command": "uvx",
  "args": [
    "--from",
    "awslabs.eks-mcp-server@latest",
    "awslabs.eks-mcp-server",
    "--allow-sensitive-data-access"
  ],
  "env": {
    "AWS_PROFILE": "<PROFILE_NAME>",
    "AWS_REGION": "<REGION>",
    "FASTMCP_LOG_LEVEL": "ERROR"
  }
}
```

Aqui é o contrário: o nome vai **sem** `.exe`.

Reinicie o Cursor. Nos dois sistemas, três detalhes decidem entre funcionar e não
funcionar:

- **`AWS_REGION`** é obrigatório; sem ele o servidor não encontra os clusters.
- **`--allow-sensitive-data-access`** libera logs, eventos e Secrets. Sem a flag
  o agente lista recursos mas não investiga incidente.
- **Sem `--allow-write`** — modo somente leitura, recomendado pela AWS para
  produção. Acrescente a flag só quando quiser que o agente altere o cluster, e
  lembre que a permissão real vem da política associada à access entry.

---

## 4. Autenticar

Com perfil SSO (IAM Identity Center), a sessão dura algumas horas e, quando
expira, o MCP para de responder — é a falha mais comum.

**Windows e Linux**

```shell
aws sso login --profile <PROFILE_NAME>
```

Com credenciais estáticas ou role assumida por outro meio, basta que o perfil
esteja válido.

---

## 5. Validar

Sem argumentos, o script lê o perfil e a região do próprio `mcp.json` e testa
todos os clusters visíveis na conta. Confere, em ordem: binários, configuração
do MCP, credenciais válidas, clusters visíveis, access entry do principal e uma
chamada real ao API server de cada cluster. Para no primeiro passo que falhar e
diz o que corrigir.

**Windows**

```powershell
.\scripts\Validate-McpEks.ps1

# apontando manualmente
.\scripts\Validate-McpEks.ps1 -Profile <PROFILE_NAME> -Region <REGION> -Clusters <CLUSTER_NAME>
```

Confere também que o entry point tem o sufixo `.exe`.

**Linux**

```bash
./scripts/validate-mcp-eks.sh

# apontando manualmente
./scripts/validate-mcp-eks.sh -p <PROFILE_NAME> -r <REGION> -c <CLUSTER_NAME>
```

Recusa o entry point com `.exe`, exige o `uvx` no PATH e aceita `-f` para
apontar outro `mcp.json`; `-h` lista as opções.

---

## 6. Usar

Sempre informe o cluster: o servidor não tem padrão e atende todos os clusters
visíveis na conta.

> *"liste os pods em CrashLoopBackOff no namespace `<NAMESPACE>` do cluster `<CLUSTER_NAME>`"*

Ferramentas mais usadas:

- `list_k8s_resources` — qualquer kind, com `field_selector` e `label_selector`
- `get_pod_logs` e `get_k8s_events` — investigação de incidente
- `get_cloudwatch_logs` e `get_cloudwatch_metrics` — Container Insights
- `get_eks_insights` e `get_eks_vpc_config` — saúde e rede do cluster
- `search_eks_troubleshoot_guide` — guia oficial da AWS

A lista completa, com parâmetros e permissões IAM de cada ferramenta, está na
[documentação oficial](https://awslabs.github.io/mcp/servers/eks-mcp-server).

---

## Nesta pasta

| Arquivo | Conteúdo |
|---|---|
| [`ACESSO-AWS.md`](ACESSO-AWS.md) | Autenticação, access entries e políticas |
| [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) | Erros conhecidos e como resolver |

| Função | Windows | Linux |
|---|---|---|
| Configuração | [`mcp.json.windows.example`](mcp.json.windows.example) | [`mcp.json.linux.example`](mcp.json.linux.example) |
| Diagnóstico ponta a ponta | [`scripts/Validate-McpEks.ps1`](scripts/Validate-McpEks.ps1) | [`scripts/validate-mcp-eks.sh`](scripts/validate-mcp-eks.sh) |
| Cria/garante a access entry | [`scripts/Setup-EksAccess.ps1`](scripts/Setup-EksAccess.ps1) | [`scripts/setup-eks-access.sh`](scripts/setup-eks-access.sh) |
