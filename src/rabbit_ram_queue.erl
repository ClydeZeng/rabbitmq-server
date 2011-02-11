%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc. All rights reserved.
%%

-module(rabbit_ram_queue).

-export([init/3, terminate/1, delete_and_terminate/1,
         purge/1, publish/3, publish_delivered/4, fetch/2, ack/2,
         tx_publish/4, tx_ack/3, tx_rollback/2, tx_commit/4,
         requeue/3, len/1, is_empty/1, dropwhile/2,
         set_ram_duration_target/2, ram_duration/1,
         needs_idle_timeout/1, idle_timeout/1, handle_pre_hibernate/1,
         status/1]).

-export([start/1, stop/0]).

-behaviour(rabbit_backing_queue).

-record(s,
        { q,
          next_seq_id,
          pending_ack,
          pending_ack_index,
          unconfirmed
        }).

-record(m,
        { seq_id,
          msg,
          is_delivered,
          props
        }).

-record(tx, { pending_messages, pending_acks }).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(seq_id() :: non_neg_integer()).
-type(ack() :: seq_id()).

-type(s() :: #s {
         q :: queue(),
         next_seq_id :: seq_id(),
         pending_ack :: dict(),
         unconfirmed :: gb_set() }).
-type(state() :: s()).

-include("rabbit_backing_queue_spec.hrl").

-endif.

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------

start(_) -> ok.

stop() -> ok.

init(_, _, _) ->
    #s {
      q = queue:new(),
      next_seq_id = 0,
      pending_ack = dict:new(),
      unconfirmed = gb_sets:new() }.

terminate(S) -> remove_pending_ack(S).

delete_and_terminate(S) -> {_PurgeCount, S1} = purge(S),
                           remove_pending_ack(S1).

