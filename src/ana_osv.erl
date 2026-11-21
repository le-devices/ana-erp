%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Vulnerability advisories in the OSV format (spec 033, RF-033-02).
%%
%% Import accepts one advisory, a list, or {"vulns": [...]}; each affected range becomes a row
%% (an advisory imported again replaces its rows). Matching compares the inventory (spec 033,
%% ana_inventory) with the ranges: ecosystem (case-insensitive; "Debian" covers "Debian:12"),
%% package name (case-insensitive) and version (generic ordering with Debian epochs and "~",
%% numeric and alphanumeric segments, pre-releases before the release).
-module(ana_osv).

-export([import/2, findings/0, affected/2, compare/2, cvss3/1, severity/1, parse/1, refresh/0, feed_connector/0]).

-define(MAX_ADVISORIES, 200000).
-define(CHUNK, 2000).

%% ---------------------------------------------------------------- import

-spec import(binary() | term(), binary()) -> {ok, map()} | {error, binary()}.
import(Body, Who) when is_binary(Body) ->
    case catch json:decode(Body) of
        {'EXIT', _} -> {error, <<"o arquivo não é JSON válido"/utf8>>};
        Decoded -> import(Decoded, Who)
    end;
import(Decoded, Who) ->
    Advisories = case Decoded of
        #{<<"vulns">> := L} when is_list(L) -> L;
        L when is_list(L) -> L;
        #{<<"id">> := _} = M -> [M];
        _ -> []
    end,
    case Advisories of
        [] -> {error, <<"nenhum aviso no formato OSV (esperado \"id\" e \"affected\")"/utf8>>};
        _ when length(Advisories) > ?MAX_ADVISORIES -> {error, <<"arquivo grande demais: divida a base"/utf8>>};
        _ ->
            Rows = lists:append([parse(A) || A <- Advisories]),
            %% Every advisory in the file replaces its rows; a withdrawn one only removes them.
            Ids = lists:usort([clip(Id, 100) || #{<<"id">> := Id} <- Advisories, is_binary(Id)]),
            {ok, _} = ana_db:transaction(fun(C) ->
                {ok, _} = ana_db:query(C, "DELETE FROM ana_system.vulnerability WHERE osv_id = ANY($1::text[])", [Ids]),
                lists:foreach(fun(Chunk) -> insert(C, Chunk, Who) end, chunks(Rows, ?CHUNK)),
                {ok, length(Rows)}
            end),
            {ok, #{advisories => length(Ids), ranges => length(Rows),
                   withdrawn => length([1 || #{<<"withdrawn">> := W} <- Advisories, is_binary(W)])}}
    end.

insert(C, Rows, Who) ->
    Col = fun(K) -> [maps:get(K, R) || R <- Rows] end,
    {ok, _} = ana_db:query(C,
        "INSERT INTO ana_system.vulnerability (osv_id, ecosystem, package, introduced, fixed, last_affected, versions, "
        "  severity, summary, aliases, modified, imported_by) "
        "SELECT i, e, p, intro, fix, last, ARRAY(SELECT jsonb_array_elements_text(vs::jsonb)), sev, summ, "
        "  ARRAY(SELECT jsonb_array_elements_text(al::jsonb)), mod::timestamptz, $12 "
        "FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[], $8::text[], "
        "            $9::text[], $10::text[], $11::text[]) AS x(i, e, p, intro, fix, last, vs, sev, summ, al, mod)",
        [Col(osv_id), Col(ecosystem), Col(package), Col(introduced), Col(fixed), Col(last_affected),
         [iolist_to_binary(json:encode(V)) || V <- Col(versions)], Col(severity), Col(summary),
         [iolist_to_binary(json:encode(A)) || A <- Col(aliases)], Col(modified), Who]),
    ok.

chunks([], _) -> [];
chunks(L, N) when length(L) =< N -> [L];
chunks(L, N) -> {A, B} = lists:split(N, L), [A | chunks(B, N)].

%% One OSV advisory → rows (one per affected range; a package with only "versions" gets one row).
-spec parse(map()) -> [map()].
parse(#{<<"withdrawn">> := W}) when is_binary(W) -> [];
parse(#{<<"id">> := Id, <<"affected">> := Affected} = A) when is_binary(Id), is_list(Affected) ->
    Top = #{osv_id => clip(Id, 100), summary => clip(text(maps:get(<<"summary">>, A, maps:get(<<"details">>, A, <<>>))), 500),
            aliases => [X || X <- list(maps:get(<<"aliases">>, A, [])), is_binary(X)],
            modified => case maps:get(<<"modified">>, A, null) of M when is_binary(M) -> M; _ -> null end},
    TopSev = severity(A),
    lists:append([affected_rows(Top, TopSev, Af) || Af <- Affected, is_map(Af)]);
parse(_) -> [].

affected_rows(Top, TopSev, #{<<"package">> := #{<<"ecosystem">> := Eco, <<"name">> := Pkg}} = Af)
  when is_binary(Eco), is_binary(Pkg), Eco =/= <<>>, Pkg =/= <<>> ->
    Sev = case severity(Af) of undefined -> default(TopSev); S -> S end,
    Versions = [V || V <- list(maps:get(<<"versions">>, Af, [])), is_binary(V)],
    Base = Top#{ecosystem => clip(Eco, 60), package => clip(Pkg, 200), severity => Sev},
    Ranges = lists:append([pairs(list(maps:get(<<"events">>, R, [])))
                           || R <- list(maps:get(<<"ranges">>, Af, [])), is_map(R),
                              maps:get(<<"type">>, R, <<>>) =/= <<"GIT">>]),
    case Ranges of
        [] when Versions =/= [] -> [Base#{introduced => null, fixed => null, last_affected => null, versions => Versions}];
        [] -> [];
        [First | Rest] ->
            [maps:merge(Base#{versions => Versions}, First) | [maps:merge(Base#{versions => []}, R) || R <- Rest]]
    end;
affected_rows(_, _, _) -> [].

default(undefined) -> <<"warning">>;
default(S) -> S.

%% Events in order: each "introduced" closes with the next "fixed" / "last_affected" (or stays open).
pairs(Events) -> pairs(Events, undefined, []).
pairs([], undefined, Acc) -> lists:reverse(Acc);
pairs([], Intro, Acc) -> lists:reverse([#{introduced => Intro, fixed => null, last_affected => null} | Acc]);
pairs([#{<<"introduced">> := I} | T], undefined, Acc) when is_binary(I) -> pairs(T, I, Acc);
pairs([#{<<"introduced">> := I} | T], Prev, Acc) when is_binary(I) ->
    pairs(T, I, [#{introduced => Prev, fixed => null, last_affected => null} | Acc]);
pairs([#{<<"fixed">> := F} | T], Intro, Acc) when is_binary(F) ->
    pairs(T, undefined, [#{introduced => null_if_undefined(Intro), fixed => F, last_affected => null} | Acc]);
pairs([#{<<"last_affected">> := L} | T], Intro, Acc) when is_binary(L) ->
    pairs(T, undefined, [#{introduced => null_if_undefined(Intro), fixed => null, last_affected => L} | Acc]);
pairs([_ | T], Intro, Acc) -> pairs(T, Intro, Acc).

null_if_undefined(undefined) -> null;
null_if_undefined(X) -> X.

list(L) when is_list(L) -> L;
list(_) -> [].

text(B) when is_binary(B) -> B;
text(_) -> <<>>.

clip(B, N) when byte_size(B) > N -> string:slice(B, 0, N);
clip(B, _) -> B.

%% ---------------------------------------------------------------- severity

%% database_specific.severity (CRITICAL/HIGH/MODERATE/LOW) or a CVSS v3 vector; undefined if absent.
-spec severity(map()) -> binary() | undefined.
severity(M) ->
    Named = case M of
        #{<<"database_specific">> := #{<<"severity">> := S}} when is_binary(S) -> named(string:uppercase(S));
        #{<<"ecosystem_specific">> := #{<<"severity">> := S}} when is_binary(S) -> named(string:uppercase(S));
        _ -> undefined
    end,
    case Named of
        undefined ->
            Scores = [cvss3(V) || #{<<"type">> := T, <<"score">> := V} <- list(maps:get(<<"severity">>, M, [])),
                                  is_binary(V), lists:member(T, [<<"CVSS_V3">>, <<"CVSS_V31">>])],
            case [S || S <- Scores, is_number(S)] of
                [] -> undefined;
                L -> by_score(lists:max(L))
            end;
        N -> N
    end.

named(<<"CRITICAL">>) -> <<"critical">>;
named(<<"HIGH">>) -> <<"serious">>;
named(<<"MODERATE">>) -> <<"warning">>;
named(<<"MEDIUM">>) -> <<"warning">>;
named(<<"LOW">>) -> <<"info">>;
named(_) -> undefined.

by_score(S) when S >= 9.0 -> <<"critical">>;
by_score(S) when S >= 7.0 -> <<"serious">>;
by_score(S) when S >= 4.0 -> <<"warning">>;
by_score(_) -> <<"info">>.

%% CVSS v3.x base score from the vector ("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" → 9.8).
-spec cvss3(binary()) -> float() | undefined.
cvss3(Vector) ->
    M = maps:from_list([list_to_tuple(binary:split(P, <<":">>)) || P <- binary:split(Vector, <<"/">>, [global]),
                                                                  length(binary:split(P, <<":">>)) =:= 2]),
    try
        Changed = maps:get(<<"S">>, M) =:= <<"C">>,
        AV = maps:get(maps:get(<<"AV">>, M), #{<<"N">> => 0.85, <<"A">> => 0.62, <<"L">> => 0.55, <<"P">> => 0.2}),
        AC = maps:get(maps:get(<<"AC">>, M), #{<<"L">> => 0.77, <<"H">> => 0.44}),
        PR = case {maps:get(<<"PR">>, M), Changed} of
            {<<"N">>, _} -> 0.85; {<<"L">>, false} -> 0.62; {<<"L">>, true} -> 0.68;
            {<<"H">>, false} -> 0.27; {<<"H">>, true} -> 0.5
        end,
        UI = maps:get(maps:get(<<"UI">>, M), #{<<"N">> => 0.85, <<"R">> => 0.62}),
        CIA = #{<<"H">> => 0.56, <<"L">> => 0.22, <<"N">> => 0.0},
        [C, I, A] = [maps:get(maps:get(K, M), CIA) || K <- [<<"C">>, <<"I">>, <<"A">>]],
        ISS = 1 - (1 - C) * (1 - I) * (1 - A),
        Impact = case Changed of
            false -> 6.42 * ISS;
            true -> 7.52 * (ISS - 0.029) - 3.25 * math:pow(ISS - 0.02, 15)
        end,
        Expl = 8.22 * AV * AC * PR * UI,
        if
            Impact =< 0 -> 0.0;
            not Changed -> roundup(min(Impact + Expl, 10));
            true -> roundup(min(1.08 * (Impact + Expl), 10))
        end
    catch _:_ -> undefined
    end.

roundup(X) ->
    I = round(X * 100000),
    case I rem 10000 of
        0 -> I / 100000;
        _ -> (I div 10000 + 1) / 10
    end.

%% ---------------------------------------------------------------- versions

%% -1 | 0 | 1. Debian epochs ("1:2.0"), "~" before anything, numbers numerically, words
%% lexically, and a release after its pre-releases ("1.0.0-rc1" < "1.0.0" < "1.0.1").
-spec compare(binary(), binary()) -> -1 | 0 | 1.
compare(A, B) ->
    {EA, RA} = epoch(A),
    {EB, RB} = epoch(B),
    if EA < EB -> -1; EA > EB -> 1; true -> cmp(tokens(RA), tokens(RB)) end.

epoch(V) ->
    case binary:split(V, <<":">>) of
        [E, R] -> try {binary_to_integer(E), R} catch _:_ -> {0, V} end;
        _ -> {0, V}
    end.

tokens(V) ->
    case re:run(string:lowercase(V), <<"[0-9]+|[a-z]+|~">>, [global, {capture, all, binary}]) of
        {match, Ms} -> [token(T) || [T] <- Ms];
        nomatch -> []
    end.

token(<<"~">>) -> tilde;
token(T) ->
    case re:run(T, <<"^[0-9]+$">>) of
        {match, _} -> {num, binary_to_integer(T)};
        nomatch -> {str, T}
    end.

cmp([], []) -> 0;
cmp([], [tilde | _]) -> 1;
cmp([tilde | _], []) -> -1;
cmp([], [{str, _} | _]) -> 1;          % 1.0.0 > 1.0.0-rc1
cmp([{str, _} | _], []) -> -1;
cmp([], [{num, _} | _]) -> -1;         % 1.0 < 1.0.1
cmp([{num, _} | _], []) -> 1;
cmp([X | TA], [X | TB]) -> cmp(TA, TB);
cmp([tilde | _], _) -> -1;
cmp(_, [tilde | _]) -> 1;
cmp([{num, A} | _], [{num, B} | _]) -> sign(A - B);
cmp([{str, A} | _], [{str, B} | _]) -> if A < B -> -1; true -> 1 end;
cmp([{num, _} | _], [{str, _} | _]) -> 1;
cmp([{str, _} | _], [{num, _} | _]) -> -1.

sign(N) when N < 0 -> -1;
sign(N) when N > 0 -> 1;
sign(_) -> 0.

%% Is Version inside the row's range (or listed among its versions)?
-spec affected(binary(), map()) -> boolean().
affected(Version, R) ->
    Listed = lists:member(Version, maps:get(versions, R, [])),
    Intro = maps:get(introduced, R, null),
    Fixed = maps:get(fixed, R, null),
    Last = maps:get(last_affected, R, null),
    InRange = (Intro =/= null orelse Fixed =/= null orelse Last =/= null)
        andalso (Intro =:= null orelse Intro =:= <<"0">> orelse compare(Version, Intro) >= 0)
        andalso (Fixed =:= null orelse compare(Version, Fixed) < 0)
        andalso (Last =:= null orelse compare(Version, Last) =< 0),
    Listed orelse InRange.

%% ---------------------------------------------------------------- findings

%% {rule, target, severity, title, detail, suggestion, evidence} for the checks engine.
-spec findings() -> [tuple()].
findings() ->
    {ok, Rows} = ana_db:rows(
        "SELECT c.ecosystem AS c_eco, c.name, c.version, v.osv_id, v.introduced, v.fixed, v.last_affected, v.versions, "
        "  v.severity, v.summary, v.aliases "
        "FROM ana_system.component c JOIN ana_system.vulnerability v ON lower(v.package) = lower(c.name) "
        "  AND (lower(v.ecosystem) = lower(c.ecosystem) OR lower(split_part(c.ecosystem, ':', 1)) = lower(v.ecosystem))", []),
    Hits = [R || R = #{<<"version">> := V} <- Rows,
                 affected(V, #{introduced => maps:get(<<"introduced">>, R), fixed => maps:get(<<"fixed">>, R),
                               last_affected => maps:get(<<"last_affected">>, R), versions => maps:get(<<"versions">>, R)})],
    [{<<"vulnerable_component">>, <<Eco/binary, ":", N/binary, "@", V/binary, " ", Id/binary>>, Sev,
      fmt("~ts ~ts tem vulnerabilidade conhecida (~ts)", [N, V, Id]),
      fmt("~ts~ts", [Summ, case Al of [] -> <<>>; _ -> [<<" — também "/utf8>>, lists:join(<<", ">>, Al)] end]),
      case Fixed of
          null -> <<"Sem versão corrigida publicada: avalie mitigação e acompanhe o aviso."/utf8>>;
          _ -> fmt("Atualize ~ts para ~ts ou mais recente (nova versão do ANA ou da imagem).", [N, Fixed])
      end,
      #{ecosystem => Eco, package => N, version => V, osv_id => Id, fixed => Fixed}}
     || #{<<"c_eco">> := Eco, <<"name">> := N, <<"version">> := V, <<"osv_id">> := Id, <<"severity">> := Sev,
          <<"summary">> := Summ, <<"aliases">> := Al, <<"fixed">> := Fixed} <- Hits].

%% ---------------------------------------------------------------- feed by connector (T-033-09b)

%% The connector the administrator turned on for this (options.purpose = "osv_feed"); none = off (P13).
-spec feed_connector() -> map() | none.
feed_connector() ->
    case ana_db:one("SELECT name, options FROM integration.connector WHERE active AND kind = 'http_api' "
                    "AND options ->> 'purpose' = 'osv_feed' ORDER BY name LIMIT 1", []) of
        {ok, #{<<"name">> := _} = C} -> C;
        _ -> none
    end.

%% Two ways, chosen by options.mode: "feed" (GET options.path answering OSV JSON — a mirror or a
%% file server inside the company) or "query" (the osv.dev API: querybatch with the inventory, then
%% each advisory). Every call goes through the connector: allowed hosts, TLS, limits, breaker, log.
-spec refresh() -> {ok, map()} | {skipped, binary()} | {error, binary()}.
refresh() ->
    case feed_connector() of
        none -> {skipped, <<"nenhum conector de base de vulnerabilidades ligado"/utf8>>};
        #{<<"name">> := Name, <<"options">> := O} ->
            R = case maps:get(<<"mode">>, O, <<"feed">>) of
                <<"query">> -> by_query(Name);
                _ -> by_feed(Name, maps:get(<<"path">>, O, <<"/">>))
            end,
            {Ok, Msg, N} = case R of
                {ok, #{advisories := A}} -> {true, fmt("~b aviso(s) importado(s)", [A]), A};
                {error, M} -> {false, M, null}
            end,
            _ = ana_db:exec("UPDATE ana_system.check_config SET feed_connector = $1, feed_at = now(), feed_ok = $2, "
                            "feed_message = $3, feed_advisories = $4", [Name, Ok, Msg, N]),
            R
    end.

by_feed(Name, Path) ->
    case get_json(Name, <<"GET">>, Path, #{}) of
        {ok, Json} -> import(Json, <<"system">>);
        E -> E
    end.

by_query(Name) ->
    {ok, Comps} = ana_db:rows("SELECT ecosystem, name, version FROM ana_system.component WHERE ecosystem <> 'PostgreSQL'", []),
    Queries = [#{package => #{name => N, ecosystem => E}, version => V}
               || #{<<"ecosystem">> := E, <<"name">> := N, <<"version">> := V} <- Comps],
    case batch_ids(Name, chunks(Queries, 1000), []) of
        {error, _} = E -> E;
        {ok, []} -> {ok, #{advisories => 0, ranges => 0, withdrawn => 0}};
        {ok, Ids} ->
            Got = [get_json(Name, <<"GET">>, <<"/v1/vulns/", (uri_string:quote(Id))/binary>>, #{})
                   || Id <- lists:sublist(lists:usort(Ids), 2000)],
            case [M || {error, M} <- Got] of
                [M | _] -> {error, M};
                [] -> import([J || {ok, J} <- Got], <<"system">>)
            end
    end.

batch_ids(_, [], Acc) -> {ok, Acc};
batch_ids(Name, [Q | Rest], Acc) ->
    case get_json(Name, <<"POST">>, <<"/v1/querybatch">>, #{<<"json">> => #{queries => Q}}) of
        {ok, #{<<"results">> := Results}} when is_list(Results) ->
            Ids = [Id || #{<<"vulns">> := Vs} <- Results, is_list(Vs), #{<<"id">> := Id} <- Vs, is_binary(Id)],
            batch_ids(Name, Rest, Acc ++ Ids);
        {ok, _} -> {error, <<"resposta do serviço OSV sem \"results\""/utf8>>};
        E -> E
    end.

get_json(Name, Method, Path, Opts) ->
    case ana_connector:http(Name, Method, Path, Opts, null) of
        {ok, #{<<"status">> := S, <<"json">> := J}} when S >= 200, S < 300 -> {ok, J};
        {ok, #{<<"status">> := S, <<"text">> := T}} when S >= 200, S < 300 ->
            case catch json:decode(T) of
                {'EXIT', _} -> {error, <<"o serviço não respondeu JSON"/utf8>>};
                J -> {ok, J}
            end;
        {ok, #{<<"status">> := S}} -> {error, fmt("o serviço de vulnerabilidades respondeu ~b", [S])};
        {error, #{<<"message">> := M}} -> {error, M}
    end.

fmt(F, A) -> unicode:characters_to_binary(io_lib:format(F, A)).
