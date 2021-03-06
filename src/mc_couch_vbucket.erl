-module(mc_couch_vbucket).

-export([get_state/2,
         set_vbucket/3,
         handle_delete/2,
         handle_stats/3,
         handle_set_state/3,
         list_vbuckets/1]).

-include("couch_db.hrl").
-include("mc_constants.hrl").

get_state(VBucket, State) ->
    mc_daemon:with_open_db(fun(Db) ->
                                   case mc_couch_kv:get(Db, <<"_local/vbstate">>) of
                                       {ok, _Flags, _Expiration, 0, StateDoc} ->
                                           {J} = mc_couch_kv:json_decode(StateDoc),
                                           proplists:get_value(<<"state">>, J);
                                       not_found ->
                                           "dead"
                                   end
                           end,
                           VBucket, State).

set_vbucket(VBucket, StateName, State) ->
    DbName = mc_daemon:db_name(VBucket, State),
    {ok, Db} = case couch_db:create(DbName, []) of
                   {ok, D} ->
                       {ok, D};
                   _ ->
                       couch_db:open(DbName, [])
               end,
    StateJson = ["{\"state\": \"", StateName, "\"}"],
    mc_couch_kv:set(Db, <<"_local/vbstate">>, 0, 0,
                    StateJson, true),
    couch_db:close(Db),
    {reply, #mc_response{}, processing, State}.

handle_delete(VBucket, State) ->
    DbName = mc_daemon:db_name(VBucket, State),
    couch_server:delete(DbName, []),
    #mc_response{}.

list_vbuckets(State) ->
    {ok, DBs} = couch_server:all_databases(),
    DBPrefix = mc_daemon:db_prefix(State),
    Len = size(DBPrefix),
    lists:filter(fun is_tuple/1,
                 lists:map(fun(DBName) ->
                                   case (catch binary:split(DBName, <<$/>>,
                                                            [{scope, {Len,size(DBName)-Len}}])) of
                                       [DBPrefix, VB] ->
                                           VBStr = binary_to_list(VB),
                                           VBInt = list_to_integer(VBStr),
                                           StatVal = get_state(VBInt, State),
                                           {VBInt, StatVal};
                                       _ -> ignore
                                   end
                           end, DBs)).

handle_stats(Socket, Opaque, State) ->
    lists:foreach(fun({VBInt, V}) ->
                          StatKey = io_lib:format("vb_~p", [VBInt]),
                          mc_connection:respond(Socket, ?STAT, Opaque,
                                                mc_couch_stats:mk_stat(StatKey, V))
                  end, list_vbuckets(State)),
    mc_connection:respond(Socket, ?STAT, Opaque,
                          mc_couch_stats:mk_stat("", "")).

handle_set_state(VBucket, ?VB_STATE_ACTIVE, State) ->
    set_vbucket(VBucket, "active", State);
handle_set_state(VBucket, ?VB_STATE_REPLICA, State) ->
    set_vbucket(VBucket, "replica", State);
handle_set_state(VBucket, ?VB_STATE_PENDING, State) ->
    set_vbucket(VBucket, "pending", State);
handle_set_state(VBucket, ?VB_STATE_DEAD, State) ->
    set_vbucket(VBucket, "dead", State).

