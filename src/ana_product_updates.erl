%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Product program updates offered to existing installations (spec 028).
%%
%% Seeds never overwrite an installed program. Each program records the hash of
%% the seed it is based on (seed_hash); when the product ships a different seed,
%% an update is offered and an administrator accepts or dismisses it.
-module(ana_product_updates).
-export([check/0, decide/4, hash/1, list/0, detail/1, accept/3, accept_unmodified/1, dismiss/2,
         pending_count/0]).

-define(COMMENT, <<"atualização do produto"/utf8>>).

-spec hash(binary()) -> binary().
hash(Source) -> binary:encode_hex(crypto:hash(sha256, Source), lowercase).

%% Pure decision (RF-028-02/03). Current/Base/Seed are hashes (Base may be null);
%% Offer is undefined or {Status, OfferedHash}.
-spec decide(binary(), binary() | null, binary(), undefined | {binary(), binary()}) ->
          in_sync | customized | keep | {offer, boolean()}.
decide(Seed, _Base, Seed, _Offer) -> in_sync;
decide(_Current, Seed, Seed, _Offer) -> customized;
decide(_Current, _Base, Seed, {<<"dismissed">>, Seed}) -> keep;
decide(Current, Base, _Seed, _Offer) -> {offer, Current =/= Base}.

