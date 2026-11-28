-- 092 — Operation modes to get through a crisis (spec 077, T-077-07, D14, RF-077-13, CA-077-08; plan §2.5).
--
-- One row for the installation: read-only (queries work, writes are refused with the mode's message), maintenance
-- (only administrators and the technical team get in), the entry of integrations paused (messages wait in the
-- queue) and the scheduled routines suspended. Each with a message and the expected end, shown on the screens, the
-- portal and the API. Read by every node from memory (NOTIFY "ana_mode"): no query per request.
CREATE TABLE technical.operation_mode (
    id                 smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    mode               text NOT NULL DEFAULT 'normal' CHECK (mode IN ('normal', 'read_only', 'maintenance')),
    inbound_paused     boolean NOT NULL DEFAULT false,
    routines_suspended boolean NOT NULL DEFAULT false,
    message            text CHECK (message IS NULL OR length(message) <= 300),
    until              timestamptz,
    technical_group    text REFERENCES ana_system.access_group(name) ON UPDATE CASCADE ON DELETE SET NULL,
    set_by             text,
    set_at             timestamptz NOT NULL DEFAULT now()
);
INSERT INTO technical.operation_mode (id) VALUES (1);

CREATE FUNCTION technical.mode_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ana_mode', '');
    RETURN NULL;
END $$;
CREATE TRIGGER operation_mode_changed AFTER UPDATE ON technical.operation_mode
    FOR EACH STATEMENT EXECUTE FUNCTION technical.mode_changed();

INSERT INTO technical.action (code, name, description, params, effect, impact, risk, undo, success, in_rescue, area, sequence) VALUES
('mode.read_only', 'Ligar o modo somente leitura', 'O ERP continua consultando, mas não grava nada (telas, API, portal e rotinas)',
 '[{"name":"message","type":"text","label":"mensagem para as pessoas","required":true},
   {"name":"minutes","type":"integer","label":"previsão de término (minutos)","required":false}]',
 'Toda gravação é recusada com a mensagem do modo; as consultas funcionam',
 'Todos: ninguém grava até sair do modo', 'medium', 'mode.normal', 'Uma gravação é recusada com a mensagem', true, 'modos', 90),
('mode.maintenance', 'Ligar o modo manutenção', 'Só administradores e a equipe técnica entram; os demais veem a mensagem',
 '[{"name":"message","type":"text","label":"mensagem para as pessoas","required":true},
   {"name":"minutes","type":"integer","label":"previsão de término (minutos)","required":false},
   {"name":"technical_group","type":"text","label":"grupo da equipe técnica (vazio = só administradores)","required":false}]',
 'Quem não é da equipe técnica não entra e recebe a mensagem',
 'Todos fora da equipe técnica, até sair do modo', 'medium', 'mode.normal', 'Uma pessoa fora da equipe recebe a mensagem',
 true, 'modos', 91),
('mode.normal', 'Voltar ao funcionamento normal', 'Sai do modo e retoma, na ordem, gravações, integrações e rotinas',
 '[]', 'Primeiro as gravações voltam, depois a entrada de integrações, por último as rotinas agendadas',
 'Todos voltam a trabalhar normalmente', 'low', NULL, 'O modo é normal e nada está pausado', true, 'modos', 92),
('integrations.pause_inbound', 'Pausar a entrada de integrações', 'As mensagens recebidas esperam na fila, sem processar',
 '[]', 'Nada do que chega é processado até retomar; nada se perde', 'Quem depende do que chega de outros sistemas',
 'low', 'integrations.resume_inbound', 'A entrada está pausada', true, 'integracoes', 32),
('integrations.resume_inbound', 'Retomar a entrada de integrações', 'Volta a processar o que chegou, na ordem',
 '[]', 'O que esperou na fila é processado', 'Nenhum', 'low', NULL, 'A entrada está ativa', true, 'integracoes', 33),
('scheduler.suspend', 'Suspender as rotinas agendadas', 'O agendador não dispara nada até retomar (o que estava agendado espera)',
 '[]', 'Nenhuma rotina agendada começa', 'Quem espera relatórios e rotinas automáticas', 'low', 'scheduler.resume',
 'O agendador está suspenso', true, 'rotinas', 34),
('scheduler.resume', 'Retomar as rotinas agendadas', 'O agendador volta a disparar; as ocorrências atrasadas seguem a regra de cada rotina',
 '[]', 'As rotinas voltam a rodar', 'Nenhum', 'low', NULL, 'O agendador está ativo', true, 'rotinas', 35);
