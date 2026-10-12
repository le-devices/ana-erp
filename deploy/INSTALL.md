# Instalação do ANA ERP

Guia para o técnico do cliente. Escolha um caminho:

| Caminho | Quando usar |
|---------|-------------|
| **A. Servidor próprio (on-premise)** | servidor Linux na empresa, acesso pela rede interna ou pela internet |
| **B. Máquina virtual na nuvem** | qualquer provedor (AWS, Azure, Google Cloud, Oracle, Magalu, Locaweb…) |
| **C. Kubernetes** | a empresa já opera um cluster; banco PostgreSQL gerenciado |

Os caminhos A e B usam o mesmo instalador (`deploy/install.sh`) e a mesma
ferramenta de operação (`ana-ctl`).

## Requisitos

- Linux de 64 bits (Ubuntu 22.04/24.04, Debian 12, RHEL/Rocky/Alma 9 ou similar).
- Docker Engine 24 ou mais novo com o plugin `docker compose` (v2) —
  instalação: <https://docs.docker.com/engine/install/>.
- 2 vCPUs e 4 GB de memória (mínimo 2 GB); 50 GB de disco (mínimo 10 GB),
  de preferência SSD.
- Portas 80 e 443 livres no servidor (ou escolha outras).
- Para certificado automático: um nome (ex.: `erp.empresa.com.br`) apontando
  para o servidor e as portas 80/443 acessíveis pela internet.

## A. Servidor próprio (on-premise)

1. **Copie o pacote** do ANA para o servidor e descompacte:
   ```bash
   tar xzf ana-erp-<versão>.tar.gz && cd ana-erp-<versão>
   ```
2. **Rode o instalador** como root, escolhendo uma das formas de acesso:
   - com nome na internet e certificado automático:
     ```bash
     sudo ./deploy/install.sh --domain erp.empresa.com.br --email ti@empresa.com.br
     ```
   - só na rede interna, pelo IP (certificado interno):
     ```bash
     sudo ./deploy/install.sh --ip 192.168.0.10
     ```
   - com o certificado da própria empresa:
     ```bash
     sudo ./deploy/install.sh --domain erp.empresa.local --cert fullchain.pem --key privkey.pem
     ```
   O instalador confere os requisitos, **gera todas as senhas e chaves**
   (nenhuma senha de exemplo fica em uso), constrói a imagem, sobe banco,
   dois nós do ERP e o proxy HTTPS, faz a primeira cópia do banco e agenda as
   cópias diárias e o teste de restauração mensal.
3. **Anote a senha inicial** mostrada no fim. Entre em `https://<endereço>`
   com o usuário `admin`: o ERP pede a troca da senha no primeiro acesso.
4. **Guarde uma cópia de `/opt/ana-erp/.env`** em local seguro (cofre de
   senhas ou mídia off-line). Ele contém a chave mestra: sem ela os segredos
   dos conectores não podem ser lidos.
5. **Confira**:
   ```bash
   sudo /opt/ana-erp/ana-ctl doctor
   ```
6. **Endereço público**: o instalador grava `ANA_PUBLIC_URL` (usado nos
   links de download enviados a clientes) como valor inicial; depois, um
   administrador muda em Administração → Empresa → "Endereço público do ERP",
   sem reiniciar.
7. **Configure**: Administração → Empresa (dados e coordenadas), Usuários,
   Parâmetros; Administração → Verificações mostra o que ainda precisa de
   atenção.

Opções úteis do instalador: `--nodes 1` (um nó só; atualização com parada
curta), `--dir`, `--http-port`/`--https-port`, `--timezone`,
`--non-interactive` (automação). `./deploy/install.sh --help` lista todas.

Com certificado interno, os navegadores avisam até que a autoridade do proxy
seja instalada nas máquinas (`docker compose … cp proxy:/data/caddy/pki/authorities/local/root.crt .`)
ou até usar `--cert`.

## B. Máquina virtual na nuvem

1. Crie uma VM Linux (requisitos acima) com disco SSD; anexe um disco de
   dados se o provedor separar.
2. Libere no firewall do provedor (grupo de segurança) **apenas** as portas
   22 (de preferência só do IP da empresa/VPN), 80 e 443.