%% Compares every seed with the installed program; writes only what changed (P15).
-spec check() -> {ok, map()}.
check() ->
    Seeds = maps:from_list(ana_seeds:files()),
    {ok, Rows} = ana_db:rows(
        "SELECT p.name, p.source, p.seed_hash, u.status, u.seed_hash AS offer_hash, u.locally_modified "
        "FROM ana_system.program p LEFT JOIN ana_system.product_update u ON u.name = p.name "
        "WHERE p.name = ANY($1::text[])", [maps:keys(Seeds)]),
    Results = [apply_decision(R, maps:get(N, Seeds)) || R = #{<<"name">> := N} <- Rows],
    Offered = length([x || offered <- Results]),
    _ = Offered > 0 andalso ok =:= logger:notice("product updates available: ~b", [Offered]),
    {ok, #{checked => length(Rows), offered => Offered, available => pending_count()}}.

apply_decision(#{<<"name">> := Name, <<"source">> := Source, <<"seed_hash">> := Base, <<"status">> := Status,
                 <<"offer_hash">> := OfferHash, <<"locally_modified">> := Mod0}, SeedSource) ->
    Seed = hash(SeedSource),
    Offer = case Status of null -> undefined; _ -> {Status, OfferHash} end,
    case decide(hash(Source), Base, Seed, Offer) of
        in_sync ->
            _ = ana_db:exec("UPDATE ana_system.program SET seed_hash = $2 WHERE name = $1 "
                            "AND seed_hash IS DISTINCT FROM $2", [Name, Seed]),
            drop_pending(Name);
        customized -> drop_pending(Name);
        keep -> unchanged;
        {offer, Mod} when Status =:= <<"available">>, OfferHash =:= Seed, Mod =:= Mod0 -> unchanged;
        {offer, Mod} ->
            {ok, _} = ana_db:exec(
                "INSERT INTO ana_system.product_update (name, seed_source, seed_hash, base_hash, locally_modified) "
                "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (name) DO UPDATE SET seed_source = EXCLUDED.seed_source, "
                "  seed_hash = EXCLUDED.seed_hash, base_hash = EXCLUDED.base_hash, "
                "  locally_modified = EXCLUDED.locally_modified, status = 'available', "
                "  detected_at = CASE WHEN product_update.seed_hash = EXCLUDED.seed_hash "
                "                     THEN product_update.detected_at ELSE now() END, "
                "  decided_at = NULL, decided_by = NULL",
                [Name, SeedSource, Seed, Base, Mod]),
            offered
    end.

%% Based on the current seed again: a pending offer or a dismissal no longer applies
%% (accepted rows stay as history).
drop_pending(Name) ->
    _ = ana_db:exec("DELETE FROM ana_system.product_update WHERE name = $1 AND status IN ('available', 'dismissed')",
                    [Name]),
    unchanged.

-spec pending_count() -> non_neg_integer().
pending_count() ->
    case ana_db:one("SELECT count(*) AS n FROM ana_system.product_update WHERE status = 'available'", []) of
        {ok, #{<<"n">> := N}} -> N;
        _ -> 0
    end.

list() ->
    ana_db:rows("SELECT u.name, p.kind, p.description, p.version, u.status, u.locally_modified, u.detected_at, "
                "  u.decided_at, u.decided_by FROM ana_system.product_update u "
                "JOIN ana_system.program p ON p.name = u.name "
                "ORDER BY u.status <> 'available', u.locally_modified, u.name", []).

%% Installed, product and base sources for the side-by-side comparison.
detail(Name) ->
    case ana_db:one(
        "SELECT u.name, u.status, u.locally_modified, u.detected_at, u.seed_source, p.source AS installed, "
        "  p.version, p.kind, (SELECT v.source FROM ana_system.program_version v WHERE v.name = u.name "
        "   AND u.base_hash IS NOT NULL AND encode(sha256(convert_to(v.source, 'UTF8')), 'hex') = u.base_hash "
        "   ORDER BY v.version DESC LIMIT 1) AS base "
        "FROM ana_system.product_update u JOIN ana_system.program p ON p.name = u.name WHERE u.name = $1", [Name]) of
        {ok, undefined} -> {error, not_found};
        Other -> Other
    end.

%% RF-028-04. The local-modification check is redone now (the program may have
%% changed since the offer); optimistic control against a concurrent edit.
accept(Name, Overwrite, User = #{username := Who}) ->
    case ana_db:one(
        "SELECT u.seed_source, u.seed_hash, p.source, p.seed_hash AS base, p.version FROM ana_system.product_update u "
        "JOIN ana_system.program p ON p.name = u.name WHERE u.name = $1 AND u.status = 'available'", [Name]) of
        {ok, undefined} -> {error, not_found};
        {ok, #{<<"seed_source">> := SeedSource, <<"seed_hash">> := Seed, <<"source">> := Source,
               <<"base">> := Base, <<"version">> := V}} ->
            case hash(Source) =/= Base andalso Overwrite =/= true of
                true ->
                    {error, #{code => <<"LOCALLY_MODIFIED">>,
                              message => <<"o programa foi alterado nesta instalação; confirme para sobrescrever "
                                           "(a versão atual fica no histórico)"/utf8>>}};
                false ->
                    Meta = ana_seeds:metadata(SeedSource),
                    Fields = #{<<"source">> => SeedSource, <<"comment">> => ?COMMENT, <<"base_version">> => V,
                               <<"description">> => maps:get(<<"description">>, Meta, null)},
                    case ana_program:save(Name, Fields, User) of
                        {ok, R} ->
                            {ok, _} = ana_db:exec("UPDATE ana_system.program SET seed_hash = $2 WHERE name = $1",
                                                  [Name, Seed]),
                            {ok, _} = ana_db:exec("UPDATE ana_system.product_update SET status = 'accepted', "
                                                  "decided_at = now(), decided_by = $2 WHERE name = $1", [Name, Who]),
                            ok = ana_admin:log(Who, <<"product_update.accept">>, Name,
                                               #{version => V, modified => hash(Source) =/= Base},
                                               #{version => maps:get(version, R, null), seed_hash => Seed}),
                            {ok, #{name => Name, version => maps:get(version, R, null)}};
                        {error, {conflict, _}} ->
                            {error, #{code => <<"CONFLICT">>,
                                      message => <<"o programa mudou agora há pouco; abra de novo e confira"/utf8>>}};
                        {error, E} ->
                            {error, #{code => <<"SAVE_FAILED">>,
                                      message => unicode:characters_to_binary(io_lib:format("~0p", [E]))}}
                    end
            end;
        Error -> Error
    end.

%% RF-028-05: every available update whose program was not changed here.
accept_unmodified(User) ->
    {ok, Rows} = ana_db:rows(
        "SELECT u.name FROM ana_system.product_update u JOIN ana_system.program p ON p.name = u.name "
        "WHERE u.status = 'available' AND p.seed_hash IS NOT NULL "
        "  AND encode(sha256(convert_to(p.source, 'UTF8')), 'hex') = p.seed_hash ORDER BY u.name", []),
    Results = [{N, accept(N, false, User)} || #{<<"name">> := N} <- Rows],
    {ok, #{accepted => [N || {N, {ok, _}} <- Results],
           failed => [#{name => N, error => E} || {N, {error, E}} <- Results]}}.

dismiss(Name, #{username := Who}) ->
    case ana_db:exec("UPDATE ana_system.product_update SET status = 'dismissed', decided_at = now(), decided_by = $2 "
                     "WHERE name = $1 AND status = 'available'", [Name, Who]) of
        {ok, 0} -> {error, not_found};
        {ok, _} ->
            ok = ana_admin:log(Who, <<"product_update.dismiss">>, Name, null, null),
            {ok, #{name => Name, status => <<"dismissed">>}}
    end.
