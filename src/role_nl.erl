%% Copyright (c) 2017, Oleksiy Kebkal <lesha@evologics.de>
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. The name of the author may not be used to endorse or promote products
%%    derived from this software without specific prior written permission.
%%
%% Alternatively, this software may be distributed under the terms of the
%% GNU General Public License ("GPL") version 2 as published by the Free
%% Software Foundation.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
%% IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
%% NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
%% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
%% THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
%% THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-module(role_nl).
-behaviour(role_worker).

-include("fsm.hrl").
-include("nl.hrl").

-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2, split/2]).

-record(config, {eol}).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  _ = {ok, busy, error, failed, delivered, send, recv, empty, ack}, %% atom vocabular
  _ = {staticr, staticrack, sncfloodr, sncfloodrack, dpfloodr, dpfloodrack, icrpr, sncfloodpfr, sncfloodpfrack, evoicrppfr, evoicrppfrack, dblfloodpfr, dblfloodpfrack, laorp},
  _ = {time, period},
  _ = {source, relay},
  Cfg = #config{eol = "\r\n"},
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg).

ctrl(_, Cfg) -> Cfg.

to_term(Tail, Chunk, Cfg) ->
  role_worker:to_term(?MODULE, Tail, Chunk, Cfg).

split(L, Cfg) ->
  case re:split(L,"\r?\n",[{parts,2}]) of
    [<<"NL,recv,", _/binary>>, _] -> %% binary
      nl_recv_extract(L, Cfg);
    [<<"NL,send,ack,", _/binary>>, _] -> %% binary
      nl_ack_extract(L, Cfg);
    [<<"NL,protocolinfo,", _/binary>>, _] -> %% multiline
      nl_multiline_extract(L, Cfg);
    [<<"NL,states,", States/binary>>, _] when States =/= <<"empty">> -> %% multiline
      nl_multiline_extract(L, Cfg);
    [<<"NL,statistics,", _/binary>>, _] -> %% multiline
      nl_multiline_extract(L, Cfg);
    [<<"NL,buffer,", _/binary>>, _] -> %% multiline
      nl_multiline_extract(L, Cfg);
    [Answer, Rest] ->
      case re:run(Answer,"^NL,([^,]*),(.*)", [dotall, {capture, [1, 2], binary}]) of
        {match, [Subject, Params]} ->
          Reply = try nl_extract_subject(Subject, Params)
                  catch error: _ -> {nl, error, {parseError, Answer}}
                  end,
          [Reply | split(Rest, Cfg)];
        nomatch -> [{nl, error, {parseError, Answer}} | split(Rest, Cfg)]
      end;
    _ ->
      [{more, L}]
  end.

%% NL,recv,<Len>,<Src>,<Dst>,<Data>
nl_recv_extract(L, Cfg) ->
  try
    [Type, BLen, BSrc, BDst, Rest] = nl_recv_extract_helper(L),
    [Len, Src, Dst] = [binary_to_integer(I) || I <- [BLen, BSrc, BDst]],
    PLLen = byte_size(Rest),
    case re:run(Rest, "^(.{" ++ integer_to_list(Len) ++ "})\r?\n(.*)",[dotall,{capture,[1,2],binary}]) of
      {match, [Data, Tail]} when Type == notype ->
        [{nl, recv, Src, Dst, Data} | split(Tail, Cfg)];
      {match, [Data, Tail]} ->
        [{nl, recv, Type, Src, Dst, Data} | split(Tail, Cfg)];
      _ when Len + 1 =< PLLen ->
        [{nl, error, {parseError, L}}];
      _ ->
        [{more, L}]
    end
  catch error: _Reason -> [{nl, error, {parseError, L}}]
  end.

nl_recv_extract_helper(L) ->
  Templates = [{"NL,recv,(tolerant|sensitive|broadcast|alarm),([^,]*),([^,]*),([^,]*),(.*)", [1,2,3,4,5]},
               {"NL,recv,([^,]*),([^,]*),([^,]*),(.*)", [1,2,3,4]}],

  nl_recv_extract_helper(L, Templates).

