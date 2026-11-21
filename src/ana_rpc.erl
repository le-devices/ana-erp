%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Exposed programs (spec 003).
%%
%% Erlang API callable locally or from another node (RF-003-06):
%%   erpc:call('ana@host', ana_rpc, call, [<<"sales.create_order">>, Params, <<"username">>])
-module(ana_rpc).
-export([call/3, functions/1, jsonrpc_code/1]).

%% User: session map (#{username, role}) or a username (binary) — the latter
%% for Erlang distribution calls, where the node is already trusted (cookie).
-spec call(binary(), map(), map() | binary()) -> {ok, term()} | {error, map()}.
call(Function, Params, Username) when is_binary(Username) ->
    %% RF-024-02: recorded as an access from the calling node.
    From = atom_to_binary(node(group_leader())),
    T0 = erlang:monotonic_time(millisecond),
    {Result, Who} = case ana_db:one("SELECT username, role FROM ana_system.app_user "
                                    "WHERE username = $1 AND active", [Username]) of
        {ok, #{<<"username">> := U, <<"role">> := R}} ->
            {call(Function, Params, #{username => U, role => R,
                                      trace => #{ip => From, auth => <<"node">>, key_id => null}}), U};
        _ ->
            {{error, err(<<"FORBIDDEN">>, <<"usuário inválido"/utf8>>)}, null}
    end,
    ana_access_log:record(#{username => Who, auth => <<"node">>, ip => From, method => <<"ERPC">>,
                            path => <<"ana_rpc:call/", (fn(Function))/binary>>,
                            status => case Result of {ok, _} -> 200; _ -> 400 end,
                            duration_ms => erlang:monotonic_time(millisecond) - T0}),
    Result;
call(Function, Params, User) when is_binary(Function), is_map(Params), is_map(User) ->
    %% RF-003-02: only exposed programs; never reveals whether others exist.
    case ana_program:valid_name(Function) andalso ana_program:for_execution(Function) of
        {ok, #{<<"exposed">> := true, <<"active">> := true, <<"kind">> := <<"program">>,
               <<"min_role">> := Min} = P} ->
            case api_allows(User, Function, P) andalso ana_security:has_role(User, Min) andalso ana_access:allowed(User, P) of
                true ->
                    case ana_execution:run(Function, Params, User, #{origin => <<"remote">>}) of
                        {ok, #{result := R}} -> {ok, R};
                        {error, E} -> {error, public(E)}
                    end;
                false when is_map_key(api, User) ->
                    %% RNF-010-05: outside the client's scope, as if it did not exist.
                    {error, err(<<"NOT_FOUND">>, <<"função não encontrada"/utf8>>)};
                false ->
                    {error, err(<<"FORBIDDEN">>, <<"sem permissão"/utf8>>)}
            end;
        _ ->
            {error, err(<<"NOT_FOUND">>, <<"função não encontrada"/utf8>>)}
    end;
call(_, _, _) ->
    {error, err(<<"INVALID_REQUEST">>, <<"params deve ser um objeto"/utf8>>)}.

%% Spec 010 (RF-010-05): exposed ∩ client scopes (∩ public for a publishable key).
api_allows(#{api := #{scopes := Scopes, kind := Kind}}, Function, P) ->
    ana_api:in_scope(Scopes, Function) andalso (Kind =/= <<"publishable">> orelse maps:get(<<"public">>, P, false) =:= true);
api_allows(_, _, _) -> true.

fn(F) when is_binary(F), byte_size(F) =< 200 -> F;
fn(_) -> <<"?">>.

%% RF-003-05
functions(User) ->
    {ok, Rows} = ana_db:rows(
        "SELECT name, description, params, docs, min_role, restricted, public "
        "FROM ana_system.program WHERE exposed AND active AND kind = 'program' ORDER BY name", []),
    {ok, [maps:without([<<"min_role">>, <<"restricted">>, <<"public">>], R)
          || R = #{<<"min_role">> := M, <<"name">> := N} <- Rows,
             api_allows(User, N, R), ana_security:has_role(User, M), ana_access:allowed(User, R)]}.

%% RF-003-04: external callers never see internal traces.
public(#{<<"code">> := C} = E) ->
    Base = maps:with([<<"code">>, <<"message">>, <<"execution_id">>, <<"data">>], E),
    case internal(C) of
        true -> Base#{<<"message">> => <<"erro interno">>};
        false -> Base
    end.

internal(<<"EXCEPTION">>) -> true;
internal(<<"INTERNAL">>) -> true;
internal(<<"SQL">>) -> true;
internal(<<"PROTOCOL">>) -> true;
internal(<<"PROCESS_EXITED">>) -> true;
internal(<<"SYNTAX">>) -> true;
internal(_) -> false.

%% JSON-RPC codes (spec 003 plan).
jsonrpc_code(<<"NOT_FOUND">>) -> -32601;
jsonrpc_code(<<"PROGRAM_NOT_FOUND">>) -> -32601;
jsonrpc_code(<<"PROGRAM_INACTIVE">>) -> -32601;
jsonrpc_code(<<"NOT_EXECUTABLE">>) -> -32601;
jsonrpc_code(<<"INVALID_PARAMETER">>) -> -32602;
jsonrpc_code(<<"INVALID_REQUEST">>) -> -32600;
jsonrpc_code(<<"FORBIDDEN">>) -> -32003;
jsonrpc_code(<<"OVERLOAD">>) -> -32004;
jsonrpc_code(<<"QUOTA_EXCEEDED">>) -> -32004;
jsonrpc_code(<<"PROGRAM_BUSY">>) -> -32004;
jsonrpc_code(<<"TIMEOUT">>) -> -32001;
jsonrpc_code(C) ->
    case internal(C) of
        true -> -32603;
        false -> -32000
    end.

err(C, M) -> #{<<"code">> => C, <<"message">> => M}.
