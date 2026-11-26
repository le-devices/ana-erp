# 072 — Canal com os órgãos de governo: certificado, assinatura, transmissão e protocolo

Situação: especificada (nov/2026). É a base das specs 059 (documentos fiscais), 074 (eSocial) e 075 (obrigações
acessórias).

## Problema
Emitir nota, enviar eventos do eSocial ou entregar a EFD-Reinf são, no fundo, a
mesma coisa:
1. montar um documento no leiaute oficial;
2. validá-lo;
3. assiná-lo com o certificado digital da empresa;
4. transmiti-lo a um serviço do governo;
5. guardar o protocolo e o retorno.

Cada órgão tem o seu jeito:
- SEFAZ de cada estado, com serviços próprios e contingências;
- Ambiente Nacional da NFS-e;
- eSocial e EFD-Reinf, com envio em lote e consulta posterior;
- Receita Federal, com programas validadores dos arquivos SPED.

Feito uma vez para cada caso, isso repete código, espalha o certificado e
multiplica os pontos de falha.

Os riscos são concretos:
- **Certificado.** Um certificado vencido para a empresa inteira. Um certificado
  copiado é uma assinatura falsificável.
- **Rede.** O serviço do governo fica fora do ar em horário de pico (fim de mês,
  véspera de prazo).
- **Retorno.** Um retorno perdido deixa a empresa sem saber se a nota foi
  autorizada.
- **Duplicidade.** Uma transmissão repetida pode gerar duplicidade e multa.

## Decisões
- **D1 — Um único canal.** Toda comunicação com órgãos de governo passa por um
  serviço do núcleo. Ele monta o envelope, assina, transmite, consulta, guarda
  o protocolo e devolve um resultado padronizado:
  - autorizado, com protocolo;
  - rejeitado, com código e motivo;
  - em processamento, com recibo para consulta;
  - indisponível, para tentar de novo.

  Os programas de cada obrigação só montam o conteúdo e interpretam o
  resultado.
- **D2 — Certificado digital no cofre.**
  - **Tipo e guarda.** O certificado A1 (arquivo e senha) fica no cofre da
    spec 017. Nunca vai para disco aberto, log, tela nem cópia de segurança sem
    cifra.
  - **Uso.** Só o núcleo usa o certificado, para assinar e para a conexão
    autenticada. Nenhum programa do cliente lê a chave.
  - **Várias empresas.** Mais de um certificado é possível (matriz e filiais,
    procurador), cada um com o CNPJ e as obrigações que cobre.
  - **A3.** O certificado A3 (token, cartão) fica para uma fase posterior, por
    um agente local, porque exige hardware na estação.
- **D3 — Validade vigiada.**
  - **Avisos.** Avisa aos 60, 30, 15 e 7 dias do vencimento, ao administrador e
    ao responsável fiscal, como tarefa em "Minhas tarefas".
  - **Troca.** O certificado novo é testado antes de substituir o antigo, com
    uma consulta de status no serviço do governo.
  - **Vencido.** Nada é transmitido, e a tela diz exatamente o que parou.
- **D4 — Leiautes e serviços como dado (P21).**
  - **Pacotes.** Endereços dos serviços por órgão, UF e ambiente, versões de
    leiaute, esquemas XSD, regras de validação publicadas nos manuais e tabelas
    de códigos chegam em **pacotes** pelas atualizações do produto (spec 028).
  - **Versões.** Cada pacote tem vigência. Uma mudança de leiaute é um pacote
    novo, não um programa novo.
  - **Vigilância.** A vigilância da spec 070 avisa quando sai uma nota técnica
    nova.
- **D5 — Validar antes de enviar.**
  - **O quê.** Todo documento é validado no esquema oficial e nas regras de
    negócio dos manuais que dá para conferir localmente (dígitos, somatórios,
    códigos, datas, coerência entre campos).
  - **Erro.** Um erro local vira mensagem em português, apontando o campo e o
    cadastro de origem ("CEP do cliente 214 inválido: abra o cadastro"), e não
    vai ao governo.
  - **Por quê.** Rejeição evitada é tempo e multa evitados.
- **D6 — Transmissão confiável.**
  - **Fila.** A transmissão usa a fila de saída da spec 017, com chave de
    idempotência por documento.
  - **Perda do retorno.** Antes de repetir uma transmissão sem retorno, o canal
    **consulta** o documento no órgão (pela chave ou pelo recibo). Nunca
    reenvia às cegas.
  - **Ordem.** É preservada onde o órgão exige, como os eventos do eSocial do
    mesmo trabalhador.
  - **Ritmo.** Novas tentativas com espera crescente e limite de vazão por
    serviço, para não ser bloqueado pelo órgão.
- **D7 — Contingência e indisponibilidade.**
  - **Disponibilidade.** O canal mantém o estado de cada serviço do governo
    (consulta de status periódica e falhas recentes).
  - **Contingência.** Onde a lei prevê contingência (NF-e, NFC-e), a 059 decide
    a forma usando esse estado.
  - **Indisponível.** Nos demais casos, o documento espera na fila com o prazo
    legal visível, e a agenda (spec 075) avisa se o prazo corre risco.
- **D8 — Ambientes de teste oficiais e homologação.**
  - **Ambientes.** Cada instalação escolhe por obrigação: **produção** ou o
    ambiente de teste oficial (homologação da SEFAZ, produção restrita do
    eSocial e da EFD-Reinf, ambiente de testes da NFS-e nacional).
  - **Testes.** As instâncias de teste da spec 034 usam sempre o ambiente de
    teste.
  - **Mudar para produção.** Exige quatro olhos e só é permitido depois que a
    bateria de homologação daquela obrigação passou (D9).
