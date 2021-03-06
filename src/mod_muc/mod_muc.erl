%%%----------------------------------------------------------------------
%%% File    : mod_muc.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : MUC support (JEP-0045)
%%% Created : 19 Mar 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2009   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_muc).
-author('alexey@process-one.net').

-behaviour(gen_server).
-behaviour(gen_mod).

%% API
-export([start_link/2,
	 start/2,
	 stop/1,
	 room_destroyed/4,
	 store_room/3,
	 restore_room/2,
	 forget_room/2,
	 create_room/5,
	 process_iq_disco_items/4,
	 can_use_nick/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("exmpp/include/exmpp.hrl").

-include("ejabberd.hrl").
-include("jlib.hrl").


-record(muc_room, {name_host, opts}).
-record(muc_online_room, {name_host, pid}).
-record(muc_registered, {us_host, nick}).

-record(state, {host,
		server_host,
		access,
		history_size,
		default_room_opts,
		room_shaper}).

-define(PROCNAME, ejabberd_mod_muc).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    start_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec =
	{Proc,
	 {?MODULE, start_link, [Host, Opts]},
	 temporary,
	 1000,
	 worker,
	 [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    stop_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:delete_child(ejabberd_sup, Proc).

%% This function is called by a room in three situations:
%% A) The owner of the room destroyed it
%% B) The only participant of a temporary room leaves it
%% C) mod_muc:stop was called, and each room is being terminated
%%    In this case, the mod_muc process died before the room processes
%%    So the message sending must be catched
room_destroyed(Host, Room, Pid, ServerHost) when is_binary(Host), 
                                                 is_binary(Room) ->
    catch gen_mod:get_module_proc(ServerHost, ?PROCNAME) !
	{room_destroyed, {Room, Host}, Pid},
    ok.

%% @doc Create a room.
%% If Opts = default, the default room options are used.
%% Else use the passed options as defined in mod_muc_room.
create_room(Host, Name, From, Nick, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, {create, Name, From, Nick, Opts}).

store_room(Host, Name, Opts) when is_binary(Host), is_binary(Name) ->
    F = fun() ->
		mnesia:write(#muc_room{name_host = {Name, Host},
				       opts = Opts})
	end,
    mnesia:transaction(F).

