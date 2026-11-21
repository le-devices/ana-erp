# 047 — Acesso emergencial e depuração em produção

Situação: especificada (nov/2026).

## Problema
O depurador (spec 004) serve o desenvolvedor que roda o próprio programa, e
termina sempre desfazendo o que foi gravado. Em produção o problema real
acontece com **outro usuário**, com dados reais, às vezes fora do horário:
é preciso ver exatamente o que aconteceu (dono, programa, parâmetros, pilha,
SQL, chamadas externas), reproduzir passo a passo e, em casos raros, intervir
— sem dar privilégio permanente a ninguém e com tudo registrado para revisão.

## Decisões
- **D1 — Acesso emergencial.** Perfil temporário (ex.: "depuração em produção",
  "correção de dados") pedido com **motivo**, referência (chamado) e prazo
  (máximo configurável, padrão 4 h). Concedido por um **aprovador** de um
  grupo definido — nunca pela própria pessoa. Exceção configurável: **uso
  imediato com revisão obrigatória depois** (para plantão fora do horário),
  que avisa os aprovadores na hora e deixa a revisão pendente até alguém
  revisar.
- **D2 — Tudo registrado.** Durante o acesso, cada execução, comando de
  depuração, avaliação de expressão, SQL e alteração de dado fica ligado à
  sessão emergencial; ao fim (prazo, devolução ou revogação), um relatório da
  sessão vai ao aprovador (Estúdio e e-mail, spec 044), que marca revisado
  com comentário. Sessões não revisadas aparecem nas Verificações (spec 033).
- **D3 — Revogação automática.** Ao vencer o prazo o perfil some em todos os
  nós em até 5 s; depurações abertas pelo acesso são encerradas com
  ROLLBACK.
- **D4 — Depuração por reexecução (padrão em produção).** A partir de uma
  execução registrada (erro, lentidão, resultado estranho), "Depurar
  reexecução" roda o mesmo programa, na mesma versão, com os mesmos
  parâmetros e como o mesmo usuário (permissões e escopo de dados dele), em
  modo depuração e **sempre com ROLLBACK**; chamadas externas ficam
  bloqueadas ou simuladas. O usuário original não percebe nada. Exige
  permissão de depuração em produção (via acesso emergencial ou papel).
- **D5 — Ponto de parada para outro usuário (ao vivo).** Só com acesso
  emergencial ativo: marcar ponto de parada para "usuário X + programa Y"
  (com expiração curta, padrão 15 min); a próxima execução real dele pausa e
  abre a sessão para quem depura. Enquanto pausada, a execução segura
  transação e travas: aviso visível, tempo máximo curto, e ao fim **segue a
  regra normal** (a execução do usuário continua e confirma, salvo se quem
  depura escolher interromper, o que desfaz). Alterar variável numa execução
  real exige perfil "correção de dados" e fica destacado no relatório.
- **D6 — O que a sessão mostra.** Usuário dono da execução, dono do programa,
  programa e versão, parâmetros (sensíveis mascarados), origem (tela, API,
  agendamento, esteira), pilha, variáveis, rastro completo (linha do tempo de
  SQL com tempos e linhas, chamadas externas, arquivos, execuções filhas,
  eventos), consumo até o ponto.
- **D7 — Ferramentas.** Além do que a spec 004 já tem (pontos, passo, entrar,
  sair, avaliar, parar): pontos de parada **condicionais** (expressão),
  por **contagem** (na N-ésima vez), **pontos de registro** (registram uma
  expressão sem parar — úteis em produção), parar em **exceção** (qualquer
  ou por tipo), **observar** variável (para quando muda), e salvar o estado
  da sessão (pontos, observações) como variante para reutilizar.

## Requisitos funcionais
- **RF-047-01** Perfis emergenciais configuráveis (o que concedem, prazo
  máximo, grupo aprovador, uso imediato permitido ou não) (D1).
- **RF-047-02** Pedir, aprovar, recusar, devolver e revogar acesso, com motivo
  e prazo; notificação ao aprovador e ao pedinte (D1).
- **RF-047-03** Registro ligado à sessão, relatório ao fim e revisão
  obrigatória (D2); pendências nas Verificações.
- **RF-047-04** Revogação automática no cluster (D3).
- **RF-047-05** Depurar reexecução a partir de qualquer execução registrada,
  com bloqueio de chamadas externas e ROLLBACK forçado (D4).
- **RF-047-06** Ponto de parada para outro usuário ao vivo (D5), com aviso,
  tempo máximo, interrupção opcional e destaque de alterações.
- **RF-047-07** Visão da sessão (D6) e ferramentas (D7) no Estúdio.
- **RF-047-08** Diagnósticos (spec 046) oferecem "Depurar reexecução" a
  partir de um grupo de erro.

## Requisitos não funcionais
- **RNF-047-01** Segurança: ninguém aprova o próprio pedido; o acesso não se
  renova sozinho; o relatório não pode ser alterado (somente acrescentar
  revisão); segredos e campos sensíveis seguem mascarados mesmo na sessão.
- **RNF-047-02** Pontos de registro e condicionais com custo desprezível
  quando a condição é falsa; sem ponto ativo, custo zero (RNF-004-05).
- **RNF-047-03** Reexecução nunca grava (testado como CA) e nunca chama
  sistema externo sem confirmação explícita por chamada.
- **RNF-047-04** No máximo N sessões ao vivo simultâneas (parâmetro, padrão 2)
  — cada uma segura transação.

## Critérios de aceite
- **CA-047-01** Pedido de acesso sem aprovador fica pendente; o próprio pedinte
  não consegue aprovar; aprovado, vale até o prazo e some sozinho.
- **CA-047-02** Uso imediato (quando permitido) avisa os aprovadores na hora
  e deixa revisão pendente nas Verificações até ser revisado.
- **CA-047-03** Reexecução de uma execução com erro para na exceção com a
  mesma pilha; nada é gravado; chamada externa é bloqueada.
- **CA-047-04** Ponto de parada para o usuário X pausa a próxima execução dele
  do programa Y; ao continuar, a execução dele termina normalmente; ao
  interromper, nada fica gravado.
- **CA-047-05** Ponto condicional `total > 1000` só para quando a condição
  vale; ponto de registro grava o valor sem pausar.
- **CA-047-06** O relatório da sessão lista cada comando e alteração, e é
  enviado ao aprovador ao fim.

## Experiência e automação (P18, P19)
- Pedir e aprovar acesso emergencial em até 3 toques, inclusive pelo celular
  com notificação (spec 060).
- "Depurar reexecução" a um clique a partir de qualquer erro (execução,
  diagnóstico, chamado de suporte — specs 046 e 057).
- Revogação, relatório e cobrança de revisão são automáticos; a pessoa só
  revisa.
