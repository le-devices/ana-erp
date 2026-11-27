%% SPDX-FileCopyrightText: 2026 André Luis Pereira dos Santos
%% SPDX-License-Identifier: AGPL-3.0-or-later
%% Spec 068 (T-068-04, RNF-068-02): a table whose lock is held is tried again with a growing pause, never in a loop.
-module(ana_watch_tests).
-include_lib("eunit/include/eunit.hrl").

rnf_068_02_backoff_grows_and_is_capped_test() ->
    ?assertEqual([1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000],
                 [ana_watch:backoff_ms(N) || N <- [1, 2, 3, 4, 5, 6, 7, 100]]).
