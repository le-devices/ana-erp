# 009 — Licenciamento e distribuição (RASCUNHO — decisões pendentes)

> Status: **rascunho**. Nada desta spec está implementado. As decisões abaixo
> precisam do dono do produto antes de virar plano e tarefas.

## Problema
O ANA será vendido a vários clientes. Cada um precisa de seus dados isolados,
dos módulos que contratou, de atualizações do produto sem perder as próprias
customizações — e o fornecedor precisa controlar o que foi licenciado.

## Decisão 1 — Modelo de implantação
| Opção | Prós | Contras |
|-------|------|---------|
| **A. Uma instância por cliente** (banco próprio; nuvem gerenciada ou local) | isolamento total, backup/restauração por cliente, customização livre, falha não afeta outros, atende quem exige dados locais | mais instâncias para operar (mitigável com automação) |
| B. Multi-inquilino (vários clientes no mesmo banco, coluna de inquilino + RLS) | menor custo por cliente | customização em Python por cliente fica arriscada, vazamento entre clientes vira risco central, atualizações afetam todos ao mesmo tempo |

**Recomendação: A.** Combina com o princípio P5 (programas customizáveis no
próprio ERP) e com segurança em profundidade (P10). Um cliente com várias
empresas (filiais, CNPJs) é tratado dentro da sua instância (`base.company`).

## Decisão 2 — Licença
Proposta: arquivo de licença assinado pelo fornecedor (Ed25519), verificado
pelo núcleo na partida e periodicamente, contendo cliente, módulos, limites
(usuários nomeados, execuções simultâneas), validade e versão máxima do
produto. Sem chamada obrigatória à internet (funciona em rede isolada).
- Ao expirar: **modo restrito** (leitura, relatórios e exportação continuam;
  gravações de módulos licenciados ficam bloqueadas) — nunca sequestro de dados.
- Módulo não licenciado: programas do módulo não executam (`NOT_LICENSED`);
  tabelas continuam legíveis.

## Decisão 3 — Camadas de programas
- **Produto**: programas entregues pelo fornecedor (namespaces reservados,
  ex. `sales.*`, `projects.*`), com assinatura de conteúdo.
- **Cliente**: programas novos do cliente (namespace livre, ex. `cli.*`) e
  **customizações** de programas do produto.
- Atualização do produto: se o cliente **não** alterou o programa, recebe a
  nova versão; se alterou, a nova versão fica disponível para comparação e
  adoção manual no Estúdio (diff + mesclar). Nada é sobrescrito em silêncio.
- Pontos de extensão (ganchos) em programas do produto, para que o cliente
  customize sem copiar o programa inteiro (ex.: `before_invoice`).

## Decisão 4 — Transporte entre ambientes
Pacote exportável (programas + migrações do cliente + parâmetros) para levar
customizações de desenvolvimento/homologação para produção, com registro de
quem importou o quê.

## Outros itens a especificar
- Perfis de acesso de negócio (além de admin/desenvolvedor/usuário):
  permissões por programa e por dado (ex.: só os próprios projetos).
- Marca do cliente no Estúdio (nome, logotipo).
- Internacionalização (idioma, moeda, fuso) se houver clientes fora do Brasil.
- Telemetria opcional e consentida para suporte.
- **Atualização dos programas do produto em instalações existentes** (ligado à
  Decisão 3): hoje as sementes só criam programas que não existem, para nunca
  sobrescrever customizações; por isso melhorias do produto (ex.: campos de
  escolha e consultas nos formulários, out/2026) não chegam a quem já tem o
  programa. Opções: (a) programa do produto não editável + cópia do cliente
  com outro nome; (b) atualizar quando o cliente não alterou (comparar com a
  versão semeada) e avisar quando alterou, com comparação lado a lado;
  (c) camadas com herança/sobreposição de funções.
  **Decidido (out/2026): oferecer e o administrador aceita** — implementado na
  [spec 028](../028-product-updates/spec.md).
