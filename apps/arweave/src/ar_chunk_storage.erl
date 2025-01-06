%% The blob storage optimized for fast reads.
-module(ar_chunk_storage).

-behaviour(gen_server).

-export([start_link/2, name/1, is_storage_supported/3, put/2, put/3,
		open_files/1, get/1, get/2, get/3,get/5, locate_chunk_on_disk/2, get_range/2, get_range/3,
		get_handle_by_filepath/1, close_file/2, close_files/1, cut/2, delete/1, delete/2, 
		list_files/2, run_defragmentation/0,
		get_storage_module_path/2, get_chunk_storage_path/2, is_prepared/1,
		get_chunk_bucket_start/1, get_chunk_bucket_end/1,
		sync_record_id/1, write_chunk/4, write_chunk2/6, record_chunk/5]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include("../include/ar.hrl").
-include("../include/ar_config.hrl").
-include("../include/ar_consensus.hrl").
-include("../include/ar_chunk_storage.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-record(state, {
	file_index,
	store_id,
	packing_map = #{},
	repack_cursor = 0,
	prev_repack_cursor = 0,
	target_packing = none,
	repacking_complete = false,
	range_start,
	range_end,
	reward_addr,
	prepare_replica_2_9_cursor,
	is_prepared = false
}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link(Name, StoreID) ->
	gen_server:start_link({local, Name}, ?MODULE, StoreID, []).

%% @doc Return the name of the server serving the given StoreID.
name(StoreID) ->
	list_to_atom("ar_chunk_storage_" ++ ar_storage_module:label_by_id(StoreID)).

%% @doc Return true if we can accept the chunk for storage.
%% 256 KiB chunks are stored in the blob storage optimized for read speed.
%% Unpacked chunks smaller than 256 KiB cannot be stored here currently,
%% because the module does not keep track of the chunk sizes - all chunks
%% are assumed to be 256 KiB.
-spec is_storage_supported(
		Offset :: non_neg_integer(),
		ChunkSize :: non_neg_integer(),
		Packing :: term()
) -> true | false.

is_storage_supported(Offset, ChunkSize, Packing) ->
	case Offset > ?STRICT_DATA_SPLIT_THRESHOLD of
		true ->
			%% All chunks above ?STRICT_DATA_SPLIT_THRESHOLD are placed in 256 KiB buckets
			%% so technically can be stored in ar_chunk_storage. However, to avoid
			%% managing padding in ar_chunk_storage for unpacked chunks smaller than 256 KiB
			%% (we do not need fast random access to unpacked chunks after
			%% ?STRICT_DATA_SPLIT_THRESHOLD anyways), we put them to RocksDB.
			Packing /= unpacked orelse ChunkSize == (?DATA_CHUNK_SIZE);
		false ->
			ChunkSize == (?DATA_CHUNK_SIZE)
	end.

%% @doc Store the chunk under the given end offset,
%% bytes Offset - ?DATA_CHUNK_SIZE, Offset - ?DATA_CHUNK_SIZE + 1, .., Offset - 1.
put(PaddedOffset, Chunk) ->
	put(PaddedOffset, Chunk, "default").

%% @doc Store the chunk under the given end offset,
%% bytes Offset - ?DATA_CHUNK_SIZE, Offset - ?DATA_CHUNK_SIZE + 1, .., Offset - 1.
put(PaddedOffset, Chunk, StoreID) ->
	GenServerID = gen_server_id(StoreID),
	case catch gen_server:call(GenServerID, {put, PaddedOffset, Chunk}, 180_000) of
		{'EXIT', {timeout, {gen_server, call, _}}} ->
			{error, timeout};
		Reply ->
			Reply
	end.

%% @doc Open all the storage files. The subsequent calls to get/1 in the
%% caller process will use the opened file descriptors.
open_files(StoreID) ->
	ets:foldl(
		fun ({{Key, ID}, Filepath}, _) when ID == StoreID ->
				case erlang:get({cfile, {Key, ID}}) of
					undefined ->
						case file:open(Filepath, [read, raw, binary]) of
							{ok, F} ->
								erlang:put({cfile, {Key, ID}}, F);
							_ ->
								ok
						end;
					_ ->
						ok
				end;
			(_, _) ->
				ok
		end,
		ok,
		chunk_storage_file_index
	).

%% @doc Return {AbsoluteEndOffset, Chunk} for the chunk containing the given byte.
get(Byte) ->
	get(Byte, "default").

%% @doc Return {AbsoluteEndOffset, Chunk} for the chunk containing the given byte.
get(Byte, StoreID) ->
	case ar_sync_record:get_interval(Byte + 1, ar_chunk_storage, StoreID) of
		not_found ->
			not_found;
		{_End, IntervalStart} ->
			get(Byte, IntervalStart, StoreID)
	end.

get(Byte, IntervalStart, StoreID) ->
	%% The synced ranges begin at IntervalStart => the chunk
	%% should begin at a multiple of ?DATA_CHUNK_SIZE to the right of IntervalStart.
	ChunkStart = Byte - (Byte - IntervalStart) rem ?DATA_CHUNK_SIZE,
	ChunkFileStart = get_chunk_file_start_by_start_offset(ChunkStart),
	case get(Byte, ChunkStart, ChunkFileStart, StoreID, 1) of
		[] ->
			not_found;
		[{EndOffset, Chunk}] ->
			{EndOffset, Chunk}
	end.

locate_chunk_on_disk(PaddedEndOffset, StoreID) ->
	locate_chunk_on_disk(PaddedEndOffset, StoreID, #{}).

locate_chunk_on_disk(PaddedEndOffset, StoreID, FileIndex) ->
	ChunkFileStart = get_chunk_file_start(PaddedEndOffset),
	Filepath = filepath(ChunkFileStart, FileIndex, StoreID),
	{Position, ChunkOffset} =
        get_position_and_relative_chunk_offset(ChunkFileStart, PaddedEndOffset),
	{ChunkFileStart, Filepath, Position, ChunkOffset}.

%% @doc Return a list of {AbsoluteEndOffset, Chunk} pairs for the stored chunks
%% inside the given range. The given interval does not have to cover every chunk
%% completely - we return all chunks at the intersection with the range.
get_range(Start, Size) ->
	get_range(Start, Size, "default").

%% @doc Return a list of {AbsoluteEndOffset, Chunk} pairs for the stored chunks
%% inside the given range. The given interval does not have to cover every chunk
%% completely - we return all chunks at the intersection with the range. The
%% very last chunk might be outside of the interval - its start offset is
%% at most Start + Size + ?DATA_CHUNK_SIZE - 1.
get_range(Start, Size, StoreID) ->
	?assert(Size < get_chunk_group_size()),
	case ar_sync_record:get_next_synced_interval(Start, infinity, ar_chunk_storage, StoreID) of
		{_End, IntervalStart} when Start + Size > IntervalStart ->
			Start2 = max(Start, IntervalStart),
			Size2 = Start + Size - Start2,
			ChunkStart = Start2 - (Start2 - IntervalStart) rem ?DATA_CHUNK_SIZE,
			ChunkFileStart = get_chunk_file_start_by_start_offset(ChunkStart),
			End = Start2 + Size2,
			LastChunkStart = (End - 1) - ((End - 1) - IntervalStart) rem ?DATA_CHUNK_SIZE,
			LastChunkFileStart = get_chunk_file_start_by_start_offset(LastChunkStart),
			ChunkCount = (LastChunkStart - ChunkStart) div ?DATA_CHUNK_SIZE + 1,
			case ChunkFileStart /= LastChunkFileStart of
				false ->
					%% All chunks are from the same chunk file.
					get(Start2, ChunkStart, ChunkFileStart, StoreID, ChunkCount);
				true ->
					SizeBeforeBorder = ChunkFileStart + get_chunk_group_size() - ChunkStart,
					ChunkCountBeforeBorder = SizeBeforeBorder div ?DATA_CHUNK_SIZE
							+ case SizeBeforeBorder rem ?DATA_CHUNK_SIZE of 0 -> 0; _ -> 1 end,
					StartAfterBorder = ChunkStart + ChunkCountBeforeBorder * ?DATA_CHUNK_SIZE,
					SizeAfterBorder = Size2 - ChunkCountBeforeBorder * ?DATA_CHUNK_SIZE
							+ (Start2 - ChunkStart),
					get(Start2, ChunkStart, ChunkFileStart, StoreID, ChunkCountBeforeBorder)
						++ get_range(StartAfterBorder, SizeAfterBorder, StoreID)
			end;
		_ ->
			[]
	end.

%% @doc Close the file with the given Key.
close_file(Key, StoreID) ->
	case erlang:erase({cfile, {Key, StoreID}}) of
		undefined ->
			ok;
		F ->
			file:close(F)
	end.

%% @doc Close the files opened by open_files/1.
close_files(StoreID) ->
	close_files(erlang:get_keys(), StoreID).

%% @doc Soft-delete everything above the given end offset.
cut(Offset, StoreID) ->
	ar_sync_record:cut(Offset, ar_chunk_storage, StoreID).

%% @doc Remove the chunk with the given end offset.
delete(Offset) ->
	delete(Offset, "default").

%% @doc Remove the chunk with the given end offset.
delete(PaddedOffset, StoreID) ->
	GenServerID = gen_server_id(StoreID),
	case catch gen_server:call(GenServerID, {delete, PaddedOffset}, 20000) of
		{'EXIT', {timeout, {gen_server, call, _}}} ->
			{error, timeout};
		Reply ->
			Reply
	end.

%% @doc Run defragmentation of chunk files if enabled
run_defragmentation() ->
	{ok, Config} = application:get_env(arweave, config),
	case Config#config.run_defragmentation of
		false ->
			ok;
		true ->
			ar:console("Defragmentation threshold: ~B bytes.~n",
					   [Config#config.defragmentation_trigger_threshold]),
			DefragModules = modules_to_defrag(Config),
			Sizes = read_chunks_sizes(Config#config.data_dir),
			Files = files_to_defrag(DefragModules,
									Config#config.data_dir,
									Config#config.defragmentation_trigger_threshold,
									Sizes),
			ok = defrag_files(Files),
			ok = update_sizes_file(Files, #{})
	end.

get_storage_module_path(DataDir, "default") ->
	DataDir;
get_storage_module_path(DataDir, StoreID) ->
	filename:join([DataDir, "storage_modules", StoreID]).

get_chunk_storage_path(DataDir, StoreID) ->
	filename:join([get_storage_module_path(DataDir, StoreID), ?CHUNK_DIR]).
%% @doc Return true if the storage is ready to accept chunks.
-spec is_prepared(StoreID :: string()) -> true | false.
is_prepared(StoreID) ->
	GenServerID = gen_server_id(StoreID),
	case catch gen_server:call(GenServerID, is_prepared) of
		{'EXIT', {noproc, {gen_server, call, _}}} ->
			{error, timeout};
		{'EXIT', {timeout, {gen_server, call, _}}} ->
			{error, timeout};
		Reply ->
			Reply
	end.

%% @doc Return the start offset of the bucket containing the given offset.
%% A chunk bucket a 0-based, 256-KiB wide, 256-KiB aligned range that fully contains a chunk.
-spec get_chunk_bucket_start(PaddedEndOffset :: non_neg_integer()) -> non_neg_integer().
get_chunk_bucket_start(PaddedEndOffset) ->
	ar_util:floor_int(max(0, PaddedEndOffset - ?DATA_CHUNK_SIZE), ?DATA_CHUNK_SIZE).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init({"default" = StoreID, _}) ->
	%% Trap exit to avoid corrupting any open files on quit..
	process_flag(trap_exit, true),
	{ok, Config} = application:get_env(arweave, config),
	DataDir = Config#config.data_dir,
	Dir = get_storage_module_path(DataDir, StoreID),
	ok = filelib:ensure_dir(Dir ++ "/"),
	ok = filelib:ensure_dir(filename:join(Dir, ?CHUNK_DIR) ++ "/"),
	FileIndex = read_file_index(Dir),
	FileIndex2 = maps:map(
		fun(Key, Filepath) ->
			Filepath2 = filename:join([DataDir, ?CHUNK_DIR, Filepath]),
			ets:insert(chunk_storage_file_index, {{Key, StoreID}, Filepath2}),
			Filepath2
		end,
		FileIndex
	),
	warn_custom_chunk_group_size(StoreID),
	{ok, #state{ file_index = FileIndex2, store_id = StoreID }};
init({StoreID, RepackInPlacePacking}) ->
	%% Trap exit to avoid corrupting any open files on quit..
	process_flag(trap_exit, true),
	{ok, Config} = application:get_env(arweave, config),
	DataDir = Config#config.data_dir,
	Dir = get_storage_module_path(DataDir, StoreID),
	ok = filelib:ensure_dir(Dir ++ "/"),
	ok = filelib:ensure_dir(filename:join(Dir, ?CHUNK_DIR) ++ "/"),
	FileIndex = read_file_index(Dir),
	FileIndex2 = maps:map(
		fun(Key, Filepath) ->
			ets:insert(chunk_storage_file_index, {{Key, StoreID}, Filepath}),
			Filepath
		end,
		FileIndex
	),
	warn_custom_chunk_group_size(StoreID),
	{RangeStart, RangeEnd} = ar_storage_module:get_range(StoreID),
	State = #state{ file_index = FileIndex2, store_id = StoreID,
			range_start = RangeStart, range_end = RangeEnd },
	RunEntropyProcess =
		case RepackInPlacePacking of
			none ->
				case ar_storage_module:get_packing(StoreID) of
					{replica_2_9, Addr} ->
						{true, Addr};
					_ ->
						false
				end;
			{replica_2_9, Addr} ->
				{true, Addr};
			_ ->
				false
		end,
	State2 =
		case RunEntropyProcess of
			{true, RewardAddr} ->
				PrepareCursor = {Start, _SubChunkStart} = 
					read_prepare_replica_2_9_cursor(StoreID, {RangeStart + 1, 0}),
				IsPrepared =
					case Start =< RangeEnd of
						true ->
							gen_server:cast(self(), prepare_replica_2_9),
							false;
						false ->
							true
					end,
				State#state{ reward_addr = RewardAddr,
						prepare_replica_2_9_cursor = PrepareCursor,
						is_prepared = IsPrepared };
			_ ->
				State#state{ is_prepared = true }
		end,
	case RepackInPlacePacking of
		none ->
			{ok, State2#state{ repack_cursor = none }};
		Packing ->
			Cursor = read_repack_cursor(StoreID, Packing, RangeStart),
			gen_server:cast(self(), {repack, Packing}),
			?LOG_INFO([{event, starting_repack_in_place},
					{tags, [repack_in_place]},
					{cursor, Cursor},
					{store_id, StoreID},
					{target_packing, ar_serialize:encode_packing(Packing, true)}]),
			{ok, State2#state{ repack_cursor = Cursor, target_packing = Packing }}
	end.

warn_custom_chunk_group_size(StoreID) ->
	case StoreID == "default" andalso get_chunk_group_size() /= ?CHUNK_GROUP_SIZE of
		true ->
			%% This warning applies to all store ids, but we will only print it when loading
			%% the default StoreID to ensure it is only printed once.
			WarningMessage = "WARNING: changing chunk_storage_file_size is not "
				"recommended and may cause errors if different sizes are used for the same "
				"chunk storage files.",
			ar:console(WarningMessage),
			?LOG_WARNING(WarningMessage);
		false ->
			ok
	end.

handle_cast(prepare_replica_2_9, #state{ store_id = StoreID } = State) ->
	case try_acquire_replica_2_9_formatting_lock(StoreID) of
		true ->
			?LOG_DEBUG([{event, acquired_replica_2_9_formatting_lock}, {store_id, StoreID}]),
			gen_server:cast(self(), do_prepare_replica_2_9);
		false ->
			?LOG_DEBUG([{event, failed_to_acquire_replica_2_9_formatting_lock}, {store_id, StoreID}]),
			ar_util:cast_after(2000, self(), prepare_replica_2_9)
	end,
	{noreply, State};

handle_cast(do_prepare_replica_2_9, State) ->
	#state{ reward_addr = RewardAddr, prepare_replica_2_9_cursor = {Start, SubChunkStart},
			range_start = RangeStart, range_end = RangeEnd,
			store_id = StoreID, repack_cursor = RepackCursor } = State,
	
	PaddedEndOffset = get_chunk_bucket_end(ar_block:get_chunk_padded_offset(Start)),
	PaddedRangeEnd = get_chunk_bucket_end(ar_block:get_chunk_padded_offset(RangeEnd)),
	%% Sanity checks:
	PaddedEndOffset = get_chunk_bucket_end(PaddedEndOffset),
	true = (
		max(0, PaddedEndOffset - ?DATA_CHUNK_SIZE) == get_chunk_bucket_start(PaddedEndOffset)
	),
	%% End of sanity checks.

	Partition = ar_replica_2_9:get_entropy_partition(PaddedEndOffset),
	CheckRangeEnd =
		case PaddedEndOffset > PaddedRangeEnd of
			true ->
				release_replica_2_9_formatting_lock(StoreID),
				?LOG_INFO([{event, storage_module_replica_2_9_preparation_complete},
						{store_id, StoreID}]),
				ar:console("The storage module ~s is prepared for 2.9 replication.~n",
						[StoreID]),
				complete;
			false ->
				false
		end,
	%% For now the SubChunkStart and SubChunkStart2 values will always be 0. The field
	%% is used to make future improvemets easier. e.g. have the cursor increment by
	%% sub-chunk rather than chunk.
	SubChunkStart2 = (SubChunkStart + ?DATA_CHUNK_SIZE) rem ?DATA_CHUNK_SIZE,
	Start2 = PaddedEndOffset + ?DATA_CHUNK_SIZE,
	Cursor2 = {Start2, SubChunkStart2},
	State2 = State#state{ prepare_replica_2_9_cursor = Cursor2 },
	CheckRepackCursor =
		case CheckRangeEnd of
			complete ->
				complete;
			false ->
				case RepackCursor of
					none ->
						false;
					_ ->
						SectorSize = ar_replica_2_9:get_sector_size(),
						RangeStart2 = get_chunk_bucket_start(RangeStart + 1),
						RepackCursor2 = get_chunk_bucket_start(RepackCursor + 1),
						RepackSectorShift = (RepackCursor2 - RangeStart2) rem SectorSize,
						SectorShift = (PaddedEndOffset - RangeStart2) rem SectorSize,
						case SectorShift > RepackSectorShift of
							true ->
								waiting_for_repack;
							false ->
								false
						end
				end
		end,
	CheckIsRecorded =
		case CheckRepackCursor of
			complete ->
				complete;
			waiting_for_repack ->
				waiting_for_repack;
			false ->
				ar_entropy_storage:is_sub_chunk_recorded(
					PaddedEndOffset, SubChunkStart, StoreID)
		end,
	StoreEntropy =
		case CheckIsRecorded of
			complete ->
				complete;
			waiting_for_repack ->
				waiting_for_repack;
			true ->
				is_recorded;
			false ->
				%% Get all the entropies needed to encipher the chunk at PaddedEndOffset.
				Entropies = ar_entropy_storage:generate_entropies(RewardAddr, PaddedEndOffset, SubChunkStart),
				EntropyKeys = ar_entropy_storage:generate_entropy_keys(
					RewardAddr, PaddedEndOffset, SubChunkStart),
				SliceIndex = ar_replica_2_9:get_slice_index(PaddedEndOffset),
				%% If we are not at the beginning of the entropy, shift the offset to
				%% the left. store_entropy will traverse the entire 2.9 partition shifting
				%% the offset by sector size. It may happen some sub-chunks will be written
				%% to the neighbouring storage module(s) on the left or on the right
				%% since the storage module may be configured to be smaller than the
				%% partition.
				PaddedEndOffset2 = ar_entropy_storage:shift_entropy_offset(
					PaddedEndOffset, -SliceIndex),
				%% The end of a recall partition (3.6TB) may fall in the middle of a chunk, so
				%% we'll use the padded offset to end the store_entropy iteration.
				PartitionEnd = (Partition + 1) * ?PARTITION_SIZE,
				PaddedPartitionEnd =
					get_chunk_bucket_end(ar_block:get_chunk_padded_offset(PartitionEnd)),
				ar_entropy_storage:store_entropy(Entropies, PaddedEndOffset2, SubChunkStart, PaddedPartitionEnd,
						EntropyKeys, RewardAddr, 0, 0)
		end,
	?LOG_DEBUG([{event, do_prepare_replica_2_9}, {store_id, StoreID},
			{start, Start}, {padded_end_offset, PaddedEndOffset},
			{range_end, RangeEnd}, {padded_range_end, PaddedRangeEnd},
			{sub_chunk_start, SubChunkStart},
			{check_is_recorded, CheckIsRecorded}, {store_entropy, StoreEntropy}]),
	case StoreEntropy of
		complete ->
			{noreply, State#state{ is_prepared = true }};
		waiting_for_repack ->
			?LOG_INFO([{event, waiting_for_repacking},
					{store_id, StoreID},
					{padded_end_offset, PaddedEndOffset},
					{repack_cursor, RepackCursor},
					{cursor, Start},
					{range_start, RangeStart},
					{range_end, RangeEnd}]),
			ar_util:cast_after(10000, self(), do_prepare_replica_2_9),
			{noreply, State};
		is_recorded ->
			gen_server:cast(self(), do_prepare_replica_2_9),
			{noreply, State2};
		{error, Error} ->
			?LOG_WARNING([{event, failed_to_store_replica_2_9_entropy},
					{cursor, Start},
					{store_id, StoreID},
					{reason, io_lib:format("~p", [Error])}]),
			ar_util:cast_after(500, self(), do_prepare_replica_2_9),
			{noreply, State};
		{ok, SubChunksStored} ->
			?LOG_DEBUG([{event, stored_replica_2_9_entropy},
					{sub_chunks_stored, SubChunksStored},
					{store_id, StoreID},
					{cursor, Start},
					{padded_end_offset, PaddedEndOffset}]),
			gen_server:cast(self(), do_prepare_replica_2_9),
			case store_prepare_replica_2_9_cursor(Cursor2, StoreID) of
				ok ->
					ok;
				{error, Error} ->
					?LOG_WARNING([{event, failed_to_store_prepare_replica_2_9_cursor},
							{chunk_cursor, Start2},
							{sub_chunk_cursor, SubChunkStart2},
							{store_id, StoreID},
							{reason, io_lib:format("~p", [Error])}])
			end,
			{noreply, State2}
	end;

handle_cast(store_repack_cursor, #state{ repacking_complete = true } = State) ->
	{noreply, State};
handle_cast(store_repack_cursor,
		#state{ repack_cursor = Cursor, prev_repack_cursor = Cursor } = State) ->
	{noreply, State};
handle_cast(store_repack_cursor,
		#state{ repack_cursor = Cursor, store_id = StoreID,
				target_packing = TargetPacking } = State) ->
	ar:console("Repacked up to ~p, scanning further..~n", [Cursor]),
	?LOG_INFO([{event, repacked_partially},
			{tags, [repack_in_place]},
			{storage_module, StoreID}, {cursor, Cursor}]),
	store_repack_cursor(Cursor, StoreID, TargetPacking),
	{noreply, State#state{ prev_repack_cursor = Cursor }};

handle_cast(repacking_complete, State) ->
	{noreply, State#state{ repacking_complete = true }};

handle_cast({repack, Packing},
		#state{ store_id = StoreID, repack_cursor = Cursor,
				range_start = RangeStart, range_end = RangeEnd } = State) ->
	spawn(fun() -> repack(Cursor, RangeStart, RangeEnd, Packing, StoreID) end),
	{noreply, State};

handle_cast({repack, Cursor, RangeStart, RangeEnd, Packing},
		#state{ store_id = StoreID } = State) ->
	gen_server:cast(self(), store_repack_cursor),
	spawn(fun() -> repack(Cursor, RangeStart, RangeEnd, Packing, StoreID) end),
	{noreply, State#state{ repack_cursor = Cursor }};

handle_cast({register_packing_ref, Ref, Args}, #state{ packing_map = Map } = State) ->
	{noreply, State#state{ packing_map = maps:put(Ref, Args, Map) }};

handle_cast({expire_repack_request, Ref}, #state{ packing_map = Map } = State) ->
	{noreply, State#state{ packing_map = maps:remove(Ref, Map) }};

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_call(is_prepared, _From, #state{ is_prepared = IsPrepared } = State) ->
	{reply, IsPrepared, State};

handle_call({put, PaddedEndOffset, Chunk}, _From, State)
		when byte_size(Chunk) == ?DATA_CHUNK_SIZE ->
	case handle_store_chunk(PaddedEndOffset, Chunk, State) of
		{ok, FileIndex2, Packing} ->
			{reply, {ok, Packing}, State#state{ file_index = FileIndex2 }};
		Error ->
			{reply, Error, State}
	end;

handle_call({delete, PaddedEndOffset}, _From, State) ->
	#state{	file_index = FileIndex, store_id = StoreID } = State,
	StartOffset = PaddedEndOffset - ?DATA_CHUNK_SIZE,
	case ar_sync_record:delete(PaddedEndOffset, StartOffset, ar_chunk_storage, StoreID) of
		ok ->
			case ar_entropy_storage:delete_record(PaddedEndOffset, StoreID) of
				ok ->
					case delete_chunk(PaddedEndOffset, StoreID) of
						ok ->
							{reply, ok, State};
						Error ->
							{reply, Error, State}
					end;
				Error2 ->
					{reply, Error2, State}
			end;
		Error3 ->
			{reply, Error3, State}
	end;

handle_call(reset, _, #state{ store_id = StoreID, file_index = FileIndex } = State) ->
	maps:map(
		fun(_Key, Filepath) ->
			file:delete(Filepath)
		end,
		FileIndex
	),
	ok = ar_sync_record:cut(0, ar_chunk_storage, StoreID),
	erlang:erase(),
	{reply, ok, State#state{ file_index = #{} }};

handle_call(Request, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {request, Request}]),
	{reply, ok, State}.

handle_info({chunk, {packed, Ref, ChunkArgs}},
	#state{ packing_map = Map, store_id = StoreID, repack_cursor = PrevCursor } = State) ->
	case maps:get(Ref, Map, not_found) of
		not_found ->
			{noreply, State};
		Args ->
			State2 = State#state{ packing_map = maps:remove(Ref, Map) },
			{Packing, Chunk, Offset, _, ChunkSize} = ChunkArgs,
			PaddedEndOffset = ar_block:get_chunk_padded_offset(Offset),
			StartOffset = PaddedEndOffset - ?DATA_CHUNK_SIZE,
			RemoveFromSyncRecordResult = ar_sync_record:delete(PaddedEndOffset,
					StartOffset, ar_data_sync, StoreID),
			IsStorageSupported =
				case RemoveFromSyncRecordResult of
					ok ->
						is_storage_supported(PaddedEndOffset, ChunkSize, Packing);
					Error ->
						Error
				end,
			RemoveFromChunkStorageSyncRecordResult =
				case IsStorageSupported of
					true ->
						store;
					false ->
						%% Based on the new packing we do not want to
						%% store the chunk in the chunk storage anymore so
						%% we also remove the record from the
						%% chunk-storage specific sync record and
						%% send the chunk to the corresponding ar_data_sync
						%% module to store it in RocksDB.
						ar_sync_record:delete(PaddedEndOffset, StartOffset,
								ar_chunk_storage, StoreID);
					Error2 ->
						Error2
				end,
			case RemoveFromChunkStorageSyncRecordResult of
				ok ->
					DataSyncServer = ar_data_sync:name(StoreID),
					gen_server:cast(DataSyncServer,
							{store_chunk, ChunkArgs, Args}),
					{noreply, State2#state{ repack_cursor = PaddedEndOffset,
							prev_repack_cursor = PrevCursor }};
				store ->
					case handle_store_chunk(PaddedEndOffset, Chunk, State2) of
						{ok, FileIndex2, NewPacking} ->
							ar_sync_record:add_async(repacked_chunk,
									PaddedEndOffset, StartOffset,
									NewPacking, ar_data_sync, StoreID),
							{noreply, State2#state{ file_index = FileIndex2,
									repack_cursor = PaddedEndOffset,
									prev_repack_cursor = PrevCursor }};
						Error3 ->
							PackingStr = ar_serialize:encode_packing(Packing, true),
							?LOG_ERROR([{event, failed_to_store_repacked_chunk},
									{type, repack_in_place},
									{storage_module, StoreID},
									{padded_end_offset, PaddedEndOffset},
									{packing, PackingStr},
									{error, io_lib:format("~p", [Error3])}]),
							{noreply, State2}
					end;
				Error4 ->
					PackingStr = ar_serialize:encode_packing(Packing, true),
					?LOG_ERROR([{event, failed_to_store_repacked_chunk},
							{type, repack_in_place},
							{storage_module, StoreID},
							{padded_end_offset, PaddedEndOffset},
							{packing, PackingStr},
							{error, io_lib:format("~p", [Error4])}]),
					{noreply, State2}
			end
	end;

handle_info({Ref, _Reply}, State) when is_reference(Ref) ->
	%% A stale gen_server:call reply.
	{noreply, State};

handle_info({'EXIT', _PID, normal}, State) ->
	{noreply, State};

handle_info(Info, State) ->
	?LOG_ERROR([{event, unhandled_info}, {info, io_lib:format("~p", [Info])}]),
	{noreply, State}.

terminate(_Reason, #state{ repack_cursor = Cursor, store_id = StoreID,
		target_packing = TargetPacking }) ->
	sync_and_close_files(),
	store_repack_cursor(Cursor, StoreID, TargetPacking),
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

get_chunk_group_size() ->
	{ok, Config} = application:get_env(arweave, config),
	Config#config.chunk_storage_file_size.

read_repack_cursor(StoreID, TargetPacking, RangeStart) ->
	Filepath = get_filepath("repack_in_place_cursor2", StoreID),
	case file:read_file(Filepath) of
		{ok, Bin} ->
			case catch binary_to_term(Bin) of
				{Cursor, TargetPacking} when is_integer(Cursor) ->
					Cursor;
				_ ->
					get_chunk_bucket_start(RangeStart + 1)
			end;
		_ ->
			get_chunk_bucket_start(RangeStart + 1)
	end.

read_prepare_replica_2_9_cursor(StoreID, Default) ->
	Filepath = get_filepath("prepare_replica_2_9_cursor", StoreID),
	case file:read_file(Filepath) of
		{ok, Bin} ->
			case catch binary_to_term(Bin) of
				{ChunkCursor, SubChunkCursor} = Cursor
						when is_integer(ChunkCursor), is_integer(SubChunkCursor) ->
					Cursor;
				_ ->
					Default
			end;
		_ ->
			Default
	end.

store_repack_cursor(none, _StoreID, _TargetPacking) ->
	ok;
store_repack_cursor(Cursor, StoreID, TargetPacking) ->
	Filepath = get_filepath("repack_in_place_cursor2", StoreID),
	file:write_file(Filepath, term_to_binary({Cursor, TargetPacking})).

store_prepare_replica_2_9_cursor(Cursor, StoreID) ->
	Filepath = get_filepath("prepare_replica_2_9_cursor", StoreID),
	file:write_file(Filepath, term_to_binary(Cursor)).

get_filepath(Name, StoreID) ->
	{ok, Config} = application:get_env(arweave, config),
	DataDir = Config#config.data_dir,
	ChunkDir = get_chunk_storage_path(DataDir, StoreID),
	filename:join([ChunkDir, Name]).

handle_store_chunk(PaddedEndOffset, Chunk, State) ->
	#state{ store_id = StoreID, is_prepared = IsPrepared, file_index = FileIndex } = State,
	Packing = ar_storage_module:get_packing(StoreID),
	case Packing of
		{replica_2_9, Addr} ->
			ar_entropy_storage:record_chunk(PaddedEndOffset, Chunk, Addr, StoreID, FileIndex, IsPrepared);
		_ ->
			record_chunk(PaddedEndOffset, Chunk, Packing, StoreID, FileIndex)
	end.

record_chunk(PaddedEndOffset, Chunk, Packing, StoreID, FileIndex) ->
	case write_chunk(PaddedEndOffset, Chunk, FileIndex, StoreID) of
		{ok, Filepath} ->
			prometheus_counter:inc(chunks_stored, [Packing]),
			case ar_sync_record:add(
					PaddedEndOffset, PaddedEndOffset - ?DATA_CHUNK_SIZE,
					sync_record_id(Packing), StoreID) of
				ok ->
					ChunkFileStart = get_chunk_file_start(PaddedEndOffset),
					ets:insert(chunk_storage_file_index,
						{{ChunkFileStart, StoreID}, Filepath}),
					{ok, maps:put(ChunkFileStart, Filepath, FileIndex), Packing};
				Error ->
					Error
			end;
		Error2 ->
			Error2
	end.

sync_record_id(unpacked_padded) ->
	%% Entropy indexing changed between 2.9.0 and 2.9.1. So we'll use a new
	%% sync_record id (ar_chunk_storage_replica_2_9_1_unpacked) going forward.
	%% The old id (ar_chunk_storage_replica_2_9_unpacked) should not be used.
	ar_chunk_storage_replica_2_9_1_unpacked;
sync_record_id(_Packing) ->
	ar_chunk_storage.

get_chunk_file_start(EndOffset) ->
	StartOffset = EndOffset - ?DATA_CHUNK_SIZE,
	get_chunk_file_start_by_start_offset(StartOffset).

get_chunk_file_start_by_start_offset(StartOffset) ->
	ar_util:floor_int(StartOffset, get_chunk_group_size()).

get_chunk_bucket_end(PaddedEndOffset) ->
	get_chunk_bucket_start(PaddedEndOffset) + ?DATA_CHUNK_SIZE.

write_chunk(PaddedOffset, Chunk, FileIndex, StoreID) ->
	{_ChunkFileStart, Filepath, Position, ChunkOffset} =
		locate_chunk_on_disk(PaddedOffset, StoreID, FileIndex),
	case get_handle_by_filepath(Filepath) of
		{error, _} = Error ->
			Error;
		F ->
			write_chunk2(PaddedOffset, ChunkOffset, Chunk, Filepath, F, Position)
	end.

filepath(ChunkFileStart, FileIndex, StoreID) ->
	case maps:get(ChunkFileStart, FileIndex, not_found) of
		not_found ->
			filepath(ChunkFileStart, StoreID);
		Filepath ->
			Filepath
	end.

filepath(ChunkFileStart, StoreID) ->
	get_filepath(integer_to_binary(ChunkFileStart), StoreID).

get_handle_by_filepath(Filepath) ->
	case erlang:get({write_handle, Filepath}) of
		undefined ->
			case file:open(Filepath, [read, write, raw]) of
				{error, Reason} = Error ->
					?LOG_ERROR([
						{event, failed_to_open_chunk_file},
						{file, Filepath},
						{reason, io_lib:format("~p", [Reason])}
					]),
					Error;
				{ok, F} ->
					erlang:put({write_handle, Filepath}, F),
					F
			end;
		F ->
			F
	end.

write_chunk2(PaddedOffset, ChunkOffset, Chunk, Filepath, F, Position) ->
	ChunkOffsetBinary =
		case ChunkOffset of
			0 ->
				ZeroOffset = get_special_zero_offset(),
				%% Represent 0 as the largest possible offset plus one,
				%% to distinguish zero offset from not yet written data.
				<< ZeroOffset:?OFFSET_BIT_SIZE >>;
			_ ->
				<< ChunkOffset:?OFFSET_BIT_SIZE >>
		end,
	Result = file:pwrite(F, Position, [ChunkOffsetBinary | Chunk]),
	case Result of
		{error, Reason} = Error ->
			?LOG_ERROR([
				{event, failed_to_write_chunk},
				{padded_offset, PaddedOffset},
				{file, Filepath},
				{position, Position},
				{reason, io_lib:format("~p", [Reason])}
			]),
			Error;
		ok ->
			{ok, Filepath}
	end.

get_special_zero_offset() ->
	?DATA_CHUNK_SIZE.

get_position_and_relative_chunk_offset(ChunkFileStart, Offset) ->
	BucketPickOffset = Offset - ?DATA_CHUNK_SIZE,
	get_position_and_relative_chunk_offset_by_start_offset(ChunkFileStart, BucketPickOffset).

get_position_and_relative_chunk_offset_by_start_offset(ChunkFileStart, BucketPickOffset) ->
	BucketStart = ar_util:floor_int(BucketPickOffset, ?DATA_CHUNK_SIZE),
	ChunkOffset = BucketPickOffset - BucketStart,
	RelativeOffset = BucketStart - ChunkFileStart,
	Position = RelativeOffset + ?OFFSET_SIZE * (RelativeOffset div ?DATA_CHUNK_SIZE),
	{Position, ChunkOffset}.

delete_chunk(PaddedOffset, StoreID) ->
	{_ChunkFileStart, Filepath, Position, _ChunkOffset} =
		locate_chunk_on_disk(PaddedOffset, StoreID),
	case file:open(Filepath, [read, write, raw]) of
		{ok, F} ->
			ZeroChunk =
				case erlang:get(zero_chunk) of
					undefined ->
						OffsetBytes = << 0:?OFFSET_BIT_SIZE >>,
						ZeroBytes = << <<0>> || _ <- lists:seq(1, ?DATA_CHUNK_SIZE) >>,
						Chunk = << OffsetBytes/binary, ZeroBytes/binary >>,
						%% Cache the zero chunk in the process memory, constructing
						%% it is expensive.
						erlang:put(zero_chunk, Chunk),
						Chunk;
					Chunk ->
						Chunk
				end,
			ar_entropy_storage:acquire_semaphore(Filepath),
			Result = file:pwrite(F, Position, ZeroChunk),
			ar_entropy_storage:release_semaphore(Filepath),
			Result;
		{error, enoent} ->
			ok;
		Error ->
			Error
	end.

get(Byte, Start, ChunkFileStart, StoreID, ChunkCount) ->
	case erlang:get({cfile, {ChunkFileStart, StoreID}}) of
		undefined ->
			case ets:lookup(chunk_storage_file_index, {ChunkFileStart, StoreID}) of
				[] ->
					[];
				[{_, Filepath}] ->
					read_chunk(Byte, Start, ChunkFileStart, Filepath, ChunkCount)
			end;
		File ->
			read_chunk2(Byte, Start, ChunkFileStart, File, ChunkCount)
	end.

read_chunk(Byte, Start, ChunkFileStart, Filepath, ChunkCount) ->
	case file:open(Filepath, [read, raw, binary]) of
		{error, enoent} ->
			[];
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_open_chunk_file},
				{byte, Byte},
				{reason, io_lib:format("~p", [Reason])}
			]),
			[];
		{ok, File} ->
			Result = read_chunk2(Byte, Start, ChunkFileStart, File, ChunkCount),
			file:close(File),
			Result
	end.

read_chunk2(Byte, Start, ChunkFileStart, File, ChunkCount) ->
	{Position, _ChunkOffset} =
			get_position_and_relative_chunk_offset_by_start_offset(ChunkFileStart, Start),
	BucketStart = ar_util:floor_int(Start, ?DATA_CHUNK_SIZE),
	read_chunk3(Byte, Position, BucketStart, File, ChunkCount).

read_chunk3(Byte, Position, BucketStart, File, ChunkCount) ->
	case file:pread(File, Position, (?DATA_CHUNK_SIZE + ?OFFSET_SIZE) * ChunkCount) of
		{ok, << ChunkOffset:?OFFSET_BIT_SIZE, _Chunk/binary >> = Bin} ->
			case is_offset_valid(Byte, BucketStart, ChunkOffset) of
				true ->
					extract_end_offset_chunk_pairs(Bin, BucketStart, 1);
				false ->
					[]
			end;
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_read_chunk},
				{byte, Byte},
				{position, Position},
				{reason, io_lib:format("~p", [Reason])}
			]),
			[];
		eof ->
			[]
	end.

extract_end_offset_chunk_pairs(
		<< 0:?OFFSET_BIT_SIZE, _ZeroChunk:?DATA_CHUNK_SIZE/binary, Rest/binary >>,
		BucketStart,
		Shift
 ) ->
	extract_end_offset_chunk_pairs(Rest, BucketStart, Shift + 1);
extract_end_offset_chunk_pairs(
		<< ChunkOffset:?OFFSET_BIT_SIZE, Chunk:?DATA_CHUNK_SIZE/binary, Rest/binary >>,
		BucketStart,
		Shift
 ) ->
	ChunkOffsetLimit = ?DATA_CHUNK_SIZE,
	EndOffset =
		BucketStart
		+ (ChunkOffset rem ChunkOffsetLimit)
		+ (?DATA_CHUNK_SIZE * Shift),
	[{EndOffset, Chunk}
			| extract_end_offset_chunk_pairs(Rest, BucketStart, Shift + 1)];
extract_end_offset_chunk_pairs(<<>>, _BucketStart, _Shift) ->
	[].

is_offset_valid(_Byte, _BucketStart, 0) ->
	%% 0 is interpreted as "data has not been written yet".
	false;
is_offset_valid(Byte, BucketStart, ChunkOffset) ->
	Delta = Byte - (BucketStart + ChunkOffset rem ?DATA_CHUNK_SIZE),
	Delta >= 0 andalso Delta < ?DATA_CHUNK_SIZE.

close_files([{cfile, {_, StoreID} = Key} | Keys], StoreID) ->
	file:close(erlang:get({cfile, Key})),
	close_files(Keys, StoreID);
close_files([_ | Keys], StoreID) ->
	close_files(Keys, StoreID);
close_files([], _StoreID) ->
	ok.

read_file_index(Dir) ->
	ChunkDir = filename:join(Dir, ?CHUNK_DIR),
	{ok, Filenames} = file:list_dir(ChunkDir),
	lists:foldl(
		fun(Filename, Acc) ->
			case catch list_to_integer(Filename) of
				Key when is_integer(Key) ->
					maps:put(Key, filename:join(ChunkDir, Filename), Acc);
				_ ->
					Acc
			end
		end,
		#{},
		Filenames
	).

sync_and_close_files() ->
	sync_and_close_files(erlang:get_keys()).

sync_and_close_files([{write_handle, _} = Key | Keys]) ->
	F = erlang:get(Key),
	ok = file:sync(F),
	file:close(F),
	sync_and_close_files(Keys);
sync_and_close_files([_ | Keys]) ->
	sync_and_close_files(Keys);
sync_and_close_files([]) ->
	ok.

list_files(DataDir, StoreID) ->
	Dir = get_storage_module_path(DataDir, StoreID),
	ok = filelib:ensure_dir(Dir ++ "/"),
	ok = filelib:ensure_dir(filename:join(Dir, ?CHUNK_DIR) ++ "/"),
	StorageIndex = read_file_index(Dir),
	maps:values(StorageIndex).

files_to_defrag(StorageModules, DataDir, ByteSizeThreshold, Sizes) ->
	AllFiles = lists:flatmap(
		fun(StorageModule) ->
			list_files(DataDir, ar_storage_module:id(StorageModule))
		end, StorageModules),
	lists:filter(
		fun(Filepath) ->
			case file:read_file_info(Filepath) of
				{ok, #file_info{ size = Size }} ->
					LastSize = maps:get(Filepath, Sizes, 1),
					Growth = (Size - LastSize) / LastSize,
					Size >= ByteSizeThreshold andalso Growth > 0.1;
				{error, Reason} ->
					?LOG_ERROR([
						{event, failed_to_read_chunk_file_info},
						{file, Filepath},
						{reason, io_lib:format("~p", [Reason])}
					]),
					false
			end
		end, AllFiles).

defrag_files([]) ->
	ok;
defrag_files([Filepath | Rest]) ->
	?LOG_DEBUG([{event, defragmenting_file}, {file, Filepath}]),
	ar:console("Defragmenting ~s...~n", [Filepath]),
	TmpFilepath = Filepath ++ ".tmp",
	DefragCmd = io_lib:format("rsync --sparse --quiet ~ts ~ts", [Filepath, TmpFilepath]),
	MoveDefragCmd = io_lib:format("mv ~ts ~ts", [TmpFilepath, Filepath]),
	%% We expect nothing to be returned on successful calls.
	[] = os:cmd(DefragCmd),
	[] = os:cmd(MoveDefragCmd),
	ar:console("Defragmented ~s...~n", [Filepath]),
	defrag_files(Rest).

update_sizes_file([], Sizes) ->
	{ok, Config} = application:get_env(arweave, config),
	SizesFile = filename:join(Config#config.data_dir, "chunks_sizes"),
	case file:open(SizesFile, [write, raw]) of
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_open_chunk_sizes_file},
				{file, SizesFile},
				{reason, io_lib:format("~p", [Reason])}
			]),
			error;
		{ok, F} ->
			SizesBinary = erlang:term_to_binary(Sizes),
			ok = file:write(F, SizesBinary),
			file:close(F)
	end;
update_sizes_file([Filepath | Rest], Sizes) ->
	case file:read_file_info(Filepath) of
		{ok, #file_info{ size = Size }} ->
			update_sizes_file(Rest, Sizes#{ Filepath => Size });
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_read_chunk_file_info},
				{file, Filepath},
				{reason, io_lib:format("~p", [Reason])}
			]),
			error
	end.

read_chunks_sizes(DataDir) ->
	SizesFile = filename:join(DataDir, "chunks_sizes"),
	case file:read_file(SizesFile) of
		{ok, Content} ->
			erlang:binary_to_term(Content);
		{error, enoent} ->
			#{};
		{error, Reason} ->
			?LOG_ERROR([
				{event, failed_to_read_chunk_sizes_file},
				{file, SizesFile},
				{reason, io_lib:format("~p", [Reason])}
			]),
			error
	end.

modules_to_defrag(#config{defragmentation_modules = [_ | _] = Modules}) -> Modules;
modules_to_defrag(#config{storage_modules = Modules}) -> Modules.

chunk_offset_list_to_map(ChunkOffsets) ->
	chunk_offset_list_to_map(ChunkOffsets, infinity, 0, #{}).

get_repack_interval_size() ->
	{ok, Config} = application:get_env(arweave, config),
	?DATA_CHUNK_SIZE * Config#config.repack_batch_size.

shift_repack_cursor(Cursor, RangeStart, RangeEnd) ->
	RepackIntervalSize = get_repack_interval_size(),
	SectorSize = ar_replica_2_9:get_sector_size(),
	Cursor2 = get_chunk_bucket_start(Cursor + SectorSize + ?DATA_CHUNK_SIZE),
	case Cursor2 > get_chunk_bucket_start(RangeEnd) of
		true ->
			RangeStart2 = get_chunk_bucket_start(RangeStart + 1),
			RelativeOffset = Cursor + RepackIntervalSize - RangeStart2,
			Cursor3 = RangeStart2 + (RelativeOffset rem SectorSize),
			case Cursor3 > RangeStart2 + SectorSize of
				true ->
					none;
				false ->
					Cursor3
			end;
		false ->
			Cursor2
	end.

repack(none, _RangeStart, _RangeEnd, Packing, StoreID) ->
	ar:console("~n~nRepacking of ~s is complete! "
			"We suggest you stop the node, rename "
			"the storage module folder to reflect "
			"the new packing, and start the "
			"node with the new storage module.~n", [StoreID]),
	?LOG_INFO([{event, repacking_complete},
			{storage_module, StoreID},
			{target_packing, ar_serialize:encode_packing(Packing, true)}]),
	Server = gen_server_id(StoreID),
	gen_server:cast(Server, repacking_complete);
repack(Cursor, RangeStart, RangeEnd, Packing, StoreID) ->
	RightBound = Cursor + get_repack_interval_size(),
	?LOG_DEBUG([{event, repacking_in_place},
			{tags, [repack_in_place]},
			{s, Cursor},
			{e, RightBound},
			{store_id, StoreID}]),
	case ar_sync_record:get_next_synced_interval(Cursor, RightBound,
			ar_data_sync, StoreID) of
		not_found ->
			Cursor2 = shift_repack_cursor(Cursor, RangeStart, RangeEnd),
			repack(Cursor2, RangeStart, RangeEnd, Packing, StoreID);
		{_End, _Start} ->
			repack_batch(Cursor, RangeStart, RangeEnd, Packing, StoreID)
	end.

repack_batch(Cursor, RangeStart, RangeEnd, RequiredPacking, StoreID) ->
	{ok, Config} = application:get_env(arweave, config),
	RepackIntervalSize = ?DATA_CHUNK_SIZE * Config#config.repack_batch_size,
	Server = gen_server_id(StoreID),
	Cursor2 = shift_repack_cursor(Cursor, RangeStart, RangeEnd),
	RepackFurtherArgs = {repack, Cursor2, RangeStart, RangeEnd, RequiredPacking},
	CheckPackingBuffer =
		case ar_packing_server:is_buffer_full() of
			true ->
				ar_util:cast_after(200, Server,
						{repack, Cursor, RangeStart, RangeEnd, RequiredPacking}),
				continue;
			false ->
				ok
		end,
	ReadRange =
		case CheckPackingBuffer of
			continue ->
				continue;
			ok ->
				repack_read_chunk_range(Cursor, RepackIntervalSize,
						StoreID, RepackFurtherArgs)
		end,
	ReadMetadataRange =
		case ReadRange of
			continue ->
				continue;
			{ok, Range2} ->
				repack_read_chunk_metadata_range(Cursor, RepackIntervalSize, RangeEnd,
						Range2, StoreID, RepackFurtherArgs)
		end,
	case ReadMetadataRange of
		continue ->
			ok;
		{ok, Map2, MetadataMap2} ->
			gen_server:cast(Server, RepackFurtherArgs),
			Args = {StoreID, RequiredPacking, Map2},
			repack_send_chunks_for_repacking(MetadataMap2, Args)
	end.

repack_read_chunk_range(Start, Size, StoreID, RepackFurtherArgs) ->
	Server = name(StoreID),
	case catch get_range(Start, Size, StoreID) of
		[] ->
			gen_server:cast(Server, RepackFurtherArgs),
			continue;
		{'EXIT', _Exc} ->
			?LOG_ERROR([{event, failed_to_read_chunk_range},
					{tags, [repack_in_place]},
					{storage_module, StoreID},
					{start, Start},
					{size, Size},
					{store_id, StoreID}]),
			gen_server:cast(Server, RepackFurtherArgs),
			continue;
		Range ->
			{ok, Range}
	end.

repack_read_chunk_metadata_range(Start, Size, End,
		Range, StoreID, RepackFurtherArgs) ->
	Server = name(StoreID),
	End2 = min(Start + Size, End),
	{_, _, Map} = chunk_offset_list_to_map(Range),
	case ar_data_sync:get_chunk_metadata_range(Start, End2, StoreID) of
		{ok, MetadataMap} ->
			{ok, Map, MetadataMap};
		{error, Error} ->
			?LOG_ERROR([{event, failed_to_read_chunk_metadata_range},
					{storage_module, StoreID},
					{error, io_lib:format("~p", [Error])}]),
			gen_server:cast(Server, RepackFurtherArgs),
			continue
	end.

repack_send_chunks_for_repacking(MetadataMap, Args) ->
	maps:fold(repack_send_chunks_for_repacking(Args), ok, MetadataMap).

repack_send_chunks_for_repacking(Args) ->
	fun	(AbsoluteOffset, {_, _TXRoot, _, _, _, ChunkSize}, ok)
				when ChunkSize /= ?DATA_CHUNK_SIZE,
						AbsoluteOffset =< ?STRICT_DATA_SPLIT_THRESHOLD ->
			?LOG_DEBUG([{event, skipping_small_chunk},
					{tags, [repack_in_place]},
					{offset, AbsoluteOffset},
					{chunk_size, ChunkSize}]),
			ok;
		(AbsoluteOffset, ChunkMeta, ok) ->
			repack_send_chunk_for_repacking(AbsoluteOffset, ChunkMeta, Args)
	end.

repack_send_chunk_for_repacking(AbsoluteOffset, ChunkMeta, Args) ->
	{StoreID, RequiredPacking, ChunkMap} = Args,
	Server = name(StoreID),
	PaddedOffset = ar_block:get_chunk_padded_offset(AbsoluteOffset),
	{ChunkDataKey, TXRoot, DataRoot, TXPath,
			RelativeOffset, ChunkSize} = ChunkMeta,
	case ar_sync_record:is_recorded(PaddedOffset, ar_data_sync, StoreID) of
		{true, unpacked_padded} ->
			%% unpacked_padded is a special internal packing used
			%% for temporary storage of unpacked and padded chunks
			%% before they are enciphered with the 2.9 entropy.
			?LOG_WARNING([
				{event, repacking_process_chunk_unpacked_padded},
				{storage_module, StoreID},
				{packing,
					ar_serialize:encode_packing(RequiredPacking,true)},
				{offset, AbsoluteOffset}]),
			ok;
		{true, RequiredPacking} ->
			?LOG_WARNING([{event, repacking_process_chunk_already_repacked},
					{storage_module, StoreID},
					{packing,
						ar_serialize:encode_packing(RequiredPacking, true)},
					{offset, AbsoluteOffset}]),
			ok;
		{true, Packing} ->
			ChunkMaybeDataPath =
				case maps:get(PaddedOffset, ChunkMap, not_found) of
					not_found ->
						repack_read_chunk_and_data_path(StoreID,
								ChunkDataKey, AbsoluteOffset, no_chunk);
					Chunk3 ->
						case is_storage_supported(AbsoluteOffset,
								ChunkSize, Packing) of
							false ->
								%% We are going to move this chunk to
								%% RocksDB after repacking so we read
								%% its DataPath here to pass it later on
								%% to store_chunk.
								repack_read_chunk_and_data_path(StoreID,
										ChunkDataKey, AbsoluteOffset, Chunk3);
							true ->
								%% We are going to repack the chunk and keep it
								%% in the chunk storage - no need to make an
								%% extra disk access to read the data path.
								{Chunk3, none}
						end
				end,
			case ChunkMaybeDataPath of
				not_found ->
					ok;
				{Chunk, MaybeDataPath} ->
					RequiredPacking2 =
						case RequiredPacking of
							{replica_2_9, _} ->
								unpacked_padded;
							Packing ->
								Packing
						end,
					?LOG_DEBUG([{event, request_repack},
							{tags, [repack_in_place]},
							{storage_module, StoreID},
							{offset, PaddedOffset},
							{absolute_offset, AbsoluteOffset},
							{chunk_size, ChunkSize},
							{required_packing, ar_serialize:encode_packing(RequiredPacking2, true)},
							{packing, ar_serialize:encode_packing(Packing, true)}]),
					Ref = make_ref(),
					RepackArgs = {Packing, MaybeDataPath, RelativeOffset,
							DataRoot, TXPath, none, none},
					gen_server:cast(Server,
							{register_packing_ref, Ref, RepackArgs}),
					ar_util:cast_after(300000, Server,
							{expire_repack_request, Ref}),
					ar_packing_server:request_repack(Ref, whereis(Server),
							{RequiredPacking2, Packing, Chunk,
									AbsoluteOffset, TXRoot, ChunkSize})
			end;
		true ->
			?LOG_WARNING([{event, no_packing_information_for_the_chunk},
					{storage_module, StoreID},
					{offset, PaddedOffset}]),
			ok;
		false ->
			?LOG_WARNING([{event, chunk_not_found_in_sync_record},
					{storage_module, StoreID},
					{offset, PaddedOffset}]),
			ok
	end.

repack_read_chunk_and_data_path(StoreID, ChunkDataKey, AbsoluteOffset,
		MaybeChunk) ->
	case ar_kv:get({chunk_data_db, StoreID}, ChunkDataKey) of
		not_found ->
			?LOG_WARNING([{event, chunk_not_found},
					{type, repack_in_place},
					{storage_module, StoreID},
					{offset, AbsoluteOffset}]),
			not_found;
		{ok, V} ->
			case binary_to_term(V) of
				{Chunk, DataPath} ->
					{Chunk, DataPath};
				DataPath when MaybeChunk /= no_chunk ->
					{MaybeChunk, DataPath};
				_ ->
					?LOG_WARNING([{event, chunk_not_found2},
						{type, repack_in_place},
						{storage_module, StoreID},
						{offset, AbsoluteOffset}]),
					not_found
			end
	end.

chunk_offset_list_to_map([], Min, Max, Map) ->
	{Min, Max, Map};
chunk_offset_list_to_map([{Offset, Chunk} | ChunkOffsets], Min, Max, Map) ->
	chunk_offset_list_to_map(ChunkOffsets, min(Min, Offset), max(Max, Offset),
			maps:put(Offset, Chunk, Map)).

-ifdef(TEST).
	try_acquire_replica_2_9_formatting_lock(_StoreID) ->
		true.
-else.
try_acquire_replica_2_9_formatting_lock(StoreID) ->
	case ets:insert_new(ar_chunk_storage, {update_replica_2_9_lock}) of
		true ->
			Count = get_replica_2_9_acquired_locks_count(),
			{ok, Config} = application:get_env(arweave, config),
			MaxWorkers = Config#config.replica_2_9_workers,
			case Count + 1 > MaxWorkers of
				true ->
					ets:delete(ar_chunk_storage, update_replica_2_9_lock),
					false;
				false ->
					ets:update_counter(ar_chunk_storage, replica_2_9_acquired_locks_count,
							1, {replica_2_9_acquired_locks_count, 0}),
					ets:delete(ar_chunk_storage, update_replica_2_9_lock),
					true
			end;
		false ->
			try_acquire_replica_2_9_formatting_lock(StoreID)
	end.
-endif.

get_replica_2_9_acquired_locks_count() ->
	case ets:lookup(ar_chunk_storage, replica_2_9_acquired_locks_count) of
		[] ->
			0;
		[{_, Count}] ->
			Count
	end.

release_replica_2_9_formatting_lock(StoreID) ->
	case ets:insert_new(ar_chunk_storage, {update_replica_2_9_lock}) of
		true ->
			Count = get_replica_2_9_acquired_locks_count(),
			case Count of
				0 ->
					ok;
				_ ->
					ets:update_counter(ar_chunk_storage, replica_2_9_acquired_locks_count,
							-1, {replica_2_9_acquired_locks_count, 0})
			end,
			ets:delete(ar_chunk_storage, update_replica_2_9_lock);
		false ->
			release_replica_2_9_formatting_lock(StoreID)
	end.

%%%===================================================================
%%% Tests.
%%%===================================================================

replica_2_9_test_() ->
	{timeout, 20, fun test_replica_2_9/0}.

test_replica_2_9() ->
	RewardAddr = ar_wallet:to_address(ar_wallet:new_keyfile()),
	StorageModules = [
			{?PARTITION_SIZE, 0, {replica_2_9, RewardAddr}},
			{?PARTITION_SIZE, 1, {replica_2_9, RewardAddr}}
	],
	{ok, Config} = application:get_env(arweave, config),
	try
		ar_test_node:start(#{ reward_addr => RewardAddr, storage_modules => StorageModules }),
		StoreID1 = ar_storage_module:id(lists:nth(1, StorageModules)),
		StoreID2 = ar_storage_module:id(lists:nth(2, StorageModules)),
		C1 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
		%% The replica_2_9 storage does not support updates and three chunks are written
		%% into the first partition when the test node is launched.
		?assertEqual({error, already_stored},
				ar_chunk_storage:put(?DATA_CHUNK_SIZE, C1, StoreID1)),
		?assertEqual({error, already_stored},
				ar_chunk_storage:put(2 * ?DATA_CHUNK_SIZE, C1, StoreID1)),
		?assertEqual({error, already_stored},
				ar_chunk_storage:put(3 * ?DATA_CHUNK_SIZE, C1, StoreID1)),

		%% Store the new chunk.
		?assertEqual(ok, ar_chunk_storage:put(4 * ?DATA_CHUNK_SIZE, C1, StoreID1)),
		{ok, P1, _Entropy} =
				ar_packing_server:pack_replica_2_9_chunk(RewardAddr, 4 * ?DATA_CHUNK_SIZE, C1),
		assert_get(P1, 4 * ?DATA_CHUNK_SIZE, StoreID1),

		assert_get(not_found, 8 * ?DATA_CHUNK_SIZE, StoreID1),
		?assertEqual(ok, ar_chunk_storage:put(8 * ?DATA_CHUNK_SIZE, C1, StoreID1)),
		{ok, P2, _} =
				ar_packing_server:pack_replica_2_9_chunk(RewardAddr, 8 * ?DATA_CHUNK_SIZE, C1),
		assert_get(P2, 8 * ?DATA_CHUNK_SIZE, StoreID1),

		%% Store chunks in the second partition.
		?assertEqual(ok, ar_chunk_storage:put(12 * ?DATA_CHUNK_SIZE, C1, StoreID2)),
		{ok, P3, Entropy3} =
				ar_packing_server:pack_replica_2_9_chunk(RewardAddr, 12 * ?DATA_CHUNK_SIZE, C1),

		assert_get(P3, 12 * ?DATA_CHUNK_SIZE, StoreID2),
		?assertEqual(ok, ar_chunk_storage:put(15 * ?DATA_CHUNK_SIZE, C1, StoreID2)),
		{ok, P4, Entropy4} =
				ar_packing_server:pack_replica_2_9_chunk(RewardAddr, 15 * ?DATA_CHUNK_SIZE, C1),
		assert_get(P4, 15 * ?DATA_CHUNK_SIZE, StoreID2),
		?assertNotEqual(P3, P4),
		?assertNotEqual(Entropy3, Entropy4),

		?assertEqual(ok, ar_chunk_storage:put(16 * ?DATA_CHUNK_SIZE, C1, StoreID2)),
		{ok, P5, Entropy5} =
				ar_packing_server:pack_replica_2_9_chunk(RewardAddr, 16 * ?DATA_CHUNK_SIZE, C1),
		assert_get(P5, 16 * ?DATA_CHUNK_SIZE, StoreID2),
		?assertNotEqual(Entropy4, Entropy5)
	after
		ok = application:set_env(arweave, config, Config)
	end.

well_aligned_test_() ->
	{timeout, 20, fun test_well_aligned/0}.

test_well_aligned() ->
	clear("default"),
	C1 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C2 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C3 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	ok = ar_chunk_storage:put(2 * ?DATA_CHUNK_SIZE, C1),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE),
	?assertEqual(not_found, ar_chunk_storage:get(2 * ?DATA_CHUNK_SIZE)),
	?assertEqual(not_found, ar_chunk_storage:get(2 * ?DATA_CHUNK_SIZE + 1)),
	ar_chunk_storage:delete(2 * ?DATA_CHUNK_SIZE),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE),
	ar_chunk_storage:put(?DATA_CHUNK_SIZE, C2),
	assert_get(C2, ?DATA_CHUNK_SIZE),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE),
	ar_chunk_storage:put(2 * ?DATA_CHUNK_SIZE, C1),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE),
	assert_get(C2, ?DATA_CHUNK_SIZE),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			ar_chunk_storage:get_range(0, 2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			ar_chunk_storage:get_range(1, 2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			ar_chunk_storage:get_range(1, 2 * ?DATA_CHUNK_SIZE - 1)),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			ar_chunk_storage:get_range(0, 3 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{?DATA_CHUNK_SIZE, C2}, {2 * ?DATA_CHUNK_SIZE, C1}],
			ar_chunk_storage:get_range(0, ?DATA_CHUNK_SIZE + 1)),
	ar_chunk_storage:put(3 * ?DATA_CHUNK_SIZE, C3),
	assert_get(C2, ?DATA_CHUNK_SIZE),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE),
	assert_get(C3, 3 * ?DATA_CHUNK_SIZE),
	?assertEqual(not_found, ar_chunk_storage:get(3 * ?DATA_CHUNK_SIZE)),
	?assertEqual(not_found, ar_chunk_storage:get(3 * ?DATA_CHUNK_SIZE + 1)),
	ar_chunk_storage:put(2 * ?DATA_CHUNK_SIZE, C2),
	assert_get(C2, ?DATA_CHUNK_SIZE),
	assert_get(C2, 2 * ?DATA_CHUNK_SIZE),
	assert_get(C3, 3 * ?DATA_CHUNK_SIZE),
	ar_chunk_storage:delete(?DATA_CHUNK_SIZE),
	assert_get(not_found, ?DATA_CHUNK_SIZE),
	?assertEqual([], ar_chunk_storage:get_range(0, ?DATA_CHUNK_SIZE)),
	assert_get(C2, 2 * ?DATA_CHUNK_SIZE),
	assert_get(C3, 3 * ?DATA_CHUNK_SIZE),
	?assertEqual([{2 * ?DATA_CHUNK_SIZE, C2}, {3 * ?DATA_CHUNK_SIZE, C3}],
			ar_chunk_storage:get_range(0, 4 * ?DATA_CHUNK_SIZE)),
	?assertEqual([], ar_chunk_storage:get_range(7 * ?DATA_CHUNK_SIZE, 13 * ?DATA_CHUNK_SIZE)).

not_aligned_test_() ->
	{timeout, 20, fun test_not_aligned/0}.

test_not_aligned() ->
	clear("default"),
	C1 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C2 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C3 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	ar_chunk_storage:put(2 * ?DATA_CHUNK_SIZE + 7, C1),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE + 7),
	ar_chunk_storage:delete(2 * ?DATA_CHUNK_SIZE + 7),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE + 7),
	ar_chunk_storage:put(2 * ?DATA_CHUNK_SIZE + 7, C1),
	assert_get(C1, 2 * ?DATA_CHUNK_SIZE + 7),
	?assertEqual(not_found, ar_chunk_storage:get(2 * ?DATA_CHUNK_SIZE + 7)),
	?assertEqual(not_found, ar_chunk_storage:get(?DATA_CHUNK_SIZE + 7 - 1)),
	?assertEqual(not_found, ar_chunk_storage:get(?DATA_CHUNK_SIZE)),
	?assertEqual(not_found, ar_chunk_storage:get(?DATA_CHUNK_SIZE - 1)),
	?assertEqual(not_found, ar_chunk_storage:get(0)),
	?assertEqual(not_found, ar_chunk_storage:get(1)),
	ar_chunk_storage:put(?DATA_CHUNK_SIZE + 3, C2),
	assert_get(C2, ?DATA_CHUNK_SIZE + 3),
	?assertEqual(not_found, ar_chunk_storage:get(0)),
	?assertEqual(not_found, ar_chunk_storage:get(1)),
	?assertEqual(not_found, ar_chunk_storage:get(2)),
	ar_chunk_storage:delete(2 * ?DATA_CHUNK_SIZE + 7),
	assert_get(C2, ?DATA_CHUNK_SIZE + 3),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE + 7),
	ar_chunk_storage:put(3 * ?DATA_CHUNK_SIZE + 7, C3),
	assert_get(C3, 3 * ?DATA_CHUNK_SIZE + 7),
	ar_chunk_storage:put(3 * ?DATA_CHUNK_SIZE + 7, C1),
	assert_get(C1, 3 * ?DATA_CHUNK_SIZE + 7),
	ar_chunk_storage:put(4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2, C2),
	assert_get(C2, 4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2),
	?assertEqual(
		not_found,
		ar_chunk_storage:get(4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2)
	),
	?assertEqual(not_found, ar_chunk_storage:get(3 * ?DATA_CHUNK_SIZE + 7)),
	?assertEqual(not_found, ar_chunk_storage:get(3 * ?DATA_CHUNK_SIZE + 8)),
	ar_chunk_storage:put(5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2),
	assert_get(C2, 5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1),
	assert_get(not_found, 2 * ?DATA_CHUNK_SIZE + 7),
	ar_chunk_storage:delete(4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2),
	assert_get(not_found, 4 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2),
	assert_get(C2, 5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1),
	assert_get(C1, 3 * ?DATA_CHUNK_SIZE + 7),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1}],
			ar_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 7, 2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1}],
			ar_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 6, 2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1},
			{5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2}],
			%% The end offset of the second chunk is bigger than Start + Size but
			%% it is included because Start + Size is bigger than the start offset
			%% of the bucket where the last chunk is placed.
			ar_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 7, 2 * ?DATA_CHUNK_SIZE + 1)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1},
			{5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2}],
			ar_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 7, 3 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1},
			{5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2}],
			ar_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE + 7 - 1, 3 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{3 * ?DATA_CHUNK_SIZE + 7, C1},
			{5 * ?DATA_CHUNK_SIZE + ?DATA_CHUNK_SIZE div 2 + 1, C2}],
			ar_chunk_storage:get_range(2 * ?DATA_CHUNK_SIZE, 4 * ?DATA_CHUNK_SIZE)).

