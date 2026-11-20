%% Company values (spec 065, phase 1: T-065-01..06).
%%
%% Small named business values — typed, with validity, per instance and per company of the group — that any
%% routine reads by name (ana.value, base.company_value in SQL) and the company keeps on screen. The definitions
%% and the active versions live in an ETS table on every node (D7): reading a fixed value is a lookup in memory
%% and never writes anything; an expression of the closed list (D5) is one read-only query to its single
%% implementation in the database. A change is written with its trail (before and after, D9) and announced by
%% NOTIFY "ana_value" (a trigger, so only after COMMIT): every node reloads that value and the open screens are
%% woken up. Sensitive values wait for a second person (four eyes, enforced by the database too).
-module(ana_values).

-export([init_cache/0, load/0, reload/1, on_notify/2, read/2, today/0]).
-export([check_set/4, apply_sets/2, names_in/1, usage/1, quality_findings/1, daily_notices/0,
         transport_items/1, item_sha/1, transport_status/1, transport_apply/3, transport_undo/2, missing_in_package/2]).
-export([meta/0, list/2, detail/2, define/2, redefine/3, propose/3, decide/5, withdraw/3, preview/2,
         can_edit/2, secret/1]).

-define(TAB, ana_values_cache).
-define(TYPES, [<<"text">>, <<"integer">>, <<"decimal">>, <<"date">>, <<"boolean">>, <<"month">>, <<"reference">>]).
-define(SHAPES, [<<"single">>, <<"list">>, <<"selection">>]).
-define(INSTANCES, [<<"development">>, <<"test">>, <<"production">>]).
-define(MAX_ITEMS, 1000).

%% ======================================================================= cache (D7)

init_cache() ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    ok.

%% Everything, at start and after the listener (re)connects (notifications may have been missed).
-spec load() -> ok.
load() ->
    case fetch(all) of
        {ok, Entries} ->
            Names = [N || {N, _, _} <- Entries],
            ets:insert(?TAB, Entries),
            Stale = [K || {K, _, _} <- ets:tab2list(?TAB), is_binary(K), not lists:member(K, Names)],
            _ = [ets:delete(?TAB, K) || K <- Stale],
            ets:insert(?TAB, {'$loaded', true, true}),
            ok;
        {error, E} ->
            logger:warning("company values not loaded: ~0p", [E]),
            ok
    end.

reload(Name) ->
    case fetch(Name) of
        {ok, [Entry]} -> ets:insert(?TAB, Entry);
        {ok, []} -> ets:delete(?TAB, Name);
        {error, E} -> logger:warning("company value ~ts not reloaded: ~0p", [Name, E])
    end,
    ok.

on_notify(_Channel, all) ->
    load(),
    ana_events:publish_local(<<"values">>, all);
on_notify(_Channel, Name) when is_binary(Name) ->
    reload(Name),
    ana_events:publish_local(<<"values">>, Name).

