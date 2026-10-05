# 033 — Plano técnico

## Dados (migração `029_periodic_checks.sql`)
- `ana_system.advice` ganha `category` (`security`, `dependencies`,
  `integrity`, `robustness`, `performance`): o conselheiro (spec 019) e as
  verificações usam o mesmo modelo de achado (dispensa, resolução, P15).
  As regras atuais recebem a categoria (integridade de arquivos →
  `integrity`; limites e timeouts → `robustness`; SQL e índices →
  `performance`).
- `ana_system.component`: inventário corrente (ecossistema, nome, versão,
  origem); reescrito só quando muda.
- `ana_system.vulnerability`: base OSV importada, uma linha por faixa
  afetada (id, ecossistema, pacote, introduzida, corrigida, última afetada,
  versões listadas, severidade, resumo, apelidos, modificada).
- `ana_system.ops_event`: eventos operacionais externos ao núcleo
  (`backup_base`, `restore_test`), gravados pelos scripts `backup.sh` e
  `restore-test.sh`.
- `ana_system.perf_sample`: amostras das sondas (sonda, instante, ms),
  particionada por mês? — não: volume pequeno (≈ 3 sondas × 12/h); retenção
  de 30 dias pela spec 024.
- `ana_system.notice`: avisos do sistema para administradores (achado
  crítico novo), lidos uma vez por instalação; o sino mostra avisos do
  agendamento e do sistema.
- Parâmetros: `checks_backup_max_hours` (26), `checks_restore_max_days`
  (35), `checks_key_max_days` (365), `checks_perf_factor` (2.0 ×,
  como inteiro em %: 200).

## Núcleo
- `ana_checks` (gen_server, só no líder do agendamento, P14 via
  `ana_task:run/4` com o robô `system`):
  - `security` e `integrity`: diário (e 2 min após subir);
  - `dependencies`: diário e ao importar base;
  - `robustness`: 15 min; `performance`: sondas a cada 5 min, avaliação
    horária.
  - Cada categoria: lista de regras → achados → `ana_advisor:upsert/8` →
    resolve os achados da categoria que sumiram. Achado crítico novo →
    `ana_system.notice`.
- `ana_inventory`: OTP/ERTS, aplicações carregadas (Hex), Python, PostgreSQL
  e extensões, pacotes Debian (`/var/lib/dpkg/status`), arquivos da
  interface com SHA-256 conferidos com `priv/asset-manifest.txt` (gerado no
  Dockerfile).
- `ana_osv`: importação (objeto, lista ou `{"vulns": [...]}`), comparação de
  versões (épocas Debian, segmentos numéricos e alfanuméricos) e casamento
  com o inventário.
- Regras de segurança: senha trivial em conta privilegiada (nome do
  usuário, `admin`, `password`, `123456`, `ana`), chave mestra e senha do
  banco de exemplo, cookie padrão, tamanho mínimo de senha < 10, sessão >
  24 h, administradores > 3, troca de senha pendente há > 7 dias, chaves de
  API sem uso há > 90 dias ou mais antigas que o limite sem validade, links
  de compartilhamento sem senha válidos por > 30 dias, conectores de API sem
  hosts permitidos, retenção da auditoria < 90 dias.
- Regras de robustez: arquivamento de WAL desligado ou falhando, cópia base
  e teste de restauração mais antigos que o limite, filas mortas da
  integração, disjuntores abertos, taxa de erro por rotina (≥ 20 execuções
  e ≥ 20 % de erro na última hora), espaço livre do diretório de arquivos
  < 10 %.
- Desempenho: sondas `db_roundtrip` (`SELECT 1`), `python_exec` (programa
  trivial no pool) e `catalog_query` (consulta ao catálogo de programas);
  linha de base = mediana dos p95 horários dos últimos 7 dias (exceto a
  última hora); achado quando p95 da última hora ≥ base × fator e ≥ base +
  50 ms, com pelo menos 6 amostras.
- Em modo demonstração (`ANA_DEMO=true`) os achados de cópia de segurança e
  WAL são `info` (ambiente de teste).

## HTTP
- `GET /api/admin/checks` (resumo por categoria, achados com filtro),
  `POST /api/admin/checks/run` (`{"category"}`), `GET /api/admin/checks/inventory`,
  `POST /api/admin/checks/vulnerabilities` (arquivo OSV, até 20 MiB),
  `GET /api/notifications` inclui avisos do sistema para administradores,
  `POST /api/notifications/system/<id>/read`.

## Interface
- Administração → Operação do sistema → **Verificações**: chips por
  categoria (abertos por severidade), achados com filtro de categoria e
  dispensa, "Verificar agora" por categoria, aba Inventário (componentes,
  vulneráveis em destaque) e envio da base OSV.

## Scripts
- `backup.sh base` e `restore-test.sh` gravam `ops_event` (ok/falha,
  detalhe) via `psql` no contêiner do banco.

## Testes
- eunit: comparação de versões, casamento OSV, manifesto de arquivos,
  regressão de desempenho, decisão de severidade.
- Integração: CA-033-01 (senha de fábrica do admin no ambiente de teste),
  CA-033-02 (base OSV com faixa que cobre um componente real do
  inventário), CA-033-04 (evento de cópia antigo), CA-033-06 (dispensa),
  inventário e tela.