cross_file_aligned_test_() ->
	{timeout, 20, fun test_cross_file_aligned/0}.

test_cross_file_aligned() ->
	clear("default"),
	C1 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C2 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	ar_chunk_storage:put(get_chunk_group_size(), C1),
	assert_get(C1, get_chunk_group_size()),
	?assertEqual(not_found, ar_chunk_storage:get(get_chunk_group_size())),
	?assertEqual(not_found, ar_chunk_storage:get(get_chunk_group_size() + 1)),
	?assertEqual(not_found, ar_chunk_storage:get(0)),
	?assertEqual(not_found, ar_chunk_storage:get(get_chunk_group_size() - ?DATA_CHUNK_SIZE - 1)),
	ar_chunk_storage:put(get_chunk_group_size() + ?DATA_CHUNK_SIZE, C2),
	assert_get(C2, get_chunk_group_size() + ?DATA_CHUNK_SIZE),
	assert_get(C1, get_chunk_group_size()),
	?assertEqual([{get_chunk_group_size(), C1}, {get_chunk_group_size() + ?DATA_CHUNK_SIZE, C2}],
			ar_chunk_storage:get_range(get_chunk_group_size() - ?DATA_CHUNK_SIZE,
					2 * ?DATA_CHUNK_SIZE)),
	?assertEqual([{get_chunk_group_size(), C1}, {get_chunk_group_size() + ?DATA_CHUNK_SIZE, C2}],
			ar_chunk_storage:get_range(get_chunk_group_size() - 2 * ?DATA_CHUNK_SIZE - 1,
					4 * ?DATA_CHUNK_SIZE)),
	?assertEqual(not_found, ar_chunk_storage:get(0)),
	?assertEqual(not_found, ar_chunk_storage:get(get_chunk_group_size() - ?DATA_CHUNK_SIZE - 1)),
	ar_chunk_storage:delete(get_chunk_group_size()),
	assert_get(not_found, get_chunk_group_size()),
	assert_get(C2, get_chunk_group_size() + ?DATA_CHUNK_SIZE),
	ar_chunk_storage:put(get_chunk_group_size(), C2),
	assert_get(C2, get_chunk_group_size()).

