# 036 — Instalação pelo cliente: local (on-premise) e nuvem, com passos definidos

## Problema
Hoje o ERP sobe com o `docker-compose.yml` de desenvolvimento. Um cliente
precisa instalar sozinho, com passos claros, num servidor próprio ou na
nuvem, já seguro para produção (senhas e chaves geradas, HTTPS, backups,
verificações) e atualizar depois sem parada.

## Histórias
- **H1** Como técnico do cliente, sigo um guia e um instalador que conferem
  os pré-requisitos, geram segredos, sobem o ERP com HTTPS e me dão a senha
  inicial do administrador.
- **H2** Na nuvem, uso uma VM (qualquer provedor) ou Kubernetes, com banco
  gerenciado opcional.
- **H3** Atualizo para uma versão nova sem parar (dois nós), com backup
  antes e volta atrás se falhar.
- **H4** Confiro a instalação (diagnóstico) e desinstalo sem perder dados
  por engano.

## Requisitos funcionais
- **RF-036-01** Instalador (`install.sh`) não interativo ou guiado: confere
  sistema, Docker, portas, memória e disco; gera senhas, `ANA_MASTER_KEY`,
  cookie e senha inicial do admin (troca obrigatória no primeiro acesso);
  `ANA_INSTANCE=production`, `ANA_DEMO=false`; grava `.env` com permissão
  restrita.
- **RF-036-02** Composição de produção: proxy com HTTPS (certificado
  automático por domínio ou certificado do cliente), banco com
  arquivamento de WAL ligado, dois nós do ERP opcionais, limites de recursos,
  reinício automático.
- **RF-036-03** Backups agendados (cópia completa diária, teste de
  restauração mensal) registrados no ERP (spec 033).
- **RF-036-04** Atualização (`ana-ctl upgrade`): backup, nova imagem,
  migrações, troca nó a nó sem parada, conferência de saúde e volta atrás.
- **RF-036-05** Nuvem: guia para VM em qualquer provedor e manifesto
  Kubernetes (ou Helm) com banco gerenciado opcional.
- **RF-036-06** Diagnóstico (`ana-ctl doctor`) e desinstalação que preserva
  volumes salvo pedido explícito.
- **RF-036-07** Guia de instalação em português, passo a passo.

## Critérios de aceite
- **CA-036-01** Numa máquina limpa (contêiner de teste), `install.sh
  --domain … --non-interactive` termina com o ERP saudável, HTTPS, admin
  com senha gerada e troca obrigatória, sem nenhuma senha de exemplo (as
  verificações da spec 033 sem achados críticos de segredos).
- **CA-036-02** `ana-ctl upgrade` para uma imagem nova não derruba
  requisições em andamento.
- **CA-036-03** `ana-ctl uninstall` sem `--purge` mantém os dados.

## Decisões
- O cliente recebe um pacote (`make pacote`) e o instalador constrói a
  imagem localmente; Kubernetes usa uma imagem publicada no registro da
  empresa.
- Proxy Caddy: HTTPS automático por domínio, interno por IP, ou certificado
  da empresa; balanceia só para nós prontos (a atualização nó a nó não perde
  requisições).
- Banco gerenciado é opcional; as análises colunares (Citus) degradam para
  tabelas comuns.
- Achado durante a implementação: numa base nova o admin não era criado
  (o robô `system` já existia); corrigido no núcleo.
