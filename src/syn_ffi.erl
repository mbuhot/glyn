-module(syn_ffi).
-export([
    to_result/1
]).

-type result() :: ok | {error, term()}.

to_result(ok) ->
    {ok, nil};

to_result({error, E}) ->
    {error, E}.
