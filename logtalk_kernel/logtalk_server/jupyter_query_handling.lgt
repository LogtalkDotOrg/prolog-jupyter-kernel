
% The main predicates are
% - call_with_output_to_file/3: call a goal and read all its output
% - call_query_with_output_to_file/7: call a goal, read all its output, and assert its runtime and query data
% - retrieve_message/2: for a term of the form message_data(Kind, Term), print the message with print_message(Kind, jupyter, Term) and read it

% Additionally, it provides the dynamic predicate query_data(CallRequestId, Runtime, TermData, OriginalTermData) where TermData and OriginalTermData are terms of the form term_data(TermAtom, Bindings).
% It is used to remember all queries' IDs, goal and runtime so that the data can be accessed by jupyter::print_query_time/0 and jupyter::print_queries/1.
% If there was a replacement of $Var terms in the original term, OriginalTermData contains the original term and its bindings.
% Otherwise, OriginalTermData=same


:- object(jupyter_query_handling).

	:- info([
		version is 0:1:0,
		author is 'Anne Brecklinghaus, Michael Leuschel, and Paulo Moura',
		date is 2022-11-13,
		comment is 'This object provides predicates to redirect the output of a query execution to a file and read it from the file.'
	]).

	:- public([
		call_query_with_output_to_file/7,  % call_query_with_output_to_file(+Goal, +CallRequestId, +Bindings, +OriginalTermData, -Output, -ErrorMessageData -IsFailure)
		call_with_output_to_file/3,        % call_with_output_to_file(+Goal, -Output, -ErrorMessageData)
		delete_output_file/1,              % delete_output_file(+DeleteFile)
		query_data/4,                      % query_data(-CallRequestId, -Runtime, -TermData, -OriginalTermData)
		redirect_output_to_file/0,
		remove_output_lines_for/1,         % remove_output_lines_for(Type),
		retrieve_message/2,                % retrieve_message(+ErrorMessageData, -Message)
		send_reply_on_error/0,
		debug_mode_for_breakpoints/0
	]).

	:- meta_predicate(call_with_output_to_file(*, *, *)).
	:- meta_predicate(call_query_with_output_to_file(*, *, *, *, *, *, *)).
	:- meta_predicate(call_with_exception_handling(*, *)).

	:- uses(debugger, [notrace/0]).
	:- uses(list, [append/2, append/3, length/2]).
	:- uses(logtalk, [print_message/3]).
	:- uses(os, [delete_file/1, wall_time/1]).
	:- uses(reader, [line_to_codes/2 as read_line_to_codes/2]).
	:- uses(term_io, [write_term_to_codes/3]).
	:- uses(jupyter_logging, [log/1, log/2]).

	% query_data(CallRequestId, Runtime, TermData, OriginalTermData)
	:- dynamic(query_data/4).

	% TermData and OriginalTermData are terms of the form term_data(TermAtom, Bindings)
	:- dynamic(remove_output_lines_for/1).  % remove_output_lines_for(Type),
	:- dynamic(send_reply_on_error/0).

	% If send_reply_on_error exists, an error reply is sent to the client if an unhandled error occurs and is printed with print_message/2.
	% This predicate is retracted when an error message is to be produced from an error term and therefore printed.
	send_reply_on_error.

	file_name(stdout, '.server_stdout').
	file_name(message_output, '.message_output').
	file_name(output, '.server_output').
	file_name(test, 'test_definition.pl').


	%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
	%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

	% Call a goal and read all output

	% call_with_output_to_file(+Goal, -Output, -ErrorMessageData)
	%
	% Redirects the output of the goal Goal and debugging messages to a file.
	% This is done by creating a file which is set as the current output and error stream.
	% Calls the goal Goal and reads its output Output (and debugging messages) from the file.
	% If an exception is thrown when calling the goal, ErrorMessageData is a term of the form message_data(Kind, Term) so that the acutal error message can be retrieved with print_message(Kind, jupyter, Term).
	% If Goal=jupyter::trace(TraceGoal), debug mode has to be switched off afterwards.
	call_with_output_to_file(Goal, Output, ErrorMessageData) :-
		prepare_call_with_output_to_file,
		% Call the goal Goal and compute the runtime
		(	call_with_exception_handling(Goal, ErrorMessageData)
		;	% Goal failed
			reset_output_streams(true),
			fail
		),
		cleanup_and_read_output_from_file(Goal, Output).

	% call_query_with_output_to_file(+Goal, +CallRequestId, +Bindings, +OriginalTermData, -Output, -ErrorMessageData -IsFailure)
	%
	% Like call_with_output_to_file/3.
	% Additionally, the runtime of the goal Goal is elapsed and query data is asserted.
	call_query_with_output_to_file(Goal, CallRequestId, Bindings, OriginalTermData, Output, ErrorMessageData, IsFailure) :-
		% Compute the atom of the goal Goal before calling it causes variables to be bound
		% The atom is needed for the term data which is asserted
		write_term_to_codes(Goal, GoalCodes, [variable_names(Bindings)]),
		atom_codes(GoalAtom, GoalCodes),
		prepare_call_with_output_to_file,
		% Call the goal Goal and compute the runtime
		wall_time(WallTime0),
		(	call_with_exception_handling(Goal, ErrorMessageData)
		;	% Goal failed
			IsFailure = true
		),
		wall_time(WallTime1),
		WallTime is WallTime1 - WallTime0,
		assert_query_data(CallRequestId, WallTime, term_data(GoalAtom, Bindings), OriginalTermData),
		cleanup_and_read_output_from_file(Goal, Output).


	prepare_call_with_output_to_file :-
		redirect_output_to_file,
		retractall(send_reply_on_error),
		!.


	% Redirects the output of a goal and debugging messages to a file
	redirect_output_to_file :-
		file_name(output, OutputFileName),
		open(OutputFileName, write, OutputStream, [alias(output_to_file_stream)]),
		% Set the streams to which the goal's output and debugging messages are written by default
		redirect_output_to_stream(current_output, OutputStream),
		redirect_output_to_stream(user_output, OutputStream),
		redirect_output_to_stream(user_error, OutputStream).


	% call_with_exception_handling(+Goal, -ErrorMessageData)
	call_with_exception_handling(Goal, ErrorMessageData) :-
		catch(
			{Goal},
			Exception,
			% In case of an exception, switch debug mode off so that no more debugging messages are printed
			(notrace, ErrorMessageData = message_data(error, Exception))
		).

	debug_mode_for_breakpoints.


	% assert_query_data(+CallRequestId,  +Runtime, +TermData, +OriginalTermData)
	assert_query_data(0, _Runtime, _TermData, _OriginalTermData) :- !.
	% Do not assert query data for requests with ID 0
	% With requests with this ID, the kernel can request additional data (e.g. for inspection in the case of SWI-Prolog)
	assert_query_data(CallRequestId, Runtime, TermData, OriginalTermData) :-
		nonvar(OriginalTermData),
		!,
		% Remember all queries' IDs, goal and runtime so that it can be accessed by jupyter:print_query_time/0 and jupyter:print_queries/1
		(	TermData = OriginalTermData ->
			StoreOriginalTermData = same
		;	% there was a replacement of $Var terms in the original term -> store both terms data
			StoreOriginalTermData = OriginalTermData
		),
		% Assert the data with assertz/1 so that they can be accessed in the correct order with jupyter:print_queries/1
		assertz(query_data(CallRequestId, Runtime, TermData, StoreOriginalTermData)).
	assert_query_data(_CallRequestId, _Runtime, _TermData, _OriginalTermData).


	% cleanup_and_read_output_from_file(+Goal, -Output)
	%
	% Output is the output and debugging messages of the goal Goal which was written to the output file.
	cleanup_and_read_output_from_file(Goal, Output) :-
		reset_output_streams(false),
		assertz(send_reply_on_error),
		file_name(output, OutputFileName),
		read_output_from_file(OutputFileName, Goal, Output),
		delete_output_file(true).


	% reset_output_streams(+DeleteFile)
	reset_output_streams(DeleteFile) :-
		close(output_to_file_stream),
		delete_output_file(DeleteFile).


	% delete_output_file(+DeleteFile)
	delete_output_file(true) :-
		!,
		file_name(output, OutputFileName),
		catch(delete_file(OutputFileName), _Exception, true).
	delete_output_file(_).


	%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
	%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

	% Print and read (error) messages

	% retrieve_message(+ErrorMessageData, -Message)
	%
	% ErrorMessageData either null or a term of the form message_data(Kind, Term).
	% In the first case, Message=''.
	% Otherwise, Message is the message as printed by print_message(Kind, jupyter, Term).
	% For this, the error stream is redirected to a file, the message is printed and read from the file.
	retrieve_message(null, '') :- !.
	retrieve_message(message_data(Kind, Term), Message) :-
		% Open a file to print the message to it
		file_name(message_output, FileName),
		open(FileName, write, Stream),
		redirect_output_to_stream(user_output, Stream),
		% Do not send an error reply when printing the error message
		% Use catch/3, because send_reply_on_error might have been retracted by call_with_output_to_file/3
		catch(retractall(send_reply_on_error), _Exception, true),
		print_message(Kind, jupyter, Term),
		assertz(send_reply_on_error),
		close(Stream),
		% Read the error message from the file
		read_atom_from_file(FileName, Message),
		delete_file(FileName),
		!.


	% redirect_output_to_stream(+StreamAlias, +Stream)
	:- if(current_logtalk_flag(prolog_dialect, eclipse)).

		redirect_output_to_stream(StreamAlias, Stream) :-
			set_stream(StreamAlias, Stream).
	
	:- elif(predicate_property(set_stream(_,_), built_in)).

		redirect_output_to_stream(StreamAlias, Stream) :-
			set_stream(Stream, alias(StreamAlias)).

	:- elif(current_logtalk_flag(prolog_dialect, sicstus)).

		redirect_output_to_stream(current_output, Stream) :-
			!,
			set_output(Stream).
		redirect_output_to_stream(StreamAlias, Stream) :-
			set_prolog_flag(StreamAlias, Stream).

	:- endif.


	%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
	%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

	% Read from a file

	% read_output_from_file(+OutputFileName, +Goal, -Output)
	read_output_from_file(OutputFileName, _, Output) :-
		read_atom_from_file(OutputFileName, Output).


	% read_atom_from_file(+FileName, -FileContent)
	%
	% FileContent is an atom containing the content of the file with name FileName.
	% If IsSicstusJupyterTrace=true, some of the lines of the file are not included.
	read_atom_from_file(FileName, FileContent) :-
		open(FileName, read, Stream),
		read_lines(Stream, AllLinesCodes),
		close(Stream),
		AllLinesCodes \= [],
		!,
		remove_output_lines(AllLinesCodes, LineCodes),
		% Create an atom from the line lists
		(	LineCodes == [] ->
			FileContent = ''
		;	append(LineCodes, [_|ContentCodes]), % Cut off the first new line code
			atom_codes(FileContent, ContentCodes)
		).
	read_atom_from_file(_FileName, '').


	% read_lines(+Stream, -Lines)
	read_lines(Stream, NewLines) :-
		read_line_to_codes(Stream, Line),
		(	Line == end_of_file ->
			NewLines = []
		;	% Add a new line code to the beginning of each line
			NewLines = [[10|Line]|Lines],
			read_lines(Stream, Lines)
		).


	% remove_output_lines(++Lines, -NewLines)
	%
	% Lines is a list of codes corresponding to lines read from a file to which output of a goal was written.
	% In some cases such as for a jupyter::trace/1 or juypter::print_sld_tree/1 call, not all lines should be included in the output sent to the client.
	remove_output_lines(Lines, NewLines) :-
		remove_output_lines_for(sld_tree_breakpoint_messages),
		!,
		retractall(remove_output_lines_for(sld_tree_breakpoint_messages)),
		% The output was produced by a call of jupyter:print_sld_tree
		% The first two lines are of the following form:
		% "% The debugger will first leap -- showing spypoints (debug)"
		% "% Generic spypoint added, BID=1"
		% The last line is like the following:
		% "% Generic spypoint, BID=1, removed (last)"
		% The lines corresponding to those messages are removed
		append(LinesWithoutLast, [_LastLine], Lines),
		LinesWithoutLast = [_First, _Second|NewLines].
	remove_output_lines(Lines, Lines).

:- end_object.
