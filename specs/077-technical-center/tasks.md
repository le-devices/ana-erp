# 077 — Tarefas

Antes do código: plan.md com:
- a **matriz de falhas**: para cada falha (banco, disco, Python, aplicação principal, memória, rede, nó, servidor),
  o que cada camada consegue ver e fazer, e qual roteiro atende;
- o **modelo de ameaças** do socorro e do `ana-ctl`: quem pode alcançar a porta, o que um guardião sozinho
  consegue, o que acontece com o arquivo de chaves copiado, como se evita repetir uma confirmação antiga;
- o desenho da árvore OTP: o socorro como aplicação permanente que sobe antes; o reinício controlado da aplicação
  principal, com limite e recuo; os limites de memória e de processos do socorro;
- o inventário dos parâmetros técnicos de hoje (configuração, variáveis de ambiente, tabelas), com escopo, quando
  vale e risco; e o inventário das seções atuais da Administração, com o lugar de cada uma na Central;
- as medições de referência: abertura da aba Agora, resposta do socorro com o banco fora, escrita ociosa
  (RNF-077-03, RNF-077-04).

## Fase 1 — Central técnica, ações e configuração
- [x] T-077-01 Catálogo de ações técnicas como dado (parâmetros, pré-condições, efeito, impacto, risco, ensaio, desfazer, sucesso), com as ações atuais da Administração migradas para ele; teste que recusa ação sem esses campos (RF-077-04, D5)
- [x] T-077-02 Risco e permissão: cerimônia por classe, endurecimento por empresa, permissão por grupo e por ação, "agir agora e revisar depois"; recusa também pela API (RF-077-05, RNF-077-02, CA-077-04)
- [x] T-077-03 Central técnica: abas Agora, Rotina, Capacidade, Mudanças, Segurança técnica e Registro, a partir das fontes existentes; item com o quê, por quê, efeito e ação; três camadas; paleta de comandos; verificador da spec 050 (RF-077-01..03, RNF-077-03, RNF-077-05, CA-077-01)
- [x] T-077-04 Catálogo de parâmetros técnicos com escopo e origem do valor; alterados primeiro, motivo, ensaio, mudança temporária, versões, comparação entre ambientes, transporte e exportação (RF-077-08, CA-077-05, CA-077-06)
- [x] T-077-05 Console de diagnóstico: consultas prontas, SQL somente leitura com limites e mascaramento, introspecção do núcleo, registros filtráveis, consultas salvas (RF-077-06, CA-077-09)
- [x] T-077-06 Roteiros como dado e o executor (passo a passo, até a próxima decisão, pausa, retomada, entrega a outra pessoa); roteiros do produto: disco cheio, banco fora, réplica atrasada, nó que não sobe, laço de quedas, certificado vencido, fila parada; ligação com os alertas (RF-077-07, CA-077-01)
- [x] T-077-07 Modos somente leitura e manutenção, entrada de integrações pausada, rotinas suspensas, faixa nas telas, no portal e na API, e volta ordenada (RF-077-13, CA-077-08)

## Fase 2 — Modo de socorro
- [ ] T-077-08 Aplicação `ana_rescue`: árvore própria, porta própria com HTTPS no endereço configurado, medições locais, última fotografia da saúde gravada só quando muda, anel de registros em memória; página mínima (RF-077-09, RNF-077-01, RNF-077-03, RNF-077-04)
- [ ] T-077-09 Reinício controlado da aplicação principal, com limite, recuo e motivo da queda; laço de quedas não derruba a máquina virtual (RF-077-10, CA-077-03)
- [ ] T-077-10 Guardiões: cadastro de chave de acesso (e código de uso único como alternativa sinalizada), cópia local por nó, segundo guardião, bloqueio progressivo, avisos, giro e remoção (RF-077-11, RNF-077-02, CA-077-04, CA-077-12)
- [ ] T-077-11 Registro local encadeado, conferência e envio à auditoria quando o banco volta; alerta e pendência quando a cadeia falha (RF-077-12, CA-077-02, CA-077-07)
- [ ] T-077-12 Ações e roteiros disponíveis no socorro; pacote de diagnóstico do socorro (RF-077-09, RF-077-16, CA-077-02)
- [ ] T-077-13 Testes de caos do socorro: banco parado, disco cheio, Python parado, laço de quedas, memória alta; medição no orçamento da spec 063 (RNF-077-01, RNF-077-04)

## Fase 3 — Servidor, treino e parceiros
- [ ] T-077-14 `ana-ctl rescue`: os mesmos roteiros e o mesmo formato de registro, confirmação de guardião para risco alto (RF-077-14, CA-077-11)
- [ ] T-077-15 Ensaio de roteiros com falha provocada no ambiente de teste e simulado de crise agendado, com resultado na aba Rotina; teste de restauração na mesma rotina (RF-077-15, CA-077-10)
- [ ] T-077-16 Suporte e parceiro: acesso com consentimento, prazo e escopo; guardião do parceiro; depende das specs 047 e 057 (RF-077-16)
- [ ] T-077-17 Sugestões de regra a partir de ações técnicas repetidas à mão (spec 051)
