%%%-------------------------------------------------------------------
%%% @author Arun Suresh <>
%%% @copyright (C) 2010, Arun Suresh
%%% @doc
%%%
%%% @end
%%% Created :  4 Nov 2010 by Arun Suresh <>
%%%-------------------------------------------------------------------
-module(external_store_file).
-behaviour(external_store).
-include("phoebus.hrl").

%% API
-export([init/1,
         partition_input/1,
         read_vertices/2,
         store_vertices/2,
         destroy/1]).

%%%===================================================================
%%% API
%%%===================================================================
init([$f, $i, $l, $e, $:, $/, $/ | AbsPath] = URI) ->
  IsDir = external_store:check_dir(URI),
  {true, [{uri, URI}, {abs_path, AbsPath}, {type, file}, {is_dir, IsDir}]};
init(_) -> {false, []}.

  
partition_input(State) ->
  case proplists:get_value(is_dir, State) of
    true ->
      {ok, Files} = file:list_dir(proplists:get_value(abs_path, State)),
      Base = proplists:get_value(uri, State),
      {ok, [Base ++ F || F <- Files], State};
    _ ->
      {error, State}
  end.

read_vertices(State, Recvr) ->
  case proplists:get_value(is_dir, State) of
    false ->
      start_reading(proplists:get_value(type, State), 
                    proplists:get_value(abs_path, State), Recvr, State);
    _ ->
      {error, State}
  end.  

store_vertices(State, Vertices) ->
  case proplists:get_value(is_dir, State) of
    false ->
      {FD, NewState} = 
        case proplists:get_value(open_file_ref, State) of
          undefined ->
            {ok, F} = 
              file:open(proplists:get_value(abs_path, State), [write]),
            {F, [{open_file_ref, F}|State]};
          F -> {F, State}
        end,
      lists:foreach(
        fun(V) -> file:write(FD, external_store:serialize(V)) end, Vertices),
      NewState;
    _ ->
      {error, State}
  end.  

destroy(State) ->
  case proplists:get_value(open_file_ref, State) of
    undefined -> ok;
    FD -> file:close(FD)
  end.

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
start_reading(file, File, Recvr, State) ->
  RPid = spawn(fun() -> reader_loop({init, File}, Recvr, {State, []}) end),
  {ok, RPid, State}.


reader_loop({init, File}, Pid, State) ->
  {ok, FD} = file:open(File, [raw, read_ahead, binary]),
  reader_loop(FD, Pid, State);
reader_loop(FD, Pid, {State, Buffer}) ->
  case file:read_line(FD) of
    {ok, Line} ->
      case external_store:deserialize(Line) of
        nil -> reader_loop(FD, Pid, {State, Buffer});
        V -> 
          case length(Buffer) > 100 of
            true ->
              gen_fsm:send_event(
                Pid, {vertices, [V|Buffer], self(), State}),
              reader_loop(FD, Pid, {State, []});
            _ ->
              reader_loop(FD, Pid, {State, [V|Buffer]})
          end
      end;
    eof ->
      gen_fsm:send_event(Pid, {vertices_done, Buffer, self(), State}),
      file:close(FD)
  end.