nl_recv_extract_helper(match, L) -> L;
nl_recv_extract_helper(_, []) -> nomatch;
nl_recv_extract_helper(L, [H | T]) ->
  {Template, LB} = H,
  case re:run(L, Template, [dotall, {capture, LB, binary}]) of
    {match, [BType, BLen, BSrc, BDst, Rest]} ->
      Type = binary_to_existing_atom(BType, utf8),
      nl_recv_extract_helper(match, [Type, BLen, BSrc, BDst, Rest]);
    {match, [BLen, BSrc, BDst, Rest]} ->
      nl_recv_extract_helper(match, [notype, BLen, BSrc, BDst, Rest]);
    nomatch -> nl_recv_extract_helper(L, T)
  end.

nl_ack_extract(L, Cfg) ->
  try
    {match, [BLen, BDst, Rest]} = re:run(L,"NL,send,ack,([^,]*),([^,]*),(.*)", [dotall, {capture, [1, 2, 3], binary}]),
    [Len, Dst] = [binary_to_integer(I) || I <- [BLen, BDst]],

    PLLen = byte_size(Rest),
    case re:run(Rest, "^(.{" ++ integer_to_list(Len) ++ "})\r?\n(.*)",[dotall,{capture,[1,2],binary}]) of
      {match, [Data, Tail]} ->
        [{nl, ack, Dst, Data} | split(Tail, Cfg)];
      _ when Len + 1 =< PLLen ->
        [{nl, error, {parseError, L}}];
      _ ->
        [{more, L}]
    end
  catch error: _Reason -> [{nl, error, {parseError, L}}]
  end.

nl_multiline_extract(L, Cfg) ->
  case re:split(L,"\r?\n\r?\n",[{parts,2}]) of
    [Answer, Rest] ->
      case re:run(Answer,"^NL,([^,]*),(.*)", [dotall, {capture, [1, 2], binary}]) of
        {match, [Subject, Params]} ->
          Reply = try nl_extract_subject(Subject, Params)
                  catch error: _ -> {nl, error, {parseError, Answer}}
                  end,
          [Reply | split(Rest, Cfg)];
        nomatch -> [{nl, error, {parseError, Answer}} | split(Rest, Cfg)]
      end;
    _ ->
        [{more, L}]
  end.

%% NL,send,Status
%% Status: ok|busy|error
nl_extract_subject(<<"send">>, Params) ->
  SendRes = try binary_to_integer(Params)
          catch error: _ -> binary_to_existing_atom(Params, utf8)
          end,
  {nl, send, SendRes};
%% NL,address,Address
%% Address: integer
nl_extract_subject(<<"address">>, <<H:8,_/binary>> = Params) when H >= $0, H =< $9 ->
  {nl, address, binary_to_integer(Params)};
nl_extract_subject(<<"address">>, Params) ->
  {nl, address, binary_to_existing_atom(Params, utf8)};
%% NL,version,Major,Minor,Description
nl_extract_subject(<<"version">>, Params) ->
  [BMajor,BMinor,Description] = binary:split(Params,<<$,>>, [global]),
  [Major,Minor] = [binary_to_integer(V) || V <- [BMajor,BMinor]],
  {nl, version, Major, Minor, binary_to_list(Description)};
%% NL,protocols,Protocol1,Protocol2,...,ProtocolN
%% ProtocolI: atom
nl_extract_subject(<<"protocols">>, Params) ->
  {nl, protocols, [binary_to_existing_atom(P, utf8) || P <- binary:split(Params, <<$,>>, [global])]};
%% NL,protocol,Protocol
%% Protoco: atom
nl_extract_subject(<<"protocol">>, Params) ->
  {nl, protocol, binary_to_existing_atom(Params, utf8)};
%% NL,routing,ok
nl_extract_subject(<<"routing">>, <<"ok">>) ->
  {nl, routing, ok};
