-module(syn_ffi).
-export([
    to_result/1
]).

-type result() :: ok | {error, term()}.

-spec to_result(result()) -> {ok, nil} | {error, term()}.
to_result(ok) ->
    {ok, nil};

to_result({error, E}) ->
    {error, E}.
