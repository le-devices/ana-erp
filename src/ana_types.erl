%% PostgreSQL <-> JSON type conversion (spec 001, plan.md "Tipos").
%%
%% Parameters arrive as JSON terms (binaries, numbers, booleans, null, maps,
%% lists) and are coerced to the type PostgreSQL expects for each position of
%% the prepared statement. Results become JSON-serializable terms, keeping
%% `numeric` exact (as text).
-module(ana_types).
-export([coerce_params/2, coerce/2, to_json/2, type_name/1,
         iso_date/1, iso_timestamp/2]).

-define(OID_NUMERIC, 1700).

%% --------------------------------------------------------------------------
%% Type names
%% --------------------------------------------------------------------------

-spec type_name(term()) -> binary().
type_name({unknown_oid, ?OID_NUMERIC}) -> <<"numeric">>;
type_name({unknown_oid, 19}) -> <<"text">>;    % name
type_name({unknown_oid, 26}) -> <<"int">>;     % oid
type_name({unknown_oid, Oid}) -> <<"oid:", (integer_to_binary(Oid))/binary>>;
type_name({array, T}) -> <<(type_name(T))/binary, "[]">>;
type_name(T) when is_atom(T) -> atom_to_binary(T, utf8).

%% --------------------------------------------------------------------------
%% Parameters: JSON -> Erlang/epgsql
%% --------------------------------------------------------------------------

-spec coerce_params([term()], [term()]) -> {ok, [term()]} | {error, binary()}.
coerce_params(Types, Values) when length(Types) =/= length(Values) ->
    {error, unicode:characters_to_binary(io_lib:format(
        "a instrução espera ~b parâmetro(s), recebeu ~b", [length(Types), length(Values)]))};
coerce_params(Types, Values) ->
    try
        {ok, lists:zipwith(fun coerce/2, Types, Values)}
    catch
        throw:{type, Type, Value} ->
            {error, unicode:characters_to_binary(io_lib:format(
                "valor ~0p incompatível com o tipo ~s", [Value, type_name(Type)]))}
    end.

-spec coerce(term(), term()) -> term().
coerce(_, null) -> null;
coerce(_, undefined) -> null;
coerce({array, T}, L) when is_list(L) -> [coerce(T, V) || V <- L];
coerce(T, V) when T =:= int2; T =:= int4; T =:= int8 -> to_integer(T, V);
coerce(T, V) when T =:= float4; T =:= float8 -> to_float(T, V);
coerce(bool, true) -> true;
coerce(bool, false) -> false;
coerce(bool, <<"true">>) -> true;
coerce(bool, <<"false">>) -> false;
coerce(bool, 1) -> true;
coerce(bool, 0) -> false;
coerce(date, V) when is_binary(V) -> date(V);
coerce(T, V) when (T =:= timestamp orelse T =:= timestamptz), is_binary(V) -> timestamp(T, V);
coerce(time, V) when is_binary(V) -> time(V);
coerce(T, V) when (T =:= json orelse T =:= jsonb), (is_map(V) orelse is_list(V)) ->
    iolist_to_binary(json:encode(V));
coerce(T, V) when (T =:= json orelse T =:= jsonb), is_binary(V) -> V;
coerce(T, V) when (T =:= json orelse T =:= jsonb) -> iolist_to_binary(json:encode(V));
coerce({unknown_oid, _}, V) when is_binary(V); is_integer(V); is_float(V) -> V;
coerce({unknown_oid, _}, true) -> <<"true">>;
coerce({unknown_oid, _}, false) -> <<"false">>;
coerce(T, V) when T =:= text; T =:= varchar; T =:= bpchar ->
    if is_binary(V) -> V;
       is_integer(V) -> integer_to_binary(V);
       is_float(V) -> float_to_binary(V, [short]);
       is_boolean(V) -> atom_to_binary(V, utf8);
       true -> throw({type, T, V})
    end;
coerce(uuid, V) when is_binary(V) -> V;
coerce(bytea, V) when is_binary(V) -> V;
coerce(_, V) when is_map(V) -> throw({type, object, V});
coerce(_T, V) when is_binary(V); is_integer(V); is_float(V); is_boolean(V) -> V;
coerce(T, V) -> throw({type, T, V}).

to_integer(_, V) when is_integer(V) -> V;
to_integer(T, V) when is_float(V) ->
    case trunc(V) == V of
        true -> trunc(V);
        false -> throw({type, T, V})
    end;
to_integer(T, V) when is_binary(V) ->
    try binary_to_integer(string:trim(V))
    catch error:badarg -> throw({type, T, V})
    end;
to_integer(T, V) -> throw({type, T, V}).

to_float(_, V) when is_float(V) -> V;
to_float(_, V) when is_integer(V) -> float(V);
to_float(T, V) when is_binary(V) ->
    S = string:trim(V),
    try binary_to_float(S)
    catch error:badarg ->
        try float(binary_to_integer(S))
        catch error:badarg -> throw({type, T, V})
        end
    end;
