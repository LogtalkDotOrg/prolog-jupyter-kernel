
:- initialization((
	logtalk_load(basic_types(loader)),
	logtalk_load(format(loader)),
	logtalk_load(json(loader)),
	logtalk_load(meta(loader)),
	logtalk_load(os(loader)),
	logtalk_load(reader(loader)),
	logtalk_load(term_io(loader)),
	logtalk_load([
		jupyter_logging,
		jupyter_preferences,
		jupyter_variable_bindings,
		jupyter_term_handling,
		jupyter_query_handling,
		jupyter_request_handling,
		jupyter_jsonrpc,
		jupyter_server,
		jupyter
	], [
		portability(warning)
	])
)).