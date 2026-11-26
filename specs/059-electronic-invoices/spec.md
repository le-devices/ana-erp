# 059 — Documentos fiscais eletrônicos: NF-e, NFC-e e NFS-e, homologados

Situação: especificada (nov/2026); revisada em 26/11/2026 com homologação, contingência, NFC-e e documentos de
entrada. Depende da spec 072 (canal com os órgãos de governo) e da spec 049 (motor de impostos; a fase 2 para ICMS
e IPI).

## Problema
No Brasil, vender exige emitir documento fiscal eletrônico:
- **NF-e** (modelo 55) para mercadorias entre empresas;
- **NFC-e** (modelo 65) para venda ao consumidor no balcão;
- **NFS-e** para serviços, com o padrão nacional substituindo os padrões
  municipais.

Sem isso, o ERP depende de outro sistema para faturar, o que quebra P17 (tudo
integrado) e é motivo de não compra. A reforma tributária ainda põe CBS, IBS e
o Imposto Seletivo nos mesmos documentos, com regras que mudam ano a ano até
2033.

Emitir não basta. A nota precisa:
- sair **certa na primeira vez**: cada rejeição atrasa o faturamento e a
  entrega;
- sair **mesmo com a SEFAZ fora do ar** (contingência);
- **conversar com o resto**: estoque, financeiro, contabilidade, expedição,
  livros fiscais e as obrigações da spec 075;
- ter a emissão **homologada**: testada nos ambientes oficiais em todos os
  cenários que a empresa usa, com evidência guardada.

Do outro lado, as notas recebidas de fornecedores precisam entrar sem
digitação. Hoje alguém confere item a item.

## Decisões
- **D1 — A nota nasce do documento.**
  - **Origem.** A fatura de venda, de serviço, de ordem de serviço e de projeto
    gera a nota. A devolução, a remessa (conserto, demonstração,
    industrialização) e a transferência entre filiais também.
  - **Dados.** Vêm do motor de impostos (spec 049, com a explicação), do
    cadastro fiscal (spec 043), dos itens (NCM, CEST, origem, unidade
    tributável) e da expedição (transportadora, volumes, peso).
  - **Fim da redigitação.** Nada é redigitado. O que faltar no cadastro aparece
    **antes** de faturar, como pendência com o link para corrigir.
- **D2 — Uma emissão, três modelos.** NF-e, NFC-e e NFS-e usam o mesmo fluxo:
  1. montar;
  2. validar (spec 072, D5);
  3. assinar e transmitir;
  4. receber o retorno;
  5. guardar e distribuir.

  Muda só o leiaute, que vem como pacote. A NFS-e segue o **padrão nacional**
  (Ambiente Nacional). Municípios fora dele entram por pacotes de conector
  (T-017-08b), um município por vez, por demanda de cliente.
- **D3 — Faturar e emitir são um passo só.**
  - **Ligar a política.** Com a emissão ligada para a operação, faturar
    **emite**.
  - **Autorizada.** A nota autorizada confirma a fatura: baixa de estoque,
    títulos, lançamento, expedição liberada.
  - **Rejeitada.** A fatura fica "aguardando autorização". Nada é baixado em
    duplicidade, e a pessoa vê o motivo com a correção ao lado.
  - **Mudança de estado.** Feita pelo banco na mesma transação do retorno,
    nunca por conciliação posterior (P17).
- **D4 — Eventos da nota.**
  - **Cancelamento.** Dentro do prazo legal, desfaz a fatura pelo caminho
    existente (spec 038: cancelar fatura) e devolve o estoque.
  - **Carta de correção.** Só para os campos que a lei permite. A tela não
    oferece o que a lei proíbe.
  - **Inutilização de numeração.** Automática para os buracos de numeração,
    com aviso.
  - **Manifestação do destinatário.** Para as notas recebidas (D8).
  - **Comprovante de entrega.** Quando a expedição registra a entrega
    (spec 015).
