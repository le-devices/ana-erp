-- 072 — Assistant that runs routines safely (spec 052).

-- D4: off by default. The model is either a language model reached through a connector of the hub (secret in the vault,
-- allowed hosts, timeout, rate and circuit breaker of spec 017) or a local program with the same contract (offline
-- installations; tests). D5: routines and areas the company keeps away from the assistant.
CREATE TABLE ana_system.assistant_config (
    id               integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    enabled          boolean NOT NULL DEFAULT false,
    provider         text NOT NULL DEFAULT 'anthropic' CHECK (provider IN ('anthropic', 'program')),
    connector        text,                                           -- provider anthropic: integration.connector
    model            text NOT NULL DEFAULT 'claude-opus-5-5' CHECK (model ~ '^[a-z0-9][a-z0-9._-]{1,80}$'),
    effort           text NOT NULL DEFAULT 'medium' CHECK (effort IN ('low', 'medium', 'high')),
    program          text,                                           -- provider program: the local model
    daily_tokens     integer NOT NULL DEFAULT 300000 CHECK (daily_tokens BETWEEN 1000 AND 100000000),
    blocked          text[] NOT NULL DEFAULT '{}' CHECK (array_position(blocked, NULL) IS NULL),
    updated_by       text NOT NULL DEFAULT 'ana',
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CHECK (provider <> 'anthropic' OR NOT enabled OR connector IS NOT NULL),
    CHECK (provider <> 'program' OR NOT enabled OR program IS NOT NULL)
);
INSERT INTO ana_system.assistant_config (id, program) VALUES (1, 'assistant.local_model');

-- D6: every conversation — the messages exchanged with the model (to go on) and, apart, what happened: questions,
-- tools called, rehearsals, actions waiting for the person, confirmations and executions, with the user.
CREATE TABLE ana_system.assistant_conversation (
    id          uuid PRIMARY KEY,
    username    text NOT NULL,
    started_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    title       text NOT NULL DEFAULT '',
    messages    jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(messages) = 'array'),
    tokens_in   bigint NOT NULL DEFAULT 0,
    tokens_out  bigint NOT NULL DEFAULT 0
);
CREATE INDEX assistant_conversation_user_idx ON ana_system.assistant_conversation (username, updated_at DESC);

CREATE TABLE ana_system.assistant_event (
    id               bigserial PRIMARY KEY,
    conversation_id  uuid NOT NULL REFERENCES ana_system.assistant_conversation(id) ON DELETE CASCADE,
    at               timestamptz NOT NULL DEFAULT now(),
    kind             text NOT NULL CHECK (kind IN ('question', 'answer', 'query', 'rehearsal', 'refused_tool', 'confirmed',
                                                   'declined', 'expired', 'failed')),
    program          text,
    detail           jsonb NOT NULL DEFAULT '{}',
    execution_id     uuid
);
CREATE INDEX assistant_event_conv_idx ON ana_system.assistant_event (conversation_id, id);
CREATE INDEX assistant_event_at_brin ON ana_system.assistant_event USING brin (at);

-- D2: a routine that writes is rehearsed and waits for the person; only "Confirmar" on the screen runs it — with the
-- parameters rehearsed, never new ones from the model.
CREATE TABLE ana_system.assistant_action (
    id                 uuid PRIMARY KEY,
    conversation_id    uuid NOT NULL REFERENCES ana_system.assistant_conversation(id) ON DELETE CASCADE,
    username           text NOT NULL,
    program            text NOT NULL,
    params             jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(params) = 'object'),
    effect             jsonb,
    rehearsal_id       uuid,
    status             text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'declined', 'failed', 'expired')),
    execution_id       uuid,
    created_at         timestamptz NOT NULL DEFAULT now(),
    decided_at         timestamptz
);
CREATE INDEX assistant_action_conv_idx ON ana_system.assistant_action (conversation_id);
CREATE INDEX assistant_action_pending_idx ON ana_system.assistant_action (username) WHERE status = 'pending';
COMMENT ON TABLE ana_system.assistant_action IS 'Ações do assistente aguardando a confirmação da pessoa (spec 052, D2)';