restore_room(Host, Name) when is_binary(Host), is_binary(Name) ->
    case catch mnesia:dirty_read(muc_room, {Name, Host}) of
	[#muc_room{opts = Opts}] ->
	    Opts;
	_ ->
	    error
    end.

forget_room(Host, Name) when is_binary(Host), is_binary(Name) ->
    F = fun() ->
		mnesia:delete({muc_room, {Name, Host}})
	end,
    mnesia:transaction(F).

process_iq_disco_items(Host, From, To, #iq{lang = Lang} = IQ) when is_binary(Host) ->
    Rsm = jlib:rsm_decode(IQ),
    Res = exmpp_iq:result(IQ, #xmlel{ns = ?NS_DISCO_ITEMS, 
                               name = 'query',
                               children = iq_disco_items(Host, From, Lang, Rsm)}),
    ejabberd_router:route(To,
			  From,
			  exmpp_iq:iq_to_xmlel(Res)).

can_use_nick(_Host, _JID, <<>>)  ->
    false;
can_use_nick(Host, JID, Nick) when is_binary(Host), is_binary(Nick) ->
    LUS = {exmpp_jid:prep_node(JID), exmpp_jid:prep_domain(JID)},
    case catch mnesia:dirty_select(
		 muc_registered,
		 [{#muc_registered{us_host = '$1',
				   nick = Nick,
				   _ = '_'},
		   [{'==', {element, 2, '$1'}, Host}],
		   ['$_']}]) of
	{'EXIT', _Reason} ->
	    true;
	[] ->
	    true;
	[#muc_registered{us_host = {U, _Host}}] ->
	    U == LUS
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, Opts]) ->
    mnesia:create_table(muc_room,
			[{disc_copies, [node()]},
			 {attributes, record_info(fields, muc_room)}]),
    mnesia:create_table(muc_registered,
			[{disc_copies, [node()]},
			 {attributes, record_info(fields, muc_registered)}]),
    mnesia:create_table(muc_online_room,
			[{ram_copies, [node()]},
			 {attributes, record_info(fields, muc_online_room)}]),
    mnesia:add_table_copy(muc_online_room, node(), ram_copies),
    catch ets:new(muc_online_users, [bag, named_table, public, {keypos, 2}]),
    MyHost_L = gen_mod:get_opt_host(Host, Opts, "conference.@HOST@"),
    MyHost = list_to_binary(MyHost_L),
    update_tables(MyHost),
    clean_table_from_bad_node(node(), MyHost),
    mnesia:add_table_index(muc_registered, nick),
    mnesia:subscribe(system),
    Access = gen_mod:get_opt(access, Opts, all),
    AccessCreate = gen_mod:get_opt(access_create, Opts, all),
    AccessAdmin = gen_mod:get_opt(access_admin, Opts, none),
    AccessPersistent = gen_mod:get_opt(access_persistent, Opts, all),
    HistorySize = gen_mod:get_opt(history_size, Opts, 20),
    DefRoomOpts = gen_mod:get_opt(default_room_options, Opts, []),
    RoomShaper = gen_mod:get_opt(room_shaper, Opts, none),
    ejabberd_router:register_route(MyHost_L),
    load_permanent_rooms(MyHost, Host,
			 {Access, AccessCreate, AccessAdmin, AccessPersistent},
			 HistorySize,
			 RoomShaper),
    {ok, #state{host = MyHost,
		server_host = Host,
		access = {Access, AccessCreate, AccessAdmin, AccessPersistent},
		default_room_opts = DefRoomOpts,
		history_size = HistorySize,
		room_shaper = RoomShaper}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call({create, Room, From, Nick, Opts},
	    _From,
	    #state{host = Host,
		   server_host = ServerHost,
		   access = Access,
		   default_room_opts = DefOpts,
		   history_size = HistorySize,
		   room_shaper = RoomShaper} = State) ->
    ?DEBUG("MUC: create new room '~s'~n", [Room]),
    NewOpts = case Opts of
		  default -> DefOpts;
		  _ -> Opts
	      end,
    {ok, Pid} = mod_muc_room:start(
		  Host, ServerHost, Access,
		  Room, HistorySize,
		  RoomShaper, From,
		  Nick, NewOpts),
    register_room(Host, Room, Pid),
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({route, From, To, Packet},
	    #state{host = Host,
		   server_host = ServerHost,
		   access = Access,
 		   default_room_opts = DefRoomOpts,
		   history_size = HistorySize,
		   room_shaper = RoomShaper} = State) ->
    case catch do_route(Host, ServerHost, Access, HistorySize, RoomShaper,
			From, To, Packet, DefRoomOpts) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p", [Reason]);
	_ ->
	    ok
    end,
    {noreply, State};
handle_info({room_destroyed, RoomHost, Pid}, State) ->
    F = fun() ->
		mnesia:delete_object(#muc_online_room{name_host = RoomHost,
						      pid = Pid})
	end,
    mnesia:transaction(F),
    {noreply, State};
