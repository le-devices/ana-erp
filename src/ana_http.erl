%% HTTP server and shared helpers (spec 001: RF-001-05..07, RNF-001-03..05).
-module(ana_http).
-export([start/0, json/3, reply_error/4, read_json/1, authenticate/1, require/3, require_any/2,
         ip/1, qs_int/3, qs_map/1]).

start() ->
    ana_http_static:load(),
    Routes = cowboy_router:compile([{'_', [
        {"/", ana_http_static, <<"index.html">>},
        {"/studio/:file", ana_http_static, undefined},
        {"/health", ana_http_api, health},
        {"/health/live", ana_http_api, live},
        {"/health/ready", ana_http_api, ready},
        {"/api/admin/[...]", ana_http_admin, admin},
        {"/api/scheduler/[...]", ana_http_scheduler, scheduler},
        {"/api/[...]", ana_http_api, api},
        {"/rpc", ana_http_rpc, rpc},
        {"/rpc/functions", ana_http_rpc, functions}
    ]}]),
    Port = ana_config:integer("ANA_HTTP_PORT", 8080),
    {ok, _} = cowboy:start_clear(ana_http,
        #{socket_opts => [{port, Port}], max_connections => 16384, num_acceptors => 16},
        #{env => #{dispatch => Routes},
          middlewares => [cowboy_router, ana_http_security, cowboy_handler],
          %% RF-024-01: every API request is recorded (ana_access_log).
          stream_handlers => [cowboy_metrics_h, cowboy_stream_h],
          metrics_callback => fun ana_access_log:metrics_callback/1,
          idle_timeout => 60000,
          request_timeout => 30000,
          max_header_value_length => 8192,
          max_headers => 64}),
    logger:notice("ANA ERP listening on port ~b", [Port]),
    ok.

json(Status, Body, Req) ->
    cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json; charset=utf-8">>},
                     json:encode(Body), Req).

%% RNF-001-03
reply_error(Status, Code, Message, Req) ->
    json(Status, #{error => #{code => Code, message => unicode:characters_to_binary(Message)}}, Req).

%% RNF-001-05: bounded request body.
-spec read_json(cowboy_req:req()) ->
          {ok, term(), cowboy_req:req()} | {too_large, cowboy_req:req()} | {invalid, cowboy_req:req()}.
read_json(Req) ->
    Max = ana_config:integer("ANA_HTTP_MAX_BODY", 2 * 1024 * 1024),
    case cowboy_req:body_length(Req) of
        N when is_integer(N), N > Max -> {too_large, Req};
        _ ->
            case cowboy_req:read_body(Req, #{length => Max, period => 15000}) of
                {ok, <<>>, Req2} -> {ok, #{}, Req2};
                {ok, Body, Req2} ->
                    try {ok, json:decode(Body), Req2}
                    catch _:_ -> {invalid, Req2}
                    end;
                {more, _, Req2} -> {too_large, Req2}
            end
    end.

%% RF-001-06
-spec authenticate(cowboy_req:req()) -> {ok, map()} | {error, invalid}.
%% The authenticated user carries `trace` (ip, auth, key_id) so executions
%% record where they came from (RF-024-04); the request is tagged for the
%% access log (RF-024-01).
authenticate(Req) ->
    Ip = ip(Req),
    Result = case cowboy_req:header(<<"authorization">>, Req) of
        <<"Bearer ana_rk_", _/binary>> = H ->
            <<"Bearer ", Key/binary>> = H,
            traced(ana_security:validate_key(string:trim(Key), Ip), <<"api_key">>, Ip);
        <<"Bearer ", Token/binary>> ->
            traced(ana_security:validate(string:trim(Token)), <<"session">>, Ip);
        _ -> {error, invalid}
    end,
    ok = case Result of
        {ok, #{username := U, trace := T}} -> ana_access_log:tag(T#{username => U}, Req);
        _ -> ok
    end,
    Result.

traced({ok, U}, Auth, Ip) ->
    {ok, U#{trace => #{ip => Ip, auth => Auth, key_id => maps:get(key_id, U, null)}}};
traced(E, _, _) -> E.

%% RF-001-10 + RF-011-03: authenticates, requires a minimum role and refuses
%% sessions that must change the password first.
require(Req, Role, Fun) ->
    require_any(Req, fun
        (#{must_change_password := true}) ->
            reply_error(403, <<"PASSWORD_CHANGE_REQUIRED">>, <<"troque sua senha para continuar">>, Req);
        (U) ->
            case ana_security:has_role(U, Role) of
                true -> Fun(U);
                false -> reply_error(403, <<"FORBIDDEN">>, <<"papel insuficiente">>, Req)
            end
    end).

%% Any valid session, even one that must change the password (me, password, logout).
require_any(Req, Fun) ->
    case authenticate(Req) of
        {ok, U} -> Fun(U);
        {error, _} -> reply_error(401, <<"NOT_AUTHENTICATED">>, <<"credencial ausente ou inválida"/utf8>>, Req)
    end.

ip(Req) ->
    {Ip, _} = cowboy_req:peer(Req),
    list_to_binary(inet:ntoa(Ip)).

qs_int(Name, Req, Default) ->
    case lists:keyfind(Name, 1, cowboy_req:parse_qs(Req)) of
        {_, V} when is_binary(V) -> try binary_to_integer(V) catch _:_ -> Default end;
        _ -> Default
    end.

qs_map(Req) ->
    maps:from_list([{K, V} || {K, V} <- cowboy_req:parse_qs(Req), is_binary(V)]).