purge(S = #s { q = Q }) -> {queue:len(Q), S #s { q = queue:new() }}.

publish(Msg, Props, S) -> publish5(Msg, Props, false, S).

publish_delivered(false,
                  #basic_message { guid = Guid },
                  _Props,
                  S) ->
    blind_confirm(self(), gb_sets:singleton(Guid)),
    {undefined, S};
publish_delivered(true,
		  Msg = #basic_message { guid = Guid },
		  Props = #message_properties {
		    needs_confirming = NeedsConfirming },
		  S = #s { next_seq_id = SeqId, unconfirmed = UC }) ->
    S1 = record_pending_ack((m(SeqId, Msg, Props))
			    #m { is_delivered = true }, S),
    UC1 = gb_sets_maybe_insert(NeedsConfirming, Guid, UC),
    {SeqId, S1 #s { next_seq_id = SeqId + 1, unconfirmed = UC1 }}.

dropwhile(Pred, S) -> {_OkOrEmpty, S1} = dropwhile1(Pred, S),
                      S1.

dropwhile1(Pred, S) ->
    internal_queue_out(
      fun(M = #m { props = Props }, S1 = #s { q = Q }) ->
              case Pred(Props) of
                  true -> {_, S2} = internal_fetch(false, M, S1),
			  dropwhile1(Pred, S2);
                  false -> {ok, S1 #s {q = queue:in_r(M, Q) }}
              end
      end,
      S).

fetch(AckRequired, S) ->
    internal_queue_out(
      fun(M, S1) -> internal_fetch(AckRequired, M, S1) end, S).

internal_queue_out(F, S = #s { q = Q }) ->
    case queue:out(Q) of
        {empty, _Q} -> {empty, S};
        {{value, M}, Qa} -> F(M, S #s { q = Qa })
    end.

internal_fetch(AckRequired,
	       M = #m { seq_id = SeqId,
			msg = Msg,
			is_delivered = IsDelivered },
               S = #s { q = Q }) ->
    {AckTag, S1} = case AckRequired of
                       true -> SN = record_pending_ack(
				      M #m { is_delivered = true },
				      S),
                               {SeqId, SN};
                       false -> {undefined, S}
                   end,
    {{Msg, IsDelivered, AckTag, queue:len(Q)}, S1}.

ack(AckTags, S) -> ack(fun (_, S0) -> S0 end, AckTags, S).

tx_publish(Txn, Msg, Props, S) ->
    Tx = #tx { pending_messages = Pubs } = lookup_tx(Txn),
    store_tx(Txn, Tx #tx { pending_messages = [{Msg, Props} | Pubs] }),
    S.

tx_ack(Txn, AckTags, S) ->
    Tx = #tx { pending_acks = Acks } = lookup_tx(Txn),
    store_tx(Txn, Tx #tx { pending_acks = [AckTags | Acks] }),
    S.

tx_rollback(Txn, S) ->
    #tx { pending_acks = AckTags } = lookup_tx(Txn),
    erase_tx(Txn),
    {lists:append(AckTags), S}.

tx_commit(Txn, F, PropsF, S) ->
    #tx { pending_acks = AckTags, pending_messages = Pubs } = lookup_tx(Txn),
    erase_tx(Txn),
    AckTags1 = lists:append(AckTags),
    {AckTags1, tx_commit_post_msg_store(Pubs, AckTags1, F, PropsF, S)}.

requeue(AckTags, PropsF, S) ->
    PropsF1 = fun (Props) ->
		      (PropsF(Props)) #message_properties {
			needs_confirming = false }
	      end,
    ack(fun (#m { msg = Msg, props = Props }, S1) ->
                publish5(Msg, PropsF1(Props), true, S1)
        end,
        AckTags,
        S).

len(#s { q = Q }) -> queue:len(Q).

is_empty(#s { q = Q }) -> queue:is_empty(Q).

set_ram_duration_target(_, S) -> S.

ram_duration(S) -> {0, S}.

needs_idle_timeout(_) -> false.

idle_timeout(S) -> S.

handle_pre_hibernate(S) -> S.

status(#s { q = Q, pending_ack = PA, next_seq_id = NextSeqId }) ->
    [ {q , queue:len(Q)},
      {len , queue:len(Q)},
      {pending_acks , dict:size(PA)},
      {next_seq_id , NextSeqId} ].

%%----------------------------------------------------------------------------
%% Minor helpers
%%----------------------------------------------------------------------------

gb_sets_maybe_insert(false, _Val, Set) -> Set;
gb_sets_maybe_insert(true, Val, Set) -> gb_sets:add(Val, Set).

m(SeqId, Msg, Props) -> #m { seq_id = SeqId,
			     msg = Msg,
			     is_delivered = false,
			     props = Props }.

lookup_tx(Txn) -> case get({txn, Txn}) of
                      undefined -> #tx { pending_messages = [],
                                         pending_acks = [] };
                      V -> V
                  end.

store_tx(Txn, Tx) -> put({txn, Txn}, Tx).

erase_tx(Txn) -> erase({txn, Txn}).

%%----------------------------------------------------------------------------
%% Internal major helpers for Public API
%%----------------------------------------------------------------------------

tx_commit_post_msg_store(Pubs, AckTags, F, PropsF, S) ->
    Pubs2 = [{Msg, PropsF(Props)} || {Msg, Props} <- lists:reverse(Pubs)],
    S1 = lists:foldl(
	   fun ({Msg, Props}, S2) -> publish5(Msg, Props, false, S2) end,
	   ack(AckTags, S),
	   Pubs2),
    F(),
    S1.

%%----------------------------------------------------------------------------
%% Internal gubbins for publishing
%%----------------------------------------------------------------------------

publish5(Msg = #basic_message { guid = Guid },
	 Props = #message_properties { needs_confirming = NeedsConfirming },
	 IsDelivered,
	 S = #s { q = Q, next_seq_id = SeqId, unconfirmed = UC }) ->
    S1 = S #s { q = queue:in((m(SeqId, Msg, Props))
			     #m { is_delivered = IsDelivered },
			     Q) },
    UC1 = gb_sets_maybe_insert(NeedsConfirming, Guid, UC),
    S1 #s { next_seq_id = SeqId + 1, unconfirmed = UC1 }.

%%----------------------------------------------------------------------------
%% Internal gubbins for acks
%%----------------------------------------------------------------------------

record_pending_ack(#m { seq_id = SeqId } = M, S = #s { pending_ack = PA }) ->
    AckEntry = M,
    PA1 = dict:store(SeqId, AckEntry, PA),
    S #s { pending_ack = PA1 }.

remove_pending_ack(S) -> S #s { pending_ack = dict:new() }.

ack(F, AckTags, S) ->
    lists:foldl(
      fun (SeqId, S2 = #s { pending_ack = PA }) ->
	      AckEntry = dict:fetch(SeqId, PA),
	      F(AckEntry, S2 #s { pending_ack = dict:erase(SeqId, PA)})
      end,
      S,
      AckTags).

%%----------------------------------------------------------------------------
%% Internal plumbing for confirms (aka publisher acks)
%%----------------------------------------------------------------------------

remove_confirms(GuidSet, S = #s { unconfirmed = UC }) ->
    S #s { unconfirmed = gb_sets:difference(UC, GuidSet) }.

msgs_confirmed(GuidSet, S) ->
    {gb_sets:to_list(GuidSet), remove_confirms(GuidSet, S)}.

blind_confirm(QPid, GuidSet) ->
    rabbit_amqqueue:maybe_run_queue_via_backing_queue_async(
      QPid, fun (S) -> msgs_confirmed(GuidSet, S) end).

