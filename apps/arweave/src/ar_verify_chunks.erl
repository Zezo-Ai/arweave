-module(ar_verify_chunks).

-behaviour(gen_server).

-export([start_link/2, name/1]).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-export([generate_sample_offsets/3]).

-include("../include/ar.hrl").
-include("../include/ar_consensus.hrl").
-include("../include/ar_verify_chunks.hrl").

-include_lib("eunit/include/eunit.hrl").

-record(state, {
	store_id :: string(),
	packing :: term(),
	start_offset :: non_neg_integer(),
	end_offset :: non_neg_integer(),
	cursor :: non_neg_integer(),
	ready = false :: boolean(),
	verify_report = #verify_report{} :: #verify_report{}
}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link(Name, StorageModule) ->
	gen_server:start_link({local, Name}, ?MODULE, StorageModule, []).

-spec name(binary()) -> atom().
name(StoreID) ->
	list_to_atom("ar_verify_chunks_" ++ ar_storage_module:label_by_id(StoreID)).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init(StoreID) ->
	?LOG_INFO([{event, verify_chunk_storage_started}, {store_id, StoreID}]),
	{StartOffset, EndOffset} = ar_storage_module:get_range(StoreID),
	gen_server:cast(self(), sample),
	{ok, #state{
		store_id = StoreID,
		packing = ar_storage_module:get_packing(StoreID),
		start_offset = StartOffset,
		end_offset = EndOffset,
		cursor = StartOffset,
		ready = is_ready(EndOffset),
		verify_report = #verify_report{
			start_time = erlang:system_time(millisecond)
		}
	}}.

