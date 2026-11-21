%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Bootstrap configuration from environment variables (spec 001, plan.md).
%% Runtime-tunable values live in ana_settings (spec 011); only connection
%% data, secrets and process-level options stay here.
-module(ana_config).
-export([text/2, integer/2, boolean/2, db/0, db_role/1, role_password/1, timezone/0, node_id/0]).

-spec text(string(), string()) -> string().
text(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        V -> V
    end.

-spec integer(string(), integer()) -> integer().
integer(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        V ->
            try list_to_integer(string:trim(V))
            catch error:badarg -> Default
            end
    end.

-spec boolean(string(), boolean()) -> boolean().
boolean(Name, Default) ->
    case string:lowercase(text(Name, "")) of
        "" -> Default;
        V -> lists:member(V, ["1", "true", "yes"])
    end.

%% Time zone of the deployment (P13): "today" for programs and the database
%% follows the customer, not the server. Validated against the zone database.
-spec timezone() -> string().
timezone() ->
    Tz = text("ANA_TIMEZONE", "UTC"),
    case re:run(Tz, "^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$", [{capture, none}]) of
        match -> Tz;
        nomatch -> "UTC"
    end.

%% Identity of this node in records shared by the cluster (executions, access
%% log, prepared transactions). Without Erlang distribution every node is
%% nonode@nohost, so the host name tells them apart (RF-023-04).
-spec node_id() -> binary().
node_id() ->
    case persistent_term:get({?MODULE, node_id}, undefined) of
        undefined ->
            Id = case node() of
                'nonode@nohost' ->
                    {ok, Host} = inet:gethostname(),
                    list_to_binary("nonode@" ++ Host);
                N -> atom_to_binary(N)
            end,
            persistent_term:put({?MODULE, node_id}, Id),
            Id;
        Id -> Id
    end.

%% Core connection to PostgreSQL (RF-001-02).
-spec db() -> map().
db() ->
    #{host => text("ANA_DB_HOST", "localhost"),
      port => integer("ANA_DB_PORT", 5432),
      database => text("ANA_DB_NAME", "ana"),
      username => text("ANA_DB_USER", "ana"),
      password => text("ANA_DB_PASSWORD", "ana"),
      timeout => 10000,
      application_name => "ana_erp",
      codecs => []}.

%% Connection authenticated as a restricted role (P10): exec for programs,
%% read for the SQL console. Passwords exist only inside the core.
-spec db_role(exec | read) -> map().
db_role(Role) ->
    (db())#{username => "ana_" ++ atom_to_list(Role),
            password => binary_to_list(role_password(Role)),
            application_name => "ana_erp_" ++ atom_to_list(Role)}.

%% ANA_DB_EXEC_PASSWORD / ANA_DB_READ_PASSWORD, or random per boot (secure
%% default for a single node; clusters must set the variables).
-spec role_password(exec | read) -> binary().
role_password(Role) ->
    Key = {?MODULE, password, Role},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Env = "ANA_DB_" ++ string:uppercase(atom_to_list(Role)) ++ "_PASSWORD",
            Password = case text(Env, "") of
                "" -> base64:encode(crypto:strong_rand_bytes(24), #{mode => urlsafe, padding => false});
                V -> list_to_binary(V)
            end,
            persistent_term:put(Key, Password),
            Password;
        P -> P
    end.
