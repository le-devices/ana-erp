%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Quality gate of programs (spec 064, phase 1: T-064-02..04).
%%
%% Findings come from the inspection of the Python runtime (security, performance, robustness, standards,
%% disk), each with a fingerprint (rule + the text of its line). A program passes the gate when no finding
%% at or above the blocking severity is left after the baseline (old findings) and the approved, unexpired
%% exemptions (approved by someone other than who asked — the database enforces it). Transport packages
%% carry the gate report inside the signed manifest; production may refuse packages without it.
-module(ana_quality).

-export([inspect/1, gate/1, blocking_level/0, check_manifest/1,
         exemptions/1, request_exemption/2, decide_exemption/4, set_baseline/2]).

-define(LEVELS, [<<"info">>, <<"warning">>, <<"serious">>, <<"critical">>]).

%% ---------------------------------------------------------------- inspection (editor, while typing)

-spec inspect(binary()) -> {ok, map()} | {error, binary()}.
inspect(Source) when is_binary(Source), byte_size(Source) =< 1048576 ->
    case ana_py:inspect(Source) of
        {ok, #{<<"ok">> := false, <<"error">> := #{<<"line">> := L, <<"message">> := M}}} ->
            {ok, #{ok => false, syntax => #{line => L, message => M}, lint => []}};
        {ok, #{<<"ok">> := true} = R} ->
            %% Spec 065 (D8, T-065-11): a company value that does not exist, and a constant that already is one.
            {ok, #{ok => true, lint => maps:get(<<"lint">>, R, []) ++ ana_values:quality_findings(Source),
                   params => maps:get(<<"params">>, R, null)}};
        {error, _} -> {error, <<"inspeção indisponível agora; tente de novo"/utf8>>}
    end;
inspect(_) -> {error, <<"código ausente ou grande demais"/utf8>>}.

%% ---------------------------------------------------------------- gate

-spec blocking_level() -> binary().
blocking_level() ->
    lists:nth(ana_settings:get(quality_gate_level) + 1, ?LEVELS).

rank(S) -> rank(S, ?LEVELS, 0).
rank(S, [S | _], N) -> N;
rank(S, [_ | T], N) -> rank(S, T, N + 1);
rank(_, [], _) -> 0.

%% Report for the named programs (the sources as they are now).
-spec gate([binary()]) -> {ok, map()}.
gate(Names) ->
    Level = blocking_level(),
    {ok, Rows} = ana_db:rows("SELECT name, source FROM ana_system.program WHERE name = ANY($1::text[]) ORDER BY name", [Names]),
    {ok, Base} = ana_db:rows("SELECT program, fingerprint FROM ana_system.quality_baseline WHERE program = ANY($1::text[])", [Names]),
    {ok, Ex} = ana_db:rows("SELECT id, program, fingerprint, decided_by FROM ana_system.quality_exemption "
                           "WHERE program = ANY($1::text[]) AND status = 'approved' AND valid_until >= current_date", [Names]),
    Baseline = sets:from_list([{P, F} || #{<<"program">> := P, <<"fingerprint">> := F} <- Base]),
    Exempt = maps:from_list([{{P, F}, #{id => I, approved_by => D}} || #{<<"id">> := I, <<"program">> := P,
                                                                         <<"fingerprint">> := F, <<"decided_by">> := D} <- Ex]),
    Programs = [program_report(N, S, Level, Baseline, Exempt) || #{<<"name">> := N, <<"source">> := S} <- Rows, is_binary(S)],
    Ok = lists:all(fun(#{blocking := B}) -> B =:= [] end, Programs),
    {ok, #{ok => Ok, level => Level, programs => Programs, product_version => ana_instance:product_version(),
           instance => ana_instance:name(),
           checked_at => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}]))}}.

program_report(Name, Source, Level, Baseline, Exempt) ->
    Sha = ana_transport:item_sha(#{<<"kind">> => <<"program">>, <<"source">> => Source}),
    %% Spec 064 (D4, D5): the latest test run of this exact source — failing tests, performance worse than the
    %% previous version, and (by policy) a program that writes without a passing test.
    Findings = ana_program_tests:gate_findings(Name, Sha) ++ case inspect(Source) of
        {ok, #{ok := true, lint := L}} -> L;
        {ok, #{ok := false, syntax := #{line := Ln, message := M}}} ->
            [#{<<"line">> => Ln, <<"rule">> => <<"syntax">>, <<"severity">> => <<"critical">>, <<"category">> => <<"robustness">>,
               <<"message">> => M, <<"fingerprint">> => <<"0000000000000000">>}];
        {error, M} -> [#{<<"line">> => 0, <<"rule">> => <<"inspection">>, <<"severity">> => <<"critical">>,
                         <<"category">> => <<"robustness">>, <<"message">> => M, <<"fingerprint">> => <<"0000000000000000">>}]
    end,
    Relevant = [F || F = #{<<"severity">> := S} <- Findings, rank(S) >= rank(Level)],
    {Blocking, Exempted, Old} = lists:foldr(
        fun(F = #{<<"fingerprint">> := FP}, {B, E, O}) ->
                case {sets:is_element({Name, FP}, Baseline), maps:find({Name, FP}, Exempt)} of
                    {true, _} -> {B, E, [brief(F) | O]};
                    {false, {ok, X}} -> {B, [(brief(F))#{exemption => X} | E], O};
                    _ -> {[brief(F) | B], E, O}
                end
        end, {[], [], []}, Relevant),
    #{name => Name, sha256 => Sha,
      blocking => Blocking, exempted => Exempted, baseline => Old, findings => length(Findings)}.

brief(F) -> maps:with([<<"line">>, <<"rule">>, <<"severity">>, <<"category">>, <<"message">>, <<"suggestion">>, <<"fingerprint">>], F).

%% Destination side (D7, CA-064-04): with the policy on, a package with programs needs a green gate report that
%% covers exactly the programs it carries. The report is inside the signed manifest, so it cannot be forged.
-spec check_manifest(map()) -> ok | {error, binary()}.
check_manifest(#{<<"items">> := Items} = M) ->
    Progs = [{N, H} || #{<<"kind">> := <<"program">>, <<"name">> := N, <<"sha256">> := H} <- Items],
    case {ana_settings:get(quality_gate_required), Progs, maps:get(<<"quality_gate">>, M, null)} of
        {0, _, _} -> ok;
        {_, [], _} -> ok;
        {_, _, null} -> {error, <<"pacote sem relatório do portão de qualidade: esta instalação exige o portão (spec 064)"/utf8>>};
        {_, _, #{<<"ok">> := true, <<"programs">> := Reported}} ->
            Covered = [{N, H} || #{<<"name">> := N, <<"sha256">> := H, <<"blocking">> := []} <- Reported],
            case Progs -- Covered of
                [] -> ok;
                Missing -> {error, iolist_to_binary([<<"o relatório do portão não cobre estes programas como estão no pacote: "/utf8>>,
                                                     lists:join(<<", ">>, [N || {N, _} <- Missing])])}
            end;
        {_, _, _} -> {error, <<"o portão de qualidade do pacote não está verde"/utf8>>}
    end;
check_manifest(_) -> ok.

%% ---------------------------------------------------------------- exemptions (D3, CA-064-02)

-spec exemptions(map()) -> {ok, [map()]}.
exemptions(Filter) ->
    ana_db:rows("SELECT id, program, fingerprint, rule, reason, valid_until, status, requested_by, requested_at, "
                "  decided_by, decided_at, decision FROM ana_system.quality_exemption "
                "WHERE ($1::text IS NULL OR program = $1) AND ($2::text IS NULL OR status = $2) "
                "ORDER BY status = 'requested' DESC, requested_at DESC LIMIT 500",
                [maps:get(<<"program">>, Filter, null), maps:get(<<"status">>, Filter, null)]).

-spec request_exemption(map(), map()) -> {ok, map()} | {error, binary()}.
request_exemption(#{<<"program">> := P, <<"fingerprint">> := F, <<"reason">> := R, <<"valid_until">> := U}, #{username := Who})
  when is_binary(P), is_binary(F), is_binary(R), is_binary(U) ->
    Max = ana_settings:get(quality_exemption_max_days),
    case ana_db:one("SELECT name, source FROM ana_system.program WHERE name = $1", [P]) of
        {ok, #{<<"source">> := Src}} when is_binary(Src) ->
            Rule = case inspect(Src) of
                {ok, #{lint := L}} -> hd([Ru || #{<<"fingerprint">> := Fp, <<"rule">> := Ru} <- L, Fp =:= F] ++ [undefined]);
                _ -> undefined
            end,
            case Rule of
                undefined -> {error, <<"esse achado não existe mais neste programa"/utf8>>};
                _ ->
                    case ana_db:one("INSERT INTO ana_system.quality_exemption (program, fingerprint, rule, reason, valid_until, requested_by) "
                                    "SELECT $1, $2, $3, $4, $5::date, $6 WHERE $5::date BETWEEN current_date AND current_date + $7::int "
                                    "RETURNING id", [P, F, Rule, string:trim(R), U, Who, Max]) of
                        {ok, #{<<"id">> := Id}} ->
                            ana_admin:log(Who, <<"quality.exemption.request">>, P, null, #{id => Id, rule => Rule, until => U}),
                            {ok, #{id => Id, status => <<"requested">>}};
                        {ok, undefined} -> {error, iolist_to_binary([<<"prazo da isenção: de hoje até "/utf8>>, integer_to_binary(Max), <<" dias"/utf8>>])};
                        {error, #{sqlstate := <<"23505">>}} -> {error, <<"já há um pedido de isenção aberto para este achado"/utf8>>};
                        {error, #{sqlstate := <<"23514">>}} -> {error, <<"explique o motivo da isenção (10 caracteres ou mais)"/utf8>>};
                        {error, #{message := M}} -> {error, M}
                    end
            end;
        _ -> {error, <<"programa não encontrado"/utf8>>}
    end;
request_exemption(_, _) -> {error, <<"informe programa, achado (fingerprint), motivo e prazo"/utf8>>}.

-spec decide_exemption(integer(), binary(), binary(), map()) -> {ok, map()} | {error, binary()}.
decide_exemption(Id, Decision, Note, #{username := Who}) when Decision =:= <<"approved">>; Decision =:= <<"refused">> ->
    case ana_db:one("UPDATE ana_system.quality_exemption SET status = $2, decided_by = $3, decided_at = now(), decision = $4 "
                    "WHERE id = $1 AND status = 'requested' RETURNING program, requested_by", [Id, Decision, Who, Note]) of
        {ok, #{<<"program">> := P}} ->
            ana_admin:log(Who, <<"quality.exemption.", Decision/binary>>, P, null, #{id => Id}),
            {ok, #{id => Id, status => Decision}};
        {ok, undefined} -> {error, <<"pedido de isenção não encontrado ou já decidido"/utf8>>};
        {error, #{sqlstate := <<"23514">>}} -> {error, <<"quatro olhos: quem pediu a isenção não pode decidi-la"/utf8>>};
        {error, #{message := M}} -> {error, M}
    end;
decide_exemption(_, _, _, _) -> {error, <<"decisão deve ser approved ou refused"/utf8>>}.

%% ---------------------------------------------------------------- baseline (D3)

%% Takes the current blocking findings of the programs (all, or the named ones) as the baseline.
-spec set_baseline([binary()] | all, map()) -> {ok, map()}.
set_baseline(Which, #{username := Who}) ->
    Names = case Which of
        all -> {ok, R} = ana_db:rows("SELECT name FROM ana_system.program WHERE kind IN ('program', 'library')", []),
               [N || #{<<"name">> := N} <- R];
        L when is_list(L) -> L
    end,
    {ok, #{programs := Ps}} = gate(Names),
    Rows = [[N, maps:get(<<"fingerprint">>, F), maps:get(<<"rule">>, F)] || #{name := N, blocking := B} <- Ps, F <- B],
    lists:foreach(fun([N, F, Ru]) ->
                      {ok, _} = ana_db:exec("INSERT INTO ana_system.quality_baseline (program, fingerprint, rule, created_by) "
                                            "VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING", [N, F, Ru, Who])
                  end, Rows),
    ana_admin:log(Who, <<"quality.baseline">>, <<"programs">>, null, #{programs => length(Names), findings => length(Rows)}),
    {ok, #{programs => length(Names), findings => length(Rows)}}.
