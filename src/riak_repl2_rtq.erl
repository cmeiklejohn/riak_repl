%% Riak EnterpriseDS
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
-module(riak_repl2_rtq).

%% @doc Queue module for realtime replication.
%%
%% The queue strives to reliably pass on realtime replication, with the
%% aim of reducing the need to fullsync.  Every item in the queue is
%% given a sequence number when pushed.  Consumers register with the
%% queue, then pull passing in a function to receive items (executed
%% on the queue process - it can cast/! as it desires).
%%
%% Once the consumer has delievered the item, it must ack the queue
%% with the sequence number.  If multiple deliveries have taken
%% place an ack of the highest seq number acknowledge all previous.
%%
%% The queue is currently stored in a private ETS table.  Once
%% all consumers are done with an item it is removed from the table.

-behaviour(gen_server).
%% API
-export([start_link/0,
         register/1,
         unregister/1,
         push/1,
         pull/2,
         ack/2,
         status/0,
         dumpq/0]).

-define(SERVER, ?MODULE).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {qtab = ets:new(?MODULE, [private, ordered_set]), % ETS table
                qseq = 0,  % Last sequence number handed out
                cs = []}).  % Consumers
-record(c, {name,      % consumer name
            aseq = 0,  % last sequence acked
            cseq = 0,  % last sequence sent
            errs = 0,  % delivery errors
            deliver}).  % deliver function if pending, otherwise undefined

%% API
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

register(Name) ->
    gen_server:call(?SERVER, {register, Name}).

unregister(Name) ->
    gen_server:call(?SERVER, {unregister, Name}).

%% Push an item onto the queue
push(Item) ->
    gen_server:cast(?SERVER, {push, Item}).

%% DeliverFun - (Seq, Item)
pull(Name, DeliverFun) ->
    gen_server:cast(?SERVER, {pull, Name, DeliverFun}).

ack(Name, Seq) ->
    gen_server:cast(?SERVER, {ack, Name, Seq}).

status() ->
    gen_server:call(?SERVER, status).

dumpq() ->
    gen_server:call(?SERVER, dumpq).

%% Internals
init([]) ->
    %% make ets table
    {ok, #state{}}.

handle_call(status, _From, State = #state{qseq = QSeq, cs = Cs}) ->
    Status =
        [{Name, [{pending, QSeq - CSeq},  % items to be send
                 {unacked, CSeq - ASeq}]} % sent items requiring ack
         || #c{name = Name, aseq = ASeq, cseq = CSeq} <- Cs],
    {reply, Status, State};
handle_call({register, Name}, _From, State = #state{qtab = QTab, qseq = QSeq, cs = Cs}) ->
    case lists:keytake(Name, #c.name, Cs) of
        {value, C, Cs2} ->
            %% Re-registering, send from the last acked sequence
            CSeq = C#c.aseq,
            UpdCs = [C#c{cseq = CSeq} | Cs2];
        false ->
            %% New registration, start from the beginning
            CSeq = minseq(QTab, QSeq),
            UpdCs = [#c{name = Name, aseq = CSeq, cseq = CSeq} | Cs]
    end,
    {reply, {ok, CSeq}, State#state{cs = UpdCs}};
handle_call({unregister, Name}, _From, State = #state{qtab = QTab, cs = Cs}) ->
    case lists:keytake(Name, #c.name, Cs) of
        {value, C, Cs2} ->
            %% Remove C from Cs, let any pending process know 
            %% and clean up the queue
            case C#c.deliver of
                undefined ->
                    ok;
                Deliver ->
                    Deliver({error, unregistered})
            end,
            MinSeq = case Cs2 of 
                         [] ->
                             State#state.qseq; % no consumers, remove it all
                         _ ->
                             lists:min([Seq || #c{aseq = Seq} <- Cs2])
                     end,
            cleanup(QTab, MinSeq),
            {reply, ok, State#state{cs = Cs2}};
        false ->
            {reply, {error, not_registered}, State}
    end;
handle_call(dumpq, _From, State = #state{qtab = QTab}) ->
    {reply, ets:tab2list(QTab), State}.


handle_cast({push, Item}, State = #state{qtab = QTab, qseq = QSeq, cs = Cs}) ->
    QSeq2 = QSeq + 1,
    SeqItem = {QSeq2, Item},
    %% Send to any pending consumers
    UpdCs = [maybe_deliver_item(C, SeqItem) || C <- Cs],
    ets:insert(QTab, SeqItem),
    {noreply, State#state{qseq = QSeq2, cs = UpdCs}};
handle_cast({pull, Name, DeliverFun}, State = #state{qtab = QTab, qseq = QSeq, cs = Cs}) ->
    UpdCs = case lists:keytake(Name, #c.name, Cs) of
                {value, C, Cs2} ->
                    [maybe_pull(QTab, QSeq, C, DeliverFun) | Cs2];
                false ->
                    DeliverFun({error, not_registered})
            end,
    {noreply, State#state{cs = UpdCs}};
handle_cast({ack, Name, Seq}, State = #state{qtab = QTab, qseq = QSeq, cs = Cs}) ->
    %% Scan through the clients, updating Name for Seq and also finding the minimum
    %% sequence
    {UpdCs, MinSeq} = lists:foldl(
                        fun(C, {Cs2, MinSeq2}) ->
                                case C#c.name of
                                    Name ->
                                        {[C#c{aseq = Seq} | Cs2], min(Seq, MinSeq2)};
                                    _ ->
                                        {[C | Cs2], min(C#c.aseq, MinSeq2)}
                                end
                        end, {[], QSeq}, Cs),
    %% Remove any entries from the ETS table before MinSeq
    cleanup(QTab, MinSeq),
    {noreply, State#state{cs = UpdCs}}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(Reason, #state{cs = Cs}) ->
    [case DeliverFun of
         undefined ->
             ok;
         _ ->
             DeliverFun({error, {terminate, Reason}})
     end || #c{deliver = DeliverFun} <- Cs],
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



maybe_pull(QTab, QSeq, C = #c{cseq = CSeq}, DeliverFun) ->
    CSeq2 = CSeq + 1,
    case CSeq2 =< QSeq of
        true -> % something reday
            [SeqItem] = ets:lookup(QTab, CSeq2),
            deliver_item(C, DeliverFun, SeqItem);
        false ->
            %% consumer is up to date with head, keep deliver function
            %% until something pushed
            C#c{deliver = DeliverFun}
    end.

maybe_deliver_item(C = #c{deliver = DeliverFun}, SeqItem) ->
    case DeliverFun of
        undefined ->
            C;
        _ ->
            deliver_item(C, DeliverFun, SeqItem)
    end.

deliver_item(C, DeliverFun, {Seq,_Item} = SeqItem) ->
    try
        Seq = C#c.cseq + 1, % bit of paranoia, remove after EQC
        ok = DeliverFun(SeqItem),
        C#c{cseq = Seq, deliver = undefined}
    catch
        _:_ ->
            %% do not advance head so it will be delivered again
            C#c{errs = C#c.errs + 1, deliver = undefined}
    end.

%% Find the first sequence number
minseq(QTab, QSeq) ->
    case ets:first(QTab) of
        '$end_of_table' ->
            QSeq;
        MinSeq ->
            MinSeq
    end.


%% Cleanup until the start of the table
cleanup(_QTab, '$end_of_table') ->
    ok;
cleanup(QTab, Seq) ->
    ets:delete(QTab, Seq),
    cleanup(QTab, ets:prev(QTab, Seq)).