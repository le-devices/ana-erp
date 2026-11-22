%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Seed programs (RF-006-06, RF-006-08).
%%
%% Reads priv/programs/<name>.py with metadata in the header:
%%   # ana:description Creates a sales order
%%   # ana:exposed yes
%%   # ana:menu no            (executable helper, not a routine in the menu)
%%   # ana:command order
%%   # ana:kind program|library
%%   # ana:role user|developer|admin
%%   # ana:portal yes          (external portal accounts may run it, spec 016)
%%   # ana:public yes          (anonymous browsers with a publishable key may call it, spec 010)
%% Only creates what does not exist: never overwrites studio changes.
-module(ana_seeds).
-export([apply/0, files/0, metadata/1, reserved/1]).


apply() ->
    Dir = filename:join(code:priv_dir(ana), "programs"),
    Files = lists:sort(filelib:wildcard(filename:join(Dir, "*.py"))),
    _ = ana_task:run(<<"seed.programs">>, ana_task:system_user(), <<"internal">>, fun() ->
        Created = [N || F <- Files, {created, N} <- [seed(F)]],
        _ = Created =/= [] andalso ok =:= logger:notice("seed programs created: ~p", [length(Created)]),
        {ok, unicode:characters_to_binary(io_lib:format("~b programa(s) criado(s)", [length(Created)]))}
    end),
    _ = ana_task:run(<<"programs.refresh_params">>, ana_task:system_user(), <<"internal">>,
                     fun() -> ana_program:refresh_params() end),
    %% Spec 028: newer product versions of installed programs are offered, never applied.
    _ = ana_task:run(<<"programs.product_updates">>, ana_task:system_user(), <<"internal">>,
                     fun() -> ana_product_updates:check() end),
    _ = ana_task:run(<<"seed.routines">>, ana_task:system_user(), <<"internal">>, fun ensure_routines/0),
    %% Spec 048: the product's blocks of the home panel, once, after their programs exist.
    _ = ana_task:run(<<"seed.home">>, ana_task:system_user(), <<"internal">>, fun ana_home:ensure_product_blocks/0),
    ok.

%% Spec 038 (phase 4): the routines that keep the subsystems reconciled without typing. Created once,
%% inactive (the company turns each one on in Agendamento), never recreated after being deleted or renamed.
%% They run as an administrator because they post and invoice.
routines() ->
    [%% Spec 067 (D6): the usage simulation, every night — turn it on in the test instance (refused in production).
     {<<"uso.simulado">>, <<"simulation.start">>, #{<<"days">> => 1, <<"per_day">> => 12}, <<"0 2 * * *">>,
      <<"Uso simulado: personas percorrem as esteiras inteiras à noite e apontam furos de automação, contas e robustez (só na instância de testes)."/utf8>>},
     {<<"pedidos.liberar">>, <<"sales.release_held">>, #{}, <<"*/10 * * * *">>,
      <<"Pedidos retidos ou aguardando compra/produção: libera os que já têm estoque, do mais antigo para o mais novo (spec 041)."/utf8>>},
     {<<"extratos.buscar">>, <<"finance.fetch_statements">>, #{}, <<"0 7-19 * * 1-5">>,
      <<"Busca de extratos: lê de hora em hora, nos dias úteis, as pastas de arquivos (OFX, CNAB 240) e as APIs dos bancos de cada conta e concilia."/utf8>>},
     {<<"conciliacao.bancaria">>, <<"finance.reconcile_all">>, #{}, <<"0 6 * * *">>,
      <<"Conciliação bancária diária: concilia todas as contas pelos extratos importados e compensa créditos."/utf8>>},
     {<<"compensacao.creditos">>, <<"finance.offset_credits">>, #{}, <<"30 6 * * *">>,
      <<"Compensação de créditos: créditos de clientes e com fornecedores abatem os títulos em aberto do mesmo parceiro."/utf8>>},
     {<<"projetos.mao_de_obra">>, <<"projects.appropriate_labor">>,
      #{<<"month">> => <<"{{last_month_start}}">>, <<"execute">> => true}, <<"0 2 1 * *">>,
      <<"Apropriação de mão de obra: custo das horas aprovadas do mês anterior lançado nos projetos."/utf8>>},
     {<<"rateio.mensal">>, <<"finance.allocate_costs">>,
      #{<<"month">> => <<"{{last_month_start}}">>, <<"execute">> => true}, <<"0 3 1 * *">>,
      <<"Rateio de custos: centros de custo do mês anterior, depois da apropriação de mão de obra."/utf8>>},
     {<<"projetos.faturamento">>, <<"projects.invoice_all">>,
      #{<<"through">> => <<"{{last_month_end}}">>}, <<"0 5 1 * *">>,
      <<"Faturamento mensal de projetos: horas, despesas refaturáveis e marcos concluídos até o fim do mês anterior."/utf8>>},
     {<<"estoque.reposicao">>, <<"supply.suggest_replenishment">>,
      #{<<"create">> => true}, <<"30 5 * * 1-5">>,
      <<"Reposição de estoque: abaixo do ponto de pedido vira solicitação de compra (segue a alçada de aprovação)."/utf8>>},
     {<<"impostos.vigilancia">>, <<"tax.watch">>, #{}, <<"0 6 * * 1-5">>,
      <<"Vigilância fiscal (spec 049): pacote de regras não aplicado, vigência terminando sem regra seguinte, indicador perto do limite (fator R) e regras em conflito."/utf8>>}].

