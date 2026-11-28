-- 089 — Technical actions (spec 077, T-077-01, T-077-02; plan §2.1).
--
-- Every technical intervention is an action of a catalog (data), carried out by a fixed function of the core
-- (ana_tech): never typed code, never a system command, never SQL that writes. The risk decides the ceremony — low:
-- just do it (and offer the undo); medium: confirmation that says the consequence; high: a second person approves.
-- A company may only make an action stricter, and choose which groups may run it. Everything done is recorded.
CREATE SCHEMA technical;

CREATE TABLE technical.action (
    code          text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    name          text NOT NULL CHECK (length(btrim(name)) BETWEEN 3 AND 80),
    description   text NOT NULL CHECK (length(btrim(description)) BETWEEN 3 AND 400),
    -- [{name, type, label, required}] — type: text, integer, choice
    params        jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(params) = 'array'),
    preconditions text[] NOT NULL DEFAULT '{}',
    effect        text NOT NULL CHECK (length(btrim(effect)) >= 3),          -- what happens, in plain Portuguese
    impact        text NOT NULL CHECK (length(btrim(impact)) >= 3),          -- who is affected and for how long
    risk          text NOT NULL CHECK (risk IN ('low', 'medium', 'high')),   -- the product's minimum
    rehearsable   boolean NOT NULL DEFAULT false,
    undo          text REFERENCES technical.action(code) DEFERRABLE INITIALLY DEFERRED,
    success       text NOT NULL CHECK (length(btrim(success)) >= 3),         -- what is checked after acting
    in_rescue     boolean NOT NULL DEFAULT false,                            -- also in the rescue mode (phase 2)
    area          text NOT NULL CHECK (area ~ '^[a-z]+$'),
    sequence      integer NOT NULL DEFAULT 100
);

-- The company's hardening: never below the product's risk (checked in the core), groups that may run it.
CREATE TABLE technical.action_policy (
    code          text PRIMARY KEY REFERENCES technical.action(code) ON DELETE CASCADE,
    risk          text CHECK (risk IN ('low', 'medium', 'high')),
    groups        text[] NOT NULL DEFAULT '{}',          -- empty: administrators only
    act_now       boolean NOT NULL DEFAULT false,        -- high risk: act now, review afterwards (on call)
    updated_by    text NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Each request and each run: the request of a high-risk action waits for a second person; params are frozen.
CREATE TABLE technical.action_run (
    id            bigserial PRIMARY KEY,
    code          text NOT NULL REFERENCES technical.action(code),
    params        jsonb NOT NULL DEFAULT '{}',
    risk          text NOT NULL,
    status        text NOT NULL CHECK (status IN ('pending', 'rejected', 'expired', 'done', 'failed', 'review')),
    requested_by  text NOT NULL,
    requested_at  timestamptz NOT NULL DEFAULT now(),
    origin        text NOT NULL DEFAULT 'studio',
    reason        text,
    approved_by   text,
    decided_at    timestamptz,
    expires_at    timestamptz,
    node          text,
    result        jsonb,
    error         jsonb,
    finished_at   timestamptz,
    CHECK (approved_by IS NULL OR approved_by <> requested_by)
);
CREATE INDEX action_run_recent_idx ON technical.action_run (id DESC);
CREATE INDEX action_run_pending_idx ON technical.action_run (status) WHERE status IN ('pending', 'review');

INSERT INTO technical.action (code, name, description, params, preconditions, effect, impact, risk, undo, success, in_rescue, area, sequence) VALUES
('execution.stop', 'Encerrar uma execução', 'Interrompe uma execução de programa que está rodando',
 '[{"name":"id","type":"text","label":"execução","required":true}]', '{}',
 'A execução para e a transação dela é desfeita', 'Quem esperava o resultado recebe "interrompida"', 'medium', NULL,
 'A execução não aparece mais rodando', false, 'execucoes', 10),
('user.revoke_sessions', 'Encerrar as sessões de um usuário', 'Desconecta a pessoa de todos os aparelhos',
 '[{"name":"username","type":"text","label":"usuário","required":true}]', '{}',
 'Todas as sessões da pessoa deixam de valer', 'A pessoa precisa entrar de novo', 'medium', NULL,
 'Nenhuma sessão ativa da pessoa', false, 'acesso', 20),
('user.unlock', 'Desbloquear um usuário', 'Libera quem foi bloqueado por tentativas de login',
 '[{"name":"username","type":"text","label":"usuário","required":true}]', '{}',
 'A pessoa volta a poder entrar', 'Só a pessoa', 'low', NULL, 'O usuário não está bloqueado', false, 'acesso', 21),
('ip.unlock', 'Desbloquear um endereço', 'Libera um endereço bloqueado por tentativas de login',
 '[{"name":"ip","type":"text","label":"endereço","required":true}]', '{}',
 'O endereço volta a poder tentar o login', 'Quem usa aquele endereço', 'low', NULL, 'O contador do endereço está zerado',
 false, 'acesso', 22),
('integration.reprocess', 'Reprocessar uma mensagem de integração', 'Coloca de novo na fila uma mensagem que falhou',
 '[{"name":"kind","type":"choice","label":"direção","required":true,"choices":[["inbox","entrada"],["outbox","saída"]]},
   {"name":"id","type":"integer","label":"mensagem","required":true}]', '{}',
 'A mensagem é processada outra vez', 'O sistema do outro lado pode receber de novo', 'low', NULL,
 'A mensagem volta para a fila', false, 'integracoes', 30),