3. Aponte o nome (DNS) para o IP público da VM.
4. Instale o Docker e siga os passos do caminho A com `--domain` e `--email`.
5. Cópias fora da VM: copie periodicamente o volume `ana-erp_wal_archive`
   (ou o diretório de cópias) para armazenamento de objetos do provedor
   (S3, Blob, GCS) — uma cópia no mesmo disco não é cópia de segurança.

**Banco gerenciado (opcional)**: em vez do banco em contêiner, use o
PostgreSQL 15+ do provedor:
1. Crie a instância (com cópias automáticas e recuperação a um instante).
2. Como administrador do serviço, rode `deploy/initdb-managed.sql`:
   ```bash
   psql "host=<host> user=<admin> dbname=postgres sslmode=require" -v ana_password='<senha>' -f deploy/initdb-managed.sql
   ```
3. Instale apontando para ele:
   ```bash
   sudo ANA_DB_PASSWORD_MANAGED='<senha>' ./deploy/install.sh --domain erp.empresa.com.br --email ti@empresa.com.br --db-host <host>
   ```
   As análises colunares (extensão Citus) são opcionais: sem elas o ERP usa
   tabelas comuns.

## C. Kubernetes

1. Construa e publique a imagem no registro da empresa:
   ```bash
   docker build -t registry.empresa.com.br/ana-erp:<versão> .
   docker push registry.empresa.com.br/ana-erp:<versão>
   ```
2. Prepare o banco gerenciado (passo "Banco gerenciado" acima).
3. Edite `deploy/k8s/`: `kustomization.yaml` (imagem), `config.yaml` (banco,
   fuso, nome da instância), `secret.yaml` (senhas e chave mestra — gere os
   valores como indicado no arquivo), `files-pvc.yaml` (classe de
   armazenamento ReadWriteMany), `ingress.yaml` (nome e emissor de
   certificado).
4. Aplique e acompanhe:
   ```bash
   kubectl apply -k deploy/k8s
   kubectl -n ana-erp rollout status deploy/ana
   ```
5. Atualização sem parada: troque `newTag` no `kustomization.yaml` e aplique
   de novo (dois pods, `maxUnavailable: 0`, nó sai do balanceamento antes de
   parar).

## Operação (caminhos A e B)

| Comando | O que faz |
|---------|-----------|
| `ana-ctl status` | contêineres e prontidão de cada nó |
| `ana-ctl doctor` | diagnóstico completo (HTTPS, nós, disco, idade da última cópia, achados críticos das Verificações) |
| `ana-ctl backup` | cópia completa do banco agora (diária pelo agendamento) |
| `ana-ctl restore-test` | restaura a última cópia num contêiner descartável e confere (mensal pelo agendamento) |
| `ana-ctl upgrade --source <pacote novo>` | constrói a versão nova, faz cópia do banco e atualiza **nó a nó, sem parar**; se um nó não ficar pronto, volta à versão anterior |
| `ana-ctl rollback` | volta à versão anterior |
| `ana-ctl logs [ana1\|ana2\|db\|proxy]` | registros |
| `ana-ctl uninstall` | para tudo e **mantém os dados**; `ana-ctl up` volta |
| `ana-ctl uninstall --purge` | apaga também banco, arquivos e cópias (pede confirmação) |

**Atualizar para uma versão nova**:
```bash
tar xzf ana-erp-<nova>.tar.gz
sudo /opt/ana-erp/ana-ctl upgrade --source ./ana-erp-<nova>
```
As migrações do banco rodam no primeiro nó atualizado; programas do produto
alterados aparecem como "Atualizações do produto" para o administrador
aceitar (nada é sobrescrito sem aviso).

**Restaurar** (desastre): reinstale no mesmo diretório (o `.env` é mantido)
e restaure o volume de cópias; o procedimento de recuperação a um instante
está em `scripts/restore-test.sh` (o mesmo usado pelo teste mensal).

## Problemas comuns

| Sintoma | Verifique |
|---------|-----------|
| HTTPS não responde | `ana-ctl logs proxy`; portas 80/443 abertas; DNS apontando para o servidor |
| "certificado inválido" | certificado interno: instale a autoridade ou use `--cert`; automático: o nome precisa ser público |
| nó não fica pronto | `ana-ctl logs ana1`; memória livre; banco acessível |
| achado crítico em Verificações | siga a sugestão de cada achado (senha, chave, cópia, componente vulnerável) |
