# 072 — Tarefas

Antes do código: plan.md com:
- a biblioteca de assinatura XML (XMLDSig) e a conexão autenticada no núcleo
  Erlang (`public_key`, `ssl`), medindo a assinatura de uma NF-e de 50 itens
  (RNF-072-03);
- o formato dos pacotes de leiaute;
- a lista inicial de serviços: SEFAZ de SP e serviços nacionais, NFS-e
  nacional, eSocial e EFD-Reinf.

- [ ] T-072-01 Certificado A1 no cofre: carga, conferência de CNPJ, validade e cadeia; vários por CNPJ e obrigação; leitura negada a programas (RF-072-02, RNF-072-01, CA-072-05)
- [ ] T-072-02 Vigilância de validade com tarefas e teste do certificado novo antes da troca (RF-072-03, CA-072-02)
- [ ] T-072-03 Assinatura XML e conexão autenticada no núcleo, com medição de desempenho (RF-072-01, RNF-072-01, RNF-072-03)
- [ ] T-072-04 Pacotes de leiaute (XSD, regras, códigos, endereços) com vigência, pela atualização do produto (RF-072-04, CA-072-06)
- [ ] T-072-05 Validação local em esquema e regras, com mensagem em português que aponta o cadastro ou o documento de origem (RF-072-05, CA-072-03)
- [ ] T-072-06 Transmissão pela fila de saída: idempotência, consulta antes de repetir, ordem, limite de vazão, retomada em outro nó (RF-072-06, RNF-072-02, CA-072-01)
- [ ] T-072-07 Estado dos serviços do governo em memória, com espera e prazo visível (RF-072-07, RNF-072-03)
- [ ] T-072-08 Ambientes por obrigação; produção com quatro olhos e só depois da bateria (RF-072-08, CA-072-04)
- [ ] T-072-09 Bateria de homologação: cenários, evidências, relatório e nova rodada a cada pacote (RF-072-09, CA-072-06)
- [ ] T-072-10 Guarda legal imutável com hash, retenção legal e busca (RF-072-10, RNF-072-04)
- [ ] T-072-11 Painel "Governo", rejeição como tarefa com ação e sugestões; verificador da spec 050 (RF-072-11)
- [ ] T-072-12 Simulador local dos serviços do governo para a bateria do CI (respostas oficiais gravadas: autorizado, rejeitado, fora do ar, resposta perdida), sem rede externa