%% NL,routing,A1->A2,A3->A4,..,default->Default
%% AI and Default: interger
nl_extract_subject(<<"routing">>, Params) ->
  Map =
    lists:map(fun([<<"default">>,To]) ->
                  {default, binary_to_integer(To)};
                 ([From,To]) ->
                  {binary_to_integer(From), binary_to_integer(To)}
              end, [binary:split(V,<<"->">>) || V <- binary:split(Params,<<$,>>,[global])]),
  {nl, routing, Map};
%% NL,neighbours,ok
nl_extract_subject(<<"ps">>, <<"ok">>) ->
  {nl, ps, ok};
nl_extract_subject(<<"ps">>, Params) ->
  Ls = [binary_to_integer(V) || V <- binary:split(Params,<<$,>>,[global])],
  {nl, ps, Ls};
%% NL,neighbours,ok
nl_extract_subject(<<"neighbours">>, <<"ok">>) ->
  {nl, neighbours, ok};
%% NL,neighbours,empty
nl_extract_subject(<<"neighbours">>, <<"empty">>) ->
  {nl, neighbours, []};
%% NL,neighbours,A1:R1:I1:T1,...,AN:RN:IN:TN
%% NL,neighbours,A1,...,AN
%% all parameters integers
nl_extract_subject(<<"neighbours">>, Params) ->
  Lst = [binary:split(V, <<$:>>, [global]) || V <- binary:split(Params, <<$,>>, [global])],
  Neighbours =
    case lists:usort([length(Item) || Item <- Lst]) of
      [1] -> [binary_to_integer(Item) || [Item] <- Lst];
      [4] -> [list_to_tuple([binary_to_integer(I) || I <- Item]) || Item <- Lst]
    end,
  {nl, neighbours, Neighbours};
%% NL,neighbour,ok
nl_extract_subject(<<"neighbour">>, <<"ok">>) ->
  {nl, neighbour, ok};
%% NL,state,State(Event)
nl_extract_subject(<<"state">>, <<"ok">>) ->
  {nl, state, ok};
nl_extract_subject(<<"state">>, Params) ->
  {match, BList} = re:run(Params,"(.*)\\((.*)\\)",[{capture, [1,2], binary}]),
  {nl, state, list_to_tuple([binary_to_list(I) || I <- BList])};
%% NL,discovery,ok
nl_extract_subject(<<"discovery">>, <<"ok">>) ->
  {nl, discovery, ok};
%% NL,discovery,busy
nl_extract_subject(<<"discovery">>, <<"busy">>) ->
  {nl, discovery, busy};
%% NL,discovery,Period,Time
%% Period: integer
%% Time: integer
nl_extract_subject(<<"discovery">>, Params) ->
  [Period, Time] = [binary_to_integer(V) || V <- binary:split(Params, <<$,>>)],
  {nl, discovery, Period, Time};
%% NL,polling,[ok|error|empty|Seq]
nl_extract_subject(<<"polling">>, Params) ->
  [H|T] = re:split(Params,",",[{parts,2}]),
  case H of
    <<I:8,_/binary>> when I >= $0, I =< $9 ->
      {nl, polling, [binary_to_integer(P) || P <- binary:split(Params, <<$,>>, [global])]};
    <<"status">> ->
      {nl, polling, status, binary_to_existing_atom(hd(T), utf8)};
    _ ->
      {nl, polling, binary_to_existing_atom(Params, utf8)}
  end;
%NL,path,Retries,Dst
% Retries decreasinf, if < 0 -> Retries = failed
nl_extract_subject(<<"path">>, <<"failed,", Params/binary>>) ->
  [Dst] = [binary_to_integer(V) || V <- binary:split(Params,<<$,>>, [global])],
  {nl, path, failed, Dst};
nl_extract_subject(<<"path">>, Params) ->
  [Retries, Dst] = [binary_to_integer(V) || V <- binary:split(Params,<<$,>>, [global])],
  {nl, path, Retries, Dst};
%% NL,delivered,PC,Src,Dst
nl_extract_subject(<<"delivered">>, Params) ->
  [PC, Src, Dst] = [binary_to_integer(V) || V <- binary:split(Params,<<$,>>, [global])],
  {nl, delivered, PC, Src, Dst};
