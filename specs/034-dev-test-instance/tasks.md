# 034 — Tarefas: Instância de desenvolvimento e testes, transporte e massa de testes

- [x] T-034-01 Migração `030_transports.sql`; papel da instância (`ANA_INSTANCE`), faixa na tela e `transport_required` (RF-034-01)
- [x] T-034-02 Chave Ed25519 da instância no cofre, origens cadastradas, pacote assinado com programas, comandos e parâmetros (RF-034-02, RF-034-03, CA-034-02)
- [x] T-034-03 Recebimento com verificação prévia (conflitos, dependências), importação atômica sem parada, quatro olhos, recusa e desfazer (RF-034-04, RF-034-05, CA-034-01, CA-034-03, CA-034-04)
- [x] T-034-04 Cópia mascarada: exportação consistente e cifrada, máscaras determinísticas com catálogo e ajustes, importação em transação com ensaio, ciclos de chaves e conferência (RF-034-06, CA-034-05)
- [x] T-034-05 Bloqueio de chamadas externas e conectores desligados após a carga (RF-034-07, CA-034-06)
- [x] T-034-06 Telas Transportes e Cópia de dados para testes; testes
- [ ] T-034-07b Agendamentos e migrações de dados de negócio dentro do pacote
- [ ] T-034-08b Envio do pacote e da cópia por sistema remoto/conector (hoje: arquivo)
- [ ] T-034-09b Teste automatizado de importação real numa segunda instância (hoje: ensaio com rollback na mesma instância)
