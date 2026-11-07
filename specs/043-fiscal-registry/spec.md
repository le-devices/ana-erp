# 043 — Cadastro fiscal de pessoas (CNPJ alfanumérico, CPF, inscrições e regime)

Situação: implementada (nov/2026), exceto o dígito verificador da inscrição estadual por UF (T-043-02b).

Decisões de implementação: a regra está no banco (migração 057): `base.valid_cnpj` aceita o CNPJ
alfanumérico, `base.fiscal_profile()` vale para parceiros e empresa (formata, mantém o tipo de pessoa,
recusa duplicado dizendo quem tem o documento e incoerências fiscais) e `base.employee_tax_id()` para o CPF
dos colaboradores; só valida quando um campo fiscal muda. A biblioteca `util.tax_id` pergunta ao banco (a
cópia em Python do `master.core` saiu) e a importação confere o arquivo inteiro numa consulta. A ficha do
parceiro ganhou os dados fiscais e a aba "Mesma raiz (filiais)"; a tela Empresa, os dados fiscais. A
consulta de CNPJ (`base.lookup_tax_id`) usa um conector HTTP com `options.purpose = "tax_id_lookup"`
(endereço e mapeamento de campos nas opções); sem ele, o botão não aparece.

## Problema
Clientes, fornecedores e transportadoras já têm CNPJ/CPF validado pelo dígito
verificador e formatado no banco (spec 040). Mas:
- desde julho/2026 a Receita Federal emite **CNPJ alfanumérico** (12
  caracteres com letras e números + 2 dígitos verificadores); o validador
  atual só aceita números e **recusa esses CNPJs** — uma empresa aberta agora
  não entra no cadastro;
- não há tipo de pessoa (física/jurídica), inscrição estadual (com isento e
  não contribuinte), inscrição municipal, nem regime tributário — dados que
  o motor de impostos (spec 049) precisa para decidir alíquotas, retenções e
  substituição tributária;
- a empresa da instalação, técnicos e contatos não seguem a mesma regra.

## Decisões
- **D1 — Uma regra só, no banco.** Validação e formatação de CNPJ (numérico e
  alfanumérico) e CPF em funções do banco, usadas por gatilho em toda tabela
  que guarda documento: vale para tela, API, importação e esteiras (P17).
- **D2 — CNPJ alfanumérico.** As 12 primeiras posições aceitam `0-9A-Z`; cada
  caractere vale o código ASCII − 48 no módulo 11, com os mesmos pesos; os 2
  dígitos verificadores continuam numéricos. Guardado em maiúsculas,
  formatado `AA.AAA.AAA/AAAA-99`. CNPJs numéricos antigos continuam válidos
  sem mudança.
- **D3 — Tipo de pessoa derivado.** 11 dígitos = física; 14 posições =
  jurídica; estrangeiro sem documento brasileiro é tipo próprio (com
  identificação livre e país).
- **D4 — Dados fiscais do parceiro:** inscrição estadual (por UF, com
  validação do formato por estado quando houver; "ISENTO"), indicador de
  contribuinte do ICMS (contribuinte, isento, não contribuinte), inscrição
  municipal, regime tributário (Simples Nacional, Simples com excesso de
  sublimite, Lucro Presumido, Lucro Real, MEI, órgão público, sem fins
  lucrativos) e se é consumidor final. Mesmos dados para a empresa da
  instalação.
- **D5 — Duplicidade.** O mesmo CNPJ/CPF não se repete entre parceiros
  (ativos ou inativos — reative o cadastro antigo em vez de criar outro; a
  mensagem diz qual é); filiais (mesma raiz de CNPJ, ordem diferente) são
  permitidas e a ficha mostra as outras da mesma raiz.
- **D4a — Inscrição estadual (decisão da implementação).** Agora: formato
  por UF (tamanho e caracteres, "ISENTO", produtor rural de SP) e coerência
  com o indicador do ICMS. O dígito verificador por UF fica para a
  T-043-02b: os algoritmos das 27 UFs precisam de vetores oficiais de teste
  para não recusar inscrição válida.
- **D6 — Consulta opcional.** Com um conector configurado (spec 017), a ficha
  oferece "Buscar dados do CNPJ" (razão social, endereço, situação
  cadastral, CNAE); nunca obrigatório, nunca sem conector.

## Requisitos funcionais
- **RF-043-01** Validação e formatação de CNPJ alfanumérico (D2) e CPF em todas
  as tabelas com documento (parceiros, empresa, transportadoras, técnicos,
  contatos), por gatilho; mensagem `INVALID_TAX_ID` com o motivo.
- **RF-043-02** Tipo de pessoa (D3) mantido pelo banco a partir do documento.
- **RF-043-03** Dados fiscais (D4) na ficha do parceiro e da empresa, com
  validação de inscrição estadual por UF e coerência (não contribuinte sem
  inscrição; MEI só pessoa jurídica).
- **RF-043-04** Duplicidade e filiais (D5).
- **RF-043-05** Consulta por conector (D6), preenchendo só campos vazios ou
  mostrando a diferença para confirmar.
- **RF-043-06** Biblioteca `util.tax_id` para programas (validar, formatar,
  tipo, raiz) — a mesma regra do banco, sem cópia da lógica.

## Requisitos não funcionais
- **RNF-043-01** Migração sem parada: documentos existentes não são
  revalidados (só quando mudam).
- **RNF-043-02** Validação no banco abaixo de 50 µs por linha (importação de
  100 mil parceiros sem gargalo).

## Critérios de aceite
- **CA-043-01** `12.ABC.345/01DE-35` (exemplo oficial) é aceito e formatado;
  trocar um caractere é recusado; CNPJ numérico antigo segue aceito.
- **CA-043-02** O mesmo CNPJ alfanumérico entra pela tela, pela API pública e
  pela importação de cadastros com o mesmo resultado.
- **CA-043-03** Parceiro "não contribuinte" com inscrição estadual é recusado;
  inscrição estadual com formato errado para a UF é recusada; regime
  tributário em pessoa física é recusado.
- **CA-043-04** Segundo parceiro com o mesmo documento é recusado dizendo qual cadastro já o tem;
  filial da mesma raiz é aceita e aparece na ficha da matriz.
- **CA-043-05** Sem conector configurado, "Buscar dados do CNPJ" não aparece.