%% NL,failed,PC, Src,Dst
nl_extract_subject(<<"failed">>, Params) ->
  [PC, Src, Dst] = [binary_to_integer(V) || V <- binary:split(Params,<<$,>>, [global])],
  {nl, failed, PC, Src, Dst};
%% NL,protocolinfo,Protocol,<EOL>Property1 : Value1<EOL>...PropertyN : ValueN<EOL><EOL>
%% one of the properties must be "name"
%% parameters are strings
nl_extract_subject(<<"protocolinfo">>, Params) ->
  [Protocol, KVParams] = re:split(Params,",",[{parts,2}]),
  PropList = [list_to_tuple(re:split(I," : ",[{return,list}])) || I <- tl(re:split(KVParams,"\r?\n"))],
  %% {value, ["name",Protocol], PropList} = lists:keytake("name", 1, KVLst),
  {nl,protocolinfo,binary_to_existing_atom(Protocol,utf8),PropList};
%% NL,states,<EOL><State1>(<Event1>)<EOL>...<StateN>(<EventN>)<EOL><EOL>
nl_extract_subject(<<"states">>, <<"empty">>) ->
  {nl, states, empty};
nl_extract_subject(<<"states">>, Params) ->
  {nl,states,
   lists:map(fun(Param) ->
                 {match, BList} = re:run(Param,"(.*)\\((.*)\\)",[{capture, [1,2], binary}]),
                 list_to_tuple([binary_to_list(I) || I <- BList])
             end, tl(re:split(Params,"\r?\n")))};

nl_extract_subject(<<"time">>, <<"monotonic,",Time/binary>>) ->
  {nl,time,monotonic, binary_to_integer(Time)};
%% NL,statistics,ok
nl_extract_subject(<<"statistics">>, <<"ok">>) ->
  {nl, statistics, ok};
nl_extract_subject(<<"get">>, <<"routing">>) ->
  {nl, get, routing};
nl_extract_subject(<<"get">>, <<"service">>) ->
  {nl, get, service};
nl_extract_subject(<<"get">>, <<"bitrate">>) ->
  {nl, get, bitrate};
nl_extract_subject(<<"get">>, <<"status">>) ->
  {nl, get, status};
nl_extract_subject(<<"update">>, <<"routing,", Params/binary>>) ->
  Dst = binary_to_integer(Params),
  {nl, update, routing, Dst};
%% NL,statistics,neighbours,<EOL> <relay or source> neighbours:<neighbours> count:<count> total:<total><EOL>...<EOL><EOL>
%% NL,statistics,neighbours,
%%  neighbour:3 duration:Time count:8 total:10
%%  neighbour:2 duration:Time count:4 total:10
%% -> [{Role,Neighbours,Count,Total}]
nl_extract_subject(<<"statistics">>, <<"neighbours,empty",_/binary>>) ->
  {nl,statistics,neighbours,empty};
nl_extract_subject(<<"statistics">>, <<"neighbours,",Params/binary>>) ->
  Lines = tl(re:split(Params,"\r?\n")),
  {nl,statistics,neighbours,
   lists:map(fun(Line) ->
                 {match, [A,U,C,T]} =
                   re:run(Line, " neighbour:(\\d+) last update:(\\d+) count:(\\d+) total:(\\d+)", [{capture, [1,2,3,4], binary}]),
                 list_to_tuple([binary_to_integer(V) || V <- [A,U,C,T]])
             end, Lines)};
%% NL,statistics,paths,<EOL> <relay or source> path:<path> duration:<duration> count:<count> total:<total><EOL>...<EOL><EOL>
%% NL,statistics,paths,
%%  source path:1,2,3 duration:10 count:1 total:2
%%  source path:1,2,4,3 duration:12 count:1 total:2
%% -> [{Role,Path,Duration,Count,Total}]
nl_extract_subject(<<"statistics">>, <<"paths,empty",_/binary>>) ->
  {nl,statistics,paths,empty};
nl_extract_subject(<<"statistics">>, <<"paths,error",_/binary>>) ->
  {nl,statistics,paths,error};
