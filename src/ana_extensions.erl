%% Extension points (spec 009, D9): a customer program registered for a point of a product program runs in
%% the same transaction, without copying the product program. before_* may refuse (business error) or adjust
%% the fields the point allows; after_* receives the result. Registrations are cached in persistent_term and
%% refreshed by NOTIFY ana_extension (every node).
-module(ana_extensions).
-export([catalog/0, programs/1, list/0, save/2, delete/2, on_notify/2]).

-define(KEY, {?MODULE, registrations}).

%% {Point, Product program, Label, Adjustable fields}.
-define(POINTS, [
    {<<"before_invoice_order">>, <<"sales.invoice_order">>, <<"Antes de faturar o pedido (pode recusar)">>, []},
    {<<"after_invoice_order">>, <<"sales.invoice_order">>, <<"Depois de faturar o pedido">>, []},
    {<<"before_receive_purchase">>, <<"supply.receive">>, <<"Antes de receber a compra (pode recusar; ajusta documento e observação)"/utf8>>,
     [<<"document">>, <<"note">>]},
    {<<"after_receive_purchase">>, <<"supply.receive">>, <<"Depois de receber a compra">>, []},
    {<<"before_approve_purchase">>, <<"supply.approve_request">>, <<"Antes de aprovar a solicitação de compra (pode recusar)"/utf8>>, []},
    {<<"after_approve_purchase">>, <<"supply.approve_request">>, <<"Depois de aprovar a solicitação de compra"/utf8>>, []},
    {<<"before_invoice_project">>, <<"projects.invoice_project">>, <<"Antes de faturar o projeto (pode recusar; ajusta data e prazo)">>,
     [<<"through">>, <<"payment_days">>]},
    {<<"after_invoice_project">>, <<"projects.invoice_project">>, <<"Depois de faturar o projeto">>, []},
    {<<"before_settle_bill">>, <<"finance.banking">>, <<"Antes de baixar títulos pelo extrato ou cobrança (pode recusar)"/utf8>>, []},
    {<<"after_settle_bill">>, <<"finance.banking">>, <<"Depois de baixar títulos"/utf8>>, []}]).

-spec catalog() -> [map()].
catalog() -> [#{point => P, program => Prog, label => L, adjust => A} || {P, Prog, L, A} <- ?POINTS].

%% What the runtime needs for ana.extend(point, data): the programs, in order, and the adjustable fields.
-spec programs(binary()) -> map().
programs(Point) ->
    Regs = case persistent_term:get(?KEY, undefined) of
        undefined -> load();
        R -> R
    end,
    Adjust = case lists:keyfind(Point, 1, ?POINTS) of {_, _, _, A} -> A; false -> [] end,
    #{programs => maps:get(Point, Regs, []), adjust => Adjust}.

load() ->
    R = case ana_db:rows("SELECT point, program FROM ana_system.extension WHERE active ORDER BY point, position, id", []) of
        {ok, Rows} -> lists:foldl(fun(#{<<"point">> := P, <<"program">> := Pr}, Acc) ->
                                          Acc#{P => maps:get(P, Acc, []) ++ [Pr]} end, #{}, Rows);
        _ -> #{}
    end,
    persistent_term:put(?KEY, R),
    R.

on_notify(_Channel, _Payload) ->
    _ = load(),
    ok.

-spec list() -> {ok, map()}.
list() ->
    {ok, Rows} = ana_db:rows("SELECT id, point, program, position, active, created_by, created_at FROM ana_system.extension "
                             "ORDER BY point, position, id", []),
    {ok, #{points => catalog(), extensions => Rows}}.

%% Only programs of the customer (outside the product's namespaces) extend the product.
-spec save(map(), map()) -> {ok, map()} | {error, binary()}.
save(#{<<"point">> := Point, <<"program">> := Program} = F, #{username := Who}) when is_binary(Point), is_binary(Program) ->
    case {lists:keymember(Point, 1, ?POINTS), ana_seeds:reserved(Program) orelse lists:member(Program, product_programs()),
          ana_program:for_execution(Program)} of
        {false, _, _} -> {error, <<"ponto de extensão desconhecido"/utf8>>};
        {_, true, _} -> {error, <<"use um programa seu (fora dos namespaces do produto), por exemplo cli.meu_ajuste">>};
        {_, _, {ok, #{<<"kind">> := <<"program">>}}} ->
            case ana_db:one("INSERT INTO ana_system.extension (point, program, position, active, created_by) "
                            "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (point, program) DO UPDATE SET position = EXCLUDED.position, "
                            "active = EXCLUDED.active RETURNING id",
                            [Point, Program, maps:get(<<"position">>, F, 100), maps:get(<<"active">>, F, true) =/= false, Who]) of
                {ok, #{<<"id">> := Id}} ->
                    ana_admin:log(Who, <<"extension.save">>, Point, null, #{program => Program}),
                    _ = load(),
                    {ok, #{id => Id}};
                {error, _} -> {error, <<"não foi possível registrar a extensão"/utf8>>}
            end;
        _ -> {error, <<"programa inexistente, inativo ou biblioteca">>}
    end;
save(_, _) -> {error, <<"informe o ponto e o programa">>}.

-spec delete(integer(), map()) -> {ok, map()} | {error, not_found}.
delete(Id, #{username := Who}) ->
    case ana_db:exec("DELETE FROM ana_system.extension WHERE id = $1", [Id]) of
        {ok, 1} -> ana_admin:log(Who, <<"extension.delete">>, integer_to_binary(Id), null, null), _ = load(), {ok, #{deleted => Id}};
        _ -> {error, not_found}
    end.

product_programs() -> [Name || {Name, _} <- ana_seeds:files()].
