%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_config).

-export([new/0, new/1, new/2, new2/2, base_config/1, consult_file/1,
         get/3, get_local/3, get_list/3,
         get_all/2,
         set/3,
         command_args/1, command_args/2,
         set_global/3, get_global/3,
         is_recursive/1,
         save_env/3, get_env/2, reset_envs/1,
         set_skip_dir/2, is_skip_dir/2, reset_skip_dirs/1,
         create_logic_providers/2,
         providers/1, providers/2, add_provider/2,
         add_dep/2, get_dep/2, deps/2, deps/1, deps_graph/1, deps_graph/2, deps_to_build/1,
         goals/1, goals/2,
         get_app/2, apps_to_build/1, apps_to_build/2, add_app/2, replace_app/3,
         set_xconf/3, get_xconf/2, get_xconf/3, erase_xconf/2]).

-include("rebar.hrl").

-ifdef(namespaced_types).
%% dict:dict() exists starting from Erlang 17.
-type rebar_dict() :: dict:dict(term(), term()).
-else.
%% dict() has been obsoleted in Erlang 17 and deprecated in 18.
-type rebar_dict() :: dict().
-endif.

-record(config, { dir :: file:filename(),
                  opts = [] :: list(),
                  local_opts = [] :: list(),
                  globals = new_globals() :: rebar_dict(),
                  envs = new_env() :: rebar_dict(),
                  command_args = [] :: list(),
                  %% cross-directory/-command config
                  goals = [],
                  providers = [],
                  apps_to_build = [],
                  deps_to_build = [],
                  deps = [],
                  deps_graph = undefined,
                  skip_dirs = new_skip_dirs() :: rebar_dict(),
                  xconf = new_xconf() :: rebar_dict() }).

-export_type([config/0]).

-opaque config() :: #config{}.

-define(DEFAULT_NAME, "rebar.config").
-define(LOCK_FILE, "rebar.lock").

%% ===================================================================
%% Public API
%% ===================================================================

base_config(GlobalConfig) ->
    ConfName = rebar_config:get_global(GlobalConfig, config, ?DEFAULT_NAME),
    new(GlobalConfig, ConfName).

new() ->
    #config{dir = rebar_utils:get_cwd()}.

new(ConfigFile) when is_list(ConfigFile) ->
    case consult_file(ConfigFile) of
        {ok, Opts} ->
            #config { dir = rebar_utils:get_cwd(),
                      opts = Opts };
        Other ->
            ?ABORT("Failed to load ~s: ~p~n", [ConfigFile, Other])
    end;