nl_extract_subject(<<"statistics">>, <<"paths,",Params/binary>>) ->
  Lines = tl(re:split(Params,"\r?\n")),
  Regexp1 = " path:([^ ]*) duration:(\\d+) count:(\\d+) total:(\\d+)",
  Regexp2 = " path:([^ ]*) count:(\\d+) total:(\\d+)",
  {nl,statistics,paths,
   lists:map(fun(Line) ->
                 case re:run(Line, Regexp1, [{capture, [1,2,3,4], binary}]) of
                  {match, [Path,Duration,Count,Total]} ->
                     PathList = [binary_to_integer(I) || I <- binary:split(Path,<<$,>>,[global])],
                     Values = [Duration,Count,Total],
                     list_to_tuple([PathList | [binary_to_integer(V) || V <- Values]]);
                  _ ->
                    {match, [Path,Count,Total]} = re:run(Line, Regexp2, [{capture, [1,2,3], binary}]),
                    PathList = [binary_to_integer(I) || I <- binary:split(Path,<<$,>>,[global])],
                    Values = [Count,Total],
                    list_to_tuple([PathList | [binary_to_integer(V) || V <- Values]])
                  end
             end, Lines)};
%% NL,service,status:P1,P2 service:empty
%% NL,service,status:P1,P2 service:src,dst,type,decoded,transmitted,rssi,integrity
nl_extract_subject(<<"service">>, <<"status:", Params/binary>>) ->
  %Lines = tl(re:split(Params,"\r?\n")),
  Regexp1 = "(.*?) (.*?) service:([^ ]*)",
  {match, [S1, S2, Service]} = re:run(Params, Regexp1, [{capture, [1,2,3], binary}]),
  if Service == <<"empty">> ->
    {nl, service, {status, binary_to_list(S1), binary_to_list(S2)}, []};
  true ->
    Regexp2 = "(.*?) (.*?) service:([^ ]*),([^ ]*),([^ ]*),([^ ]*),([^ ]*),([^ ]*),([^ ]*)",
    {match, [S1, S2, Src, Dst, Type, Decoded, Transmitted, RRssi, RIntegrity]} =
      re:run(Params, Regexp2, [{capture, [1,2,3,4,5,6,7,8,9], binary}]),

      {nl, service, {status, binary_to_list(S1), binary_to_list(S2)},
                    {recvsrv, binary_to_integer(Src), binary_to_integer(Dst),
                              binary_to_list(Type), binary_to_integer(Decoded),
                              binary_to_integer(Transmitted), binary_to_integer(RRssi),
                              binary_to_integer(RIntegrity)}}
  end;
%% NL,status,Status
nl_extract_subject(<<"status">>, <<Params/binary>>) ->
  {nl,status,binary_to_list(Params)};
%% NL,bitrate,empty
%% NL,bitrate,bitrate
nl_extract_subject(<<"bitrate">>, <<"empty">>) ->
  {nl,bitrate,empty};
nl_extract_subject(<<"bitrate">>, <<Params/binary>>) ->
  {nl,bitrate,binary_to_integer(Params)};
%% NL,statistics,data,<EOL> <relay or source> data:<hash> len:<length> duration:<duration> state:<state> total:<total> dst:<dst> hops:<hops><EOL>...<EOL><EOL>
%% NL,statistics,data,
%%  source data:0xabde len:4 duration:5.6 state:delivered total:1 dst:4 hops:1
%%  source data:0x1bdf len:4 duration:11.4 state:delivered total:1 dst:4 hops:2
%%  source data:0xabdf len:4 duration:9.9 state:delivered total:1 dst:4 hops:2
%% -> [{Role,Hash,Len,Duration,State,Total,Dst,Hops}]
nl_extract_subject(<<"statistics">>, <<"data,empty",_/binary>>) ->
  {nl,statistics,data,empty};
nl_extract_subject(<<"statistics">>, <<"data,error",_/binary>>) ->
  {nl,statistics,data,error};
