# 011 — Plano técnico: Administração

## Dados (migração `006_administration.sql`)
- `ana_system.app_user` + `must_change_password`, `last_login_at`.
- Fuso horário da implantação: `ANA_TIMEZONE` aplicado aos papéis do banco e ao processo Python (P13).
- `ana_system.access_group(name PK, description, program_patterns text[])`,
  `ana_system.user_group(username, group_name)`.
- `ana_system.program.restricted boolean`.
- `ana_system.setting(key PK, value jsonb, kind, min, max, description, updated_at, updated_by)`.
- `ana_system.login_event(id, username, ip, success, reason, at)` com BRIN em `at`.
- `ana_system.admin_log(id, username, action, target, before jsonb, after jsonb, at)`.

## Núcleo
| Módulo | Papel |
|--------|-------|
| `ana_settings` | definições (chave, tipo, faixa, padrão, env inicial), cache ETS, NOTIFY `ana_setting`; `get/1` usado por timeouts e limites |
| `ana_admin` | usuários, grupos, sessões, desbloqueio, último admin, `admin_log` |
| `ana_access` | `allowed(User, Program)` com grupos em cache |
| `ana_http_admin` | rotas `/api/admin/*` |

## Rotas
`/api/admin/users[/:username[/password|/sessions/revoke|/unlock]]`, `/api/admin/groups[/:name]`,
`/api/admin/settings[/:key]`, `/api/admin/company`, `/api/admin/remote-systems[/:name]`,
`/api/admin/default-accounts[/:key]`, `/api/admin/monitor`, `/api/admin/executions/:id/stop`,
`/api/admin/audit/{executions,logins,changes}`, `DELETE /api/programs/:name?purge=1`,
`POST /api/me/password`. Comandos continuam em `/api/commands` (developer+), reaproveitados
pela tela de administração.

## Estúdio
- Seletor de área no topo: **Desenvolvimento** | **Administração** (admin).
- Administração: navegação lateral por seção; tabelas com busca; formulários
  laterais; confirmações para ações destrutivas.
- Layout em flex column (RNF-011-05): o editor tem `flex: 1` e altura mínima.

## Usuários robô (RF-011-12..15) — migração `010_robot_users.sql`
- `ana_system.app_user.kind` (`human` | `robot`); robôs recebem hash de senha
  inutilizável e o login por senha os recusa (motivo `robot` na auditoria).
- `ana_system.api_key(id, username, name, prefix, key_hash, ip_allow cidr[],
  expires_at, last_used_at, revoked_at, created_by, created_at)`.
- `ana_security:validate/2` aceita `ana_rk_…`: SHA-256 → busca (cache ETS de
  30 s, limpo na revogação) → validade, revogação e IP (`inet` + máscara
  CIDR, IPv4/IPv6); último uso gravado no máximo uma vez por minuto.
- Administração → Usuários: tipo pessoa/robô na criação; ficha do robô com
  as chaves (gerar mostra a chave uma vez; revogar).
- A spec 010 (API pública) acrescentará OAuth/PKCE e chaves publicáveis; as
  chaves de robô são o mecanismo servidor-a-servidor simples.
