%%
%%   Copyright (c) 2012, Dmitry Kolesnikov
%%   All Rights Reserved.
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%% @description
%%    queue file  
-module(esq_file).
-behaviour(gen_server).

-export([
   start_link/2
  ,init/1 
  ,terminate/2
  ,handle_call/3 
  ,handle_cast/2 
  ,handle_info/2  
  ,code_change/3
   %% api
  ,encode/1
  ,decode/1
  ,write/2
  ,read/1
  ,remove/1
  ,close/1
]).

%%
%%
-define(PAGE,             64 * 1024).
-define(CHUNK,                  255).
-define(HASH32(X),  erlang:crc32(X)).
 
-record(io, {
   file  = undefined :: list()
  ,fd    = undefined :: any()
  ,cache = undefined :: binary()
}).

%%
%% open file
start_link(File, Opts) ->
   case gen_server:start_link(?MODULE, [self(), Ref = make_ref(), File, Opts], []) of
      {ok, Fd} ->
         {ok, Fd};
      ignore   ->
         receive
            {Ref, Error} ->
               Error
         end;
      Error ->
         Error
   end.

init([Pid, Ref, File, Opts]) ->
   %% terminate process gracefully and close the file
   process_flag(trap_exit, true),
   case file:open(File, [raw, binary] ++ Opts) of
      {ok, FD} ->
         {ok, #io{file=File, fd=FD, cache = <<>>}};
      Error    ->
         Pid ! {Ref, Error},
         ignore
   end.

terminate(_Reason, #io{fd=undefined}) ->
   ok;
terminate(_Reason, #io{}=S) ->
   file:close(S#io.fd).

%%%----------------------------------------------------------------------------   
%%%
%%% api
%%%
%%%----------------------------------------------------------------------------   

%%
%%
write(FD, Data)
 when is_pid(FD) ->
   gen_server:call(FD, {write, Data}).

%%
%%
read(FD)
 when is_pid(FD) ->
   gen_server:call(FD, read). 

%%
%%
remove(FD)
 when is_pid(FD) ->
   gen_server:call(FD, remove). 

%%
%%
close(FD)
 when is_pid(FD) ->
   gen_server:call(FD, close). 


%%%----------------------------------------------------------------------------   
%%%
%%% gen_server
%%%
%%%----------------------------------------------------------------------------   

%%
%%
handle_call({write, Bin}, _Tx, S) ->
   Chunk = encode(Bin),
   case file:write(S#io.fd, Chunk) of
      ok    -> 
         {reply, {ok, byte_size(Chunk)}, S};
      Error -> 
         {reply, Error, S}
   end;

handle_call(read, Tx, #io{cache = <<>>}=S) ->
   case file:read(S#io.fd, ?PAGE) of
      {ok, Data} ->
         handle_call(read, Tx, S#io{cache = Data});
      Error ->
         {reply, Error, S}
   end; 

handle_call(read, Tx, #io{}=S) ->
   case decode(S#io.cache) of
      {error, no_message} ->
         case file:read(S#io.fd, ?PAGE) of
            {ok, Data} ->
               handle_call(read, Tx, S#io{cache = <<(S#io.cache)/binary, Data/binary>>});
            Error ->
               {reply, Error, S}
         end;
      {<<>>, Cache} ->
         handle_call(read, Tx, S#io{cache=Cache});
      {Msg,  Cache} ->
         {reply, {ok, Msg}, S#io{cache=Cache}}
   end;   

handle_call(remove, _Tx, #io{}=S) ->
   _ = file:close(S#io.fd),
   _ = file:delete(S#io.file),
   {stop, normal, ok, S#io{fd=undefined}};

handle_call(close, _Tx, S) ->
   {stop, normal, ok, S}; 

handle_call(_Req, _Tx, S) ->
   {noreply, S}.

%%
%%
handle_cast(_Req, S) ->
   {noreply, S}.

%%
%%
handle_info({'EXIT', _, normal}, S) ->
    {noreply, S};
handle_info({'EXIT', _, Reason}, S) ->
    {stop, Reason, S};
handle_info(_Msg, S) ->
   {noreply, S}.

%%
%% 
code_change(_Vsn, S, _Extra) ->
   {ok, S}.


%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   

%%
%% encode binary to file cells
%% see for optimization
%%    http://erlang.org/pipermail/erlang-questions/2013-April/073292.html
%%    https://gist.github.com/nox/5359459/raw/0b86154804b43b9043a3fed00debe284f4702f10/prealloc_bin.S
encode(Msg) ->
   Hash = ?HASH32(Msg),
   Head = <<(byte_size(Msg)):32, Hash:32, Msg/binary>>, 
   Tail = <<0:(8 * (?CHUNK - byte_size(Head) rem ?CHUNK))>>,
   Chunks = [ X || <<X:?CHUNK/binary>> <= <<Head/binary, Tail/binary>> ],
   << <<X/binary>> || X <- lists:zipwith(fun encode_chunk/2, lists:seq(1, length(Chunks)), Chunks) >>. 

encode_chunk(1, Chunk) ->
   <<1:8, Chunk/binary>>;
encode_chunk(_, Chunk) ->
   <<0:8, Chunk/binary>>.

%%
%% decode file cells to binary 
decode(<<1:8, Len:32, Hash:32, Chunk:(?CHUNK - 8)/binary, Tail/binary>>) ->
   case byte_size(Tail) + ?CHUNK - 8 of
      %% unable to decode (more data is needed)
      X when X < Len ->
         {error, no_message};
      %%
      _ ->
         decode(Tail, Len, Hash, [Chunk])
   end.

decode(<<0:8, Chunk:?CHUNK/binary, Tail/binary>>, Len, Hash, Acc) ->
   decode(Tail, Len, Hash, [Chunk | Acc]);
decode(<<1:8, _/binary>>=Tail, Len, Hash, Acc) ->
   <<Msg:Len/binary, _/binary>> = << <<X/binary>> || X <- lists:reverse(Acc) >>,
   case ?HASH32(Msg) of
      Hash -> {Msg,  Tail};
      _    -> {<<>>, Tail}
   end;
decode(<<>>=Tail, Len, Hash, Acc) ->
   <<Msg:Len/binary, _/binary>> = << <<X/binary>> || X <- lists:reverse(Acc) >>,
   case ?HASH32(Msg) of
      Hash -> {Msg,  Tail};
      _    -> {<<>>, Tail}
   end.








% -export([
% 	writer/2,
% 	reader/2,
% 	close/1,
% 	rotate/1,
% 	remove/1,
% 	write_record/3,
% 	write_string/2,
% 	read_record/1
% ]).



% %%
% %% close file
% close(undefined) ->
% 	ok;
% close({file, _, FD}) ->
% 	file:close(FD).


% %%
% %% rotate file
% rotate(undefined) ->
% 	ok;
% rotate({file, File, FD}) ->
% 	file:close(FD),
% 	rotate(File);
% rotate(File) ->
%    {A, B, C} = erlang:now(),
%    Now = lists:flatten(
%       io_lib:format(".~6..0b~6..0b~6..0b", [A, B, C])
%    ),
%    file:rename(File, filename:rootname(File) ++ Now).

% %%
% %% remove file
% remove(undefined) ->
% 	ok;
% remove({file, File, FD}) ->
% 	file:close(FD),
% 	remove(File);
% remove(File) ->
% 	file:delete(File).

% %%
% %% 
% write_record({file, _, FD}, Type, Msg) ->
%    Size = size(Msg),
%    case file:write(FD, [<<Type:8>>, <<Size:56>>, Msg]) of
%       ok    -> {ok, Size};
%       Error -> Error
%    end.

% write_string({file, _, FD}, Msg) ->
%    Size = size(Msg),
%    case file:write(FD, [Msg, $\n]) of
%       ok    -> {ok, Size};
%       Error -> Error
%    end.

% %%
% %%
% read_record({file, _, FD}) ->
% 	case file:read(FD, 8) of
%       {ok, <<Type:8, Size:56>>} ->
%          case file:read(FD, Size) of
%             {ok, Msg} ->
%                {ok, Type, Msg};
%             Error     ->
%                Error
%          end;
%       Error ->
%       	Error
%    end.