fetch(Which) ->
    {Where, Params} = case Which of
        all -> {"", []};
        N -> {" WHERE d.name = $1", [N]}
    end,
    case ana_db:rows(["SELECT d.name, d.description, d.area, d.value_type, d.shape, d.ref_kind, d.sensitive, "
                                   "d.reason_required, d.same_everywhere, d.archived FROM ana_system.company_value d", Where], Params) of
        {ok, Defs} ->
            case ana_db:rows(["SELECT v.id, v.name, v.valid_from::text AS valid_from, v.instance, v.company_id, "
                              "v.content::text AS content, v.expression FROM ana_system.company_value_version v "
                              "JOIN ana_system.company_value d ON d.name = v.name", Where,
                              case Which of all -> " WHERE"; _ -> " AND" end, " v.status = 'active'"], Params) of
                {ok, Vs} ->
                    ByName = lists:foldl(fun(V = #{<<"name">> := N}, Acc) ->
                                             maps:update_with(N, fun(L) -> [version(V) | L] end, [version(V)], Acc)
                                         end, #{}, Vs),
                    {ok, [{N, D, maps:get(N, ByName, [])} || D = #{<<"name">> := N} <- Defs]};
                E -> E
            end;
        E -> E
    end.

version(#{<<"id">> := Id, <<"valid_from">> := F, <<"instance">> := I, <<"company_id">> := C,
          <<"content">> := Content, <<"expression">> := E}) ->
    #{id => Id, valid_from => date(F), valid_from_text => F, instance => I, company => C,
      content => case Content of null -> null; B -> json:decode(B) end, expression => E}.

loaded() ->
    case ets:lookup(?TAB, '$loaded') of
        [_] -> ok;
        [] -> load()
    end.

%% Today in the company's time zone, exact at midnight: asked to the database once a day (and at most hourly).
-spec today() -> calendar:date().
today() ->
    Now = erlang:system_time(second),
    case ets:lookup(?TAB, '$today') of
        [{_, D, Until}] when Now < Until -> D;
        _ ->
            Tz = list_to_binary(ana_config:timezone()),
            case ana_db:one("SELECT (now() AT TIME ZONE $1)::date::text AS d, "
                            "extract(epoch FROM (date_trunc('day', now() AT TIME ZONE $1) + interval '1 day') AT TIME ZONE $1)::bigint AS m",
                            [Tz]) of
                {ok, #{<<"d">> := T, <<"m">> := M}} ->
                    D = date(T),
                    ets:insert(?TAB, {'$today', D, min(M, Now + 3600)}),
                    D;
                _ -> element(1, calendar:universal_time())
            end
    end.

%% ======================================================================= reading (D2, D3, D6)

%% Opts: at (date text or null = today), company (id or null), user (login, for expressions).
-spec read(binary(), map()) -> {ok, map()} | {error, binary(), binary()}.
read(Name, Opts) when is_binary(Name) ->
    loaded(),
    case ets:lookup(?TAB, Name) of
        [{_, #{<<"archived">> := true}, _}] ->
            {error, <<"VALUE_NOT_FOUND">>, <<"valor da empresa arquivado: "/utf8, Name/binary>>};
        [{_, Def, Versions}] ->
            case at(maps:get(at, Opts, null)) of
                {error, M} -> {error, <<"INVALID">>, M};
                {ok, At, Given} ->
                    Company = case maps:get(company, Opts, null) of C when is_integer(C) -> C; _ -> null end,
                    Base = #{name => Name, type => maps:get(<<"value_type">>, Def), shape => maps:get(<<"shape">>, Def),
                             at => iso(At)},
                    case pick(Versions, At, Company, ana_instance:role()) of
                        none -> {ok, Base#{value => null, version => null}};
                        #{expression := null} = V ->
                            {ok, Base#{value => maps:get(content, V), version => maps:get(id, V), valid_from => maps:get(valid_from_text, V)}};
                        #{expression := E} = V ->
                            case expression(E, Given, maps:get(user, Opts, null)) of
                                {ok, X} -> {ok, Base#{value => X, version => maps:get(id, V), expression => E,
                                                      valid_from => maps:get(valid_from_text, V)}};
                                {error, Code, M} -> {error, Code, M}
                            end
                    end
            end;
        [] -> {error, <<"VALUE_NOT_FOUND">>, <<"valor da empresa inexistente: "/utf8, Name/binary>>}
    end;
read(_, _) -> {error, <<"INVALID">>, <<"informe o nome do valor"/utf8>>}.

at(null) -> {ok, today(), null};
at(B) when is_binary(B) ->
    case date(B) of
        bad -> {error, <<"data de referência inválida (use AAAA-MM-DD)"/utf8>>};
        D -> {ok, D, B}
    end;
at(_) -> {error, <<"data de referência inválida (use AAAA-MM-DD)"/utf8>>}.

%% The most specific version (instance and company > instance > company > general), then the most recent.
pick(Versions, At, Company, Instance) ->
    Ok = [{{I =/= null, C =/= null, F}, V} || V = #{valid_from := F, instance := I, company := C} <- Versions,
                                              F =< At, I =:= null orelse I =:= Instance,
                                              C =:= null orelse C =:= Company],
    case lists:reverse(lists:keysort(1, Ok)) of
        [{_, V} | _] -> V;
        [] -> none
    end.

expression(E, At, User) ->
    case ana_db:one("SELECT ana_system.value_expression($1, $2::text::date, $3, true, $4) AS v",
                    [E, At, list_to_binary(ana_config:timezone()), User]) of
        {ok, #{<<"v">> := V}} -> {ok, V};
        {error, #{message := M}} -> coded(M);
        _ -> {error, <<"VALUE_EXPRESSION">>, <<"expressão não resolvida"/utf8>>}
    end.

%% "CODE: message" raised by the database functions.
coded(M) ->
    case re:run(M, <<"^([A-Z_]+): (.*)$">>, [{capture, all_but_first, binary}, dotall]) of
        {match, [C, Text]} -> {error, C, Text};
        nomatch -> {error, <<"INVALID">>, M}
    end.

%% ======================================================================= screen

-spec meta() -> {ok, map()}.
meta() ->
    {ok, Ex} = ana_db:rows("SELECT token, label, result_type, offset_unit FROM base.value_expressions()", []),
    {ok, Kinds} = ana_db:rows("SELECT kind, label FROM ana_system.value_reference_kind ORDER BY label", []),
    {ok, Cos} = ana_db:rows("SELECT id, legal_name FROM base.company ORDER BY id", []),
    {ok, #{expressions => Ex, reference_kinds => Kinds, companies => Cos, instance => ana_instance:role(),
           types => ?TYPES, shapes => ?SHAPES, today => iso(today())}}.

%% All the values with what is in effect today and what comes next, from memory (RNF-065-03); expressions are
%% resolved together in one query.
-spec list(map(), map()) -> {ok, map()}.
list(Filters, User) ->
    loaded(),
    Q = string:lowercase(maps:get(<<"q">>, Filters, <<>>)),
    Area = maps:get(<<"area">>, Filters, <<>>),
    Archived = maps:get(<<"archived">>, Filters, <<"0">>) =:= <<"1">>,
    Today = today(),
    Inst = ana_instance:role(),
    Entries = lists:sort([E || E = {N, #{<<"description">> := D, <<"area">> := A, <<"archived">> := Ar}, _} <- ets:tab2list(?TAB),
                               is_binary(N), Ar =:= false orelse Archived, Area =:= <<>> orelse A =:= Area,
                               Q =:= <<>> orelse string:find(N, Q) =/= nomatch orelse string:find(string:lowercase(D), Q) =/= nomatch]),
    Cur = [{N, pick(Vs, Today, null, Inst)} || {N, _, Vs} <- Entries],
    Exprs = lists:usort([E || {_, #{expression := E}} <- Cur, E =/= null]),
    Resolved = resolve_many(Exprs, maps:get(username, User, null)),
    {ok, Pend} = ana_db:rows("SELECT name, count(*)::int AS n FROM ana_system.company_value_version WHERE status = 'pending' GROUP BY name", []),
    Pending = maps:from_list([{N, C} || #{<<"name">> := N, <<"n">> := C} <- Pend]),
    Editable = editable(User),
    Rows = [maps:merge(maps:with([<<"name">>, <<"description">>, <<"area">>, <<"value_type">>, <<"shape">>, <<"ref_kind">>,
                                 <<"sensitive">>, <<"archived">>], Def),
                       #{current => current(V, Resolved), next => next(Vs, Today, Inst, Resolved),
                         pending => maps:get(N, Pending, 0), can_edit => Editable(N)})
            || {{N, Def, Vs}, {N, V}} <- lists:zip(Entries, Cur)],
    Areas = lists:usort([A || {N, #{<<"area">> := A}, _} <- ets:tab2list(?TAB), is_binary(N)]),
    %% T-065-11: values nobody reads for 180 days are suggested for archiving.
    Unused = unused([N || #{<<"name">> := N} <- Rows]),
    {ok, #{values => [R#{unused => lists:member(N, Unused)} || R = #{<<"name">> := N} <- Rows],
           areas => Areas, today => iso(Today), instance => Inst}}.

current(none, _) -> null;
current(#{expression := null} = V, _) -> #{value => maps:get(content, V), version => maps:get(id, V), valid_from => maps:get(valid_from_text, V)};
current(#{expression := E} = V, R) ->
    #{value => maps:get(E, R, null), expression => E, version => maps:get(id, V), valid_from => maps:get(valid_from_text, V)}.

%% The next version to take effect here (any company), if one is scheduled.
next(Vs, Today, Inst, R) ->
    case lists:sort([{F, V} || V = #{valid_from := F, instance := I} <- Vs, F > Today, I =:= null orelse I =:= Inst]) of
        [{_, V} | _] -> current(V, R);
        [] -> null
    end.

resolve_many([], _) -> #{};
resolve_many(Exprs, User) ->
    case ana_db:rows("SELECT e, ana_system.value_expression(e, NULL, $2, false, $3) AS v FROM unnest($1::text[]) e",
                     [Exprs, list_to_binary(ana_config:timezone()), User]) of
        {ok, Rows} -> maps:from_list([{E, V} || #{<<"e">> := E, <<"v">> := V} <- Rows]);
        _ -> #{}
    end.

-spec detail(binary(), map()) -> {ok, map()} | {error, binary(), binary()}.
detail(Name, User) ->
    case ana_db:one("SELECT name, description, area, value_type, shape, ref_kind, sensitive, reason_required, same_everywhere, "
                    "archived, maintained_by, created_by, created_at FROM ana_system.company_value WHERE name = $1", [Name]) of
        {ok, undefined} -> {error, <<"NOT_FOUND">>, <<"valor da empresa inexistente"/utf8>>};
        {ok, Def} ->
            {ok, Vs} = ana_db:rows(
                "SELECT v.id, v.valid_from::text AS valid_from, v.instance, v.company_id, c.legal_name AS company, "
                "v.content, v.expression, v.status, v.reason, v.requested_by, v.requested_at, v.decided_by, v.decided_at, "
                "v.decision_note FROM ana_system.company_value_version v LEFT JOIN base.company c ON c.id = v.company_id "
                "WHERE v.name = $1 ORDER BY v.valid_from DESC, v.id DESC LIMIT 500", [Name]),
            {ok, Ch} = ana_db:rows("SELECT at, action, username, version_id, before, after, reason, program FROM ana_system.company_value_change "
                                   "WHERE name = $1 ORDER BY at DESC, id DESC LIMIT 200", [Name]),
            Now = case read(Name, #{user => maps:get(username, User, null)}) of
                {ok, R} -> R;
                {error, _, M} -> #{error => M}
            end,
            Labels = labels(maps:get(<<"ref_kind">>, Def), Vs),
            {ok, #{definition => Def, versions => [decoded(V, Labels) || V <- Vs], changes => [decoded(C, #{}) || C <- Ch],
                   usage => usage(Name),
                   current => Now, can_edit => (editable(User))(Name), me => maps:get(username, User, null)}}
    end.

decoded(M, Labels) ->
    M2 = maps:map(fun(K, V) when (K =:= <<"content">> orelse K =:= <<"before">> orelse K =:= <<"after">>), is_binary(V) ->
                          try json:decode(V) catch _:_ -> V end;
                     (_, V) -> V
                  end, M),
    case maps:get(<<"content">>, M2, null) of
        null -> M2;
        C -> M2#{<<"labels">> => maps:with(keys(C), Labels)}
    end.

%% Names of the records a reference value points to, for the screen.
labels(null, _) -> #{};
labels(Kind, Vs) ->
    Keys = lists:usort(lists:append([keys(try json:decode(C) catch _:_ -> null end) || #{<<"content">> := C} <- Vs, is_binary(C)])),
    case Keys of
        [] -> #{};
        _ ->
            case ana_db:rows("SELECT k, ana_system.value_reference_label($1, k) AS l FROM unnest($2::text[]) k", [Kind, Keys]) of
                {ok, Rows} -> maps:from_list([{K, L} || #{<<"k">> := K, <<"l">> := L} <- Rows, L =/= null]);
                _ -> #{}
            end
    end.

keys(B) when is_binary(B) -> [B];
keys(L) when is_list(L) -> lists:append([keys(X) || X <- L]);
keys(M) when is_map(M) -> lists:append([keys(V) || V <- maps:values(M)]);
keys(N) when is_integer(N) -> [integer_to_binary(N)];
keys(_) -> [].

-spec preview(map(), map()) -> {ok, map()} | {error, binary(), binary()}.
preview(#{<<"expression">> := E} = B, User) when is_binary(E) ->
    case expression(E, maps:get(<<"at">>, B, null), maps:get(username, User, null)) of
        {ok, V} -> {ok, #{expression => E, value => V}};
        Err -> Err
    end;
preview(#{<<"name">> := N} = B, User) when is_binary(N) ->
    read(N, #{at => maps:get(<<"at">>, B, null), company => maps:get(<<"company">>, B, null), user => maps:get(username, User, null)});
preview(_, _) -> {error, <<"INVALID">>, <<"informe a expressão ou o nome do valor"/utf8>>}.

%% ======================================================================= governance (D9)

%% Administrators, and groups with the value's name or "area.*" among "Valores da empresa que alteram".
-spec can_edit(map(), binary()) -> boolean().
can_edit(User, Name) -> (editable(User))(Name).

editable(#{role := <<"admin">>}) -> fun(_) -> true end;
editable(#{username := U}) ->
    Patterns = case ana_db:rows("SELECT DISTINCT p FROM ana_system.user_group ug JOIN ana_system.access_group g ON g.name = ug.group_name, "
                                "unnest(g.value_patterns) p WHERE ug.username = $1", [U]) of
        {ok, Rows} -> [P || #{<<"p">> := P} <- Rows];
        _ -> []
    end,
    fun(Name) -> lists:any(fun(P) -> ana_access:matches(P, Name) end, Patterns) end;
editable(_) -> fun(_) -> false end.

%% Secrets are not company values: they belong to the connectors' vault (spec 017).
-spec secret(term()) -> boolean().
secret(B) when is_binary(B) ->
    Patterns = [<<"-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)">>, <<"^(sk|pk|rk)_(live|test)_[A-Za-z0-9]{8,}">>,
                <<"^eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.">>, <<"^gh[pousr]_[A-Za-z0-9]{20,}">>, <<"^AKIA[0-9A-Z]{16}$">>,
                <<"^xox[abprs]-[A-Za-z0-9-]{10,}">>, <<"^AIza[0-9A-Za-z_-]{30,}">>],
    lists:any(fun(P) -> re:run(B, P, [{capture, none}, unicode]) =:= match end, Patterns) orelse random_like(B);
secret(L) when is_list(L) -> lists:any(fun secret/1, L);
secret(M) when is_map(M) -> lists:any(fun secret/1, maps:values(M));
secret(_) -> false.

%% A long word with no spaces mixing upper, lower and digits, with high entropy: looks like a key or a token.
random_like(B) when byte_size(B) >= 24, byte_size(B) =< 4096 ->
    re:run(B, <<"^[A-Za-z0-9+/=_.-]+$">>, [{capture, none}]) =:= match
        andalso re:run(B, <<"[A-Z]">>, [{capture, none}]) =:= match
        andalso re:run(B, <<"[a-z]">>, [{capture, none}]) =:= match
        andalso re:run(B, <<"[0-9]">>, [{capture, none}]) =:= match
        andalso entropy(B) > 4.0;
random_like(_) -> false.

entropy(B) ->
    Counts = lists:foldl(fun(C, M) -> maps:update_with(C, fun(N) -> N + 1 end, 1, M) end, #{}, binary_to_list(B)),
    L = byte_size(B),
    -lists:sum([(N / L) * math:log2(N / L) || N <- maps:values(Counts)]).

secret_name(Name) ->
    re:run(Name, <<"(senha|password|passwd|token|secret|segredo|api_?key|chave_(api|privada|secreta)|credencial|credential|private_key)">>,
           [{capture, none}]) =:= match.

refused_secret() ->
    {error, <<"VALUE_SECRET">>, <<"parece uma credencial: senhas, tokens e chaves não são valores da empresa — guarde no cofre "
                                  "dos conectores (Administração → Integrações)"/utf8>>}.

%% ======================================================================= definition (D1)

-spec define(map(), map()) -> {ok, map()} | {error, binary(), binary()}.
define(#{<<"name">> := Name} = B, User = #{username := Who}) when is_binary(Name) ->
    Type = maps:get(<<"value_type">>, B, <<"text">>),
    Shape = maps:get(<<"shape">>, B, <<"single">>),
    Ref = maps:get(<<"ref_kind">>, B, null),
    Area = case maps:get(<<"area">>, B, null) of
        A when is_binary(A), A =/= <<>> -> A;
        _ -> hd(binary:split(Name, <<".">>))
    end,
    Checks = [{re:run(Name, <<"^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*){1,3}$">>, [{capture, none}]) =:= match andalso byte_size(Name) =< 100,
               <<"nome: minúsculas sem acento, em partes separadas por ponto (ex.: financeiro.margem_minima)"/utf8>>},
              {not secret_name(Name), secret},
              {lists:member(Type, ?TYPES), <<"tipo inválido"/utf8>>},
              {lists:member(Shape, ?SHAPES), <<"forma inválida"/utf8>>},
              {(Type =:= <<"reference">>) =:= is_binary(Ref), <<"um valor que aponta para um cadastro informa qual cadastro"/utf8>>},
              {Shape =/= <<"selection">> orelse lists:member(Type, [<<"text">>, <<"integer">>, <<"reference">>]),
               <<"seleção só para texto, número inteiro ou cadastro"/utf8>>},
              {text_ok(maps:get(<<"description">>, B, <<>>), 3, 300), <<"descreva o valor (3 a 300 caracteres)"/utf8>>}],
    case [M || {false, M} <- Checks] of
        [secret | _] -> refused_secret();
        [M | _] -> {error, <<"INVALID">>, M};
        [] ->
            case can_edit(User, Name) of
                false -> {error, <<"FORBIDDEN">>, <<"você não pode criar valores desta área"/utf8>>};
                true ->
                    Row = #{name => Name, description => string:trim(maps:get(<<"description">>, B)), area => Area,
                            value_type => Type, shape => Shape, ref_kind => Ref,
                            sensitive => maps:get(<<"sensitive">>, B, false) =:= true,
                            reason_required => maps:get(<<"reason_required">>, B, false) =:= true,
                            same_everywhere => maps:get(<<"same_everywhere">>, B, false) =:= true,
                            maintained_by => keepers(maps:get(<<"maintained_by">>, B, []))},
                    tx(fun(C) ->
                        case ana_db:query(C, "INSERT INTO ana_system.company_value (name, description, area, value_type, shape, ref_kind, "
                                             "sensitive, reason_required, same_everywhere, created_by, maintained_by) "
                                             "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)",
                                          [Name, maps:get(description, Row), Area, Type, Shape, Ref, maps:get(sensitive, Row),
                                           maps:get(reason_required, Row), maps:get(same_everywhere, Row), Who, maps:get(maintained_by, Row)]) of
                            {ok, _} ->
                                change(C, Name, <<"defined">>, Who, null, null, Row, null),
                                {ok, Row};
                            {error, #{sqlstate := <<"23505">>}} -> {error, <<"CONFLICT">>, <<"já existe um valor com esse nome"/utf8>>};
                            {error, #{sqlstate := <<"23503">>}} -> {error, <<"INVALID">>, <<"cadastro de referência desconhecido"/utf8>>};
                            {error, #{message := M}} -> {error, <<"INVALID">>, M}
                        end
                    end, Who, Name, <<"value.define">>)
            end
    end;
define(_, _) -> {error, <<"INVALID">>, <<"informe o nome do valor"/utf8>>}.

%% Description, area and rules; the type and the form only while there is no version (the content would no
%% longer fit). Archiving keeps the history; an archived value is no longer read.
-spec redefine(binary(), map(), map()) -> {ok, map()} | {error, binary(), binary()}.
redefine(Name, B, User = #{username := Who}) ->
    case ana_db:one("SELECT name, description, area, value_type, shape, ref_kind, sensitive, reason_required, same_everywhere, archived, "
                    "maintained_by, EXISTS (SELECT 1 FROM ana_system.company_value_version v WHERE v.name = d.name) AS used "
                    "FROM ana_system.company_value d WHERE name = $1", [Name]) of
        {ok, undefined} -> {error, <<"NOT_FOUND">>, <<"valor da empresa inexistente"/utf8>>};
        {ok, Old} ->
            New = maps:merge(maps:remove(<<"used">>, Old),
                             (maps:with([<<"description">>, <<"area">>, <<"value_type">>, <<"shape">>, <<"ref_kind">>, <<"sensitive">>,
                                         <<"reason_required">>, <<"same_everywhere">>, <<"archived">>], B))
                             #{<<"maintained_by">> => keepers(maps:get(<<"maintained_by">>, B, maps:get(<<"maintained_by">>, Old)))}),
            Shape = [maps:get(K, New) || K <- [<<"value_type">>, <<"shape">>, <<"ref_kind">>]],
            Checks = [{can_edit(User, Name), forbidden},
                      {not maps:get(<<"used">>, Old) orelse Shape =:= [maps:get(K, Old) || K <- [<<"value_type">>, <<"shape">>, <<"ref_kind">>]],
                       <<"o tipo e a forma não mudam depois que o valor tem versões: crie outro valor"/utf8>>},
                      {lists:member(maps:get(<<"value_type">>, New), ?TYPES) andalso lists:member(maps:get(<<"shape">>, New), ?SHAPES),
                       <<"tipo ou forma inválidos"/utf8>>},
                      {text_ok(maps:get(<<"description">>, New), 3, 300), <<"descreva o valor (3 a 300 caracteres)"/utf8>>},
                      {lists:all(fun is_boolean/1, [maps:get(K, New) || K <- [<<"sensitive">>, <<"reason_required">>,
                                                                             <<"same_everywhere">>, <<"archived">>]]),
                       <<"opções devem ser sim ou não"/utf8>>}],
            case [M || {false, M} <- Checks] of
                [forbidden | _] -> {error, <<"FORBIDDEN">>, <<"você não pode alterar valores desta área"/utf8>>};
                [M | _] -> {error, <<"INVALID">>, M};
                [] ->
                    Action = case {maps:get(<<"archived">>, Old), maps:get(<<"archived">>, New)} of
                        {false, true} -> <<"archived">>;
                        {true, false} -> <<"restored">>;
                        _ -> <<"redefined">>
                    end,
                    Before = maps:remove(<<"used">>, Old),
                    tx(fun(C) ->
                        case ana_db:query(C, "UPDATE ana_system.company_value SET description = $2, area = $3, value_type = $4, shape = $5, "
                                             "ref_kind = $6, sensitive = $7, reason_required = $8, same_everywhere = $9, archived = $10, "
                                             "maintained_by = $11 WHERE name = $1",
                                          [Name | [maps:get(K, New) || K <- [<<"description">>, <<"area">>, <<"value_type">>, <<"shape">>,
                                                                             <<"ref_kind">>, <<"sensitive">>, <<"reason_required">>,
                                                                             <<"same_everywhere">>, <<"archived">>, <<"maintained_by">>]]]) of
                            {ok, _} ->
                                change(C, Name, Action, Who, null, Before, New, null),
                                {ok, New};
                            {error, #{message := M}} -> {error, <<"INVALID">>, M}
                        end
                    end, Who, Name, <<"value.", Action/binary>>)
            end
    end.

%% ======================================================================= versions (D2, D3, D5, D9)

%% A new version: content or expression, from a date, for this or every instance and company. The past is never
%% rewritten: a version starts today or later (only the first one of a value may start earlier).
-spec propose(binary(), map(), map()) -> {ok, map()} | {error, binary(), binary()}.
propose(Name, B, User = #{username := Who}) ->
    case ana_db:one("SELECT name, value_type, shape, ref_kind, sensitive, reason_required, archived, "
                    "EXISTS (SELECT 1 FROM ana_system.company_value_version v WHERE v.name = d.name AND v.status = 'active') AS has_active "
                    "FROM ana_system.company_value d WHERE name = $1", [Name]) of
        {ok, undefined} -> {error, <<"NOT_FOUND">>, <<"valor da empresa inexistente"/utf8>>};
        {ok, #{<<"archived">> := true}} -> {error, <<"INVALID">>, <<"valor arquivado: restaure-o antes de mudar"/utf8>>};
        {ok, Def} ->
            Today = today(),
            From = case maps:get(<<"valid_from">>, B, null) of
                null -> Today;
                F when is_binary(F) -> date(F);
                _ -> bad
            end,
            Reason = case maps:get(<<"reason">>, B, null) of R when is_binary(R) -> string:trim(R); _ -> <<>> end,
            Instance = maps:get(<<"instance">>, B, null),
            Company = maps:get(<<"company_id">>, B, null),
            Pre = [{can_edit(User, Name), forbidden},
                   {From =/= bad, <<"vigência: data inválida (AAAA-MM-DD)"/utf8>>},
                   {From =:= bad orelse From >= Today orelse not maps:get(<<"has_active">>, Def),
                    <<"o passado não se reescreve: a vigência começa hoje ou depois"/utf8>>},
                   {Instance =:= null orelse lists:member(Instance, ?INSTANCES), <<"instância inválida"/utf8>>},
                   {Company =:= null orelse is_integer(Company), <<"empresa inválida"/utf8>>},
                   {not maps:get(<<"reason_required">>, Def) orelse byte_size(Reason) >= 5, <<"explique o motivo da mudança"/utf8>>},
                   {byte_size(Reason) =< 500, <<"motivo longo demais (até 500 caracteres)"/utf8>>}],
            case [M || {false, M} <- Pre] of
                [forbidden | _] -> {error, <<"FORBIDDEN">>, <<"você não pode alterar valores desta área"/utf8>>};
                [M | _] -> {error, <<"INVALID">>, M};
                [] ->
                    case content(Def, B, User) of
                        {error, _, _} = E -> E;
                        {ok, Content, Expr} ->
                            Status = case maps:get(<<"sensitive">>, Def) of true -> <<"pending">>; false -> <<"active">> end,
                            insert_version(Name, #{from => iso(From), instance => Instance, company => Company, content => Content,
                                                   expression => Expr, status => Status,
                                                   reason => case Reason of <<>> -> null; _ -> Reason end}, Who)
                    end
            end
    end.

insert_version(Name, V = #{from := From, instance := I, company := Co, status := Status}, Who) ->
    tx(fun(C) ->
        Old = case Status of
            <<"active">> -> replace(C, Name, From, I, Co);
            _ -> null
        end,
        case ana_db:query(C, "INSERT INTO ana_system.company_value_version (name, valid_from, instance, company_id, content, expression, "
                             "status, reason, requested_by) VALUES ($1, $2::date, $3, $4, $5::jsonb, $6, $7, $8, $9) RETURNING id",
                          [Name, From, I, Co, json_text(maps:get(content, V)), maps:get(expression, V), Status, maps:get(reason, V), Who]) of
            {ok, #{rows := [[Id]]}} ->
                After = shown(V),
                change(C, Name, case Status of <<"active">> -> <<"activated">>; _ -> <<"requested">> end, Who, Id, Old, After,
                       maps:get(reason, V)),
                {ok, #{id => Id, status => Status, valid_from => From}};
            {error, #{sqlstate := <<"23505">>}} ->
                {error, <<"CONFLICT">>, <<"já há um pedido pendente para essa vigência: aprove, recuse ou retire antes"/utf8>>};
            {error, #{sqlstate := <<"23503">>}} -> {error, <<"INVALID">>, <<"empresa inexistente"/utf8>>};
            {error, #{message := M}} -> {error, <<"INVALID">>, M}
        end
    end, Who, Name, <<"value.version">>).

%% The active version in the same place (same date, instance and company) gives way to the new one.
replace(C, Name, From, I, Co) ->
    case ana_db:query(C, "UPDATE ana_system.company_value_version SET status = 'replaced' WHERE name = $1 AND status = 'active' "
                         "AND valid_from = $2::date AND instance IS NOT DISTINCT FROM $3 AND company_id IS NOT DISTINCT FROM $4 "
                         "RETURNING content::text, expression", [Name, From, I, Co]) of
        {ok, #{rows := [[Content, E] | _]}} -> #{content => case Content of null -> null; B -> json:decode(B) end, expression => E};
        _ -> null
    end.

shown(V) -> maps:filter(fun(_, X) -> X =/= null end, maps:with([content, expression, from, instance, company], V)).

-spec decide(binary(), integer(), binary(), binary() | null, map()) -> {ok, map()} | {error, binary(), binary()}.
decide(Name, Id, Decision, Note, User = #{username := Who}) when Decision =:= <<"approve">>; Decision =:= <<"refuse">> ->
    case ana_db:one("SELECT id, valid_from::text AS valid_from, instance, company_id, content::text AS content, expression, requested_by, "
                    "EXISTS (SELECT 1 FROM ana_system.company_value_version a WHERE a.name = $2 AND a.status = 'active') AS has_active "
                    "FROM ana_system.company_value_version WHERE id = $1 AND name = $2 AND status = 'pending'", [Id, Name]) of
        {ok, undefined} -> {error, <<"NOT_FOUND">>, <<"pedido não encontrado ou já decidido"/utf8>>};
        {ok, #{<<"requested_by">> := Who}} -> {error, <<"FOUR_EYES">>, <<"quatro olhos: quem pediu a mudança não pode decidi-la"/utf8>>};
        {ok, P = #{<<"valid_from">> := From}} ->
            %% The same rule as the request: the past is not rewritten (only the first version of a value may start earlier).
            case {can_edit(User, Name), Decision =:= <<"refuse">> orelse date(From) >= today() orelse not maps:get(<<"has_active">>, P)} of
                {false, _} -> {error, <<"FORBIDDEN">>, <<"você não pode decidir mudanças desta área"/utf8>>};
                {true, false} -> {error, <<"INVALID">>, <<"a vigência pedida já passou: recuse e peça de novo com outra data"/utf8>>};
                {true, true} ->
                    Status = case Decision of <<"approve">> -> <<"active">>; _ -> <<"refused">> end,
                    tx(fun(C) ->
                        Old = case Status of
                            <<"active">> -> replace(C, Name, From, maps:get(<<"instance">>, P), maps:get(<<"company_id">>, P));
                            _ -> null
                        end,
                        case ana_db:query(C, "UPDATE ana_system.company_value_version SET status = $2, decided_by = $3, decided_at = now(), "
                                             "decision_note = $4 WHERE id = $1 AND status = 'pending'", [Id, Status, Who, Note]) of
                            {ok, #{affected := 1}} ->
                                change(C, Name, case Status of <<"active">> -> <<"approved">>; _ -> <<"refused">> end, Who, Id, Old,
                                       #{content => case maps:get(<<"content">>, P) of null -> null; B -> json:decode(B) end,
                                         expression => maps:get(<<"expression">>, P), from => From}, Note),
                                {ok, #{id => Id, status => Status}};
                            {ok, _} -> {error, <<"NOT_FOUND">>, <<"pedido já decidido"/utf8>>};
                            {error, #{sqlstate := <<"23514">>}} ->
                                {error, <<"FOUR_EYES">>, <<"quatro olhos: quem pediu a mudança não pode decidi-la"/utf8>>};
                            {error, #{message := M}} -> {error, <<"INVALID">>, M}
                        end
                    end, Who, Name, <<"value.", Decision/binary>>)
            end
    end;
decide(_, _, _, _, _) -> {error, <<"INVALID">>, <<"decisão deve ser approve ou refuse"/utf8>>}.

%% A pending request (by whoever asked or an editor) or a version still to come can be withdrawn; the past stays.
-spec withdraw(binary(), integer(), map()) -> {ok, map()} | {error, binary(), binary()}.
withdraw(Name, Id, User = #{username := Who}) ->
    case ana_db:one("SELECT status, valid_from > (now() AT TIME ZONE $3)::date AS future, requested_by FROM ana_system.company_value_version "
                    "WHERE id = $1 AND name = $2", [Id, Name, list_to_binary(ana_config:timezone())]) of
        {ok, undefined} -> {error, <<"NOT_FOUND">>, <<"versão não encontrada"/utf8>>};
        {ok, #{<<"status">> := S, <<"future">> := F, <<"requested_by">> := R}} ->
            Allowed = (S =:= <<"pending">> andalso (R =:= Who orelse can_edit(User, Name)))
                      orelse (S =:= <<"active">> andalso F andalso can_edit(User, Name)),
            case Allowed of
                false when S =:= <<"active">>; S =:= <<"pending">> ->
                    {error, <<"INVALID">>, <<"só se retira um pedido pendente ou uma versão que ainda não começou"/utf8>>};
                false -> {error, <<"INVALID">>, <<"esta versão já não está em uso"/utf8>>};
                true ->
                    tx(fun(C) ->
                        {ok, _} = ana_db:query(C, "UPDATE ana_system.company_value_version SET status = 'withdrawn' WHERE id = $1", [Id]),
                        change(C, Name, <<"withdrawn">>, Who, Id, #{status => S}, #{status => <<"withdrawn">>}, null),
                        {ok, #{id => Id, status => <<"withdrawn">>}}
                    end, Who, Name, <<"value.withdraw">>)
            end
    end.

%% Content of a version, checked against the type and the form of the value (D1), or an expression (D5).
content(Def = #{<<"value_type">> := Type}, #{<<"expression">> := E}, User) when is_binary(E), E =/= <<>> ->
    {ok, Ex} = ana_db:rows("SELECT token, result_type FROM base.value_expressions()", []),
    Tok = hd(binary:split(E, [<<"+">>, <<"-">>])),
    Result = [R || #{<<"token">> := T, <<"result_type">> := R} <- Ex, T =:= Tok],
    Fits = case Result of
        [<<"date">>] -> Type =:= <<"date">>;
        [<<"month">>] -> Type =:= <<"month">>;
        [<<"datetime">>] -> Type =:= <<"text">>;
        [<<"text">>] -> Type =:= <<"text">>;
        [<<"cost_center">>] -> Type =:= <<"text">> orelse maps:get(<<"ref_kind">>, Def) =:= <<"cost_center">>;
        _ -> false
    end,
    if
        Result =:= [] -> {error, <<"INVALID">>, <<"expressão fora da lista"/utf8>>};
        not Fits -> {error, <<"INVALID">>, <<"o resultado dessa expressão não é do tipo do valor"/utf8>>};
        true ->
            case maps:get(<<"shape">>, Def) of
                <<"single">> ->
                    case maps:get(<<"name">>, Def) =:= <<"financeiro.periodo_aberto">> andalso Tok =:= <<"open_period">> of
                        true -> {error, <<"INVALID">>, <<"o período aberto não pode ser definido por ele mesmo"/utf8>>};
                        false ->
                            case expression(E, null, maps:get(username, User, null)) of
                                {ok, _} -> {ok, null, E};
                                Err -> Err
                            end
                    end;
                _ -> {error, <<"INVALID">>, <<"expressões valem para valores simples (não lista nem seleção)"/utf8>>}
            end
    end;
content(Def, #{<<"content">> := V}, _User) ->
    case secret(V) of
        true -> refused_secret();
        false ->
            case shape(maps:get(<<"shape">>, Def), maps:get(<<"value_type">>, Def), V) of
                {ok, Norm} ->
                    case maps:get(<<"ref_kind">>, Def) of
                        null -> {ok, Norm, null};
                        Kind ->
                            case missing(Kind, lists:usort(keys(Norm))) of
                                [] -> {ok, Norm, null};
                                Miss -> {error, <<"INVALID">>, iolist_to_binary([<<"não encontrado no cadastro: "/utf8>>,
                                                                                 lists:join(<<", ">>, Miss)])}
                            end
                    end;
                {error, M} -> {error, <<"INVALID">>, M}
            end
    end;
content(_, _, _) -> {error, <<"INVALID">>, <<"informe o valor (content) ou uma expressão"/utf8>>}.

missing(_, []) -> [];
missing(Kind, Keys) ->
    {ok, Rows} = ana_db:rows("SELECT k FROM unnest($2::text[]) k WHERE ana_system.value_reference_label($1, k) IS NULL", [Kind, Keys]),
    [K || #{<<"k">> := K} <- Rows].

shape(<<"single">>, T, V) -> typed(T, V);
shape(<<"list">>, T, L) when is_list(L), length(L) =< ?MAX_ITEMS ->
    case all_typed(T, L) of
        {ok, Xs} when length(Xs) =:= length(L) ->
            case length(lists:usort(Xs)) =:= length(Xs) of
                true -> {ok, Xs};
                false -> {error, <<"a lista tem itens repetidos"/utf8>>}
            end;
        E -> E
    end;
shape(<<"list">>, _, _) -> {error, <<"uma lista de até 1000 itens"/utf8>>};
shape(<<"selection">>, T, M) when is_map(M) ->
    Known = [<<"include">>, <<"exclude">>, <<"ranges">>, <<"prefixes">>],
    case maps:keys(M) -- Known of
        [] ->
            R = [{K, sel_part(K, T, maps:get(K, M))} || K <- Known, maps:is_key(K, M)],
            case [E || {_, {error, E}} <- R] of
                [] -> {ok, maps:from_list([{K, X} || {K, {ok, X}} <- R, X =/= []])};
                [E | _] -> {error, E}
            end;
        _ -> {error, <<"seleção: use include, exclude, ranges e prefixes"/utf8>>}
    end;
shape(<<"selection">>, _, _) -> {error, <<"seleção: use include, exclude, ranges e prefixes"/utf8>>};
shape(_, _, _) -> {error, <<"forma inválida"/utf8>>}.

sel_part(K, T, L) when (K =:= <<"include">> orelse K =:= <<"exclude">>), is_list(L), length(L) =< ?MAX_ITEMS -> all_typed(T, L);
sel_part(<<"prefixes">>, T, L) when T =/= <<"integer">>, is_list(L), length(L) =< ?MAX_ITEMS ->
    case lists:all(fun(P) -> is_binary(P) andalso P =/= <<>> andalso byte_size(P) =< 100 end, L) of
        true -> {ok, L};
        false -> {error, <<"seleção: prefixos são textos"/utf8>>}
    end;
sel_part(<<"ranges">>, T, L) when is_list(L), length(L) =< ?MAX_ITEMS ->
    Rs = [case R of [A, B] -> {typed(T, A), typed(T, B)}; _ -> bad end || R <- L],
    case lists:all(fun({{ok, _}, {ok, _}}) -> true; (_) -> false end, Rs) of
        true -> {ok, [[A, B] || {{ok, A}, {ok, B}} <- Rs]};
        false -> {error, <<"seleção: cada faixa é [de, até]"/utf8>>}
    end;
sel_part(_, _, _) -> {error, <<"seleção inválida"/utf8>>}.

all_typed(T, L) ->
    R = [typed(T, X) || X <- L],
    case [E || {error, E} <- R] of
        [] -> {ok, [X || {ok, X} <- R]};
        [E | _] -> {error, E}
    end.

%% Typed JSON: integers and booleans as such; decimals as exact text ("18.5"); dates and months as text;
%% references as the record's key in text.
typed(<<"text">>, V) when is_binary(V) ->
    T = string:trim(V),
    case byte_size(T) =< 1000 of
        true -> {ok, T};
        false -> {error, <<"texto longo demais (até 1000 caracteres)"/utf8>>}
    end;
typed(<<"integer">>, V) when is_integer(V) -> {ok, V};
typed(<<"integer">>, V) when is_binary(V) ->
    try {ok, binary_to_integer(string:trim(V))} catch _:_ -> {error, <<"número inteiro inválido"/utf8>>} end;
typed(<<"decimal">>, V) when is_integer(V) -> {ok, integer_to_binary(V)};
typed(<<"decimal">>, V) when is_float(V) -> {ok, float_to_binary(V, [short])};
typed(<<"decimal">>, V) when is_binary(V) ->
    D = binary:replace(string:trim(V), <<",">>, <<".">>),
    case re:run(D, <<"^-?[0-9]{1,18}(\\.[0-9]{1,10})?$">>, [{capture, none}]) of
        match -> {ok, D};
        nomatch -> {error, <<"número decimal inválido"/utf8>>}
    end;
typed(<<"date">>, V) when is_binary(V) ->
    case date(V) of
        bad -> {error, <<"data inválida (AAAA-MM-DD)"/utf8>>};
        D -> {ok, iso(D)}
    end;
typed(<<"month">>, V) when is_binary(V) ->
    case re:run(V, <<"^([0-9]{4})-(0[1-9]|1[0-2])$">>, [{capture, none}]) of
        match -> {ok, V};
        nomatch -> {error, <<"mês inválido (AAAA-MM)"/utf8>>}
    end;
typed(<<"boolean">>, V) when is_boolean(V) -> {ok, V};
typed(<<"reference">>, V) when is_integer(V) -> {ok, integer_to_binary(V)};
typed(<<"reference">>, V) when is_binary(V), V =/= <<>>, byte_size(V) =< 100 -> {ok, string:trim(V)};
typed(T, _) -> {error, <<"valor não é do tipo "/utf8, T/binary>>}.

%% ======================================================================= phase 2: kept by routines (D4, RF-065-07)

%% ana.set_value: checked now (the routine may keep it, the content fits), written right after the routine's COMMIT —
%% a routine that fails changes nothing. Returns the change to apply later.
-spec check_set(binary(), map(), binary(), map()) -> {ok, map()} | {error, binary(), binary()}.
check_set(Name, A, Program, User) when is_binary(Name) ->
    case ana_db:one("SELECT name, value_type, shape, ref_kind, archived, maintained_by FROM ana_system.company_value WHERE name = $1",
                    [Name]) of
        {ok, undefined} -> {error, <<"VALUE_NOT_FOUND">>, <<"valor da empresa inexistente: "/utf8, Name/binary>>};
        {ok, #{<<"archived">> := true}} -> {error, <<"VALUE_NOT_FOUND">>, <<"valor da empresa arquivado: "/utf8, Name/binary>>};
        {ok, Def = #{<<"maintained_by">> := Keepers}} ->
            case lists:member(Program, Keepers) of
                false -> {error, <<"FORBIDDEN">>, iolist_to_binary([<<"o programa "/utf8>>, Program, <<" não mantém o valor "/utf8>>, Name,
                                                                   <<" (veja \"Mantido pelas rotinas\" na definição do valor)"/utf8>>])};
                true ->
                    Today = today(),
                    From = case maps:get(<<"valid_from">>, A, null) of null -> iso(Today); F -> F end,
                    case {date(From), content(Def#{<<"name">> => Name}, #{<<"content">> => maps:get(<<"value">>, A, null)}, User)} of
                        {bad, _} -> {error, <<"INVALID">>, <<"vigência: data inválida (AAAA-MM-DD)"/utf8>>};
                        {D, _} when D < Today -> {error, <<"INVALID">>, <<"o passado não se reescreve: a vigência começa hoje ou depois"/utf8>>};
                        {_, {ok, Norm, _}} ->
                            Before = case read(Name, #{user => maps:get(username, User, null)}) of {ok, #{value := V}} -> V; _ -> null end,
                            {ok, #{name => Name, value => Norm, from => From, before => Before, program => Program,
                                   reason => maps:get(<<"reason">>, A, null)}};
                        {_, {error, C, M}} -> {error, C, M}
                    end
            end;
        {error, #{message := M}} -> {error, <<"INVALID">>, M}
    end;
check_set(_, _, _, _) -> {error, <<"INVALID">>, <<"informe o nome do valor"/utf8>>}.

%% After the COMMIT of the routine: one version each, recorded as kept by the routine for its user.
-spec apply_sets([map()], map()) -> ok.
apply_sets([], _) -> ok;
apply_sets(Sets, #{username := Who}) ->
    _ = [case ana_db:transaction(fun(C) ->
                 Old = replace(C, N, F, null, null),
                 {ok, #{rows := [[Id]]}} = ana_db:query(C,
                     "INSERT INTO ana_system.company_value_version (name, valid_from, content, status, reason, requested_by) "
                     "VALUES ($1, $2::date, $3::jsonb, 'active', $4, $5) RETURNING id", [N, F, json_text(V), R, Who]),
                 {ok, _} = ana_db:query(C, "INSERT INTO ana_system.company_value_change (name, action, username, version_id, before, after, "
                                           "reason, program) VALUES ($1, 'kept', $2, $3, $4::jsonb, $5::jsonb, $6, $7)",
                                        [N, Who, Id, json_text(case Old of null -> #{value => B}; _ -> Old end),
                                         json_text(#{content => V, from => F}), R, P]),
                 {ok, Id}
             end) of
             {ok, _} -> reload(N);
             E -> logger:error("company value ~ts not kept after the routine ~ts: ~0p", [N, P, E])
         end || #{name := N, value := V, from := F, before := B, program := P, reason := R} <- Sets],
    ok.

%% ======================================================================= phase 2: where it is used (D8, RF-065-08)

%% Names of company values written literally in a program: ana.value("x"), ana.set_value("x"), base.company_value('x')
%% in SQL and {{valor:x}} in templates — with the line of the first use.
-spec names_in(binary()) -> [{binary(), pos_integer()}].
names_in(Source) when is_binary(Source) ->
    N = <<"([a-z][a-z0-9_]*(?:\\.[a-z][a-z0-9_]*){1,3})">>,
    Pats = [<<"ana\\.(?:set_)?value\\(\\s*[\"']", N/binary, "[\"']">>,
            <<"company_value(?:_list|_matches)?\\(\\s*\\\\?[\"']", N/binary, "\\\\?[\"']">>,
            <<"\\{\\{valor:", N/binary, "\\}\\}">>],
    Hits = lists:append([case re:run(Source, P, [global, {capture, [1], index}]) of
                             {match, L} -> [{binary:part(Source, Pos, Len), Pos} || [{Pos, Len}] <- L];
                             nomatch -> []
                         end || P <- Pats]),
    First = lists:foldl(fun({Nm, Pos}, Acc) -> maps:update_with(Nm, fun(P0) -> min(P0, Pos) end, Pos, Acc) end, #{}, Hits),
    lists:sort([{Nm, line_of(Source, Pos)} || {Nm, Pos} <- maps:to_list(First)]);
names_in(_) -> [].

line_of(Source, Pos) -> length(binary:matches(binary:part(Source, 0, Pos), <<"\n">>)) + 1.

%% Who reads or keeps the value: programs, variants, schedules, alert rules, processes and tax rules; and the reads
%% recorded by the executions of the last 180 days. Shown before changing or archiving it.
-spec usage(binary()) -> map().
usage(Name) ->
    Like = <<"%", Name/binary, "%">>,
    Tpl = <<"%{{valor:", Name/binary, "}}%">>,
    Rows = fun(Sql, P) -> case ana_db:rows(Sql, P) of {ok, R} -> R; _ -> [] end end,
    Progs = [#{name => P, line => L, keeps => binary:match(S, <<"set_value">>) =/= nomatch andalso keeps(S, Name)}
             || #{<<"name">> := P, <<"source">> := S} <- Rows("SELECT name, source FROM ana_system.program WHERE active AND kind = 'program' "
                                                          "AND source LIKE $1 ORDER BY name", [Like]),
                {Nm, L} <- names_in(S), Nm =:= Name],
    Libs = [#{name => P, line => L}
            || #{<<"name">> := P, <<"source">> := S} <- Rows("SELECT name, source FROM ana_system.program WHERE active AND kind = 'library' "
                                                          "AND source LIKE $1 ORDER BY name", [Like]),
               {Nm, L} <- names_in(S), Nm =:= Name],
    Reads = case ana_db:one("SELECT count(*)::int AS n, max(started_at) AS last FROM ana_system.execution "
                            "WHERE values_read IS NOT NULL AND started_at > now() - interval '180 days' "
                            "AND EXISTS (SELECT 1 FROM jsonb_object_keys(values_read) k WHERE k = $1 OR k LIKE $1 || '@%')", [Name]) of
        {ok, R} -> R;
        _ -> #{}
    end,
    #{programs => Progs, libraries => Libs,
      maintained_by => case ana_db:one("SELECT maintained_by FROM ana_system.company_value WHERE name = $1", [Name]) of
                           {ok, #{<<"maintained_by">> := M}} -> M; _ -> [] end,
      variants => Rows("SELECT id, program, name, owner IS NULL AS company FROM ana_system.run_variant "
                       "WHERE jsonb_path_exists(entries, '$.*.company_value ? (@ == $n)', jsonb_build_object('n', $1::text)) "
                       "ORDER BY program, name", [Name]),
      schedules => Rows("SELECT id, name, program FROM scheduler.job WHERE params::text LIKE $1 ORDER BY name", [Tpl]),
      alert_rules => Rows("SELECT id, name FROM ana_system.alert_rule WHERE threshold_value = $1 ORDER BY name", [Name]),
      processes => Rows("SELECT DISTINCT p.code, p.name FROM bpm.version v JOIN bpm.process p ON p.code = v.process_code "
                        "WHERE v.status = 'published' AND v.model::text LIKE $1 ORDER BY p.name", [Tpl]),
      flows => Rows("SELECT DISTINCT d.code, d.name FROM flow.step s JOIN flow.definition d ON d.code = s.flow_code "
                    "WHERE s.condition::text LIKE $1 OR s.params::text LIKE $1 ORDER BY d.name", [Tpl]),
      tax_rules => Rows("SELECT id, name FROM tax.rule WHERE status = 'active' AND formulas::text LIKE $1 ORDER BY name",
                        [<<"%company_value(%", Name/binary, "%">>]),
      reads => Reads}.

keeps(Source, Name) ->
    re:run(Source, <<"ana\\.set_value\\(\\s*[\"']", Name/binary, "[\"']">>, [{capture, none}]) =:= match.

%% Values nobody reads (no program, variant, schedule or rule names it, no execution read it in 180 days) and that
%% exist for that long: suggested for archiving (T-065-11).
unused(Names) ->
    {ok, Old} = ana_db:rows("SELECT name FROM ana_system.company_value WHERE NOT archived AND created_at < now() - interval '180 days' "
                            "AND name = ANY($1::text[])", [Names]),
    Cands = [N || #{<<"name">> := N} <- Old],
    case Cands of
        [] -> [];
        _ ->
            {ok, Read} = ana_db:rows("SELECT DISTINCT split_part(k, '@', 1) AS n FROM ana_system.execution, jsonb_object_keys(values_read) k "
                                     "WHERE values_read IS NOT NULL AND started_at > now() - interval '180 days'", []),
            R = [N || #{<<"n">> := N} <- Read],
            [N || N <- Cands, not lists:member(N, R), static_unused(N)]
    end.

static_unused(N) ->
    U = usage(N),
    lists:all(fun(K) -> maps:get(K, U) =:= [] end, [programs, libraries, maintained_by, variants, schedules, alert_rules,
                                                     processes, flows, tax_rules]).

%% ======================================================================= phase 2: quality gate and editor (D8, T-065-11)

%% Findings for the editor and the gate (spec 064): a name that does not exist (blocks: the routine would fail in
%% production) and a constant written in the code that is already a company value (a suggestion).
-spec quality_findings(binary()) -> [map()].
quality_findings(Source) when is_binary(Source) ->
    loaded(),
    Lines = binary:split(Source, <<"\n">>, [global]),
    LineText = fun(L) -> case L =< length(Lines) of true -> string:trim(lists:nth(L, Lines)); false -> <<>> end end,
    Unknown = [finding(<<"company_value_unknown">>, <<"serious">>, <<"robustness">>, L, LineText(L),
                       <<"valor da empresa inexistente: "/utf8, N/binary>>,
                       <<"crie-o em Administração → Valores da empresa ou corrija o nome"/utf8>>)
               || {N, L} <- names_in(Source), ets:lookup(?TAB, N) =:= []],
    Known = constants(),
    Const = case map_size(Known) of
        0 -> [];
        _ ->
            Lits = case re:run(Source, <<"([\"'])([^\"'\\\\\\n]{3,60})\\1|\\b([0-9]+\\.[0-9]+)\\b">>,
                               [global, {capture, all, index}]) of
                {match, Ms} -> Ms;
                nomatch -> []
            end,
            lists:usort([{L, Txt, maps:get(Txt, Known)} ||
                         M <- Lits, {Pos, Txt} <- [literal(Source, M)], maps:is_key(Txt, Known),
                         L <- [line_of(Source, Pos)],
                         binary:match(LineText(L), [<<"ana.value">>, <<"company_value">>, <<"ana:">>, <<"PARAMS">>]) =:= nomatch])
    end,
    Unknown ++ [finding(<<"company_value_constant">>, <<"info">>, <<"standards">>, L, LineText(L),
                        iolist_to_binary([<<"constante \""/utf8>>, Txt, <<"\" já é o valor da empresa "/utf8>>, N]),
                        iolist_to_binary([<<"use ana.value(\""/utf8>>, N, <<"\"): quando a empresa mudar o valor, a rotina acompanha"/utf8>>]))
                || {L, Txt, N} <- Const];
quality_findings(_) -> [].

literal(Source, [{_, _}, _, {P, Len}]) when P >= 0 -> {P, binary:part(Source, P, Len)};
literal(Source, [{_, _}, _, _, {P, Len}]) when P >= 0 -> {P, binary:part(Source, P, Len)};
literal(_, _) -> {0, <<>>}.

%% Text and number contents in effect today of simple values (three characters or more): content → name.
constants() ->
    Today = today(),
    Inst = ana_instance:role(),
    maps:from_list([{T, N} || {N, #{<<"shape">> := <<"single">>, <<"archived">> := false}, Vs} <- ets:tab2list(?TAB), is_binary(N),
                              #{content := C} <- [pick(Vs, Today, null, Inst)],
                              T <- [case C of B when is_binary(B) -> B; _ -> <<>> end], byte_size(T) >= 3]).

finding(Rule, Sev, Cat, Line, Text, Msg, Sugg) ->
    <<FP:8/binary, _/binary>> = binary:encode_hex(crypto:hash(sha256, [Rule, 0, Text]), lowercase),
    #{<<"line">> => Line, <<"rule">> => Rule, <<"severity">> => Sev, <<"category">> => Cat, <<"message">> => Msg,
      <<"suggestion">> => Sugg, <<"fingerprint">> => FP}.

%% ======================================================================= phase 2: notices (T-065-11)

%% Once a day (the cluster's daily task): a version that starts in the next 7 days becomes a notice — once.
-spec daily_notices() -> ok.
daily_notices() ->
    _ = ana_db:exec(
          "INSERT INTO ana_system.notice (kind, severity, message, link) "
          "SELECT 'company_value', 'info', format('O valor da empresa %s muda em %s (vigência de uma nova versão).', v.name, "
          "       to_char(v.valid_from, 'DD/MM/YYYY')), '#/admin/values' "
          "FROM ana_system.company_value_version v JOIN ana_system.company_value d ON d.name = v.name AND NOT d.archived "
          "WHERE v.status = 'active' AND v.valid_from > current_date AND v.valid_from <= current_date + 7 "
          "AND NOT EXISTS (SELECT 1 FROM ana_system.notice n WHERE n.kind = 'company_value' AND n.message = "
          "  format('O valor da empresa %s muda em %s (vigência de uma nova versão).', v.name, to_char(v.valid_from, 'DD/MM/YYYY')))", []),
    ok.

%% ======================================================================= phase 2: transport (D10, RF-065-10)

%% The definitions of the values the programs of a package read; the content only of the values marked "igual em
%% todos os ambientes" (their general versions).
-spec transport_items([binary()]) -> [map()].
transport_items(Sources) ->
    Names = lists:usort([N || S <- Sources, {N, _} <- names_in(S)]),
    case Names of
        [] -> [];
        _ ->
            {ok, Defs} = ana_db:rows("SELECT name, description, area, value_type, shape, ref_kind, sensitive, reason_required, "
                                     "same_everywhere, maintained_by FROM ana_system.company_value WHERE name = ANY($1::text[]) ORDER BY name",
                                     [Names]),
            [begin
                 Versions = case maps:get(<<"same_everywhere">>, D) of
                     true ->
                         {ok, Vs} = ana_db:rows("SELECT valid_from::text AS valid_from, content::text AS content, expression "
                                                "FROM ana_system.company_value_version WHERE name = $1 AND status = 'active' "
                                                "AND instance IS NULL AND company_id IS NULL ORDER BY valid_from", [maps:get(<<"name">>, D)]),
                         [maps:filter(fun(_, X) -> X =/= null end,
                                      V#{<<"content">> => case maps:get(<<"content">>, V) of null -> null; B -> json:decode(B) end})
                          || V <- Vs];
                     false -> null
                 end,
                 I = #{<<"kind">> => <<"value">>, <<"name">> => maps:get(<<"name">>, D),
                       <<"definition">> => maps:remove(<<"name">>, D), <<"versions">> => Versions},
                 I#{<<"sha256">> => item_sha(I)}
             end || D <- Defs]
    end.

-spec item_sha(map()) -> binary().
item_sha(#{<<"name">> := N, <<"definition">> := D, <<"versions">> := V}) ->
    binary:encode_hex(crypto:hash(sha256, json:encode([N, D, V])), lowercase).

%% new | unchanged | update
-spec transport_status(map()) -> binary().
transport_status(#{<<"name">> := N} = I) ->
    Archived = case ana_db:one("SELECT archived FROM ana_system.company_value WHERE name = $1", [N]) of
        {ok, #{<<"archived">> := A}} -> A;
        _ -> false
    end,
    case transport_items_here(N) of
        undefined -> <<"new">>;
        _ when Archived -> <<"update">>;                  % the import brings it back
        Here -> case maps:get(<<"definition">>, Here) =:= maps:get(<<"definition">>, I) andalso
                     (maps:get(<<"versions">>, I) =:= null orelse maps:get(<<"versions">>, Here) =:= maps:get(<<"versions">>, I)) of
                    true -> <<"unchanged">>;
                    false -> <<"update">>
                end
    end.

%% The same item as this installation would export it (to compare with the one that arrives).
transport_items_here(N) ->
    case transport_items([<<"ana.value('", N/binary, "')">>]) of
        [Item] -> Item;
        [] -> undefined
    end.

%% Inside the import's transaction: the definition created or brought up to date (the content of a value marked the
%% same everywhere too). Returns what it was before, for the undo.
-spec transport_apply(pid(), map(), binary()) -> map() | null.
transport_apply(C, #{<<"name">> := N, <<"definition">> := D} = I, Who) ->
    Prev = case ana_db:rows(C, "SELECT description, area, value_type, shape, ref_kind, sensitive, reason_required, same_everywhere, "
                               "maintained_by, archived FROM ana_system.company_value WHERE name = $1 FOR UPDATE", [N]) of
        {ok, [P]} -> P;
        _ -> null
    end,
    Get = fun(K) -> maps:get(K, D, null) end,
    {ok, _} = ana_db:query(C, "INSERT INTO ana_system.company_value (name, description, area, value_type, shape, ref_kind, sensitive, "
                              "reason_required, same_everywhere, maintained_by, created_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, "
                              "COALESCE($10::text[], '{}'), $11) ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description, "
                              "area = EXCLUDED.area, sensitive = EXCLUDED.sensitive, reason_required = EXCLUDED.reason_required, "
                              "same_everywhere = EXCLUDED.same_everywhere, maintained_by = EXCLUDED.maintained_by, archived = false",
                           [N, Get(<<"description">>), Get(<<"area">>), Get(<<"value_type">>), Get(<<"shape">>), Get(<<"ref_kind">>),
                            Get(<<"sensitive">>) =:= true, Get(<<"reason_required">>) =:= true, Get(<<"same_everywhere">>) =:= true,
                            Get(<<"maintained_by">>), Who]),
    Added = case maps:get(<<"versions">>, I, null) of
        Vs when is_list(Vs) ->
            [Id || V <- Vs,
                   {ok, #{rows := [[Id]]}} <- [ana_db:query(C,
                       "INSERT INTO ana_system.company_value_version (name, valid_from, content, expression, status, reason, requested_by) "
                       "SELECT $1, $2::date, $3::jsonb, $4, 'active', 'transporte', $5 WHERE NOT EXISTS ("
                       "  SELECT 1 FROM ana_system.company_value_version x WHERE x.name = $1 AND x.status = 'active' AND x.valid_from = $2::date "
                       "  AND x.instance IS NULL AND x.company_id IS NULL AND x.content IS NOT DISTINCT FROM $3::jsonb "
                       "  AND x.expression IS NOT DISTINCT FROM $4) RETURNING id",
                       [N, maps:get(<<"valid_from">>, V), json_text(maps:get(<<"content">>, V, null)), maps:get(<<"expression">>, V, null), Who])]];
        _ -> []
    end,
    {ok, _} = ana_db:query(C, "INSERT INTO ana_system.company_value_change (name, action, username, before, after, reason) "
                              "VALUES ($1, 'transported', $2, $3::jsonb, $4::jsonb, 'transporte')",
                           [N, Who, json_text(Prev), json_text(D#{<<"versions">> => length(Added)})]),
    #{<<"definition">> => Prev, <<"added">> => Added}.

%% Undo of an import: the versions it added are withdrawn; the definition goes back as it was (archived if it was new).
-spec transport_undo(pid(), map()) -> ok.
transport_undo(C, #{<<"name">> := N, <<"previous">> := Prev}) ->
    Added = case Prev of #{<<"added">> := A} -> A; _ -> [] end,
    {ok, _} = ana_db:query(C, "UPDATE ana_system.company_value_version SET status = 'withdrawn' WHERE id = ANY($1::bigint[])", [Added]),
    {ok, _} = case Prev of
        #{<<"definition">> := null} -> ana_db:query(C, "UPDATE ana_system.company_value SET archived = true WHERE name = $1", [N]);
        #{<<"definition">> := D} ->
            ana_db:query(C, "UPDATE ana_system.company_value SET description = $2, area = $3, sensitive = $4, reason_required = $5, "
                            "same_everywhere = $6, maintained_by = $7, archived = $8 WHERE name = $1",
                         [N | [maps:get(K, D) || K <- [<<"description">>, <<"area">>, <<"sensitive">>, <<"reason_required">>,
                                                       <<"same_everywhere">>, <<"maintained_by">>, <<"archived">>]]]);
        _ -> {ok, ok}
    end,
    ok.

%% Values the programs of a package read that neither the package nor this installation has (warned before the import).
-spec missing_in_package([binary()], [binary()]) -> [binary()].
missing_in_package(Sources, InPackage) ->
    Names = lists:usort([N || S <- Sources, {N, _} <- names_in(S)]) -- InPackage,
    case Names of
        [] -> [];
        _ ->
            {ok, Here} = ana_db:rows("SELECT name FROM ana_system.company_value WHERE name = ANY($1::text[])", [Names]),
            Names -- [N || #{<<"name">> := N} <- Here]
    end.

%% Program names that may keep a value (invalid entries are dropped).
keepers(L) when is_list(L) ->
    lists:usort([string:trim(P) || P <- L, is_binary(P), ana_program:valid_name(string:trim(P))]);
keepers(_) -> [].

%% ======================================================================= helpers

text_ok(B, Min, Max) when is_binary(B) -> L = string:length(string:trim(B)), L >= Min andalso L =< Max;
text_ok(_, _, _) -> false.

%% Writes and their trail in one transaction; the central administration log too (spec 024).
tx(Fun, Who, Name, Action) ->
    case ana_db:transaction(fun(C) ->
             case Fun(C) of
                 {ok, R} -> {ok, R};
                 {error, Code, M} -> {error, {Code, M}}
             end
         end) of
        {ok, R} ->
            reload(Name),                    % this node at once; the others by the notice (after COMMIT)
            ana_admin:log(Who, Action, Name, null, R),
            {ok, R};
        {error, {Code, M}} -> {error, Code, M};
        {error, #{message := M}} -> {error, <<"INVALID">>, M};
        {error, E} -> {error, <<"INVALID">>, unicode:characters_to_binary(io_lib:format("~0p", [E]))}
    end.

change(C, Name, Action, Who, Version, Before, After, Reason) ->
    {ok, _} = ana_db:query(C, "INSERT INTO ana_system.company_value_change (name, action, username, version_id, before, after, reason) "
                              "VALUES ($1, $2, $3, $4, $5::jsonb, $6::jsonb, $7)",
                           [Name, Action, Who, Version, json_text(Before), json_text(After), Reason]),
    ok.

json_text(null) -> null;
json_text(V) -> iolist_to_binary(json:encode(V)).

date(<<Y:4/binary, "-", M:2/binary, "-", D:2/binary>>) ->
    try
        Dt = {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)},
        case calendar:valid_date(Dt) of
            true -> Dt;
            false -> bad
        end
    catch _:_ -> bad
    end;
date(_) -> bad.

iso({Y, M, D}) -> iolist_to_binary(io_lib:format("~4..0b-~2..0b-~2..0b", [Y, M, D])).
