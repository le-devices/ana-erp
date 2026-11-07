# 043 — Plano

- **Banco (migração 057).** `base.tax_id_norm` (só `0-9A-Z`, maiúsculas); `base.valid_cnpj` reescrita para o
  alfanumérico (valor de cada caractere = ASCII − 48, mesmos pesos; DV numérico); `base.valid_cpf` exige
  11 dígitos depois da normalização; `base.format_tax_id`, `base.person_kind`, `base.tax_id_root`.
  `base.valid_state_registration(uf, ie)`: formato por UF (tamanho e caracteres; "ISENTO"; produtor rural
  de SP com P). Colunas fiscais em `base.party` e `base.company`; CPF em `projects.employee`.
  Um gatilho genérico `base.fiscal_profile()` (parceiro e empresa) e um de CPF para colaboradores:
  validam só quando um campo fiscal muda (dados antigos intactos), formatam, mantêm o tipo de pessoa,
  recusam duplicado com o nome de quem já tem o documento (`DUPLICATE_TAX_ID`) e incoerências
  (`TAX_PROFILE_MISMATCH`, `INVALID_STATE_REGISTRATION`). Índice pela raiz do CNPJ para filiais.
- **Programas.** Biblioteca `util.tax_id` (consulta as funções do banco; `prefetch` em lote para a
  importação); `master.core` deixa de ter a cópia em Python e usa a biblioteca; `base.save_party` e a ficha
  do parceiro ganham os campos fiscais e a aba "Mesma raiz (filiais)"; `projects.save_employee` e a ficha do
  colaborador ganham CPF; `base.lookup_tax_id` consulta um conector configurado (opcional).
- **Empresa.** Tela Empresa ganha os campos fiscais; `ana_admin:save_company` devolve as mensagens do banco.
- **Decisão registrada.** Inscrição estadual: formato por UF agora; dígito verificador por UF fica para
  a T-043-02b (algoritmos de 27 UFs exigem vetores oficiais de teste para não recusar inscrição válida).
- **Testes.** Integração `TestFiscalRegistry` (CA-043-01..05) e desempenho (RNF-043-02); smoke do Estúdio.