handle_info({mnesia_system_event, {mnesia_down, Node}}, State) ->
    clean_table_from_bad_node(Node),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    ejabberd_router:unregister_route(binary_to_list(State#state.host)),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
start_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host, ejabberd_mod_muc_sup),
    ChildSpec =
	{Proc,
	 {ejabberd_tmp_sup, start_link,
	  [Proc, mod_muc_room]},
	 permanent,
	 infinity,
	 supervisor,
	 [ejabberd_tmp_sup]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host, ejabberd_mod_muc_sup),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

do_route(Host, ServerHost, Access, HistorySize, RoomShaper,
	 From, To, Packet, DefRoomOpts) ->
    {AccessRoute, _AccessCreate, _AccessAdmin, _AccessPersistent} = Access,
    case acl:match_rule(ServerHost, AccessRoute, From) of
	allow ->
	    do_route1(Host, ServerHost, Access, HistorySize, RoomShaper,
		      From, To, Packet, DefRoomOpts);
	_ ->
        Lang = exmpp_stanza:get_lang(Packet),
        ErrText = "Access denied by service policy",
        Err = exmpp_iq:error(Packet,exmpp_stanza:error(Packet#xmlel.ns,
                                                       'forbidden',
                                                       {Lang,ErrText})),
	    ejabberd_router:route(To, From, Err)
    end.


do_route1(Host, ServerHost, Access, HistorySize, RoomShaper,
	  From, To, Packet, DefRoomOpts) ->
    {_AccessRoute, AccessCreate, AccessAdmin, _AccessPersistent} = Access,
    Room = exmpp_jid:prep_node(To),
    Nick = exmpp_jid:prep_resource(To),
    #xmlel{name = Name} = Packet,
    case Room of
	'undefined' ->
	    case Nick of
		'undefined' ->
		    case Name of
			'iq' ->
			    case exmpp_iq:xmlel_to_iq(Packet) of
				#iq{type = get, ns = ?NS_DISCO_INFO = XMLNS,
 				    payload = _SubEl, lang = Lang} = IQ ->
		    ServerHostB = list_to_binary(ServerHost),
		    Info = ejabberd_hooks:run_fold(
			     disco_info, ServerHostB, [],
			     [ServerHost, ?MODULE, <<>>, ""]),
                    ResPayload = #xmlel{ns = XMLNS, name = 'query',
                                        children = iq_disco_info(Lang)++Info},
                    Res = exmpp_iq:result(IQ, ResPayload),
				    ejabberd_router:route(To,
							  From,
							  exmpp_iq:iq_to_xmlel(Res));
				#iq{type = get,
				    ns = ?NS_DISCO_ITEMS} = IQ ->
				    spawn(?MODULE,
					  process_iq_disco_items,
					  [Host, From, To, IQ]);
				#iq{type = get,
				    ns = ?NS_INBAND_REGISTER = XMLNS,
				    lang = Lang} = IQ ->
                    ResPayload = #xmlel{ns = XMLNS, name = 'query',
                                        children = iq_get_register_info(Host, 
                                                                    From,
                                                                    Lang)},
                    Res = exmpp_iq:result(IQ,ResPayload),
				    ejabberd_router:route(To,
							  From,
							  exmpp_iq:iq_to_xmlel(Res));
				#iq{type = set,
				    ns = ?NS_INBAND_REGISTER ,
				    lang = Lang,
				    payload = SubEl} = IQ ->
				    case process_iq_register_set(Host, From, SubEl, Lang) of
					ok ->
                        Res = exmpp_iq:result(IQ),
					    ejabberd_router:route(
					      To, From, exmpp_iq:iq_to_xmlel(Res));
					{error, Error} ->
					    Err = exmpp_iq:error(IQ,Error),
					    ejabberd_router:route(
					      To, From, exmpp_iq:iq_to_xmlel(Err))
				    end;
				#iq{type = get,
				    ns = ?NS_VCARD,
				    lang = Lang} = IQ ->
                    Res = exmpp_iq:result(IQ,iq_get_vcard(Lang)),
				    ejabberd_router:route(To,
							  From,
							  exmpp_iq:iq_to_xmlel(Res));
				#iq{type = get,
				   ns = ?NS_MUC_UNIQUE} = IQ ->
				   Res = exmpp_iq:result(IQ, iq_get_unique_el(From)),
				   ejabberd_router:route(To,
				   			 From,
							  exmpp_iq:iq_to_xmlel(Res));
				#iq{} = IQ ->
                    Err = exmpp_iq:error(IQ,'feature-not-implemented'),
				    ejabberd_router:route(To, From, Err);
				_ ->
				    ok
			    end;
			'message' ->
			    case exmpp_xml:get_attribute_as_list(Packet,type, "chat") of
				"error" ->
				    ok;
				_ ->
				    case acl:match_rule(ServerHost, AccessAdmin, From) of
					allow ->
					    Msg = exmpp_xml:get_path(Packet, 
                                                 [{element,'body'},cdata]),
					    broadcast_service_message(Host, Msg);
					_ ->
					    Lang = exmpp_stanza:get_lang(Packet),
					    ErrText = "Only service administrators "
						      "are allowed to send service messages",
                        Err = exmpp_iq:error(Packet,exmpp_stanza:error(Packet#xmlel.ns,
                                                       'forbidden',
                                                       {Lang,ErrText})),
					    ejabberd_router:route(
					      To, From, Err)
				    end
			    end;
			'presence' ->
			    ok
		    end;
		_ ->
		    case exmpp_stanza:get_type(Packet) of
			<<"error">> ->
			    ok;
			<<"result">> ->
			    ok;
			_ ->
			    Err = exmpp_iq:error(Packet,'item-not-found'),
			    ejabberd_router:route(To, From, Err)
		    end
	    end;
	_ ->
	    case mnesia:dirty_read(muc_online_room, {Room, Host}) of
		[] ->
		    Type = exmpp_stanza:get_type(Packet),
		    case {Name, Type} of
			{'presence', 'undefined'} ->
			    case check_user_can_create_room(ServerHost,
							    AccessCreate, From,
							    Room) of
				true ->
				    {ok, Pid} = start_new_room(
						  Host, ServerHost, Access,
						  Room, HistorySize,
						  RoomShaper, From,
						  Nick, DefRoomOpts),
				    register_room(Host, Room, Pid),
				    mod_muc_room:route(Pid, From, Nick, Packet),
				    ok;
				false ->
				    Lang = exmpp_stanza:get_lang(Packet),
				    ErrText = "Room creation is denied by service policy",
                                    Err = exmpp_stanza:reply_with_error(Packet,exmpp_stanza:error(Packet#xmlel.ns,
                                                       'forbidden',
                                                       {Lang,ErrText})),
				    ejabberd_router:route(To, From, Err)
			    end;
			_ ->
                Lang = exmpp_stanza:get_lang(Packet),
			    ErrText = "Conference room does not exist",
                Err = exmpp_stanza:reply_with_error(Packet,
                                        exmpp_stanza:error(Packet#xmlel.ns,
                                                          'item-not-found',
                                                           {Lang,ErrText})),
			    ejabberd_router:route(To, From, Err)
		    end;
		[R] ->
		    Pid = R#muc_online_room.pid,
		    ?DEBUG("MUC: send to process ~p~n", [Pid]),
		    mod_muc_room:route(Pid, From, Nick, Packet),
		    ok
	    end
    end.

