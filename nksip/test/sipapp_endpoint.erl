%% -------------------------------------------------------------------
%%
%% sipapp_endpoint: Endpoint callback module for all tests
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(sipapp_endpoint).
-behaviour(nksip_sipapp).

-export([start/2, stop/1, add_callback/2, get_sessions/2]).
-export([init/1, get_user_pass/4, authorize/4, route/6, options/3, invite/4, reinvite/4,
        cancel/3, ack/4]).
-export([ping_update/3, register_update/3, dialog_update/3, session_update/3]).
-export([handle_call/3]).

-include_lib("nksip/include/nksip.hrl").


start(AppId, Opts) ->
    nksip:start(AppId, ?MODULE, AppId, Opts).

stop(AppId) ->
    nksip:stop(AppId).

add_callback(AppId, Ref) ->
    ok = nksip:call(AppId, {add_callback, Ref, self()}).

get_sessions(AppId, DialogId) ->
    nksip:call(AppId, {get_sessions, DialogId}).


%%%%%%%%%%%%%%%%%%%%%%%  NkSipCore CallBack %%%%%%%%%%%%%%%%%%%%%


-record(state, {
    id,
    dialogs,
    callbacks,
    sessions
}).


init(error1) ->
    {stop, error1};

init(Id) ->
    {ok, #state{id=Id, dialogs=[], callbacks=[], sessions=[]}}.

% Password for any user in realm "client1" is "4321",
% for any user in realm "client2" is "1234", and for "client3" is "abcd"
get_user_pass(User, <<"client1">>, _From, State) -> 
    % A hash can be used instead of the plain password
    {reply, nksip_auth:make_ha1(User, "4321", "client1"), State};
get_user_pass(_, <<"client2">>, _From, State) ->
    {reply, "1234", State};
get_user_pass(_, <<"client3">>, _From, State) ->
    {reply, "abcd", State};
get_user_pass(_User, _Realm, _From, State) -> 
    {reply, false, State}.


% Authorization is only used for "auth" suite
% client3 doesn't support dialog authorization
authorize(Auth, _RequestId, _From, #state{id={auth, Id}}=State) ->
    case Id=/=client3 andalso lists:member(dialog, Auth) of
        true ->
            {reply, true, State};
        false ->
            BinId = nksip_lib:to_binary(Id) ,
            case nksip_lib:get_value({digest, BinId}, Auth) of
                true -> {reply, true, State}; % At least one user is authenticated
                false -> {reply, false, State}; % Failed authentication
                undefined -> {reply, {authenticate, BinId}, State} % No auth header
            end
    end;
authorize(_Auth, _RequestId, _From, State) ->
    {reply, ok, State}.


route(_Scheme, _User, _Domain, _RequestId, _From, #state{id={speed, client1}}=SD) ->
    {reply, {process, [stateless]}, SD};

route(_Scheme, _User, _Domain, _RequestId, _From, #state{id={speed, client2}}=SD) ->
    {reply, process, SD};

route(_Scheme, _User, _Domain, _RequestId, _From, SD) ->
    {reply, process, SD}.


% For OPTIONS requests, we copy in the response "Nk" headers and "Nk-Id" headers
% adding our own id, and "Nk-R" header with the received routes 
options(RequestId, _From, #state{id={_, Id}}=State) ->
    Values = nksip_request:headers(<<"Nk">>, RequestId),
    Ids = nksip_request:headers(<<"Nk-Id">>, RequestId),
    Routes = nksip_request:headers(<<"Route">>, RequestId),
    Hds = [
        case Values of [] -> []; _ -> {<<"Nk">>, nksip_lib:bjoin(Values)} end,
        case Routes of [] -> []; _ -> {<<"Nk-R">>, nksip_lib:bjoin(Routes)} end,
        {<<"Nk-Id">>, nksip_lib:bjoin([Id|Ids])}
    ],
    {reply, {ok, lists:flatten(Hds)}, State};

options(_RequestId, _From, State) ->
    {reply, ok, State}.



% INVITE for invite_test and proxy_test
% Gets the operation from Nk-Op header, time to sleep from Nk-Sleep,
% if to send provisional response from Nk-Prov
% Copies all received Nk-Id headers adding our own Id
invite(DialogId, RequestId, From, #state{id={Test, Id}, dialogs=Dialogs}=State)
       when Test=:=invite; Test=:=stateless; Test=:=stateful ->
    Values = nksip_request:headers(<<"Nk">>, RequestId),
    Routes = nksip_request:headers(<<"Route">>, RequestId),
    Ids = nksip_request:headers(<<"Nk-Id">>, RequestId),
    Hds = [
        case Values of [] -> []; _ -> {<<"Nk">>, nksip_lib:bjoin(Values)} end,
        case Routes of [] -> []; _ -> {<<"Nk-R">>, nksip_lib:bjoin(Routes)} end,
        {<<"Nk-Id">>, nksip_lib:bjoin([Id|Ids])}
    ],
    Op = case nksip_request:headers(<<"Nk-Op">>, RequestId) of
        [Op0] -> Op0;
        _ -> <<"decline">>
    end,
    Sleep = case nksip_request:headers(<<"Nk-Sleep">>, RequestId) of
        [Sleep0] -> nksip_lib:to_integer(Sleep0);
        _ -> 0
    end,
    Prov = case nksip_request:headers(<<"Nk-Prov">>, RequestId) of
        [<<"true">>] -> true;
        _ -> false
    end,
    case nksip_request:headers(<<"Nk-Reply">>, RequestId) of
        [RepBin] ->
            {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
            State1 = State#state{dialogs=[{DialogId, Ref, Pid}|Dialogs]};
        _ ->
            State1 = State
    end,
    proc_lib:spawn(
        fun() ->
            if 
                Prov -> nksip_request:provisional_reply(RequestId, ringing); 
                true -> ok 
            end,
            case Sleep of
                0 -> ok;
                _ -> timer:sleep(Sleep)
            end,
            case Op of
                <<"ok">> ->
                    nksip:reply(From, {ok, Hds});
                <<"answer">> ->
                    SDP = nksip_sdp:new("client2", 
                                            [{"test", 4321, [{rtpmap, 0, "codec1"}]}]),
                    nksip:reply(From, {ok, Hds, SDP});
                <<"busy">> ->
                    nksip:reply(From, busy);
                <<"increment">> ->
                    SDP1 = nksip_dialog:field(local_sdp, RequestId),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip:reply(From, {ok, Hds, SDP2});
                _ ->
                    nksip:reply(From, decline)
            end
        end),
    {noreply, State1};

% INVITE for fork tests
% Adds Nk-Id header
% Gets operation from body
invite(DialogId, RequestId, From, #state{id={fork, Id}, dialogs=Dialogs}=State) ->
    Ids = nksip_request:headers(<<"Nk-Id">>, RequestId),
    Hds = [{<<"Nk-Id">>, nksip_lib:bjoin([Id|Ids])}],
    case nksip_request:headers(<<"Nk-Reply">>, RequestId) of
        [RepBin] ->
            {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
            State1 = State#state{dialogs=[{DialogId, Ref, Pid}|Dialogs]};
        _ ->
            Ref = Pid = none,
            State1 = State
    end,
    case nksip_request:body(RequestId) of
        Ops when is_list(Ops) ->
            proc_lib:spawn(
                fun() ->
                    case nksip_lib:get_value(Id, Ops) of
                        {redirect, Contacts} ->
                            Code = 300,
                            nksip:reply(From, {redirect, Contacts});
                        Code when is_integer(Code) -> 
                            nksip:reply(From, {Code, Hds});
                        {Code, Wait} when is_integer(Code), is_integer(Wait) ->
                            nksip_request:provisional_reply(RequestId, ringing),
                            timer:sleep(Wait),
                            nksip:reply(From, {Code, Hds});
                        _ -> 
                            Code = 580,
                            nksip:reply(From, {580, Hds})
                    end,
                    case is_pid(Pid) of
                        true -> Pid ! {Ref, {Id, Code}};
                        false -> ok
                    end
                end),
            {noreply, State1};
        _ ->
            {reply, {500, Hds}, State1}
    end;

% INVITE for auth tests
invite(DialogId, RequestId, _From, #state{id={auth, _}, dialogs=Dialogs}=State) ->
    case nksip_request:headers(<<"Nk-Reply">>, RequestId) of
        [RepBin] -> 
            {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
            State1 = State#state{dialogs=[{DialogId, Ref, Pid}|Dialogs]};
        _ ->
            State1 = State
    end,
    {reply, ok, State1}.


reinvite(DialogId, RequestId, From, State) ->
    invite(DialogId, RequestId, From, State).


ack(DialogId, RequestId, _From, #state{id={_, Id}, dialogs=Dialogs}=State) ->
    case lists:keyfind(DialogId, 1, Dialogs) of
        false -> 
            case nksip_request:headers(<<"Nk-Reply">>, RequestId) of
                [RepBin] -> 
                    {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
                    Pid ! {Ref, {Id, ack}};
                _ ->
                    ok
            end;
        {DialogId, Ref, Pid} -> 
            Pid ! {Ref, {Id, ack}}
    end,
    {reply, ok, State}.


cancel(_RequestId, _From, State) ->
    {reply, true, State}.


ping_update(PingId, OK, #state{callbacks=CBs}=State) ->
    [Pid ! {Ref, {ping, PingId, OK}} || {Ref, Pid} <- CBs],
    {noreply, State}.


register_update(RegId, OK, #state{callbacks=CBs}=State) ->
    [Pid ! {Ref, {reg, RegId, OK}} || {Ref, Pid} <- CBs],
    {noreply, State}.


dialog_update(DialogId, Update, #state{id={invite, Id}, dialogs=Dialogs}=State) ->
    case lists:keyfind(DialogId, 1, Dialogs) of
        false -> 
            none;
        {DialogId, Ref, Pid} ->
            case Update of
                {status, confirmed} -> Pid ! {Ref, {Id, dialog_confirmed}};
                target_update -> Pid ! {Ref, {Id, dialog_target_update}};
                {stop, Reason} -> Pid ! {Ref, {Id, {dialog_stop, Reason}}};
                _ -> ok
            end
    end,
    {noreply, State};

dialog_update(_DialogId, _Update, State) ->
    {noreply, State}.


session_update(DialogId, Update, #state{id={invite, Id}, dialogs=Dialogs, 
                                        sessions=Sessions}=State) ->
    case lists:keyfind(DialogId, 1, Dialogs) of
        false -> 
            {noreply, State};
        {DialogId, Ref, Pid} ->
            case Update of
                {start, Local, Remote} ->
                    Pid ! {Ref, {Id, sdp_start}},
                    Sessions1 = [{DialogId, Local, Remote}|Sessions],
                    {noreply, State#state{sessions=Sessions1}};
                {update, Local, Remote} ->
                    Pid ! {Ref, {Id, sdp_update}},
                    Sessions1 = [{DialogId, Local, Remote}|Sessions],
                    {noreply, State#state{sessions=Sessions1}};
                stop ->
                    Pid ! {Ref, {Id, sdp_stop}},
                    {noreply, State}
            end
    end;

session_update(_DialogId, _Update, State) ->
    {noreply, State}.




%%%%%%%%%%%%%%%%%%%%%%%  NkSipCore gen_server CallBacks %%%%%%%%%%%%%%%%%%%%%


handle_call({add_callback, Ref, Pid}, _From, #state{callbacks=CB}=State) ->
    {reply, ok, State#state{callbacks=[{Ref, Pid}|CB]}};

handle_call({get_sessions, DialogId}, _From, #state{sessions=Sessions}=State) ->
    case lists:keyfind(DialogId, 1, Sessions) of
        {_DialogId, Local, Remote} -> {reply, {Local, Remote}, State};
        false -> {reply, not_found, State}
    end.


