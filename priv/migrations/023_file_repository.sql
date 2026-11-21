-- 023 — File repository with granular permissions and external portal accounts (spec 016)

-- RF-016-04: external portal accounts, tied to a party (customer/supplier).
ALTER TABLE ana_system.app_user DROP CONSTRAINT app_user_role_check;
ALTER TABLE ana_system.app_user ADD CONSTRAINT app_user_role_check
    CHECK (role IN ('admin', 'developer', 'user', 'external'));
ALTER TABLE ana_system.app_user ADD COLUMN party_id integer REFERENCES base.party(id);
ALTER TABLE ana_system.app_user ADD CONSTRAINT external_has_party CHECK ((role = 'external') = (party_id IS NOT NULL));
CREATE INDEX app_user_party_idx ON ana_system.app_user (party_id);
-- Programs an external account may run (e.g. "my invoices").
ALTER TABLE ana_system.program ADD COLUMN portal boolean NOT NULL DEFAULT false;

CREATE SCHEMA IF NOT EXISTS files;
REVOKE ALL ON SCHEMA files FROM PUBLIC;

-- Content: unique, encrypted, addressed by the SHA-256 of the plain text (RNF-016-02).
CREATE TABLE files.blob (
    sha256     text PRIMARY KEY CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    size       bigint NOT NULL CHECK (size >= 0),
    iv         bytea NOT NULL CHECK (length(iv) = 16),
    mac        bytea NOT NULL CHECK (length(mac) = 32),
    created_at timestamptz NOT NULL DEFAULT now(),
    verified_at timestamptz
);

CREATE TABLE files.folder (
    id          bigserial PRIMARY KEY,
    parent_id   bigint REFERENCES files.folder(id),
    name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 200 AND name !~ '[/\\\x00-\x1f]'),
    inherit     boolean NOT NULL DEFAULT true,
    entity_kind text CHECK (entity_kind IN ('project', 'party', 'system')),
    entity_id   bigint,
    quota_mb    integer CHECK (quota_mb > 0),
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_id IS NULL OR parent_id <> id)
);
CREATE UNIQUE INDEX folder_name_uk ON files.folder (COALESCE(parent_id, 0), lower(name));
CREATE UNIQUE INDEX folder_entity_uk ON files.folder (entity_kind, entity_id) WHERE entity_kind IS NOT NULL;
CREATE INDEX folder_parent_idx ON files.folder (parent_id);

CREATE TABLE files.file (
    id          bigserial PRIMARY KEY,
    folder_id   bigint NOT NULL REFERENCES files.folder(id),
    name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 200 AND name !~ '[/\\\x00-\x1f]'),
    version     integer NOT NULL DEFAULT 0,
    tags        text[] NOT NULL DEFAULT '{}',
    status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'quarantine', 'deleted')),
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX file_name_uk ON files.file (folder_id, lower(name)) WHERE status <> 'deleted';
CREATE INDEX file_folder_idx ON files.file (folder_id);
CREATE INDEX file_tags_idx ON files.file USING gin (tags);

CREATE TABLE files.file_version (
    file_id    bigint NOT NULL REFERENCES files.file(id),
    version    integer NOT NULL CHECK (version > 0),
    blob       text NOT NULL REFERENCES files.blob(sha256),
    name       text NOT NULL,
    mime       text NOT NULL,
    size       bigint NOT NULL,
    comment    text NOT NULL DEFAULT '',
    created_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (file_id, version)
);
CREATE INDEX file_version_blob_idx ON files.file_version (blob);

-- RF-016-03
CREATE TABLE files."grant" (
    id           bigserial PRIMARY KEY,
    subject_kind text NOT NULL CHECK (subject_kind IN ('user', 'group', 'role', 'party')),
    subject      text NOT NULL,
    folder_id    bigint REFERENCES files.folder(id) ON DELETE CASCADE,
    file_id      bigint REFERENCES files.file(id) ON DELETE CASCADE,
    level        text NOT NULL CHECK (level IN ('view', 'download', 'upload', 'manage')),
    deny         boolean NOT NULL DEFAULT false,
    expires_at   timestamptz,
    granted_by   text NOT NULL,
    granted_at   timestamptz NOT NULL DEFAULT now(),
    CHECK ((folder_id IS NULL) <> (file_id IS NULL))
);
CREATE UNIQUE INDEX grant_uk ON files."grant" (subject_kind, subject, COALESCE(folder_id, 0), COALESCE(file_id, 0), deny);
CREATE INDEX grant_folder_idx ON files."grant" (folder_id);
CREATE INDEX grant_file_idx ON files."grant" (file_id);
CREATE INDEX grant_subject_idx ON files."grant" (subject_kind, subject);

