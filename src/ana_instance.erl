%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Role of this installation (spec 034, RF-034-01): production (default), test or development.
%% Shown on screen outside production; production can require transports for program changes.
-module(ana_instance).

-export([role/0, name/0, product_version/0, info/0, transport_required/0, public_url/0, forget_public_url/0]).

-spec role() -> binary().
role() ->
    case string:lowercase(ana_config:text("ANA_INSTANCE", "production")) of
        "test" -> <<"test">>;
        "development" -> <<"development">>;
        _ -> <<"production">>
    end.

%% Name of this instance in transport packages (origin). Defaults to "ana-<role>".
-spec name() -> binary().
name() ->
    N = list_to_binary(string:lowercase(ana_config:text("ANA_INSTANCE_NAME", ""))),
    case re:run(N, <<"^[a-z][a-z0-9_-]{1,62}$">>) of
        {match, _} -> N;
        nomatch -> <<"ana-", (role())/binary>>
    end.

-spec product_version() -> binary().
product_version() ->
    case application:get_key(ana, vsn) of
        {ok, V} -> list_to_binary(V);
        _ -> <<"0.0.0">>
    end.

-spec info() -> map().
info() -> #{role => role(), name => name(), product_version => product_version()}.

%% Production with "transport_required" on: programs change only by importing a package.
-spec transport_required() -> boolean().
transport_required() ->
    role() =:= <<"production">> andalso ana_settings:get(transport_required) =:= 1.

%% Spec 037: public address used in links sent to partners. The administrator's value
%% (Administração → Empresa) wins over the installer's ANA_PUBLIC_URL; cached for 30 s per node
%% (another node sees a change within that time).
-spec public_url() -> binary().
public_url() ->
    Now = erlang:monotonic_time(millisecond),
    %% Kept in the settings cache table (public ETS owned by the application).
    case catch ets:lookup(ana_settings_cache, {?MODULE, public_url}) of
        [{_, {Url, At}}] when Now - At < 30000 -> Url;
        _ ->
            Url = case catch ana_db:one("SELECT public_url FROM base.company WHERE public_url IS NOT NULL ORDER BY id LIMIT 1", []) of
                {ok, #{<<"public_url">> := U}} when is_binary(U), U =/= <<>> -> U;
                _ -> list_to_binary(string:trim(ana_config:text("ANA_PUBLIC_URL", ""), trailing, "/"))
            end,
            _ = catch ets:insert(ana_settings_cache, {{?MODULE, public_url}, {Url, Now}}),
            Url
    end.

-spec forget_public_url() -> ok.
forget_public_url() ->
    _ = catch ets:delete(ana_settings_cache, {?MODULE, public_url}),
    ok.