ensure_routines() ->
    case ana_db:one("SELECT username FROM ana_system.app_user WHERE role = 'admin' AND active AND kind <> 'robot' "
                    "ORDER BY username = 'admin' DESC, username LIMIT 1", []) of
        {ok, #{<<"username">> := Admin}} ->
            %% A name that ever existed (still there, renamed or deleted by the company) is never created again.
            {ok, Rows} = ana_db:rows("SELECT name FROM scheduler.job UNION SELECT after->>'name' FROM ana_system.admin_log "
                                     "WHERE action = 'scheduler.job.save' AND after ? 'name'", []),
            Have = [N || #{<<"name">> := N} <- Rows],
            %% The built-in robot creates them; an administrator is the one they run as.
            Creator = (ana_task:system_user())#{role => <<"admin">>},
            Results = [{Name, ana_schedule:save_job(new, #{<<"name">> => Name, <<"description">> => Desc,
                                                           <<"program">> => Program, <<"params">> => Params,
                                                           <<"run_as">> => Admin, <<"active">> => false,
                                                           <<"triggers">> => [#{<<"kind">> => <<"cron">>, <<"cron">> => Cron}]},
                                                    Creator)}
                       || {Name, Program, Params, Cron, Desc} <- routines(), not lists:member(Name, Have)],
            Failed = [{Name, E} || {Name, {error, E}} <- Results],
            _ = Failed =/= [] andalso ok =:= logger:warning("seed routines not created: ~p", [Failed]),
            {ok, unicode:characters_to_binary(io_lib:format("~b rotina(s) criada(s), ~b com erro",
                                                            [length(Results) - length(Failed), length(Failed)]))};
        _ -> {ok, <<"sem administrador ainda: rotinas ficam para a próxima partida"/utf8>>}
    end.

%% Spec 009 (D8, RF-009-09): a new program may not take a namespace of the product (first segment of any
%% product program), unless it is a product program itself.
-spec reserved(binary()) -> boolean().
reserved(Name) ->
    {Names, Spaces} = case persistent_term:get({?MODULE, namespaces}, undefined) of
        undefined ->
            Dir = filename:join(code:priv_dir(ana), "programs"),
            Ns = [list_to_binary(filename:basename(F, ".py")) || F <- filelib:wildcard(filename:join(Dir, "*.py"))],
            V = {Ns, lists:usort([hd(binary:split(N, <<".">>)) || N <- Ns])},
            persistent_term:put({?MODULE, namespaces}, V),
            V;
        V -> V
    end,
    lists:member(hd(binary:split(Name, <<".">>)), Spaces) andalso not lists:member(Name, Names).

%% Seed files: [{Name, Source}].
-spec files() -> [{binary(), binary()}].
files() ->
    Dir = filename:join(code:priv_dir(ana), "programs"),
    [{list_to_binary(filename:basename(F, ".py")), Source}
     || F <- lists:sort(filelib:wildcard(filename:join(Dir, "*.py"))), {ok, Source} <- [file:read_file(F)]].

seed(File) ->
    Name = list_to_binary(filename:basename(File, ".py")),
    case ana_program:get(Name) of
        {ok, undefined} ->
            {ok, Source} = file:read_file(File),
            Meta = metadata(Source),
            Fields = #{<<"source">> => Source,
                       <<"description">> => maps:get(<<"description">>, Meta, <<>>),
                       <<"kind">> => maps:get(<<"kind">>, Meta, <<"program">>),
                       <<"exposed">> => maps:get(<<"exposed">>, Meta, <<"no">>) =:= <<"yes">>,
                       <<"min_role">> => maps:get(<<"role">>, Meta, <<"user">>),
                       <<"in_menu">> => maps:get(<<"menu">>, Meta, <<"yes">>) =/= <<"no">>,
                       <<"portal">> => maps:get(<<"portal">>, Meta, <<"no">>) =:= <<"yes">>,
                       <<"public">> => maps:get(<<"public">>, Meta, <<"no">>) =:= <<"yes">>,
                       <<"comment">> => <<"seed">>},
            case ana_program:save(Name, Fields, ana_task:system_user()) of
                {ok, _} ->
                    _ = case maps:find(<<"command">>, Meta) of
                        {ok, Cmd} ->
                            {ok, _} = ana_program:save_command(Cmd, Name, maps:get(<<"description">>, Meta, <<>>));
                        error -> ok
                    end,
                    {created, Name};
                {error, E} ->
                    logger:error("seed ~s failed: ~0p", [Name, E]),
                    error
            end;
        _ -> exists
    end.

metadata(Source) ->
    Lines = binary:split(Source, <<"\n">>, [global]),
    maps:from_list(
        [{K, string:trim(V)} || L <- Lines,
                                {match, [K, V]} <- [re:run(L, "^#\\s*ana:([a-z_]+)\\s+(.*)$",
                                                           [{capture, all_but_first, binary}, unicode])]]).