nl_extract_subject(<<"statistics">>, <<"data,",Params/binary>>) ->
  Lines = tl(re:split(Params,"\r?\n")),
  Regexp1 = " ([^ ]*) data:0x([^ ]*) len:(\\d+) duration:([0-9.]*) state:([^ ]*) src:(\\d+) dst:(\\d+) hops:(\\d+)",
  Regexp2 = " ([^ ]*) data:0x([^ ]*) len:(\\d+) send_time:([0-9.]*) recv_time:([^ ]*) src:(\\d+) dst:(\\d+) last_ttl:(\\d+)",
  {nl,statistics,data,
   lists:map(fun(Line) ->
      case re:run(Line, Regexp1, [{capture, [1,2,3,4,5,6,7,8], binary}]) of
       {match, [Role,Hash,Len,Duration,State,Total,Dst,Hops]} ->
         list_to_tuple(
           [binary_to_existing_atom(Role, utf8),
            binary_to_integer(Hash, 16),
            binary_to_integer(Len),
            binary_to_float(Duration),
            binary_to_existing_atom(State,utf8),
            binary_to_integer(Total),
            binary_to_integer(Dst),
            binary_to_integer(Hops)]);
        _ ->
         {match, [Role,Hash,Len,STime,RTime,Src,Dst,TTL]} =
          re:run(Line, Regexp2, [{capture, [1,2,3,4,5,6,7,8], binary}]),
         list_to_tuple(
           [binary_to_existing_atom(Role, utf8),
            binary_to_integer(Hash, 16),
            binary_to_integer(Len),
            binary_to_integer(STime),
            binary_to_integer(RTime),
            binary_to_integer(Src),
            binary_to_integer(Dst),
            binary_to_integer(TTL)])
      end
   end, Lines)};
%% NL,statistics,tolerant,<EOL> <relay or source> data:<data hash> len:<length> duration:<duration> state:<state> src:<total> dst:<dst><EOL>...<EOL><EOL>
nl_extract_subject(<<"statistics">>, <<"tolerant,empty",_/binary>>) ->
  {nl,statistics,tolerant,empty};
nl_extract_subject(<<"statistics">>, <<"tolerant,",Params/binary>>) ->
  Lines = tl(re:split(Params,"\r?\n")),
  Regexp = " ([^ ]*) id:(\\d+) data:0x([^ ]*) len:(\\d+) duration:([0-9.]*) state:([^ ]*) src:(\\d+) dst:(\\d+)",
  {nl,statistics,tolerant,
   lists:map(fun(Line) ->
                 {match, [Role,PC,Hash,Len,Duration,State,Src,Dst]} =
                   re:run(Line, Regexp, [{capture, [1,2,3,4,5,6,7,8], binary}]),
                 Time =
                 try binary_to_float(Duration)
                 catch error: _ ->
                    binary_to_integer(Duration)
                 end,
                 list_to_tuple(
                 [binary_to_existing_atom(Role, utf8),
                  binary_to_integer(PC),
                  binary_to_integer(Hash, 16),
                  binary_to_integer(Len),
                  Time,
                  binary_to_existing_atom(State,utf8),
                  binary_to_integer(Src),
                  binary_to_integer(Dst)])
             end, Lines)};
%% NL,polling,Addr1,..,AddrN
nl_extract_subject(<<"buffer">>, <<"ok">>) ->
  {nl, buffer, ok};
%% NL,buffer,empty
nl_extract_subject(<<"buffer">>, <<"empty">>) ->
  {nl, buffer, empty};
% NL,statistics,data,<EOL> data:<hash> dst:<dst> type:<type><EOL>...<EOL><EOL>
nl_extract_subject(<<"buffer">>, Params) ->
  Lines = tl(re:split(Params,"\r?\n")),
  Regexp1 = "data:(.*?) dst:(\\d+) type:([^ ]*)",
  Regexp2 = "data:(.*?) src:(\\d+) dst:(\\d+) len:(\\d+) id:(\\d+)",

  {nl, buffer,
   lists:map(fun(Line) ->
                case re:run(Line, Regexp1, [{capture, [1,2,3], binary}]) of
                  {match, [Hash, Dst, Type]} ->
                    list_to_tuple( [Hash,
                                    binary_to_integer(Dst), Type]);
                  _ ->
                    {match, [Hash, Src, Dst, Len, PC]} =
                      re:run(Line, Regexp2, [{capture, [1,2,3,4,5], binary}]),
                    list_to_tuple( [Hash,
                                    binary_to_integer(Src),
                                    binary_to_integer(Dst),
                                    binary_to_integer(Len),
                                    binary_to_integer(PC)])
                end
             end, Lines)}.

