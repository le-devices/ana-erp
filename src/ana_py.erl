%% Runtime Python processes (spec 002, plan "Isolamento").
%%
%% Each process is a {packet, 4} port with a clean environment (RNF-002-01): no
%% core variable — database credentials in particular — is inherited.
-module(ana_py).
-export([open/0, wait_ready/2, checkout/0, send/2, decode/1, kill/1, inspect/1]).

-define(READY_TIMEOUT, 10000).

%% Opens a process and returns {ok, Port, OsPid} once it is ready.
-spec open() -> {ok, port(), integer()} | {error, term()}.
open() ->
    case python() of
        false -> {error, python_not_found};
        Exe ->
            Runtime = filename:join([code:priv_dir(ana), "python", "ana_runtime.py"]),
            Args = case ana_config:boolean("ANA_PY_SITE", false) of
                true -> ["-I", "-B", Runtime];
                false -> ["-I", "-S", "-B", Runtime]
            end,
            Port = open_port({spawn_executable, Exe},
                             [{packet, 4}, binary, exit_status, use_stdio,
                              {args, Args}, {cd, directory()}, {env, environment()}]),
            wait_ready(Port, ?READY_TIMEOUT)
    end.

-spec wait_ready(port(), timeout()) -> {ok, port(), integer()} | {error, term()}.
wait_ready(Port, Timeout) ->
    receive
        {Port, {data, Bin}} ->
            case decode(Bin) of
                #{<<"type">> := <<"ready">>, <<"pid">> := Pid} -> {ok, Port, Pid};
                Other -> catch port_close(Port), {error, {unexpected, Other}}
            end;
        {Port, {exit_status, S}} ->
            {error, {exited, S}}
    after Timeout ->
        catch port_close(Port),
        {error, timeout}
    end.

%% Takes a prewarmed process from the pool, or opens one right away (RNF-002-07).
-spec checkout() -> {ok, port(), integer()} | {error, term()}.
checkout() ->
    case catch ana_py_pool:checkout() of
        {ok, Port, Pid} -> {ok, Port, Pid};
        _ -> open()
    end.

send(Port, Msg) ->
    port_command(Port, json:encode(Msg)).

decode(Bin) ->
    try json:decode(Bin) catch _:_ -> {invalid, Bin} end.

%% Ends the process immediately (timeout, stop, failure).
-spec kill({port(), integer()}) -> ok.
kill({Port, OsPid}) ->
    catch port_close(Port),
    _ = (catch os:cmd("kill -9 " ++ integer_to_list(OsPid) ++ " 2>/dev/null")),
    ok.

%% Checks syntax and extracts PARAMS without running (RF-005-08).
-spec inspect(binary()) -> {ok, map()} | {error, term()}.
inspect(Source) ->
    case checkout() of
        {ok, Port, OsPid} ->
            send(Port, #{type => inspect, source => Source}),
            receive
                {Port, {data, Bin}} ->
                    kill({Port, OsPid}),
                    {ok, decode(Bin)};
                {Port, {exit_status, S}} ->
                    {error, {exited, S}}
            after 10000 ->
                kill({Port, OsPid}),
                {error, timeout}
            end;
        E -> E
    end.

python() ->
    os:find_executable(ana_config:text("ANA_PYTHON", "python3")).

directory() ->
    D = ana_config:text("ANA_PY_DIR", "/tmp"),
    case filelib:is_dir(D) of true -> D; false -> "/" end.

%% Clean environment: removes everything inherited and sets only what is needed.
environment() ->
    Inherited = [K || KV <- os:getenv(), [K | _] <- [string:split(KV, "=")], K =/= ""],
    [{K, false} || K <- Inherited] ++
        [{"PATH", "/usr/local/bin:/usr/bin:/bin"},
         {"LANG", "C.UTF-8"},
         {"PYTHONDONTWRITEBYTECODE", "1"},
         {"PYTHONUNBUFFERED", "1"},
         {"TZ", ana_config:timezone()},
         {"ANA_PY_MEMORY_MB", integer_to_list(ana_config:integer("ANA_PY_MEMORY_MB", 512))},
         {"ANA_PY_CPU_S", integer_to_list(ana_config:integer("ANA_PY_CPU_S", 3600))},
         {"ANA_OUTPUT_MAX_KB", integer_to_list(ana_settings:get(output_max_kb))}].