check_user_can_create_room(ServerHost, AccessCreate, From, RoomID) ->
    case acl:match_rule(ServerHost, AccessCreate, From) of
	allow ->
	    (size(RoomID) =< gen_mod:get_module_opt(ServerHost, mod_muc,
						      max_room_id, infinite));
	_ ->
	    false
    end.


load_permanent_rooms(Host, ServerHost, Access, HistorySize, RoomShaper) ->
    case catch mnesia:dirty_select(
		 muc_room, [{#muc_room{name_host = {'_', Host}, _ = '_'},
			     [],
			     ['$_']}]) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p", [Reason]),
	    ok;
	Rs ->
	    lists:foreach(
	      fun(R) ->
		      {Room, Host} = R#muc_room.name_host,
		      case mnesia:dirty_read(muc_online_room, {Room, Host}) of
			  [] ->
			      {ok, Pid} = mod_muc_room:start(
					    Host,
					    ServerHost,
					    Access,
					    Room,
					    HistorySize,
					    RoomShaper,
					    R#muc_room.opts),
			      register_room(Host, Room, Pid);
			  _ ->
			      ok
		      end
	      end, Rs)
    end.

start_new_room(Host, ServerHost, Access, Room,
	       HistorySize, RoomShaper, From,
	       Nick, DefRoomOpts) ->
    case mnesia:dirty_read(muc_room, {Room, Host}) of
	[] ->
	    ?DEBUG("MUC: open new room '~s'~n", [Room]),
	    mod_muc_room:start(Host, ServerHost, Access,
			       Room, HistorySize,
			       RoomShaper, From,
			       Nick, DefRoomOpts);
	[#muc_room{opts = Opts}|_] ->
	    ?DEBUG("MUC: restore room '~s'~n", [Room]),
	    mod_muc_room:start(Host, ServerHost, Access,
			       Room, HistorySize,
			       RoomShaper, Opts)
    end.

register_room(Host, Room, Pid) when is_binary(Host), is_binary(Room) ->
    F = fun() ->
		mnesia:write(#muc_online_room{name_host = {Room, Host},
					      pid = Pid})
	end,
    mnesia:transaction(F).


iq_disco_info(Lang) ->
    [#xmlel{ns = ?NS_DISCO_INFO, name = 'identity',
           attrs = [?XMLATTR('category', 
                             <<"conference">>),
                    ?XMLATTR('type', 
                             <<"text">>),
                    ?XMLATTR('name', 
                             translate:translate(Lang, "Chatrooms"))]},
     #xmlel{ns = ?NS_DISCO_INFO, name = 'feature', attrs = 
                              [?XMLATTR('var', 
                                       ?NS_DISCO_INFO_s)]},
     #xmlel{ns = ?NS_DISCO_INFO, name = 'feature', attrs = 
                              [?XMLATTR('var', 
                                       ?NS_DISCO_ITEMS_s)]},
     #xmlel{ns = ?NS_DISCO_INFO, name = 'feature', attrs = 
                              [?XMLATTR('var', 
                                       ?NS_MUC_s)]},
     #xmlel{ns = ?NS_DISCO_INFO, name = 'feature', attrs = 
                              [?XMLATTR('var', 
                                       ?NS_MUC_UNIQUE_s)]},
     #xmlel{ns = ?NS_DISCO_INFO, name = 'feature', attrs = 
                              [?XMLATTR('var', 
                                        ?NS_INBAND_REGISTER_s)]},
     #xmlel{ns = ?NS_DISCO_INFO, name = 'feature', attrs = 
                              [?XMLATTR('var', 
                                        ?NS_RSM_s)]},
     #xmlel{ns = ?NS_DISCO_INFO, name = 'feature', attrs = 
                              [?XMLATTR('var', 
                                        ?NS_VCARD_s)]}].


