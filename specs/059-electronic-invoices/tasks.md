# 059 — Tarefas

Depende da spec 072 (canal), da spec 049 (fase 2 para ICMS e IPI na NF-e; a NFS-e precisa só da fase 1) e de um
certificado A1 de teste. Começar pela NFS-e nacional: é o caso das empresas de serviço e o primeiro cliente.

Antes do código: plan.md com:
- o modelo dos documentos fiscais (cabeçalho, itens, eventos, numeração por série);
- o leiaute em pacote;
- as medições de desempenho e de escrita (RNF-059-01, RNF-059-03).

- [ ] T-059-01 Documento fiscal no banco: modelo, série e numeração sem repetição nem buraco, estados e eventos (RF-059-06, CA-059-06)
- [ ] T-059-02 NFS-e padrão nacional a partir das faturas de serviço, OS e projeto, com ISS e retenções do motor (RF-059-01, 02, CA-059-01)
- [ ] T-059-03 Faturar e emitir num passo: confirmação da fatura só com a nota autorizada, na mesma transação do retorno (RF-059-03, RNF-059-02)
- [ ] T-059-04 Pendências de cadastro antes de faturar e prévia "vai sair assim" na fatura (RF-059-01, RF-059-11)
- [ ] T-059-05 NF-e modelo 55: venda, devolução, remessa, transferência; ICMS, ST, DIFAL, FCP e IPI do motor (RF-059-02, CA-059-02)
- [ ] T-059-06 Eventos: cancelamento (desfaz a fatura), carta de correção, inutilização automática, comprovante de entrega (RF-059-04)
- [ ] T-059-07 Contingência (SVC, EPEC, off-line da NFC-e) com retransmissão e prazo vigiado (RF-059-05, CA-059-03)
- [ ] T-059-08 NFC-e modelo 65 no balcão, com QR Code e contingência off-line (RF-059-02, RNF-059-01)
- [ ] T-059-09 XML, DANFE, DANFSE e QR Code no repositório; e-mail, portal, API e impressão na expedição (RF-059-07)
- [ ] T-059-10 Notas de entrada: distribuição da SEFAZ e XML, confronto com pedido e recebimento, manifestação, ligação de itens (RF-059-08, CA-059-05)
- [ ] T-059-11 Bateria de homologação tirada da configuração da empresa, nos ambientes de teste (RF-059-09, RNF-059-04, CA-059-07)
- [ ] T-059-12 Campos da reforma tributária (CBS, IBS, IS) por pacote com vigência (RF-059-10)
- [ ] T-059-13 Painel "Notas", rejeição traduzida com correção, correção em lote, assistente; verificador da spec 050 (RF-059-11, CA-059-04)
- [ ] T-059-14 Uso simulado (spec 067): personas faturando com SEFAZ simulada instável, com oráculo de estados e numeração
