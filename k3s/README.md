# Servidor MCP `k3s`

Como ligar o Cursor a um cluster Kubernetes que **não** é EKS: k3s, k0s,
on-premises, Rancher, kind, minikube ou qualquer cluster alcançável por
kubeconfig.

O servidor é o [`kubernetes-mcp-server`](https://github.com/containers/kubernetes-mcp-server),
genérico, distribuído como binário nativo e executado pelo `uvx`.

Cada bloco de comando diz onde roda: **Windows** (PowerShell), **Linux** (bash)
ou **Windows e Linux**, quando é idêntico nos dois.

---

## Requisitos

| Requisito | Para quê | Windows | Linux |
|---|---|---|---|
| `uv` / `uvx` | baixa e executa o servidor | `winget install --id=astral-sh.uv -e` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| kubeconfig válido | acesso ao cluster | ver [seção 2](#2-obtendo-o-kubeconfig-do-k3s) | ver [seção 2](#2-obtendo-o-kubeconfig-do-k3s) |

Não precisa de Node, Python no PATH, `kubectl` ou `helm`. O pacote do PyPI é um
wrapper fino: na primeira execução ele baixa o binário nativo do GitHub Releases
e passa a executá-lo. O servidor fala direto com a API do cluster.

---

## 1. Configuração no Cursor

Diferente do `eks`, a configuração é a mesma nos dois sistemas — só muda o
formato do caminho. Cópia pronta em [`mcp.json.example`](mcp.json.example).

**Windows** — em `%USERPROFILE%\.cursor\mcp.json`, com barra dupla no caminho:

```json
"k3s": {
  "command": "uvx",
  "args": ["kubernetes-mcp-server@latest"],
  "env": {
    "KUBECONFIG": "C:\\Users\\<USER>\\.kube\\<KUBECONFIG_FILE>"
  }
}
```

**Linux** — em `~/.cursor/mcp.json`:

```json
"k3s": {
  "command": "uvx",
  "args": ["kubernetes-mcp-server@latest"],
  "env": {
    "KUBECONFIG": "/home/<USER>/.kube/<KUBECONFIG_FILE>"
  }
}
```

Se você omitir `KUBECONFIG`, ele usa `~/.kube/config` (no Windows,
`%USERPROFILE%\.kube\config`) e enxerga **todos** os contextos de uma vez —
prático para alternar entre clusters no mesmo servidor. Apontar para um arquivo
dedicado é mais previsível quando se quer isolar um cluster específico. Este
servidor e o do EKS podem conviver no mesmo `mcp.json`.

---

## 2. Obtendo o kubeconfig do k3s

O kubeconfig fica no nó do servidor k3s, em `/etc/rancher/k3s/k3s.yaml`, e aponta
para `https://127.0.0.1:6443`.

**No nó do k3s (Linux)**

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copie o conteúdo para a sua máquina, no caminho que você colocou em
`KUBECONFIG`, e substitua `127.0.0.1` pelo IP ou DNS do nó.

Para outros tipos de cluster, use o kubeconfig que você já tem. Valide antes de
configurar o MCP:

**Windows e Linux**

```shell
kubectl --kubeconfig <KUBECONFIG_PATH> get nodes
```

---

## 3. Modo somente leitura

Diferente do servidor do EKS, aqui não existe flag de linha de comando: a trava
fica num arquivo TOML, igual nos dois sistemas. Crie `mcp-readonly.toml`:

```toml
read_only = true
toolsets = ["core", "config"]
```

E aponte para ele nos `args`:

**Windows**

```json
"args": ["kubernetes-mcp-server@latest", "--config", "C:\\Users\\<USER>\\.kube\\mcp-readonly.toml"]
```

**Linux**

```json
"args": ["kubernetes-mcp-server@latest", "--config", "/home/<USER>/.kube/mcp-readonly.toml"]
```

Com `read_only = true` desaparecem exatamente as ferramentas que alteram o
cluster:

| Ferramenta removida | O que ela faz |
|---|---|
| `pods_delete` | apaga pod |
| `pods_exec` | executa comando dentro do pod |
| `pods_run` | cria pod a partir de uma imagem |
| `resources_create_or_update` | cria ou atualiza qualquer recurso |
| `resources_delete` | apaga qualquer recurso |
| `resources_scale` | altera réplicas |

Vale o aviso que o próprio projeto dá: `read_only` é um *guardrail* de
best-effort. O controle de acesso em que confiar é o RBAC da identidade usada no
kubeconfig. Em cluster que importa, faça as duas coisas.

---

## 4. Ferramentas disponíveis

Com o toolset `core` (padrão): `pods_list`, `pods_log`, `pods_top`,
`events_list`, `namespaces_list`, `nodes_top`, `nodes_log`, `resources_list`,
`resources_get` e `api_resources_list`, entre outras. O toolset `config` expõe
`configuration_view` e `configuration_contexts_list` para inspecionar o
kubeconfig.

Há toolsets opcionais para `helm`, `kubevirt`, `kiali`, `kcp` e `netobserv`,
desligados por padrão. Ligue só o que for usar: cada ferramenta extra consome
contexto e piora a escolha de ferramenta pelo modelo.

---

## 5. Referências

- [Repositório `containers/kubernetes-mcp-server`](https://github.com/containers/kubernetes-mcp-server) —
  lista completa de ferramentas, toolsets e opções.
- [Pacote no PyPI](https://pypi.org/project/kubernetes-mcp-server/) — é o que o
  `uvx` resolve.
- [Guia de setup no Kubernetes](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/getting-started-kubernetes.md) —
  ServiceAccount dedicado e acesso somente leitura.