cross_file_not_aligned_test_() ->
	{timeout, 20, fun test_cross_file_not_aligned/0}.

test_cross_file_not_aligned() ->
	clear("default"),
	C1 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C2 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	C3 = crypto:strong_rand_bytes(?DATA_CHUNK_SIZE),
	ar_chunk_storage:put(get_chunk_group_size() + 1, C1),
	assert_get(C1, get_chunk_group_size() + 1),
	?assertEqual(not_found, ar_chunk_storage:get(get_chunk_group_size() + 1)),
	?assertEqual(not_found, ar_chunk_storage:get(get_chunk_group_size() - ?DATA_CHUNK_SIZE)),
	ar_chunk_storage:put(2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2, C2),
	assert_get(C2, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	?assertEqual(not_found, ar_chunk_storage:get(get_chunk_group_size() + 1)),
	ar_chunk_storage:put(2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2, C3),
	assert_get(C2, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	assert_get(C3, 2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	?assertEqual([{2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2, C3},
			{2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2, C2}],
			ar_chunk_storage:get_range(2 * get_chunk_group_size()
					- ?DATA_CHUNK_SIZE div 2 - ?DATA_CHUNK_SIZE, ?DATA_CHUNK_SIZE * 2)),
	?assertEqual(not_found, ar_chunk_storage:get(get_chunk_group_size() + 1)),
	?assertEqual(
		not_found,
		ar_chunk_storage:get(get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2 - 1)
	),
	ar_chunk_storage:delete(2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	assert_get(not_found, 2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	assert_get(C2, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	assert_get(C1, get_chunk_group_size() + 1),
	ar_chunk_storage:delete(get_chunk_group_size() + 1),
	assert_get(not_found, get_chunk_group_size() + 1),
	assert_get(not_found, 2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	assert_get(C2, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	ar_chunk_storage:delete(2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	assert_get(not_found, 2 * get_chunk_group_size() + ?DATA_CHUNK_SIZE div 2),
	ar_chunk_storage:delete(get_chunk_group_size() + 1),
	ar_chunk_storage:delete(100 * get_chunk_group_size() + 1),
	ar_chunk_storage:put(2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2, C1),
	assert_get(C1, 2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2),
	?assertEqual(not_found,
			ar_chunk_storage:get(2 * get_chunk_group_size() - ?DATA_CHUNK_SIZE div 2)).

gen_server_id(StoreID) ->
	list_to_atom("ar_chunk_storage_" ++ ar_storage_module:label_by_id(StoreID)).

clear(StoreID) ->
	ok = gen_server:call(gen_server_id(StoreID), reset).

assert_get(Expected, Offset) ->
	assert_get(Expected, Offset, "default").

assert_get(Expected, Offset, StoreID) ->
	ExpectedResult =
		case Expected of
			not_found ->
				not_found;
			_ ->
				{Offset, Expected}
		end,
	?assertEqual(ExpectedResult, ar_chunk_storage:get(Offset - 1, StoreID)),
	?assertEqual(ExpectedResult, ar_chunk_storage:get(Offset - 2, StoreID)),
	?assertEqual(ExpectedResult, ar_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE, StoreID)),
	?assertEqual(ExpectedResult, ar_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE + 1, StoreID)),
	?assertEqual(ExpectedResult, ar_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE + 2, StoreID)),
	?assertEqual(ExpectedResult,
			ar_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE div 2, StoreID)),
	?assertEqual(ExpectedResult,
			ar_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE div 2 + 1, StoreID)),
	?assertEqual(ExpectedResult,
			ar_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE div 2 - 1, StoreID)),
	?assertEqual(ExpectedResult,
			ar_chunk_storage:get(Offset - ?DATA_CHUNK_SIZE div 3, StoreID)).

defrag_command_test() ->
	RandomID = crypto:strong_rand_bytes(16),
	Filepath = "test_defrag_" ++ binary_to_list(ar_util:encode(RandomID)),
	{ok, F} = file:open(Filepath, [binary, write]),
	{O1, C1} = {236, crypto:strong_rand_bytes(262144)},
	{O2, C2} = {262144, crypto:strong_rand_bytes(262144)},
	{O3, C3} = {262143, crypto:strong_rand_bytes(262144)},
	file:pwrite(F, 1, <<"a">>),
	file:pwrite(F, 1000, <<"b">>),
	file:pwrite(F, 1000000, <<"cde">>),
	file:pwrite(F, 10000001, << O1:24, C1/binary, O2:24, C2/binary >>),
	file:pwrite(F, 30000001, << O3:24, C3/binary >>),
	file:close(F),
	defrag_files([Filepath]),
	{ok, F2} = file:open(Filepath, [binary, read]),
	?assertEqual({ok, <<0>>}, file:pread(F2, 0, 1)),
	?assertEqual({ok, <<"a">>}, file:pread(F2, 1, 1)),
	?assertEqual({ok, <<0>>}, file:pread(F2, 2, 1)),
	?assertEqual({ok, <<"b">>}, file:pread(F2, 1000, 1)),
	?assertEqual({ok, <<"c">>}, file:pread(F2, 1000000, 1)),
	?assertEqual({ok, <<"cde">>}, file:pread(F2, 1000000, 3)),
	?assertEqual({ok, C1}, file:pread(F2, 10000001 + 3, 262144)),
	?assertMatch({ok, << O1:24, _/binary >>}, file:pread(F2, 10000001, 10)),
	?assertMatch({ok, << O1:24, C1:262144/binary, O2:24, C2:262144/binary,
			0:((262144 + 3) * 2 * 8) >>}, file:pread(F2, 10000001, (262144 + 3) * 4)),
	?assertMatch({ok, << O3:24, C3:262144/binary >>},
			file:pread(F2, 30000001, 262144 + 3 + 100)). % End of file => +100 is ignored.
