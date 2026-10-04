%% Structured logs (spec 019, RF-019-09): one JSON object per line with the
%% correlation metadata (execution_id, program, user) set by each process.
%% Enabled with ANA_LOG_FORMAT=json.
-module(ana_log_json).
-export([format/2, enable/0]).

enable() ->
    case string:lowercase(ana_config:text("ANA_LOG_FORMAT", "text")) of
        "json" -> logger:update_handler_config(default, formatter, {?MODULE, #{}});
        _ -> ok
    end.

format(#{level := Level, msg := Msg, meta := Meta}, _Config) ->
    Text = case Msg of
        {string, S} -> unicode:characters_to_binary(S);
        {report, R} -> unicode:characters_to_binary(io_lib:format("~0tp", [R]));
        {Fmt, Args} -> unicode:characters_to_binary(io_lib:format(Fmt, Args))
    end,
    Base = #{time => list_to_binary(calendar:system_time_to_rfc3339(maps:get(time, Meta, erlang:system_time(microsecond)),
                                                                     [{unit, microsecond}, {offset, "Z"}])),
             level => Level, msg => Text, node => ana_config:node_id()},
    Corr = maps:with([execution_id, program, user], Meta),
    Where = case Meta of
        #{mfa := {M, F, A}} -> #{mfa => unicode:characters_to_binary(io_lib:format("~p:~p/~p", [M, F, A]))};
        _ -> #{}
    end,
    [json:encode(maps:merge(maps:merge(Base, Corr), Where)), $\n].