%% NL,send[,<Type>],[<Datalen>],<Dst>,<Data>
from_term({nl,send,Dst,Data}, Cfg) ->
  BLen = integer_to_binary(byte_size(Data)),
  [list_to_binary(["NL,send,",BLen,$,,integer_to_binary(Dst),$,,Data,Cfg#config.eol]), Cfg];
from_term({nl,send,Type,Dst,Data}, Cfg) ->
  BLen = integer_to_binary(byte_size(Data)),
  [list_to_binary(["NL,send,",atom_to_binary(Type,utf8),$,,BLen,$,,integer_to_binary(Dst),$,,Data,Cfg#config.eol]), Cfg];
%% NL,ack,Src,Dst,Data
from_term({nl, ack, Src,Dst, Data}, Cfg) ->
  [list_to_binary(["NL,ack,", integer_to_binary(Src),$,,integer_to_binary(Dst),$,,Data,Cfg#config.eol]), Cfg];
%% NL,set,routing,[<A1>-><A2>],[<A3>-><A4>],..,<Default Addr>
from_term({nl,set,routing,Routing}, Cfg) ->
  RoutingLst =
    lists:map(fun({default,To}) -> "default->" ++ integer_to_list(To);
                 ({From,To}) -> integer_to_list(From) ++ "->" ++ integer_to_list(To)
              end, Routing),
  [list_to_binary(["NL,set,routing,",lists:join(",",RoutingLst),Cfg#config.eol]), Cfg];
%% NL,set,neighbours,empty
from_term({nl,set,neighbours,[]}, Cfg) ->
  [list_to_binary(["NL,set,neighbours,empty",Cfg#config.eol]), Cfg];
%% NL,set,neighbours,<A1>,<A2>,...,<AN>
from_term({nl,set,neighbours,[H|_] = Neighbours}, Cfg) when is_integer(H) ->
  NeighboursLst = [integer_to_list(A) || A <- Neighbours],
  [list_to_binary(["NL,set,neighbours,",lists:join(",",NeighboursLst),Cfg#config.eol]), Cfg];
%% NL,set,neighbours,<A1:R1:I1:T1>,<A2:R2:I2:T2>,...,< AN:RN:IN:TN>
from_term({nl,set,neighbours,Neighbours}, Cfg) ->
  NeighboursLst =
    lists:map(fun(T) ->
                  lists:flatten(io_lib:format("~B:~B:~B:~B",tuple_to_list(T)))
              end, Neighbours),
  [list_to_binary(["NL,set,neighbours,",lists:join(",",NeighboursLst),Cfg#config.eol]), Cfg];
%% NL,set,polling,[Addr1,...,AddrN]
%% NL,set,polling,empty
from_term({nl,set,polling,[]}, Cfg) ->
  [list_to_binary(["NL,set,polling,empty",Cfg#config.eol]), Cfg];
from_term({nl,set,polling,Seq}, Cfg) ->
  SeqLst = [integer_to_list(A) || A <- Seq],
  [list_to_binary(["NL,set,polling,",lists:join(",",SeqLst),Cfg#config.eol]), Cfg];
%% NL command with atoms or integers
from_term(Tuple, Cfg) ->
  try
    Lst =
      lists:map(fun(nl) -> <<"NL">>;
                   (I) when is_number(I) -> integer_to_binary(I);
                   (A) when is_atom(A) -> atom_to_binary(A,utf8)
                end, tuple_to_list(Tuple)),
    [list_to_binary([lists:join(",", Lst),Cfg#config.eol]), Cfg]
  catch error:_ -> {error, formError}
  end.