new(_ParentConfig=#config{opts=Opts0, globals=Globals, skip_dirs=SkipDirs, xconf=Xconf}) ->
    new(#config{opts=Opts0, globals=Globals, skip_dirs=SkipDirs, xconf=Xconf},
        ?DEFAULT_NAME).

new(ParentConfig=#config{}, ConfName) ->
    %% Load terms from rebar.config, if it exists
    Dir = rebar_utils:get_cwd(),
    new(ParentConfig, ConfName, Dir).

new2(_ParentConfig=#config{opts=Opts0, globals=Globals, skip_dirs=SkipDirs, xconf=Xconf}, Dir) ->
    new(#config{opts=Opts0, globals=Globals, skip_dirs=SkipDirs, xconf=Xconf},
        ?DEFAULT_NAME, Dir).

new(ParentConfig, ConfName, Dir) ->
    ConfigFile = filename:join([Dir, ConfName]),
    Opts0 = ParentConfig#config.opts,
    Opts = case consult_file(ConfigFile) of
               {ok, Terms} ->
                   Terms;
               {error, enoent} ->
                   [];
               Other ->
                   ?ABORT("Failed to load ~s: ~p\n", [ConfigFile, Other])
           end,

    Opts1 = case consult_file(?LOCK_FILE) of
                {ok, [D]} ->
                    [{lock_deps, D} | Opts];
                _ ->
                    Opts
            end,

    ProviderModules = [],
    create_logic_providers(ProviderModules, ParentConfig#config{dir=Dir
                                                               ,local_opts=Opts1
                                                               ,opts=Opts0}).


get(Config, Key, Default) ->
    proplists:get_value(Key, Config#config.opts, Default).

get_list(Config, Key, Default) ->
    get(Config, Key, Default).

get_local(Config, Key, Default) ->
    proplists:get_value(Key, Config#config.local_opts, Default).

get_all(Config, Key) ->
    proplists:get_all_values(Key, Config#config.opts).

set(Config, Key, Value) ->
    Opts = proplists:delete(Key, Config#config.opts),
    Config#config { opts = [{Key, Value} | Opts] }.

set_global(Config, jobs=Key, Value) when is_list(Value) ->
    set_global(Config, Key, list_to_integer(Value));
set_global(Config, jobs=Key, Value) when is_integer(Value) ->
    NewGlobals = dict:store(Key, erlang:max(1, Value), Config#config.globals),
    Config#config{globals = NewGlobals};
set_global(Config, Key, Value) ->
    NewGlobals = dict:store(Key, Value, Config#config.globals),
    Config#config{globals = NewGlobals}.

get_global(Config, Key, Default) ->
    case dict:find(Key, Config#config.globals) of
        error ->
            Default;
        {ok, Value} ->
            Value
    end.

is_recursive(Config) ->
    get_xconf(Config, recursive, false).

consult_file(File) when is_binary(File) ->
    consult_file(binary_to_list(File));
consult_file(File) ->
    case filename:extension(File) of
        ".script" ->
            consult_and_eval(remove_script_ext(File), File);
        _ ->
            Script = File ++ ".script",
            case filelib:is_regular(Script) of
                true ->
                    consult_and_eval(File, Script);
                false ->
                    ?DEBUG("Consult config file ~p~n", [File]),
                    file:consult(File)
            end
    end.

save_env(Config, Mod, Env) ->
    NewEnvs = dict:store(Mod, Env, Config#config.envs),
    Config#config{envs = NewEnvs}.

get_env(Config, Mod) ->
    dict:fetch(Mod, Config#config.envs).

reset_envs(Config) ->
    Config#config{envs = new_env()}.

set_skip_dir(Config, Dir) ->
    OldSkipDirs = Config#config.skip_dirs,
    NewSkipDirs = case is_skip_dir(Config, Dir) of
                      false ->
                          ?DEBUG("Adding skip dir: ~s\n", [Dir]),
                          dict:store(Dir, true, OldSkipDirs);
                      true ->
                          OldSkipDirs
                  end,
    Config#config{skip_dirs = NewSkipDirs}.

is_skip_dir(Config, Dir) ->
    dict:is_key(Dir, Config#config.skip_dirs).

reset_skip_dirs(Config) ->
    Config#config{skip_dirs = new_skip_dirs()}.

set_xconf(Config, Key, Value) ->
    NewXconf = dict:store(Key, Value, Config#config.xconf),
    Config#config{xconf=NewXconf}.

get_xconf(Config, Key) ->
    {ok, Value} = dict:find(Key, Config#config.xconf),
    Value.

get_xconf(Config, Key, Default) ->
    case dict:find(Key, Config#config.xconf) of
        error ->
            Default;
        {ok, Value} ->
            Value
    end.

erase_xconf(Config, Key) ->
    NewXconf = dict:erase(Key, Config#config.xconf),
    Config#config{xconf = NewXconf}.

command_args(#config{command_args=CmdArgs}) ->
    CmdArgs.

command_args(Config, CmdArgs) ->
    Config#config{command_args=CmdArgs}.

get_dep(#config{deps=Apps}, Name) ->
    lists:keyfind(Name, 2, Apps).

deps(#config{deps=Apps}) ->
    Apps.

deps(Config, Apps) ->
    Config#config{deps=Apps}.

deps_graph(#config{deps_graph=Graph}) ->
    Graph.

deps_graph(Config, Graph) ->
    Config#config{deps_graph=Graph}.

get_app(#config{apps_to_build=Apps}, Name) ->
    lists:keyfind(Name, 2, Apps).

apps_to_build(#config{apps_to_build=Apps}) ->
    Apps.

apps_to_build(Config, Apps) ->
    Config#config{apps_to_build=Apps}.

add_app(Config=#config{apps_to_build=Apps}, App) ->
    Config#config{apps_to_build=[App | Apps]}.

replace_app(Config=#config{apps_to_build=Apps}, Name, App) ->
    Apps1 = lists:keydelete(Name, 2, Apps),
    Config#config{apps_to_build=[App | Apps1]}.

deps_to_build(#config{deps_to_build=Apps}) ->
    Apps.

add_dep(Config=#config{deps_to_build=Apps}, App) ->
    Config#config{deps_to_build=[App | Apps]}.

providers(#config{providers=Providers}) ->
    Providers.

providers(Config, NewProviders) ->
    Config#config{providers=NewProviders}.

goals(#config{goals=Goals}) ->
    Goals.

goals(Config, Goals) ->
    Config#config{goals=Goals}.

add_provider(Config=#config{providers=Providers}, Provider) ->
    Config#config{providers=[Provider | Providers]}.

create_logic_providers(ProviderModules, State0) ->
    lists:foldl(fun(ProviderMod, Acc) ->
                        {ok, State1} = rebar_provider:new(ProviderMod, Acc),
                        State1
                end, State0, ProviderModules).

%% ===================================================================
%% Internal functions
%% ===================================================================

consult_and_eval(File, Script) ->
    ?DEBUG("Evaluating config script ~p~n", [Script]),
    ConfigData = try_consult(File),
    file:script(Script, bs([{'CONFIG', ConfigData}, {'SCRIPT', Script}])).

remove_script_ext(F) ->
    "tpircs." ++ Rev = lists:reverse(F),
    lists:reverse(Rev).

try_consult(File) ->
    case file:consult(File) of
        {ok, Terms} ->
            ?DEBUG("Consult config file ~p~n", [File]),
            Terms;
        {error, enoent} ->
            [];
        {error, Reason} ->
            ?ABORT("Failed to read config file ~s: ~p~n", [File, Reason])
    end.

bs(Vars) ->
    lists:foldl(fun({K,V}, Bs) ->
                        erl_eval:add_binding(K, V, Bs)
                end, erl_eval:new_bindings(), Vars).

new_globals() -> dict:new().

new_env() -> dict:new().

new_skip_dirs() -> dict:new().

new_xconf() -> dict:new().