to_float(T, V) -> throw({type, T, V}).

date(<<Y:4/binary, "-", M:2/binary, "-", D:2/binary, _/binary>> = V) ->
    try
        Date = {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)},
        true = calendar:valid_date(Date),
        Date
    catch _:_ -> throw({type, date, V})
    end;
date(V) -> throw({type, date, V}).

time(V) ->
    try
        [H, M | R] = binary:split(V, <<":">>, [global]),
        S = case R of [] -> 0.0; [Sb | _] -> to_float(time, Sb) end,
        {binary_to_integer(H), binary_to_integer(M), S}
    catch _:_ -> throw({type, time, V})
    end.

%% Accepts "YYYY-MM-DD", "YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]" and a space
%% instead of the T. timestamptz is normalized to UTC; timestamp drops the offset.
timestamp(T, V) when byte_size(V) =:= 10 ->
    _ = date(V),
    timestamp(T, <<V/binary, "T00:00:00">>);
timestamp(T, V0) ->
    V = binary:replace(V0, <<" ">>, <<"T">>),
    HasOffset = offset_size(V) > 0,
    Text = case HasOffset of
        true -> binary_to_list(V);
        false -> binary_to_list(V) ++ "Z"
    end,
    try calendar:rfc3339_to_system_time(Text, [{unit, microsecond}]) of
        Micros when T =:= timestamptz; not HasOffset ->
            from_micros(Micros);
        _Micros ->
            Local = binary:part(V, 0, byte_size(V) - offset_size(V)),
            timestamp(T, Local)
    catch _:_ -> throw({type, T, V0})
    end.

offset_size(V) ->
    case binary:last(V) of
        $Z -> 1;
        _ when byte_size(V) > 19 ->
            case binary:part(V, byte_size(V) - 6, 6) of
                <<S, _, _, $:, _, _>> when S =:= $+; S =:= $- -> 6;
                _ -> 0
            end;
        _ -> 0
    end.

from_micros(Micros) ->
    Sec = Micros div 1000000,
    Frac = Micros rem 1000000,
    {Date, {H, M, S}} = calendar:system_time_to_universal_time(Sec, second),
    {Date, {H, M, S + Frac / 1000000}}.

%% --------------------------------------------------------------------------
%% Results: epgsql -> JSON
%% --------------------------------------------------------------------------

-spec to_json(term(), term()) -> term().
to_json(null, _) -> null;
to_json(V, date) -> iso_date(V);
to_json(V, timestamp) -> iso_timestamp(V, false);
to_json(V, timestamptz) -> iso_timestamp(V, true);
to_json({H, M, S}, time) -> unicode:characters_to_binary(io_lib:format("~2..0b:~2..0b:~s", [H, M, seconds(S)]));
to_json({{H, M, S}, D, Mon}, interval) ->
    unicode:characters_to_binary(io_lib:format("~b mons ~b days ~2..0b:~2..0b:~s", [Mon, D, H, M, seconds(S)]));
to_json(V, T) when (T =:= json orelse T =:= jsonb), is_binary(V) ->
    try json:decode(V) catch _:_ -> V end;
to_json(V, bytea) when is_binary(V) -> base64:encode(V);
to_json(V, {array, T}) when is_list(V) -> [to_json(E, T) || E <- V];
to_json(V, _) when is_binary(V) ->
    case unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> base64:encode(V)
    end;
to_json(V, _) when is_integer(V); is_float(V); is_boolean(V) -> V;
to_json({A, B}, T) -> [to_json(A, T), to_json(B, T)];
to_json(V, _) -> unicode:characters_to_binary(io_lib:format("~0p", [V])).

-spec iso_date(calendar:date()) -> binary().
iso_date({Y, M, D}) ->
    unicode:characters_to_binary(io_lib:format("~4..0b-~2..0b-~2..0b", [Y, M, D])).

-spec iso_timestamp({calendar:date(), {integer(), integer(), number()}}, boolean()) -> binary().
iso_timestamp({Date, {H, Mi, S}}, Utc) ->
    iolist_to_binary([iso_date(Date),
                      io_lib:format("T~2..0b:~2..0b:~s", [H, Mi, seconds(S)]),
                      case Utc of true -> "Z"; false -> "" end]).

seconds(S) when is_integer(S) -> io_lib:format("~2..0b", [S]);
seconds(S) when is_float(S) ->
    Int = trunc(S),
    Micros = round((S - Int) * 1000000),
    case Micros of
        0 -> io_lib:format("~2..0b", [Int]);
        1000000 -> io_lib:format("~2..0b", [Int + 1]);
        _ -> io_lib:format("~2..0b.~6..0b", [Int, Micros])
    end.
