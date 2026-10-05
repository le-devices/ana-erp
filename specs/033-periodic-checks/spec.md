# 033 — Verificações periódicas: segurança, componentes vulneráveis, robustez e desempenho

## Problema
O ERP é de missão crítica (24/7). Hoje o conselheiro (spec 019) aponta
problemas de SQL, índices e limites, mas nada verifica periodicamente se a
instalação continua segura (senhas e chaves de fábrica, links abertos,
chaves de API antigas), se algum componente (OTP, bibliotecas Erlang,
Python, PostgreSQL e extensões, pacotes da imagem, arquivos da interface)
tem vulnerabilidade conhecida, nem se robustez (cópias de segurança,
restauração testada, réplica, filas) e desempenho (rotinas-chave, SQL) se
degradaram. O administrador só descobre quando algo quebra.

## Histórias
- **H1** Como administrador, vejo numa tela as verificações com a última
  execução, o que mudou e o que exige ação, por severidade.
- **H2** Como administrador, sei quais componentes e versões compõem a
  instalação (inventário) e quais têm vulnerabilidade conhecida, com a
  versão que corrige.
- **H3** Como responsável pela operação, recebo aviso quando uma verificação
  crítica falha, sem precisar abrir a tela.
- **H4** Como administrador, dispenso um achado com motivo e validade; ele
  volta se a validade vence ou se a situação piora.

## Requisitos funcionais
- **RF-033-01** Inventário de componentes (lista de materiais de software):
  versão do ERP, OTP e bibliotecas Erlang (rebar.lock), Python e módulos,
  PostgreSQL e extensões, pacotes da imagem, arquivos da interface com
  hash. Gerado na construção da imagem e conferido em execução.
- **RF-033-02** Vulnerabilidades: base no formato OSV, atualizada por
  conector do hub (spec 017, host permitido, desligado de fábrica) ou por
  arquivo enviado (instalações sem internet); casa ecossistema, pacote e
  faixa de versões; achado com identificador, severidade e versão que
  corrige.
- **RF-033-03** Segurança da configuração: senha de fábrica do admin, chave
  mestra ou senha do banco de exemplo, cookie padrão, sessão e política de
  senha fracas, administradores em excesso, usuários sem troca de senha,
  chaves de API sem uso ou antigas, robôs sem dono ativo, links de
  compartilhamento sem senha ou validade, conectores sem hosts permitidos,
  webhooks sem segredo, retenção da auditoria abaixo do mínimo.
- **RF-033-04** Integridade: arquivos da interface e sementes conferidos com
  o inventário; arquivos do repositório (spec 016, já existe) entram no
  mesmo painel.
- **RF-033-05** Robustez: idade da última cópia de segurança e do último
  teste de restauração, atraso da réplica, espaço em disco, filas mortas da
  integração, disjuntores abertos, tarefas agendadas perdidas, taxa de erro
  por rotina.
- **RF-033-06** Desempenho: sondas sintéticas (rotinas leves do produto) com
  linha de base; alerta quando o p95 piora além do limiar; regressões de SQL
  pelas estatísticas (spec 019).
- **RF-033-07** Agendamento como tarefas internas do robô `system` (P14):
  segurança e integridade diárias, vulnerabilidades diárias quando houver
  base nova, robustez a cada 15 min, desempenho a cada hora; execução sob
  demanda.
- **RF-033-08** Achados no mesmo modelo do conselheiro (regra, alvo,
  severidade, evidência, dispensa com motivo e validade), com categoria;
  só grava o que mudou (P15); histórico pela retenção (spec 024).
- **RF-033-09** Aviso aos administradores (sino) e, se configurado, por
  conector (e-mail/chat) para achados críticos novos.

## Critérios de aceite
- **CA-033-01** Instalação com a senha de fábrica do admin gera achado
  crítico; trocar a senha resolve o achado na próxima execução.
- **CA-033-02** Base OSV com faixa que cobre a versão instalada de um
  componente do inventário gera achado com a versão que corrige; base sem
  correspondência não gera.
- **CA-033-03** Arquivo da interface alterado depois da construção gera
  achado de integridade.
- **CA-033-04** Cópia de segurança mais antiga que o limite gera achado de
  robustez.
- **CA-033-05** Sonda com p95 acima de linha de base × limiar gera achado
  de desempenho; dentro do limiar, não.
- **CA-033-06** Achado dispensado não reaparece até a validade; reaparece
  se a severidade aumentar.

## Decisões
- Nenhuma consulta externa sem o administrador ligar o conector (P13 e
  ambientes isolados); arquivo OSV enviado à mão é o caminho padrão.
- Varredura da imagem (pacotes do sistema) roda na construção e o resultado
  segue no inventário; em execução só se confere.