- **D9 — Bateria de homologação.**
  - **O que é.** Para cada obrigação, um conjunto de cenários oficiais e do
    produto roda contra o ambiente de teste do órgão e guarda a evidência
    (documento enviado, retorno, protocolo, data).
  - **Exemplos.** Nota com ST, nota de devolução, cancelamento, carta de
    correção, inutilização, contingência; admissão, folha, desligamento e
    retificação no eSocial.
  - **Para que serve.** Ela é o critério para ligar a produção e roda de novo a
    cada pacote de leiaute novo (D4).
  - **Relatório.** Gera o relatório que a empresa usa no credenciamento junto
    aos órgãos que pedem.
- **D10 — Guarda legal.**
  - **O quê.** Documento assinado, retorno e protocolo vão para o repositório de
    arquivos da spec 016, imutáveis, com o hash registrado.
  - **Prazo.** Retenção pelo prazo legal de cada obrigação (dados de retenção da
    spec 024), em geral pelo menos 5 anos.
  - **Apagar.** Nunca há exclusão antes do prazo, nem pelo administrador.
  - **Achar.** Busca por chave, número, período, CNPJ e situação.
- **D11 — Experiência premium (P18).**
  - **Painel "Governo".** Mostra:
    - os certificados e a validade;
    - a disponibilidade de cada serviço;
    - o que está na fila e o que espera retorno;
    - as rejeições do dia, com a ação que corrige;
    - os ambientes de cada obrigação.
  - **Rejeição.** Vira tarefa para quem pode corrigir, com o motivo explicado e
    um botão que abre o cadastro ou o documento de origem.
  - **Repetição.** Rejeições repetidas pelo mesmo motivo viram uma sugestão de
    regra ou de ajuste de cadastro (spec 051).

## O que a pessoa deixa de fazer (P19)
- Instalar certificado em cada estação ou programa, e lembrar do vencimento.
- Conferir se a nota "foi ou não foi": o canal consulta sozinho e mostra.
- Reenviar à mão depois de uma queda do serviço do governo.
- Juntar evidências de homologação em planilhas.

## Requisitos funcionais
- **RF-072-01** Serviço único de transmissão com resultado padronizado (D1).
- **RF-072-02** Certificado A1 no cofre, uso só pelo núcleo, vários
  certificados por CNPJ e obrigação (D2).
- **RF-072-03** Vigilância de validade com tarefas e teste do certificado novo
  antes da troca (D3).
- **RF-072-04** Pacotes de leiaute, esquemas, regras e endereços com vigência
  (D4).
- **RF-072-05** Validação local em esquema e regras, com mensagem que aponta a
  origem (D5).
- **RF-072-06** Fila idempotente com consulta antes de repetir, ordem e limite
  de vazão (D6).
- **RF-072-07** Estado dos serviços do governo e espera com prazo visível (D7).
- **RF-072-08** Ambiente por obrigação, produção só com quatro olhos e bateria
  aprovada (D8).
- **RF-072-09** Bateria de homologação com evidências e relatório (D9).
- **RF-072-10** Guarda imutável com hash, retenção legal e busca (D10).
- **RF-072-11** Painel "Governo", rejeição como tarefa com ação, sugestões
  (D11).

## Requisitos não funcionais
- **RNF-072-01 (segurança).**
  - A chave privada nunca sai do núcleo: a assinatura é feita no processo do
    núcleo e a senha fica só em memória durante o uso.
  - O acesso ao cofre e cada uso do certificado vão para a auditoria (spec 024):
    quem, o quê, qual documento.
  - A conexão com o governo usa TLS com validação da cadeia oficial.
- **RNF-072-02 (robustez).**
  - Nenhum documento é transmitido duas vezes sem consulta.
  - Uma queda do nó no meio de uma transmissão é retomada pelo outro nó, pela
    consulta (spec 023).
  - O documento assinado é gravado antes do envio.
- **RNF-072-03 (desempenho).**
  - Assinar e validar uma NF-e de 50 itens leva menos de 150 ms no p95.
  - O canal sustenta 20 transmissões por segundo por nó, respeitando os limites
    de cada órgão.
  - Com o sistema ocioso, a consulta de status dos serviços fica dentro do
    orçamento de escrita da spec 063: o estado é guardado em memória e gravado
    só quando muda.
- **RNF-072-04 (disco, P15).** A guarda legal grava o documento uma vez e
  comprimido. Consultas e novas tentativas não regravam o documento.

## Critérios de aceite
- **CA-072-01** Uma nota enviada cuja resposta se perde (rede cortada depois do
  envio) é consultada, e não reenviada. Ela aparece autorizada com o protocolo
  certo, e o órgão não registra duplicidade.
- **CA-072-02** Com o certificado a 15 dias do vencimento, o responsável tem uma
  tarefa com o passo a passo. Um certificado novo inválido (senha errada, CNPJ
  diferente) é recusado sem trocar o atual.
- **CA-072-03** Um documento com CEP inválido no cadastro do cliente é barrado
  localmente, com a mensagem apontando o cadastro, e nada vai ao governo.
- **CA-072-04** Ligar a produção da NF-e sem a bateria de homologação aprovada
  é recusado. Com a bateria aprovada, exige uma segunda pessoa, e as duas ficam
  na auditoria.
- **CA-072-05** Um programa do cliente que tenta ler o certificado ou a senha
  recebe recusa, e a tentativa vai para a auditoria.
- **CA-072-06** Um pacote de leiaute novo com vigência futura não muda nada
  antes da data. Na data, os documentos passam a sair no leiaute novo, e a
  bateria de homologação roda de novo sozinha.