-- RF-016-05
CREATE TABLE files.share_link (
    id             bigserial PRIMARY KEY,
    token_hash     text NOT NULL UNIQUE,
    file_id        bigint NOT NULL REFERENCES files.file(id),
    version        integer,
    expires_at     timestamptz NOT NULL,
    password_hash  text,
    max_downloads  integer CHECK (max_downloads > 0),
    downloads      integer NOT NULL DEFAULT 0,
    revoked        boolean NOT NULL DEFAULT false,
    created_by     text NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX share_link_file_idx ON files.share_link (file_id);

-- RF-016-06: resumable upload (the encrypted part grows on disk; offset = bytes received).
CREATE TABLE files.upload (
    id          text PRIMARY KEY CHECK (id ~ '^[0-9a-f]{32}$'),
    folder_id   bigint NOT NULL REFERENCES files.folder(id),
    name        text NOT NULL,
    size        bigint NOT NULL CHECK (size >= 0),
    received    bigint NOT NULL DEFAULT 0,
    iv          bytea NOT NULL,
    comment     text NOT NULL DEFAULT '',
    created_by  text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX upload_folder_idx ON files.upload (folder_id);

-- RF-016-10
CREATE TABLE files.event (
    id        bigserial PRIMARY KEY,
    action    text NOT NULL,
    folder_id bigint,
    file_id   bigint,
    version   integer,
    username  text,
    ip        text,
    detail    jsonb,
    at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX event_file_idx ON files.event (file_id, at);
CREATE INDEX event_folder_idx ON files.event (folder_id, at);
CREATE INDEX event_at_brin ON files.event USING brin (at);

-- Effective level (0 none, 1 view, 2 download, 3 upload, 4 manage) of a user on a folder
-- or file: highest grant along the inheritance chain (up to the first folder that does not
-- inherit); an explicit deny wins; admins/developers and the folder's creator manage.
CREATE FUNCTION files.level(p_user text, p_folder bigint, p_file bigint) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_role text;
    v_party integer;
    v_folder bigint := p_folder;
    v_result integer;
BEGIN
    SELECT role, party_id INTO v_role, v_party FROM ana_system.app_user WHERE username = p_user AND active;
    IF v_role IS NULL THEN RETURN 0; END IF;
    IF v_role IN ('admin', 'developer') THEN RETURN 4; END IF;
    IF p_file IS NOT NULL THEN
        SELECT folder_id INTO v_folder FROM files.file WHERE id = p_file AND status <> 'deleted';
        IF v_folder IS NULL THEN RETURN 0; END IF;
    END IF;
    WITH RECURSIVE chain AS (
        SELECT f.id, f.parent_id, f.inherit, f.created_by, 0 AS depth FROM files.folder f WHERE f.id = v_folder
        UNION ALL
        SELECT p.id, p.parent_id, p.inherit, p.created_by, c.depth + 1 FROM files.folder p
        JOIN chain c ON p.id = c.parent_id WHERE c.inherit AND c.depth < 64
    ),
    subjects AS (
        SELECT 'user' AS kind, p_user AS subject
        UNION ALL SELECT 'role', v_role
        UNION ALL SELECT 'party', v_party::text WHERE v_party IS NOT NULL
        UNION ALL SELECT 'group', g.group_name FROM ana_system.user_group g WHERE g.username = p_user
    ),
    hits AS (
        SELECT g.level, g.deny FROM files."grant" g JOIN subjects s ON s.kind = g.subject_kind AND s.subject = g.subject
        WHERE (g.expires_at IS NULL OR g.expires_at > now())
          AND (g.folder_id IN (SELECT id FROM chain) OR (p_file IS NOT NULL AND g.file_id = p_file))
    )
    SELECT CASE
             WHEN EXISTS (SELECT 1 FROM hits WHERE deny) THEN 0
             WHEN v_role <> 'external' AND EXISTS (SELECT 1 FROM chain WHERE created_by = p_user) THEN 4
             ELSE COALESCE(max(CASE level WHEN 'view' THEN 1 WHEN 'download' THEN 2 WHEN 'upload' THEN 3
                                          WHEN 'manage' THEN 4 END), 0)
           END INTO v_result
    FROM hits WHERE NOT deny;
    RETURN v_result;
END $$;

DO $$
BEGIN
    REVOKE EXECUTE ON FUNCTION files.level(text, bigint, bigint) FROM PUBLIC;
    -- Programs never touch the repository tables: everything goes through the core (ana.files).
    GRANT USAGE ON SCHEMA files TO ana_read;
    GRANT SELECT ON files.folder, files.file, files.file_version, files.event TO ana_read;
END $$;
