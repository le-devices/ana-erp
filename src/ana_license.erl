%% SPDX-FileCopyrightText: 2026 LE Devices
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% License of the instance (spec 009, phase 1).
%%
%% A license is base64url(JSON) "." base64url(Ed25519 signature), signed by the vendor with a key listed in
%% priv/license/keys.json. verify/2 and status/5 are pure; the server keeps the resulting state in
%% persistent_term (one lookup per execution, RNF-009-01), recomputes it hourly, on install and when another
%% node installs one (NOTIFY ana_license). Restricted mode never blocks reading (RNF-009-02).
-module(ana_license).
-behaviour(gen_server).

-export([start_link/0, current/0, restricted/0, allowed/1, module_of/1, modules/0, boot_check/0, seat/0,
         install/3, detail/0, on_notify/2, refresh/0]).
-export([verify/2, status/5, version_covered/2, parse/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(KEY, {?MODULE, status}).
-define(TRIAL_DAYS, 30).
-define(WARN_DAYS, 30).
-define(GRACE_DAYS, 15).
-define(TICK_MS, 3600000).
-define(BEGIN, <<"-----BEGIN ANA LICENSE-----">>).
-define(END, <<"-----END ANA LICENSE-----">>).

%% Contracted modules and the program namespaces they cover (D4). Anything else is the core.
-define(MODULES, [{<<"sales">>, <<"Vendas">>, [<<"sales">>]},
                  {<<"supply">>, <<"Suprimentos">>, [<<"supply">>]},
                  {<<"production">>, <<"Produção"/utf8>>, [<<"production">>]},
                  {<<"logistics_field">>, <<"Logística e campo"/utf8>>, [<<"logistics">>, <<"field">>]},
                  {<<"projects">>, <<"Projetos">>, [<<"projects">>]},
                  {<<"bpm">>, <<"Processos (BPM)">>, [<<"bpm">>]},
                  {<<"analytics">>, <<"Analítico"/utf8>>, [<<"analytics">>]},
                  {<<"public_api">>, <<"API pública"/utf8>>, []},
                  {<<"portal">>, <<"Portal de clientes e fornecedores">>, []}]).

%% ==========================================================================
%% Queries used everywhere (cheap)
%% ==========================================================================

-spec current() -> map().
current() ->
    persistent_term:get(?KEY, #{state => <<"trial">>, reason => null, modules => all_modules(),
                                named_users => unlimited, environment => <<"production">>, days_left => ?TRIAL_DAYS}).

-spec restricted() -> boolean().
restricted() -> maps:get(state, current()) =:= <<"restricted">>.

-spec allowed(binary()) -> boolean().
allowed(<<"core">>) -> true;
allowed(Module) -> lists:member(Module, maps:get(modules, current())).

-spec module_of(binary()) -> binary().
module_of(ProgramName) ->
    [First | _] = binary:split(ProgramName, <<".">>),
    case [M || {M, _, Spaces} <- ?MODULES, lists:member(First, Spaces)] of
        [M | _] -> M;
        [] -> <<"core">>
    end.

%% RF-009-04: one more named user (active human internal account) fits in the license?
-spec seat() -> ok | {error, binary()}.
seat() ->
    case maps:get(named_users, current()) of
        unlimited -> ok;
        Limit ->
            {ok, [#{<<"n">> := Used}]} = ana_db:rows(
                "SELECT count(*) AS n FROM ana_system.app_user WHERE active AND kind = 'human' AND role <> 'external'", []),
            case Used < Limit of
                true -> ok;
                false -> {error, unicode:characters_to_binary(io_lib:format(
                             "LICENSE_LIMIT: a licença permite ~b usuários nomeados e já há ~b ativos "
                             "(desative alguém ou amplie a licença; robôs e contas do portal não contam)", [Limit, Used]))}
            end
    end.

-spec modules() -> [map()].
modules() -> [#{module => M, label => L, namespaces => S} || {M, L, S} <- ?MODULES].

all_modules() -> [M || {M, _, _} <- ?MODULES].

%% ==========================================================================
%% Pure: verification and state
%% ==========================================================================

%% Text → {ok, Payload, Kid, IsTestKey} | {error, Message}. Keys: #{Kid => #{<<"public">>, <<"test">>}}.
-spec verify(binary(), map()) -> {ok, map(), binary(), boolean()} | {error, binary()}.
verify(Text, Keys) ->
    try
        {Body, Sig} = split(Text),
        Payload = json:decode(b64d(Body)),
        true = is_map(Payload) orelse throw(<<"conteúdo da licença inválido"/utf8>>),
        Kid = maps:get(<<"kid">>, Payload, null),
        Key = case maps:get(Kid, Keys, undefined) of
            undefined -> throw(<<"licença assinada por chave desconhecida"/utf8>>);
            K -> K
        end,
        Pub = base64:decode(maps:get(<<"public">>, Key)),
        crypto:verify(eddsa, none, Body, b64d(Sig), [Pub, ed25519]) orelse throw(<<"assinatura da licença inválida"/utf8>>),
        ok = fields(Payload),
        Test = maps:get(<<"test">>, Key, false) =:= true,
        %% A test key never grants production use, even if its private half leaks (D2).
        P2 = case Test of true -> Payload#{<<"environment">> => <<"non_production">>}; false -> Payload end,
        {ok, P2, Kid, Test}
    catch
        throw:Msg when is_binary(Msg) -> {error, Msg};
        _:_ -> {error, <<"texto de licença ilegível"/utf8>>}
    end.

split(Text) ->
    case binary:split(Text, ?BEGIN) of
        [_, Rest] ->
            [Inner | _] = binary:split(Rest, ?END),
            Clean = << <<C>> || <<C>> <= Inner, C > 32 >>,
            case binary:split(Clean, <<".">>) of
                [B, S] when B =/= <<>>, S =/= <<>> -> {B, S};
                _ -> throw(<<"texto de licença incompleto"/utf8>>)
            end;
        _ -> throw(<<"cole o texto inteiro, das linhas BEGIN a END">>)
    end.

fields(P) ->
    Need = [<<"id">>, <<"customer">>, <<"valid_from">>, <<"valid_until">>, <<"max_version">>, <<"modules">>,
            <<"limits">>, <<"environment">>],
    case [F || F <- Need, not maps:is_key(F, P)] of
        [] -> ok;
        Missing -> throw(iolist_to_binary([<<"licença sem os campos: "/utf8>>, lists:join(<<", ">>, Missing)]))
    end,
    _ = parse(maps:get(<<"valid_from">>, P)),
    _ = parse(maps:get(<<"valid_until">>, P)),
    _ = version(maps:get(<<"max_version">>, P)),
    is_list(maps:get(<<"modules">>, P)) orelse throw(<<"módulos da licença inválidos"/utf8>>),
    lists:member(maps:get(<<"environment">>, P), [<<"production">>, <<"non_production">>])
        orelse throw(<<"ambiente da licença inválido"/utf8>>),
    ok.

-spec parse(binary()) -> calendar:date().
parse(<<Y:4/binary, "-", M:2/binary, "-", D:2/binary>>) ->
    Date = {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)},
    calendar:valid_date(Date) orelse throw(<<"data inválida na licença"/utf8>>),
    Date;
parse(_) -> throw(<<"data inválida na licença"/utf8>>).

version(V) when is_binary(V) ->
    case [binary_to_integer(X) || X <- binary:split(V, <<".">>, [global])] of
        [Maj, Min | _] -> {Maj, Min};
        [Maj] -> {Maj, 0}
    end;
version(_) -> throw(<<"versão inválida na licença"/utf8>>).

%% The license covers product versions up to max_version (major.minor).
-spec version_covered(binary(), binary()) -> boolean().
version_covered(Max, Product) ->
    try version(Product) =< version(Max) catch _:_ -> false end.

%% License (payload or none), first boot, latest date seen, today, product version → state map.
-spec status(map() | none, calendar:date(), calendar:date(), calendar:date(), binary()) -> map().
status(License, FirstBoot, LastSeen, Today, Version) ->
    Base = base(License),
    case days(Today) < days(LastSeen) - 1 of
        true ->
            Base#{state => <<"restricted">>, reason => <<"clock">>, days_left => 0};
        false when License =:= none ->
            Left = ?TRIAL_DAYS - (days(Today) - days(FirstBoot)),
            case Left >= 0 of
                true -> Base#{state => <<"trial">>, reason => null, days_left => Left};
                false -> Base#{state => <<"restricted">>, reason => <<"trial_over">>, days_left => Left}
            end;
        false ->
            Left = days(parse(maps:get(<<"valid_until">>, License))) - days(Today),
            Early = days(Today) < days(parse(maps:get(<<"valid_from">>, License))),
            Covered = version_covered(maps:get(<<"max_version">>, License), Version),
            {State, Reason} = if
                not Covered -> {<<"restricted">>, <<"version">>};
                Early -> {<<"restricted">>, <<"not_yet">>};
                Left > ?WARN_DAYS -> {<<"valid">>, null};
                Left >= 0 -> {<<"expiring">>, null};
                Left >= -?GRACE_DAYS -> {<<"grace">>, null};
                true -> {<<"restricted">>, <<"expired">>}
            end,
            Base#{state => State, reason => Reason, days_left => Left}
    end.

base(none) ->
    #{modules => all_modules(), named_users => unlimited, environment => <<"production">>, customer => null,
      valid_until => null, license_id => null, max_version => null};
base(L) ->
    Users = case maps:get(<<"named_users">>, maps:get(<<"limits">>, L, #{}), null) of
        N when is_integer(N), N > 0 -> N;
        _ -> unlimited
    end,
    #{modules => [M || M <- maps:get(<<"modules">>, L), lists:member(M, all_modules())],
      named_users => Users, environment => maps:get(<<"environment">>, L),
      customer => maps:get(<<"customer">>, L), valid_until => maps:get(<<"valid_until">>, L),
      license_id => maps:get(<<"id">>, L), max_version => maps:get(<<"max_version">>, L)}.

days(Date) -> calendar:date_to_gregorian_days(Date).

b64d(B) ->
    Pad = case byte_size(B) rem 4 of 0 -> <<>>; 2 -> <<"==">>; 3 -> <<"=">>; _ -> throw(<<"base64 inválido"/utf8>>) end,
    base64:decode(<< <<(case C of $- -> $+; $_ -> $/; _ -> C end)>> || <<C>> <= <<B/binary, Pad/binary>> >>).

%% ==========================================================================
%% Keys, version, files
%% ==========================================================================

keys() ->
    case persistent_term:get({?MODULE, keys}, undefined) of
        undefined ->
            K = case file:read_file(filename:join([code:priv_dir(ana), "license", "keys.json"])) of
                {ok, B} -> json:decode(B);
                _ -> #{}
            end,
            persistent_term:put({?MODULE, keys}, K),
            K;
        K -> K
    end.

product_version() ->
    {ok, V} = application:get_key(ana, vsn),
    list_to_binary(V).

file_license() ->
    case os:getenv("ANA_LICENSE_FILE") of
        F when is_list(F), F =/= "" ->
            case file:read_file(F) of
                {ok, Text} -> {ok, Text};
                {error, R} -> logger:warning("ANA_LICENSE_FILE ~s: ~p", [F, R]), none
            end;
        _ -> none
    end.

%% RF-009-07: before migrations, a product version above the license's max_version does not start.
-spec boot_check() -> ok.
boot_check() ->
    {ok, C} = ana_db:connect(ana_config:db()),
    Active = try
        case epgsql:squery(C, "SELECT text FROM ana_system.license WHERE active") of
            {ok, _, [{T}]} -> {ok, T};
            _ -> none                                   % no table yet (first start with licensing) or none installed
        end
    after
        epgsql:close(C)
    end,
    Texts = [T || {ok, T} <- [Active, file_license()]],
    Verified = [P || T <- Texts, {ok, P, _, _} <- [verify(T, keys())]],
    V = product_version(),
    case Verified =/= [] andalso not lists:any(fun(P) -> version_covered(maps:get(<<"max_version">>, P), V) end, Verified) of
        true ->
            Max = maps:get(<<"max_version">>, hd(Verified)),
            logger:error("license covers versions up to ~s; this is ~s: install the renewed license with ANA_LICENSE_FILE",
                         [Max, V]),
            exit({license_version, Max, V});
        false -> ok
    end.

%% ==========================================================================
%% Install and detail (administrator)
%% ==========================================================================

-spec install(binary(), binary(), binary()) -> {ok, map()} | {error, binary()}.
install(Text, Source, Who) ->
    case write(Text, Source, Who) of
        ok -> refresh(), {ok, current()};
        {error, _} = E -> E
    end.

write(Text, Source, Who) ->
    case verify(Text, keys()) of
        {ok, P, Kid, _} ->
            V = product_version(),
            case version_covered(maps:get(<<"max_version">>, P), V) of
                false ->
                    {error, <<"a licença não cobre a versão "/utf8, V/binary, " do produto (vai até "/utf8,
                              (maps:get(<<"max_version">>, P))/binary, ")">>};
                true ->
                    {ok, _} = ana_db:transaction(fun(C) ->
                        {ok, _} = ana_db:query(C, "UPDATE ana_system.license SET active = false WHERE active", []),
                        ana_db:query(C, "INSERT INTO ana_system.license (text, payload, kid, installed_by, source) "
                                        "VALUES ($1, $2::text::jsonb, $3, $4, $5)",
                                     [Text, iolist_to_binary(json:encode(P)), Kid, Who, Source])
                    end),
                    ana_admin:log(Who, <<"license.install">>, maps:get(<<"id">>, P), null,
                                  maps:with([<<"customer">>, <<"valid_until">>, <<"modules">>, <<"limits">>,
                                             <<"environment">>, <<"max_version">>], P)),
                    ok
            end;
        {error, _} = E -> E
    end.

-spec detail() -> map().
detail() ->
    {ok, [#{<<"n">> := Used}]} = ana_db:rows(
        "SELECT count(*) AS n FROM ana_system.app_user WHERE active AND kind = 'human' AND role <> 'external'", []),
    {ok, History} = ana_db:rows(
        "SELECT id, payload->>'id' AS license, payload->>'customer' AS customer, payload->>'valid_until' AS valid_until, "
        "  payload->>'environment' AS environment, installed_by, installed_at, source, active "
        "FROM ana_system.license ORDER BY id DESC LIMIT 20", []),
    S = current(),
    S#{named_users_used => Used, history => History, catalog => modules(), product_version => product_version()}.

%% ==========================================================================
%% Server
%% ==========================================================================

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec refresh() -> ok.
refresh() ->
    case whereis(?MODULE) of
        undefined -> compute();
        _ -> gen_server:call(?MODULE, refresh, 30000)
    end.

on_notify(_Channel, _Payload) ->
    gen_server:cast(?MODULE, refresh).

init([]) ->
    _ = keys(),
    _ = catch install_file(),
    _ = compute(),
    erlang:send_after(?TICK_MS, self(), tick),
    {ok, #{}}.

handle_call(refresh, _From, S) -> {reply, compute(), S};
handle_call(_, _, S) -> {reply, ok, S}.

handle_cast(refresh, S) -> _ = compute(), {noreply, S};
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, S) ->
    _ = catch install_file(),
    _ = compute(),
    erlang:send_after(?TICK_MS, self(), tick),
    {noreply, S};
handle_info(_, S) -> {noreply, S}.

%% The file (installations without a screen) wins when it is a different, valid license issued later.
install_file() ->
    case file_license() of
        {ok, Text} ->
            case verify(Text, keys()) of
                {ok, P, _, _} ->
                    {ok, Rows} = ana_db:rows("SELECT payload->>'id' AS id, payload->>'issued_at' AS issued FROM ana_system.license "
                                             "WHERE active", []),
                    Newer = case Rows of
                        [] -> true;
                        [#{<<"id">> := Id, <<"issued">> := Iss}] ->
                            Id =/= maps:get(<<"id">>, P) andalso maps:get(<<"issued_at">>, P, <<>>) >= (case Iss of null -> <<>>; _ -> Iss end)
                    end,
                    _ = Newer andalso write(Text, <<"file">>, <<"system">>),
                    ok;
                {error, Msg} -> logger:warning("ANA_LICENSE_FILE refused: ~ts", [Msg])
            end;
        none -> ok
    end.

%% Reads the active license and the state row, keeps the latest date seen, caches the result.
compute() ->
    try
        {ok, [St]} = ana_db:rows("UPDATE ana_system.license_state SET last_seen = greatest(last_seen, current_date) "
                                 "RETURNING first_boot::text, current_date::text AS today, "
                                 "  (SELECT last_seen FROM ana_system.license_state)::text AS seen_before", []),
        {ok, Lic} = ana_db:rows("SELECT text FROM ana_system.license WHERE active", []),
        License = case Lic of
            [#{<<"text">> := T}] -> case verify(T, keys()) of {ok, P, _, _} -> P; _ -> none end;
            [] -> none
        end,
        #{<<"first_boot">> := F, <<"seen_before">> := Seen, <<"today">> := Today} = St,
        S = status(License, parse(F), parse(Seen), parse(Today), product_version()),
        Old = persistent_term:get(?KEY, undefined),
        _ = Old =/= S andalso persistent_term:put(?KEY, S),
        _ = (Old =:= undefined orelse maps:get(state, Old) =/= maps:get(state, S))
            andalso ok =:= logger:notice("license state: ~ts ~p", [maps:get(state, S), maps:get(reason, S)]),
        ok
    catch C:E ->
        logger:warning("license state not computed: ~p:~p", [C, E]),
        ok
    end.
