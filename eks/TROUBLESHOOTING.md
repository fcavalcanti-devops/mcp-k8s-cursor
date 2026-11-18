# Troubleshooting — servidor MCP `eks`

Erros conhecidos e como resolver cada um. Cada bloco de comando diz onde roda:
**Windows** (PowerShell), **Linux** (bash) ou **Windows e Linux**, quando é
idêntico nos dois.

Antes de tudo, olhe os logs do servidor: no Cursor, abra o painel Output
(`Ctrl+Shift+U`) e escolha **MCP Logs** no seletor. Eles mostram a inicialização,
as chamadas de ferramenta e o erro exato quando o servidor cai
([documentação do Cursor](https://cursor.com/docs/context/mcp)).

Em seguida, rode o diagnóstico — ele cobre a maioria dos casos abaixo e aponta a
correção:

**Windows**

```powershell
.\scripts\Validate-McpEks.ps1
```

**Linux**

```bash
./scripts/validate-mcp-eks.sh
```

---

## Erros só do Windows

### `a execução de scripts foi desabilitada neste sistema`

Erro do PowerShell, não do MCP: a política de execução padrão do Windows é
`Restricted` e bloqueia qualquer `.ps1`. Libere para o seu usuário, sem precisar
de administrador:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

`RemoteSigned` roda scripts locais e exige assinatura só nos baixados da
internet. Se preferir não mudar nada, contorne a cada execução com
`powershell -ExecutionPolicy Bypass -File .\scripts\Validate-McpEks.ps1`.

Se o erro persistir depois disso, confira `Get-ExecutionPolicy -List`: uma
política de grupo em `MachinePolicy` ou `UserPolicy` tem precedência sobre a do
usuário e só o administrador do domínio pode mudá-la.

### O servidor não inicia

Sintoma: no painel de MCP o servidor fica vermelho e nenhuma ferramenta aparece.

Verifique se o entry point tem o sufixo `.exe`:

```json
"args": ["--from", "awslabs.eks-mcp-server@latest", "awslabs.eks-mcp-server.exe", "--allow-sensitive-data-access"]
```

Sem o `.exe` o `uvx` não localiza o executável no pacote e o processo morre no
start. Teste manualmente no terminal:

```powershell
uvx --from awslabs.eks-mcp-server@latest awslabs.eks-mcp-server.exe --help
```

---

## Erros só do Linux

### `Permission denied` ao rodar um `.sh`

O arquivo não tem permissão de execução — comum quando o repositório foi copiado
em vez de clonado:

```bash
chmod +x scripts/*.sh
```

### `/usr/bin/env: 'bash\r': No such file or directory`

O script ganhou fim de linha CRLF, geralmente ao passar por uma máquina Windows
ou por uma pasta sincronizada. O `.gitattributes` do repositório evita isso em
clones novos; para corrigir uma cópia existente:

```bash
sed -i 's/\r$//' scripts/*.sh
```

O mesmo problema aparece como erros sem sentido aparente, como
`ambiguous redirect` ou `syntax error near unexpected token`.

### O servidor não inicia

Sintoma: no painel de MCP o servidor fica vermelho e nenhuma ferramenta aparece.

Duas causas, nesta ordem:

1. **O entry point tem `.exe`.** No Linux o nome vai sem sufixo:

   ```json
   "args": ["--from", "awslabs.eks-mcp-server@latest", "awslabs.eks-mcp-server", "--allow-sensitive-data-access"]
   ```

2. **O Cursor não acha o `uvx`.** Se o MCP Logs disser que o comando não foi
   encontrado, use o caminho absoluto no `command`. Descubra qual é com
   `command -v uvx` — o instalador do `uv` costuma colocá-lo em
   `/home/<USER>/.local/bin/uvx`.

Teste manualmente no terminal:

```bash
uvx --from awslabs.eks-mcp-server@latest awslabs.eks-mcp-server --help
```

---

## O MCP para de responder depois de algumas horas

Sintoma: as ferramentas retornam erro de credencial, ou o servidor aparece sem
ferramentas no Cursor. É de longe a causa mais frequente com perfis SSO.

A sessão do IAM Identity Center expirou. Renove:

**Windows e Linux**

```shell
aws sso login --profile <PROFILE_NAME>
```

O servidor lê as credenciais a cada chamada, então normalmente não é preciso
reiniciar o Cursor — mas se continuar falhando, reinicie para forçar um processo
novo. Detalhes do fluxo em
[IAM Identity Center com o AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html).

---

## `get_pod_logs` ou `get_k8s_events` retornam erro de permissão da ferramenta

Falta a flag `--allow-sensitive-data-access` nos `args`. Essa flag é do servidor
MCP, não da AWS — o IAM pode estar perfeito e o servidor ainda assim recusar.

---

## O agente diz que não consegue aplicar YAML ou alterar recursos

Esperado: o servidor roda sem `--allow-write`. Para habilitar escrita, acrescente
`"--allow-write"` aos `args` e reinicie o Cursor.

Antes disso, confira qual política está associada à access entry do seu
principal. Com `AmazonEKSClusterAdminPolicy`, habilitar a flag dá ao agente poder
real de alterar o cluster. A AWS recomenda manter o modo somente leitura em
produção — veja a seção *Security Considerations* da
[documentação oficial](https://awslabs.github.io/mcp/servers/eks-mcp-server).

---

## `AccessDeniedException` ao chamar a API do EKS

O cluster aparece na lista (permissão IAM existe) mas o acesso aos recursos
Kubernetes é negado: falta a access entry do seu principal.

**Windows**

```powershell
.\scripts\Setup-EksAccess.ps1 -Cluster <CLUSTER_NAME>
```

**Linux**

```bash
./scripts/setup-eks-access.sh -c <CLUSTER_NAME>
```

Se o cluster estiver com `authenticationMode: CONFIG_MAP`, access entries não
valem — o acesso ainda depende do `aws-auth` ConfigMap e é preciso migrar. Veja
[EKS access entries](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html)
e [Associate access policies](https://docs.aws.amazon.com/eks/latest/userguide/access-policies.html).

Um detalhe que confunde no diagnóstico: `kubectl auth can-i --list` **não** mostra
as permissões vindas de access policies. Se o comando parecer dizer que você não
tem acesso, confie no `list-associated-access-policies` em vez dele.

---

## Timeout ao falar com o API server

Verifique primeiro se o endpoint do cluster é público:

**Windows**

```powershell
aws eks describe-cluster --name <CLUSTER_NAME> --region <REGION> `
  --query 'cluster.resourcesVpcConfig.{publico:endpointPublicAccess,cidrs:publicAccessCidrs}'
```

**Linux**

```bash
aws eks describe-cluster --name <CLUSTER_NAME> --region <REGION> \
  --query 'cluster.resourcesVpcConfig.{publico:endpointPublicAccess,cidrs:publicAccessCidrs}'
```

Com endpoint privado, a estação precisa de VPN, Direct Connect ou bastion na VPC.
Com endpoint público, timeout costuma ser rede local, proxy corporativo ou
inspeção TLS — e o servidor aceita `HTTP_PROXY` / `HTTPS_PROXY` no `env`.

Para isolar o problema fora do MCP:

**Windows e Linux**

```shell
aws eks update-kubeconfig --name <CLUSTER_NAME> --region <REGION> --profile <PROFILE_NAME>
kubectl get ns
```

Se o `kubectl` também falhar, o problema não é do MCP.

---

## O agente erra o cluster ou pergunta qual usar

O servidor não tem cluster padrão: toda chamada leva `cluster_name`. Diga o nome
explicitamente no pedido. Com muitos clusters, vale configurar um servidor por
ambiente no `mcp.json` (`eks-prod`, `eks-hml`) para reduzir a ambiguidade.

---

## Primeira execução muito lenta

O `uvx` resolve `awslabs.eks-mcp-server@latest` e baixa o pacote. Depois fica em
cache. Para forçar a atualização:

**Windows**

```powershell
uvx --refresh --from awslabs.eks-mcp-server@latest awslabs.eks-mcp-server.exe --help
```

**Linux**

```bash
uvx --refresh --from awslabs.eks-mcp-server@latest awslabs.eks-mcp-server --help
```

Para fugir do `@latest` e fixar uma versão, consulte as releases no
[PyPI](https://pypi.org/project/awslabs.eks-mcp-server/).

---

## Onde procurar o resto

A [documentação oficial do EKS MCP Server](https://awslabs.github.io/mcp/servers/eks-mcp-server)
lista todas as ferramentas, as flags e as permissões IAM exigidas por cada uma.
