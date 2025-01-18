-module(ar_chunk_storage_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-include_lib("arweave/include/ar_sup.hrl").
-include_lib("arweave/include/ar_config.hrl").

%%%===================================================================
%%% Public interface.
%%%===================================================================

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks.
%% ===================================================================

init([]) ->
	ets:new(chunk_storage_file_index, [set, public, named_table, {read_concurrency, true}]),
	{ok, Config} = application:get_env(arweave, config),
	ConfiguredWorkers = lists:map(
		fun(StorageModule) ->
			StoreID = ar_storage_module:id(StorageModule),
			Name = ar_chunk_storage:name(StoreID),
			?CHILD_WITH_ARGS(ar_chunk_storage, worker, Name, [Name, {StoreID, none}])
		end,
		Config#config.storage_modules
	),
	DefaultChunkStorageWorker = ?CHILD_WITH_ARGS(ar_chunk_storage, worker,
		ar_chunk_storage_default, [ar_chunk_storage_default, {"default", none}]),
	RepackInPlaceWorkers = lists:map(
		fun({StorageModule, Packing}) ->
			StoreID = ar_storage_module:id(StorageModule),
            %% Note: the config validation will prevent a StoreID from being used in both
            %% `storage_modules` and `repack_in_place_storage_modules`, so there's
            %% no risk of a `Name` clash with the workers spawned above.
			Name = ar_chunk_storage:name(StoreID),
			?CHILD_WITH_ARGS(ar_chunk_storage, worker, Name, [Name, {StoreID, Packing}])
		end,
		Config#config.repack_in_place_storage_modules
	),

	EntropyStorageWorkers = lists:map(
		fun(StorageModule) ->
			StoreID = ar_storage_module:id(StorageModule),
			Name = ar_entropy_storage:name(StoreID),
			?CHILD_WITH_ARGS(ar_entropy_storage, worker, Name, [Name, StoreID])
		end,
		Config#config.storage_modules
	),
	Workers = [DefaultChunkStorageWorker] ++ ConfiguredWorkers ++ RepackInPlaceWorkers ++ EntropyStorageWorkers,
	{ok, {{one_for_one, 5, 10}, Workers}}.
