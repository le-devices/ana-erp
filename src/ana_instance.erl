%% Role of this installation (spec 034, RF-034-01): production (default), test or development.
%% Shown on screen outside production; production can require transports for program changes.
-module(ana_instance).

-export([role/0, name/0, product_version/0, info/0, transport_required/0]).

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
