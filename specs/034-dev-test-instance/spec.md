# 034 — Ambiente de desenvolvimento e testes, transporte para produção e massa de testes

## Problema
Hoje o desenvolvedor altera programas direto na instalação em uso. Em
sistema de missão crítica, o que se desenvolve precisa ser testado numa
instância separada e levado à produção de forma controlada, segura e sem
parada; e os testes ficam melhores com dados parecidos com os reais, sem
expor dados pessoais.

## Histórias
- **H1** Como desenvolvedor, trabalho numa instância própria (desenvolvimento
  e testes), com o mesmo produto e versão da produção.
- **H2** Como desenvolvedor, monto um **pacote de transporte** com programas
  (e versões), agendamentos, parâmetros, comandos e migrações de dados de
  negócio, e o envio para revisão.
- **H3** Como administrador da produção, vejo o pacote (diferenças lado a
  lado, autor, testes executados), aprovo e importo; a importação é atômica,
  não para o sistema e pode ser desfeita.
- **H4** Como desenvolvedor, peço uma **cópia dos dados de produção** para a
  instância de testes, com dados pessoais mascarados, completa ou por
  recorte (período, empresas).

## Requisitos funcionais
- **RF-034-01** Papel da instância (`production` | `test` | `development`)
  definido na instalação; faixa colorida e título indicam a instância; a de
  produção recusa edição direta de programas quando a política exigir
  transporte.
- **RF-034-02** Pacote de transporte: manifesto (itens, versões de origem,
  hash de cada item, versão do produto exigida, autor, testes e resultado),
  assinado com chave da instância de origem (Ed25519); a produção só aceita
  pacotes de origens cadastradas.
- **RF-034-03** Envio por arquivo (download/upload) ou por sistema remoto
  cadastrado (spec 007/017), sempre conferindo assinatura e hashes.
- **RF-034-04** Importação: verificação prévia (conflitos com versões
  alteradas na produção, dependências, versão do produto, lint), aplicação
  numa transação, programas novos entram como versão nova (spec 005) e o
  cache dos nós é trocado sem parada (P16); desfazer volta às versões
  anteriores com um clique.
- **RF-034-05** Fila de pacotes com estados (rascunho, enviado, aprovado,
  importado, recusado, desfeito), aprovação por quem não é o autor (quatro
  olhos, configurável) e trilha completa (spec 024).
- **RF-034-06** Cópia de dados produção → testes: exportação por esquema de
  negócio em lotes, transmitida cifrada; regras de mascaramento por coluna
  (nome, documento, e-mail, telefone, endereço, coordenadas, texto livre)
  determinísticas por chave da cópia (mantém junções e duplicidades), com
  catálogo padrão e ajustes por instalação; tabelas do sistema, cofre,
  senhas e chaves **nunca** são copiadas.
- **RF-034-07** A instância de testes não envia nada para fora (conectores
  em modo simulado, e-mails retidos) depois de receber dados copiados.

## Critérios de aceite
- **CA-034-01** Pacote com dois programas alterados importado na produção
  vira versão nova de cada um, sem reinício, e execuções em andamento
  terminam na versão antiga.
- **CA-034-02** Pacote com hash adulterado ou assinatura de origem não
  cadastrada é recusado sem aplicar nada.
- **CA-034-03** Pacote em conflito (programa alterado na produção depois da
  origem) aparece na verificação prévia e só segue com decisão explícita.
- **CA-034-04** Desfazer um pacote restaura as versões anteriores.
- **CA-034-05** Cópia mascarada: nenhum nome, documento, e-mail ou telefone
  da origem aparece no destino; o mesmo cliente mascarado é o mesmo em
  todas as tabelas; contagens e totais conferem.
- **CA-034-06** Depois da cópia, conectores da instância de testes não
  fazem chamadas externas.

## Decisões
- Uma instância por papel (sem misturar dados de produção e testes no mesmo
  banco); a instância de desenvolvimento usa a mesma imagem e versão.
- Transporte leva definições, nunca dados de negócio; dados só pelo caminho
  da cópia mascarada (liga com a decisão 4 da spec 009 — licença por
  instância).
- Máscara aplicada **na origem**: o arquivo que sai da produção já não tem
  dado pessoal; a chave da cópia (mostrada uma vez) só cifra o arquivo e
  torna as máscaras determinísticas dentro daquela cópia.
- A produção recusa receber cópias; a importação tem **ensaio** (carga
  completa, conferência e desfeita ao final) — é o caminho dos testes
  automatizados, que usam a mesma instância como origem e destino.
- Ciclos de chaves estrangeiras entre tabelas são quebrados numa coluna que
  aceita vazio, preenchida no fim da carga (ex.: linha de base ↔ mudança de
  escopo).