- **D5 — Contingência sem parar a venda.**
  - **Quando.** O estado dos serviços da spec 072 (D7) mostra a SEFAZ
    indisponível.
  - **Como.** A emissão entra na contingência prevista para o modelo (SVC,
    off-line da NFC-e, EPEC).
  - **Depois.** Transmite sozinha quando o serviço volta.
  - **Na tela.** Tudo isso é visível ("12 notas em contingência, transmitindo
    em 3 min") e auditado.
  - **Dentro do prazo.** O prazo legal da contingência é vigiado (spec 075,
    agenda).
- **D6 — Numeração e séries seguras.** O número é reservado no banco, na mesma
  transação da emissão, por série e estabelecimento. Nunca há número repetido
  nem buraco sem inutilização, inclusive com dois nós emitindo (spec 023).
- **D7 — Documentos e distribuição.**
  - **Guarda.** XML autorizado, DANFE, DANFE simplificado, DANFSE e DANFE da
    NFC-e (QR Code) vão para o repositório (spec 016) com a guarda legal da
    spec 072.
  - **Envio.** Por e-mail ao destinatário e à transportadora (spec 044), no
    portal do cliente (spec 037) e pela API pública (spec 010).
  - **Impressão.** O DANFE sai na expedição sem passo extra.
- **D8 — Notas de entrada sem digitação.**
  - **Chegada.** As notas emitidas contra o CNPJ da empresa chegam pela
    distribuição de documentos da SEFAZ (consulta automática pelo canal da
    spec 072). Também entram por XML recebido por e-mail ou enviado.
  - **Confronto.** Cada nota é confrontada com o pedido de compra e o
    recebimento (spec 038):
    - quantidade e preço dentro da tolerância;
    - impostos conferidos pelo motor (spec 049).
  - **Diferença.** Vira tarefa com o que divergiu.
  - **Manifestação.** A manifestação (ciência, confirmação, desconhecimento,
    não realizada) sai do resultado do confronto, com confirmação humana onde
    a lei pede.
  - **Itens.** O item do fornecedor é ligado ao item da empresa uma vez
    (catálogo de fornecimento) e lembrado.
- **D9 — Homologação por cenários (spec 072, D9).**
  - **Cenários.** A bateria da 059 cobre os cenários que a empresa usa, tirados
    da configuração dela:
    - regime e operações;
    - venda para contribuinte e não contribuinte, dentro e fora do estado;
    - com ST, DIFAL e FCP, quando houver;
    - serviço com retenções;
    - devolução, remessa, transferência;
    - cancelamento, carta de correção, inutilização, contingência;
    - NFC-e com e sem identificação do consumidor;
    - NFS-e com ISS retido e sem retenção.
  - **Onde roda.** Na homologação da SEFAZ e no ambiente de testes da NFS-e
    nacional.
  - **Produção.** Só é ligada depois da bateria aprovada (spec 072, D8).
  - **Atualizações.** Roda de novo a cada pacote de leiaute novo e a cada
    mudança de regra tributária que afete a nota (casos de teste da spec 049).
- **D10 — Reforma tributária nos documentos.**
  - **Campos.** Os campos de CBS, IBS e Imposto Seletivo (classificação
    tributária, bases, alíquotas, créditos) vêm do motor (spec 049, fase 3) e
    dos pacotes de leiaute com vigência.
  - **Mudança anual.** Um novo ano da transição não exige programa novo (P21).
- **D11 — Experiência premium (P18, P19).**
  - **Na fatura.** Mostra antes de emitir "vai sair assim": impostos com a
    explicação, natureza, CFOP e pendências.
  - **Erro de cadastro.** Abre o cadastro na hora, sem perder a fatura.
  - **Rejeição.** Vem com o motivo da SEFAZ traduzido para o que fazer. Um
    caso conhecido tem correção de um clique ("NCM vencido: trocar pelo
    sucessor 8542.31.90?").
  - **Painel "Notas".** Emitidas, em contingência, aguardando, rejeitadas,
    canceladas, recebidas a confrontar, com filtros e ações em lote.
  - **Correção em lote.** Corrigir o cadastro corrige todas as notas presas
    pelo mesmo motivo.
  - **Assistente (spec 052).** Pode explicar uma rejeição e ensaiar a
    correção.

## O que a pessoa deixa de fazer (P19)
- Redigitar a fatura em outro emissor.
- Ficar de olho na SEFAZ: contingência e retransmissão são sozinhas.
- Conferir à mão a nota do fornecedor contra o pedido.
- Mandar XML e DANFE por e-mail um a um.
- Lembrar de inutilizar buracos de numeração.

## Requisitos funcionais
- **RF-059-01** Nota gerada a partir dos documentos, com pendências de cadastro
  antes de faturar (D1).
- **RF-059-02** NF-e, NFC-e e NFS-e (padrão nacional) pelo mesmo fluxo, com
  leiaute em pacote (D2).
- **RF-059-03** Faturar e emitir num passo, com estados consistentes no banco
  (D3).
- **RF-059-04** Cancelamento, carta de correção, inutilização, manifestação e
  comprovante de entrega (D4).
- **RF-059-05** Contingência automática com retransmissão e prazo vigiado (D5).
- **RF-059-06** Numeração por série e estabelecimento, sem repetição nem buraco
  (D6).
- **RF-059-07** XML, DANFE, DANFSE e QR Code no repositório, e-mail, portal e
  API (D7).
- **RF-059-08** Notas de entrada pela distribuição da SEFAZ e por XML, com
  confronto, manifestação e ligação de itens (D8).
- **RF-059-09** Bateria de homologação dos cenários da empresa (D9).
- **RF-059-10** Campos da reforma tributária por pacote com vigência (D10).
- **RF-059-11** Prévia na fatura, rejeição explicada com correção, painel
  "Notas" e correção em lote (D11).

## Requisitos não funcionais
- **RNF-059-01 (desempenho).**
  - Da fatura à NF-e autorizada, sem contar o tempo de resposta da SEFAZ, a
    parte do ANA leva até 300 ms no p95 para 50 itens.
  - A NFC-e no balcão é autorizada ou entra em contingência em até 3 s no p95.
  - Faturamento em lote de 500 pedidos: as notas saem em paralelo, até o
    limite de vazão do órgão, sem segurar quem está usando o sistema.
- **RNF-059-02 (robustez).**
  - Nenhuma nota é autorizada sem que a fatura esteja confirmada, e nenhuma
    fatura é confirmada sem nota quando a emissão está ligada.
  - Uma queda do nó no meio da emissão é retomada pela consulta (spec 072).
  - A numeração é garantida pelo banco.
- **RNF-059-03 (escrita, P15).** A nota grava o XML uma vez, comprimido, e o
  estado só quando muda. As entradas no orçamento da spec 063 ficam no
  plan.md.
- **RNF-059-04 (correção).** As notas da bateria de homologação validam nos
  esquemas oficiais e são autorizadas nos ambientes de teste. Cada mudança de
  regra tributária roda os casos de teste da spec 049 antes de valer.

## Critérios de aceite
- **CA-059-01** Uma fatura de serviço gera NFS-e autorizada no ambiente de
  testes nacional, com o ISS e as retenções do motor, e o PDF chega ao cliente
  por e-mail e ao portal.
- **CA-059-02** Uma venda para contribuinte de outro estado com ST gera NF-e
  autorizada em homologação. Os valores de ICMS, ST e FCP batem com os casos
  de teste do motor, e o estoque e os títulos só mudam depois da autorização.
- **CA-059-03** Com a SEFAZ simulada fora do ar, a NFC-e sai em contingência
  em até 3 s, com o QR Code correto, e é transmitida sozinha quando o serviço
  volta.
- **CA-059-04** Uma nota rejeitada por cadastro (IE do cliente) mostra o
  motivo traduzido e o botão para o cadastro. Corrigido o cadastro, as 7 notas
  presas pelo mesmo motivo são reenviadas de uma vez.
- **CA-059-05** Uma nota do fornecedor com preço 3% acima do pedido
  (tolerância de 2%) vira tarefa para o comprador com a diferença. Dentro da
  tolerância, entra sozinha e confirma a operação.
- **CA-059-06** Dois nós emitindo ao mesmo tempo na mesma série não repetem
  número. Um número que falhou é inutilizado sozinho, com aviso.
- **CA-059-07** Ligar a produção da NF-e sem a bateria aprovada é recusado
  (spec 072, CA-072-04).
