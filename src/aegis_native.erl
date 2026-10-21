%% OS and port primitives the Gleam kernel needs and gleam_erlang does not wrap.
%% A port opened here uses {packet, 4}, so every message is one complete frame
%% in both directions: the Node bridge reads and writes the same 4-byte
%% big-endian length prefix.
-module(aegis_native).

-export([
    halt/1,
    open_port/3,
    port_send/2,
    port_close/1,
    decode_port/1,
    env/1,
    argv/0,
    monotonic_ms/0,
    unique/0,
    mkdir_p/1,
    find_executable/1,
    priv_dir/1,
    file_exists/1,
    read_file/1,
    list_dir/1
]).

open_port(Node, Args, Env) ->
    try
        Port = erlang:open_port(
            {spawn_executable, unicode:characters_to_list(Node)},
            [
                {args, [unicode:characters_to_list(Arg) || Arg <- Args]},
                {env, [
                    {unicode:characters_to_list(Name), unicode:characters_to_list(Value)}
                 || {Name, Value} <- Env
                ]},
                {packet, 4},
                binary,
                exit_status,
                hide
            ]
        ),
        {ok, Port}
    catch
        error:Reason ->
            {error, lists:flatten(io_lib:format("~p", [Reason]))}
    end.

port_send(Port, Data) ->
    try
        case erlang:port_command(Port, Data) of
            true -> {ok, nil};
            false -> {error, nil}
        end
    catch
        error:_ -> {error, nil}
    end.

port_close(Port) ->
    catch erlang:port_close(Port),
    nil.

decode_port({Port, {data, Data}}) when is_port(Port) -> {ok, {data, Data}};
decode_port({Port, {exit_status, Status}}) when is_port(Port) -> {ok, {exit, Status}};
decode_port(_) -> {error, nil}.

env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

argv() ->
    All = [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()],
    %% An escript's plain arguments start with the script path; `gleam run`'s do not.
    case is_escript() of
        true ->
            Script = unicode:characters_to_binary(escript:script_name()),
            case All of
                [First | Rest] ->
                    case same_script(First, Script) of
                        true -> Rest;
                        false -> All
                    end;
                [] -> []
            end;
        false -> All
    end.

%% `gleam run` reports the first plain argument as the escript's name (and it
%% is not a file); a real escript's name resolves to the script itself.
same_script(Arg, Script) ->
    A = unicode:characters_to_list(Arg),
    S = unicode:characters_to_list(Script),
    filename:basename(A) =:= filename:basename(S) andalso
        (filelib:is_regular(A) orelse os:find_executable(A) =/= false).

is_escript() ->
    try escript:script_name() of
        _ -> true
    catch
        _:_ -> false
    end.

monotonic_ms() ->
    erlang:monotonic_time(millisecond).

unique() ->
    erlang:unique_integer([positive, monotonic]).

mkdir_p(Path) ->
    _ = filelib:ensure_dir(filename:join(Path, "keep")),
    nil.

find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

priv_dir(App) ->
    Candidate = case code:priv_dir(list_to_atom(unicode:characters_to_list(App))) of
        {error, _} -> "";
        Dir -> Dir
    end,
    case filelib:is_dir(Candidate) of
        true -> {ok, unicode:characters_to_binary(Candidate)};
        false ->
            case is_escript() of
                true ->
                    EscriptPriv = filename:join(filename:dirname(escript:script_name()), "priv"),
                    case filelib:is_dir(EscriptPriv) of
                        true -> {ok, unicode:characters_to_binary(EscriptPriv)};
                        false -> {error, nil}
                    end;
                false -> {error, nil}
            end
    end.

halt(Code) ->
    erlang:halt(Code).

list_dir(Path) ->
    case file:list_dir(unicode:characters_to_list(Path)) of
        {ok, Names} -> lists:sort([unicode:characters_to_binary(Name) || Name <- Names]);
        {error, _} -> []
    end.

file_exists(Path) ->
    filelib:is_regular(unicode:characters_to_list(Path)).

read_file(Path) ->
    case file:read_file(unicode:characters_to_list(Path)) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.