('integration.discard', 'Descartar uma mensagem de integração', 'Tira da fila uma mensagem que não deve ser processada',
 '[{"name":"kind","type":"choice","label":"direção","required":true,"choices":[["inbox","entrada"],["outbox","saída"]]},
   {"name":"id","type":"integer","label":"mensagem","required":true}]', '{}',
 'A mensagem não será processada', 'O que ela traria não acontece', 'medium', 'integration.reprocess',
 'A mensagem está descartada', false, 'integracoes', 31),
('api_client.release_breaker', 'Liberar o disjuntor de um cliente da API', 'Volta a aceitar as chamadas de um cliente bloqueado por falhas',
 '[{"name":"client","type":"text","label":"cliente da API","required":true}]', '{}',
 'O cliente volta a ser atendido', 'Só esse cliente', 'low', NULL, 'O disjuntor está fechado', false, 'api', 40),
('api_client.rotate_secret', 'Trocar o segredo de um cliente da API', 'Gera um segredo novo; o anterior vale até ser retirado',
 '[{"name":"client","type":"text","label":"cliente da API","required":true}]', '{}',
 'Um segredo novo é emitido', 'O cliente precisa passar a usar o segredo novo', 'medium', NULL,
 'O cliente tem um segredo novo', false, 'api', 41),
('api.rotate_keys', 'Girar as chaves de assinatura da API', 'Troca as chaves que assinam os tokens da API pública',
 '[]', '{}', 'Tokens novos passam a ser assinados com a chave nova', 'Os clientes renovam o token na próxima chamada',
 'medium', NULL, 'Há uma chave nova em uso', false, 'api', 42),
('retention.purge', 'Liberar espaço pela retenção', 'Apaga agora o que já passou do prazo de guarda (registros, execuções, filas)',
 '[]', '{}', 'O que passou do prazo é apagado', 'Nenhum dado dentro do prazo é tocado', 'medium', NULL,
 'Nada além do prazo permanece', true, 'espaco', 50),
('health.check', 'Conferir a saúde agora', 'Roda a conferência de saúde sem esperar o próximo ciclo',
 '[]', '{}', 'A situação de cada componente é atualizada', 'Nenhum', 'low', NULL, 'A conferência terminou', true, 'saude', 60),
('disk.sample', 'Medir o disco agora', 'Mede espaço e escrita do disco sem esperar o próximo ciclo',
 '[]', '{}', 'A medição do disco é atualizada', 'Nenhum', 'low', NULL, 'Há uma medição nova', true, 'espaco', 61),
('checks.run', 'Rodar as verificações', 'Roda as verificações periódicas de uma categoria, ou todas',
 '[{"name":"category","type":"text","label":"categoria (vazio = todas)","required":false}]', '{}',
 'Os achados das verificações são atualizados', 'Nenhum', 'low', NULL, 'As verificações terminaram', false, 'saude', 62),
('advice.run', 'Analisar o desempenho do SQL', 'Recalcula as dicas de otimização a partir das medições',
 '[]', '{}', 'As dicas são atualizadas', 'Nenhum', 'low', NULL, 'A análise terminou', false, 'desempenho', 63),
('node.drain', 'Drenar este nó', 'Tira este nó do balanceamento: as novas chamadas vão para os outros nós',
 '[]', '{other_node_ready}', 'Este nó para de receber trabalho novo e termina o que está rodando',
 'Nenhum, se houver outro nó pronto', 'low', 'node.resume', 'Este nó está fora do balanceamento', true, 'nos', 70),
('node.resume', 'Voltar a receber trabalho neste nó', 'Coloca este nó de volta no balanceamento',
 '[]', '{}', 'Este nó volta a receber chamadas', 'Nenhum', 'low', NULL, 'Este nó está pronto', true, 'nos', 71);

-- The record of technical actions goes to the audit like the rest (spec 024): nothing here is purged by retention.
COMMENT ON TABLE technical.action_run IS 'Ações técnicas pedidas e executadas (spec 077): a aba Registro da Central técnica';
