# MCP Kubernetes no Cursor

Como dar ao Cursor acesso de leitura a clusters Kubernetes via MCP. Dois
servidores, escolhidos conforme onde o cluster roda:

| Servidor | Quando usar | Guia |
|---|---|---|
| **`eks`** | clusters Amazon EKS (autenticação por IAM/SSO) | [eks/README.md](eks/README.md) |
| **`k3s`** | qualquer outro cluster: k3s, on-premises, Rancher, kind | [k3s/README.md](k3s/README.md) |

Os dois rodam via `uvx`, sob demanda, em modo somente leitura. Não há serviço em
background. Podem conviver no mesmo `mcp.json`, inclusive com várias instâncias
(um servidor por cluster, se preferir separar).

Todo bloco de comando deste repositório diz onde roda: **Windows** (PowerShell),
**Linux** (bash) ou **Windows e Linux**, quando o comando é idêntico nos dois.

---

## Diferenças entre Windows e Linux

| | Windows | Linux |
|---|---|---|
| Instalar o `uv` | `winget install --id=astral-sh.uv -e` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Arquivo de configuração | `%USERPROFILE%\.cursor\mcp.json` | `~/.cursor/mcp.json` |
| Entry point do `eks` | `awslabs.eks-mcp-server.exe` | `awslabs.eks-mcp-server` |
| Caminho no JSON | `C:\\Users\\<USER>\\...` (barra dupla) | `/home/<USER>/...` |
| Exemplo do `eks` | [`mcp.json.windows.example`](eks/mcp.json.windows.example) | [`mcp.json.linux.example`](eks/mcp.json.linux.example) |
| Scripts do `eks` | `.ps1` | `.sh` (exige `jq`) |
| Quebra de linha em comando longo | `` ` `` (crase) | `\` |

O resto — AWS CLI, perfis, access entries, kubeconfig, flags dos servidores — é
igual nos dois.

---

## Requisito comum

Só o `uv` é obrigatório — ele baixa e executa os servidores.

**Windows**

```powershell
winget install --id=astral-sh.uv -e
```

**Linux**

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Não é necessário instalar `kubectl`, `helm`, Python ou Node: os servidores falam
direto com a API dos clusters. Cada guia lista os requisitos extras do seu
cenário (AWS CLI para o `eks`, kubeconfig para o `k3s`).

---

## Configuração

Os dois servidores convivem no mesmo `mcpServers` — use só o bloco que precisar.
Substitua os valores entre `<>` e reinicie o Cursor.

### Windows

Arquivo: `%USERPROFILE%\.cursor\mcp.json`

```json
{
  "mcpServers": {
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
    },
    "k3s": {
      "command": "uvx",
      "args": ["kubernetes-mcp-server@latest"],
      "env": {
        "KUBECONFIG": "C:\\Users\\<USER>\\.kube\\<KUBECONFIG_FILE>"
      }
    }
  }
}
```

### Linux

Arquivo: `~/.cursor/mcp.json`

```json
{
  "mcpServers": {
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
    },
    "k3s": {
      "command": "uvx",
      "args": ["kubernetes-mcp-server@latest"],
      "env": {
        "KUBECONFIG": "/home/<USER>/.kube/<KUBECONFIG_FILE>"
      }
    }
  }
}
```

O nome da chave (`eks`, `k3s`) é livre: serve só para você identificar o servidor
e vira o prefixo das ferramentas para o agente. Com vários clusters, nomes como
`eks-prod` e `eks-hml` ajudam.

---

## Uso

Peça em linguagem natural. No servidor `eks`, **sempre diga qual cluster** — ele
não tem padrão e atende todos os clusters visíveis na conta:

> *"liste os pods em CrashLoopBackOff no namespace `<NAMESPACE>` do cluster `<CLUSTER_NAME>`"*
>
> *"mostre os eventos de warning do k3s"*

Deu errado? Comece pelos **MCP Logs** no painel Output do Cursor (`Ctrl+Shift+U`).

---

## Estrutura

```
eks/
  README.md                    guia do servidor eks
  ACESSO-AWS.md                autenticação IAM/SSO e access entries
  TROUBLESHOOTING.md           erros conhecidos
  mcp.json.windows.example     config do servidor (Windows)
  mcp.json.linux.example       config do servidor (Linux)
  scripts/
    Validate-McpEks.ps1        diagnóstico ponta a ponta (Windows)
    Setup-EksAccess.ps1        cria/garante a access entry (Windows)
    validate-mcp-eks.sh        diagnóstico ponta a ponta (Linux)
    setup-eks-access.sh        cria/garante a access entry (Linux)

k3s/
  README.md                    guia do servidor k3s
  mcp.json.example             config do servidor (Windows e Linux)
```

---

## Referências

- [EKS MCP Server](https://awslabs.github.io/mcp/servers/eks-mcp-server) — servidor usado no `eks`.
- [`kubernetes-mcp-server`](https://github.com/containers/kubernetes-mcp-server) — servidor usado no `k3s`.
- [MCP no Cursor](https://cursor.com/docs/context/mcp) — formato do `mcp.json` e onde ver os logs.
- [Instalação do `uv`](https://docs.astral.sh/uv/getting-started/installation/).
