-module(met_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(UA, "agent/1.0 (EmergenceSystem; +https://github.com/EmergenceSystem)").

base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"image">>, <<"images">>, <<"art">>, <<"artwork">>, <<"painting">>, <<"sculpture">>, <<"museum">>, <<"met">>, <<"media">>].

start(_Type, _Args) ->
    case met_filter_sup:start_link() of
        {ok, Pid} -> ok = start_pop_and_http(), {ok, Pid};
        Error -> Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(met_filter_query_listener),
    catch em_pop_sup:stop_node(met_filter),
    ok.

start_pop_and_http() ->
    PopPort   = application:get_env(met_filter, pop_port,   9558),
    QueryPort = application:get_env(met_filter, query_port, 9559),
    Seeds     = application:get_env(met_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(met_filter),
    catch cowboy:stop_listener(met_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(met_filter, #{
        port => PopPort, query_port => QueryPort, vector => Vec,
        max_peers => 100, gossip_interval => 5_000
    }),
    lists:foreach(fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end, Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http, #{server => met_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(met_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[met_filter] gossip port ~w  query port ~w", [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) -> {[], Memory}.

extract_query(Body) ->
    try json:decode(Body) of
        Map when is_map(Map) ->
            binary_to_list(maps:get(<<"value">>, Map, maps:get(<<"query">>, Map, <<"">>)));
        _ -> binary_to_list(Body)
    catch _:_ -> binary_to_list(Body) end.

put_opt(M, _K, null)      -> M;
put_opt(M, _K, <<>>)      -> M;
put_opt(M, K, V) when is_binary(V) -> M#{K => V};
put_opt(M, _K, _)         -> M.

-define(SEARCH_URL, "https://collectionapi.metmuseum.org/public/collection/v1/search?hasImages=true&q=").
-define(OBJ_URL, "https://collectionapi.metmuseum.org/public/collection/v1/objects/").

generate_embryo_list(Body) ->
    case extract_query(Body) of
        "" -> [];
        Query -> fetch_objects(search_ids(?SEARCH_URL ++ uri_string:quote(Query)))
    end.

search_ids(Url) ->
    Headers = [{"User-Agent", ?UA}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, 8000}, {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case catch json:decode(Body) of
                #{<<"objectIDs">> := L} when is_list(L) -> lists:sublist(L, 8);
                _ -> []
            end;
        _ -> []
    end.

fetch_objects([]) -> [];
fetch_objects(Ids) ->
    Parent = self(),
    _ = [spawn(fun() -> Parent ! {obj_result, fetch_one(Id)} end) || Id <- Ids],
    collect(length(Ids), []).

collect(0, Acc) -> lists:reverse(Acc);
collect(N, Acc) ->
    receive
        {obj_result, {ok, E}} -> collect(N - 1, [E | Acc]);
        {obj_result, _}       -> collect(N - 1, Acc)
    after 8000 -> lists:reverse(Acc)
    end.

fetch_one(Id) ->
    Url = ?OBJ_URL ++ integer_to_list(Id),
    Headers = [{"User-Agent", ?UA}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, 4000}, {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case catch json:decode(Body) of
                #{<<"primaryImageSmall">> := Small} = O
                  when is_binary(Small), byte_size(Small) > 0 ->
                    Full = case maps:get(<<"primaryImage">>, O, <<>>) of
                               F when is_binary(F), byte_size(F) > 0 -> F;
                               _ -> Small
                           end,
                    Base = #{
                        <<"media_type">> => <<"image">>,
                        <<"media_url">>  => Full,
                        <<"thumbnail">>  => Small,
                        <<"title">>      => maps:get(<<"title">>, O, <<"Untitled">>),
                        <<"url">>        => maps:get(<<"objectURL">>, O, Full),
                        <<"source">>     => <<"met museum">>
                    },
                    {ok, #{<<"properties">> => put_opt(Base, <<"author">>,
                                                       maps:get(<<"artistDisplayName">>, O, null))}};
                _ -> skip
            end;
        _ -> skip
    end.
