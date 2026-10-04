-- 008 — User preferences: favorite routines (spec 020, RF-020-02)

CREATE TABLE ana_system.user_favorite (
    username   text NOT NULL REFERENCES ana_system.app_user(username) ON DELETE CASCADE ON UPDATE CASCADE,
    program    text NOT NULL REFERENCES ana_system.program(name) ON DELETE CASCADE ON UPDATE CASCADE,
    position   integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (username, program)
);
CREATE INDEX user_favorite_program_idx ON ana_system.user_favorite (program);