iq_disco_items(Host, From, Lang, none) when is_binary(Host) ->
    lists:zf(fun(#muc_online_room{name_host = {Name, _Host}, pid = Pid}) ->
		     case catch gen_fsm:sync_send_all_state_event(
				  Pid, {get_disco_item, From, Lang}, 100) of
			 {item, Desc} ->
			     flush(),
			     {true,
                  #xmlel{name = 'item',
                         attrs = [?XMLATTR('jid', 
                                          exmpp_jid:to_binary(Name,
                                                                        Host)),
                                 ?XMLATTR('name',
                                          Desc)]}};
			 _ ->
			     false
		     end
	     end, get_vh_rooms(Host));

iq_disco_items(Host, From, Lang, Rsm) ->
    {Rooms, RsmO} = get_vh_rooms(Host, Rsm),
    RsmOut = jlib:rsm_encode(RsmO),
    lists:zf(fun(#muc_online_room{name_host = {Name, _Host}, pid = Pid}) ->
		     case catch gen_fsm:sync_send_all_state_event(
				  Pid, {get_disco_item, From, Lang}, 100) of
			 {item, Desc} ->
			     flush(),
			     {true,
			      {xmlelement, "item",
			       [{"jid", jlib:jid_to_string({Name, Host, ""})},
				{"name", Desc}], []}};
			 _ ->
			     false
		     end
	     end, Rooms) ++ RsmOut.

get_vh_rooms(Host, #rsm_in{max=M, direction=Direction, id=I, index=Index})->
    AllRooms = lists:sort(get_vh_rooms(Host)),
    Count = erlang:length(AllRooms),
    Guard = case Direction of
		_ when Index =/= undefined -> [{'==', {element, 2, '$1'}, Host}];
		aft -> [{'==', {element, 2, '$1'}, Host}, {'>=',{element, 1, '$1'} ,I}];
		before when I =/= []-> [{'==', {element, 2, '$1'}, Host}, {'=<',{element, 1, '$1'} ,I}];
		_ -> [{'==', {element, 2, '$1'}, Host}]
	    end,
    L = lists:sort(
	  mnesia:dirty_select(muc_online_room,
			      [{#muc_online_room{name_host = '$1', _ = '_'},
				Guard,
				['$_']}])),
    L2 = if
	     Index == undefined andalso Direction == before ->
		 lists:reverse(lists:sublist(lists:reverse(L), 1, M));
	     Index == undefined ->
		 lists:sublist(L, 1, M);
	     Index > Count  orelse Index < 0 ->
		 [];
	     true ->
		 lists:sublist(L, Index+1, M)
	 end,
    if
	L2 == [] ->
	    {L2, #rsm_out{count=Count}};
	true ->
	    H = hd(L2),
	    NewIndex = get_room_pos(H, AllRooms),
	    T=lists:last(L2),
	    {F, _}=H#muc_online_room.name_host,
	    {Last, _}=T#muc_online_room.name_host,
	    {L2, #rsm_out{first=F, last=Last, count=Count, index=NewIndex}}
    end.

%% @doc Return the position of desired room in the list of rooms.
%% The room must exist in the list. The count starts in 0.
%% @spec (Desired::muc_online_room(), Rooms::[muc_online_room()]) -> integer()
get_room_pos(Desired, Rooms) ->
    get_room_pos(Desired, Rooms, 0).
get_room_pos(Desired, [HeadRoom | _], HeadPosition)
  when (Desired#muc_online_room.name_host ==
	HeadRoom#muc_online_room.name_host) ->
    HeadPosition;
get_room_pos(Desired, [_ | Rooms], HeadPosition) ->
    get_room_pos(Desired, Rooms, HeadPosition + 1).

flush() ->
    receive
	_ ->
	    flush()
    after 0 ->
	    ok
    end.

-define(XFIELD(Type, Label, Var, Val),
	#xmlel{name = "field",
          attrs = [?XMLATTR('type', Type),
			       ?XMLATTR('label', 
                            translate:translate(Lang, Label)),
			       ?XMLATTR('var', Var)],
          children = [#xmlel{name = 'value',
                             children = [#xmlcdata{cdata = Val}]}]}).

iq_get_register_info(Host, From, Lang)  ->
    LUser = exmpp_jid:prep_node(From),
    LServer = exmpp_jid:prep_domain(From),
    LUS = {LUser, LServer},
    {Nick, Registered} =
	case catch mnesia:dirty_read(muc_registered, {LUS, Host}) of
	    {'EXIT', _Reason} ->
		{"", []};
	    [] ->
		{"", []};
	    [#muc_registered{nick = N}] ->
		{N, [#xmlel{name = 'registered'}]}
	end,
    Registered ++
    [#xmlel{name = 'instructions' ,
        children = [#xmlcdata{cdata = 
              	    translate:translate(Lang,
	            "You need an x:data capable client to register nickname")}]},
    #xmlel{ns = ?NS_DATA_FORMS, name = 'x',
        children = [
            #xmlel{ns = ?NS_DATA_FORMS, name = 'title',
                        children = [#xmlcdata{cdata = 
	       [translate:translate(Lang, "Nickname Registration at "), Host]}]},
           #xmlel{ns = ?NS_DATA_FORMS, name = 'instructions',
                 children = [#xmlcdata{cdata = 
	       translate:translate(Lang, "Enter nickname you want to register")}]},
	   ?XFIELD(<<"text-single">>, "Nickname", <<"nick">>, Nick)]}].



iq_set_register_info(Host, From, Nick, Lang) when is_binary(Host), is_binary(Nick) ->
    LUser = exmpp_jid:prep_node(From),
    LServer = exmpp_jid:prep_domain(From),
    LUS = {LUser, LServer},
    F = fun() ->
		case Nick of
		    <<>> ->
			mnesia:delete({muc_registered, {LUS, Host}}),
			ok;
		    _ ->
			Allow =
			    case mnesia:select(
				   muc_registered,
				   [{#muc_registered{us_host = '$1',
						     nick = Nick,
						     _ = '_'},
				     [{'==', {element, 2, '$1'}, Host}],
				     ['$_']}]) of
				[] ->
				    true;
				[#muc_registered{us_host = {U, _Host}}] ->
				    U == LUS
			    end,
			if
			    Allow ->
				mnesia:write(
				  #muc_registered{us_host = {LUS, Host},
						  nick = Nick}),
				ok;
			    true ->
				false
			end
		end
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    ok;
	{atomic, false} ->
	    ErrText = "That nickname is registered by another person",
        %%TODO: Always in the jabber:client namespace?
	    {error,exmpp_stanza:error(?NS_JABBER_CLIENT, 
                                  'conflict', 
                                  {Lang, ErrText})};
	_ ->
	    {error, 'internal-server-error'}
    end.

process_iq_register_set(Host, From, SubEl, Lang) ->
%    {xmlelement, _Name, _Attrs, Els} = SubEl,
    case exmpp_xml:get_element(SubEl,'remove') of
	undefined ->
	    case exmpp_xml:get_child_elements(SubEl) of
		[#xmlel{ns= NS, name = 'x'} = XEl] ->
		    case {NS, exmpp_stanza:get_type(XEl)} of
            {?NS_DATA_FORMS, <<"cancel">>} ->
			    ok;
			{?NS_DATA_FORMS, <<"submit">>} ->
			    XData = jlib:parse_xdata_submit(XEl),
			    case XData of
				invalid ->
				    {error, 'bad-request'};
				_ ->
				    case lists:keysearch("nick", 1, XData) of
					{value, {_, [Nick]}} ->
					    iq_set_register_info(Host, From, list_to_binary(Nick), Lang);
					_ ->
					    ErrText = "You must fill in field \"Nickname\" in the form",
                        Err = exmpp_stanza:error(SubEl#xmlel.ns, 
                                   'not-acceptable', 
                                   {Lang, translate:translate(Lang,ErrText)}),
					    {error, Err}
				    end
			    end;
			_ ->
			    {error, 'bad-request'}
		    end;
		_ ->
		    {error, 'bad-request'}
	    end;
	_ ->
	    iq_set_register_info(Host, From, <<>>, Lang)
    end.

iq_get_vcard(Lang) ->
    #xmlel{ns = ?NS_VCARD, name = 'vCard',
           children =
        [#xmlel{ns = ?NS_VCARD, name = 'FN',
            children = [#xmlcdata{cdata = <<"ejabberd/mod_muc">>}]},
         #xmlel{ns = ?NS_VCARD, name = 'URL',
            children = [#xmlcdata{cdata = ?EJABBERD_URI}]},
         #xmlel{ns = ?NS_VCARD, name = 'DESC',
            children = [#xmlcdata{cdata = 
                    translate:translate(Lang, "ejabberd MUC module") ++
                	  "\nCopyright (c) 2003-2009 Alexey Shchepin"}]}]}.

iq_get_unique_el(From) ->
    #xmlel{ns = ?NS_MUC_UNIQUE, name = 'unique',
            children = [#xmlcdata{cdata = iq_get_unique_name(From)}]}.

%% @doc Get a pseudo unique Room Name. The Room Name is generated as a hash of 
%%      the requester JID, the local time and a random salt.
%%
%%      "pseudo" because we don't verify that there is not a room
%%       with the returned Name already created, nor mark the generated Name 
%%       as "already used".  But in practice, it is unique enough. See
%%       http://xmpp.org/extensions/xep-0045.html#createroom-unique
iq_get_unique_name(From) ->
	sha:sha(term_to_binary([From, now(), randoms:get_string()])).

broadcast_service_message(Host, Msg) ->
    lists:foreach(
      fun(#muc_online_room{pid = Pid}) ->
	      gen_fsm:send_all_state_event(
		Pid, {service_message, Msg})
      end, get_vh_rooms(Host)).

get_vh_rooms(Host) when is_binary(Host) ->
    mnesia:dirty_select(muc_online_room,
			[{#muc_online_room{name_host = '$1', _ = '_'},
			  [{'==', {element, 2, '$1'}, Host}],
			  ['$_']}]).


clean_table_from_bad_node(Node) ->
    F = fun() ->
		Es = mnesia:select(
		       muc_online_room,
		       [{#muc_online_room{pid = '$1', _ = '_'},
			 [{'==', {node, '$1'}, Node}],
			 ['$_']}]),
		lists:foreach(fun(E) ->
				      mnesia:delete_object(E)
			      end, Es)
        end,
    mnesia:transaction(F).

clean_table_from_bad_node(Node, Host) ->
    F = fun() ->
		Es = mnesia:select(
		       muc_online_room,
		       [{#muc_online_room{pid = '$1',
					  name_host = {'_', Host},
					  _ = '_'},
			 [{'==', {node, '$1'}, Node}],
			 ['$_']}]),
		lists:foreach(fun(E) ->
				      mnesia:delete_object(E)
			      end, Es)
        end,
    mnesia:transaction(F).


update_tables(Host) ->
    update_muc_room_table(Host),
    update_muc_registered_table(Host).

update_muc_room_table(Host) ->
    Fields = record_info(fields, muc_room),
    case mnesia:table_info(muc_room, attributes) of
	Fields ->
	    ok;
	[name, opts] ->
	    ?INFO_MSG("Converting muc_room table from "
		      "{name, opts} format", []),
	    {atomic, ok} = mnesia:create_table(
			     mod_muc_tmp_table,
			     [{disc_only_copies, [node()]},
			      {type, bag},
			      {local_content, true},
			      {record_name, muc_room},
			      {attributes, record_info(fields, muc_room)}]),
	    mnesia:transform_table(muc_room, ignore, Fields),
	    F1 = fun() ->
			 mnesia:write_lock_table(mod_muc_tmp_table),
			 mnesia:foldl(
			   fun(#muc_room{name_host = Name} = R, _) ->
				   mnesia:dirty_write(
				     mod_muc_tmp_table,
				     R#muc_room{name_host = {Name, Host}})
			   end, ok, muc_room)
		 end,
	    mnesia:transaction(F1),
	    mnesia:clear_table(muc_room),
	    F2 = fun() ->
			 mnesia:write_lock_table(muc_room),
			 mnesia:foldl(
			   fun(R, _) ->
				   mnesia:dirty_write(R)
			   end, ok, mod_muc_tmp_table)
		 end,
	    mnesia:transaction(F2),
	    mnesia:delete_table(mod_muc_tmp_table);
	_ ->
	    ?INFO_MSG("Recreating muc_room table", []),
	    mnesia:transform_table(muc_room, ignore, Fields)
    end.


update_muc_registered_table(Host) ->
    Fields = record_info(fields, muc_registered),
    case mnesia:table_info(muc_registered, attributes) of
	Fields ->
	    ok;
	[user, nick] ->
	    ?INFO_MSG("Converting muc_registered table from "
		      "{user, nick} format", []),
	    {atomic, ok} = mnesia:create_table(
			     mod_muc_tmp_table,
			     [{disc_only_copies, [node()]},
			      {type, bag},
			      {local_content, true},
			      {record_name, muc_registered},
			      {attributes, record_info(fields, muc_registered)}]),
	    mnesia:del_table_index(muc_registered, nick),
	    mnesia:transform_table(muc_registered, ignore, Fields),
	    F1 = fun() ->
			 mnesia:write_lock_table(mod_muc_tmp_table),
			 mnesia:foldl(
			   fun(#muc_registered{us_host = US} = R, _) ->
				   mnesia:dirty_write(
				     mod_muc_tmp_table,
				     R#muc_registered{us_host = {US, Host}})
			   end, ok, muc_registered)
		 end,
	    mnesia:transaction(F1),
	    mnesia:clear_table(muc_registered),
	    F2 = fun() ->
			 mnesia:write_lock_table(muc_registered),
			 mnesia:foldl(
			   fun(R, _) ->
				   mnesia:dirty_write(R)
			   end, ok, mod_muc_tmp_table)
		 end,
	    mnesia:transaction(F2),
	    mnesia:delete_table(mod_muc_tmp_table);
	_ ->
	    ?INFO_MSG("Recreating muc_registered table", []),
	    mnesia:transform_table(muc_registered, ignore, Fields)
    end.