handle_cast(sample, #state{ready = false, end_offset = EndOffset} = State) ->
	ar_util:cast_after(1000, self(), sample),
	{noreply, State#state{ready = is_ready(EndOffset)}};
handle_cast(sample,
		#state{cursor = Cursor, end_offset = EndOffset} = State) when Cursor >= EndOffset ->
	ar:console("Done!~n"),
	{noreply, State};
handle_cast(sample, State) ->
	%% Sample ?SAMPLE_CHUNK_COUNT random chunks, read them, unpack them and verify them.
	%% Report the collected statistics and continue with the "verify" procedure.
	sample_random_chunks(?SAMPLE_CHUNK_COUNT, State#state.packing,
			State#state.start_offset, State#state.end_offset, State#state.store_id),
	gen_server:cast(self(), verify),
	{noreply, State};

handle_cast(verify, #state{ready = false, end_offset = EndOffset} = State) ->
	ar_util:cast_after(1000, self(), verify),
	{noreply, State#state{ready = is_ready(EndOffset)}};
handle_cast(verify,
		#state{cursor = Cursor, end_offset = EndOffset} = State) when Cursor >= EndOffset ->
	ar:console("Done!~n"),
	{noreply, State};
handle_cast(verify, State) ->
	State2 = verify(State),
	State3 = report_progress(State2),
	{noreply, State3};

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_call(Call, From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {call, Call}, {from, From}]),
	{reply, ok, State}.

handle_info(Info, State) ->
	?LOG_WARNING([{event, unhandled_info}, {module, ?MODULE}, {info, Info}]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

is_ready(EndOffset) ->
	case ar_block_index:get_last() of
		'$end_of_table' ->
			false;
		{WeaveSize, _Height, _H, _TXRoot}  ->
			WeaveSize >= EndOffset
	end.

verify(State) ->
	#state{store_id = StoreID} = State,
	{UnionInterval, Intervals} = query_intervals(State),
	State2 = verify_chunks(UnionInterval, Intervals, State),
	case State2#state.cursor >= State2#state.end_offset of
		true ->
			ar:console("Done verifying ~s!~n", [StoreID]),
			?LOG_INFO([{event, verify_chunk_storage_verify_chunks_done}, {store_id, StoreID}]),
			State2;
		false ->
			gen_server:cast(self(), verify)
	end,
	State2.

verify_chunks(not_found, _Intervals, State) ->
	State#state{ cursor = State#state.end_offset };
verify_chunks({End, _Start}, _Intervals, #state{cursor = Cursor} = State) when Cursor >= End ->
	State;
verify_chunks({IntervalEnd, IntervalStart}, Intervals, State) ->
	#state{cursor = Cursor, store_id = StoreID} = State,
	Cursor2 = max(IntervalStart, Cursor),
	ChunkData = ar_data_sync:get_chunk_by_byte(Cursor2+1, StoreID),
	State2 = verify_chunk(ChunkData, Intervals, State#state{ cursor = Cursor2 }),
	verify_chunks({IntervalEnd, IntervalStart}, Intervals, State2).

verify_chunk({error, Reason}, _Intervals, State) ->
	#state{ cursor = Cursor } = State,
	NextCursor = ar_data_sync:advance_chunks_index_cursor(Cursor),
	RangeSkipped = NextCursor - Cursor,
	State2 = log_error(get_chunk_error, Cursor, RangeSkipped, [{reason, Reason}], State),
	State2#state{ cursor = NextCursor };
verify_chunk({ok, _Key, Metadata}, Intervals, State) ->
	{AbsoluteOffset, _ChunkDataKey, _TXRoot, _DataRoot, _TXPath,
		_TXRelativeOffset, ChunkSize} = Metadata,
	{ChunkStorageInterval, _DataSyncInterval} = Intervals,

	PaddedOffset = ar_block:get_chunk_padded_offset(AbsoluteOffset),
	State2 = verify_chunk_storage(AbsoluteOffset, PaddedOffset, ChunkSize, ChunkStorageInterval, State),

	State3 = verify_proof(Metadata, State2),

	State4 = verify_packing(Metadata, State3),

	State4#state{ cursor = PaddedOffset }.

verify_proof(Metadata, State) ->
	#state{ store_id = StoreID } = State,
	{AbsoluteOffset, ChunkDataKey, TXRoot, _DataRoot, TXPath,
		_TXRelativeOffset, ChunkSize} = Metadata,

	case ar_data_sync:read_data_path(ChunkDataKey, StoreID) of
		{ok, DataPath} ->
			case ar_poa:validate_paths(TXRoot, TXPath, DataPath, AbsoluteOffset - 1) of
				{false, _Proof} ->
					invalidate_chunk(validate_paths_error, AbsoluteOffset, ChunkSize, State);
				{true, _Proof} ->
					State
			end;
		Error ->
			invalidate_chunk(
				read_data_path_error, AbsoluteOffset, ChunkSize, [{reason, Error}], State)
	end.

verify_packing(Metadata, State) ->
	#state{packing=Packing, store_id=StoreID} = State,
	{AbsoluteOffset, _ChunkDataKey, _TXRoot, _DataRoot, _TXPath,
			_TXRelativeOffset, ChunkSize} = Metadata,
	PaddedOffset = ar_block:get_chunk_padded_offset(AbsoluteOffset),
	StoredPackingCheck = ar_sync_record:is_recorded(AbsoluteOffset, ar_data_sync, StoreID),
	ExpectedPacking =
		case ar_chunk_storage:is_storage_supported(PaddedOffset, ChunkSize, Packing) of
			true ->
				Packing;
			false ->
				unpacked
		end,
	case {StoredPackingCheck, ExpectedPacking} of
		{{true, ExpectedPacking}, _} ->
			%% Chunk is recorded in ar_sync_record under the expected Packing.
			ok;
		{{true, unpacked_padded}, {replica_2_9, _}} ->
			%% The module is in the process of entropy generation and has
			%% synced some chunks to offsets which do not yet have the entropy.
			ok;
		{{true, StoredPacking}, _} ->
			?LOG_WARNING([{event, verify_chunk_storage_unexpected_packing},
				{expected_packing, ar_storage_module:packing_label(Packing)},
				{stored_packing, ar_storage_module:packing_label(StoredPacking)},
				{offset, AbsoluteOffset}]),
			invalidate_chunk(unexpected_packing, AbsoluteOffset, ChunkSize, State);
		{Reply, _} ->
			?LOG_WARNING([{event, verify_chunk_storage_missing_packing_info},
				{expected_packing, ar_storage_module:packing_label(Packing)},
				{packing_reply, io_lib:format("~p", [Reply])},
				{offset, AbsoluteOffset}]),
			invalidate_chunk(missing_packing_info, AbsoluteOffset, ChunkSize, State)
	end,
	State.

verify_chunk_storage(AbsoluteOffset, PaddedOffset, ChunkSize, {End, Start}, State)
		when PaddedOffset - ?DATA_CHUNK_SIZE >= Start andalso PaddedOffset =< End ->
	#state{store_id = StoreID} = State,
	case ar_chunk_storage:read_offset(PaddedOffset, StoreID) of
		{ok, << 0:24 >>} ->
			%% The chunk is recorded in the ar_chunk_storage sync record, but not stored.
			invalidate_chunk(no_chunk_in_chunk_storage, AbsoluteOffset, ChunkSize, State);
		_ ->
			ok
	end,
	State;
verify_chunk_storage(AbsoluteOffset, PaddedOffset, ChunkSize, _Interval, State) ->
	#state{ packing = Packing } = State,
	case ar_chunk_storage:is_storage_supported(PaddedOffset, ChunkSize, Packing) of
		true ->
			invalidate_chunk(chunk_storage_gap, AbsoluteOffset, ChunkSize, State);
		false ->
			State
	end.

invalidate_chunk(Type, Offset, ChunkSize, State) ->
	invalidate_chunk(Type, Offset, ChunkSize, [], State).

invalidate_chunk(Type, Offset, ChunkSize, Logs, State) ->
	#state{ store_id = StoreID } = State,
	ar_data_sync:invalidate_bad_data_record(Offset, ChunkSize, StoreID, Type),
	log_error(Type, Offset, ChunkSize, Logs, State).

log_error(Type, Offset, ChunkSize, Logs, State) ->
	#state{ verify_report = Report, store_id = StoreID, cursor = Cursor, packing = Packing } = State,

	LogMessage = [{event, verify_chunk_storage_error},
		{type, Type}, {store_id, StoreID},
		{packing, ar_serialize:encode_packing(Packing, true)},
		{offset, Offset}, {cursor, Cursor}, {chunk_size, ChunkSize}] ++ Logs,
	?LOG_INFO(LogMessage),
	NewBytes = maps:get(Type, Report#verify_report.error_bytes, 0) + ChunkSize,
	NewChunks = maps:get(Type, Report#verify_report.error_chunks, 0) + 1,

	Report2 = Report#verify_report{
		total_error_bytes = Report#verify_report.total_error_bytes + ChunkSize,
		total_error_chunks = Report#verify_report.total_error_chunks + 1,
		error_bytes = maps:put(Type, NewBytes, Report#verify_report.error_bytes),
		error_chunks = maps:put(Type, NewChunks, Report#verify_report.error_chunks)
	},
	State#state{ verify_report = Report2 }.

query_intervals(State) ->
	#state{cursor = Cursor, store_id = StoreID} = State,
	{ChunkStorageInterval, DataSyncInterval} = align_intervals(Cursor, StoreID),
	UnionInterval = union_intervals(ChunkStorageInterval, DataSyncInterval),
	{UnionInterval, {ChunkStorageInterval, DataSyncInterval}}.

align_intervals(Cursor, StoreID) ->
	ChunkStorageInterval = ar_sync_record:get_next_synced_interval(
		Cursor, infinity, ar_chunk_storage, StoreID),
	DataSyncInterval = ar_sync_record:get_next_synced_interval(
		Cursor, infinity, ar_data_sync, StoreID),
	align_intervals(Cursor, ChunkStorageInterval, DataSyncInterval).

align_intervals(_Cursor, not_found, not_found) ->
	{not_found, not_found};
align_intervals(Cursor, not_found, DataSyncInterval) ->
	{not_found, clamp_interval(Cursor, infinity, DataSyncInterval)};
align_intervals(Cursor, ChunkStorageInterval, not_found) ->
	{clamp_interval(Cursor, infinity, ChunkStorageInterval), not_found};
align_intervals(Cursor, ChunkStorageInterval, DataSyncInterval) ->
	{ChunkStorageEnd, _} = ChunkStorageInterval,
	{DataSyncEnd, _} = DataSyncInterval,

	{
		clamp_interval(Cursor, DataSyncEnd, ChunkStorageInterval),
		clamp_interval(Cursor, ChunkStorageEnd, DataSyncInterval)
	}.

union_intervals(not_found, not_found) ->
	not_found;
union_intervals(not_found, B) ->
	B;
union_intervals(A, not_found) ->
	A;
union_intervals({End1, Start1}, {End2, Start2}) ->
	{max(End1, End2), min(Start1, Start2)}.

clamp_interval(ClampMin, ClampMax, {End, Start}) ->
	check_interval({min(End, ClampMax), max(Start, ClampMin)}).

check_interval({End, Start}) when Start > End ->
	not_found;
check_interval(Interval) ->
	Interval.

%% Report the sample results by sending them to ar_verify_chunks_reporter.
report_sample(StoreID, #sample_report{} = SampleReport) ->
	ar_verify_chunks_reporter:sample_update(StoreID, SampleReport).

report_progress(State) ->
	#state{ 
		store_id = StoreID, verify_report = Report, cursor = Cursor,
		start_offset = StartOffset, end_offset = EndOffset
	} = State,

	Status = case Cursor >= EndOffset of
		true -> done;
		false -> running
	end,

	BytesProcessed = Cursor - StartOffset,
	Progress = BytesProcessed * 100 div (EndOffset - StartOffset),
	Report2 = Report#verify_report{
		bytes_processed = BytesProcessed,
		progress = Progress,
		status = Status
	},
	ar_verify_chunks_reporter:update(StoreID, Report2),
	State#state{ verify_report = Report2 }.

%% Generate a list of Count random offsets in the range (Start, End]
%% (i.e. offsets strictly greater than Start and less than or equal to End)
%% such that if an offset is sampled, no other offsets are selected from the
%% open interval (Offset - ?DATA_CHUNK_SIZE, Offset + ?DATA_CHUNK_SIZE).
generate_sample_offsets(Start, End, Count) when is_integer(Start), is_integer(End) ->
	Candidates = lists:seq(Start + 1, End, ?DATA_CHUNK_SIZE),
	Count2 = min(Count, length(Candidates)),
	pick_offsets(Candidates, Count2).

pick_offsets(_Candidates, 0) ->
	[];
pick_offsets([], _Count) ->
	[];
pick_offsets(Candidates, Count) ->
	Offsets = pick_offsets_batch(min(Count, length(Candidates)), Candidates),
	UniqueOffsets = lists:usort(Offsets),
	NewCandidates = Candidates -- UniqueOffsets,
	UniqueOffsets ++ pick_offsets(NewCandidates, Count - length(UniqueOffsets)).

pick_offsets_batch(Len, Candidates) ->
	pick_offsets_batch(Len, Candidates, min(Len, 20)).

pick_offsets_batch(_Len, _Candidates, 0) ->
	[];
pick_offsets_batch(Len, Candidates, BatchSize) ->
	N = rand:uniform(Len),
	[lists:nth(N, Candidates) | pick_offsets_batch(Len, Candidates, BatchSize - 1)].

%% Use generate_sample_offsets/3 to obtain offsets (with exclusion)
%% and then queries ar_data_sync:get_chunk/2 with options to trigger unpacking.
sample_random_chunks(Count, Packing, Start, End, StoreID) ->
	Offsets = generate_sample_offsets(Start, End, Count),
	lists:foldl(fun(Offset, Acc) ->
		report_sample(StoreID, Acc),
		case ar_data_sync:get_chunk(Offset, #{pack => true, packing => Packing}) of
			{ok, _Proof} ->
				Acc#sample_report{
					total = Acc#sample_report.total + 1,
					success = Acc#sample_report.success + 1
				};
			{error, chunk_not_found} ->
				Acc#sample_report{
					total = Acc#sample_report.total + 1,
					not_found = Acc#sample_report.not_found + 1
				};
			{error, _Reason} ->
				Acc#sample_report{
					total = Acc#sample_report.total + 1,
					failure = Acc#sample_report.failure + 1
				}
		end
	end, #sample_report{}, Offsets).

%% ar_chunk_storage does not store small chunks before strict_split_data_threshold
%% (before 30607159107830 = partitions 0-7 and a half of 8
%% 

%%%===================================================================
%%% Tests.
%%%===================================================================

intervals_test_() ->
    [
        {timeout, 30, fun test_align_intervals/0},
		{timeout, 30, fun test_union_intervals/0}
	].

verify_chunk_storage_test_() ->
	[
		ar_test_node:test_with_mocked_functions(
			[{ar_chunk_storage, read_offset, fun(_Offset, _StoreID) -> << 1:24 >> end}],
			fun test_verify_chunk_storage_in_interval/0),
		ar_test_node:test_with_mocked_functions(
			[{ar_chunk_storage, read_offset, fun(_Offset, _StoreID) -> << 1:24 >> end}],
			fun test_verify_chunk_storage_should_store/0),
		ar_test_node:test_with_mocked_functions(
			[{ar_chunk_storage, read_offset, fun(_Offset, _StoreID) -> << 1:24 >> end}],
			fun test_verify_chunk_storage_should_not_store/0)
	].

verify_proof_test_() ->
	[
		ar_test_node:test_with_mocked_functions([
			{ar_data_sync, read_data_path, fun(_, _) -> not_found end}],
			fun test_verify_proof_no_datapath/0
		),
		ar_test_node:test_with_mocked_functions([
			{ar_data_sync, read_data_path, fun(_, _) -> {ok, <<>>} end},
			{ar_poa, validate_paths, fun(_, _, _, _) -> {true, <<>>} end}
		],
			fun test_verify_proof_valid_paths/0
		),
		ar_test_node:test_with_mocked_functions([
			{ar_data_sync, read_data_path, fun(_, _) -> {ok, <<>>} end},
			{ar_poa, validate_paths, fun(_, _, _, _) -> {false, <<>>} end}
		],
			fun test_verify_proof_invalid_paths/0
		)
	].

verify_chunk_test_() ->
	[
		ar_test_node:test_with_mocked_functions([
			{ar_data_sync, read_data_path, fun(_, _) -> {ok, <<>>} end},
			{ar_poa, validate_paths, fun(_, _, _, _) -> {true, <<>>} end}
		],
			fun test_verify_chunk/0
		)
	].

test_align_intervals() ->
	?assertEqual(
		{not_found, not_found},
		align_intervals(0, not_found, not_found)),
	?assertEqual(
		{{10, 5}, not_found},
		align_intervals(0, {10, 5}, not_found)),
	?assertEqual(
		{{10, 7}, not_found},
		align_intervals(7, {10, 5}, not_found)),
	?assertEqual(
		{not_found, not_found},
		align_intervals(12, {10, 5}, not_found)),
	?assertEqual(
		{not_found, {10, 5}},
		align_intervals(0, not_found, {10, 5})),
	?assertEqual(
		{not_found, {10, 7}},
		align_intervals(7, not_found, {10, 5})),
	?assertEqual(
		{not_found, not_found},
		align_intervals(12, not_found, {10, 5})),

	?assertEqual(
		{{9, 4}, {9, 5}},
		align_intervals(0, {9, 4}, {10, 5})),
	?assertEqual(
		{{9, 7}, {9, 7}},
		align_intervals(7, {9, 4}, {10, 5})),
	?assertEqual(
		{not_found, not_found},
		align_intervals(12, {9, 4}, {10, 5})),
	?assertEqual(
		{{9, 5}, {9, 4}},
		align_intervals(0, {10, 5}, {9, 4})),
	?assertEqual(
		{{9, 7}, {9, 7}},
		align_intervals(7, {10, 5}, {9, 4})),
	?assertEqual(
		{not_found, not_found},
		align_intervals(12, {10, 5}, {9, 4})),
	ok.
		
test_union_intervals() ->
	?assertEqual(
		not_found,
		union_intervals(not_found, not_found)),
	?assertEqual(
		{10, 5},
		union_intervals(not_found, {10, 5})),
	?assertEqual(
		{10, 5},
		union_intervals({10, 5}, not_found)),
	?assertEqual(
		{10, 3},
		union_intervals({10, 7}, {5, 3})),
	ok.


test_verify_chunk_storage_in_interval() ->
	?assertEqual(
		#state{},
		verify_chunk_storage(
			10*?DATA_CHUNK_SIZE,
			10*?DATA_CHUNK_SIZE,
			?DATA_CHUNK_SIZE,
			{20*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE},
			#state{})),
	?assertEqual(
		#state{},
		verify_chunk_storage(
			6*?DATA_CHUNK_SIZE - 1,
			6*?DATA_CHUNK_SIZE,
			?DATA_CHUNK_SIZE div 2,
			{20*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE},
			#state{})),
	?assertEqual(
		#state{},
		verify_chunk_storage(
			20*?DATA_CHUNK_SIZE - ?DATA_CHUNK_SIZE div 2,
			20*?DATA_CHUNK_SIZE,
			?DATA_CHUNK_SIZE div 2,
			{20*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE},
			#state{})),
	ok.

test_verify_chunk_storage_should_store() ->
	Addr = crypto:strong_rand_bytes(32),
	ExpectedState = #state{ 
		packing = unpacked,
		verify_report = #verify_report{
			total_error_bytes = ?DATA_CHUNK_SIZE,
			total_error_chunks = 1,
			error_bytes = #{chunk_storage_gap => ?DATA_CHUNK_SIZE},
			error_chunks = #{chunk_storage_gap => 1}
		} 
	},
	?assertEqual(
		ExpectedState,
		verify_chunk_storage(
			0,
			0,
			?DATA_CHUNK_SIZE,
			{20*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE},
			#state{ packing = unpacked })),
	?assertEqual(
		ExpectedState,
		verify_chunk_storage(
			?STRICT_DATA_SPLIT_THRESHOLD + 1,
			?STRICT_DATA_SPLIT_THRESHOLD + 1,
			?DATA_CHUNK_SIZE,
			{20*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE},
			#state{ packing = unpacked })),
	?assertEqual(
		#state{
			packing = {composite, Addr, 1},
			verify_report = #verify_report{
				total_error_bytes = ?DATA_CHUNK_SIZE div 2,
				total_error_chunks = 1,
				error_bytes = #{chunk_storage_gap => ?DATA_CHUNK_SIZE div 2},
				error_chunks = #{chunk_storage_gap => 1}
			} 
		},
		verify_chunk_storage(
			?STRICT_DATA_SPLIT_THRESHOLD + 1,
			?STRICT_DATA_SPLIT_THRESHOLD + 1,
			?DATA_CHUNK_SIZE div 2,
			{20*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE},
			#state{ packing = {composite, Addr, 1} })),
	ok.

test_verify_chunk_storage_should_not_store() ->
	ExpectedState = #state{ 
		packing = unpacked
	},
	?assertEqual(
		ExpectedState,
		verify_chunk_storage(
			0,
			0,
			?DATA_CHUNK_SIZE div 2,
			{20*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE},
			#state{ packing = unpacked })),
	?assertEqual(
		ExpectedState,
		verify_chunk_storage(
			?STRICT_DATA_SPLIT_THRESHOLD + 1,
			?STRICT_DATA_SPLIT_THRESHOLD + 1,
			?DATA_CHUNK_SIZE div 2,
			{20*?DATA_CHUNK_SIZE, 5*?DATA_CHUNK_SIZE},
			#state{ packing = unpacked })),
	ok.

test_verify_proof_no_datapath() ->
	ExpectedState1 = #state{ 
		packing = unpacked,
		verify_report = #verify_report{
			total_error_bytes = ?DATA_CHUNK_SIZE,
			total_error_chunks = 1,
			error_bytes = #{read_data_path_error => ?DATA_CHUNK_SIZE},
			error_chunks = #{read_data_path_error => 1}
		} 
	},
	ExpectedState2 = #state{ 
		packing = unpacked,
		verify_report = #verify_report{
			total_error_bytes = ?DATA_CHUNK_SIZE div 2,
			total_error_chunks = 1,
			error_bytes = #{read_data_path_error => ?DATA_CHUNK_SIZE div 2},
			error_chunks = #{read_data_path_error => 1}
		} 
	},
	?assertEqual(
		ExpectedState1,
		verify_proof(
			{10, <<>>, <<>>, <<>>, <<>>, <<>>, ?DATA_CHUNK_SIZE},
			#state{ packing = unpacked })),
	?assertEqual(
		ExpectedState2,
		verify_proof(
			{10, <<>>, <<>>, <<>>, <<>>, <<>>, ?DATA_CHUNK_SIZE div 2},
			#state{ packing = unpacked })),
	ok.

test_verify_proof_valid_paths() ->
	?assertEqual(
		#state{},
		verify_proof(
			{10, <<>>, <<>>, <<>>, <<>>, <<>>, ?DATA_CHUNK_SIZE},
			#state{})),
	ok.
	
test_verify_proof_invalid_paths() ->
	ExpectedState1 = #state{ 
		packing = unpacked,
		verify_report = #verify_report{
			total_error_bytes = ?DATA_CHUNK_SIZE,
			total_error_chunks = 1,
			error_bytes = #{validate_paths_error => ?DATA_CHUNK_SIZE},
			error_chunks = #{validate_paths_error => 1}
		} 
	},
	ExpectedState2 = #state{ 
		packing = unpacked,
		verify_report = #verify_report{
			total_error_bytes = ?DATA_CHUNK_SIZE div 2,
			total_error_chunks = 1,
			error_bytes = #{validate_paths_error => ?DATA_CHUNK_SIZE div 2},
			error_chunks = #{validate_paths_error => 1}
		} 
	},
	?assertEqual(
		ExpectedState1,
		verify_proof(
			{10, <<>>, <<>>, <<>>, <<>>, <<>>, ?DATA_CHUNK_SIZE},
			#state{ packing = unpacked })),
	?assertEqual(
		ExpectedState2,
		verify_proof(
			{10, <<>>, <<>>, <<>>, <<>>, <<>>, ?DATA_CHUNK_SIZE div 2},
			#state{ packing = unpacked })),
	ok.

test_verify_chunk() ->
	PreSplitOffset = ?STRICT_DATA_SPLIT_THRESHOLD - (?DATA_CHUNK_SIZE div 2),
	PostSplitOffset = ?STRICT_DATA_SPLIT_THRESHOLD + (?DATA_CHUNK_SIZE div 2),
	IntervalStart = ?STRICT_DATA_SPLIT_THRESHOLD - ?DATA_CHUNK_SIZE,
	IntervalEnd = ?STRICT_DATA_SPLIT_THRESHOLD + ?DATA_CHUNK_SIZE,
	Interval = {IntervalEnd, IntervalStart},
	?assertEqual(
		#state{cursor = PreSplitOffset, packing=unpacked},
		verify_chunk(
			{ok, <<>>, {PreSplitOffset, <<>>, <<>>, <<>>, <<>>, <<>>, ?DATA_CHUNK_SIZE div 2}},
			{Interval, not_found},
			#state{packing=unpacked})),
	?assertEqual(
		#state{cursor = ?STRICT_DATA_SPLIT_THRESHOLD + ?DATA_CHUNK_SIZE, packing=unpacked},
		verify_chunk(
			{ok, <<>>, {PostSplitOffset, <<>>, <<>>, <<>>, <<>>, <<>>, ?DATA_CHUNK_SIZE div 2}},
			{Interval, not_found},
			#state{packing=unpacked})),
	ExpectedState = #state{ 
		cursor = 33554432, %% = 2 * 2^24. From ar_data_sync:advance_chunks_index_cursor/1
		packing = unpacked,
		verify_report = #verify_report{
			total_error_bytes = 33554432,
			total_error_chunks = 1,
			error_bytes = #{get_chunk_error => 33554432},
			error_chunks = #{get_chunk_error => 1}
		}
	},
	?assertEqual(
		ExpectedState,
		verify_chunk(
			{error, some_error},
			{Interval, not_found},
			#state{ cursor = 0, packing = unpacked })),
	ok.

%% Verify that generate_sample_offsets/3 samples without replacement.
sample_offsets_without_replacement_test() ->
	ChunkSize = ?DATA_CHUNK_SIZE,
	Count = 5,
	Offsets = generate_sample_offsets(ChunkSize * 10, ChunkSize * 1000, Count),
	%% Check that exactly Count offsets are produced.
	?assertEqual(Count, length(Offsets)),
	%% For every pair, ensure the absolute difference is at least ?DATA_CHUNK_SIZE.
	lists:foreach(fun(A) ->
		lists:foreach(fun(B) ->
			case {A == B, abs(A - B) < ?DATA_CHUNK_SIZE} of
				{true, _} -> ok;
				{false, true} -> ?assert(false);
				_ -> ok
			end
		end, Offsets)
	end, Offsets),
	Offsets2 = generate_sample_offsets(0, ChunkSize, Count),
	%% We cannot sample more than one offset without replacement.
	?assertEqual(1, length(Offsets2)).

%% Verify sample_random_chunks/4 aggregates outcomes correctly.
%%
%% We mock ar_data_sync:get_chunk/2 such that:
%%   - The first call returns {error, chunk_not_found},
%%   - The second call returns {ok, <<"valid_proof">>},
%%   - The third call returns {error, invalid_chunk}.
%% Note: Using atoms for partition borders triggers the fallback in generate_sample_offsets/3.
sample_random_chunks_test_() ->
	[
		ar_test_node:test_with_mocked_functions(
			[{ar_data_sync, get_chunk, fun(_Offset, _Opts) ->
				%% Use process dictionary to simulate sequential responses.
				Counter = case erlang:get(sample_counter) of
					undefined -> 0;
					C -> C
				end,
				erlang:put(sample_counter, Counter + 1),
				case Counter of
					0 -> {error, chunk_not_found};
					1 -> {ok, <<"valid_proof">>};
					2 -> {error, invalid_chunk}
				end
			end}],
			fun test_sample_random_chunks/0)
	].

test_sample_random_chunks() ->
	%% Initialize counter.
	erlang:put(sample_counter, 0),
	Packing = unpacked,
	Report = sample_random_chunks(3, Packing, 0, 262144 * 3, "test"),
	ExpectedReport = #sample_report{total = 3, success = 1, not_found = 1, failure = 1},
	?assertEqual(ExpectedReport, Report).